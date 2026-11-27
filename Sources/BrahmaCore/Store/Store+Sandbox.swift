import Foundation
import GRDB

/// A change to a company's sandbox settings; nil fields are left as they are.
public struct SandboxPatch: Equatable, Sendable {
    public var profile: PermissionProfile?
    public var roleProfiles: [String: PermissionProfile]?
    public var allowedDomains: [String]?
    public var webDomains: [String]?
    public var allowLocalBinding: Bool?
    public var toolchainReadPaths: [String]?

    public init(profile: PermissionProfile? = nil, roleProfiles: [String: PermissionProfile]? = nil, allowedDomains: [String]? = nil,
                webDomains: [String]? = nil, allowLocalBinding: Bool? = nil, toolchainReadPaths: [String]? = nil) {
        self.profile = profile; self.roleProfiles = roleProfiles; self.allowedDomains = allowedDomains
        self.webDomains = webDomains; self.allowLocalBinding = allowLocalBinding; self.toolchainReadPaths = toolchainReadPaths
    }
}

extension Store {
    /// The owner's change to a company's sandbox settings (the only way they change; `updateCompany` keeps them). Domains are
    /// lowercased, deduped and sorted; each must be a valid pattern (`DomainMatcher.isValidPattern`) and never Anthropic's
    /// (`.forbiddenDomain`). Read paths must be absolute or `~/…` and are
    /// validated as a turn's scope would be (`SandboxScope.forTurn`/`validate`) against the owner's protected paths, the data
    /// home and every other company's workspace, whether or not they exist yet. A refused patch changes nothing.
    public func updateSandbox(companyId: String, _ patch: SandboxPatch,
                              userHome: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try updateSandbox(companyId: companyId, patch, userHome: userHome, unless: { _ in false })
    }

    /// `unless`: checked on the stored row inside the write transaction; true leaves the row as it is (`editSandbox`).
    func updateSandbox(companyId: String, _ patch: SandboxPatch, userHome: URL, unless: (Company) -> Bool) throws {
        func domains(_ list: [String]) throws -> [String] {
            for d in list { try SandboxDomains.check(d) }
            return Array(Set(list.map(SandboxDomains.normalize))).sorted()
        }
        let allowed = try patch.allowedDomains.map(domains)
        let web = try patch.webDomains.map(domains)
        func apply(_ company: inout Company) {
            if let profile = patch.profile { company.permissionProfile = profile }
            if let roles = patch.roleProfiles { company.roleProfiles = roles }
            if let allowed { company.allowedDomains = allowed }
            if let web { company.webDomains = web }
            if let binding = patch.allowLocalBinding { company.allowLocalBinding = binding }
            if let reads = patch.toolchainReadPaths { company.toolchainReadPaths = reads }
        }
        // Validated from a fetched copy, outside the write transaction (it reads the file system).
        let (fetched, others) = try writer.read { db in
            (try Company.fetchOne(db, key: companyId),
             try Company.filter(Column("id") != companyId).fetchAll(db).map { URL(fileURLWithPath: $0.workspacePath, isDirectory: false) })
        }
        guard var candidate = fetched else { throw StoreError.notFound }
        apply(&candidate)
        // The scope a turn would get; its validation covers the read paths and every domain.
        let workspaces = URL(fileURLWithPath: candidate.workspacePath, isDirectory: false).deletingLastPathComponent()
        let paths = BrahmaPaths(home: dataHome ?? FileManager.default.temporaryDirectory.appending(path: "brahma-home-\(companyId)"),
                                workspaces: workspaces)
        let layout = SandboxLayout(paths: paths, company: candidate, agentHandle: "sandbox-check")
        _ = try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: others,
                                     backupTargets: try BackupTargets.requiredProtectedFolders(store: self), kind: .audit,
                                     item: nil, company: candidate, grants: GrantInputs(), darwinUserTemp: nil, userHome: userHome)
        try writer.write { db in
            guard var company = try Company.fetchOne(db, key: companyId) else { throw StoreError.notFound }
            if unless(company) { return }
            apply(&company)
            try company.update(db)
        }
    }

    /// An owner edit computed from the STORED company (M8): `edit` gets the current row, its patch is validated as
    /// `updateSandbox` does, and the write happens only if the row has not changed meanwhile (else the edit is recomputed from
    /// the new row, a few times). Two edits made at once both land.
    public func editSandbox(companyId: String, userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                            _ edit: (Company) throws -> SandboxPatch) throws {
        for _ in 0..<5 {
            guard let current = try company(id: companyId) else { throw StoreError.notFound }
            let patch = try edit(current)
            var changed = false
            try updateSandbox(companyId: companyId, patch, userHome: userHome, unless: { stored in
                changed = !Store.sameSandbox(stored, current)
                return changed
            })
            if !changed { return }
        }
        throw WorkError.invalid("the company's sandbox settings kept changing; try again")
    }

    static func sameSandbox(_ a: Company, _ b: Company) -> Bool {
        a.permissionProfile == b.permissionProfile && a.roleProfiles == b.roleProfiles && a.allowedDomains == b.allowedDomains
            && a.webDomains == b.webDomains && a.allowLocalBinding == b.allowLocalBinding && a.toolchainReadPaths == b.toolchainReadPaths
    }
}

/// One owner edit of a list in a company's sandbox settings (`brahma network`).
public enum SandboxListEdit: Equatable, Sendable {
    case add(String)
    case remove(String)
}

public enum SandboxEditError: Error, Equatable, CustomStringConvertible {
    /// The domain is one of the built-in defaults, which are not stored and cannot be removed.
    case isDefault(String)
    case notInList(String)
    case unknownRole(String)

    public var description: String {
        switch self {
        case .isDefault(let d): "\(d) is a default and cannot be removed"
        case .notInList(let v): "\(v) is not in the list"
        case .unknownRole(let r): "no role '\(r)' in this company"
        }
    }
}

extension SandboxPatch {
    /// The company's profile, or (with `role`) that role's override.
    public static func profile(_ profile: PermissionProfile, role: String?, company: Company) -> SandboxPatch {
        guard let role else { return SandboxPatch(profile: profile) }
        var roles = company.roleProfiles
        roles[role] = profile
        return SandboxPatch(roleProfiles: roles)
    }

    /// A Bash egress domain (or, `web`, a WebFetch domain) added or removed. Defaults cannot be removed.
    public static func domains(_ edit: SandboxListEdit, web: Bool, company: Company) throws -> SandboxPatch {
        let current = web ? company.webDomains : company.allowedDomains
        let defaults = Set(web ? CompanyNetwork.defaultRegistries + CompanyNetwork.defaultDocs : CompanyNetwork.defaultRegistries)
        var list = current
        switch edit {
        case .add(let d):
            list.append(d)
        case .remove(let d):
            let n = SandboxDomains.normalize(d)
            if defaults.contains(n) { throw SandboxEditError.isDefault(n) }
            guard list.contains(n) else { throw SandboxEditError.notInList(n) }
            list.removeAll { $0 == n }
        }
        return web ? SandboxPatch(webDomains: list) : SandboxPatch(allowedDomains: list)
    }

    /// A toolchain read path added or removed (validated by `Store.updateSandbox`).
    public static func toolchain(_ edit: SandboxListEdit, company: Company) throws -> SandboxPatch {
        var list = company.toolchainReadPaths
        switch edit {
        case .add(let p):
            if !list.contains(p) { list.append(p) }
        case .remove(let p):
            guard list.contains(p) else { throw SandboxEditError.notInList(p) }
            list.removeAll { $0 == p }
        }
        return SandboxPatch(toolchainReadPaths: list)
    }
}

extension CompanyNetwork {
    /// The effective lists a company's sandboxed turns get, defaults marked `(default)` (`brahma network <co>`).
    public static func listing(company: Company) -> [String] {
        let scope = scope(company: company, grantDomains: [], grantWebDomains: [])
        let bashDefaults = Set(defaultRegistries), webDefaults = Set(defaultRegistries + defaultDocs)
        var lines = ["Bash egress (sandboxed turns and checks):"]
        lines += scope.allowedDomains.map { "  \($0)" + (bashDefaults.contains($0) ? " (default)" : "") }
        lines.append("WebFetch:")
        lines += scope.webDomains.map { "  \($0)" + (webDefaults.contains($0) ? " (default)" : "") }
        lines.append("Local binding: \(company.allowLocalBinding ? "on" : "off")" + (company.allowLocalBinding ? " (default)" : ""))
        lines.append("Toolchain read paths:")
        lines += company.toolchainReadPaths.isEmpty ? ["  (none)"] : company.toolchainReadPaths.map { "  \($0)" }
        var profile = "Profile: \(company.permissionProfile.rawValue)" + (company.permissionProfile == .sandboxed ? " (default)" : "")
        for (role, p) in company.roleProfiles.sorted(by: { $0.key < $1.key }) { profile += "; \(role): \(p.rawValue)" }
        lines.append(profile)
        return lines
    }
}

extension Store {
    /// Ruling C5b-8 (FW-B2): the keys of this company's items whose live reader set the agent is in (Ruling C5b-5, the same
    /// rule the engine reads by, `RefAccess.liveDiffSubject`: the current lease holder, else the assignee, plus the
    /// reviewer). The sandboxed turn mounts the live places (worktree, progress file, git admin dir) of exactly these items
    /// (`SandboxScope.forTurn(liveReadKeys:)`). Throws when the records cannot be read: the caller then mounts none.
    public func liveReaderItemKeys(companyId: String, agentId: String) throws -> Set<String> {
        try writer.read { db in
            let candidates = try WorkItem.fetchAll(db, sql: """
                SELECT * FROM workItem WHERE companyId = ? AND (ownerId = ? OR reviewerId = ?
                    OR id IN (SELECT itemId FROM workLease WHERE agentId = ? AND companyId = ?))
                """, arguments: [companyId, agentId, agentId, agentId, companyId])
            var keys: Set<String> = []
            for item in candidates where try RefAccess.liveDiffSubject(db, companyId, item).readerSet?.contains(agentId) == true {
                keys.insert(item.key)
            }
            return keys
        }
    }
}

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
        _ = try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: others, backupTargets: [], kind: .audit,
                                     item: nil, company: candidate, grants: GrantInputs(), darwinUserTemp: nil, userHome: userHome)
        try writer.write { db in
            guard var company = try Company.fetchOne(db, key: companyId) else { throw StoreError.notFound }
            apply(&company)
            try company.update(db)
        }
    }
}

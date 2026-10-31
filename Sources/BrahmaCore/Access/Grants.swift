import Foundation
import GRDB

// Grants widen one agent's (or a role's, an item's, the company's) sandbox: a Bash egress domain, a WebFetch domain, or a
// read-only path. An agent asks with `request_access` (a `grant` ask); only the owner approves one (`Store.approveAccess`,
// or `ownerDecide` on the ask), or an access preset the owner turned on, which goes through `ownerDecide` itself. Each turn
// resolves the active grants (`GrantResolver`) into `GrantInputs` for `SandboxScope.forTurn`; the ledger counts each use.

/// What a grant opens.
public enum GrantKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    /// A Bash egress domain (the sandbox's network allow-list).
    case networkDomain = "network_domain"
    /// A WebFetch domain.
    case webDomain = "web_domain"
    /// A directory the turn may read (never write).
    case readPath = "read_path"
    /// An installed extension, `<publisher>/<id>` (Task 5a; refused until extensions are installable).
    case `extension`

    /// Reading the web is low risk; reaching a host from Bash, reading a local path or mounting code is medium.
    public var risk: AskRisk { self == .webDomain ? .low : .medium }
}

/// Who a grant applies to.
public enum GrantScope: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    /// The requester's next turn only.
    case once
    /// Whoever's turn works the item (`scopeRef` = the item id).
    case item
    /// The requester (`scopeRef` = its agent id).
    case agent
    /// Every agent whose role is, or covers, `scopeRef`.
    case role
    /// Every agent of the company.
    case company
}

/// How long a grant lasts.
public enum GrantDuration: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    /// One turn.
    case turn
    /// While the requester's team's (else the company's) active sprint lasts; without one, `GrantResolver.noSprintTTL` active seconds.
    case sprint
    /// Until revoked.
    case always
}

/// One entry of the grant ledger, shown as `G-<number>`.
public struct Grant: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "grant"

    public var id: String
    public var companyId: String
    public var number: Int
    /// The `grant` ask it came from.
    public var askId: String?
    public var kind: GrantKind
    /// A normalized domain pattern, or a resolved absolute path.
    public var value: String
    public var scope: GrantScope
    /// The item id, agent id or role id the scope names (nil for `once` and `company`).
    public var scopeRef: String?
    public var requesterId: String?
    public var duration: GrantDuration
    /// A `sprint` grant ends with this sprint.
    public var sprintId: String?
    /// Company-active seconds at which it expires.
    public var expiresActive: Double?
    /// nil: unlimited.
    public var usesLeft: Int?
    /// "owner" or "preset:<id>".
    public var approvedBy: String
    public var createdAt: Date
    public var revokedAt: Date?
    /// "owner" or "kill".
    public var revokedBy: String?
    public var lastUsedAt: Date?
    public var useCount: Int = 0

    public var ref: String { "G-\(number)" }
}

/// What the agent asked for, as stored in the ask's `payload.details` (JSON).
public struct RequestedGrant: Codable, Equatable, Sendable {
    public var kind: GrantKind
    public var value: String
    public var duration: GrantDuration

    private enum CodingKeys: String, CodingKey { case kind = "grantKind", value, duration }
}

public enum Grants {
    /// What the agent hears for every refused read path, whatever the reason: a specific answer would let it probe which
    /// directories exist or are protected. The owner sees the reason (`Store.accessRefusals`, `brahma access`).
    public static let pathRefusal = "That path can't be granted; the owner can see why with brahma access."

    /// Multi-tenant parents (anyone can get a name under them): a wildcard grant whose parent is one of these, or lies under
    /// one, is refused. The single-label and country suffixes of `DomainMatcher.publicSuffixes` are matched exactly there; these
    /// also match as a suffix. (Folded into `DomainMatcher.publicSuffixes` in the final wave.)
    public static let multiTenantSuffixes: Set<String> = Set(DomainMatcher.publicSuffixes.filter {
        $0.contains(".") && !["co.uk", "org.uk", "com.au"].contains($0)
    }).union(["trycloudflare.com", "fly.dev", "onrender.com", "r2.dev", "ngrok.app", "web.core.windows.net"])

    /// An extension that is not installed (and enabled) in the company is refused with this.
    static func noExtension(_ id: String) -> String {
        "No extension '\(Store.flat(id, max: 200))'. Build one in your lab and use propose_extension."
    }

    /// The normalized value, or throws why it cannot be granted:
    /// - domains: `DomainMatcher.isValidPattern` (no public-suffix wildcard, `localhost`, IP literal or `*`) and never Anthropic's.
    ///   A `network_domain` (Bash egress) is an exact host only; a `web_domain` wildcard's parent may not be or lie under a
    ///   multi-tenant suffix (`multiTenantSuffixes`);
    /// - read paths: absolute, an existing directory reached without a symbolic link (`isPinned` once resolved), no character a
    ///   sandbox profile cannot carry, not overlapping `/Volumes` or any place a turn can write (the company's workspace with its
    ///   `.git` and `.brahma`, the Darwin user temp dir), and accepted as a read path by the scope a turn would get
    ///   (`SandboxScope.forTurn`: no overlap with the owner's protected paths, the data home, another company's workspace, a
    ///   backup target; never the owner's home itself). Returned resolved;
    /// - extensions: refused until extensions can be installed (Task 5a).
    public static func validate(kind: GrantKind, value raw: String, company: Company, paths: BrahmaPaths,
                                environment: SandboxEnvironment = .owner, otherWorkspaces: [URL] = [],
                                backupTargets: [URL] = [], installedExtensions: Set<String> = []) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .networkDomain, .webDomain:
            try SandboxDomains.check(value)
            let domain = SandboxDomains.normalize(value)
            if domain.hasPrefix("*.") {
                guard kind == .webDomain else {
                    throw WorkError.invalid("a network_domain grant is one exact host name; ask for each host you need")
                }
                let base = String(domain.dropFirst(2))
                if multiTenantSuffixes.contains(where: { base == $0 || base.hasSuffix("." + $0) }) {
                    throw WorkError.invalid("\(domain) would cover names anyone can register; ask for exact host names")
                }
            }
            return domain
        case .extension:
            // `<publisher>/<id>`, installed and enabled in this company (`installedExtensions` holds those keys).
            guard let ref = ExtensionRef.parse(value), installedExtensions.contains(ref.key) else { throw WorkError.invalid(noExtension(value)) }
            return ref.key
        case .readPath:
            if SandboxPath.isUnsafe(value) { throw SandboxError.unsafePathCharacter(value) }
            guard value.hasPrefix("/") else { throw WorkError.invalid("a read path must be absolute: \(Store.flat(value, max: 200))") }
            let resolved = URL(fileURLWithPath: value, isDirectory: false).resolvedForSandbox
            guard isPinned(resolved.path) else {
                throw WorkError.invalid("a read path must be an existing directory reached without a link: \(Store.flat(value, max: 200))")
            }
            // Never a place a turn can write: the agent could replace what was granted with a link to anything. Compared by
            // spelling and by identity (device and inode), so a firmlink or alias spelling is the same place.
            let writable = turnWritablePlaces(company: company, environment: environment)
            for place in writable.flatMap({ [$0, $0.resolvedForSandbox] }) where SandboxPath.overlaps(resolved.path, place.path) {
                throw SandboxError.overlapsProtected(path: resolved.path, protected: place.path)
            }
            if let hit = SandboxPath.IdentityRoots(writable).overlapping(resolved.path) {
                throw SandboxError.overlapsProtected(path: resolved.path, protected: hit)
            }
            if inClaudeTemp(resolved.path) {
                throw SandboxError.overlapsProtected(path: resolved.path, protected: "/private/tmp/claude*")
            }
            // The scope a turn of this company would get with only this grant: its checks are the turn's own.
            let layout = SandboxLayout(paths: paths, company: company, agentHandle: "grant-check")
            _ = try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: otherWorkspaces, backupTargets: backupTargets,
                                         kind: .audit, item: nil, company: company, grants: GrantInputs(readPaths: [resolved]),
                                         darwinUserTemp: environment.darwinUserTemp, userHome: environment.userHome)
            return resolved.path
        }
    }

    /// A granted path stays what the owner approved: it is absolute and safe, it resolves to itself, and no component of it is
    /// a symbolic link (an `lstat` walk from `/`); it is a directory.
    public static func isPinned(_ path: String) -> Bool { SandboxPath.isPinnedDirectory(path) }

    /// Where a sandboxed turn can write outside its own places, besides the company workspace: `/Volumes` (never grantable),
    /// the Darwin user temp dir, and Claude Code's own sandbox write defaults under the owner's home (`~/.npm`; `~/.claude` is
    /// protected). `/private/tmp/claude*` is matched by `inClaudeTemp`.
    static func turnWritablePlaces(company: Company, environment: SandboxEnvironment) -> [URL] {
        [URL(fileURLWithPath: "/Volumes", isDirectory: false), URL(fileURLWithPath: company.workspacePath, isDirectory: false),
         environment.userHome.appending(path: ".npm"), environment.userHome.appending(path: ".claude")]
            + (environment.darwinUserTemp.map { [$0] } ?? [])
    }

    /// The path is `/private/tmp` (or contains it), or lies in a `claude…` directory directly under it (Claude Code writes
    /// `/tmp/claude`, `/tmp/claude-<uid>`, `/tmp/claude-tool-results`): compared by identity, so `/tmp` and alias spellings match.
    static func inClaudeTemp(_ path: String) -> Bool {
        guard let tmp = SandboxPath.identity("/private/tmp") else { return false }
        if let id = SandboxPath.identity(path), SandboxPath.lineage("/private/tmp").contains(id) { return true }
        var current = ""
        var parentIsTmp = SandboxPath.identity("/") == tmp
        for part in path.split(separator: "/") {
            if parentIsTmp, part.lowercased().hasPrefix("claude") { return true }
            current += "/" + part
            parentIsTmp = SandboxPath.identity(current) == tmp
        }
        return false
    }

    /// How a stored read-path grant compares with what was approved, right before a turn.
    enum PathState: Equatable {
        case ok
        /// Gone for now (a part of it is missing): left out of this turn only.
        case missing
        /// A link, an alias or something other than a directory is where the approved directory was: revoked.
        case changed
        /// It is still the same directory, but now overlaps something new (another workspace, a backup target): left out of
        /// this turn only.
        case refused
    }

    static func pathState(_ grant: Grant, company: Company, paths: BrahmaPaths, environment: SandboxEnvironment,
                          otherWorkspaces: [URL], backupTargets: [URL]) -> PathState {
        guard grant.kind == .readPath else { return .ok }
        let value = grant.value
        var current = ""
        for part in value.split(separator: "/") {
            current += "/" + part
            switch SandboxPath.kind(current) {
            case .directory: continue
            case .missing: return .missing
            default: return .changed
            }
        }
        guard isPinned(value) else { return .changed }
        guard let again = try? validate(kind: .readPath, value: value, company: company, paths: paths, environment: environment,
                                        otherWorkspaces: otherWorkspaces, backupTargets: backupTargets),
              SandboxPath.key(again) == SandboxPath.key(value) else { return .refused }
        return .ok
    }

    /// The agent's request as stored on a `grant` ask; nil for any other ask.
    public static func requested(_ ask: Ask) -> RequestedGrant? {
        guard ask.kind == .grant, let details = ask.payload?.details else { return nil }
        return try? JSONDecoder().decode(RequestedGrant.self, from: Data(details.utf8))
    }

    static func details(_ request: RequestedGrant) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(request)) ?? Data(), as: UTF8.self)
    }
}

/// Which grants a turn gets.
public enum GrantResolver {
    /// A `sprint` grant without an active sprint lasts this many company-active seconds (7 active days).
    public static let noSprintTTL: TimeInterval = 7 * 86_400

    /// Not revoked, not expired (`expiresActive` against company-active time), uses left, and its sprint (if any) still active.
    public static func isLive(_ grant: Grant, activeNow: Double, sprintActive: (String) -> Bool) -> Bool {
        guard grant.revokedAt == nil else { return false }
        if let expires = grant.expiresActive, activeNow >= expires { return false }
        if let uses = grant.usesLeft, uses <= 0 { return false }
        if let sprint = grant.sprintId, !sprintActive(sprint) { return false }
        return true
    }

    /// The live grants that apply to a turn of `agent` (working `itemId`, if any). `roles` is the agent's role plus the roles it
    /// covers (`RoleTemplate.covers`): a `role` grant applies when its role is one of them.
    /// A review or audit turn gets neither one-use grants (`once` scope, `turn` duration: they are meant for the requester's
    /// own work) nor item grants (a reviewer does not work the item).
    public static func active(_ grants: [Grant], agent: Agent, roles: Set<String>, itemId: String?, kind: TurnKind = .work,
                              activeNow: Double, sprintActive: (String) -> Bool) -> [Grant] {
        let reviewing = kind == .review || kind == .audit
        let itemId = reviewing ? nil : itemId
        return grants.filter { g in
            guard g.companyId == agent.companyId, isLive(g, activeNow: activeNow, sprintActive: sprintActive) else { return false }
            if reviewing, g.scope == .once || g.duration == .turn { return false }
            switch g.scope {
            case .once: return g.requesterId == agent.id
            case .item: return itemId != nil && g.scopeRef == itemId
            case .agent: return g.scopeRef == agent.id
            case .role: return g.scopeRef.map(roles.contains) ?? false
            case .company: return true
            }
        }
    }

    /// What the grants add to a turn's scope (extension grants as `<publisher>/<id>`, resolved by `RoleBundle`).
    public static func inputs(_ grants: [Grant]) -> GrantInputs {
        func values(_ kind: GrantKind) -> [String] { Array(Set(grants.filter { $0.kind == kind }.map(\.value))).sorted() }
        return GrantInputs(domains: values(.networkDomain), webDomains: values(.webDomain),
                           readPaths: values(.readPath).map { URL(fileURLWithPath: $0, isDirectory: false) }, extensions: values(.extension))
    }
}

// MARK: Presets

/// Access presets the owner can turn on per company; both are off by default.
public enum AccessPreset: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    /// Engineers (and the roles near them) may read well-known documentation sites.
    case readOnlyWebForEngineers = "readonly-web-engineers"
    /// Under the `auto` autonomy preset, low-risk web reads are approved for the requester for the sprint.
    case autoModeLowRisk = "auto-low-risk"
}

/// Refused `request_access` calls are counted per agent: past `perActiveDay` in `window` company-active seconds, every
/// request is refused, so an agent cannot probe the owner's file system or the domain rules without bound.
public enum AccessRefusals {
    public static let perActiveDay = 5
    public static let window: TimeInterval = 86_400
    public static let message = "Too many of your access requests were refused today; ask the owner with request_from_owner instead."
}

/// One refused `request_access` call, with the reason only the owner sees.
public struct AccessRefusal: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "accessRefusal"
    public var id: Int64?
    public var companyId: String
    public var agentId: String
    public var kind: String
    public var value: String
    public var detail: String
    public var createdActive: Double
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public enum AccessPresets {
    /// Exact host names `readonly-web-engineers` approves (never a wildcard).
    public static let docsHosts: Set<String> = [
        "docs.stripe.com", "docs.github.com", "docs.aws.amazon.com", "learn.microsoft.com", "cloud.google.com", "docs.npmjs.com",
        "docs.docker.com", "kubernetes.io", "react.dev", "nextjs.org", "vuejs.org", "svelte.dev", "tailwindcss.com",
        "www.postgresql.org", "sqlite.org", "redis.io", "docs.djangoproject.com", "fastapi.tiangolo.com",
        "flask.palletsprojects.com", "stackoverflow.com",
    ]
    /// Roles whose covering roles `readonly-web-engineers` serves.
    public static let engineeringRoles = ["engineer", "qa", "devops", "security", "architect"]
    /// The ask category of every access request.
    public static let category = "tooling"

    public struct Decision: Equatable, Sendable {
        public var preset: AccessPreset
        public var scope: GrantScope
        public var duration: GrantDuration
        public var approvedBy: String { "preset:\(preset.rawValue)" }
    }

    /// The grant an enabled preset approves without the owner, or nil. Never for a risk of medium or more, a reserved matter,
    /// anything but a web domain, or a wildcard.
    public static func autoDecision(kind: GrantKind, value: String, risk: AskRisk, requesterRole: String, company: Company,
                                    enabled: Set<AccessPreset>, pack: IndustryPack?) -> Decision? {
        // The floor, whatever preset is on.
        guard risk == .low, kind.risk == .low, kind == .webDomain else { return nil }
        guard !ReservedMatters.isReserved(category, extra: pack?.reservedCategories ?? []) else { return nil }
        let host = SandboxDomains.normalize(value)
        guard !host.contains("*"), DomainMatcher.isValidPattern(host), !SandboxDomains.isForbidden(host) else { return nil }
        if enabled.contains(.readOnlyWebForEngineers), docsHosts.contains(host), let pack {
            let covered = Set(engineeringRoles.flatMap(pack.rolesCovering))
            if covered.contains(requesterRole) { return Decision(preset: .readOnlyWebForEngineers, scope: .role, duration: .always) }
        }
        if enabled.contains(.autoModeLowRisk), company.autonomy == .auto {
            return Decision(preset: .autoModeLowRisk, scope: .agent, duration: .sprint)
        }
        return nil
    }
}

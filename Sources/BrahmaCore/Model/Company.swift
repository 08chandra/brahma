import Foundation
import GRDB

public enum UsageMode: String, Codable, CaseIterable, Sendable { case low, balanced, max }

public enum CompanyStatus: String, Codable, Sendable { case running, paused }

public struct Company: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "company"

    public var id: String
    public var name: String
    public var slug: String
    public var goal: String
    public var workspacePath: String
    public var status: CompanyStatus
    public var usageMode: UsageMode
    public var priorityWeight: Int
    public var createdAt: Date
    public var packId: String = "software"
    public var packVersion: Int = 1
    /// Share of the weekly allowance kept for the owner; nil means the owner-wide setting (`1 - weeklyShare`).
    public var ownerReserve: Double? = nil
    /// How much the owner is asked (Task 11a); changing it never touches asks already waiting.
    public var autonomy: AutonomyPreset = .important
    /// The head of `refs/heads/main` the engine expects: recorded at ensureRepo, after each engine merge and when the owner
    /// accepts main. Claims and merges refuse while `main` is anything else (`Store.checkMain`).
    public var mainCommit: String? = nil
    /// The head the engine is about to move `main` to, written before the move. A crash between moving `main` and recording
    /// it leaves `main` here; the guard then accepts it and records it (`Store.checkMain`).
    public var pendingMainCommit: String? = nil
    /// Auto-approved items that landed in `main` (9c); every one is audited.
    public var autoMergeCount: Int = 0
    /// Risk-tiered auto-merge (9c) for this company: off until the owner switches it on (`Store.setAutoMergeSmall`, the CLI
    /// `brahma company set <company> auto-merge-small on`). The owner-wide switch (`Store.setAutoMerge`) must be on as well.
    public var autoMergeSmall: Bool = false
    /// The completion rule new sprints use unless the plan names one (the pack's `defaultCadence` at creation).
    public var cadence: CadenceKind = .sprint

    // Sandbox (5-lite, `"v5-sandbox"`). Changed only through `Store.updateSandbox`, which validates them; `updateCompany` keeps
    // the stored values.
    /// The company's default profile for every agent turn.
    public var permissionProfile: PermissionProfile = .sandboxed
    /// Role id → profile, overriding `permissionProfile` for that role.
    public var roleProfiles: [String: PermissionProfile] = [:]
    /// Owner-added Bash egress domains (on top of `CompanyNetwork.defaultRegistries`).
    public var allowedDomains: [String] = []
    /// Owner-added WebFetch domains (on top of the registries and `CompanyNetwork.defaultDocs`).
    public var webDomains: [String] = []
    /// Whether agent processes may listen on loopback (dev servers, test fixtures).
    public var allowLocalBinding: Bool = true
    /// Extra read-only toolchain paths (absolute or `~/…`), readable on every turn when they exist.
    public var toolchainReadPaths: [String] = []

    // Smoke check on main (Plan L, `"vL-release"`). Changed only through `Store.setSmokeCheck` and the engine's smoke runs;
    // `updateCompany` keeps the stored values.
    /// The command the engine runs on every new `main` (and before every deploy); nil: none, and deploys are blocked.
    public var smokeCheck: CheckSpec? = nil
    /// The ops agent who set `smokeCheck` (its runs carry that agent's `BRAHMA_AGENT_ID`).
    public var smokeCheckSetById: String? = nil
    /// The open system bug filed when main went red (`"Main is red at <sha7>: smoke check failed"`), until a green run.
    public var redBugItemId: String? = nil

    /// The profile a turn of an agent with this role runs under: the role's override, else the company's.
    public func profile(forRole role: String) -> PermissionProfile { roleProfiles[role] ?? permissionProfile }
}

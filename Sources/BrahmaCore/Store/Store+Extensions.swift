import Foundation
import GRDB

// The extension tables (migration `v5-extensions`, Task 5a): verified packages by tree hash, what each company has installed,
// the role and agent bindings (company overrides of the pack's suggestions), and the event log. Plus `forceFreshSession`,
// shared with Task 10.

/// A verified package, keyed by its tree hash. `publisher`, `sourceType`, `sourceUrl`, `sourceSha` and `treeSha256` are set by
/// the installer from the real fetch path, never read from the package.
public struct ExtensionPackage: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "extensionPackage"

    public var hash: String
    public var id: String
    public var version: String
    public var publisher: String
    public var sourceType: String
    public var sourceUrl: String?
    public var sourceSha: String?
    public var treeSha256: String
    /// The hash of the plugin parts alone (what is mounted in the workspace and rehashed on every mount).
    public var pluginTreeSha256: String
    public var fetchedAt: Date
    /// JSON `LintFacts`.
    public var lintFactsJSON: String?
    /// JSON `[String]`.
    public var noticesJSON: String?
    /// JSON `BrahmaSidecar` as parsed at propose (what mounts read; never the store copy on disk).
    public var sidecarJSON: String? = nil

    enum CodingKeys: String, CodingKey {
        case hash, id, version, publisher, sourceType, sourceUrl, sourceSha, treeSha256, pluginTreeSha256, fetchedAt
        case lintFactsJSON = "lintFacts", noticesJSON = "notices", sidecarJSON = "sidecar"
    }

    public var lintFacts: LintFacts? { lintFactsJSON.flatMap { try? JSONDecoder().decode(LintFacts.self, from: Data($0.utf8)) } }
    public var notices: [String] { noticesJSON.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [] }
    public var sidecar: BrahmaSidecar? { sidecarJSON.flatMap { try? JSONDecoder().decode(BrahmaSidecar.self, from: Data($0.utf8)) } }
}

/// What a company has installed: one row per extension id, pointing at the approved package hash.
public struct CompanyExtension: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "companyExtension"

    public var companyId: String
    public var id: String
    public var hash: String
    public var enabled: Bool = true
    public var installedAskId: String?
    public var installedAt: Date
    /// Set at approve from the approved ask's payload: this company's view of where its copy came from (B-I1). The package
    /// row is shared by hash and insert-only, so another company's proposal of the same bytes never relabels these.
    public var publisher: String = ""
    public var sourceType: String = ""
    public var sourceUrl: String? = nil
    public var sourceSha: String? = nil
}

/// A company override: `add` or `remove` of an extension for a role (`scope role`, `target <role>` or `*` for every role)
/// or one agent (`scope agent`, `target <agent id>`).
public struct ExtensionBinding: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "extensionBinding"

    public var companyId: String
    public var id: String
    public var scope: String
    public var target: String
    public var op: String
    public var createdAt: Date

    public init(companyId: String, id: String, scope: String, target: String, op: String, createdAt: Date) {
        self.companyId = companyId; self.id = id; self.scope = scope; self.target = target; self.op = op; self.createdAt = createdAt
    }
}

/// The extension log: staged, installed, declined, mountBlocked, tamper, try, removed.
public struct ExtensionEvent: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "extensionEvent"

    public var id: Int64?
    public var companyId: String
    public var extId: String
    public var kind: String
    public var detail: String?
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Store {
    public func installedExtensions(companyId: String) throws -> [CompanyExtension] {
        try writer.read { db in try CompanyExtension.filter(Column("companyId") == companyId).order(Column("id")).fetchAll(db) }
    }

    public func extensionPackage(hash: String) throws -> ExtensionPackage? {
        try writer.read { db in try ExtensionPackage.fetchOne(db, key: hash) }
    }

    public func extensionBindings(companyId: String) throws -> [ExtensionBinding] {
        try writer.read { db in try ExtensionBinding.filter(Column("companyId") == companyId).order(Column("createdAt"), Column.rowID).fetchAll(db) }
    }

    public func extensionEvents(companyId: String, extId: String? = nil, limit: Int = 500) throws -> [ExtensionEvent] {
        try writer.read { db in
            var q = ExtensionEvent.filter(Column("companyId") == companyId)
            if let extId { q = q.filter(Column("extId") == extId) }
            return try q.order(Column("id")).limit(limit).fetchAll(db)
        }
    }

    public func recordExtensionEvent(companyId: String, extId: String, kind: String, detail: String?, now: Date = Store.now()) throws {
        try writer.write { db in try Store.recordExtensionEvent(db, companyId: companyId, extId: extId, kind: kind, detail: detail, now: now) }
    }

    static func recordExtensionEvent(_ db: Database, companyId: String, extId: String, kind: String, detail: String?, now: Date) throws {
        var e = ExtensionEvent(companyId: companyId, extId: extId, kind: kind, detail: detail.map { Store.flat($0, max: 1000) }, createdAt: now)
        try e.insert(db)
    }

    /// The `bin/` names of a company's installed extensions (name → extension id), for the collision check.
    public func installedBins(companyId: String, paths: BrahmaPaths) throws -> [String: String] {
        var out: [String: String] = [:]
        for e in try installedExtensions(companyId: companyId) {
            let bin = paths.extensionsDir.store.appending(path: "\(e.id)/\(e.hash.prefix(12))/bin")
            for name in (try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? [] { out[name] = e.id }
        }
        return out
    }

    // MARK: Sessions

    /// Makes the agent's next turn start a fresh session (Task 5a, reused by Task 10). With an item, that item's `agentSession`
    /// row is deleted; without one, `agent.sessionId` is rotated and `sessionStarted` cleared. Either way the next turn's
    /// `freshSessionReason` is `reason` (`startTurn`/`beginTurn` apply it). The turn stays a counted work turn: only
    /// `sessionResetReason` (a failed "session not found" turn) takes a turn out of budgets, the watchdog and Continuity.
    public func forceFreshSession(agentId: String, itemId: String?, reason: String, now: Date = Store.now()) throws {
        try writer.write { db in try Store.forceFreshSession(db: db, agentId: agentId, itemId: itemId, reason: reason, now: now) }
    }

    static func forceFreshSession(db: Database, agentId: String, itemId: String?, reason: String, now: Date) throws {
        if let itemId {
            try db.execute(sql: "DELETE FROM agentSession WHERE agentId = ? AND itemId = ?", arguments: [agentId, itemId])
        } else {
            try resetSession(db: db, agentId: agentId, scope: .base)
        }
        try db.execute(sql: "UPDATE agent SET pendingSessionReset = ? WHERE id = ?", arguments: [Store.flat(reason, max: 200), agentId])
    }

    /// Moves a pending fresh-session reason onto `turnId` (the turn that starts the fresh session, as `freshSessionReason`) and
    /// clears it.
    @discardableResult
    public func applyPendingSessionReset(agentId: String, turnId: String) throws -> String? {
        try writer.write { db in try Store.applyPendingSessionReset(db: db, agentId: agentId, turnId: turnId) }
    }

    static func applyPendingSessionReset(db: Database, agentId: String, turnId: String) throws -> String? {
        guard let reason = try String.fetchOne(db, sql: "SELECT pendingSessionReset FROM agent WHERE id = ?", arguments: [agentId]) else { return nil }
        try db.execute(sql: "UPDATE turn SET freshSessionReason = ? WHERE id = ?", arguments: [reason, turnId])
        try db.execute(sql: "UPDATE agent SET pendingSessionReset = NULL WHERE id = ?", arguments: [agentId])
        return reason
    }
}

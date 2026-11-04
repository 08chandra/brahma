import Foundation
import GRDB

/// One commit of an agent's lab and the taint state of the turn that first recorded it (Task 10, read by Task 10b).
public struct LabCommit: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "labCommit"
    public var agentId: String
    public var sha: String
    public var turnId: String?
    public var tainted: Bool
    public var recordedAt: Date
}

extension Store {
    /// The scope key `pendingSessionResetScope` stores: '' for the base session, else the item id (B-M12).
    static func scopeKey(_ itemId: String?) -> String { itemId ?? "" }

    // MARK: Taint

    /// Marks the agent's session tainted, and its in-progress turn (the first source wins on the turn). A newly tainted session
    /// writes one activity event. The source is redacted; when the redactor is not loaded only its kind (`bash`, ...) is kept.
    public func markTainted(agentId: String, source: String, now: Date = Store.now()) throws {
        let shown: String
        if let redacted = try? redact(TaintPolicy.flat(source)) { shown = Store.flat(redacted, max: 120) }
        else { shown = String(source.split(separator: ":", maxSplits: 1).first ?? "outside content") }
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            try db.execute(sql: """
                UPDATE turn SET taintedAt = ?, taintSource = ? WHERE agentId = ? AND outcome = ? AND taintedAt IS NULL
                """, arguments: [now, shown, agentId, TurnOutcome.inProgress.rawValue])
            guard !agent.sessionTainted else { return }
            try db.execute(sql: "UPDATE agent SET sessionTainted = 1 WHERE id = ?", arguments: [agentId])
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: nil, kind: .error,
                              text: "@\(agent.name) read outside content (\(shown)); its high-risk tools are off until a fresh session",
                              createdAt: now).insert(db)
        }
    }

    /// The most recent taint source of the agent's turns, if any.
    public func latestTaintSource(agentId: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT taintSource FROM turn WHERE agentId = ? AND taintedAt IS NOT NULL ORDER BY taintedAt DESC, rowid DESC LIMIT 1
                """, arguments: [agentId])
        }
    }

    /// A high-risk call was refused under taint: the turn's end starts a fresh session.
    public func requestFreshSession(agentId: String) throws {
        try writer.write { db in try db.execute(sql: "UPDATE agent SET freshSessionRequested = 1 WHERE id = ?", arguments: [agentId]) }
    }

    /// At a turn's end: when a fresh session was requested, `forceFreshSession(reason: "tainted")` for the turn's scope (its
    /// next turn there carries the reason), every other session of the agent is reset too (the flag is agent-wide, so no
    /// session that may hold the outside content survives it), both flags are cleared and the flag file removed. Returns
    /// whether it reset.
    @discardableResult
    public func clearTaintIfRequested(agentId: String, scope: SessionScope, now: Date = Store.now()) throws -> Bool {
        let cleared = try writer.write { db -> Bool in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.freshSessionRequested else { return false }
            try Store.forceFreshSession(db: db, agentId: agentId, itemId: scope.itemId, reason: "tainted", now: now)
            try db.execute(sql: "DELETE FROM agentSession WHERE agentId = ?", arguments: [agentId])
            if scope.itemId != nil { try Store.resetSession(db: db, agentId: agentId, scope: .base) }
            try db.execute(sql: "UPDATE agent SET sessionTainted = 0, freshSessionRequested = 0 WHERE id = ?", arguments: [agentId])
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: nil, kind: .stateChanged,
                              text: "@\(agent.name)'s next turn starts a fresh session (tainted)", createdAt: now).insert(db)
            return true
        }
        if cleared, let home = dataHome { TaintFlag.remove(home: home, agentId: agentId) }
        return cleared
    }

    // MARK: Hook gates

    public func recordHookGate(_ gate: String, fingerprint: String, now: Date = Store.now()) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO hookGate (gate, cliFingerprint, passedAt) VALUES (?, ?, ?)",
                           arguments: [gate, fingerprint, now])
        }
    }

    public func hookGatePassed(_ gate: String, fingerprint: String) throws -> Bool {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hookGate WHERE gate = ? AND cliFingerprint = ?",
                             arguments: [gate, fingerprint]) ?? 0 > 0
        }
    }

    // MARK: Extensions

    /// The publisher this company installed `extId` from; nil when it is not installed.
    public func extensionPublisher(companyId: String, extId: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT publisher FROM companyExtension WHERE companyId = ? AND id = ?",
                                arguments: [companyId, extId])
        }.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Lab provenance

    /// Records lab commits not seen before with the turn's taint state; returns how many were new.
    @discardableResult
    public func recordLabCommits(agentId: String, turnId: String?, shas: [String], tainted: Bool, now: Date = Store.now()) throws -> Int {
        guard !shas.isEmpty else { return 0 }
        return try writer.write { db in
            var added = 0
            for sha in shas where sha.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO labCommit (agentId, sha, turnId, tainted, recordedAt) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [agentId, sha, turnId, tainted, now])
                added += db.changesCount
            }
            return added
        }
    }

    public func labCommits(agentId: String) throws -> [LabCommit] {
        try writer.read { db in try LabCommit.filter(Column("agentId") == agentId).order(Column.rowID).fetchAll(db) }
    }

    /// The commit recorded last (the next listing starts after it).
    public func lastLabCommit(agentId: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT sha FROM labCommit WHERE agentId = ? ORDER BY rowid DESC LIMIT 1", arguments: [agentId])
        }
    }
}

/// Lab provenance at a turn's end: the lab's new commits (every local branch, since the last recorded one) are listed through
/// the engine's `GitCommand` and recorded with the turn's taint state. A lab whose config the engine refuses, or that cannot be
/// listed, is not recorded: the agent's session is marked tainted instead, and an unrecorded lab commit counts as tainted (10b).
public enum LabProvenance {
    public enum Outcome: Equatable, Sendable {
        case none
        case recorded(Int)
        case refused(String)
    }

    /// Blocking (git).
    public static func record(store: Store, workspace: URL, handle: String, companyId: String, agentId: String, turnId: String?,
                              tainted: Bool, now: Date) -> Outcome {
        let root = workspace.resolvedForSandbox.path
        let lab = URL(fileURLWithPath: root).appending(path: ".brahma/labs/\(handle)", directoryHint: .isDirectory)
        let gitDir = lab.appending(path: ".git", directoryHint: .isDirectory)
        // The lab and its `.git` must be real directories down from the workspace (an agent could plant links there).
        if SandboxPath.linkedComponent(gitDir.path, under: root) != nil {
            return refuse(store: store, agentId: agentId, why: "the lab's .git is reached through a link", now: now)
        }
        guard SandboxPath.kind(gitDir.path) == .directory else { return .none }
        let git = store.gitWorkspace(root: lab, companyId: companyId)
        do {
            let shas = try git.labCommits(since: try store.lastLabCommit(agentId: agentId))
            return .recorded(try store.recordLabCommits(agentId: agentId, turnId: turnId, shas: shas, tainted: tainted, now: now))
        } catch {
            return refuse(store: store, agentId: agentId, why: "\(error)", now: now)
        }
    }

    private static func refuse(store: Store, agentId: String, why: String, now: Date) -> Outcome {
        try? store.markTainted(agentId: agentId, source: "lab-git: refused", now: now)
        return .refused(why)
    }
}

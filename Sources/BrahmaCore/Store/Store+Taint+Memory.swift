import Foundation
import GRDB

/// The two session-taint readers every Plan ML writer uses (ruling c): `currentTaint` for what an agent writes now, and
/// `taintAt` for what it wrote at some earlier time (auto-ingest of messages, comments, submit summaries and hand-offs).
///
/// A session starts fresh at a turn that carries `sessionResetReason` (the session was gone) or `freshSessionReason` (the
/// engine reset it on purpose: "tainted", "mounts changed"). Both clear what the session had read, so both end a taint.
extension Store {
    /// What the agent's session has read that taints what it writes now, or nil when it is clean:
    /// - its session is tainted (`agent.sessionTainted`): the newest source the session recorded (`agent.taintSources`), else the
    ///   newest non-nil `taintSource` among its turns since its last fresh-session turn, else `"session"`;
    /// - else, its taint flag file exists (a hook error, fail closed): `"hook-error"`;
    /// - else nil.
    /// An agent row that cannot be read counts as tainted (`"session"`).
    public func currentTaint(agentId: String, paths: BrahmaPaths) throws -> String? {
        try writer.read { db in try Store.currentTaint(db: db, agentId: agentId, home: paths.home) }
    }

    /// In-transaction `currentTaint`. `home` is the data home the flag file lives under (nil: no flag file to read).
    static func currentTaint(db: Database, agentId: String, home: URL?) throws -> String? {
        guard let agent = try Agent.fetchOne(db, key: agentId) else { return "session" }
        if agent.sessionTainted {
            let recorded = agent.taintSources.split(separator: "\n").map(String.init)
                .filter { !$0.isEmpty && $0 != "(more sources)" }
            if let newest = recorded.last { return newest }
            let since = try Date.fetchOne(db, sql: """
                SELECT startedAt FROM turn WHERE agentId = ? AND (sessionResetReason IS NOT NULL OR freshSessionReason IS NOT NULL)
                ORDER BY startedAt DESC, rowid DESC LIMIT 1
                """, arguments: [agentId])
            let source = try String.fetchOne(db, sql: """
                SELECT taintSource FROM turn WHERE agentId = ? AND taintSource IS NOT NULL AND startedAt >= ?
                ORDER BY COALESCE(taintedAt, startedAt) DESC, rowid DESC LIMIT 1
                """, arguments: [agentId, since ?? Date.distantPast])
            return source ?? "session"
        }
        if let home {
            // An id the flag path cannot name reads as flagged: fail closed.
            guard let flag = TaintFlag.url(home: home, agentId: agentId) else { return TaintPolicy.hookErrorSource }
            if TaintFlag.exists(flag) { return TaintPolicy.hookErrorSource }
        }
        return nil
    }

    /// Whether what the agent wrote at `at` came from a tainted session, and its source. Let T be the agent's newest turn with
    /// `taintedAt ≤ at`: the agent was tainted at `at` iff none of its turns that started a fresh session started in
    /// `(T.taintedAt, at]`. Returns `T.taintSource` (or `"outside content"` when it recorded none), else nil.
    public func taintAt(agentId: String, at: Date) throws -> String? {
        try writer.read { db in try TaintHistory.load(db: db, agentId: agentId).taint(at: at) }
    }

    /// In-transaction `taintAt`.
    static func taintAt(db: Database, agentId: String, at: Date) throws -> String? {
        try TaintHistory.load(db: db, agentId: agentId).taint(at: at)
    }
}

/// One agent's taint marks and fresh-session starts, loaded once and asked many times (auto-ingest reads it per row).
struct TaintHistory: Sendable {
    /// `(taintedAt, source)`, oldest first.
    var marks: [(at: Date, source: String)]
    /// When each fresh-session turn started, oldest first.
    var resets: [Date]

    static let clean = TaintHistory(marks: [], resets: [])

    static func load(db: Database, agentId: String) throws -> TaintHistory {
        let marks = try Row.fetchAll(db, sql: """
            SELECT taintedAt, taintSource FROM turn WHERE agentId = ? AND taintedAt IS NOT NULL ORDER BY taintedAt, rowid
            """, arguments: [agentId]).map { row -> (at: Date, source: String) in
            let source: String? = row["taintSource"]
            return (row["taintedAt"], source.flatMap { $0.isEmpty ? nil : $0 } ?? "outside content")
        }
        guard !marks.isEmpty else { return .clean }
        let resets = try Date.fetchAll(db, sql: """
            SELECT startedAt FROM turn WHERE agentId = ? AND (sessionResetReason IS NOT NULL OR freshSessionReason IS NOT NULL)
            ORDER BY startedAt
            """, arguments: [agentId])
        return TaintHistory(marks: marks, resets: resets)
    }

    func taint(at: Date) -> String? {
        guard let t = marks.last(where: { $0.at <= at }) else { return nil }
        if resets.contains(where: { $0 > t.at && $0 <= at }) { return nil }
        return t.source
    }
}

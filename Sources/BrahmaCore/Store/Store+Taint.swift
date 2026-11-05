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

    static let maxTaintSources = 50

    /// Whether what `actorId` writes now carries a tainted origin (I2): an agent whose session is tainted (row or flag file). An
    /// agent row that cannot be read counts as tainted; the owner and the engine never are.
    func writesTainted(db: Database, actorId: String) throws -> Bool {
        guard actorId != "owner", actorId != "system" else { return false }
        guard let agent = try Agent.fetchOne(db, key: actorId) else { return true }
        if agent.sessionTainted { return true }
        guard let home = dataHome, let flag = TaintFlag.url(home: home, agentId: actorId) else { return false }
        return TaintFlag.exists(flag)
    }

    /// The tainted-origin items a turn is about to read (its inbox, its work notices, its item's latest hand-off), as a source
    /// for `markTainted` (`relayed: ...`), or nil.
    public func relayedTaint(inbox: [(InboxItem, Message, Channel)], notices: [PendingNotice], handoff: Handoff?,
                             handles: [String: String]) -> String? {
        func who(_ id: String) -> String { "@" + (handles[id] ?? "unknown") }
        if let m = inbox.first(where: { $0.1.taintedOrigin }) { return "relayed: message from \(who(m.1.senderId))" }
        if let n = notices.first(where: { $0.event.taintedOrigin }) { return "relayed: \(n.itemKey) \(n.event.kind.rawValue) by \(who(n.event.actorId))" }
        if let h = handoff, h.taintedOrigin { return "relayed: hand-off by \(who(h.authorId))" }
        return nil
    }

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
            // The item the agent holds is now worked on by a tainted session (its worktree files, fix round 2). Not from a review
            // or audit turn: it works in a throwaway session, not on the items it holds.
            let kind = try String.fetchOne(db, sql: """
                SELECT kind FROM turn WHERE agentId = ? AND outcome = ? ORDER BY startedAt DESC, rowid DESC LIMIT 1
                """, arguments: [agentId, TurnOutcome.inProgress.rawValue])
            if kind != TurnKind.review.rawValue, kind != TurnKind.audit.rawValue { try Store.markHeldItemsTainted(db: db, agentId: agentId) }
            // S22: every source is kept for the session (a verdict is exempt only when all are the reviewed item's relay).
            var sources = agent.taintSources.split(separator: "\n").map(String.init)
            if !sources.contains(shown), sources.count < Store.maxTaintSources {
                sources.append(shown)
                try db.execute(sql: "UPDATE agent SET taintSources = ? WHERE id = ?", arguments: [sources.joined(separator: "\n"), agentId])
            } else if !sources.contains(shown) {
                // Too many to keep: a marker no verdict exemption accepts.
                try db.execute(sql: "UPDATE agent SET taintSources = taintSources || ? WHERE id = ? AND taintSources NOT LIKE '%(more sources)%'",
                               arguments: ["\n(more sources)", agentId])
            }
            guard !agent.sessionTainted else { return }
            try db.execute(sql: "UPDATE agent SET sessionTainted = 1 WHERE id = ?", arguments: [agentId])
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: nil, kind: .error,
                              text: "@\(agent.name) read outside content (\(shown)); its high-risk tools are off until a fresh session",
                              createdAt: now).insert(db)
        }
    }

    /// Marks every item the agent holds a lease on (worktree files written by a tainted session); done items are left alone.
    static func markHeldItemsTainted(db: Database, agentId: String) throws {
        try db.execute(sql: """
            UPDATE workItem SET taintedOrigin = 1 WHERE status <> 'done'
              AND id IN (SELECT itemId FROM \(WorkLease.databaseTableName) WHERE agentId = ?)
            """, arguments: [agentId])
    }

    /// At a holder turn's end (fix round 2): a session that is tainted now marks the items it holds, even when the taint came
    /// from an earlier turn of the same session.
    public func markHeldItemsIfTainted(agentId: String) throws {
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId) else { return }
            var tainted = agent.sessionTainted
            if !tainted, let home = dataHome, let flag = TaintFlag.url(home: home, agentId: agentId) { tainted = TaintFlag.exists(flag) }
            if tainted { try Store.markHeldItemsTainted(db: db, agentId: agentId) }
        }
    }

    /// A review or audit turn's throwaway session ended (S19): the agent's own sessions were clean before it, so its flags go
    /// back to clean. The flag file (a hook error) stays: fail closed.
    public func endThrowawaySessionTaint(agentId: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE agent SET sessionTainted = 0, freshSessionRequested = 0, taintSources = '' WHERE id = ?",
                           arguments: [agentId])
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
            try db.execute(sql: "UPDATE agent SET sessionTainted = 0, freshSessionRequested = 0, taintSources = '' WHERE id = ?",
                           arguments: [agentId])
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

    /// The publisher the taint rule sees for `extId` in this company: the one it was installed from; for a `company:`
    /// extension whose lab history is tainted (10b), `third-party:lab-tainted`; for a Brahma built-in that is not installed
    /// under that id, `brahma`; nil when it is not installed (which taints).
    public func extensionPublisher(companyId: String, extId: String) throws -> String? {
        let row = try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT publisher, sourceType FROM companyExtension WHERE companyId = ? AND id = ?",
                             arguments: [companyId, extId])
        }
        guard let row else { return BuiltinExtensions.ids.contains(extId) ? ExtensionPublisher.brahma : nil }
        let publisher: String = row["publisher"] ?? ""
        let sourceType: String = row["sourceType"] ?? ""
        guard !publisher.isEmpty else { return nil }
        return sourceType == ExtensionSourceKind.labTainted ? ExtensionSourceKind.taintedPublisher : publisher
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

    /// Whether a lab commit is tainted for 10b: recorded tainted, or not recorded at all (fail closed).
    public func labCommitTainted(agentId: String, sha: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT tainted FROM labCommit WHERE agentId = ? AND sha = ?", arguments: [agentId, sha]) ?? true
        }
    }

    /// The commit recorded last.
    public func lastLabCommit(agentId: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT sha FROM labCommit WHERE agentId = ? ORDER BY rowid DESC LIMIT 1", arguments: [agentId])
        }
    }
}

/// Lab provenance at a turn's end (fix round 1, I3): every commit object of the lab not recorded yet is recorded with the
/// session's taint state, whatever ref (or none) reaches it, so a commit a tainted session parks on a tag or leaves unreferenced
/// is recorded tainted before a clean turn can branch it. A lab whose `.git` is not a real directory, whose config the engine
/// refuses, or that cannot be listed is not recorded: the session is marked tainted and the owner alerted. An unrecorded lab
/// commit counts as tainted (`labCommitTainted`).
public enum LabProvenance {
    public enum Outcome: Equatable, Sendable {
        case none
        case recorded(Int)
        case refused(String)
    }

    public static let alertReason = "lab-provenance"

    /// Blocking (git).
    public static func record(store: Store, workspace: URL, handle: String, companyId: String, agentId: String, turnId: String?,
                              tainted: Bool, now: Date, limit: Int = 100_000, maxOutput: Int = 16 << 20) -> Outcome {
        let root = workspace.resolvedForSandbox.path
        let lab = URL(fileURLWithPath: root).appending(path: ".brahma/labs/\(handle)", directoryHint: .isDirectory)
        let gitDir = lab.appending(path: ".git", directoryHint: .isDirectory)
        // The lab and its `.git` must be real directories down from the workspace (an agent could plant links there).
        if SandboxPath.linkedComponent(gitDir.path, under: root) != nil {
            return refuse(store: store, companyId: companyId, agentId: agentId, handle: handle, why: "the lab's .git is reached through a link", now: now)
        }
        switch SandboxPath.kind(gitDir.path) {
        case .missing: return .none
        case .directory: break
        default:
            return refuse(store: store, companyId: companyId, agentId: agentId, handle: handle, why: "the lab's .git is not a directory", now: now)
        }
        // Object stores and history the lab borrows or rewrites are refused (I3-b): alternates, grafts, a shallow file, replace refs.
        // F2: a link anywhere under `.git` (it could steer git at another repository's objects or refs) is refused.
        if let link = firstLink(under: gitDir) {
            return refuse(store: store, companyId: companyId, agentId: agentId, handle: handle, why: "the lab's .git holds a link (\(link))", now: now)
        }
        for rel in ["objects/info/alternates", "objects/info/http-alternates", "info/grafts", "shallow", "commondir"]
        where SandboxPath.kind(gitDir.appending(path: rel).path) != .missing {
            return refuse(store: store, companyId: companyId, agentId: agentId, handle: handle, why: "the lab has \(rel)", now: now)
        }
        let replace = gitDir.appending(path: "refs/replace").path
        // Read without following a link (EngineFiles); a packed-refs that cannot be read whole is refused below.
        let packedData = try? EngineFiles.read(workspace: URL(fileURLWithPath: root), dir: ".brahma/labs/\(handle)/.git", name: "packed-refs",
                                               limit: 8 << 20)
        if packedData == nil, SandboxPath.kind(gitDir.appending(path: "packed-refs").path) != .missing {
            return refuse(store: store, companyId: companyId, agentId: agentId, handle: handle, why: "the lab's packed-refs cannot be read", now: now)
        }
        let packed = packedData.flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if SandboxPath.kind(replace) != .missing, !((try? FileManager.default.contentsOfDirectory(atPath: replace)) ?? ["?"]).isEmpty
            || packed.contains("refs/replace/") {
            return refuse(store: store, companyId: companyId, agentId: agentId, handle: handle, why: "the lab has replace refs", now: now)
        }
        let git = store.gitWorkspace(root: lab, companyId: companyId)
        do {
            let shas = try git.labCommits(limit: limit, maxOutput: maxOutput)
            return .recorded(try store.recordLabCommits(agentId: agentId, turnId: turnId, shas: shas, tainted: tainted, now: now))
        } catch {
            return refuse(store: store, companyId: companyId, agentId: agentId, handle: handle, why: "\(error)", now: now)
        }
    }

    /// The first symbolic link under `dir` (relative path), never following one. An unreadable entry counts as a link.
    /// Fails closed (S24): any error while walking (an unreadable directory, say) returns a marker.
    static func firstLink(under dir: URL, limit: Int = 200_000) -> String? {
        final class Failed: @unchecked Sendable { var path: String? }
        let failed = Failed()
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [],
                                                     errorHandler: { url, _ in failed.path = url.path; return false }) else { return "?" }
        var n = 0
        for case let url as URL in e {
            n += 1
            if n > limit { return "too many entries" }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink != false { return String(url.path.dropFirst(dir.path.count)) }
            if failed.path != nil { break }
        }
        if let path = failed.path { return "unreadable: " + String(path.dropFirst(dir.path.count)) }
        return nil
    }

    private static func refuse(store: Store, companyId: String, agentId: String, handle: String, why: String, now: Date) -> Outcome {
        try? store.markTainted(agentId: agentId, source: "lab-git: refused", now: now)
        try? EngineAlerts.raise(store: store, text: "@\(handle)'s lab could not be read for provenance (\(Store.flat(why, max: 200))); "
                                + "its session is treated as tainted.", now: now, reason: alertReason, companyId: companyId)
        return .refused(why)
    }
}

import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Taint as data (design §4.3). A session that read outside content stamps what it produces — the commits of its holder turn,
/// the files it snapshots, the refs it pins, the messages it posts — and every reader of those is tainted in turn when it
/// opens them (`openRef`). "Now" is ML's `Store.currentTaint`, a past moment `Store.taintAt`: taint is per session and
/// survives resumed turns, so no turn's own `taintedAt` decides it. C has no taint reader of its own.
extension Store {
    /// The reason a `.brahma/…` file at a rev other than `main`'s recorded head is tainted (ruling 8).
    static let brahmaRevReason = "a .brahma file outside main's recorded head"

    /// The reason a `.brahma/…` file on disk that no item or hand-off accounts for is tainted (ruling 9).
    static let unplacedBrahmaReason = "a .brahma file no item accounts for"

    /// The reason an artifact whose source can't be shown to be clean is tainted (ruling 16).
    static let artifactSourceReason = "an artifact whose source can't be shown to be clean"

    /// The source recorded when a taint check or record could not be made and nothing better is known (fail closed, ruling 11).
    static let taintCheckFailedSource = "a taint check that failed"

    /// The reason a session's taint gives what it produced.
    static func sessionReason(_ source: String) -> String { "from a session that read \(source)" }

    // MARK: Tainted commits

    /// Records `git rev-list <headBefore>..<headAfter>` of a tainted holder turn as tainted commits of the item (an existing
    /// row is kept as it is). The caller has read the session's taint (`source`) before any fresh-session reset.
    public func recordTaintedCommits(companyId: String, itemId: String, agentId: String, turnId: String?, headBefore: String,
                                     headAfter: String, source: String, git: SafeGit, now: Date) throws {
        if refHooks.failTaintRecords { throw WorkError.conflict("injected: the taint record could not be written") }
        guard headBefore != headAfter else { return }
        let shas = try git.revList(headBefore, headAfter)
        guard !shas.isEmpty else { return }
        try writer.write { db in
            guard try WorkItem.fetchOne(db, sql: "SELECT * FROM workItem WHERE companyId = ? AND id = ?", arguments: [companyId, itemId]) != nil
            else { throw WorkError.notFound("no such work item") }
            for sha in shas {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO taintedCommit (companyId, sha, itemId, agentId, turnId, source, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [companyId, sha, itemId, agentId, turnId, Store.flat(source, max: 200), now])
            }
        }
    }

    /// Stops the item's tainted commits from tainting what holds them: `by` is `"review"` (merged through the review gate) or
    /// `"owner"` (the owner vouched for the item).
    public func clearTaintedCommits(itemId: String, by: String, now: Date) throws {
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
            try Self.clearTaintedCommits(db: db, item: item, by: by, now: now)
        }
    }

    static func clearTaintedCommits(db: Database, item: WorkItem, by: String, now: Date) throws {
        try db.execute(sql: """
            UPDATE taintedCommit SET clearedBy = ?, clearedAt = ? WHERE companyId = ? AND itemId = ? AND clearedBy IS NULL
            """, arguments: [by, now, item.companyId, item.id])
    }

    /// The owner vouches for an item's changes: its tainted commits are cleared (`clearedBy = "owner"`) and the activity log
    /// says so. Owner callers only (the app and the owner CLI).
    public func vouchItem(itemId: String, now: Date, owner: OwnerPrincipal) throws {
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
            try Self.clearTaintedCommits(db: db, item: item, by: "owner", now: now)
            try ActivityEvent(companyId: item.companyId, agentId: nil, turnId: nil, kind: .access,
                              text: "Owner vouched for \(item.key)'s changes", createdAt: now).insert(db)
        }
    }

    /// Ruling 22 (P2 R5-1): the owner vouches for what a restore over an unreadable database could not place in the company.
    /// Final wave B1, controller Ruling 28: the vouch binds to the exact epoch ids the owner was shown (the Inbox row's, or the
    /// CLI's `--epoch <id>` / `--all` over the epochs it listed): only those epochs, and only those still open, are cleared, with
    /// the tainted-commit rows each one recorded (`clearedBy = "owner"`; each clearing gets its `taintOrder` sequence from the
    /// triggers); an epoch opened since (another restore) stays open, and so do its rows. An id that is not an open epoch of
    /// this company clears nothing. An item's own rows (a turn's, a marker) are not cleared: those clear through the review
    /// gate or `vouchItem`. Owner callers only (the owner principal; refused in an agent process). Returns how many commit rows
    /// and epochs it cleared (none: nothing was left, and nothing is logged).
    @discardableResult
    public func vouchRestoredCommits(companyId: String, epochIds: [String], now: Date, owner: OwnerPrincipal) throws -> (commits: Int, epochs: Int) {
        try ProcessRole.refuseInAgentProcess()
        _ = try requireOwner(owner)
        let ids = Array(Set(epochIds))
        guard !ids.isEmpty else { return (0, 0) }
        return try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw WorkError.notFound("no such company") }
            let marks = ids.map { _ in "?" }.joined(separator: ",")
            let open = try String.fetchAll(db, sql: """
                SELECT id FROM restoreEpoch WHERE companyId = ? AND clearedBy IS NULL AND id IN (\(marks))
                """, arguments: StatementArguments([companyId] + ids))
            guard !open.isEmpty else { return (0, 0) }
            let openMarks = open.map { _ in "?" }.joined(separator: ",")
            try db.execute(sql: """
                UPDATE taintedCommit SET clearedBy = 'owner', clearedAt = ?
                WHERE companyId = ? AND restoreEpoch IN (\(openMarks)) AND clearedBy IS NULL
                """, arguments: StatementArguments([now, companyId] as [any DatabaseValueConvertible] + open))
            let commits = db.changesCount
            try db.execute(sql: "UPDATE restoreEpoch SET clearedBy = 'owner', clearedAt = ? WHERE companyId = ? AND id IN (\(openMarks)) AND clearedBy IS NULL",
                           arguments: StatementArguments([now, companyId] as [any DatabaseValueConvertible] + open))
            let epochs = db.changesCount
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .access,
                              text: "Owner vouched for the commits a restore could not place (\(commits))", createdAt: now).insert(db)
            return (commits, epochs)
        }
    }

    /// The company's open restore epochs, oldest first: what the restore vouch lists and binds to (Ruling 28).
    public func openRestoreEpochList(companyId: String) throws -> [RestoreEpoch] {
        try writer.read { db in
            guard try db.tableExists("restoreEpoch") else { return [] }
            return try RestoreEpoch.fetchAll(db, sql: "SELECT * FROM restoreEpoch WHERE companyId = ? AND clearedBy IS NULL ORDER BY createdAt, rowid",
                                             arguments: [companyId])
        }
    }

    /// Whether the company has a restore epoch the owner has not cleared (the restore alert then offers the vouch).
    public func hasOpenRestoreEpoch(companyId: String) throws -> Bool {
        try writer.read { db in
            try db.tableExists("restoreEpoch")
                && (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM restoreEpoch WHERE companyId = ? AND clearedBy IS NULL",
                                     arguments: [companyId]) ?? 0) > 0
        }
    }

    /// The `subjectId` of a company's restore alert (`RestoreCarry.raiseRestoreAlert`), the ask the Inbox offers the vouch on.
    public static var restoreAlertSubject: String { engineAlertKey(RestoreCarry.restoreAlertReason) }

    // MARK: A ref's taint

    /// Whether `ref` carries outside content, and why (design §4.3). Fail closed: a history that can't be read is tainted
    /// whenever the company has an uncleared tainted commit that could be in it.
    /// - a pinned ref made by (or of `@worktree` content held by) a tainted session (`params["taint"]`, set by `pinRef`):
    ///   tainted, whatever it names;
    /// - a resource: its `tainted`; a message or thread: `fromTaintedSession` (or the older `taintedOrigin`); an item, kb page
    ///   or memory entry: its own flag;
    /// - a commit: an uncleared tainted-commit row with that sha (a short sha matches every row it prefixes);
    /// - a committed diff: any uncleared row in `rev-list <merge-base>..<head>`; a file on an item branch: any in
    ///   `log <merge-base>..<rev> -- <path>`; and either one while the item has uncleared rows of which none is on its branch
    ///   any more (a rewrite nothing carried the taint through), until the review gate or the owner clears them. The engine's
    ///   own rebase carries the rows to the new commits (`carryTaintThroughRebase`);
    /// - a key-less file at a rev: any uncleared row in `log <merge-base main>..<rev> -- <path>` (so a tainted commit is not
    ///   laundered by naming it without its item); `main`'s head is clean (what reached it went through the review gate); a
    ///   `.brahma/…` path at any rev but `main`'s engine-recorded head (`company.mainCommit`) is tainted, a pinned blob of one
    ///   included (ruling 8);
    /// - after a restore over a database that could not be read (Ruling 22, `RestoreEpoch`), until the owner vouches
    ///   (`vouchRestoredCommits`), under EVERY such epoch, listed or not (Ruling 24: a listing can't see a dangling or
    ///   reflog-only commit that is made reachable later, so it only attributes commits to items and never makes one clean):
    ///   a commit ref not in the history of the epoch's `main` (`mainCommit`, the snapshot's record) is tainted; a file or a
    ///   diff whose range from the epoch's `main` to its tip is not empty is tainted (Ruling 25: never from live `main`, which
    ///   moves past a post-restore commit once it is merged): a file at a rev, an item's file or diff, a rev-less key-less file
    ///   (tip: `main`'s head), a `.brahma/…` file at `main`'s recorded head, and a main-checkout artifact's source (tip: the
    ///   recorded head). No `mainCommit`, or any git error: tainted;
    /// - `@worktree` content: the lease holder's session is tainted now, or a tainted session held the item (5-lite's sticky
    ///   `taintedOrigin`), or (a file) the branch history it holds is tainted; a pinned worktree diff: its snapshot's.
    public func refTaint(_ ref: WorkRef, companyId: String) throws -> (tainted: Bool, reason: String?) {
        if let source = ref.params["taint"] { return (true, Self.sessionReason(source)) }
        switch ref.kind {
        case .resource:
            guard let n = Int(ref.id), let r = try resource(companyId: companyId, number: n) else { return (false, nil) }
            return r.tainted ? (true, r.taintReason ?? "outside content") : (false, nil)
        case .message, .thread:
            guard let m = try writer.read({ db in
                try Message.fetchOne(db, sql: "SELECT * FROM message WHERE companyId = ? AND id = ?", arguments: [companyId, ref.id])
            }) else { return (false, nil) }
            if m.fromTaintedSession || m.taintedOrigin { return (true, Self.sessionReason(m.taintSource ?? "outside content")) }
            return (false, nil)
        case .artifact:
            guard let n = Int(ref.id), let a = try artifact(companyId: companyId, number: n) else { return (false, nil) }
            return artifactTaint(a)
        case .item:
            guard let item = try writer.read({ db in try RefAccess.item(db, companyId, ref.id) }) else { return (false, nil) }
            return item.taintedOrigin ? (true, "outside content") : (false, nil)
        case .kb:
            guard let page = try writer.read({ db in try Store.kbPage(db: db, companyId: companyId, path: ref.id) }) else { return (false, nil) }
            return page.tainted ? (true, page.taintReason ?? "outside content") : (false, nil)
        case .memory:
            guard let n = Int(ref.id), let entry = try writer.read({ db in
                try MemoryEntry.fetchOne(db, sql: "SELECT * FROM memoryEntry WHERE companyId = ? AND number = ?", arguments: [companyId, n])
            }) else { return (false, nil) }
            return entry.tainted ? (true, entry.taintReason ?? "outside content") : (false, nil)
        case .commit:
            return try commitRowSource(companyId: companyId, sha: ref.rev ?? ref.id).map { (true, Self.sessionReason($0)) } ?? (false, nil)
        case .file, .diff:
            // C5b: `diff:<sha>..<sha>` names no item: tainted when any uncleared tainted commit lies in its range (or the
            // range can't be listed). `wt:@handle` is resolved to its item diff before it reaches here; unresolved, it is clean
            // only in name (nothing opens for it).
            if ref.kind == .diff, ref.id.isEmpty {
                guard ref.params["wt"] == nil, let from = ref.params["from"], let to = ref.params["to"] else { return (false, nil) }
                return try rangeSource(companyId: companyId, from: from, to: to).map { (true, Self.sessionReason($0)) } ?? (false, nil)
            }
            if ref.kind == .file, ref.itemKey == nil {
                guard let rev = ref.rev else {
                    if ref.id.hasPrefix(".brahma/") { return try onDiskBrahmaTaint(ref, companyId: companyId) }
                    // `main`'s head went through the review gate, but not past a restore epoch's `main` (Ruling 25).
                    return try restoreEpochSource(companyId: companyId, tip: nil, path: ref.id).map { (true, Self.sessionReason($0)) } ?? (false, nil)
                }
                // Ruling 8: a `.brahma/…` path at any rev but `main`'s engine-recorded head is tainted (it can be force-added on
                // an item branch, and a pinned blob of a live `.brahma` file carries no record of who wrote it).
                if ref.id.hasPrefix(".brahma/") {
                    let main = try company(id: companyId)?.mainCommit
                    guard let main, rev == main else { return (true, Self.brahmaRevReason) }
                    return try restoreEpochSource(companyId: companyId, tip: main, path: ref.id).map { (true, Self.sessionReason($0)) } ?? (false, nil)
                }
                return try keylessSource(ref, rev: rev, companyId: companyId).map { (true, Self.sessionReason($0)) } ?? (false, nil)
            }
            guard let key = ref.kind == .diff ? ref.id : ref.itemKey,
                  let item = try writer.read({ db in try RefAccess.item(db, companyId, key) }) else { return (false, nil) }
            if ref.isWorktree {
                if let snapshot = ref.params["snapshot"] {
                    let row = try writer.read { db in
                        try RefSnapshot.fetchOne(db, sql: "SELECT * FROM refSnapshot WHERE companyId = ? AND id = ?", arguments: [companyId, snapshot])
                    }
                    // A snapshot row that is gone reads as tainted (fail closed); it opens nothing anyway.
                    return row.map { $0.tainted ? (true, $0.taintReason ?? "outside content") : (false, nil) } ?? (true, "outside content")
                }
                if ref.rev != nil { return (false, nil) }      // a pinned blob: its taint was fixed at pin time (`params["taint"]`)
            }
            return try contentSource(ref, item: item).map { (true, Self.sessionReason($0)) } ?? (false, nil)
        default:
            return (false, nil)
        }
    }

    /// Ruling 9: a rev-less `.brahma/…` file read from disk takes the taint of the item it belongs to.
    /// - `progress/<KEY>.md`: the item's holder's session now, or 5-lite's sticky mark (a tainted session held it);
    /// - `handoffs/<KEY>/…`: the hand-off row's own mark (its writer's session when it was written), or the item's as above;
    ///   a file no hand-off row names can't be attributed: tainted;
    /// - `resources/company/…`: clean (the engine mirrors only untainted, unflagged owner resources there);
    /// - `artifacts/<number>-<slug>/…`: the taint of this company's artifact row whose `storedPath` is that folder
    ///   (`artifactTaint`: the row's flag and its source's provenance; the folder is engine-written, write-denied to every
    ///   turn); a folder no row names (a leftover, a staging copy, another company's), a file beside the folders, or a lookup
    ///   that fails: tainted;
    /// - an agent's lab or notes (private: only it and the owner read them): its own place, not judged here;
    /// - anything else (an unknown item): it can't be determined, so tainted (fail closed).
    private func onDiskBrahmaTaint(_ ref: WorkRef, companyId: String) throws -> (tainted: Bool, reason: String?) {
        let unknown = (true, Optional(Self.unplacedBrahmaReason))
        if RefAccess.privatePlace(ref) != nil { return (false, nil) }
        let parts = ref.id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return unknown }
        func item(_ key: String) throws -> WorkItem? { try writer.read { db in try RefAccess.item(db, companyId, key) } }
        func itemSource(_ item: WorkItem) throws -> String? {
            try holderSource(item: item) ?? (item.taintedOrigin ? "outside content" : nil)
        }
        switch parts[1] {
        case "resources" where parts[2] == "company":
            return (false, nil)
        case "artifacts":
            guard parts.count >= 4, parts.dropFirst(2).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  !parts[2].hasPrefix(".") else { return unknown }
            let folder = ".brahma/artifacts/\(parts[2])"
            let row: Artifact?
            do {
                row = try writer.read { db in
                    try Artifact.fetchOne(db, sql: "SELECT * FROM artifact WHERE companyId = ? AND storedPath = ?", arguments: [companyId, folder])
                }
            } catch {
                return unknown
            }
            guard let row else { return unknown }
            return artifactTaint(row)
        case "progress" where parts.count == 3 && parts[2].hasSuffix(".md"):
            guard let item = try item(String(parts[2].dropLast(3))) else { return unknown }
            return try itemSource(item).map { (true, Self.sessionReason($0)) } ?? (false, nil)
        case "handoffs":
            guard let item = try item(parts[2]) else { return unknown }
            let handoffs = try handoffs(itemId: item.id).filter { $0.companyId == companyId && $0.path.hasSuffix("/" + ref.id) }
            guard let handoff = handoffs.last else { return unknown }
            if handoff.taintedOrigin { return (true, Self.sessionReason("outside content")) }
            return try itemSource(item).map { (true, Self.sessionReason($0)) } ?? (false, nil)
        default:
            return unknown
        }
    }

    // MARK: Artifacts (ruling 16)

    /// Ruling 16: an artifact's taint, read now. 4a's `tainted` records only the publishing session, so a clean session could
    /// otherwise publish bytes a tainted one wrote. It is tainted when any of these holds:
    /// - its row is tainted (4a's flag and reason);
    /// - `itemId` names an item of this company that is tainted (its holder's session now, 5-lite's sticky mark, or an
    ///   uncleared tainted commit on its branch). `itemId` is the publisher's word: it only ever adds taint;
    /// - `sourcePath` (4a's `realpath` at publish) is not a clean path under the workspace's real path (empty, relative,
    ///   outside, the workspace itself, in `.git`, in `.brahma` outside a worktree): no usable provenance;
    /// - it is under `.brahma/wt/<KEY>/`: that item is tainted now (as above), or was when the artifact was published, or that
    ///   can't be determined (`itemTaintAtPublish`, ruling 17); an unknown item: tainted;
    /// - it is in the main checkout: unless main's engine-recorded head (`company.mainCommit`) holds it (a file, or a folder),
    ///   its key-less history there is clean (ruling 1), and every file of the copy is main's committed blob at the matching
    ///   path (git's blob id of the copy's bytes, read through SafeFS, at most `SafeGit.maxBinaryBytes` in all);
    /// - any lookup or check fails.
    /// The copy's bytes are hashed here, never shown: the reader is marked (`openRef`) before any byte reaches it. Never throws.
    func artifactTaint(_ a: Artifact) -> (tainted: Bool, reason: String?) {
        if a.tainted { return (true, a.taintReason ?? "outside content") }
        let unverified = (true, Optional(Self.artifactSourceReason))
        do {
            if let itemId = a.itemId, let item = try writer.read({ db in
                try WorkItem.fetchOne(db, sql: "SELECT * FROM workItem WHERE companyId = ? AND id = ?", arguments: [a.companyId, itemId])
            }), let source = try itemTaintSource(item) {
                return (true, Self.sessionReason(source))
            }
            guard let company = try company(id: a.companyId), let root = Self.realPath(company.workspacePath),
                  a.sourcePath.hasPrefix(root + "/") else { return unverified }
            let rel = String(a.sourcePath.dropFirst(root.count + 1))
            let parts = rel.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else { return unverified }
            if parts[0].lowercased() == ".brahma" {
                guard parts.count >= 4, parts[1] == "wt", let item = try writer.read({ db in try RefAccess.item(db, a.companyId, parts[2]) })
                else { return unverified }
                if let source = try itemTaintSource(item) { return (true, Self.sessionReason(source)) }
                return try itemTaintAtPublish(item, artifact: a)
            }
            return try mainSourceTaint(a, rel: rel, company: company)
        } catch {
            return unverified
        }
    }

    /// The source of an item's taint: its lease holder's session now, 5-lite's sticky mark, or an uncleared tainted commit on its
    /// branch (or none of its commits provably clean); nil when clean.
    private func itemTaintSource(_ item: WorkItem) throws -> String? {
        if let source = try holderSource(item: item) { return source }
        if item.taintedOrigin { return "outside content" }
        return try commitSource(WorkRef(kind: .diff, id: item.key), item: item)
    }

    /// Ruling 17: whether `item` was tainted when `artifact` (published from its worktree) was published, from what the store
    /// keeps. Tainted-commit rows are never deleted (a clearing sets `clearedBy`/`clearedAt`), and Ruling 19 orders the publish
    /// against each clearing and each status change by the database's monotonic `taintOrder` sequence, written by triggers in
    /// the same transaction as each; wall-clock times never order them. A row counts as cleared before the publish only when
    /// it has `clearedBy`, `clearedAt` and a clearing sequence below the publish's; every other row was uncleared then.
    /// - Tainted (with the row's source) by a row of the item uncleared then: a row recorded after the publish may still name
    ///   an earlier commit (taint is recorded at turn end and release);
    /// - tainted (R3-1) when any company row uncleared then names a commit the item's branch holds since it left `main`, or an
    ///   orphaned item's commit on it: `commitSource` over those rows, as the current check does over today's;
    /// - undeterminable, so tainted (`artifactSourceReason`): no publish sequence (published before the order was kept, or
    ///   lost); a row marked cleared without a time; a company row with no item uncleared then; the item done now, or with a
    ///   status change or merge after the publish (5-lite's sticky mark has no history and may drop when an item reaches done,
    ///   so a clear mark now says nothing then); any lookup that fails (the caller's catch).
    /// Clean otherwise. No other clearing path exists (a content match against a reviewed blob is Plan S's).
    private func itemTaintAtPublish(_ item: WorkItem, artifact: Artifact) throws -> (tainted: Bool, reason: String?) {
        let unverified = (true, Optional(Self.artifactSourceReason))
        let companyId = item.companyId
        let read = try writer.read { db -> (rows: [TaintedCommit], current: WorkItem?, publish: Int64?, clears: [String: Int64],
                                              statusAfter: Int, epochs: [RestoreEpoch]) in
            let rows = try TaintedCommit.fetchAll(db, sql: """
                SELECT * FROM taintedCommit WHERE companyId = ? ORDER BY createdAt DESC, rowid DESC
                """, arguments: [companyId])
            let current = try WorkItem.fetchOne(db, sql: "SELECT * FROM workItem WHERE companyId = ? AND id = ?",
                                                arguments: [companyId, item.id])
            let publish = try Int64.fetchOne(db, sql: """
                SELECT MIN(seq) FROM taintOrder WHERE companyId = ? AND kind = 'publish' AND subject = ?
                """, arguments: [companyId, artifact.id])
            var clears: [String: Int64] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT subject, MAX(seq) AS seq FROM taintOrder WHERE companyId = ? AND kind = 'clear' GROUP BY subject
                """, arguments: [companyId]) {
                clears[row["subject"]] = row["seq"]
            }
            let statusAfter = try publish.map { seq in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM taintOrder WHERE companyId = ? AND kind = 'status' AND subject = ? AND seq > ?
                    """, arguments: [companyId, item.id, seq]) ?? 0
            } ?? 0
            // Every epoch, listed or not (Ruling 24).
            let epochs = try RestoreEpoch.fetchAll(db, sql: "SELECT * FROM restoreEpoch WHERE companyId = ? ORDER BY rowid",
                                                   arguments: [companyId])
            return (rows, current, publish, clears, statusAfter, epochs)
        }
        guard let publish = read.publish else { return unverified }
        // The restore epochs not cleared before the publish (R5-1, Ruling 24), by the same rule as the rows.
        let epochsAtPublish = read.epochs.filter { e in
            guard e.clearedBy != nil, e.clearedAt != nil, let cleared = read.clears[e.orderSubject] else { return true }
            return cleared > publish
        }
        // The rows uncleared at the publish.
        let atPublish = read.rows.filter { row in
            guard row.clearedBy != nil, row.clearedAt != nil, let cleared = read.clears[row.sha] else { return true }
            return cleared > publish
        }
        for row in atPublish where row.itemId == item.id || row.itemId == nil {
            if row.itemId == nil || (row.clearedBy != nil && row.clearedAt == nil) { return unverified }
            return (true, Self.sessionReason(row.source))
        }
        guard let current = read.current, current.status != .done, read.statusAfter == 0 else { return unverified }
        if let source = try commitSource(WorkRef(kind: .diff, id: item.key), item: item, rows: atPublish, epochs: epochsAtPublish) {
            return (true, Self.sessionReason(source))
        }
        return (false, nil)
    }

    /// Ruling 16 for a source in the main checkout (`rel`, workspace-relative): see `artifactTaint`.
    private func mainSourceTaint(_ a: Artifact, rel: String, company: Company) throws -> (tainted: Bool, reason: String?) {
        let unverified = (true, Optional(Self.artifactSourceReason))
        guard let main = company.mainCommit, let folder = RefAccess.artifactFolder(a) else { return unverified }
        func history(_ path: String) throws -> String? {
            try keylessSource(WorkRef(kind: .file, id: path, rev: main), rev: main, companyId: company.id)
        }
        if let source = try history(rel) { return (true, Self.sessionReason(source)) }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let git = try refGit(workspace)
        let listed = try git.lsTree(rev: main, path: rel, cap: ArtifactPolicy.maxFiles)
        guard !listed.truncated, !listed.entries.isEmpty else { return unverified }
        var expected = Dictionary(listed.entries.map { ($0.path, $0.sha) }, uniquingKeysWith: { first, _ in first })
        // A file is copied under its own name (with, for glTF, bare-name siblings from its folder); a folder as it is.
        let isFile = listed.entries.count == 1 && listed.entries[0].path == rel
        if isFile {
            guard a.entryFile == (rel as NSString).lastPathComponent else { return unverified }
        } else {
            guard listed.entries.allSatisfy({ $0.path.hasPrefix(rel + "/") }) else { return unverified }
        }
        let base = isFile ? (rel as NSString).deletingLastPathComponent : rel
        let stored = try ArtifactCopyListing.files(workspace: workspace, folder: folder)
        guard !stored.isEmpty else { return unverified }
        let fs = try SafeFS(workspace: workspace, ownHandle: nil)
        let sha256 = main.utf8.count == 64
        var budget = SafeGit.maxBinaryBytes
        for name in stored {
            let path = base.isEmpty ? name : "\(base)/\(name)"
            if expected[path] == nil {
                // A glTF sibling beside a file: it must be on main too, with clean history. A folder's copy holds nothing else.
                guard isFile, !name.contains("/") else { return unverified }
                let one = try git.lsTree(rev: main, path: path, cap: 1)
                guard !one.truncated, one.entries.count == 1, one.entries[0].path == path else { return unverified }
                if let source = try history(path) { return (true, Self.sessionReason(source)) }
                expected[path] = one.entries[0].sha
            }
            guard budget > 0 else { return unverified }
            let file = try fs.open(workspacePath: "\(a.storedPath)/\(name)", maxBytes: budget)
            budget -= file.size
            guard try SafeGit.blobId(of: file, sha256: sha256) == expected[path] else { return unverified }
        }
        return (false, nil)
    }

    /// The source of the taint of an item-branch file or diff (committed or `@worktree`), or nil when it is clean.
    func contentSource(_ ref: WorkRef, item: WorkItem) throws -> String? {
        if ref.isWorktree {
            if let source = try holderSource(item: item) { return source }
            if item.taintedOrigin { return "outside content" }
            if ref.kind == .file {
                var committed = ref
                committed.branch = "item/\(item.key)"
                committed.rev = nil
                return try commitSource(committed, item: item)
            }
            // Fix round 1 (N-1): a live diff shows the branch's commits from its base on (vs main: the merge base; `?vs=check`,
            // `@r<n>..worktree`: a run's commit), so their taint rides on it; vs head it shows uncommitted work only.
            return try compareRangeSource(ref, item: item)
        }
        // Fix round 1 (N-1b): `@r<n>..r<m>` is judged over exactly the pair it shows, both ways.
        if ref.params["from"] != nil, ref.params["to"] != nil { return try compareRangeSource(ref, item: item) }
        return try commitSource(ref, item: item)
    }

    /// The taint of the commits a compare shows: `commitSource` (the branch from its merge base, restore epochs included) when
    /// the base is the merge base with main, else the symmetric range between the compare's base and its target (or the branch
    /// head for the live worktree). A base that can't be resolved reads as tainted.
    private func compareRangeSource(_ ref: WorkRef, item: WorkItem) throws -> String? {
        // A live diff ref that names no compare can't be judged: tainted (fail closed).
        guard let compare = CompareMode(ref: ref) else { return "outside content" }
        guard let company = try company(id: item.companyId) else { return "outside content" }
        let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        let bases: (base: String, target: String?)
        do { bases = try changesBases(companyId: item.companyId, item: item, compare: compare, git: git) } catch { return "outside content" }
        let target: String
        do { target = try bases.target ?? git.head("item/\(item.key)") } catch { return "outside content" }
        let rows = try unclearedCommits(companyId: item.companyId)
        // Fix round 2 (R1-2): both trees are displayed (context and `-` lines come from the base), so every commit either side
        // holds since its merge base with main counts, plus the pair's symmetric range. Fix round 3 (Ruling C5b-7): the commits
        // of every orphaned item (a taint record a rewrite left behind) count in that set too, and a lookup that fails is tainted.
        let orphans: [OrphanedItem]
        do { orphans = Array(try orphanedItems(companyId: item.companyId, rows: rows).values) } catch {
            return rows.first { $0.itemId == item.id }?.source ?? rows.first?.source ?? Self.taintCheckFailedSource
        }
        let companyId = item.companyId
        if let source = try Self.displayedRangeSource(git, bases.base, target, rows: rows, orphans: orphans,
                                                      recorded: { try self.recordedCommitShas(companyId: companyId, shas: $0) }) { return source }
        // Never clean on a narrower check: `commitSource` (the item's own orphaned record, restore epochs, every orphaned
        // item's commits over the branch up to the target, fail-closed on any failure) has the last word.
        var committed = WorkRef(kind: .diff, id: item.key)
        committed.rev = target
        return try commitSource(committed, item: item)
    }

    /// R1-2: the source of the first uncleared tainted commit whose content a diff of `a` against `b` can display: the
    /// symmetric range `a...b`, and each side's own commits since its merge base with `main` (`merge-base(main, side)..side`).
    /// A side with no merge base with `main`, a pair with none, or a range that can't be listed reads as tainted (fail closed).
    /// Final wave B1 item 13: `recorded` names which of a list of shas have a recorded author (`turnCommit`); while an orphaned
    /// item's branch is gone, a displayed commit with none is tainted by it (`OrphanedItem.hit`). By default nothing is recorded
    /// (fail closed).
    static func displayedRangeSource(_ git: SafeGit, _ a: String, _ b: String, rows: [TaintedCommit],
                                     orphans: [OrphanedItem] = [],
                                     recorded: ([String]) throws -> Set<String> = { _ in [] }) throws -> String? {
        guard !rows.isEmpty else { return nil }
        do {
            var shas: [String] = []
            if a != b {
                _ = try git.mergeBase(a, b)
                shas += try git.revList(a, b) + git.revList(b, a)
            }
            for side in Set([a, b]) {
                let mainBase = try git.mergeBase("main", side)
                if mainBase != side { shas += try git.revList(mainBase, side) }
            }
            if let hit = rows.first(where: { row in shas.contains { $0.hasPrefix(row.sha) } }) { return hit.source }
            // Ruling C5b-7: a commit of an orphaned item's branch (its tainted record names shas a rewrite replaced); item 13:
            // of a deleted one, a commit it recorded or one nobody recorded.
            return try OrphanedItem.hit(orphans, in: shas, recorded: recorded)
        } catch {
            return "outside content"
        }
    }

    /// C5b: the taint of a key-less `diff:<from>..<to>` (full or abbreviated shas, verified by git). Fix round 4 (R3-1): never
    /// narrower than `commitSource` — the displayed set (`displayedRangeSource`: the rows and every orphaned item's commits),
    /// then the open restore epochs over both displayed sides (each epoch's own `main` to `from` and to `to`, Ruling 25). Nil
    /// only when nothing marks it; any failed lookup (rows, epochs, repository, revs, orphans) reads as tainted, through the
    /// same fallback `commitSource` uses.
    private func rangeSource(companyId: String, from: String, to: String) throws -> String? {
        let rows: [TaintedCommit], epochs: [RestoreEpoch]
        do {
            rows = try unclearedCommits(companyId: companyId)
            epochs = try openRestoreEpochs(companyId: companyId)
        } catch {
            return Self.taintCheckFailedSource
        }
        guard !rows.isEmpty || !epochs.isEmpty else { return nil }
        do {
            guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
            let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            let refs = try reachabilityRefs(companyId: companyId)
            let (a, b) = (try git.verifyRev(from, reachableFrom: refs), try git.verifyRev(to, reachableFrom: refs))
            let orphans = Array(try orphanedItems(companyId: companyId, rows: rows).values)
            if let source = try Self.displayedRangeSource(git, a, b, rows: rows, orphans: orphans,
                                                          recorded: { try self.recordedCommitShas(companyId: companyId, shas: $0) }) {
                return source
            }
            for side in Set([a, b]) {
                if let source = restoreEpochSource(epochs, tip: side, path: nil, git: git) { return source }
            }
            return nil
        } catch {
            return Self.failClosedSource(itemRows: [], rows: rows, epochs: epochs)
        }
    }

    /// The source a taint check that failed reads as (ruling 11): the item's own newest uncleared row, else the company's
    /// newest, else an open restore epoch's, else the generic reason. Never nil.
    static func failClosedSource(itemRows: [TaintedCommit], rows: [TaintedCommit], epochs: [RestoreEpoch]) -> String {
        itemRows.first?.source ?? rows.first?.source ?? epochs.first?.source ?? taintCheckFailedSource
    }

    /// Fix round 1 (C5b-3): a diff between two commits shows both sides, so the taint of `a...b` (both directions) counts; a
    /// pair with no merge base, or a range that can't be listed, reads as tainted (fail closed). `a` and `b` are full shas.
    static func symmetricRangeSource(_ git: SafeGit, _ a: String, _ b: String, rows: [TaintedCommit]) throws -> String? {
        guard !rows.isEmpty else { return nil }
        guard a != b else { return nil }
        do {
            _ = try git.mergeBase(a, b)
            let shas = try git.revList(a, b) + git.revList(b, a)
            return rows.first { row in shas.contains { $0.hasPrefix(row.sha) } }?.source
        } catch {
            return "outside content"
        }
    }

    /// The company's uncleared tainted commits, sha → source.
    private func unclearedCommits(companyId: String) throws -> [TaintedCommit] {
        try writer.read { db in
            try TaintedCommit.fetchAll(db, sql: """
                SELECT * FROM taintedCommit WHERE companyId = ? AND clearedBy IS NULL ORDER BY createdAt DESC, rowid DESC
                """, arguments: [companyId])
        }
    }

    /// Ruling 22 (P2 R5-1) and Ruling 24: the company's restore epochs the owner has not cleared, listed or not. A listing
    /// only attributes the commits it saw to items; it never makes a commit it missed clean.
    private func openRestoreEpochs(companyId: String) throws -> [RestoreEpoch] {
        try writer.read { db in
            try RestoreEpoch.fetchAll(db, sql: """
                SELECT * FROM restoreEpoch WHERE companyId = ? AND clearedBy IS NULL ORDER BY rowid
                """, arguments: [companyId])
        }
    }

    /// Ruling 25: the source of the first of `epochs` under which `tip` holds what the restored database can't place: the
    /// range from the epoch's own `main` (`mainCommit`, never live `main`) to `tip` is not empty (`log <main>..<tip> -- <path>`
    /// for a file, `rev-list <main>..<tip>` for a diff, `path` nil). No `mainCommit` or a git failure: the epoch's source
    /// (fail closed). Nil when every epoch's range is empty. Never throws.
    private func restoreEpochSource(_ epochs: [RestoreEpoch], tip: String, path: String?, git: SafeGit) -> String? {
        for epoch in epochs {
            guard let main = epoch.mainCommit else { return epoch.source }
            do {
                let range = try path.map { try git.logShas(range: "\(main)..\(tip)", path: $0) } ?? git.revList(main, tip)
                if !range.isEmpty { return epoch.source }
            } catch {
                return epoch.source
            }
        }
        return nil
    }

    /// `restoreEpochSource` for a key-less file at `tip` (nil: `main`'s head now) under the company's open epochs; nil when
    /// it has none. The company, its repository or `main` can't be read: the first epoch's source (fail closed).
    private func restoreEpochSource(companyId: String, tip: String?, path: String) throws -> String? {
        let epochs = try openRestoreEpochs(companyId: companyId)
        guard let first = epochs.first else { return nil }
        do {
            guard let company = try company(id: companyId) else { return first.source }
            let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            return restoreEpochSource(epochs, tip: try tip ?? git.head("main"), path: path, git: git)
        } catch {
            return first.source
        }
    }

    /// `restoreEpochSource` for a commit ref (`sha`, 7–64 hex): tainted unless it is in each open epoch's `main`.
    private func restoreEpochSource(companyId: String, commit sha: String) throws -> String? {
        let epochs = try openRestoreEpochs(companyId: companyId)
        guard let first = epochs.first else { return nil }
        do {
            guard let company = try company(id: companyId) else { return first.source }
            let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            for epoch in epochs {
                guard let main = epoch.mainCommit, try git.isAncestor(sha, of: main) else { return epoch.source }
            }
            return nil
        } catch {
            return first.source
        }
    }

    /// Items with uncleared rows none of whose commits is provably clean any more: one of their rows (not carried by the
    /// engine's rebase) is not on the item's branch (a rewrite nothing carried the taint through, ruling 7), or is an
    /// `unrecorded-…` marker. Item id → (the newest row's source, every commit on its branch now). Throws when a branch can't
    /// be listed (callers fail closed). Final wave B1 item 13: an item whose branch is gone (deleted) is orphaned with the
    /// commits recorded for it instead (its taint rows and the engine's commit-author rows, `turnCommit`), and `gone`: a
    /// commit nobody recorded, merged elsewhere, may be its rewritten work, so it reads tainted by it (`OrphanedItem.hit`).
    private func orphanedItems(companyId: String, rows: [TaintedCommit]) throws -> [String: OrphanedItem] {
        let byItem = Dictionary(grouping: rows.filter { $0.itemId != nil && $0.carriedTo == nil }, by: { $0.itemId ?? "" })
        guard !byItem.isEmpty else { return [:] }
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        var out: [String: OrphanedItem] = [:]
        var failure: (any Error)?, readable: [WorkItem] = []
        for (itemId, itemRows) in byItem {
            guard let item = try workItem(id: itemId), item.companyId == companyId, let newest = itemRows.first else { continue }
            let branch: Set<String>
            do {
                if try git.branchExists("item/\(item.key)") {
                    let head = try git.head("item/\(item.key)")
                    branch = Set(try git.revList(try git.mergeBase("main", head), head))
                } else {
                    // No branch (gone): nothing of it is on one, so it is orphaned; its recorded commits stand in for its
                    // branch. A git failure throws instead (fail closed).
                    let recorded = try recordedItemShas(companyId: companyId, itemId: itemId)
                        .union(itemRows.map(\.sha).filter { !$0.hasPrefix(TaintedCommit.unrecordedPrefix) })
                    readable.append(item)
                    out[itemId] = OrphanedItem(source: newest.source, commits: recorded, gone: true)
                    continue
                }
            } catch {
                // Every other branch is still listed (each unreadable one gets its alert); the query then fails closed.
                noteUnreadableBranch(companyId: companyId, item: item, error: error)
                failure = failure ?? error
                continue
            }
            readable.append(item)
            if itemRows.contains(where: { !branch.contains($0.sha) }) { out[itemId] = OrphanedItem(source: newest.source, commits: branch, gone: false) }
        }
        noteReadableBranches(companyId: companyId, items: readable)
        if let failure { throw failure }
        return out
    }

    /// The shas of `shas` the engine recorded an author for (`turnCommit`, this company).
    func recordedCommitShas(companyId: String, shas: [String]) throws -> Set<String> {
        guard !shas.isEmpty else { return [] }
        return try writer.read { db in
            var out: Set<String> = []
            for chunk in stride(from: 0, to: shas.count, by: 500).map({ Array(shas[$0..<min($0 + 500, shas.count)]) }) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                out.formUnion(try String.fetchAll(db, sql: "SELECT sha FROM turnCommit WHERE companyId = ? AND sha IN (\(marks))",
                                                  arguments: StatementArguments([companyId] + chunk)))
            }
            return out
        }
    }

    /// Every sha the engine recorded as made on `itemId` (`turnCommit`, this company).
    func recordedItemShas(companyId: String, itemId: String) throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT sha FROM turnCommit WHERE companyId = ? AND itemId = ?", arguments: [companyId, itemId]))
        }
    }

    /// The reason that keys the owner's alert about an item branch the taint check can't read (ruling 12).
    static func unreadableBranchAlertReason(_ itemId: String) -> String { "taint-branch:\(itemId)" }

    /// Ruling 12: an item branch the orphan check can't read makes every item ref in the company read tainted (fail closed);
    /// the owner gets one alert naming it per break, not one per resolve: none while the newest alert for it is open, or was
    /// answered by the owner and the branch has not read cleanly since; a new one once the branch read cleanly after its last
    /// alert (which then answered itself, or, answered by the owner, was re-armed: `noteReadableBranches`). Never throws.
    private func noteUnreadableBranch(companyId: String, item: WorkItem, error: any Error) {
        let reason = Self.unreadableBranchAlertReason(item.id)
        let key = item.key
        @Sendable func alerted(_ db: Database) throws -> Bool {
            guard let newest = try Self.newestBranchAlert(db, companyId: companyId, itemId: item.id) else { return false }
            if newest.status == .pendingOwner { return true }
            if newest.decidedBy == "system" { return false }
            return try !Self.branchAlertRearmed(db, companyId: companyId, key: key, alert: newest)
        }
        do {
            if try writer.read(alerted) { return }      // the usual case on a later resolve: no write
            try writer.write { db in
                guard let company = try Company.fetchOne(db, key: companyId), try !alerted(db) else { return }
                let text = "Brahma can't read the branch item/\(item.key) in \(company.name) (\(Store.flat("\(error)", max: 300))), so "
                    + "every item's changes there are treated as outside content until it can. Something may have reset it onto "
                    + "unrelated history; run `git log item/\(item.key)` in \(Store.flat(company.workspacePath, max: 200)) to check."
                try EngineAlerts.raise(store: self, db: db, text: text, now: Store.now(), reason: reason, companyId: companyId)
            }
        } catch {
            FileHandle.standardError.write(Data("brahma: item/\(item.key) can't be read for the taint check (\(error)); the alert failed too\n".utf8))
        }
    }

    /// The newest ruling-12 alert about the item's branch, or nil.
    private static func newestBranchAlert(_ db: Database, companyId: String, itemId: String) throws -> Ask? {
        try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.engineAlert
                       && Column("subjectId") == Store.engineAlertKey(unreadableBranchAlertReason(itemId)))
            .order(Column("number").desc).fetchOne(db)
    }

    /// The activity line that re-arms an owner-answered ruling-12 alert: the branch read cleanly after the owner answered it.
    /// It names the alert, so each answered alert is re-armed once, by a clean read after it.
    static func branchReadableAgainText(key: String, alert: Ask) -> String {
        "item/\(key) can be read again for the taint check; a new break will alert again (after \(alert.ref))"
    }

    private static func branchAlertRearmed(_ db: Database, companyId: String, key: String, alert: Ask) throws -> Bool {
        try ActivityEvent.filter(Column("companyId") == companyId && Column("kind") == ActivityKind.access.rawValue
                                 && Column("agentId") == nil && Column("text") == branchReadableAgainText(key: key, alert: alert))
            .fetchCount(db) > 0
    }

    /// Branches that read again: their open ruling-12 alerts answer themselves, and an alert the owner answered is re-armed
    /// (an `access` activity line), so the next break raises a new one. One read when there is nothing to do. Never throws.
    private func noteReadableBranches(companyId: String, items: [WorkItem]) {
        guard !items.isEmpty else { return }
        let pending: (open: [String], rearm: [(key: String, alert: Ask)])? = try? writer.read { db in
            var open: [String] = [], rearm: [(key: String, alert: Ask)] = []
            for item in items {
                guard let newest = try Self.newestBranchAlert(db, companyId: companyId, itemId: item.id) else { continue }
                if newest.status == .pendingOwner {
                    open.append(Self.unreadableBranchAlertReason(item.id))
                } else if newest.decidedBy != "system", try !Self.branchAlertRearmed(db, companyId: companyId, key: item.key, alert: newest) {
                    rearm.append((item.key, newest))
                }
            }
            return (open, rearm)
        }
        guard let pending, !pending.open.isEmpty || !pending.rearm.isEmpty else { return }
        try? writer.write { db in
            let now = Store.now()
            if !pending.open.isEmpty { try resolveEngineAlerts(db, reasons: pending.open, now: now) }
            for (key, alert) in pending.rearm {
                guard try !Self.branchAlertRearmed(db, companyId: companyId, key: key, alert: alert) else { continue }
                try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .access,
                                  text: Self.branchReadableAgainText(key: key, alert: alert), createdAt: now).insert(db)
            }
        }
    }

    /// An uncleared row's source for `sha`, or for any sha it prefixes (7–64 lowercase hex; anything else names no row); else
    /// the source of an orphaned item whose branch holds it (fail closed when that can't be listed).
    private func commitRowSource(companyId: String, sha: String) throws -> String? {
        guard (7...64).contains(sha.utf8.count), sha.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return nil
        }
        let rows = try unclearedCommits(companyId: companyId)
        if let hit = rows.first(where: { $0.sha.hasPrefix(sha) }) { return hit.source }
        if let source = try restoreEpochSource(companyId: companyId, commit: sha) { return source }
        guard let newest = rows.first else { return nil }
        do {
            let orphans = Array(try orphanedItems(companyId: companyId, rows: rows).values)
            if let hit = orphans.first(where: { $0.commits.contains { $0.hasPrefix(sha) } }) { return hit.source }
            // Item 13: while a deleted item's record is orphaned, a commit off `main` nobody recorded reads tainted by it.
            guard let gone = orphans.first(where: \.gone) else { return nil }
            guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
            let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            let full = try git.verifyRev(sha, reachableFrom: try reachabilityRefs(companyId: companyId))
            if try git.isAncestor(full, of: "main") { return nil }
            return try recordedCommitShas(companyId: companyId, shas: [full]).contains(full) ? nil : gone.source
        } catch {
            return newest.source
        }
    }

    /// A key-less file ref at `rev`: its history from the merge base with `main` to `rev` against the uncleared rows and the
    /// orphaned items' commits, and its range from each open restore epoch's `main` (Ruling 25).
    private func keylessSource(_ ref: WorkRef, rev: String, companyId: String) throws -> String? {
        let rows = try unclearedCommits(companyId: companyId)
        let epochs = try openRestoreEpochs(companyId: companyId)
        guard let newest = rows.first?.source ?? epochs.first?.source else { return nil }
        let bySha = Dictionary(rows.map { ($0.sha, $0.source) }, uniquingKeysWith: { first, _ in first })
        do {
            guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
            let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            let base = try git.mergeBase("main", rev)
            let history = try git.logShas(range: "\(base)..\(rev)", path: ref.id)
            if let hit = history.first(where: { bySha[$0] != nil }) { return bySha[hit] }
            if let source = restoreEpochSource(epochs, tip: rev, path: ref.id, git: git) { return source }
            let orphaned = try orphanedItems(companyId: companyId, rows: rows)
            return try OrphanedItem.hit(Array(orphaned.values), in: history,
                                        recorded: { try self.recordedCommitShas(companyId: companyId, shas: $0) })
        } catch {
            return newest      // the history can't be read: fail closed
        }
    }

    /// The taint the item's commits give a committed diff or item-branch file ref (see `refTaint`).
    private func commitSource(_ ref: WorkRef, item: WorkItem) throws -> String? {
        try commitSource(ref, item: item, rows: try unclearedCommits(companyId: item.companyId),
                         epochs: try openRestoreEpochs(companyId: item.companyId))
    }

    /// `commitSource` against a given set of the company's rows (newest first) and restore epochs (R5-1, Ruling 24: listed or
    /// not): the uncleared ones now, or (ruling 17) the ones not cleared before an artifact was published. Under an epoch the
    /// range runs from the epoch's own `main` to the tip (Ruling 25).
    private func commitSource(_ ref: WorkRef, item: WorkItem, rows: [TaintedCommit], epochs: [RestoreEpoch]) throws -> String? {
        guard !rows.isEmpty || !epochs.isEmpty else { return nil }
        let bySha = Dictionary(rows.map { ($0.sha, $0.source) }, uniquingKeysWith: { first, _ in first })
        let itemRows = rows.filter { $0.itemId == item.id }
        do {
            // None of the item's commits is provably clean (a rewrite nothing carried, an unrecorded turn): all of it is tainted.
            let orphaned = try orphanedItems(companyId: item.companyId, rows: rows)
            if let orphan = orphaned[item.id] { return orphan.source }
            guard let company = try company(id: item.companyId) else { throw WorkError.notFound("no such company") }
            let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            let head = try ref.rev ?? git.head("item/\(item.key)")
            let base = try git.mergeBase("main", head)
            let history = ref.kind == .diff ? try git.revList(base, head) : try git.logShas(range: "\(base)..\(head)", path: ref.id)
            if let hit = history.first(where: { bySha[$0] != nil }) { return bySha[hit] }
            if let source = restoreEpochSource(epochs, tip: head, path: ref.kind == .diff ? nil : ref.id, git: git) { return source }
            // A commit of another orphaned item's branch on this one (a reset onto it, a cherry-pick that reused it); item 13:
            // while a deleted item's record is orphaned, a commit it recorded, or one nobody recorded.
            let companyId = item.companyId
            return try OrphanedItem.hit(Array(orphaned.values), in: history,
                                        recorded: { try self.recordedCommitShas(companyId: companyId, shas: $0) })
        } catch {
            // The history can't be read (this item's branch is gone, git failed on it or on any orphan candidate's branch, e.g.
            // one reset onto an unrelated root): fail closed for the whole query (ruling 11). The item's own newest source,
            // else the company's newest uncleared one, else an epoch's (one of them is non-empty here).
            return Self.failClosedSource(itemRows: itemRows, rows: rows, epochs: epochs)
        }
    }

    /// After the engine rebased an item (`finishMerge(.rebased)`; rulings 5 and 7): every new commit whose pre-rebase original
    /// was a tainted commit is recorded tainted too, and the originals are marked carried (`carriedTo`). The engine's rebase
    /// replays exactly the commits of `<base>..<before>` in order (`GitWorkspace.checkRebase`), so old and new map by
    /// position; `before` is the item's verified (else recorded) head before the rebase. When that mapping can't be
    /// established, every new commit of the item is recorded tainted (fail closed); when not even the new commits can be
    /// listed, an `unrecorded-…` marker makes the whole item tainted. Never throws.
    func carryTaintThroughRebase(item: WorkItem, rebased: String, now: Date) {
        guard let rows = try? unclearedCommits(companyId: item.companyId).filter({ $0.itemId == item.id }), let newest = rows.first
        else { return }
        let source = Dictionary(rows.map { ($0.sha, $0.source) }, uniquingKeysWith: { first, _ in first })
        var carried: [(old: String?, sha: String, source: String)] = [(nil, TaintedCommit.unrecordedPrefix + UUID().uuidString, newest.source)]
        if let company = try? company(id: item.companyId), let git = try? refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true)),
           let newBase = try? git.mergeBase("main", rebased), let fresh = try? git.revList(newBase, rebased) {
            carried = fresh.map { (nil, $0, newest.source) }
            let before = item.verifiedCommit ?? item.leaseHeadCommit
            if let before, before != rebased, let oldBase = try? git.mergeBase(before, rebased),
               let old = try? git.revList(oldBase, before), old.count == fresh.count {
                carried = zip(old, fresh).compactMap { o, n in source[o].map { (o, n, $0) } }
            }
        }
        do {
            try writer.write { db in
                for c in carried {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO taintedCommit (companyId, sha, itemId, agentId, turnId, source, createdAt)
                        VALUES (?, ?, ?, NULL, NULL, ?, ?)
                        """, arguments: [item.companyId, c.sha, item.id, c.source, now])
                    if let old = c.old {
                        try db.execute(sql: "UPDATE taintedCommit SET carriedTo = ? WHERE companyId = ? AND sha = ?",
                                       arguments: [c.sha, item.companyId, old])
                    }
                }
            }
        } catch {
            // The originals stay uncleared and off the branch: the item reads tainted all the same (`orphanedItems`).
            FileHandle.standardError.write(Data("brahma: could not carry the taint of \(item.key) through its rebase: \(error)\n".utf8))
        }
    }

    /// The leases the agent holds.
    func leases(agentId: String) throws -> [WorkLease] {
        try writer.read { db in try WorkLease.fetchAll(db, sql: "SELECT * FROM workLease WHERE agentId = ?", arguments: [agentId]) }
    }

    /// Item id → the head of its branch now, for every lease the agent holds (a branch that can't be read is left out: its
    /// turn-end record then starts at the claim head or the merge base, which records more, never less). Git.
    func leaseHeads(agentId: String, workspace: URL) -> [String: String] {
        guard let leases = try? leases(agentId: agentId), !leases.isEmpty, let git = try? refGit(workspace) else { return [:] }
        var heads: [String: String] = [:]
        for lease in leases {
            guard let item = try? workItem(id: lease.itemId), let head = try? git.head("item/\(item.key)") else { continue }
            heads[lease.itemId] = head
        }
        return heads
    }

    /// At the end of a turn of a tainted session (ruling 6): records the commits it made on every item branch it touched —
    /// the union of the items it held as the turn started (`heldAtStart`: item id → head then; `heldItemsAtStart`, P2 R4-3:
    /// every one of them from the leases, a head git couldn't read then included), every item it claimed during the turn (the
    /// claim log, even one released since), the leases it holds now and the turn's own leased item. Each starts at its head
    /// at turn start, else (held then, or the turn's own, with no head read) the merge base with `main`, else the trusted head
    /// of its first claim in the turn, else the lease's trusted claim head, else the merge base (never a head an agent could
    /// have moved). A read that fails falls back to what is known and alerts the owner. Never throws. Returns whether the
    /// record is complete (final wave B1, Ruling 23): false when the items the turn touched couldn't be read, or an item's
    /// record could not be written even as its fail-closed marker; the engine then holds the company until a retry succeeds.
    @discardableResult
    public func recordTurnTaints(companyId: String, agentId: String, turnId: String, heldAtStart: [String: String],
                                 heldItemsAtStart: [String] = [], leasedItemId: String?, source: String, now: Date) -> Bool {
        var complete = true
        var targets: [String: String?] = heldAtStart.mapValues { Optional($0) }
        for itemId in heldItemsAtStart + [leasedItemId].compactMap({ $0 }) where targets[itemId] == nil { targets[itemId] = .some(nil) }
        do {
            let (claims, leases) = try writer.read { db in
                (try Row.fetchAll(db, sql: "SELECT itemId, claimHead FROM leaseClaim WHERE agentId = ? AND turnId = ? ORDER BY id",
                                  arguments: [agentId, turnId]),
                 try WorkLease.fetchAll(db, sql: "SELECT * FROM workLease WHERE agentId = ?", arguments: [agentId]))
            }
            for claim in claims {
                let itemId: String = claim["itemId"]
                if targets[itemId] == nil { targets[itemId] = .some(claim["claimHead"] as String?) }    // the turn's first claim
            }
            for lease in leases where targets[lease.itemId] == nil { targets[lease.itemId] = .some(lease.claimHead) }
        } catch {
            complete = false
            alertTaintRecord(companyId: companyId, itemId: nil, what: "the items this turn touched could not be read (\(error))", now: now)
        }
        // Without the company (its workspace), nothing can be listed: every target still gets the fail-closed marker below.
        var workspace: URL?
        if !refHooks.failCompanyRead, let company = try? company(id: companyId) {
            workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        } else {
            alertTaintRecord(companyId: companyId, itemId: nil, what: "the company could not be read", now: now)
        }
        for (itemId, start) in targets {
            if !recordTurnTaint(companyId: companyId, itemId: itemId, agentId: agentId, turnId: turnId, start: start, source: source,
                                workspace: workspace, now: now) { complete = false }
        }
        return complete
    }

    /// Records `<start>..head(item/<KEY>)` of one item as tainted commits (`start` nil: the merge base with `main`; `workspace`
    /// nil: the company could not be read, so straight to the fail-closed marker). Fail
    /// closed: when that can't be done, every commit from the merge base is recorded instead; when not even that, an
    /// `unrecorded-…` marker makes all of the item's commits tainted (`orphanedItems`), the item is marked (5-lite's sticky
    /// `taintedOrigin`, which taints its worktree) and the owner gets an engine alert. Never throws. Returns false only when
    /// not even the marker could be written (Ruling 23: nothing recorded the taint).
    @discardableResult
    public func recordTurnTaint(companyId: String, itemId: String, agentId: String, turnId: String?, start: String?,
                                source: String, workspace: URL?, now: Date) -> Bool {
        var failure: (any Error)?
        do {
            guard let workspace else { throw WorkError.notFound("the company's workspace could not be read") }
            guard let item = try workItem(id: itemId), item.companyId == companyId else { return true }
            let git = try refGit(workspace)
            let after = try git.head("item/\(item.key)")
            let base = try git.mergeBase("main", after)
            do {
                try recordTaintedCommits(companyId: companyId, itemId: itemId, agentId: agentId, turnId: turnId, headBefore: start ?? base,
                                         headAfter: after, source: source, git: git, now: now)
                return true
            } catch {
                failure = error
                try recordTaintedCommits(companyId: companyId, itemId: itemId, agentId: agentId, turnId: turnId, headBefore: base,
                                         headAfter: after, source: source, git: git, now: now)
                return true
            }
        } catch {
            failure = failure ?? error
        }
        var marked = true
        do {
            if refHooks.failTaintRecords { throw WorkError.conflict("injected: the taint marker could not be written") }
            try writer.write { db in
                try db.execute(sql: """
                    INSERT OR IGNORE INTO taintedCommit (companyId, sha, itemId, agentId, turnId, source, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [companyId, TaintedCommit.unrecordedPrefix + UUID().uuidString, itemId, agentId, turnId,
                                     Store.flat(source, max: 200), now])
                try db.execute(sql: "UPDATE workItem SET taintedOrigin = 1 WHERE companyId = ? AND id = ?", arguments: [companyId, itemId])
            }
        } catch {
            marked = false
            FileHandle.standardError.write(Data("brahma: could not mark item \(itemId) tainted: \(error)\n".utf8))
        }
        alertTaintRecord(companyId: companyId, itemId: itemId, what: "its commits could not be listed (\(failure.map { "\($0)" } ?? "unknown"))",
                         now: now)
        return marked
    }

    /// The owner's engine alert for a taint record that could not be made as it should (stderr when even that fails).
    private func alertTaintRecord(companyId: String, itemId: String?, what: String, now: Date) {
        let key = (try? itemId.flatMap { try workItem(id: $0)?.key }) ?? nil
        let text = "The commits a session that read outside content made\(key.map { " on \($0)" } ?? "") could not all be recorded: \(what). "
            + (key.map { "\($0) is treated as tainted until it is merged or you vouch for it." } ?? "Check the items this agent worked on.")
        do {
            try EngineAlerts.raise(store: self, text: text, now: now, reason: "taint-record:\(itemId ?? companyId)", companyId: companyId)
        } catch {
            FileHandle.standardError.write(Data("brahma: \(text) (the alert failed too: \(error))\n".utf8))
        }
    }

    // MARK: Private snapshots

    /// Copies a file of the agent's own lab or notes (`workspacePath`, opened through `SafeFS`) into the vault as a new
    /// `F-<n>` resource that only `readers` (agent ids of this company, fixed now) and the owner can read: ML's `resource`
    /// table, `addedVia = "share"`, the next number of the same `UNIQUE(companyId, number)` sequence (never one an orphaned
    /// vault file holds), the bytes through `Vault.write(…, area: .resources, …)` where `ContentVault` reads them. A session
    /// that read outside content makes a tainted snapshot (`provenance .external("tainted-session:<source>")`); otherwise its
    /// provenance is the agent. Not ML's `addResources` (the owner's drop path). The bytes pass the secret gate first
    /// (`SecretGate.check`, C2b): a stored secret's value (raw, encoded or in an archive member) refuses the snapshot, as does
    /// an archive or PDF that can't be scanned (`archives`); a secret pattern stores a redacted copy (text, checked again
    /// through the gate, `SecretGate.redactedCopy`; `secretScan = redacted`, `sourceDetail` = the lab path, the owner's
    /// original) or refuses (binary, a container, or a pattern found only in decoded content).
    public func snapshotPrivateFile(companyId: String, agentId: String, workspacePath: String, readers: [String],
                                    knownValues: [(name: String, value: String)], paths: BrahmaPaths, now: Date,
                                    archives: (any ArchiveReader)? = nil) throws -> WorkRef {
        guard !readers.isEmpty else { throw WorkError.invalid("a private snapshot needs at least one reader") }
        let (agent, company, readerSet) = try writer.read { db -> (Agent, Company, Set<String>) in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId,
                  let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.forbidden("not in your company") }
            var set = Set<String>()
            for reader in readers {
                do { set.formUnion(try Self.readerSet(db: db, for: .agent(reader), companyId: companyId) ?? []) } catch {
                    throw WorkError.notFound("no such agent")
                }
            }
            return (agent, company, set)
        }
        let fs = try SafeFS(workspace: URL(fileURLWithPath: company.workspacePath, isDirectory: true), ownHandle: agent.name)
        let file: SafeFile
        do { file = try fs.open(workspacePath: workspacePath, maxBytes: ArtifactPolicy.maxFileBytes) } catch let e as SafeFSError {
            switch e {
            case .privateTo, .notAllowed, .notInPlace: throw WorkError.forbidden("only files in your own lab or notes are sent as private snapshots")
            case .tooLarge: throw WorkError.invalid("that file is over the \(ResourceText.size(Int64(ArtifactPolicy.maxFileBytes))) limit")
            default: throw WorkError.notFound("there is no such file in your lab or notes")
            }
        }
        guard file.place == .ownLab || file.place == .ownNotes else {
            throw WorkError.forbidden("only files in your own lab or notes are sent as private snapshots")
        }
        let fileName = workspacePath.split(separator: "/").last.map(String.init) ?? workspacePath
        var data = try file.readAll()
        // The secret gate, before anything is written: a stored secret's value refuses; a secret pattern in text stores a
        // redacted copy (REDACTED), in a binary refuses (it can't be redacted). C3b (Ruling 41): through `gatedBytes`, so a PDF
        // the owner vouched for is snapshotted as its flattened copy, never itself.
        // (Ruling 48: in a turn's server the engine gates what needs a helper, and its bytes are what is stored.)
        let gated = try gateRef(data, ext: ArtifactKind.ext(of: fileName), canonical: fileName, companyId: companyId,
                                ref: WorkRef(kind: .file, id: workspacePath), reader: .agent(agentId), purpose: .snapshot,
                                archives: archives ?? UnavailableArchiveReader(), knownValues: knownValues, paths: paths)
        data = gated.data
        let verdict = gated.verdict
        var secretScan = SecretScanState.none
        if case .pattern(let label, _) = verdict {
            guard SecretGate.isRedactable(data, ext: ArtifactKind.ext(of: fileName)) else {
                throw SecretGate.binaryRefusal(fileName, label: label, what: "sent", knownValues: knownValues)
            }
            data = try SecretGate.redactedCopy(data, ext: ArtifactKind.ext(of: fileName), canonical: fileName,
                                               archives: archives ?? UnavailableArchiveReader(), knownValues: knownValues, store: self)
            secretScan = .redacted
        }
        let taint = try currentTaint(agentId: agentId, paths: paths)
        let number = try vaultShareCopy(companyId: companyId, data: data, fileName: fileName,
                                        sourceDetail: secretScan == .redacted ? workspacePath : fileName, scope: .agent(agentId),
                                        readerSet: readerSet, futureHolders: false, provenance: .agent(agentId), taint: taint,
                                        secretScan: secretScan, paths: paths, now: now)
        return WorkRef(kind: .resource, id: String(number))
    }

    /// Writes `data` into the vault as the next `F-<n>` (`addedVia = "share"`): ML's `resource` table, the next number of the
    /// same `UNIQUE(companyId, number)` sequence (never one an orphaned vault file holds), the bytes through
    /// `Vault.write(…, area: .resources, …)` where `ContentVault` reads them, indexed by title. A session that read outside
    /// content (`taint`) makes it tainted (`provenance .external("tainted-session:<source>")`). Returns the number.
    func vaultShareCopy(companyId: String, data: Data, fileName: String, sourceDetail: String, scope: AccessClass,
                        readerSet: Set<String>?, futureHolders: Bool, provenance: Provenance, taint: String?,
                        secretScan: SecretScanState, paths: BrahmaPaths, now: Date) throws -> Int {
        let found = ArtifactKind.ext(of: fileName)
        let ext = ContentVault.validExt(found) ? found : "bin"
        let content = ContentVault(paths: paths)
        let vault = Vault(paths: paths, companyId: companyId, content: content)
        for _ in 0..<5 {
            // Ruling 50: from the company's counter, never a number a removed copy had (the rows and vault files its floor).
            let vaultHighest = try content.highestNumber(companyId: companyId)
            let number = try writer.write { db in
                try Store.nextRefNumber(db: db, companyId: companyId, kind: .resource, floor: max(vaultHighest, try Int.fetchOne(db, sql:
                    "SELECT MAX(number) FROM resource WHERE companyId = ?", arguments: [companyId]) ?? 0))
            }
            let written: (path: String, sha256: String)
            do { written = try vault.write(data, area: .resources, name: "F-\(number).\(ext)") } catch WorkError.conflict(_) { continue }
            let row = Resource(companyId: companyId, number: number, kind: .file, displayName: ResourceIntake.sanitizeName(fileName),
                               ext: ext, fileKind: ArtifactKind.from(ext: ext)?.rawValue, bytes: Int64(data.count), sha256: written.sha256,
                               vaultPath: written.path, scopeKind: scope.kind, scopeId: scope.id, readerSet: readerSet,
                               futureHolders: futureHolders,
                               provenance: taint.map { Provenance.external("tainted-session:\($0)") }?.raw ?? provenance.raw,
                               sourceDetail: ResourceIntake.sanitizeName(sourceDetail), tainted: taint != nil,
                               taintReason: taint.map(Self.sessionReason), secretScan: secretScan, addedVia: "share",
                               createdAt: now, updatedAt: now)
            do {
                try writer.write { db in
                    try row.insert(db)
                    _ = try ingestResource(db: db, row, text: nil, now: now)
                }
            } catch let e as DatabaseError where e.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE || e.extendedResultCode == .SQLITE_CONSTRAINT_PRIMARYKEY {
                try? vault.remove(written.path)
                continue
            } catch {
                try? vault.remove(written.path)
                throw error
            }
            return number
        }
        throw WorkError.conflict("no free resource number; try again")
    }
}

/// Merged through the review gate: the item's tainted commits stop propagating (`clearedBy = "review"`). Runs inside the
/// transaction that completes the item (`Store.completeItem`), which only the merged path and the container rule reach.
struct TaintedCommitObserver: WorkItemObserver {
    func itemCompleted(_ item: WorkItem, db: Database) throws {
        guard item.mergedCommit != nil else { return }
        try Store.clearTaintedCommits(db: db, item: item, by: "review", now: item.doneAt ?? Store.now())
    }
}

/// The files of an artifact's copy (`.brahma/artifacts/<folder>/…`), folder-relative and sorted, listed on descriptors that
/// follow no link. Anything but regular files and directories, more than `ArtifactPolicy.maxFiles` files, or more than 16
/// levels throws (ruling 16's check then reads the artifact tainted).
enum ArtifactCopyListing {
    static let maxDepth = 16

    /// Opens `<real workspace>/.brahma/artifacts/<folder>` one part at a time with `O_NOFOLLOW` and creates nothing (a read
    /// path never writes): a part that is missing, a link or not a directory throws.
    static func files(workspace: URL, folder: String) throws -> [String] {
        guard let root = Store.realPath(workspace.path) else { throw VaultError.missing }
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw VaultError.missing }
        for part in [".brahma", "artifacts", folder] {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw VaultError.missing }
            fd = next
        }
        var out: [String] = []
        try walk(fd, prefix: "", depth: 0, into: &out)
        return out.sorted()
    }

    /// Lists `fd` (and closes it).
    private static func walk(_ fd: Int32, prefix: String, depth: Int, into out: inout [String]) throws {
        defer { close(fd) }
        guard depth <= maxDepth, let names = DirectoryListing.names(fd: fd, limit: ArtifactPolicy.maxFiles + 1) else {
            throw VaultError.missing
        }
        for name in names {
            guard !name.isEmpty, !name.contains("/") else { throw VaultError.missing }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { throw VaultError.missing }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                out.append(path)
                if out.count > ArtifactPolicy.maxFiles { throw VaultError.missing }
            case S_IFDIR:
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw VaultError.missing }
                try walk(child, prefix: path, depth: depth + 1, into: &out)
            default:
                throw VaultError.missing
            }
        }
    }
}

/// An item whose taint record is orphaned (`Store.orphanedItems`): its newest uncleared row's source, the commits that stand
/// for its work (on its branch now, or, its branch gone, the ones recorded for it), and whether its branch is gone.
struct OrphanedItem: Sendable {
    var source: String
    var commits: Set<String>
    var gone: Bool

    /// The source of the first orphan any of `shas` belongs to; else (final wave B1 item 13) while an orphan's branch is gone,
    /// its source when any of `shas` has no recorded author (`recorded` returns the shas that have one): unknown provenance next
    /// to a deleted orphan reads tainted (fail closed). Nil when nothing matches.
    static func hit(_ orphans: [OrphanedItem], in shas: [String], recorded: ([String]) throws -> Set<String>) throws -> String? {
        if let hit = orphans.first(where: { o in shas.contains { o.commits.contains($0) } }) { return hit.source }
        guard let gone = orphans.first(where: \.gone), !shas.isEmpty else { return nil }
        let known = try recorded(shas)
        return shas.contains { !known.contains($0) } ? gone.source : nil
    }
}

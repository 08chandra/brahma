import Foundation
import GRDB

/// Taint as data (design §4.3). A session that read outside content stamps what it produces — the commits of its holder turn,
/// the files it snapshots, the refs it pins, the messages it posts — and every reader of those is tainted in turn when it
/// opens them (`openRef`). "Now" is ML's `Store.currentTaint`, a past moment `Store.taintAt`: taint is per session and
/// survives resumed turns, so no turn's own `taintedAt` decides it. C has no taint reader of its own.
extension Store {
    /// The reason a `.brahma/…` file at a rev other than `main`'s recorded head is tainted (ruling 8).
    static let brahmaRevReason = "a .brahma file outside main's recorded head"

    /// The reason a `.brahma/…` file on disk that no item or hand-off accounts for is tainted (ruling 9).
    static let unplacedBrahmaReason = "a .brahma file no item accounts for"

    /// The source recorded when a taint check or record could not be made and nothing better is known (fail closed, ruling 11).
    static let taintCheckFailedSource = "a taint check that failed"

    /// The reason a session's taint gives what it produced.
    static func sessionReason(_ source: String) -> String { "from a session that read \(source)" }

    // MARK: Tainted commits

    /// Records `git rev-list <headBefore>..<headAfter>` of a tainted holder turn as tainted commits of the item (an existing
    /// row is kept as it is). The caller has read the session's taint (`source`) before any fresh-session reset.
    public func recordTaintedCommits(companyId: String, itemId: String, agentId: String, turnId: String?, headBefore: String,
                                     headAfter: String, source: String, git: SafeGit, now: Date) throws {
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
    public func vouchItem(itemId: String, now: Date) throws {
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
            try Self.clearTaintedCommits(db: db, item: item, by: "owner", now: now)
            try ActivityEvent(companyId: item.companyId, agentId: nil, turnId: nil, kind: .access,
                              text: "Owner vouched for \(item.key)'s changes", createdAt: now).insert(db)
        }
    }

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
            if ref.kind == .file, ref.itemKey == nil {
                guard let rev = ref.rev else {
                    return ref.id.hasPrefix(".brahma/") ? try onDiskBrahmaTaint(ref, companyId: companyId) : (false, nil)
                }
                // Ruling 8: a `.brahma/…` path at any rev but `main`'s engine-recorded head is tainted (it can be force-added on
                // an item branch, and a pinned blob of a live `.brahma` file carries no record of who wrote it).
                if ref.id.hasPrefix(".brahma/") {
                    let main = try company(id: companyId)?.mainCommit
                    return main != nil && rev == main ? (false, nil) : (true, Self.brahmaRevReason)
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
    /// - an agent's lab or notes (private: only it and the owner read them): its own place, not judged here;
    /// - anything else (`artifacts`, an unknown item): it can't be determined, so tainted (fail closed).
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

    /// The source of the taint of an item-branch file or diff (committed or `@worktree`), or nil when it is clean.
    func contentSource(_ ref: WorkRef, item: WorkItem) throws -> String? {
        if ref.isWorktree {
            if let source = try holderSource(item: item) { return source }
            if item.taintedOrigin { return "outside content" }
            guard ref.kind == .file else { return nil }
            var committed = ref
            committed.branch = "item/\(item.key)"
            committed.rev = nil
            return try commitSource(committed, item: item)
        }
        return try commitSource(ref, item: item)
    }

    /// The company's uncleared tainted commits, sha → source.
    private func unclearedCommits(companyId: String) throws -> [TaintedCommit] {
        try writer.read { db in
            try TaintedCommit.fetchAll(db, sql: """
                SELECT * FROM taintedCommit WHERE companyId = ? AND clearedBy IS NULL ORDER BY createdAt DESC, rowid DESC
                """, arguments: [companyId])
        }
    }

    /// Items with uncleared rows none of whose commits is provably clean any more: one of their rows (not carried by the
    /// engine's rebase) is not on the item's branch (a rewrite nothing carried the taint through, ruling 7), or is an
    /// `unrecorded-…` marker. Item id → (the newest row's source, every commit on its branch now). Throws when a branch can't
    /// be listed (callers fail closed).
    private func orphanedItems(companyId: String, rows: [TaintedCommit]) throws -> [String: (source: String, commits: Set<String>)] {
        let byItem = Dictionary(grouping: rows.filter { $0.itemId != nil && $0.carriedTo == nil }, by: { $0.itemId ?? "" })
        guard !byItem.isEmpty else { return [:] }
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        var out: [String: (source: String, commits: Set<String>)] = [:]
        for (itemId, itemRows) in byItem {
            guard let item = try workItem(id: itemId), item.companyId == companyId, let newest = itemRows.first else { continue }
            let branch: Set<String>
            if try git.branchExists("item/\(item.key)") {
                let head = try git.head("item/\(item.key)")
                branch = Set(try git.revList(try git.mergeBase("main", head), head))
            } else {
                branch = []      // no branch (gone): nothing of it is on one. A git failure throws instead (fail closed).
            }
            if itemRows.contains(where: { !branch.contains($0.sha) }) { out[itemId] = (newest.source, branch) }
        }
        return out
    }

    /// An uncleared row's source for `sha`, or for any sha it prefixes (7–64 lowercase hex; anything else names no row); else
    /// the source of an orphaned item whose branch holds it (fail closed when that can't be listed).
    private func commitRowSource(companyId: String, sha: String) throws -> String? {
        guard (7...64).contains(sha.utf8.count), sha.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return nil
        }
        let rows = try unclearedCommits(companyId: companyId)
        guard let newest = rows.first else { return nil }
        if let hit = rows.first(where: { $0.sha.hasPrefix(sha) }) { return hit.source }
        do {
            return try orphanedItems(companyId: companyId, rows: rows).values.first(where: { $0.commits.contains { $0.hasPrefix(sha) } })?.source
        } catch {
            return newest.source
        }
    }

    /// A key-less file ref at `rev`: its history from the merge base with `main` to `rev` against the uncleared rows and the
    /// orphaned items' commits.
    private func keylessSource(_ ref: WorkRef, rev: String, companyId: String) throws -> String? {
        let rows = try unclearedCommits(companyId: companyId)
        guard let newest = rows.first else { return nil }
        let bySha = Dictionary(rows.map { ($0.sha, $0.source) }, uniquingKeysWith: { first, _ in first })
        do {
            guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
            let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            let base = try git.mergeBase("main", rev)
            let history = try git.logShas(range: "\(base)..\(rev)", path: ref.id)
            if let hit = history.first(where: { bySha[$0] != nil }) { return bySha[hit] }
            let orphaned = try orphanedItems(companyId: companyId, rows: rows)
            return orphaned.values.first(where: { item in history.contains { item.commits.contains($0) } })?.source
        } catch {
            return newest.source      // the history can't be read: fail closed
        }
    }

    /// The taint the item's commits give a committed diff or item-branch file ref (see `refTaint`).
    private func commitSource(_ ref: WorkRef, item: WorkItem) throws -> String? {
        let rows = try unclearedCommits(companyId: item.companyId)
        guard !rows.isEmpty else { return nil }
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
            // A commit of another orphaned item's branch on this one (a reset onto it, a cherry-pick that reused it).
            return orphaned.values.first(where: { other in history.contains { other.commits.contains($0) } })?.source
        } catch {
            // The history can't be read (this item's branch is gone, git failed on it or on any orphan candidate's branch, e.g.
            // one reset onto an unrelated root): fail closed for the whole query (ruling 11). The item's own newest source,
            // else the company's newest uncleared one (`rows` is non-empty here).
            return itemRows.first?.source ?? rows.first?.source ?? Self.taintCheckFailedSource
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
    /// the union of the items it held as the turn started (`heldAtStart`: item id → head then), every item it claimed during
    /// the turn (the claim log, even one released since), the leases it holds now and the turn's own leased item. Each starts
    /// at its head at turn start, else the trusted head of its first claim in the turn, else the lease's trusted claim head,
    /// else the merge base with `main` (never a head an agent could have moved). A read that fails falls back to what is known
    /// and alerts the owner. Never throws.
    public func recordTurnTaints(companyId: String, agentId: String, turnId: String, heldAtStart: [String: String],
                                 leasedItemId: String?, source: String, now: Date) {
        var targets: [String: String?] = heldAtStart.mapValues { Optional($0) }
        if let leasedItemId, targets[leasedItemId] == nil { targets[leasedItemId] = .some(nil) }
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
            recordTurnTaint(companyId: companyId, itemId: itemId, agentId: agentId, turnId: turnId, start: start, source: source,
                            workspace: workspace, now: now)
        }
    }

    /// Records `<start>..head(item/<KEY>)` of one item as tainted commits (`start` nil: the merge base with `main`; `workspace`
    /// nil: the company could not be read, so straight to the fail-closed marker). Fail
    /// closed: when that can't be done, every commit from the merge base is recorded instead; when not even that, an
    /// `unrecorded-…` marker makes all of the item's commits tainted (`orphanedItems`), the item is marked (5-lite's sticky
    /// `taintedOrigin`, which taints its worktree) and the owner gets an engine alert. Never throws.
    public func recordTurnTaint(companyId: String, itemId: String, agentId: String, turnId: String?, start: String?,
                                source: String, workspace: URL?, now: Date) {
        var failure: (any Error)?
        do {
            guard let workspace else { throw WorkError.notFound("the company's workspace could not be read") }
            guard let item = try workItem(id: itemId), item.companyId == companyId else { return }
            let git = try refGit(workspace)
            let after = try git.head("item/\(item.key)")
            let base = try git.mergeBase("main", after)
            do {
                try recordTaintedCommits(companyId: companyId, itemId: itemId, agentId: agentId, turnId: turnId, headBefore: start ?? base,
                                         headAfter: after, source: source, git: git, now: now)
                return
            } catch {
                failure = error
                try recordTaintedCommits(companyId: companyId, itemId: itemId, agentId: agentId, turnId: turnId, headBefore: base,
                                         headAfter: after, source: source, git: git, now: now)
                return
            }
        } catch {
            failure = failure ?? error
        }
        do {
            try writer.write { db in
                try db.execute(sql: """
                    INSERT OR IGNORE INTO taintedCommit (companyId, sha, itemId, agentId, turnId, source, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [companyId, TaintedCommit.unrecordedPrefix + UUID().uuidString, itemId, agentId, turnId,
                                     Store.flat(source, max: 200), now])
                try db.execute(sql: "UPDATE workItem SET taintedOrigin = 1 WHERE companyId = ? AND id = ?", arguments: [companyId, itemId])
            }
        } catch {
            FileHandle.standardError.write(Data("brahma: could not mark item \(itemId) tainted: \(error)\n".utf8))
        }
        alertTaintRecord(companyId: companyId, itemId: itemId, what: "its commits could not be listed (\(failure.map { "\($0)" } ?? "unknown"))",
                         now: now)
    }

    /// The owner's engine alert for a taint record that could not be made as it should (stderr when even that fails).
    func alertTaintRecord(companyId: String, itemId: String?, what: String, now: Date) {
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
    /// (`secretGate`): a stored secret's value refuses the snapshot, a secret pattern stores a redacted copy (text) or refuses
    /// (binary).
    public func snapshotPrivateFile(companyId: String, agentId: String, workspacePath: String, readers: [String],
                                    knownValues: [(name: String, value: String)], paths: BrahmaPaths, now: Date) throws -> WorkRef {
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
        // redacted copy (REDACTED), in a binary refuses (it can't be redacted).
        let scan = try Self.secretGate(data, shown: fileName, knownValues: knownValues)
        var secretScan = SecretScanState.none
        if let pattern = scan.findings.first {
            guard scan.isText else {
                throw WorkError.forbidden("\(Store.flat(fileName, max: 120)) looks like it contains a secret (\(pattern.label)); a binary "
                                          + "file can't be redacted, so it isn't sent")
            }
            data = Data(ContentScan.redact(text: String(decoding: data, as: UTF8.self), findings: scan.findings, knownValues: knownValues).utf8)
            secretScan = .redacted
        }
        let taint = try currentTaint(agentId: agentId, paths: paths)
        let found = ArtifactKind.ext(of: fileName)
        let ext = ContentVault.validExt(found) ? found : "bin"
        let content = ContentVault(paths: paths)
        let vault = Vault(paths: paths, companyId: companyId, content: content)
        for _ in 0..<5 {
            let dbMax = try writer.read { db in
                try Int.fetchOne(db, sql: "SELECT MAX(number) FROM resource WHERE companyId = ?", arguments: [companyId]) ?? 0
            }
            let number = max(dbMax, try content.highestNumber(companyId: companyId)) + 1
            let written: (path: String, sha256: String)
            do { written = try vault.write(data, area: .resources, name: "F-\(number).\(ext)") } catch WorkError.conflict(_) { continue }
            let row = Resource(companyId: companyId, number: number, kind: .file, displayName: ResourceIntake.sanitizeName(fileName),
                               ext: ext, fileKind: ArtifactKind.from(ext: ext)?.rawValue, bytes: Int64(data.count), sha256: written.sha256,
                               vaultPath: written.path, scopeKind: AccessClass.agent(agentId).kind, scopeId: agentId, readerSet: readerSet,
                               provenance: taint.map { Provenance.external("tainted-session:\($0)") }?.raw ?? Provenance.agent(agentId).raw,
                               sourceDetail: ResourceIntake.sanitizeName(fileName), tainted: taint != nil,
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
            return WorkRef(kind: .resource, id: String(number))
        }
        throw WorkError.conflict("no free resource number; try again")
    }
}

extension Store {
    /// The secret scan every byte the engine vaults, caches or hashes into git for a share goes through (design §4.5, ruling
    /// 2): ML's `ContentScan` over `data` with the stored secrets' values (`knownValues`) and the secret patterns (a binary,
    /// NUL in the first 8 KB, is pattern-scanned as text too). A stored secret's value refuses at once (`"<shown> contains a stored secret (line n); remove
    /// it before sharing"`; the value is never echoed); pattern findings are returned for the caller to redact or refuse.
    static func secretGate(_ data: Data, shown: String, knownValues: [(name: String, value: String)]) throws
        -> (findings: [ScanFinding], isText: Bool) {
        let isText = !data.prefix(OpenRefLimits.binarySniffBytes).contains(0)
        var findings = try ContentScan.scan(data: data, isText: isText, knownValues: knownValues)
        // A binary is scanned for the patterns too (as text): ML's binary scan looks only for the stored values.
        if !isText { findings += try ContentScan.scan(data: data, isText: true, knownValues: []).filter { !$0.isKnownValue } }
        if let known = findings.first(where: \.isKnownValue) {
            throw WorkError.forbidden("\(Store.flat(shown, max: 200)) contains a stored secret\(known.line > 0 ? " (line \(known.line))" : ""); "
                                      + "remove it before sharing")
        }
        return (findings, isText)
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

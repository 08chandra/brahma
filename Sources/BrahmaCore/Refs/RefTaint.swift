import Foundation
import GRDB

/// Taint as data (design §4.3). A session that read outside content stamps what it produces — the commits of its holder turn,
/// the files it snapshots, the refs it pins, the messages it posts — and every reader of those is tainted in turn when it
/// opens them (`openRef`). "Now" is ML's `Store.currentTaint`, a past moment `Store.taintAt`: taint is per session and
/// survives resumed turns, so no turn's own `taintedAt` decides it. C has no taint reader of its own.
extension Store {
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

    /// Whether `ref` carries outside content, and why (design §4.3):
    /// - a pinned ref made by a tainted session (`params["taint"]`, set by `pinRef`): tainted, whatever it names;
    /// - a resource: its `tainted`; a message or thread: `fromTaintedSession` (or the older `taintedOrigin`); an item, kb page
    ///   or memory entry: its own flag;
    /// - a committed diff: any uncleared tainted commit in `rev-list <merge-base>..<head>`; a file on an item branch: any in
    ///   `log <merge-base>..<rev> -- <path>`; when that history can't be read, any uncleared commit of the item (fail closed);
    /// - `@worktree` content: the lease holder's session is tainted now (`currentTaint`); a pinned worktree diff: its snapshot's;
    /// - anything else (main files, commits, agents, …): not tainted.
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
        case .file, .diff:
            guard let key = ref.kind == .diff ? ref.id : ref.itemKey else { return (false, nil) }   // main: merged through review
            guard let item = try writer.read({ db in try RefAccess.item(db, companyId, key) }) else { return (false, nil) }
            if ref.isWorktree {
                if let snapshot = ref.params["snapshot"] {
                    let row = try writer.read { db in
                        try RefSnapshot.fetchOne(db, sql: "SELECT * FROM refSnapshot WHERE companyId = ? AND id = ?", arguments: [companyId, snapshot])
                    }
                    return row.map { $0.tainted ? (true, $0.taintReason ?? "outside content") : (false, nil) } ?? (false, nil)
                }
                if ref.rev != nil { return (false, nil) }      // a pinned blob: its taint was fixed at pin time (`params["taint"]`)
                return try holderSource(item: item).map { (true, Self.sessionReason($0)) } ?? (false, nil)
            }
            return try commitTaint(ref, item: item)
        default:
            return (false, nil)
        }
    }

    /// The taint the item's commits give a committed diff or item-branch file ref.
    private func commitTaint(_ ref: WorkRef, item: WorkItem) throws -> (tainted: Bool, reason: String?) {
        let rows = try writer.read { db in
            try TaintedCommit.fetchAll(db, sql: """
                SELECT * FROM taintedCommit WHERE companyId = ? AND clearedBy IS NULL ORDER BY createdAt DESC, rowid DESC
                """, arguments: [item.companyId])
        }
        guard !rows.isEmpty else { return (false, nil) }
        let bySha = Dictionary(rows.map { ($0.sha, $0.source) }, uniquingKeysWith: { first, _ in first })
        do {
            guard let company = try company(id: item.companyId) else { throw WorkError.notFound("no such company") }
            let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            let head = try ref.rev ?? git.head("item/\(item.key)")
            let base = try git.mergeBase("main", head)
            let history = ref.kind == .diff ? try git.revList(base, head) : try git.logShas(range: "\(base)..\(head)", path: ref.id)
            guard let hit = history.first(where: { bySha[$0] != nil }) else { return (false, nil) }
            return (true, Self.sessionReason(bySha[hit] ?? "outside content"))
        } catch {
            // The history can't be read (the branch is gone, git failed): any uncleared commit of the item taints it.
            guard let row = rows.first(where: { $0.itemId == item.id }) else { return (false, nil) }
            return (true, Self.sessionReason(row.source))
        }
    }

    // MARK: Private snapshots

    /// Copies a file of the agent's own lab or notes (`workspacePath`, opened through `SafeFS`) into the vault as a new
    /// `F-<n>` resource that only `readers` (agent ids of this company, fixed now) and the owner can read: ML's `resource`
    /// table, `addedVia = "share"`, the next number of the same `UNIQUE(companyId, number)` sequence (never one an orphaned
    /// vault file holds), the bytes through `Vault.write(…, area: .resources, …)` where `ContentVault` reads them. A session
    /// that read outside content makes a tainted snapshot (`provenance .external("tainted-session:<source>")`); otherwise its
    /// provenance is the agent. Not ML's `addResources` (the owner's drop path). `knownValues` is C2b's secret gate.
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
        let data = try file.readAll()
        let taint = try currentTaint(agentId: agentId, paths: paths)
        let fileName = workspacePath.split(separator: "/").last.map(String.init) ?? workspacePath
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
                               taintReason: taint.map(Self.sessionReason), addedVia: "share", createdAt: now, updatedAt: now)
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

/// Merged through the review gate: the item's tainted commits stop propagating (`clearedBy = "review"`). Runs inside the
/// transaction that completes the item (`Store.completeItem`), which only the merged path and the container rule reach.
struct TaintedCommitObserver: WorkItemObserver {
    func itemCompleted(_ item: WorkItem, db: Database) throws {
        guard item.mergedCommit != nil else { return }
        try Store.clearTaintedCommits(db: db, item: item, by: "review", now: item.doneAt ?? Store.now())
    }
}

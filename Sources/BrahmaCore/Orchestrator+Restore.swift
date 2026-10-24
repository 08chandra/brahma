import Foundation
import GRDB

extension Orchestrator {
    static let restoreTaskKey = "restore-marker"

    /// The restore-marker step (Task 12, fix round 1). The marker `<home>/run/restored-at` by itself grants nothing: it must pass
    /// `RestoreMarker.read` (a regular 0600 file of this user, never a link, small) and its nonce must name a `restoreEvent` row
    /// the database has not taken up. Anything else is ignored (activity "restore marker ignored: <reason>", once) and removed
    /// when that is safe.
    ///
    /// For a valid marker, per company the restore recorded: git's `main` is read (through `GitWorkspace`/`GitCommand`, in a
    /// `Blocking` body). It is re-adopted only when it is exactly the `mainCommit` the restored database recorded
    /// (`restoreMain`) and `main` is not a symbolic ref; the event is consumed in the same transaction. Any other head is not
    /// adopted: the company's record is set to the restore's commit and 3a's own reaction to a `main` that moved outside
    /// Brahma takes over (`Store.checkMain`: one owner engine alert, claims and merges held until `brahma main accept`).
    /// The `RestoreHooks.afterRestore` handlers run for re-adopted companies only. Never waits on git.
    func restoreMarkerTick(companies: [Company]) {
        let marker = BackupService.restoreMarker(paths: paths)
        guard gitTasks[Self.restoreTaskKey] == nil else { return }
        var st = stat()
        guard lstat(marker.path, &st) == 0 || errno != ENOENT else { return }
        let (store, blocking, hooks) = (self.store, self.blocking, restoreHooks.afterRestore)
        spawnGit(Self.restoreTaskKey) { [self] in
            let reading = await blocking.run { RestoreMarker.read(marker) }
            switch reading {
            case .absent:
                return
            case .ignored(let reason, let removable, let identity):
                await ignoreRestoreMarker(marker, reason: reason, removable: removable, identity: identity, companies: companies)
            case .nonce(let nonce):
                await takeUpRestore(nonce: nonce, marker: marker, companies: companies, store: store, blocking: blocking, hooks: hooks)
            }
        }
    }

    /// Whether to log this ignored marker: each one once. A marker that was removed is forgotten (the next one is new).
    private func noteIgnoredRestoreMarker(identity: String, removed: Bool) -> Bool {
        let log = ignoredRestoreMarker != identity
        ignoredRestoreMarker = removed ? nil : identity
        return log
    }

    private func ignoreRestoreMarker(_ marker: URL, reason: String, removable: Bool, identity: String, companies: [Company]) async {
        var removed = false
        if removable { removed = unlink(marker.path) == 0 || errno == ENOENT }
        guard noteIgnoredRestoreMarker(identity: identity, removed: removed) else { return }
        let now = clock()
        let all = (try? store.companies()) ?? companies
        for company in all {
            attempt {
                try store.appendEvent(ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .error,
                                                    text: String("restore marker ignored: \(reason)".prefix(300)), createdAt: now))
            }
        }
        log("restore marker ignored: \(reason)\(removed ? " (removed)" : "")")
    }

    private struct RestoreRecord: Sendable {
        var snapshot: String
        var notes: [String]
        /// Company id → the `mainCommit` the restored database recorded (nil when it recorded none).
        var mains: [String: String?]
    }

    private struct MainReading: Sendable {
        var company: Company
        var recorded: String?
        var head: String?
        var symbolic: Bool
        var adopt: Bool { recorded != nil && head == recorded && !symbolic }
    }

    private func takeUpRestore(nonce: String, marker: URL, companies: [Company], store: Store, blocking: Blocking,
                               hooks: [RestoreHooks.Handler]) async {
        let record: RestoreRecord?
        do {
            record = try await store.writer.read { db -> RestoreRecord? in
                guard try db.tableExists("restoreEvent"),
                      let row = try Row.fetchOne(db, sql: "SELECT snapshot, notes FROM restoreEvent WHERE nonce = ? AND consumedAt IS NULL",
                                                 arguments: [nonce]) else { return nil }
                var mains: [String: String?] = [:]
                for main in try Row.fetchAll(db, sql: "SELECT companyId, mainCommit FROM restoreMain WHERE nonce = ?", arguments: [nonce]) {
                    mains[main["companyId"] as String] = main["mainCommit"] as String?
                }
                let notes: String = row["notes"]
                return RestoreRecord(snapshot: row["snapshot"], notes: notes.split(whereSeparator: \.isNewline).map(String.init), mains: mains)
            }
        } catch {
            log("restore marker: cannot read the restore record: \(error)")     // left in place: the next tick tries again
            return
        }
        guard let record else {
            await ignoreRestoreMarker(marker, reason: "it names no restore this database recorded, or one already taken up",
                                      removable: true, identity: "nonce:\(nonce)", companies: companies)
            return
        }
        let restored = ((try? store.companies()) ?? companies).filter { record.mains.keys.contains($0.id) }
        let readings: [MainReading] = await blocking.run {
            restored.map { company in
                let recorded = record.mains[company.id] ?? nil
                let git = store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
                let head: String? = try? git.head(of: GitWorkspace.mainRef)
                // 3a's HEAD-symref invariant: a symbolic `main` is never the branch the engine recorded, whatever it points at.
                let symbolic = head != nil && (try? git.mainIsSymbolic()) != false
                return MainReading(company: company, recorded: recorded, head: head, symbolic: symbolic)
            }
        }
        let now = clock()
        let consumed: Bool
        do {
            consumed = try await store.writer.write { db -> Bool in
                try db.execute(sql: "UPDATE restoreEvent SET consumedAt = ? WHERE nonce = ? AND consumedAt IS NULL", arguments: [now, nonce])
                guard db.changesCount == 1 else { return false }
                for reading in readings {
                    if reading.adopt, let recorded = reading.recorded {
                        try store.finalizeMainCommit(db, companyId: reading.company.id, commit: recorded)
                        try store.resolveEngineAlerts(db, reasons: [Store.mainAlertReason(reading.company.id)], now: now)
                    } else {
                        // Only the restore's own record counts (not a pending head): the main guard compares git against it.
                        try db.execute(sql: "UPDATE company SET mainCommit = COALESCE(?, mainCommit), pendingMainCommit = NULL WHERE id = ?",
                                       arguments: [reading.recorded, reading.company.id])
                    }
                }
                return true
            }
        } catch {
            log("restore marker: cannot take up the restore: \(error)")          // left in place: the next tick tries again
            return
        }
        guard consumed else {
            await ignoreRestoreMarker(marker, reason: "it names a restore already taken up", removable: true,
                                      identity: "nonce:\(nonce)", companies: companies)
            return
        }
        unlink(marker.path)

        // A head other than the recorded one: 3a's reaction to `main` moved outside Brahma (owner alert; claims and merges held).
        let refused = readings.filter { !$0.adopt }
        if !refused.isEmpty {
            await blocking.run {
                for reading in refused {
                    guard let company = try? store.company(id: reading.company.id) else { continue }
                    let git = store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
                    do { try store.checkMain(company: company, git: git) } catch { /* the guard raised its alert, or git refused (its own) */ }
                }
            }
        }

        for reading in readings {
            let company = reading.company
            var failure: String?
            if reading.adopt {
                let event = RestoreEvent(companyId: company.id, companyName: company.name,
                                         workspace: URL(fileURLWithPath: company.workspacePath, isDirectory: true),
                                         mainHead: reading.head, snapshotName: record.snapshot)
                for hook in hooks {
                    do { try await hook(event) } catch { failure = failure ?? "a restore handler failed: \(error)" }
                }
            } else {
                let shown = reading.recorded.map { String($0.prefix(12)) } ?? "none"
                failure = "main is not the commit the restore recorded (\(shown)), so nothing was adopted; "
                    + "review main, then accept it (brahma main accept)"
            }
            let lines = record.notes.map { "restore: \($0)" }
                + [failure.map { "restored from \(record.snapshot); \($0)" } ?? "restored from \(record.snapshot); repos re-adopted"]
            for (index, line) in lines.enumerated() {
                let isOutcome = index == lines.count - 1
                attempt {
                    try store.appendEvent(ActivityEvent(companyId: company.id, agentId: nil, turnId: nil,
                                                        kind: isOutcome && failure == nil ? .work : .error,
                                                        text: String(line.prefix(300)), createdAt: now))
                }
            }
        }
    }
}

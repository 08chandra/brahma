import Foundation
import GRDB

extension Orchestrator {
    static let restoreTaskKey = "restore-marker"

    /// The restore-marker step: on the first tick that sees `<home>/run/restored-at`, for each company re-read git's `main`
    /// (through `GitWorkspace`/`GitCommand`, in a `Blocking` body), adopt it as the company's `mainCommit` (a restored database
    /// holds the head from the snapshot, which would read as "main changed outside Brahma"), run the registered
    /// `RestoreHooks.afterRestore` handlers, log activity and delete the marker. Never waits on git.
    func restoreMarkerTick(companies: [Company]) {
        let marker = BackupService.restoreMarker(paths: paths)
        guard gitTasks[Self.restoreTaskKey] == nil, FileManager.default.fileExists(atPath: marker.path) else { return }
        let (store, blocking, hooks) = (self.store, self.blocking, restoreHooks.afterRestore)
        spawnGit(Self.restoreTaskKey) { [self] in
            let text = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            let snapshot = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "a snapshot"
            let companies = (try? store.companies()) ?? companies
            let heads: [(company: Company, head: String?, error: String?)] = await blocking.run {
                companies.map { company in
                    let git = store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true),
                                                 companyId: company.id)
                    do { return (company, try git.head(of: GitWorkspace.mainRef), nil) } catch { return (company, nil, "\(error)") }
                }
            }
            let now = clock()
            for (company, head, error) in heads {
                var failure = error
                if let head {
                    do {
                        try await store.writer.write { db in
                            try store.finalizeMainCommit(db, companyId: company.id, commit: head)
                            try store.resolveEngineAlerts(db, reasons: [Store.mainAlertReason(company.id)], now: now)
                        }
                    } catch { failure = "\(error)" }
                }
                let event = RestoreEvent(companyId: company.id, companyName: company.name,
                                         workspace: URL(fileURLWithPath: company.workspacePath, isDirectory: true),
                                         mainHead: head, snapshotName: snapshot)
                for hook in hooks {
                    do { try await hook(event) } catch { failure = failure ?? "a restore handler failed: \(error)" }
                }
                attempt {
                    let line = failure.map { "restored from \(snapshot); \($0)" } ?? "restored from \(snapshot); repos re-adopted"
                    try store.appendEvent(ActivityEvent(companyId: company.id, agentId: nil, turnId: nil,
                                                        kind: failure == nil ? .work : .error, text: String(line.prefix(300)), createdAt: now))
                }
            }
            unlink(marker.path)
        }
    }
}

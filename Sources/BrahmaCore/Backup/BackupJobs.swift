import Foundation
import GRDB

/// What an `afterRestore` handler is told about one company once the engine has re-read its repository.
public struct RestoreEvent: Sendable {
    public let companyId: String
    public let companyName: String
    public let workspace: URL
    /// The commit `refs/heads/main` stands at in git now (nil when the repository has no main).
    public let mainHead: String?
    /// The snapshot file the database was restored from.
    public let snapshotName: String
}

/// Handlers the Orchestrator runs, per company, on the first tick that sees the restore marker (after it has re-adopted `main`
/// as the company's `mainCommit`). Task 4 registers "record the branch heads the engine expects".
public final class RestoreHooks: @unchecked Sendable {
    public typealias Handler = @Sendable (RestoreEvent) async throws -> Void
    private let lock = NSLock()
    private var handlers: [Handler] = []

    public init() {}

    public func register(afterRestore handler: @escaping Handler) {
        lock.withLock { handlers.append(handler) }
    }

    var afterRestore: [Handler] { lock.withLock { handlers } }
}

/// The engine's backup timer jobs (`backup.hourly`, `backup.repos`, `backup.home`).
enum BackupJobs {
    static func hourly(_ context: TimerContext) async throws {
        let store = context.store
        let service = BackupService(paths: context.paths, writer: store.writer)
        do {
            _ = try await context.blocking.tryRun { try service.snapshot(reason: .hourly) }
        } catch {
            fail(context, "database backup failed: \(error)")
        }
    }

    static func repos(_ context: TimerContext) async throws {
        let store = context.store
        let service = BackupService(paths: context.paths)
        do {
            let companies = try store.companies()
            let results = await context.blocking.run {
                service.bundleRepos(companies: companies) { company in
                    store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
                }
            }
            let names = Dictionary(uniqueKeysWithValues: companies.map { ($0.id, $0.name) })
            let failures = results.compactMap { r -> String? in
                if case .failed(let why) = r.outcome { return "\(names[r.companyId] ?? r.companyId): \(why)" }
                return nil
            }
            if !failures.isEmpty { fail(context, "repository backup failed for " + failures.joined(separator: "; ")) }
        } catch {
            fail(context, "repository backup failed: \(error)")
        }
    }

    /// The data-home snapshot (Task 13a): archives, transcripts, role cards and the rest of the home, hard-linked against the
    /// previous snapshot. Files that could not be copied are named in the owner notice; the snapshot is still kept.
    static func home(_ context: TimerContext) async throws {
        let paths = context.paths, now = context.now
        do {
            let result = try await context.blocking.tryRun { try HomeSnapshot.take(paths: paths, now: now) }
            if !result.problems.isEmpty {
                fail(context, "the data-home snapshot left out \(result.problems.count) file(s): "
                    + result.problems.prefix(3).joined(separator: "; "))
            }
        } catch {
            fail(context, "data-home backup failed: \(error)")
        }
    }

    /// `backup.targets` (Task 13b): syncs the backup set to every configured target. An unmounted folder is skipped with one notice a
    /// day; a failed or unavailable target is a failed job. Nothing configured: nothing to do.
    static func targets(_ context: TimerContext, tools: BackupTools = .system, hostname: String = BackupTargets.hostName()) async throws {
        let store = context.store, paths = context.paths, now = context.now
        do {
            let results = try await context.blocking.tryRun {
                try BackupTargets.syncAll(store: store, paths: paths, hostname: hostname, tools: tools, now: now)
            }
            let problems = results.compactMap { r -> String? in
                switch r.outcome {
                case .failed(let why), .unavailable(let why): return "\(r.target.summary): \(why)"
                case .synced, .skipped: return nil
                }
            }
            if !problems.isEmpty { fail(context, "off-machine backup failed for " + problems.joined(separator: "; ")) }
        } catch {
            fail(context, "off-machine backup failed: \(error)")
        }
    }

    /// A failed job writes activity (every company) and tells the owner.
    private static func fail(_ context: TimerContext, _ text: String) {
        let store = context.store
        let now = Store.now()
        try? store.writer.write { db in
            try Store.logTimerError(db: db, timer: context.timer, text: "\(context.timer.name): \(text)", now: now)
            try store.notifyOwner(db: db, companyId: context.timer.companyId, kind: .system, urgency: .normal,
                                  title: "Backup failed", body: text, now: now)
        }
    }
}

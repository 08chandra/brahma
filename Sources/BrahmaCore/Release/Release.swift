import Foundation
import GRDB

/// Why a smoke run of `main` exists: the engine's run after `main` moved, a release's own run (Task 7), or the owner's.
public enum MainSmokeReason: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case merge, release, manual
}

/// Where a smoke run is. `error` is no result at all (it could not run, or a newer run superseded it while queued); only
/// `passed` and `failed` say anything about `main`.
public enum MainSmokeStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case queued, running, passed, failed, error

    public var isFinished: Bool { self == .passed || self == .failed || self == .error }
}

/// One run of the company's smoke check (`company.smokeCheck`) on one commit of `main`, in a fresh `.git`-free engine export
/// (`EngineExport`, run id `smoke-<id>`). Written only by the engine (`Store.runSmoke`, the tick's "main smoke" step), never
/// by a tool. Uniqueness (PR-12): one `merge` run per commit (a partial unique index); `release` runs carry their
/// `releaseId`; every `manual` request is a new row, so an old result is never reused for a new question.
public struct MainSmokeRun: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mainSmokeRun"

    public var id: String
    public var companyId: String
    public var commit: String
    public var status: MainSmokeStatus
    public var exitCode: Int?
    /// The run's log under the data home (scrubbed of secrets once the run ends).
    public var outputPath: String?
    /// The redacted end of the output; agent-controlled text (`"superseded"` for a run a newer one replaced).
    public var outputTail: String?
    public var reason: MainSmokeReason
    public var releaseId: String?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), companyId: String, commit: String, status: MainSmokeStatus = .queued,
                exitCode: Int? = nil, outputPath: String? = nil, outputTail: String? = nil, reason: MainSmokeReason,
                releaseId: String? = nil, createdAt: Date, startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id; self.companyId = companyId; self.commit = commit; self.status = status; self.exitCode = exitCode
        self.outputPath = outputPath; self.outputTail = outputTail; self.reason = reason; self.releaseId = releaseId
        self.createdAt = createdAt; self.startedAt = startedAt; self.finishedAt = finishedAt
    }

    /// The export (and sandbox) run id of this smoke run.
    public var runId: String { "smoke-\(id)" }
    public var sha7: String { String(commit.prefix(7)) }
    /// `exit <n>` or `timed out` (a failed run's cause, as the owner reads it).
    public var failure: String { exitCode.map { "exit \($0)" } ?? "timed out" }
}

/// The release rules (Plan L). Task 6 adds the release types next to these.
public enum ReleasePolicy {
    public static let buildTimeout: Duration = .seconds(1800)
    public static let stepTimeout: Duration = .seconds(900)
    /// The main smoke's timeout default and ceiling are `CheckSpec`'s (600 s / 3600 s).
    public static let smokeTimeoutDefault = 600
    public static let smokeTimeoutMax = 3600

    static let noSmokeCheck = "set_smoke_check first; deploys need a smoke check on main"
    static let superseded = "superseded"
    static let engineStopped = "engine stopped"
    static let engineRestarted = "engine restarted"

    /// `^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$`.
    public static func validVersion(_ v: String) -> Bool {
        v.range(of: "^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$", options: .regularExpression) != nil
    }

    /// Whether `main` at `commit` may be deployed: only when the company has a smoke check and the latest finished
    /// (`passed` or `failed`) `merge`, `manual` or `release` run at `commit` passed. Otherwise the reason, exactly one of
    /// `"set_smoke_check first; deploys need a smoke check on main"`, `"main is red: the smoke check failed at <sha7> (<exit
    /// n|timed out>)"` or `"the smoke check has not run on main <sha7> yet"`.
    public static func mainIsGreen(store: Store, company: Company, at commit: String) throws -> (green: Bool, reason: String?) {
        guard company.smokeCheck != nil else { return (false, noSmokeCheck) }
        let sha7 = String(commit.prefix(7))
        guard let last = try store.latestResult(companyId: company.id, commit: commit) else {
            return (false, "the smoke check has not run on main \(sha7) yet")
        }
        if last.status == .passed { return (true, nil) }
        return (false, "main is red: the smoke check failed at \(sha7) (\(last.failure))")
    }
}

/// What a smoke run executes through (PR-5): the platform sandbox, with a check-shaped policy, or, for a Full company whose
/// smoke-check setter's role runs Full too, the unsandboxed runner (as its checks would). Plus where the logs go and the
/// environment the run's is built from (`ChildEnvironment`, purpose `.check`).
public struct SmokeChecks: Sendable {
    public var sandbox: any SandboxedRunner
    public var unsandboxed: any SandboxedRunner
    public var paths: BrahmaPaths
    public var environment: [String: String]
    /// Test seam: called by `Store.runSmoke` right after its insert-and-claim write, before the export (nil in production).
    var afterClaim: (@Sendable (MainSmokeRun) -> Void)? = nil

    public init(sandbox: any SandboxedRunner, unsandboxed: any SandboxedRunner = UnsandboxedPreviewRunner(), paths: BrahmaPaths,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.sandbox = sandbox; self.unsandboxed = unsandboxed; self.paths = paths; self.environment = environment
    }

    /// The smoke run's log: `<home>/companies/<companyId>/smoke-output/<id>.log` (the data home, like check output).
    func outputURL(_ run: MainSmokeRun) -> URL {
        paths.companyDir(run.companyId).appending(path: "smoke-output/\(run.id).log")
    }
}

/// One smoke run at a time per company (PR-36): the tick's queued runs and a release's own smoke (Task 7) share this slot.
public actor SmokeSlots {
    private var busy = Set<String>()
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Whether a smoke of `companyId` holds the slot now.
    public func isBusy(_ companyId: String) -> Bool { busy.contains(companyId) }

    /// Runs `body` holding `companyId`'s slot, waiting for it first.
    public func withSlot<T: Sendable>(_ companyId: String, _ body: @Sendable () async -> T) async -> T {
        await acquire(companyId)
        defer { release(companyId) }
        return await body()
    }

    /// `withSlot` for a body that throws (the slot is released either way).
    public func withSlot<T: Sendable>(_ companyId: String, _ body: @Sendable () async throws -> T) async throws -> T {
        await acquire(companyId)
        defer { release(companyId) }
        return try await body()
    }

    private func acquire(_ companyId: String) async {
        if !busy.contains(companyId) { busy.insert(companyId); return }
        await withCheckedContinuation { waiters[companyId, default: []].append($0) }
    }

    private func release(_ companyId: String) {
        if var queue = waiters[companyId], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[companyId] = queue.isEmpty ? nil : queue
            next.resume()            // the slot passes straight to the next waiter
        } else {
            busy.remove(companyId)
        }
    }
}

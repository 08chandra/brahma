import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The owner's emergency stop (Task 7c, `v5-stop`): while the row exists nothing runs in any company. The engine checks it first
/// in every tick (and every running turn's supervision polls it each second); `brahma stop` also signals the recorded turn
/// processes itself, so a wedged engine cannot keep agents running.
public struct EngineStopRow: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "engineStop"

    var id: Int = 1
    public var since: Date
    /// Who pressed it: `owner`, `cli` or `app`.
    public var by: String
    public var note: String?

    public init(since: Date, by: String, note: String?) {
        self.since = since; self.by = by; self.note = note
    }
}

/// What a stop reaches beyond turns and checks: previews, deploys, merge queues, browsers and connectors register one of these
/// with the orchestrator (`Orchestrator.init(stopObservers:)`). `stopAll` runs once per stop.
public protocol EmergencyStopObserver: Sendable {
    func stopAll(reason: String) async
}

/// The owner's stop was seen right before a merge moved a ref (Task 7c fix round 1, S15): nothing was moved, and the merge is
/// put back in its queue, never counted against the item or the company.
public struct StoppedByOwner: Error, Equatable, CustomStringConvertible {
    public init() {}
    public var description: String { "stopped by the owner" }
}

public enum EmergencyStopError: Error, Equatable, CustomStringConvertible {
    case invalidActor(String)
    public var description: String {
        switch self {
        case .invalidActor(let by): "a stop is made by the owner, the CLI or the app, not \(by)"
        }
    }
}

extension Store {
    /// Who may record a stop (owner paths only: the CLI under `requireOwnerShell` and the app; never `CompanyTools`).
    public static let stopActors: Set<String> = ["owner", "cli", "app"]
    static let maxStopNote = 500

    /// Stops everything. Idempotent: an existing stop is kept as it is (its time and author) and returned.
    @discardableResult
    public func emergencyStop(note: String?, by: String, now: Date) throws -> EngineStopRow {
        guard Self.stopActors.contains(by) else { throw EmergencyStopError.invalidActor(by) }
        let note = note.map { String($0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").prefix(Self.maxStopNote)) }
            .flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return try writer.write { db in
            if let current = try EngineStopRow.fetchOne(db, key: 1) { return current }
            let row = EngineStopRow(since: now, by: by, note: note)
            try row.insert(db)
            for c in try Company.fetchAll(db) {
                try ActivityEvent(companyId: c.id, agentId: nil, turnId: nil, kind: .error,
                                  text: "everything stopped by the owner", createdAt: now).insert(db)
            }
            return row
        }
    }

    /// Ends the stop. Returns whether there was one.
    @discardableResult
    public func resumeAfterStop(now: Date) throws -> Bool {
        try writer.write { db in
            guard try EngineStopRow.fetchOne(db, key: 1) != nil else { return false }
            try db.execute(sql: "DELETE FROM engineStop WHERE id = 1")
            for c in try Company.fetchAll(db) {
                try ActivityEvent(companyId: c.id, agentId: nil, turnId: nil, kind: .usage,
                                  text: "resumed by the owner after a stop", createdAt: now).insert(db)
            }
            return true
        }
    }

    public func engineStopped() throws -> EngineStopRow? {
        try writer.read { db in try EngineStopRow.fetchOne(db, key: 1) }
    }

    /// In-transaction `engineStopped` (nil on a database older than `v5-stop`).
    static func engineStopped(_ db: Database) throws -> EngineStopRow? {
        guard try db.tableExists("engineStop") else { return nil }
        return try EngineStopRow.fetchOne(db, key: 1)
    }
}

public enum EmergencyStop {
    /// SIGTERM, then SIGKILL after this many awake seconds (as a turn's own cancellation).
    public static let grace: TimeInterval = 5
    /// How often a running turn's supervision re-reads the stop.
    public static let pollInterval: Duration = .seconds(1)
    public static let confirmText = "Stop every agent, check, preview and deploy in all companies now? Nothing runs until you resume."
    public static let bannerText = "Everything is stopped. Resume when you're ready."
    public static let buttonTitle = "STOP EVERYTHING"

    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// `brahma status`'s first line while stopped.
    public static func statusLine(_ row: EngineStopRow, timeZone: TimeZone) -> String {
        "STOPPED by the owner since \(clock(row.since, timeZone: timeZone))"
    }

    /// The stall explainer's first reason while stopped.
    public static func stallReason(since: Date, timeZone: TimeZone) -> String {
        "stopped by the owner since \(clock(since, timeZone: timeZone))"
    }

    /// What signalling came to: the groups sent SIGTERM, and those still alive after the grace that were sent SIGKILL.
    public struct Signalled: Equatable, Sendable {
        public var terminated: [Int32] = []
        public var killed: [Int32] = []

        public init(terminated: [Int32] = [], killed: [Int32] = []) {
            self.terminated = terminated
            self.killed = killed
        }
    }

    /// The live (non-zombie) processes of the owner's own user in group `pgid`, never this process's own group.
    static func liveMembers(of pgid: Int32, in table: [ProcessEntry]) -> [ProcessEntry] {
        guard pgid > 1, pgid != getpgrp() else { return [] }
        let me = getpid(), uid = getuid()
        return table.filter { $0.pgid == pgid && $0.uid == uid && !$0.isZombie && $0.pid != me }
    }

    /// Sends SIGTERM to every group that still has a live process of this user, waits up to `grace` awake seconds for them to
    /// go, then SIGKILLs what is left. A group with nobody alive in it (a stale pid) is never signalled. Blocking.
    public static func signalGroups(_ groups: Set<Int32>, grace: TimeInterval = grace,
                                    uptime: () -> TimeInterval = { AwakeTime.uptime() },
                                    pause: () -> Void = { usleep(20_000) }) -> Signalled {
        var out = Signalled()
        guard !groups.isEmpty else { return out }
        let table = ProcessTable.snapshot()
        for g in groups.sorted() where !liveMembers(of: g, in: table).isEmpty {
            if killpg(g, SIGTERM) == 0 { out.terminated.append(g) }
        }
        guard !out.terminated.isEmpty else { return out }
        let deadline = uptime() + grace
        var alive = out.terminated
        while true {
            let now = ProcessTable.snapshot()
            alive = alive.filter { !liveMembers(of: $0, in: now).isEmpty }
            if alive.isEmpty || uptime() >= deadline { break }
            pause()
        }
        for g in alive where killpg(g, SIGKILL) == 0 { out.killed.append(g) }
        return out
    }

    /// The groups of every check and merge child the engine recorded at spawn (`ChildGroups`, under the data home's
    /// `run/children`; only leaders whose start time still matches), and of every preview server Plan L's `previewState`
    /// records (`previewGroups`, L-5lite-A). The database's in-progress turn rows are not a source (Task 9c fix round 2): a row
    /// carries no start time, so a pid reused after its turn started would pass any one-sided check; the turns' leaders come
    /// from the runner's records instead (`Store.recordedTurnLeaders`, in `engineGroups`), which hold the exact start.
    public static func recordedGroups(store: Store) -> Set<Int32> {
        var groups = Set<Int32>()
        if let home = store.dataHome {
            groups.formUnion(ChildGroups.liveLeaders(in: ChildGroups.directory(runDir: home.appending(path: "run", directoryHint: .isDirectory))))
        }
        groups.formUnion(previewGroups(store: store))
        return groups
    }

    /// Every process group the engine recorded, for the stop paths (Task 9c fix round 1, controller ruling 1): `recordedGroups`
    /// plus the turn leaders the runner recorded at spawn under `<runDir>/turns` (`Store.recordedTurnLeaders`: every production
    /// turn is recorded there with its exact start, and a record still names a `claude` whose turn the engine already recorded
    /// `interrupted` but which is winding down). Every source matches a recorded start time exactly.
    public static func engineGroups(store: Store, paths: BrahmaPaths) -> Set<Int32> {
        recordedGroups(store: store).union(Store.recordedTurnLeaders(paths: paths))
    }

    /// The one stop every path uses: STOP EVERYTHING, `brahma stop`, a quit whose bound passed, and the second quit signal
    /// (`EngineShutdown.force`) all signal exactly `engineGroups` (SIGTERM, `grace`, SIGKILL; `grace` 0 is SIGKILL right behind
    /// SIGTERM). Nothing the engine did not record is ever signalled. Blocking.
    public static func signalEngineGroups(store: Store, paths: BrahmaPaths, grace: TimeInterval = grace) -> Signalled {
        signalGroups(engineGroups(store: store, paths: paths), grace: grace)
    }

    /// The groups of the preview servers recorded `building`, `starting` or `running`, each only while its pid still leads
    /// its own group of ours with a start time inside the record (`PreviewRunner.orphanGroup`, PR-4): a recycled pid is never
    /// signalled. What reaches previews when the engine itself cannot (`brahma stop`, the app's STOP EVERYTHING).
    static func previewGroups(store: Store) -> Set<Int32> {
        var groups = Set<Int32>()
        for company in (try? store.companies()) ?? [] {
            for state in ((try? store.previewStates(companyId: company.id)) ?? [:]).values
            where [.building, .starting, .running].contains(state.status) {
                if let pid = state.pid, PreviewRunner.orphanGroup(pid: pid, startedAt: state.startedAt, updatedAt: state.updatedAt) {
                    groups.insert(pid)
                }
            }
        }
        return groups
    }
}

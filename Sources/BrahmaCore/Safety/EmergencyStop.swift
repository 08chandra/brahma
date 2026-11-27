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

    /// What signalling came to: the groups sent SIGTERM, those still alive after the grace that were sent SIGKILL, and what
    /// the stop could not read (`problems`: a source of recorded groups, the process table), so the owner learns which
    /// processes it could not vouch for (`brahma stop`, STOP EVERYTHING; S4 fix round 1, I1/I2/M8). Everything else was still
    /// signalled.
    public struct Signalled: Equatable, Sendable {
        public var terminated: [Int32] = []
        public var killed: [Int32] = []
        public var problems: [String] = []

        public init(terminated: [Int32] = [], killed: [Int32] = [], problems: [String] = []) {
            self.terminated = terminated
            self.killed = killed
            self.problems = problems
        }
    }

    /// The problem a stop reports when the process table could not be read.
    static let tableUnreadableProblem = "the process table could not be read: every recorded group whose leader still leads it "
        + "was signalled, and SIGKILLed after the grace"

    /// The live (non-zombie) processes of the owner's own user in group `pgid`, never this process's own group.
    static func liveMembers(of pgid: Int32, in table: [ProcessEntry]) -> [ProcessEntry] {
        guard pgid > 1, pgid != getpgrp() else { return [] }
        let me = getpid(), uid = getuid()
        return table.filter { $0.pgid == pgid && $0.uid == uid && !$0.isZombie && $0.pid != me }
    }

    /// Whether `pgid` is a group of this user's that its leader still leads (read on its own, `ProcessTable.entry`): how the
    /// stop decides without a process table. Never this process's own group.
    static func leaderStillLeads(_ pgid: Int32) -> Bool {
        guard pgid > 1, pgid != getpgrp(), let leader = ProcessTable.entry(pgid) else { return false }
        return leader.pgid == pgid && leader.uid == getuid() && !leader.isZombie && leader.pid != getpid()
    }

    /// Sends SIGTERM to every group that still has a live process of this user, waits up to `grace` awake seconds for them to
    /// go, then SIGKILLs what is left. A group with nobody alive in it (a stale pid) is never signalled. Blocking.
    /// A process table that cannot be read is never "nothing runs" (S4 fix round 1, I2): every group whose leader still leads
    /// it (`leaderStillLeads`) is signalled, the wait cannot tell when it is gone (so it runs to the grace and SIGKILLs), and
    /// `problems` says so. `table` is injectable for tests.
    public static func signalGroups(_ groups: Set<Int32>, grace: TimeInterval = grace,
                                    uptime: () -> TimeInterval = { AwakeTime.uptime() },
                                    pause: () -> Void = { usleep(20_000) },
                                    table: () -> [ProcessEntry]? = ProcessTable.snapshot) -> Signalled {
        var out = Signalled()
        guard !groups.isEmpty else { return out }
        var blind = false
        /// Whether group `g` still has a live process of ours; without a table, whether its leader still leads it.
        func live(_ g: Int32, in entries: [ProcessEntry]?) -> Bool {
            guard let entries else { blind = true; return leaderStillLeads(g) }
            return !liveMembers(of: g, in: entries).isEmpty
        }
        let first = table()
        for g in groups.sorted() where live(g, in: first) {
            if killpg(g, SIGTERM) == 0 { out.terminated.append(g) }
        }
        if !out.terminated.isEmpty {
            let deadline = uptime() + grace
            var alive = out.terminated
            while true {
                // Without a table a group whose leader went may still have members: it counts as alive until the grace ends.
                if let now = table() {
                    alive = alive.filter { !liveMembers(of: $0, in: now).isEmpty }
                } else {
                    blind = true
                }
                if alive.isEmpty || uptime() >= deadline { break }
                pause()
            }
            for g in alive where killpg(g, SIGKILL) == 0 { out.killed.append(g) }
        }
        if blind { out.problems.append(tableUnreadableProblem) }
        return out
    }

    /// The groups of every check and merge child the engine recorded at spawn (`ChildGroups`, under the data home's
    /// `run/children`; only leaders whose start time still matches), and of every preview server Plan L's `previewState`
    /// records (`previewGroups`, L-5lite-A). The database's in-progress turn rows are not a source (Task 9c fix round 2): a row
    /// carries no start time, so a pid reused after its turn started would pass any one-sided check; the turns' leaders come
    /// from the runner's records instead (`Store.recordedTurnLeaders`, in `engineGroups`), which hold the exact start.
    public static func recordedGroups(store: Store) -> Set<Int32> {
        gatherRecorded(store: store).groups
    }

    /// `recordedGroups`, with what could not be read (the child-group records, the preview states; S4 fix round 1, I1/M8).
    static func gatherRecorded(store: Store) -> (groups: Set<Int32>, problems: [String]) {
        var groups = Set<Int32>()
        var problems: [String] = []
        if let home = store.dataHome {
            let children = ChildGroups.liveLeadersReporting(in: ChildGroups.directory(runDir: home.appending(path: "run", directoryHint: .isDirectory)))
            groups.formUnion(children.leaders)
            problems += children.problems
        }
        let previews = gatherPreviewGroups(store: store)
        groups.formUnion(previews.groups)
        problems += previews.problems
        return (groups, problems)
    }

    /// Every process group the engine recorded, for the stop paths (Task 9c fix round 1, controller ruling 1): `recordedGroups`
    /// plus the turn leaders the runner recorded at spawn under `<runDir>/turns` (`Store.recordedTurnLeaders`: every production
    /// turn is recorded there with its exact start, and a record still names a `claude` whose turn the engine already recorded
    /// `interrupted` but which is winding down). Every source matches a recorded start time exactly.
    public static func engineGroups(store: Store, paths: BrahmaPaths) -> Set<Int32> {
        gatherEngine(store: store, paths: paths).groups
    }

    /// `engineGroups`, with what could not be read.
    static func gatherEngine(store: Store, paths: BrahmaPaths) -> (groups: Set<Int32>, problems: [String]) {
        let recorded = gatherRecorded(store: store)
        return (recorded.groups.union(Store.recordedTurnLeaders(paths: paths)), recorded.problems)
    }

    /// The one stop every path uses: STOP EVERYTHING, `brahma stop`, a quit whose bound passed, and the second quit signal
    /// (`EngineShutdown.force`) all signal exactly `engineGroups` (SIGTERM, `grace`, SIGKILL; `grace` 0 is SIGKILL right behind
    /// SIGTERM). Nothing the engine did not record is ever signalled. Blocking. What could not be read (a source of recorded
    /// groups, the process table) is in `problems`; everything else is still signalled.
    public static func signalEngineGroups(store: Store, paths: BrahmaPaths, grace: TimeInterval = grace) -> Signalled {
        let gathered = gatherEngine(store: store, paths: paths)
        var out = signalGroups(gathered.groups, grace: grace)
        out.problems = gathered.problems + out.problems
        return out
    }

    /// The groups of the preview servers recorded `building`, `starting` or `running`, each only while its pid still leads
    /// its own group of ours with exactly the start time recorded at the spawn (`PreviewRunner.orphanGroup`, final review
    /// I2): a recycled pid, or a record without a start (an older engine's), is never signalled. What reaches previews when
    /// the engine itself cannot (`brahma stop`, the app's STOP EVERYTHING).
    static func previewGroups(store: Store) -> Set<Int32> {
        gatherPreviewGroups(store: store).groups
    }

    /// `previewGroups`, with what could not be read: the company list, or one company's preview states (I1). The other
    /// companies' previews are still found.
    static func gatherPreviewGroups(store: Store) -> (groups: Set<Int32>, problems: [String]) {
        var groups = Set<Int32>()
        let companies: [Company]
        do { companies = try store.companies() } catch {
            return ([], ["the companies could not be read, so no preview server was found to stop: \(error)"])
        }
        var problems: [String] = []
        for company in companies {
            let states: [String: PreviewState]
            do { states = try store.previewStates(companyId: company.id) } catch {
                problems.append("the preview servers of \(Store.flat(company.name, max: 80)) could not be read: \(error)")
                continue
            }
            for state in states.values where [.building, .starting, .running].contains(state.status) {
                if let pid = state.pid, PreviewRunner.orphanGroup(pid: pid, pidStart: state.pidStart) {
                    groups.insert(pid)
                }
            }
        }
        return (groups, problems)
    }
}

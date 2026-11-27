import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Process lifetime of a turn (5-lite Task 1b, binding from the Task 1a re-review): no process of a turn may survive into the
// next turn's scope computation or spawn. A leftover process keeps the earlier turn's (possibly wider) sandbox and could plant
// links in the agent's own places between the next scope's computation and its spawn. So each turn's `claude` is started as
// the leader of its own session and process group, every process the turn starts carries a per-turn marker in its
// environment, the engine watches the turn's descendants while it runs, and when it ends every process of the turn is killed
// (the group, the session, every watched descendant, every process carrying the marker) before its leader is reaped.

/// Every process of one turn: its leader's group and session, the descendants seen while it ran, and whatever carries its
/// marker. Watching runs on its own thread from spawn until the sweep.
final class TurnContainment: @unchecked Sendable {
    /// The variable every process of the turn inherits (unless it clears it): `BRAHMA_TURN_MARK=<random>`.
    static let markerVariable = "BRAHMA_TURN_MARK"
    static let pollInterval: TimeInterval = 0.05

    let leader: pid_t
    let marker: String
    private let uid = getuid()
    private let me = getpid()
    private let since: Double
    var sinceStamp: Double { since }
    private let lock = NSLock()
    /// pid → start time of every descendant seen (a pid whose start time changed is someone else's now).
    private var tracked: [pid_t: Double] = [:]
    /// The unique ids (`ProcessTable.lineage`) of the leader and of every tracked process. A process whose parent's unique id
    /// is here was forked by the turn, even after that parent exited and it was reparented to launchd (Ruling S5-5). Never
    /// pruned: unique ids are never reused.
    private var lineage: Set<UInt64> = []
    /// Lineage reads by (pid, start), so a process is asked once rather than at every poll. An entry goes when its process
    /// leaves the table. A read that failed is not kept (it is asked again).
    private var lineageReads: [ProcessKey: (unique: UInt64, parent: UInt64)] = [:]
    private struct ProcessKey: Hashable {
        let pid: pid_t
        let start: Double
    }
    private var stopFlag = false
    private var watching = false
    private let watcherDone = DispatchSemaphore(value: 0)

    /// Sandboxed turns: what the turn's sandbox looks like (`SandboxProbe`).
    let probe: SandboxProbe?

    init(leader: pid_t, markerValue: String, since: Double, probe: SandboxProbe? = nil) {
        self.leader = leader
        self.marker = "\(Self.markerVariable)=\(markerValue)"
        self.since = since
        self.probe = probe
        // Built right after the spawn, while the leader is unreaped: its pid is still its own.
        if let ids = ProcessTable.lineage(leader) { lineage.insert(ids.unique) }
    }

    func startWatching() {
        lock.withLock { watching = true }
        Thread.detachNewThread { [self] in
            while !lock.withLock({ stopFlag }) {
                // A poll whose table could not be read observes nothing; the sweep decides on its own reads.
                if let table = ProcessTable.snapshot() { observe(table) }
                Thread.sleep(forTimeInterval: Self.pollInterval)
            }
            watcherDone.signal()
        }
    }

    private func stopWatching() {
        let wait = lock.withLock { () -> Bool in
            defer { stopFlag = true; watching = false }
            return watching
        }
        if wait { watcherDone.wait() }
    }

    /// Adds to the tracked set every process descended from the leader or a tracked one (or in the leader's group or
    /// session). Descent is read two ways: the current ppid, and, for a process started no earlier than the turn, the
    /// unique id of the process that forked it (`ProcessTable.lineage`). The second still holds once the parent has exited
    /// and the process was reparented to launchd, which is what a `setsid`'d escapee looks like when its parent exited
    /// between two polls (Ruling S5-5).
    func observe(_ table: [ProcessEntry]) {
        lock.withLock {
            var starts: [pid_t: Double] = [:]
            for p in table where starts[p.pid] == nil { starts[p.pid] = p.start }
            tracked = tracked.filter { starts[$0.key] == $0.value }
            lineageReads = lineageReads.filter { starts[$0.key.pid] == $0.key.start }
            var changed = true
            while changed {
                changed = false
                for p in table where p.uid == uid && p.pid != leader && p.pid != me && tracked[p.pid] == nil && !p.isZombie {
                    let ids = p.start >= since ? lineageOf(p) : nil
                    var forkedByTheTurn = false
                    if let ids, lineage.contains(ids.parent) { forkedByTheTurn = true }
                    if forkedByTheTurn || p.ppid == leader || tracked[p.ppid] != nil || p.pgid == leader
                        || ProcessTable.session(p) == leader {
                        tracked[p.pid] = p.start
                        if let ids { lineage.insert(ids.unique) }
                        changed = true
                    }
                }
            }
        }
    }

    /// `p`'s lineage, read once per (pid, start). The caller holds `lock`.
    private func lineageOf(_ p: ProcessEntry) -> (unique: UInt64, parent: UInt64)? {
        let key = ProcessKey(pid: p.pid, start: p.start)
        if let known = lineageReads[key] { return known }
        guard let ids = ProcessTable.lineage(p.pid) else { return nil }
        // Read after the ids. The same start time means the pid was still `p` when they were read, not a reuse.
        guard ProcessTable.entry(p.pid)?.start == p.start else { return nil }
        lineageReads[key] = ids
        return ids
    }

    /// The processes of the turn alive in `table` (never the leader, which the caller reaps, nor this process).
    func members(_ table: [ProcessEntry]) -> [ProcessEntry] {
        let known = lock.withLock { tracked }
        return table.filter { p in
            guard p.pid != leader, p.pid != me, p.uid == uid, !p.isZombie else { return false }
            if known[p.pid] == p.start || p.pgid == leader || ProcessTable.session(p) == leader { return true }
            if let probe, probe.classify(p.pid) == .mine { return true }
            // The environment is the last resort: macOS no longer shows other processes' environments (Linux does).
            return p.start >= since && (ProcessTable.environment(p.pid)?.contains(marker) ?? false)
        }
    }

    /// Stops watching and kills (SIGKILL) every process of the turn, round after round, until none is left or `rounds` pass.
    /// Each kill re-reads the process first, so a pid that was reused meanwhile is left alone. Returns what is still alive.
    /// A process table that cannot be read rules nothing out: `[-1]`, inconclusive (S4 fix round 1, I2), as `finish` and
    /// `TurnRecords.reap` read it. `snapshot` is injectable for tests.
    func sweep(rounds: Int = 50, snapshot: () -> [ProcessEntry]? = ProcessTable.snapshot) -> [pid_t] {
        stopWatching()
        var left: [ProcessEntry] = []
        for _ in 0..<rounds {
            guard let table = snapshot() else { return [-1] }
            observe(table)
            left = members(table)
            if left.isEmpty { return [] }
            for p in left where ProcessTable.entry(p.pid)?.start == p.start { kill(p.pid, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard let table = snapshot() else { return [-1] }
        return members(table).map(\.pid)
    }
}

/// What waiting for an agent's earlier turns came to: what it killed, and what would not die (or could not be accounted for).
public struct TurnLeftovers: Equatable, Sendable {
    public var killed: [Int32]
    public var survivors: [Int32]

    public init(killed: [Int32] = [], survivors: [Int32] = []) { self.killed = killed; self.survivors = survivors }
}

/// One turn's leader as the engine recorded it at spawn (`<runDir>/turns/<agentId>.turn`, 0600): what a restarted engine
/// needs to kill whatever is left of the turn (B-I1). `machMarker` is the sandboxed turn's marker.
struct TurnRecord: Codable, Equatable, Sendable {
    var leader: pid_t
    var leaderStart: Double
    var since: Double
    var machMarker: String?
}

/// The records of every agent's turns that may still have processes: written at spawn, removed once the turn left nothing.
enum TurnRecords {
    static func file(agentId: String, in dir: URL) throws -> URL {
        guard agentId.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            throw SandboxError.invalidPath(agentId)
        }
        return dir.appending(path: "\(agentId).turn")
    }

    /// A record file that cannot be read (not a regular file, not the format): moved aside to `quarantinedTo` so it cannot
    /// refuse the agent's turns forever; the caller tells the owner (fix round 2, B-N5).
    struct Corrupt: Error, CustomStringConvertible {
        let path: String
        let quarantinedTo: String
        var description: String { "the turn record \(path) could not be read; it was moved to \(quarantinedTo)" }
    }

    static func load(agentId: String, in dir: URL) throws -> [TurnRecord] {
        let url = try file(agentId: agentId, in: dir)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return [] }
        if st.st_mode & S_IFMT == S_IFREG, let data = FileManager.default.contents(atPath: url.path),
           let records = try? JSONDecoder().decode([TurnRecord].self, from: data) {
            return records
        }
        let aside = dir.appending(path: "quarantine/\(url.lastPathComponent).\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: aside.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A rename moves the entry itself (a link stays a link; nothing is followed).
        guard rename(url.path, aside.path) == 0 else { throw SandboxError.linkedPath(url.path) }
        throw Corrupt(path: url.path, quarantinedTo: aside.path)
    }

    static func save(_ records: [TurnRecord], agentId: String, in dir: URL) throws {
        let url = try file(agentId: agentId, in: dir)
        if records.isEmpty { unlink(url.path); return }
        try SettingsFile.writePrivate(try JSONEncoder().encode(records), to: url)
    }

    static func add(_ record: TurnRecord, agentId: String, in dir: URL) throws {
        try save(try load(agentId: agentId, in: dir) + [record], agentId: agentId, in: dir)
    }

    static func replace(_ old: TurnRecord, with new: TurnRecord?, agentId: String, in dir: URL) throws {
        var all = try load(agentId: agentId, in: dir).filter { $0 != old }
        if let new { all.append(new) }
        try save(all, agentId: agentId, in: dir)
    }

    /// The agents with records in `dir`.
    static func agentIds(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).compactMap { name in
            name.hasSuffix(".turn") ? String(name.dropLast(5)) : nil
        }
    }

    /// Kills whatever is left of the agent's recorded turns: the leader itself (when its start time still matches), every owner
    /// process in its session or group started no earlier than it (a pid in use cannot become a group or session id), and, for a
    /// sandboxed turn, every process whose sandbox carries its marker (`SandboxSweep`, fail closed). A record is forgotten only
    /// once nothing of it is left. Blocking.
    /// `snapshot` is injectable for tests. Fails closed (fix round 2, B-N2): a table that cannot be read (nil, empty, or
    /// without this very process) rules nothing out: a survivor (`-1`), and the record is kept.
    static func reap(agentId: String, in dir: URL, snapshot: @escaping () -> [ProcessEntry]? = ProcessTable.snapshot) throws -> TurnLeftovers {
        var out = TurnLeftovers()
        var kept: [TurnRecord] = []
        let me = getpid(), uid = getuid()
        for record in try load(agentId: agentId, in: dir) {
            var killed = Set<pid_t>()
            var unreadable = false
            // A pid in use cannot become a group or session id, so while the old leader's pid is held by ANOTHER process (a
            // different start time), every group or session match is that process's, never the old turn's (fix round 2, B-N1).
            let reused = ProcessTable.entry(record.leader).map { $0.start != record.leaderStart } ?? false
            func members() -> [ProcessEntry] {
                guard let table = snapshot(), table.contains(where: { $0.pid == me }) else { unreadable = true; return [] }
                return table.filter { p in
                    guard p.uid == uid, p.pid != me, !p.isZombie else { return false }
                    if p.pid == record.leader { return p.start == record.leaderStart }
                    guard record.leader > 0, !reused, p.start >= record.leaderStart else { return false }
                    return p.pgid == record.leader || ProcessTable.session(p) == record.leader
                }
            }
            for _ in 0..<50 {
                let left = members()
                if left.isEmpty { break }
                for p in left where ProcessTable.entry(p.pid)?.start == p.start { kill(p.pid, SIGKILL); killed.insert(p.pid) }
                Thread.sleep(forTimeInterval: 0.02)
            }
            var survivors = members().map(\.pid)
            if let marker = record.machMarker {
                let swept = SandboxSweep.run(probe: SandboxProbe(machMarker: marker), since: record.since, snapshot: snapshot)
                killed.formUnion(swept.killed)
                survivors += swept.survivors
                if swept.tableUnreadable { unreadable = true }
            }
            if unreadable { survivors.append(-1) }
            out.killed += killed.sorted()
            out.survivors += survivors
            if !survivors.isEmpty { kept.append(record) }
        }
        try save(kept, agentId: agentId, in: dir)
        return out
    }
}

/// The turns each agent has in flight, and what a finished turn could not kill. A new turn of the agent claims its slot here
/// first: "nothing of this agent running, then begin" in one step (M3).
final class TurnRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Set<String> = []
    private var survivors: [String: [ProcessEntry]] = [:]

    /// Waits (on an awake-time deadline, and never past a cancellation) until no turn of the agent is in flight, then marks
    /// one in flight. Throws `TurnError.earlierTurnInFlight` on the deadline, `CancellationError` when cancelled.
    func claim(_ agentId: String, deadline: Duration) async throws {
        let end = AwakeTime.deadline(after: deadline)
        while true {
            if lock.withLock({ running.insert(agentId).inserted }) { return }
            try await pause(until: end)
        }
    }

    func end(_ agentId: String, survivors left: [ProcessEntry]) {
        lock.withLock {
            running.remove(agentId)
            if left.isEmpty { survivors[agentId] = nil } else { survivors[agentId, default: []] += left }
        }
    }

    private func pause(until end: SuspendingClock.Instant) async throws {
        try Task.checkCancellation()
        // The earlier turn's slot is still held: it has not ended, so there is no pid to name (it reported "(pid )" before).
        guard AwakeTime.now < end else {
            throw TurnError.earlierTurnInFlight(waitedSeconds: Int(ClaudeProcessRunner.turnWaitDeadline.components.seconds))
        }
        try await Task.sleep(for: .milliseconds(20))
    }

    /// Waits until no turn of the agent is in flight (their sweeps done; fail closed on the deadline or a cancellation), then
    /// kills what is left of its earlier turns: what an in-flight sweep could not kill, and (`records`) whatever a recorded
    /// turn of this or an earlier engine left. Returns what it killed and what is still alive.
    func waitUntilGone(_ agentId: String, records: URL?, deadline: Duration) async throws -> TurnLeftovers {
        let end = AwakeTime.deadline(after: deadline)
        while lock.withLock({ running.contains(agentId) }) { try await pause(until: end) }
        var out = TurnLeftovers()
        let left = lock.withLock { survivors[agentId] ?? [] }
        var alive: [ProcessEntry] = []
        for p in left {
            guard let now = ProcessTable.entry(p.pid), now.start == p.start, !now.isZombie else { continue }
            kill(p.pid, SIGKILL)
            out.killed.append(p.pid)
            alive.append(p)
        }
        if !alive.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        let still = alive.filter { p in ProcessTable.entry(p.pid).map { $0.start == p.start && !$0.isZombie } ?? false }
        lock.withLock { survivors[agentId] = still.isEmpty ? nil : still }
        out.survivors += still.map(\.pid)
        if let records {
            let reaped = try await Task.detached { try TurnRecords.reap(agentId: agentId, in: records) }.value
            out.killed += reaped.killed
            out.survivors += reaped.survivors
        }
        return out
    }
}

/// Can the engine see what a sandbox allows? It runs a Seatbelt-sandboxed `/bin/sleep` with a known marker and asks the kernel
/// about it. If it cannot tell, the containment of sandboxed turns is blind, and they do not start (B-I2). A pass is kept; a
/// failure is retried after a backoff, never remembered for the engine's life (fix round 2, B-N6).
public final class ContainmentSelfTest: @unchecked Sendable {
    public static let shared = ContainmentSelfTest(run: ContainmentSelfTest.probe, backoff: 30)
    /// The engine's default answer (`SandboxEnvironment.canSeeSandboxes`).
    public static var passed: Bool { shared.check(now: AwakeTime.uptime()) }

    private let run: @Sendable () -> Bool
    private let backoff: TimeInterval
    private let lock = NSLock()
    private var ok = false
    private var retryAt: TimeInterval?

    init(run: @escaping @Sendable () -> Bool, backoff: TimeInterval) { self.run = run; self.backoff = backoff }

    /// The last answer, re-checked when it was a failure whose backoff (`now`: awake seconds) has passed.
    func check(now: TimeInterval) -> Bool {
        lock.withLock {
            if ok { return true }
            if let retryAt, now < retryAt { return false }
            ok = run()
            retryAt = ok ? nil : now + backoff
            return ok
        }
    }

    public static func run() -> Bool { probe() }

    @Sendable static func probe() -> Bool {
        #if os(macOS)
        let marker = "dev.brahma.turn.selftest-\(UUID().uuidString.lowercased())"
        let profile = "(version 1)(allow default)(deny mach-lookup (global-name-prefix \"dev.brahma.turn.\"))"
            + "(allow mach-lookup (global-name \"\(marker)\"))"
        guard let child = try? ProcessGroupChild.spawn(executable: "/usr/bin/sandbox-exec",
                                                      arguments: ["sandbox-exec", "-p", profile, "/bin/sleep", "5"],
                                                      environment: ["PATH": "/usr/bin:/bin"], workingDirectory: URL(fileURLWithPath: "/"),
                                                      output: -1, newSession: true) else { return false }
        defer { child.signalGroup(SIGKILL); child.finish() }
        let probe = SandboxProbe(machMarker: marker), other = SandboxProbe(machMarker: marker + "x")
        let deadline = AwakeTime.uptime() + 5
        while AwakeTime.uptime() < deadline {
            // sandbox-exec applies the profile, then execs sleep: wait until the kernel reports it sandboxed.
            if SandboxCheck.isSandboxed(child.pid) == true {
                return probe.classify(child.pid) == .mine && other.classify(child.pid) == .notMine
                    && probe.classify(getpid()) == .notMine
            }
            usleep(20_000)
        }
        return false
        #else
        return false
        #endif
    }
}

/// A turn's `claude`: the leader of a new session (and so of its own process group), never reaped before its turn's
/// processes are swept, signalled only while it is unreaped.
final class TurnChild: @unchecked Sendable {
    let group: ProcessGroupChild
    let containment: TurnContainment
    private let lock = NSLock()
    private var terminating = false

    private init(group: ProcessGroupChild, containment: TurnContainment) { self.group = group; self.containment = containment }

    var pid: pid_t { group.pid }

    /// Spawns `executable` (`arguments[0]` included) in `workingDirectory` with exactly `environment` plus the turn's marker,
    /// stdin/stdout/stderr on the given descriptors, as a new session's leader, and starts watching its descendants.
    static func spawn(executable: String, arguments: [String], environment: [String: String], workingDirectory: String,
                      stdin: Int32, stdout: Int32, stderr: Int32, probe: SandboxProbe? = nil,
                      since: Double = ProcessTable.startStamp(slack: 1)) throws -> TurnChild {
        let markerValue = UUID().uuidString.lowercased()
        var env = environment
        env[TurnContainment.markerVariable] = markerValue
        let group = try ProcessGroupChild.spawn(executable: executable, arguments: arguments, environment: env,
                                                workingDirectory: URL(fileURLWithPath: workingDirectory, isDirectory: true),
                                                output: stdout, stdin: stdin, stderr: stderr, newSession: true)
        let containment = TurnContainment(leader: group.pid, markerValue: markerValue, since: since, probe: probe)
        containment.startWatching()
        return TurnChild(group: group, containment: containment)
    }

    /// SIGTERM to the turn's group, SIGKILL `grace` seconds later if its leader is still running. Once.
    func terminate(grace: TimeInterval) {
        let first = lock.withLock { () -> Bool in
            defer { terminating = true }
            return !terminating
        }
        guard first, !group.hasExited() else { return }
        group.signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [group] in
            if !group.hasExited() { group.signalGroup(SIGKILL) }
        }
    }

    /// Blocks until the leader exits (it stays unreaped): its exit code, or the number of the signal that ended it.
    func waitForExit() -> Int32 { group.waitForExit() }

    /// Kills every process of the turn (its group and session, its watched descendants, and on a sandboxed turn every process
    /// carrying its marker, fail closed), then reaps the leader. Blocking. Returns what could not be killed or accounted for.
    func finish() -> [ProcessEntry] {
        _ = group.waitForExit()
        var left = Set(containment.sweep())
        if let probe = containment.probe {
            let swept = SandboxSweep.run(probe: probe, since: containment.sinceStamp)
            left.formUnion(swept.survivors)
            // An unreadable table rules nothing out (fix round 2, B-N2): the turn's record stays, the next turn re-checks.
            if swept.tableUnreadable { left.insert(-1) }
        }
        group.finish()
        let unaccounted = [ProcessEntry(pid: -1, ppid: 0, pgid: 0, uid: getuid(), start: 0, isZombie: false)]
        guard let table = ProcessTable.snapshot() else {
            // The table cannot be read now (S4 fix round 1, I2): each pid left is read on its own; one that cannot be read
            // is unaccounted for, one the kernel says is gone is not.
            var rows: [ProcessEntry] = []
            var unread = left.contains(-1)
            for pid in left.filter({ $0 > 0 }).sorted() {
                switch ProcessTable.lookup(pid) {
                case .found(let row): rows.append(row)
                case .absent: break
                case .unreadable: unread = true
                }
            }
            return rows + (unread ? unaccounted : [])
        }
        return table.filter { left.contains($0.pid) } + (left.contains(-1) ? unaccounted : [])
    }
}

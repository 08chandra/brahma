import Foundation
import CSandboxCheck
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

/// One row of the process table.
struct ProcessEntry: Equatable, Sendable {
    var pid: pid_t
    var ppid: pid_t
    var pgid: pid_t
    var uid: uid_t
    /// When it started (seconds; wall clock on Darwin, clock ticks since boot on Linux): with the pid, its identity.
    var start: Double
    var isZombie: Bool
    /// The session id where the table carries it (Linux); Darwin asks `getsid`.
    var sid: pid_t? = nil
}

/// The machine's process table, read without privileges (the owner's own processes are all the engine ever signals).
enum ProcessTable {
    static func snapshot() -> [ProcessEntry] {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
            size += size / 4 + stride * 32
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            var got = buffer.count * stride
            if sysctl(&mib, 3, &buffer, &got, nil, 0) == 0 { return buffer.prefix(got / stride).map(entry) }
            if errno != ENOMEM { return [] }
        }
        return []
        #else
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        return names.compactMap { pid_t($0) }.compactMap(linuxEntry)
        #endif
    }

    /// What reading one pid's row came to. `absent` only when the kernel said there is no such process; a read that failed
    /// is `unreadable`, never "gone", so a caller can fail closed.
    enum Lookup: Equatable, Sendable {
        case found(ProcessEntry)
        case absent
        case unreadable
    }

    static func lookup(_ pid: pid_t) -> Lookup {
        guard pid > 0 else { return .absent }
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return errno == ESRCH ? .absent : .unreadable }
        // No such process: the call succeeds with nothing written.
        if size == 0 { return .absent }
        guard info.kp_proc.p_pid == pid else { return .unreadable }
        return .found(entry(info))
        #else
        if let e = linuxEntry(pid) { return .found(e) }
        var st = stat()
        return stat("/proc/\(pid)", &st) != 0 && errno == ENOENT ? .absent : .unreadable
        #endif
    }

    /// The row of `pid`, or nil when it is gone or could not be read (`lookup` tells the two apart).
    static func entry(_ pid: pid_t) -> ProcessEntry? {
        if case .found(let e) = lookup(pid) { return e }
        return nil
    }

    /// Its session id (nil when it is gone).
    static func session(_ p: ProcessEntry) -> pid_t? {
        if let sid = p.sid { return sid }
        let sid = getsid(p.pid)
        return sid < 0 ? nil : sid
    }

    /// Its environment (`NAME=value` strings) as it was given at exec, or nil when it cannot be read.
    static func environment(_ pid: pid_t) -> [String]? {
        #if canImport(Darwin)
        var maxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var len = MemoryLayout<Int32>.size
        guard sysctl(&maxMib, 2, &argmax, &len, nil, 0) == 0, argmax > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        // The executable path, then the padding NULs.
        while i < size, buffer[i] != 0 { i += 1 }
        while i < size, buffer[i] == 0 { i += 1 }
        var n: Int32 = 0
        while i < size, n < argc {
            while i < size, buffer[i] != 0 { i += 1 }
            i += 1
            n += 1
        }
        var env: [String] = []
        while i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            if i == start { break }
            env.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return env
        #else
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/environ") else { return nil }
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #endif
    }

    #if canImport(Darwin)
    private static func entry(_ p: kinfo_proc) -> ProcessEntry {
        let t = p.kp_proc.p_un.__p_starttime
        return ProcessEntry(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, pgid: p.kp_eproc.e_pgid, uid: p.kp_eproc.e_ucred.cr_uid,
                            start: Double(t.tv_sec) + Double(t.tv_usec) / 1e6, isZombie: p.kp_proc.p_stat == 5 /* SZOMB */)
    }
    #else
    private static func linuxEntry(_ pid: pid_t) -> ProcessEntry? {
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/stat") else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        // `pid (comm) state ppid pgrp session … starttime(22)`; comm may hold spaces and parentheses.
        guard let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...].split(separator: " ")
        guard fields.count > 19, let ppid = pid_t(fields[1]), let pgid = pid_t(fields[2]), let sid = pid_t(fields[3]),
              let start = Double(fields[19]) else { return nil }
        var st = stat()
        guard stat("/proc/\(pid)", &st) == 0 else { return nil }
        return ProcessEntry(pid: pid, ppid: ppid, pgid: pgid, uid: st.st_uid, start: start, isZombie: fields[0] == "Z", sid: sid)
    }
    #endif

    /// The start-time value a process started now would have (comparable with `ProcessEntry.start`), less `slack` seconds.
    static func startStamp(slack: Double) -> Double {
        #if canImport(Darwin)
        var tv = timeval()
        gettimeofday(&tv, nil)
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6 - slack
        #else
        // Linux start times count clock ticks since boot; every process the turn starts is newer than any marker check needs.
        return 0
        #endif
    }
}

/// How the engine recognizes a sandboxed run's processes by their sandbox, which no process can drop (setsid, a cleared
/// environment, a double fork and deleting its own files all keep it): the run's profile allows a unique mach global name
/// (`machMarker`: `dev.brahma.run.<id>` for a check, `dev.brahma.turn.<id>` for a turn, through Claude Code's
/// `sandbox.network.allowMachLookup`) that no service answers, and denies a sibling name. Unsandboxed processes are never
/// matched; a sandboxed one whose policy cannot be read is `.unknown` (callers fail closed).
struct SandboxProbe: Equatable, Sendable {
    let machMarker: String

    init(machMarker: String) { self.machMarker = machMarker }

    enum Match { case mine, notMine, unknown }

    /// `.mine` when the sandbox allows this run's own name AND refuses a sibling under the denied prefix (another run denies
    /// our name; a foreign sandbox that allows every lookup also allows the sibling); `.unknown` when the kernel cannot tell.
    func classify(_ pid: pid_t) -> Match {
        switch SandboxCheck.isSandboxed(pid) {
        case .some(false): return .notMine
        case nil: return .unknown
        case .some(true): break
        }
        switch (SandboxCheck.machAllowed(pid, machMarker), SandboxCheck.machAllowed(pid, machMarker + ".not")) {
        case (.some(true), .some(false)): return .mine
        case (.some(false), _), (_, .some(true)): return .notMine
        default: return .unknown
        }
    }

    func matches(_ pid: pid_t) -> Bool { classify(pid) == .mine }
}

/// What a straggler sweep came to.
struct SweepResult: Sendable, Equatable {
    /// Pids confirmed to be this run's and killed. Killing them does not change the run's outcome (N2: a tool that daemonizes
    /// outside its group is normal); the engine logs an activity line.
    var killed: [pid_t] = []
    /// This run's processes that would not die, and sandboxed same-uid processes newer than the run whose sandbox the kernel
    /// could not read (fail closed).
    var survivors: [pid_t] = []
    /// The process table could not be read (empty, or without this process in it): nothing can be ruled out (fail closed, N1).
    var tableUnreadable = false
    /// The run must be recorded inconclusive: something could not be killed or classified, or the table could not be read.
    var inconclusive: Bool { !survivors.isEmpty || tableUnreadable }
    var clean: Bool { killed.isEmpty && !inconclusive }
}

/// Kills whatever a finished sandboxed run left behind: its processes, recognized by the run's unique mach marker, that
/// started no earlier than the run (`since`), so one that did `POSIX::setsid()` or double-forked out of its process group
/// cannot outlive the run (B-I4). Shared with Task 1b's turn cleanup (`SandboxProbe`). Each kill re-reads the process and
/// checks its start time first, so a pid reused meanwhile is never signalled. Fails closed (N1): an unreadable process table
/// (empty, or missing this process) or an unclassifiable live process is a survivor, and a process whose row cannot be read
/// counts as live (`isAlive`). `snapshot`, `classify` and `alive` are injectable for tests.
enum SandboxSweep {
    /// Whether `p` is still the same live process: the same pid with the same start time, not a zombie. A row that could not
    /// be read counts as alive (fail closed): only a pid the kernel says is gone, or one now someone else's, is not.
    static func isAlive(_ p: ProcessEntry, lookup: (pid_t) -> ProcessTable.Lookup = ProcessTable.lookup) -> Bool {
        switch lookup(p.pid) {
        case .found(let e): return e.start == p.start && !e.isZombie
        case .absent: return false
        case .unreadable: return true
        }
    }
    static func run(probe: SandboxProbe, since: Double, rounds: Int = 50,
                    snapshot: () -> [ProcessEntry] = ProcessTable.snapshot,
                    classify: ((pid_t) -> SandboxProbe.Match)? = nil,
                    alive: (ProcessEntry) -> Bool = { p in SandboxSweep.isAlive(p) })
        -> SweepResult {
        let uid = getuid(), me = getpid()
        let classify = classify ?? probe.classify
        var unreadable = false
        func candidates() -> [ProcessEntry] {
            let table = snapshot()
            // A table without this very process was not really read (sysctl failed or truncated): nothing is ruled out.
            if table.isEmpty || !table.contains(where: { $0.pid == me }) { unreadable = true; return [] }
            return table.filter { $0.uid == uid && $0.pid != me && !$0.isZombie && $0.start >= since }
        }
        var killed = Set<pid_t>()
        for _ in 0..<rounds {
            let mine = candidates().filter { classify($0.pid) == .mine }
            if mine.isEmpty { break }
            for p in mine where ProcessTable.entry(p.pid)?.start == p.start { kill(p.pid, SIGKILL); killed.insert(p.pid) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        var survivors: [pid_t] = []
        for p in candidates() {
            switch classify(p.pid) {
            case .mine: survivors.append(p.pid)
            // Unclassifiable: a survivor only if it is still the same live process (one that exited meanwhile is not).
            case .unknown where alive(p): survivors.append(p.pid)
            default: break
            }
        }
        return SweepResult(killed: killed.sorted().filter { !survivors.contains($0) }, survivors: survivors, tableUnreadable: unreadable)
    }
}

/// What another process's sandbox allows, asked of the kernel (`sandbox_check`, through the `CSandboxCheck` shim: the call is
/// variadic) without its cooperation. Nil: it cannot be told (Linux).
enum SandboxCheck {
    /// Whether `pid` runs under a sandbox profile.
    static func isSandboxed(_ pid: pid_t) -> Bool? {
        let r = brahma_sandbox_is_sandboxed(pid)
        return r < 0 ? nil : r == 1
    }

    /// Whether `pid`'s sandbox denies it writing `path` (which must exist; an unsandboxed process: false). Nothing is logged.
    static func writeDenied(_ pid: pid_t, _ path: String) -> Bool? {
        let r = brahma_sandbox_write_denied(pid, path)
        return r < 0 ? nil : r == 1
    }

    /// Whether `pid`'s sandbox allows a mach-lookup of the global name `name`; nil when it cannot be told.
    static func machAllowed(_ pid: pid_t, _ name: String) -> Bool? {
        let r = brahma_sandbox_mach_allowed(pid, name)
        return r < 0 ? nil : r == 1
    }
}

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
    }

    func startWatching() {
        lock.withLock { watching = true }
        Thread.detachNewThread { [self] in
            while !lock.withLock({ stopFlag }) {
                observe(ProcessTable.snapshot())
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

    /// Adds every process descended from the leader or a tracked one (or in the leader's group or session) to the tracked set.
    func observe(_ table: [ProcessEntry]) {
        lock.withLock {
            var starts: [pid_t: Double] = [:]
            for p in table where starts[p.pid] == nil { starts[p.pid] = p.start }
            tracked = tracked.filter { starts[$0.key] == $0.value }
            var changed = true
            while changed {
                changed = false
                for p in table where p.uid == uid && p.pid != leader && p.pid != me && tracked[p.pid] == nil && !p.isZombie {
                    if p.ppid == leader || tracked[p.ppid] != nil || p.pgid == leader || ProcessTable.session(p) == leader {
                        tracked[p.pid] = p.start
                        changed = true
                    }
                }
            }
        }
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
    func sweep(rounds: Int = 50) -> [pid_t] {
        stopWatching()
        var left: [ProcessEntry] = []
        for _ in 0..<rounds {
            let table = ProcessTable.snapshot()
            observe(table)
            left = members(table)
            if left.isEmpty { return [] }
            for p in left where ProcessTable.entry(p.pid)?.start == p.start { kill(p.pid, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let table = ProcessTable.snapshot()
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
    /// `snapshot` is injectable for tests. Fails closed (fix round 2, B-N2): a table that cannot be read (empty, or without
    /// this very process) rules nothing out: a survivor (`-1`), and the record is kept.
    static func reap(agentId: String, in dir: URL, snapshot: @escaping () -> [ProcessEntry] = ProcessTable.snapshot) throws -> TurnLeftovers {
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
                let table = snapshot()
                guard !table.isEmpty, table.contains(where: { $0.pid == me }) else { unreadable = true; return [] }
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
    /// one in flight. Throws `TurnError.earlierTurnStillRunning` on the deadline, `CancellationError` when cancelled.
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
        guard AwakeTime.now < end else { throw TurnError.earlierTurnStillRunning(pids: []) }
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
        let table = ProcessTable.snapshot()
        let unaccounted = left.contains(-1) ? [ProcessEntry(pid: -1, ppid: 0, pgid: 0, uid: getuid(), start: 0, isZombie: false)] : []
        return table.filter { left.contains($0.pid) } + unaccounted
    }
}

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

    static func entry(_ pid: pid_t) -> ProcessEntry? {
        guard pid > 0 else { return nil }
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return entry(info)
        #else
        return linuxEntry(pid)
        #endif
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

/// How the engine recognizes a process of a sandboxed agent's turn by its sandbox, which no process can drop (setsid, a
/// cleared environment and a double fork all keep it): its sandbox lets it write the agent's own home (every kind of turn
/// writes there) but not the company workspace directory itself (no agent turn may; an owner's own sandboxed tool
/// started in the workspace may). Unsandboxed processes are never matched.
struct SandboxProbe: Equatable, Sendable {
    /// `<ws>/.brahma/home/<h>` (the kernel answers only for paths that exist; the layout creates this one).
    var allowed: String
    /// `<ws>`, the resolved workspace itself.
    var denied: String

    init(workspace: URL, handle: String) {
        allowed = workspace.appending(path: ".brahma/home/\(handle)").path
        denied = workspace.path
    }

    /// A per-run unique mach global name (`dev.brahma.run.<id>`) the run's profile allows and no real service answers. When
    /// set, a process is recognized by whether its sandbox allows that lookup — which survives the process deleting its own
    /// checkout (B-I4), unlike a path probe.
    var machMarker: String?

    /// For a sandboxed check (B-I4): recognize the run's processes by their unique mach marker, independent of any file.
    init(machMarker: String) {
        allowed = ""; denied = ""
        self.machMarker = machMarker
    }

    enum Match { case mine, notMine, unknown }

    /// Whether `pid` is one of this run's processes. With a `machMarker`: `.mine` when the sandbox allows this run's unique
    /// name and refuses a sibling under the denied prefix; `.notMine` when it does not; `.unknown` when the kernel cannot
    /// tell — including a nil sandbox status for a live process (fail closed, N1). Without a marker (1b turns), the
    /// write-shape probe, which has no `.unknown`.
    func classify(_ pid: pid_t) -> Match {
        if let machMarker {
            switch SandboxCheck.isSandboxed(pid) {
            case .some(false): return .notMine
            case nil: return .unknown
            case .some(true): break
            }
            // Ours: this run's own name allowed AND a sibling name under the denied prefix refused. Another Brahma run denies
            // our name; a foreign sandbox that allows every lookup also allows the sibling. Either reads as not ours.
            switch (SandboxCheck.machAllowed(pid, machMarker), SandboxCheck.machAllowed(pid, machMarker + ".not")) {
            case (.some(true), .some(false)): return .mine
            case (.some(false), _), (_, .some(true)): return .notMine
            default: return .unknown
            }
        }
        guard SandboxCheck.isSandboxed(pid) == true else { return .notMine }
        return SandboxCheck.writeDenied(pid, allowed) == false && SandboxCheck.writeDenied(pid, denied) == true ? .mine : .notMine
    }

    /// Whether `pid` runs under a sandbox shaped like one of this agent's turns (1b; `.mine` only).
    func matches(_ pid: pid_t) -> Bool { classify(pid) == .mine }

    /// The owner's processes in the table this probe matches (never this process).
    func scan(_ table: [ProcessEntry]) -> [ProcessEntry] {
        let uid = getuid(), me = getpid()
        return table.filter { $0.uid == uid && $0.pid != me && !$0.isZombie && matches($0.pid) }
    }
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
/// (empty, or missing this process) or an unclassifiable live process is a survivor. `snapshot` and `classify` are
/// injectable for tests.
enum SandboxSweep {
    static func run(probe: SandboxProbe, since: Double, rounds: Int = 50,
                    snapshot: () -> [ProcessEntry] = ProcessTable.snapshot,
                    classify: ((pid_t) -> SandboxProbe.Match)? = nil,
                    alive: (ProcessEntry) -> Bool = { p in ProcessTable.entry(p.pid).map { $0.start == p.start && !$0.isZombie } ?? false })
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
            if let probe, probe.matches(p.pid) { return true }
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

/// The turns each agent has in flight, and what a finished turn could not kill. A new turn of the agent waits here first.
final class TurnRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var running: [String: Int] = [:]
    private var survivors: [String: [ProcessEntry]] = [:]
    /// The sandbox shape of each agent's latest sandboxed turn.
    private var probes: [String: SandboxProbe] = [:]

    func begin(_ agentId: String, probe: SandboxProbe? = nil) {
        lock.withLock {
            running[agentId, default: 0] += 1
            if let probe { probes[agentId] = probe }
        }
    }

    func end(_ agentId: String, survivors left: [ProcessEntry]) {
        lock.withLock {
            let n = (running[agentId] ?? 1) - 1
            running[agentId] = n > 0 ? n : nil
            if left.isEmpty { survivors[agentId] = nil } else { survivors[agentId, default: []] += left }
        }
    }

    /// Waits until no turn of the agent is in flight (their sweeps done), then tries the leftovers of earlier turns once more;
    /// returns the pids still alive (empty: nothing of an earlier turn runs).
    func waitUntilGone(_ agentId: String) async -> [pid_t] {
        while lock.withLock({ running[agentId] != nil }) { try? await Task.sleep(for: .milliseconds(20)) }
        // Anything still running in a sandbox shaped like this agent's turns is left over from one of them.
        var left = lock.withLock { survivors[agentId] ?? [] }
        if let probe = lock.withLock({ probes[agentId] }) {
            for p in probe.scan(ProcessTable.snapshot()) where !left.contains(where: { $0.pid == p.pid && $0.start == p.start }) {
                left.append(p)
            }
        }
        guard !left.isEmpty else { return [] }
        var alive: [ProcessEntry] = []
        for p in left {
            guard let now = ProcessTable.entry(p.pid), now.start == p.start, !now.isZombie else { continue }
            kill(p.pid, SIGKILL)
            alive.append(p)
        }
        if !alive.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        let still = alive.filter { p in ProcessTable.entry(p.pid).map { $0.start == p.start && !$0.isZombie } ?? false }
        lock.withLock { survivors[agentId] = still.isEmpty ? nil : still }
        return still.map(\.pid)
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
                      stdin: Int32, stdout: Int32, stderr: Int32, probe: SandboxProbe? = nil) throws -> TurnChild {
        let markerValue = UUID().uuidString.lowercased()
        var env = environment
        env[TurnContainment.markerVariable] = markerValue
        let since = ProcessTable.startStamp(slack: 1)
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

    /// Kills every process of the turn, then reaps the leader. Blocking. Returns what could not be killed.
    func finish() -> [ProcessEntry] {
        _ = group.waitForExit()
        let left = containment.sweep()
        group.finish()
        let table = ProcessTable.snapshot()
        return table.filter { left.contains($0.pid) }
    }
}

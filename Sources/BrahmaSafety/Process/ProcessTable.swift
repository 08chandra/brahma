import Foundation
import CSandboxCheck
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One row of the process table.
public struct ProcessEntry: Equatable, Sendable {
    public var pid: pid_t
    public var ppid: pid_t
    public var pgid: pid_t
    public var uid: uid_t
    /// When it started (seconds; wall clock on Darwin, clock ticks since boot on Linux): with the pid, its identity.
    public var start: Double
    public var isZombie: Bool
    /// The session id where the table carries it (Linux); Darwin asks `getsid`.
    public var sid: pid_t? = nil

    public init(pid: pid_t, ppid: pid_t, pgid: pid_t, uid: uid_t, start: Double, isZombie: Bool, sid: pid_t? = nil) {
        self.pid = pid; self.ppid = ppid; self.pgid = pgid; self.uid = uid; self.start = start; self.isZombie = isZombie; self.sid = sid
    }
}

/// The machine's process table, read without privileges (the owner's own processes are all the engine ever signals).
public enum ProcessTable {
    /// Every process, or nil when the table could not be read (a failed `sysctl`, a table that kept outgrowing its buffer, an
    /// unlistable `/proc`). Nil is never "nothing runs": each reader handles it explicitly and fails closed (S4 fix round 1,
    /// I2): the stop signals every recorded group whose leader still leads it, a turn's sweep is inconclusive, WAL shipping
    /// does not launch, and `SandboxSweep` reports `tableUnreadable`.
    public static func snapshot() -> [ProcessEntry]? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return nil }
            size += size / 4 + stride * 32
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
            var got = buffer.count * stride
            if sysctl(&mib, 3, &buffer, &got, nil, 0) == 0 { return buffer.prefix(got / stride).map(entry) }
            if errno != ENOMEM { return nil }
        }
        return nil
        #else
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: "/proc") } catch {
            return nil
        }
        return names.compactMap { pid_t($0) }.compactMap(linuxEntry)
        #endif
    }

    /// What reading one pid's row came to. `absent` only when the kernel said there is no such process; a read that failed
    /// is `unreadable`, never "gone", so a caller can fail closed.
    public enum Lookup: Equatable, Sendable {
        case found(ProcessEntry)
        case absent
        case unreadable
    }

    public static func lookup(_ pid: pid_t) -> Lookup {
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
    public static func entry(_ pid: pid_t) -> ProcessEntry? {
        if case .found(let e) = lookup(pid) { return e }
        return nil
    }

    /// Its session id (nil when it is gone).
    public static func session(_ p: ProcessEntry) -> pid_t? {
        if let sid = p.sid { return sid }
        let sid = getsid(p.pid)
        return sid < 0 ? nil : sid
    }

    /// `proc_pidinfo`'s `PROC_PIDUNIQIDENTIFIERINFO` flavor (`<sys/proc_info.h>`), which answers with a
    /// `struct proc_uniqidentifierinfo`.
    public static let uniqueIdentifierFlavor: Int32 = 17
    /// The size of that struct: `p_uuid[16]`, `p_uniqueid` (UInt64, offset 16), `p_puniqueid` (UInt64, offset 24),
    /// `p_idversion`, `p_orig_ppidversion` (Int32 each) and two reserved UInt64s.
    private static let uniqueIdentifierInfoSize = 56
    private static let uniqueIdOffset = 16
    private static let parentUniqueIdOffset = 24

    /// A process's lineage, as the kernel recorded it at fork: its own unique id (Darwin `p_uniqueid`) and its parent's
    /// (`p_puniqueid`). A unique id is never reused while the machine runs, unlike a pid. `p_puniqueid` keeps naming the
    /// process that forked it after that parent exits and XNU reparents the child to launchd (ppid 1). A `setsid`'d child of
    /// a turn whose parent exited between two polls is therefore still known to be the turn's (Ruling S5-5), while its ppid,
    /// group and session say nothing.
    /// Nil when it cannot be read: the process is gone or another user's, or this is not Darwin (Linux has no such id).
    public static func lineage(_ pid: pid_t) -> (unique: UInt64, parent: UInt64)? {
        #if canImport(Darwin)
        guard pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: uniqueIdentifierInfoSize)
        let n = buffer.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, uniqueIdentifierFlavor, 0, raw.baseAddress, Int32(raw.count))
        }
        guard n == Int32(uniqueIdentifierInfoSize) else { return nil }
        return buffer.withUnsafeBytes { raw in
            (raw.loadUnaligned(fromByteOffset: uniqueIdOffset, as: UInt64.self),
             raw.loadUnaligned(fromByteOffset: parentUniqueIdOffset, as: UInt64.self))
        }
        #else
        return nil
        #endif
    }

    /// Its environment (`NAME=value` strings) as it was given at exec, or nil when it cannot be read.
    public static func environment(_ pid: pid_t) -> [String]? {
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
    public static func startStamp(slack: Double) -> Double {
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
public struct SandboxProbe: Equatable, Sendable {
    public let machMarker: String

    public init(machMarker: String) { self.machMarker = machMarker }

    public enum Match: Sendable { case mine, notMine, unknown }

    /// `.mine` when the sandbox allows this run's own name AND refuses a sibling under the denied prefix (another run denies
    /// our name; a foreign sandbox that allows every lookup also allows the sibling); `.unknown` when the kernel cannot tell.
    public func classify(_ pid: pid_t) -> Match {
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

    public func matches(_ pid: pid_t) -> Bool { classify(pid) == .mine }
}

/// What a straggler sweep came to.
public struct SweepResult: Sendable, Equatable {
    /// Pids confirmed to be this run's and killed. Killing them does not change the run's outcome (N2: a tool that daemonizes
    /// outside its group is normal); the engine logs an activity line.
    public var killed: [pid_t] = []
    /// This run's processes that would not die, and sandboxed same-uid processes newer than the run whose sandbox the kernel
    /// could not read (fail closed).
    public var survivors: [pid_t] = []
    /// The process table could not be read (nil, empty, or without this process in it): nothing can be ruled out (fail closed,
    /// N1).
    public var tableUnreadable = false
    /// The run must be recorded inconclusive: something could not be killed or classified, or the table could not be read.
    public var inconclusive: Bool { !survivors.isEmpty || tableUnreadable }
    public var clean: Bool { killed.isEmpty && !inconclusive }
}

/// Kills whatever a finished sandboxed run left behind: its processes, recognized by the run's unique mach marker, that
/// started no earlier than the run (`since`), so one that did `POSIX::setsid()` or double-forked out of its process group
/// cannot outlive the run (B-I4). Shared with Task 1b's turn cleanup (`SandboxProbe`). Each kill re-reads the process and
/// checks its start time first, so a pid reused meanwhile is never signalled. Fails closed (N1): an unreadable process table
/// (nil, empty, or missing this process) or an unclassifiable live process is a survivor, and a process whose row cannot be read
/// counts as live (`isAlive`). `snapshot`, `classify` and `alive` are injectable for tests.
public enum SandboxSweep {
    /// Whether `p` is still the same live process: the same pid with the same start time, not a zombie. A row that could not
    /// be read counts as alive (fail closed): only a pid the kernel says is gone, or one now someone else's, is not.
    public static func isAlive(_ p: ProcessEntry, lookup: (pid_t) -> ProcessTable.Lookup = ProcessTable.lookup) -> Bool {
        switch lookup(p.pid) {
        case .found(let e): return e.start == p.start && !e.isZombie
        case .absent: return false
        case .unreadable: return true
        }
    }
    public static func run(probe: SandboxProbe, since: Double, rounds: Int = 50,
                    snapshot: () -> [ProcessEntry]? = ProcessTable.snapshot,
                    classify: ((pid_t) -> SandboxProbe.Match)? = nil,
                    alive: (ProcessEntry) -> Bool = { p in SandboxSweep.isAlive(p) })
        -> SweepResult {
        let uid = getuid(), me = getpid()
        let classify = classify ?? probe.classify
        var unreadable = false
        func candidates() -> [ProcessEntry] {
            // No table, or one without this very process (sysctl truncated it), was not really read: nothing is ruled out.
            guard let table = snapshot(), table.contains(where: { $0.pid == me }) else { unreadable = true; return [] }
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
public enum SandboxCheck {
    /// Whether `pid` runs under a sandbox profile.
    public static func isSandboxed(_ pid: pid_t) -> Bool? {
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

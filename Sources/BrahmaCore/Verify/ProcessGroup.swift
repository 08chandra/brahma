import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One child process spawned as the leader of its own process group, signalled only while the runner still owns that group.
///
/// The descriptor- and pid-reuse window (carry-over): once a child is reaped, its pid (and so its process-group id) can be
/// handed to an unrelated process, and a later `killpg` would hit that one. So:
/// - the leader's exit is noticed with `waitid(WNOWAIT)`, which leaves it a zombie: its pid, and with it the group id, stay
///   reserved, so the final sweep (`killpg SIGKILL`) can only reach this child's own group;
/// - it is reaped only after that sweep (`finish`), under the same lock every signal takes;
/// - after the reap nothing is ever signalled again, whoever asks (`signalGroup` returns false).
/// A child that is reaped by someone else (`ECHILD`) counts as reaped: no signal is sent after that either.
final class ProcessGroupChild: @unchecked Sendable {
    /// What the child went through, for tests (`observer`).
    enum Event: CustomStringConvertible, Sendable {
        case signal(pid_t, Int32)
        case reaped(pid_t)
        var description: String {
            switch self {
            case .signal(let pid, let sig): "killpg \(pid) \(sig)"
            case .reaped(let pid): "reaped \(pid)"
            }
        }
    }
    typealias Observer = @Sendable (Event) -> Void

    let pid: pid_t
    private let lock = NSLock()
    private var exited = false
    private var status: Int32?
    private var signals = 0
    private var lost = false
    private let observer: Observer?

    private init(pid: pid_t, observer: Observer?) {
        self.pid = pid; self.observer = observer
    }

    /// Signals sent so far (tests).
    var signalCount: Int { lock.withLock { signals } }

    /// Spawns `executable` with `arguments` (argv, `arguments[0]` included) as the leader of a new process group: stdin
    /// `/dev/null`, stdout and stderr to `output` (`-1`: `/dev/null`), working directory `workingDirectory`, exactly
    /// `environment`, default signal dispositions, an empty signal mask, and (Darwin) no descriptor inherited but those.
    /// `stdin` (`-1`: `/dev/null`) and `stderr` (nil: `output`) override those two; `newSession` makes it the leader of a new
    /// session as well (`setsid`: a turn's `claude`), which is also its own process group.
    /// Throws a message when it cannot be started.
    /// `workingDirectoryFD`: an open directory descriptor the child `fchdir`s into instead of `workingDirectory`'s path
    /// (`SafeGit`: an item worktree held `O_NOFOLLOW`, so no path an agent can retarget is ever resolved for it).
    static func spawn(executable: String, arguments: [String], environment: [String: String], workingDirectory: URL,
                      output: Int32, stdin: Int32 = -1, stderr: Int32? = nil, newSession: Bool = false,
                      workingDirectoryFD: Int32? = nil, observer: Observer? = nil) throws -> ProcessGroupChild {
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        if stdin >= 0 {
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        if output >= 0 {
            posix_spawn_file_actions_adddup2(&actions, output, 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        if let stderr, stderr >= 0 {
            posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        } else if stderr == nil, output >= 0 {
            posix_spawn_file_actions_adddup2(&actions, output, 2)
        } else {
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        }
        // A chdir action that cannot be queued must never let the child start in this process's directory instead.
        let chdirStatus: Int32
        if let workingDirectoryFD {
            #if canImport(Darwin)
            chdirStatus = posix_spawn_file_actions_addfchdir_np(&actions, workingDirectoryFD)
            #else
            // Before exec (so before close-on-exec), the child's own descriptor table still holds it.
            chdirStatus = posix_spawn_file_actions_addchdir_np(&actions, "/proc/self/fd/\(workingDirectoryFD)")
            #endif
        } else {
            chdirStatus = posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        }
        guard chdirStatus == 0 else { throw SpawnFailure(message: "cannot set the working directory (\(String(cString: strerror(chdirStatus))))") }
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults); sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &mask)
        // A new session makes the child its own group's leader too (setpgid would fail on a session leader).
        var flags = Int32(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK) | (newSession ? Int32(POSIX_SPAWN_SETSID) : Int32(POSIX_SPAWN_SETPGROUP))
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attr, Int16(flags))
        if !newSession { posix_spawnattr_setpgroup(&attr, 0) }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attr, &argv, &envp)
        guard spawned == 0 else { throw SpawnFailure(message: String(cString: strerror(spawned))) }
        return ProcessGroupChild(pid: pid, observer: observer)
    }

    struct SpawnFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    /// True once the leader has exited. It is not reaped here: it stays a zombie, so the group id stays this child's.
    func hasExited() -> Bool {
        lock.withLock {
            if exited || status != nil { return true }
            var info = siginfo_t()
            while true {
                let r = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if r == 0 { break }
                if errno == EINTR { continue }
                // ECHILD: reaped by someone else, which the engine never does. Its pid may already be another process's, so
                // it is never signalled again, and the outcome is inconclusive (not a pass): the check's exit was lost (B-M1).
                status = 0; exited = true; lost = true
                return true
            }
            if Self.sigPid(info) == pid { exited = true }
            return exited
        }
    }

    /// `siginfo_t.si_pid`/`si_status` behind platform conditionals: on Glibc they are macros over `_sifields` that Swift does
    /// not import as members (B-M5).
    private static func sigPid(_ info: siginfo_t) -> pid_t {
        #if canImport(Darwin)
        return info.si_pid
        #else
        return info._sifields._sigchld.si_pid
        #endif
    }
    private static func sigStatus(_ info: siginfo_t) -> Int32 {
        #if canImport(Darwin)
        return info.si_status
        #else
        return info._sifields._sigchld.si_status
        #endif
    }

    /// True when the check's own exit status was lost (it was reaped out from under the engine): the outcome is inconclusive,
    /// never a pass (B-M1).
    var lostTrack: Bool { lock.withLock { lost } }

    /// Blocks until the leader exits and leaves it unreaped (a zombie: its pid and group id stay this child's). Returns its
    /// exit code, or the number of the signal that ended it (as Foundation's `terminationStatus` does).
    func waitForExit() -> Int32 {
        var info = siginfo_t()
        while true {
            let r = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
            if r == 0 { break }
            if errno == EINTR { continue }
            // ECHILD: reaped elsewhere; never signalled again, and the status was lost (B-M1).
            lock.withLock { if status == nil { status = 0 }; exited = true; lost = true }
            return 0
        }
        lock.withLock { exited = true }
        return Self.sigStatus(info)
    }

    /// Sends `sig` to the whole group and, directly, to the leader, unless the leader has been reaped (its pid/group id may
    /// belong to someone else by now). The leader's own pid cannot be recycled while it is unreaped, so `kill(pid, sig)`
    /// reaches it even after it moved itself out of its process group (`setpgid`/`setsid`) to dodge the `killpg` (B-I1).
    /// Returns whether it was sent.
    @discardableResult
    func signalGroup(_ sig: Int32) -> Bool {
        lock.withLock {
            guard status == nil else { return false }
            killpg(pid, sig)
            kill(pid, sig)
            signals += 1
            observer?(.signal(pid, sig))
            return true
        }
    }

    /// Blocks until the leader exits (unreaped), then kills whatever is left in its group while the zombie still holds the
    /// group id, then reaps it. Returns the wait status (the same one on every later call; nothing is signalled again).
    @discardableResult
    func finish() -> Int32 {
        while !hasExited() {
            var info = siginfo_t()
            // Blocks without reaping; a signal interrupting it just loops.
            _ = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
        }
        return lock.withLock {
            if let status { return status }
            killpg(pid, SIGKILL)
            signals += 1
            observer?(.signal(pid, SIGKILL))
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0 {
                if errno == EINTR { continue }
                raw = 0
                break
            }
            status = raw
            observer?(.reaped(pid))
            return raw
        }
    }

    /// The shell convention for a wait status: the exit code, or 128 + the signal that ended it.
    static func exitCode(_ status: Int32) -> Int32 {
        status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}

/// Reads a child's output from the read end of a pipe it owns: the first `cap` bytes to `file`, the rest only to a tail
/// buffer (with `[output truncated]` appended once). The reader thread is the only owner of both descriptors and closes them
/// itself when it is done, so no descriptor number is ever read or written after it was closed (and possibly reused).
final class OutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stopFlag = false
    private var tailData = Data()
    private let done = DispatchSemaphore(value: 0)
    private let tailBytes: Int

    /// Starts the reader on its own thread; `readEnd` and `file` belong to it from here on.
    init(readEnd: Int32, file: Int32, cap: Int, tailBytes: Int, marker: String) {
        self.tailBytes = tailBytes
        Thread.detachNewThread { [self] in
            var written = 0
            var truncated = false
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            reading: while !stopped {
                var pfd = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; break }
                if ready == 0 { continue }
                let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; break reading }
                if n == 0 { break reading }
                add(Data(buffer[0..<n]))
                let room = cap - written
                if room > 0 {
                    let take = min(room, n)
                    buffer.withUnsafeBytes { _ = write(file, $0.baseAddress, take) }
                    written += take
                }
                if n > room { truncated = true }
            }
            if truncated { let m = "\n\(marker)\n"; _ = m.withCString { write(file, $0, strlen($0)) } }
            close(readEnd)
            close(file)
            done.signal()
        }
    }

    private var stopped: Bool { lock.withLock { stopFlag } }

    private func add(_ chunk: Data) {
        lock.withLock {
            tailData.append(chunk)
            if tailData.count > tailBytes { tailData.removeFirst(tailData.count - tailBytes) }
        }
    }

    /// Waits up to `drain` seconds for the end of the output; then tells the reader to stop (a process outside the group
    /// may still hold the pipe) and waits for it to close its descriptors, which it does within one poll interval.
    func finish(drain: TimeInterval) -> Data {
        if done.wait(timeout: .now() + drain) == .timedOut {
            lock.withLock { stopFlag = true }
            done.wait()
        }
        return lock.withLock { tailData }
    }
}

/// The physical memory footprint the system charges processes (`proc_pid_rusage`, `ri_phys_footprint`). Darwin only;
/// elsewhere nil (no watchdog there, and no sandboxed reader either).
enum MemoryFootprint {
    /// The summed footprint of every process in process group `pgid`, or nil when the group can't be listed.
    static func ofGroup(_ pgid: pid_t) -> Int? {
        members(ofGroup: pgid).map { $0.reduce(0) { $0 + (of($1) ?? 0) } }
    }

    /// C2b fix round 4 (R4-4): the summed footprint of a run, `leader` itself (by its pid, whichever group it is in: its pid
    /// can't be recycled while it is unreaped) and every process in its process group, each once. Never nil on Darwin.
    static func ofRun(leader: pid_t) -> Int? {
        #if canImport(Darwin)
        let pids = Set((members(ofGroup: leader) ?? []) + [leader])
        return pids.reduce(0) { $0 + (of($1) ?? 0) }
        #else
        return nil
        #endif
    }

    /// The pids in process group `pgid`, or nil when it can't be listed.
    static func members(ofGroup pgid: pid_t) -> [pid_t]? {
        #if canImport(Darwin)
        var pids = [pid_t](repeating: 0, count: 512)
        let listed = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpgrppids(pgid, buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard listed >= 0 else { return nil }
        return pids.filter { $0 > 0 }
        #else
        return nil
        #endif
    }

    /// One process's footprint, or nil.
    static func of(_ pid: pid_t) -> Int? {
        #if canImport(Darwin)
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int(clamping: info.ri_phys_footprint) : nil
        #else
        return nil
        #endif
    }
}

/// The shared blocking body of `ProcessCheckRunner` and `SeatbeltRunner`: spawn into its own process group, capture the
/// output, enforce the timeout (SIGTERM to the group, SIGKILL `termGrace` later) and cancellation (SIGKILL), sweep the
/// group when the leader exits, and decode the outcome.
enum GroupRun {
    /// The last line of the tail of a run its memory limit stopped (C2b fix round 3).
    static let memoryExceeded = "the run used more memory than it may, and was stopped"
    /// The last line of the tail of a run whose standard output passed its cap (C2b fix round 4, R4-4).
    static let outputExceeded = "the run wrote more output than it may, and was stopped"

    final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    static func fail(_ message: String, outputURL: URL) -> CheckOutcome {
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? message.write(to: outputURL, atomically: true, encoding: .utf8)
        return CheckOutcome(exitCode: nil, timedOut: false, tail: message)
    }

    static func tailText(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        // A cut inside a multi-byte character leaves replacement characters at the start.
        while text.first == "\u{FFFD}" { text.removeFirst() }
        return String(text.suffix(ProcessCheckRunner.tailChars))
    }

    /// `stdout` (C2b fix round 4, R4-4): the run's standard output goes to that file (created anew), at most `cap` bytes;
    /// one byte more and the run is killed (`outputExceeded`); its standard error then goes to `outputURL` alone. An output
    /// that never ends (a descriptor held elsewhere) makes the run inconclusive. `newSession`: the child leads a new session
    /// (`setsid`), so it can't leave its process group. The memory watchdog sums the child itself and its group.
    static func run(executable: String, arguments: [String], workingDirectory: URL, timeout: TimeInterval, outputURL: URL,
                    environment: [String: String], termGrace: TimeInterval, clock: @Sendable () -> TimeInterval,
                    cancel: CancelFlag, observer: ProcessGroupChild.Observer? = nil, groups: ChildGroups? = nil,
                    memoryLimit: Int? = nil, stdout: (url: URL, cap: Int)? = nil, newSession: Bool = false) -> CheckOutcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: workingDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            return fail("could not start the check: \(workingDirectory.path) is not a directory", outputURL: outputURL)
        }
        do { try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
            return fail("could not start the check: no place for its output (\(error))", outputURL: outputURL)
        }
        let file = open(outputURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { return CheckOutcome(exitCode: nil, timedOut: false, tail: "could not start the check: cannot open its output file") }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            close(file)
            return fail("could not start the check: no pipe (\(String(cString: strerror(errno))))", outputURL: outputURL)
        }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        // Neither end may leak into children spawned meanwhile (a leaked write end would hold the pipe open).
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC); _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
        // The standard output apart (round 4): its own file and pipe.
        var out: (file: Int32, read: Int32, write: Int32)?
        if let stdout {
            let outFile = open(stdout.url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
            var outFds: [Int32] = [0, 0]
            guard outFile >= 0, pipe(&outFds) == 0 else {
                if outFile >= 0 { close(outFile) }
                close(readEnd); close(writeEnd); close(file)
                return fail("could not start the check: no place for its standard output", outputURL: outputURL)
            }
            _ = fcntl(outFds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(outFds[1], F_SETFD, FD_CLOEXEC)
            out = (outFile, outFds[0], outFds[1])
        }
        func closeOut() { if let out { close(out.file); close(out.read); close(out.write) } }

        let child: ProcessGroupChild
        do {
            child = try ProcessGroupChild.spawn(executable: executable, arguments: arguments, environment: environment,
                                                workingDirectory: workingDirectory, output: out?.write ?? writeEnd,
                                                stderr: out == nil ? nil : writeEnd, newSession: newSession, observer: observer)
        } catch {
            close(writeEnd); close(readEnd); close(file); closeOut()
            return fail("could not start the check: \(error)", outputURL: outputURL)
        }
        close(writeEnd)
        if let out { close(out.write) }
        // Recorded for the owner's stop (`EmergencyStop.recordedGroups`) until it is reaped.
        let record = groups?.record(child.pid)
        defer { groups?.forget(record, pid: child.pid) }
        // From here the readers own `readEnd` and `file`, and the standard output's two descriptors.
        let capture = OutputCapture(readEnd: readEnd, file: file, cap: ProcessCheckRunner.outputCap,
                                    tailBytes: ProcessCheckRunner.tailChars * 4, marker: ProcessCheckRunner.truncationMarker)
        let capped = out.map { CappedCapture(readEnd: $0.read, file: $0.file, cap: stdout?.cap ?? 0) }

        let deadline = clock() + timeout
        var timedOut = false, cancelled = false, overMemory = false, overOutput = false
        var termSentAt: TimeInterval?, killSent = false
        while !child.hasExited() {
            let now = clock()
            if cancel.isSet && !cancelled { cancelled = true; child.signalGroup(SIGKILL); killSent = true }
            // The memory watchdog (C2b fix round 3; round 4: the child itself too, whatever group it is in): every 10 ms;
            // past the limit, SIGKILL.
            if let memoryLimit, !overMemory, let used = MemoryFootprint.ofRun(leader: child.pid), used > memoryLimit {
                overMemory = true
                child.signalGroup(SIGKILL)
                killSent = true
            }
            // Round 4: standard output past its cap, SIGKILL.
            if let capped, !overOutput, capped.exceeded {
                overOutput = true
                child.signalGroup(SIGKILL)
                killSent = true
            }
            if !timedOut && !cancelled && now >= deadline {
                timedOut = true
                child.signalGroup(SIGTERM)
                termSentAt = now
            }
            if let sent = termSentAt, !killSent, now - sent >= termGrace {
                child.signalGroup(SIGKILL)
                killSent = true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // The leader is gone (still unreaped): whatever it left in its group goes too, then it is reaped.
        let status = child.finish()
        let tail = tailText(capture.finish(drain: 2))
        let outputEnded = capped?.finish(drain: 2) ?? true
        if capped?.exceeded == true { overOutput = true }

        if overMemory { return CheckOutcome(exitCode: nil, timedOut: false, tail: (tail.isEmpty ? "" : tail + "\n") + memoryExceeded) }
        if overOutput { return CheckOutcome(exitCode: nil, timedOut: false, tail: (tail.isEmpty ? "" : tail + "\n") + outputExceeded) }
        if cancelled { return CheckOutcome(exitCode: nil, timedOut: false, tail: tail) }
        if timedOut { return CheckOutcome(exitCode: nil, timedOut: true, tail: tail) }
        // Its exit was lost (reaped from under us): inconclusive, never a pass (B-M1).
        if child.lostTrack {
            let note = tail.isEmpty ? "lost track of the check process" : tail + "\nlost track of the check process"
            return CheckOutcome(exitCode: nil, timedOut: false, tail: note)
        }
        // Round 4: a standard output that did not end with the run (something else held it) was not read whole.
        if !outputEnded {
            let note = "the run's output did not end with it"
            return CheckOutcome(exitCode: nil, timedOut: false, tail: tail.isEmpty ? note : tail + "\n" + note)
        }
        return CheckOutcome(exitCode: ProcessGroupChild.exitCode(status), timedOut: false, tail: tail)
    }
}

/// C2b fix round 4 (R4-4): a run's standard output, read by the engine into `file`: at most `cap` bytes are kept; once more
/// arrives the reader stops (`exceeded`) and the runner kills the run. The reader thread owns both descriptors and closes
/// them itself when it is done.
final class CappedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var over = false
    private var ended = false
    private var stopFlag = false
    private let done = DispatchSemaphore(value: 0)

    init(readEnd: Int32, file: Int32, cap: Int) {
        Thread.detachNewThread { [self] in
            var kept = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            reading: while !stopped {
                var pfd = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; break }
                if ready == 0 { continue }
                let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; break reading }
                if n == 0 { lock.withLock { ended = true }; break reading }
                let take = min(n, max(0, cap - kept))
                var written = 0
                while written < take {
                    let w = buffer.withUnsafeBytes { write(file, $0.baseAddress! + written, take - written) }
                    if w < 0 { if errno == EINTR { continue }; break }
                    written += w
                }
                kept += written
                // More than the cap, or bytes that could not be kept: the run is stopped and its output refused.
                if n > take || written < take { lock.withLock { over = true }; break reading }
            }
            close(readEnd)
            close(file)
            done.signal()
        }
    }

    private var stopped: Bool { lock.withLock { stopFlag } }

    /// The output passed the cap (or could not be kept).
    var exceeded: Bool { lock.withLock { over } }

    /// Waits up to `drain` seconds for the reader to finish, then stops it; true when the output ended (or passed its cap)
    /// before that.
    func finish(drain: TimeInterval) -> Bool {
        if done.wait(timeout: .now() + drain) == .timedOut {
            lock.withLock { stopFlag = true }
            done.wait()
        }
        return lock.withLock { ended || over }
    }
}

/// One bounded run of an engine tool (`claude --version`, rclone, zstd/gzip, lsof): spawned as the leader of its own process
/// group (`ProcessGroupChild`), waited on in awake time (`AwakeTime`), and past `timeout` SIGTERMed as a group, then
/// SIGKILLed as a group `killGrace` later, so a hung tool's children go with it. When the leader exits its group is swept
/// before it is reaped (`finish`). Blocking: call it inside a `Blocking` body (or a CLI's main thread).
enum GroupExec {
    /// Where the child's standard output goes.
    enum Output {
        /// Captured through a pipe: at most the last `cap` bytes are kept; `stderr` joins it (else `/dev/null`).
        case capture(cap: Int, stderr: Bool)
        /// This descriptor (the caller keeps it); standard error goes to `/dev/null`.
        case descriptor(Int32)
    }

    struct Result: Sendable {
        /// False when it could not be started (`error` says why).
        var launched: Bool
        /// The exit code, or 128 + the signal that ended it.
        var status: Int32
        var output: Data
        var timedOut: Bool
        var error: String?
    }

    /// Once SIGKILL has been sent, how long to wait for the leader before giving up on it by default (INT-M4): bounded, so a
    /// process stuck in an uninterruptible wait cannot hang the engine.
    static let defaultAbandonAfter: TimeInterval = 10

    /// `arguments` excludes argv[0]. `stdin` `-1`: `/dev/null`. The working directory defaults to `/` (never the engine's own
    /// current directory, INT-M5). `abandonAfter`: once SIGKILL has been sent, how long to wait for the leader before giving up
    /// on it (`defaultAbandonAfter`). Captured output is drained for up to 2 s after a normal exit and not waited on after a
    /// timeout, so a process outside the group that holds the pipe cannot hang the caller. A leader that was abandoned, or
    /// whose exit status was lost, is reported as not succeeded (`status` -1, `error` set), never as status 0 (INT-I2).
    static func run(executable: String, arguments: [String], environment: [String: String],
                    workingDirectory: URL = URL(fileURLWithPath: "/", isDirectory: true),
                    stdin: Int32 = -1, output: Output, timeout: TimeInterval, killGrace: TimeInterval = 1,
                    abandonAfter: TimeInterval? = GroupExec.defaultAbandonAfter,
                    spawned: ((pid_t) -> Void)? = nil,
                    clock: () -> TimeInterval = { AwakeTime.uptime() }) -> Result {
        var readEnd: Int32 = -1, writeEnd: Int32 = -1
        let outFD: Int32, errFD: Int32?
        switch output {
        case .descriptor(let fd):
            outFD = fd; errFD = -1
        case .capture(_, let withStderr):
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else {
                return Result(launched: false, status: -1, output: Data(), timedOut: false,
                              error: "no pipe (\(String(cString: strerror(errno))))")
            }
            (readEnd, writeEnd) = (fds[0], fds[1])
            _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC); _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
            outFD = writeEnd; errFD = withStderr ? nil : -1
        }
        let child: ProcessGroupChild
        do {
            child = try ProcessGroupChild.spawn(executable: executable, arguments: [executable] + arguments, environment: environment,
                                                workingDirectory: workingDirectory, output: outFD, stdin: stdin, stderr: errFD)
        } catch {
            if readEnd >= 0 { close(readEnd); close(writeEnd) }
            return Result(launched: false, status: -1, output: Data(), timedOut: false, error: "could not start \(executable): \(error)")
        }
        spawned?(child.pid)   // tests only
        var capture: OutputCapture?
        if case .capture(let cap, _) = output {
            close(writeEnd)
            // The reader owns `readEnd` and the sink from here on; it keeps only the tail (`cap` bytes).
            let sink = open("/dev/null", O_WRONLY | O_CLOEXEC)
            capture = OutputCapture(readEnd: readEnd, file: sink, cap: 0, tailBytes: cap, marker: "")
        }
        let deadline = clock() + timeout
        var termAt: TimeInterval?, killAt: TimeInterval?
        var abandoned = false
        while !child.hasExited() {
            let now = clock()
            if termAt == nil, now >= deadline { termAt = now; child.signalGroup(SIGTERM) }
            if let t = termAt, killAt == nil, now - t >= killGrace { killAt = now; child.signalGroup(SIGKILL) }
            if let k = killAt, let abandonAfter, now - k >= abandonAfter { abandoned = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // A leader still there after SIGKILL is left unreaped (never signalled again by us); otherwise sweep, then reap.
        let status = abandoned ? 0 : child.finish()
        let data = capture?.finish(drain: termAt == nil ? 2 : 0) ?? Data()
        // An abandoned leader or a lost exit status is never a success (INT-I2).
        if abandoned {
            return Result(launched: true, status: -1, output: data, timedOut: true, error: "\(executable) did not exit after SIGKILL; abandoned")
        }
        if child.lostTrack {
            return Result(launched: true, status: -1, output: data, timedOut: termAt != nil, error: "lost track of \(executable)'s exit status")
        }
        return Result(launched: true, status: ProcessGroupChild.exitCode(status), output: data, timedOut: termAt != nil, error: nil)
    }
}

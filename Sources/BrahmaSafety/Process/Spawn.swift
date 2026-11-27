import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The engine's one process primitive (Plan S, spec §6.5): `posix_spawn` of an ABSOLUTE executable, with argv[0] equal to
/// that path, an explicit environment whose `PATH` holds only absolute entries, an explicit working directory, and (by
/// default) its own process group. Nothing goes through `/usr/bin/env` and nothing is looked up on a `PATH`: the engine
/// names its tools through `ToolPaths`.
///
/// - `run` is a bounded run: standard input from `Input`, standard output and error captured apart (each up to `outputCap`
///   bytes), past `timeout` of awake time SIGTERM to the group, SIGKILL `killGrace` later.
/// - `start` hands back the running child (`Spawn.Child`, a `SandboxedProcess`) for a caller that streams or waits itself.
/// - `ProcessGroupChild.spawn` (checks, turns, previews, the engine's git) starts its child through `launch` too.
public enum Spawn {
    /// What the child reads on standard input.
    public enum Input: Sendable {
        /// `/dev/null`.
        case none
        /// This process's own standard input (an owner's editor on the terminal).
        case inherit
        /// These bytes, written through a pipe by a feeder thread; the pipe closes when they are written.
        case data(Data)
        /// This descriptor; the caller keeps it and closes it.
        case descriptor(Int32)
    }

    /// Where a started child's standard output or error goes.
    public enum Sink: Sendable {
        /// `/dev/null`.
        case null
        /// This process's own (an owner's editor on the terminal).
        case inherit
        /// This descriptor; the caller keeps it and closes it.
        case descriptor(Int32)
    }

    /// Whether the child leads a new process group (the default: what Foundation's `Process` did too), a new session (a
    /// turn's `claude`), or stays in the engine's group (`group: false`).
    enum Leadership: Sendable { case none, group, session }

    /// A bounded run's result.
    public struct Output: Sendable, Equatable {
        /// The exit code, or 128 + the signal that ended it; -1 when its exit status was lost or it would not die.
        public var status: Int32
        public var stdout: Data
        public var stderr: Data
        /// The timeout stopped it.
        public var timedOut: Bool
        /// More than `outputCap` bytes arrived on standard output or error; the rest was read and dropped.
        public var truncated: Bool
    }

    /// The child could not be started (or was refused before anything started: `validate`).
    public struct Failure: Error, CustomStringConvertible, Equatable, Sendable {
        public let message: String
        public init(message: String) { self.message = message }
        public var description: String { message }
    }

    /// What was started, for tests (`observer`).
    public struct Spawned: Sendable, Equatable {
        public let executable: String
        public let arguments: [String]
        /// The working directory by path; nil when it was given as a descriptor (`fchdir`).
        public let cwd: String?
    }

    /// Tests only: told about every child started in this task (synchronously, before the spawn).
    @TaskLocal public static var observer: (@Sendable (Spawned) -> Void)?

    /// Once SIGKILL has been sent, how long a bounded run waits for the leader before it gives up on it (as `GroupExec`).
    public static let abandonAfter: Duration = .seconds(10)
    /// How long a bounded run waits for the end of its output after a normal exit (a grandchild outside the group may hold it).
    public static let drainAfterExit: TimeInterval = 2

    /// Only an absolute executable starts. A bare or relative name is a programming error: the engine names every tool by its
    /// `ToolPaths` entry and never searches a `PATH` (a relative entry would name the child's working directory).
    public static func validate(_ executable: String) -> Decision<String> {
        guard executable.hasPrefix("/") else {
            return .deny("'\(executable)' is not an absolute path: the engine starts a tool only by its absolute path (ToolPaths), never through a PATH lookup")
        }
        guard !executable.contains("\0") else { return .deny("the executable path holds a NUL byte, so it is not an absolute path") }
        return .allow(executable, because: "an absolute path")
    }

    /// `path` with only its absolute entries: an empty or relative entry names the child's working directory.
    public static func sanitizedPath(_ path: String) -> String {
        path.split(separator: ":", omittingEmptySubsequences: true).filter { $0.hasPrefix("/") }.joined(separator: ":")
    }

    /// `environment` with its `PATH` sanitized (`sanitizedPath`); no `PATH` is added where there was none.
    public static func sanitized(_ environment: [String: String]) -> [String: String] {
        var env = environment
        if let path = env["PATH"] { env["PATH"] = sanitizedPath(path) }
        return env
    }

    /// One standard stream of the child, as `launch` sets it up.
    enum Stream {
        case null, inherit, fd(Int32)
    }

    /// The one `posix_spawn` of the engine. `arguments` is the whole argv (argv[0] included). `cwdDescriptor`: an open
    /// directory the child `fchdir`s into instead of `cwd`'s path (an agent-retargetable path is never resolved for it).
    /// Every descriptor but the three streams is closed in the child (Darwin), signals are default and unmasked. Throws
    /// `Failure` when the executable is not absolute or the child cannot be started.
    static func launch(executable: String, arguments: [String], environment: [String: String], cwd: URL, cwdDescriptor: Int32?,
                       stdin: Stream, stdout: Stream, stderr: Stream, leadership: Leadership) throws -> pid_t {
        if case .deny(let why) = validate(executable) { throw Failure(message: why) }
        observer?(Spawned(executable: executable, arguments: arguments, cwd: cwdDescriptor == nil ? cwd.path : nil))
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        for (fd, stream, mode) in [(Int32(0), stdin, O_RDONLY), (1, stdout, O_WRONLY), (2, stderr, O_WRONLY)] {
            switch stream {
            case .null: posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", mode, 0)
            case .fd(let source): posix_spawn_file_actions_adddup2(&actions, source, fd)
            case .inherit:
                #if canImport(Darwin)
                // Every descriptor not named here is closed (`POSIX_SPAWN_CLOEXEC_DEFAULT`): this one is kept.
                posix_spawn_file_actions_addinherit_np(&actions, fd)
                #endif
            }
        }
        // A chdir action that cannot be queued must never let the child start in this process's directory instead.
        let chdirStatus: Int32
        if let cwdDescriptor {
            #if canImport(Darwin)
            chdirStatus = posix_spawn_file_actions_addfchdir_np(&actions, cwdDescriptor)
            #else
            // Before exec (so before close-on-exec), the child's own descriptor table still holds it.
            chdirStatus = posix_spawn_file_actions_addchdir_np(&actions, "/proc/self/fd/\(cwdDescriptor)")
            #endif
        } else {
            chdirStatus = posix_spawn_file_actions_addchdir_np(&actions, cwd.path)
        }
        guard chdirStatus == 0 else { throw Failure(message: "cannot set the working directory (\(String(cString: strerror(chdirStatus))))") }
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults); sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &mask)
        // A new session makes the child its own group's leader too (setpgid would fail on a session leader).
        var flags = Int32(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        switch leadership {
        case .none: break
        case .group: flags |= Int32(POSIX_SPAWN_SETPGROUP)
        case .session: flags |= Int32(POSIX_SPAWN_SETSID)
        }
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attr, Int16(flags))
        if leadership == .group { posix_spawnattr_setpgroup(&attr, 0) }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = sanitized(environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attr, &argv, &envp)
        guard spawned == 0 else { throw Failure(message: String(cString: strerror(spawned))) }
        return pid
    }

    /// Starts `executable` (argv[0] = `executable`, then `arguments`) and hands back the running child. `group` (default):
    /// it leads a new process group, which its signals and its final sweep reach. `.data` input is fed by a thread of its own.
    public static func start(_ executable: String, _ arguments: [String], cwd: URL, cwdDescriptor: Int32? = nil,
                             env: [String: String], stdin: Input = .none, stdout: Sink = .null, stderr: Sink = .null,
                             group: Bool = true) throws -> Child {
        let feed = try Feed(stdin)
        let child: ProcessGroupChild
        do {
            child = try ProcessGroupChild.start(executable: executable, arguments: [executable] + arguments, environment: env,
                                                cwd: cwd, cwdDescriptor: cwdDescriptor, stdin: feed.stream,
                                                stdout: stream(stdout), stderr: stream(stderr), leadership: group ? .group : .none)
        } catch {
            feed.abandon()
            throw error
        }
        feed.begin()
        return Child(child)
    }

    /// A bounded run (see the type's comment). `outputCap` bytes of each stream are kept (0: none; the rest is read and
    /// dropped, `truncated`). A leader still there `abandonAfter` past its SIGKILL is left (status -1, never a success).
    public static func run(_ executable: String, _ arguments: [String], cwd: URL, cwdDescriptor: Int32? = nil,
                           env: [String: String], stdin: Input = .none, timeout: Duration, outputCap: Int,
                           group: Bool = true, killGrace: Duration = .seconds(1)) throws -> Output {
        let out = try pipePair(), err: (read: Int32, write: Int32)
        do { err = try pipePair() } catch { close(out.read); close(out.write); throw error }
        let child: Child
        do {
            child = try start(executable, arguments, cwd: cwd, cwdDescriptor: cwdDescriptor, env: env, stdin: stdin,
                              stdout: .descriptor(out.write), stderr: .descriptor(err.write), group: group)
        } catch {
            for fd in [out.read, out.write, err.read, err.write] { close(fd) }
            throw error
        }
        close(out.write); close(err.write)
        let stdoutReader = CapReader(fd: out.read, cap: outputCap), stderrReader = CapReader(fd: err.read, cap: outputCap)
        let deadline = AwakeTime.uptime() + seconds(timeout)
        var termAt: TimeInterval?, killAt: TimeInterval?, abandoned = false
        while !child.process.hasExited() {
            let now = AwakeTime.uptime()
            if termAt == nil, now >= deadline { termAt = now; child.process.signalGroup(SIGTERM) }
            if let t = termAt, killAt == nil, now - t >= seconds(killGrace) { killAt = now; child.process.signalGroup(SIGKILL) }
            if let k = killAt, now - k >= seconds(abandonAfter) { abandoned = true; break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // A leader still there after SIGKILL is left unreaped (never signalled again by us); otherwise sweep, then reap.
        let raw = abandoned ? 0 : child.process.finish()
        let drain = termAt == nil ? drainAfterExit : 0
        let (stdout, cutOut) = stdoutReader.finish(drain: drain), (stderr, cutErr) = stderrReader.finish(drain: drain)
        let status: Int32 = abandoned || child.process.lostTrack ? -1 : ProcessGroupChild.exitCode(raw)
        return Output(status: status, stdout: stdout, stderr: stderr, timedOut: termAt != nil, truncated: cutOut || cutErr)
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func stream(_ sink: Sink) -> Stream {
        switch sink {
        case .null: return .null
        case .inherit: return .inherit
        case .descriptor(let fd): return fd >= 0 ? .fd(fd) : .null
        }
    }

    /// A pipe whose two ends are close-on-exec (no other child ever holds them; the child's end is dup'ed onto 0, 1 or 2).
    public static func pipePair() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw Failure(message: "no pipe (\(String(cString: strerror(errno))))") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (fds[0], fds[1])
    }

    /// A child `start` started: a `SandboxedProcess` over its `ProcessGroupChild` (signalled only while unreaped).
    public final class Child: SandboxedProcess, @unchecked Sendable {
        let process: ProcessGroupChild

        init(_ process: ProcessGroupChild) { self.process = process }

        public var pid: Int32 { process.pid }
        public var leaderStart: Double? { process.leaderStart }
        public func isAlive() -> Bool { !process.hasExited() }
        /// Its exit status was lost (reaped from under the engine): never a success.
        public var lostTrack: Bool { process.lostTrack }

        /// The exit code (or 128 + signal) once it has ended (it is reaped then); -1 when its exit status was lost; else nil.
        public func exitStatus() -> Int32? {
            guard process.hasExited() else { return nil }
            let raw = process.finish()
            return process.lostTrack ? -1 : ProcessGroupChild.exitCode(raw)
        }

        /// Sends `sig` to its group (and to it), unless it has been reaped.
        @discardableResult
        public func signal(_ sig: Int32) -> Bool { process.signalGroup(sig) }

        /// Blocks until it exits, sweeps its group, reaps it; returns the raw wait status (the same on every later call).
        @discardableResult
        public func waitStatus() -> Int32 { process.finish() }

        /// Blocking: SIGTERM, up to `grace` of awake time for it to exit, SIGKILL; then it is swept and reaped.
        public func stop(grace: TimeInterval) {
            if !process.hasExited() {
                process.signalGroup(SIGTERM)
                let deadline = AwakeTime.uptime() + grace
                while !process.hasExited(), AwakeTime.uptime() < deadline { usleep(20_000) }
                if !process.hasExited() { process.signalGroup(SIGKILL) }
            }
            process.finish()
        }

        public func terminate(grace: Duration) async {
            let process = self.process
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Thread.detachNewThread {
                    Child(process).stop(grace: Spawn.seconds(grace))
                    continuation.resume()
                }
            }
        }
    }

    /// `Input.data`: the pipe and the thread that writes the bytes into it once the child holds the read end.
    final class Feed: @unchecked Sendable {
        let stream: Stream
        private let pipe: (read: Int32, write: Int32)?
        private let data: Data

        init(_ input: Input) throws {
            switch input {
            case .none: stream = .null; pipe = nil; data = Data()
            case .inherit: stream = .inherit; pipe = nil; data = Data()
            case .descriptor(let fd): stream = fd >= 0 ? .fd(fd) : .null; pipe = nil; data = Data()
            case .data(let bytes):
                let p = try Spawn.pipePair()
                #if canImport(Darwin)
                // A child that stops reading makes the write fail here (EPIPE), never a SIGPIPE to the engine.
                _ = fcntl(p.write, F_SETNOSIGPIPE, 1)
                #endif
                stream = .fd(p.read); pipe = p; data = bytes
            }
        }

        /// The child holds the read end now: close ours and write the bytes on a thread, then close the write end.
        func begin() {
            guard let pipe else { return }
            close(pipe.read)
            let (fd, bytes) = (pipe.write, data)
            Thread.detachNewThread {
                bytes.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; break }
                        offset += n
                    }
                }
                close(fd)
            }
        }

        /// The child never started: both ends go.
        func abandon() {
            guard let pipe else { return }
            close(pipe.read); close(pipe.write)
        }
    }

    /// Reads one stream of a bounded run on its own thread: the first `cap` bytes are kept, the rest read and dropped. The
    /// thread owns the descriptor and closes it itself when it is done.
    final class CapReader: @unchecked Sendable {
        private let lock = NSLock()
        private var kept = Data()
        private var cut = false
        private var stopFlag = false
        private let done = DispatchSemaphore(value: 0)

        init(fd: Int32, cap: Int) {
            Thread.detachNewThread { [self] in
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                reading: while !stopped {
                    var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let ready = poll(&pfd, 1, 100)
                    if ready < 0 { if errno == EINTR { continue }; break }
                    if ready == 0 { continue }
                    let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                    if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; break reading }
                    if n == 0 { break reading }
                    lock.withLock {
                        let room = max(0, cap - kept.count)
                        if room > 0 { kept.append(contentsOf: buffer[0..<min(room, n)]) }
                        if n > room { cut = true }
                    }
                }
                close(fd)
                done.signal()
            }
        }

        private var stopped: Bool { lock.withLock { stopFlag } }

        /// Waits up to `drain` seconds for the end of the stream, then stops the reader; what was kept, and whether more came.
        func finish(drain: TimeInterval) -> (Data, Bool) {
            if done.wait(timeout: .now() + drain) == .timedOut {
                lock.withLock { stopFlag = true }
                done.wait()
            }
            return lock.withLock { (kept, cut) }
        }
    }
}

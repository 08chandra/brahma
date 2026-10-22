import Foundation

/// What one run of a check came to. `exitCode` is nil when the command did not finish by itself (timed out, or could not
/// be started: then `timedOut` is false and `tail` says why).
public struct CheckOutcome: Equatable, Sendable {
    public var exitCode: Int32?
    public var timedOut: Bool
    /// The last `ProcessCheckRunner.tailChars` characters of the output.
    public var tail: String

    public init(exitCode: Int32?, timedOut: Bool, tail: String) {
        self.exitCode = exitCode; self.timedOut = timedOut; self.tail = tail
    }
}

/// Runs a check command. Never throws: whatever goes wrong is part of the outcome.
public protocol CheckRunning: Sendable {
    func run(command: String, workingDirectory: URL, timeout: TimeInterval, outputURL: URL,
             environment: [String: String]) async -> CheckOutcome
}

/// `/bin/sh -c <command>` in its own process group, stdin `/dev/null`, exactly the environment it is given. The first
/// 1 MB of output goes to `outputURL` (`[output truncated]` appended once); the outcome carries the real last 4000
/// characters. On timeout the whole group gets SIGTERM, and SIGKILL `termGrace` seconds later. When the shell exits, any
/// process it left behind is killed too, so a check cannot leave a server running.
public struct ProcessCheckRunner: CheckRunning {
    public static let outputCap = 1_048_576
    public static let tailChars = 4000
    public static let truncationMarker = "[output truncated]"
    /// Bytes kept to build the tail from (a character is at most 4 bytes).
    private static let tailBytes = tailChars * 4

    public var termGrace: TimeInterval

    public init(termGrace: TimeInterval = 5) { self.termGrace = termGrace }

    public func run(command: String, workingDirectory: URL, timeout: TimeInterval, outputURL: URL,
                    environment: [String: String]) async -> CheckOutcome {
        let cancel = CancelFlag()
        let grace = termGrace
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CheckOutcome, Never>) in
                // A thread of its own: a check can run for an hour and must not occupy a Dispatch or Swift concurrency worker.
                let thread = Thread {
                    continuation.resume(returning: Self.runBlocking(command: command, workingDirectory: workingDirectory,
                                                                    timeout: timeout, outputURL: outputURL,
                                                                    environment: environment, termGrace: grace, cancel: cancel))
                }
                thread.name = "brahma-check"
                thread.start()
            }
        } onCancel: { cancel.set() }
    }

    // MARK: Blocking implementation

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// The reader's results, written by the reader thread and read after it has finished.
    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var _stop = false
        private var _tail = Data()
        private var _truncated = false
        func stop() { lock.withLock { _stop = true } }
        var stopped: Bool { lock.withLock { _stop } }
        func add(tail chunk: Data) {
            lock.withLock {
                _tail.append(chunk)
                if _tail.count > ProcessCheckRunner.tailBytes { _tail.removeFirst(_tail.count - ProcessCheckRunner.tailBytes) }
            }
        }
        func markTruncated() { lock.withLock { _truncated = true } }
        var tail: Data { lock.withLock { _tail } }
        var truncated: Bool { lock.withLock { _truncated } }
    }

    private static func fail(_ message: String, outputURL: URL) -> CheckOutcome {
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? message.write(to: outputURL, atomically: true, encoding: .utf8)
        return CheckOutcome(exitCode: nil, timedOut: false, tail: message)
    }

    private static func tailText(_ data: Data) -> String {
        var text = String(decoding: data, as: UTF8.self)
        // A cut inside a multi-byte character leaves replacement characters at the start.
        while text.first == "\u{FFFD}" { text.removeFirst() }
        return String(text.suffix(tailChars))
    }

    private static func runBlocking(command: String, workingDirectory: URL, timeout: TimeInterval, outputURL: URL,
                                    environment: [String: String], termGrace: TimeInterval, cancel: CancelFlag) -> CheckOutcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: workingDirectory.path, isDirectory: &isDir), isDir.boolValue else {
            return fail("could not start the check: \(workingDirectory.path) is not a directory", outputURL: outputURL)
        }
        do { try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
            return fail("could not start the check: no place for its output (\(error))", outputURL: outputURL)
        }
        let file = open(outputURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        _ = fcntl(file, F_SETFD, FD_CLOEXEC)
        guard file >= 0 else { return CheckOutcome(exitCode: nil, timedOut: false, tail: "could not start the check: cannot open its output file") }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            close(file)
            return fail("could not start the check: no pipe (\(String(cString: strerror(errno))))", outputURL: outputURL)
        }
        let (readEnd, writeEnd) = (fds[0], fds[1])
        // Neither end may leak into children spawned meanwhile (a leaked write end would hold the pipe open).
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC); _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        #else
        var actions = posix_spawn_file_actions_t()
        var attr = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attr) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults); sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &mask)
        var flags = Int32(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        #if canImport(Darwin)
        flags |= Int32(POSIX_SPAWN_CLOEXEC_DEFAULT)
        #endif
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = []
        for a in ["/bin/sh", "-c", command] { argv.append(strdup(a)) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = []
        for (k, v) in environment { envp.append(strdup("\(k)=\(v)")) }
        envp.append(nil)
        defer { for p in argv { free(p) }; for p in envp { free(p) } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, envp)
        close(writeEnd)
        guard spawned == 0 else {
            close(readEnd); close(file)
            return fail("could not start the check: \(String(cString: strerror(spawned)))", outputURL: outputURL)
        }

        // Reader: the first `outputCap` bytes to the file, the rest only to the tail buffer.
        let capture = Capture()
        let readerDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var written = 0
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            reading: while !capture.stopped {
                var pfd = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 100)
                if ready < 0 { if errno == EINTR { continue }; break }
                if ready == 0 { continue }
                let n = buffer.withUnsafeMutableBytes { read(readEnd, $0.baseAddress, $0.count) }
                if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; break reading }
                if n == 0 { break reading }
                capture.add(tail: Data(buffer[0..<n]))
                let room = outputCap - written
                if room > 0 {
                    let take = min(room, n)
                    buffer.withUnsafeBytes { _ = write(file, $0.baseAddress, take) }
                    written += take
                }
                if n > room { capture.markTruncated() }
            }
            readerDone.signal()
        }

        // Wait for the shell, enforcing the timeout and cancellation.
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false, cancelled = false
        var termSentAt: Date?, killSent = false
        var status: Int32 = 0
        while true {
            let r = waitpid(pid, &status, WNOHANG)
            if r == pid { break }
            if r < 0 && errno != EINTR { status = 0; break }
            let now = Date()
            if cancel.isSet && !cancelled { cancelled = true; killpg(pid, SIGKILL); killSent = true }
            if !timedOut && !cancelled && now >= deadline {
                timedOut = true
                killpg(pid, SIGTERM)
                termSentAt = now
            }
            if let sent = termSentAt, !killSent, now.timeIntervalSince(sent) >= termGrace {
                killpg(pid, SIGKILL)
                killSent = true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        // The shell is gone; whatever it left in its group goes too.
        killpg(pid, SIGKILL)
        if readerDone.wait(timeout: .now() + 2) == .timedOut {
            // Something outside the group still holds the pipe; take what there is.
            capture.stop()
            _ = readerDone.wait(timeout: .now() + 1)
        }
        close(readEnd)
        if capture.truncated { let m = "\n\(truncationMarker)\n"; _ = m.withCString { write(file, $0, strlen($0)) } }
        close(file)

        let tail = tailText(capture.tail)
        if cancelled { return CheckOutcome(exitCode: nil, timedOut: false, tail: tail) }
        if timedOut { return CheckOutcome(exitCode: nil, timedOut: true, tail: tail) }
        let code: Int32
        if status & 0x7f == 0 { code = (status >> 8) & 0xff }
        else { code = 128 + (status & 0x7f) }
        return CheckOutcome(exitCode: code, timedOut: false, tail: tail)
    }
}

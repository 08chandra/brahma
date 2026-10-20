import Foundation

/// Runs one agent turn and streams its parsed events. The stream throws if the turn did not produce a result.
public protocol TurnRunning: Sendable {
    func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

public enum TurnError: Error, Equatable {
    /// The process ended without emitting a `result` line.
    case exitedWithoutResult(code: Int32, stderrTail: String)
    /// The turn ran longer than `maxTurnDuration` and was killed.
    case timedOut
}

/// Runs `claude -p` as a child process: prompt on stdin, stream-json on stdout.
public struct ClaudeProcessRunner: TurnRunning {
    /// Command name looked up via `/usr/bin/env`, or an absolute path launched directly.
    public var claudePath: String
    public var maxTurnDuration: Duration

    static let stderrLimit = 4096
    static let killGrace: TimeInterval = 5
    /// After the process exits, how long to wait for stdout EOF (a grandchild may still hold the pipe).
    static let drainGrace: TimeInterval = 2

    public init(claudePath: String = "claude", maxTurnDuration: Duration = .seconds(900)) {
        self.claudePath = claudePath
        self.maxTurnDuration = maxTurnDuration
    }

    public func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await execute(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(_ request: TurnRequest, yield: (StreamEvent) -> Void) async throws {
        let process = Process()
        let args = ClaudeCommand.arguments(for: request)
        if claudePath.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [claudePath] + args
        }
        process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory, isDirectory: true)
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let (lines, lineSink) = AsyncStream.makeStream(of: String.self)
        let splitter = LineSplitter(sink: lineSink)
        stdout.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; splitter.finish() } else { splitter.append(data) }
        }
        let tail = TailBuffer(limit: Self.stderrLimit)
        stderr.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { tail.append(data) }
        }
        let exit = ExitWaiter()
        let child = ChildProcess(process)
        process.terminationHandler = { p in
            exit.signal(p.terminationStatus)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGrace) {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                splitter.finish()
            }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        // Write the prompt off-thread: a large prompt can fill the pipe before the child starts reading.
        let input = stdin.fileHandleForWriting
        #if canImport(Darwin)
        // If the child exits without reading stdin, the write must fail with EPIPE, not kill us with SIGPIPE.
        // Linux has no per-fd equivalent; a Linux host must ignore SIGPIPE process-wide.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        let prompt = Data(request.prompt.utf8)
        DispatchQueue.global().async {
            try? input.write(contentsOf: prompt)
            try? input.close()
        }

        let timedOut = Flag()
        let watchdog = Task { [maxTurnDuration] in
            try await Task.sleep(for: maxTurnDuration)
            timedOut.set()
            child.terminate(grace: Self.killGrace)
        }
        defer { watchdog.cancel() }

        var sawResult = false
        await withTaskCancellationHandler {
            for await line in lines {
                guard let event = StreamParser.parse(line: line) else { continue }
                if case .result = event { sawResult = true }
                yield(event)
            }
        } onCancel: {
            child.terminate(grace: Self.killGrace)
        }
        // Stdout can end (or the consumer be cancelled) before the process exits; always reap it.
        if Task.isCancelled { child.terminate(grace: Self.killGrace) }
        let status = await exit.wait()
        process.waitUntilExit()

        try Task.checkCancellation()
        // A result is authoritative even if the process lingered past it and had to be killed.
        if sawResult { return }
        if timedOut.isSet { throw TurnError.timedOut }
        throw TurnError.exitedWithoutResult(code: status, stderrTail: tail.text)
    }
}

/// Splits stdout bytes into lines for an `AsyncStream`.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private let sink: AsyncStream<String>.Continuation

    init(sink: AsyncStream<String>.Continuation) { self.sink = sink }

    func append(_ data: Data) {
        lock.withLock {
            guard !finished else { return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                emit(buffer[buffer.startIndex..<nl])
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !finished else { return }
            finished = true
            if !buffer.isEmpty { emit(buffer); buffer.removeAll() }
            sink.finish()
        }
    }

    private func emit(_ bytes: Data) {
        let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.isEmpty { sink.yield(line) }
    }
}

/// Keeps the last `limit` bytes of stderr.
private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ d: Data) {
        lock.withLock {
            data.append(d)
            if data.count > limit { data = Data(data.suffix(limit)) }
        }
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}

/// Resolves once with the child's exit status.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    func signal(_ s: Int32) {
        let toResume: [CheckedContinuation<Int32, Never>] = lock.withLock {
            status = s
            defer { waiters = [] }
            return waiters
        }
        for w in toResume { w.resume(returning: s) }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { c in
            let done: Int32? = lock.withLock {
                if let status { return status }
                waiters.append(c)
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }
}

/// SIGTERM, then SIGKILL if the child is still alive after the grace period.
private final class ChildProcess: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    private var terminating = false

    init(_ p: Process) { process = p }

    func terminate(grace: TimeInterval) {
        let first = lock.withLock { () -> Bool in
            defer { terminating = true }
            return !terminating
        }
        guard first, process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

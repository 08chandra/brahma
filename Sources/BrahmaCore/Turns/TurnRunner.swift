import Foundation

/// Runs one agent turn and streams its parsed events. The stream throws if the turn did not produce a result.
public protocol TurnRunning: Sendable {
    func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error>
    /// Returns once every child process this runner started has exited. Cancelling a turn ends its stream at
    /// once, before the child is reaped; a shutting-down host waits here so it never leaves orphans behind.
    func waitForChildren() async
    /// Starts the compiled argv of `request` with `--input-format stream-json`, writes `messages` (control requests) and
    /// returns what it printed until each request was answered, the process exited or `timeout` passed. No prompt is sent, so
    /// no model is called. Nil when the runner cannot (test fakes): the doctor's mode-canary is then skipped.
    func control(_ request: TurnRequest, messages: [JSONValue], timeout: Duration) async -> ControlTranscript?
    /// Returns once no turn of `agentId` is in flight and its earlier turns' processes are gone (`records`: where turns are
    /// recorded, so what an earlier engine left is found too): what it killed and what would not die. The engine waits here
    /// first, every turn, every profile. Throws when it cannot finish (its deadline, a cancellation).
    func waitForTurnProcesses(agentId: String, records: URL) async throws -> TurnLeftovers
}

extension TurnRunning {
    public func waitForChildren() async {}
    public func control(_ request: TurnRequest, messages: [JSONValue], timeout: Duration) async -> ControlTranscript? { nil }
    /// A runner that cannot account for its turns' processes fails closed (M11).
    public func waitForTurnProcesses(agentId: String, records: URL) async throws -> TurnLeftovers {
        throw TurnError.earlierTurnStillRunning(pids: [])
    }
}

/// What a control session printed: its stdout lines, and its exit status when it exited by itself.
public struct ControlTranscript: Equatable, Sendable {
    public var exitStatus: Int32?
    public var lines: [String]

    public init(exitStatus: Int32?, lines: [String]) { self.exitStatus = exitStatus; self.lines = lines }
}

public enum TurnError: Error, Equatable {
    /// The process ended without emitting a `result` line.
    case exitedWithoutResult(code: Int32, stderrTail: String)
    /// The turn ran longer than its wall clock and was killed by the engine (also after an early `result` with background
    /// work still pending).
    case timedOut
    /// The process was stopped from outside (SIGTERM, a kill) before the turn finished: either it ended with no result
    /// after a SIGTERM, or it was killed with background work (`pendingTasks`) still running, even if an early `result`
    /// had been printed. Never counted against the agent. The engine's own wall-clock kill is `timedOut`.
    case interrupted(pendingTasks: Int)
    /// Processes of an earlier turn of the agent could not be killed: no new turn of it starts. Empty `pids`: the runner cannot
    /// account for its turns' processes at all (fails closed, M11).
    case earlierTurnStillRunning(pids: [Int32])
    /// An earlier turn of the agent was still in flight in this process (its slot in the turn registry still held) after
    /// `waitedSeconds` of awake time: no new turn of it starts. No pid is involved: the earlier turn has not ended yet.
    case earlierTurnInFlight(waitedSeconds: Int)
    /// The turn's leader could not be recorded under the run directory right after the spawn (M8): the owner-command ancestry
    /// check would not know it, so the turn is stopped (fail closed) and the reason logged.
    case leaderNotRecorded(reason: String)
}

extension TurnError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .exitedWithoutResult(let code, let tail): "exitedWithoutResult(code: \(code), stderrTail: \(tail.debugDescription))"
        case .timedOut: "timedOut"
        case .interrupted(let n): "interrupted(pendingTasks: \(n))"
        case .earlierTurnStillRunning(let pids) where pids.isEmpty:
            "sandbox scope: the processes of an earlier turn could not be accounted for by this runner"
        case .earlierTurnStillRunning(let pids):
            "sandbox scope: processes of an earlier turn are still running (pid \(pids.map(String.init).joined(separator: ", ")))"
        case .earlierTurnInFlight(let seconds):
            "an earlier turn of this agent was still in flight after \(seconds) s; this turn did not start"
        case .leaderNotRecorded(let reason): "the turn's leader could not be recorded (\(reason)); the turn was stopped"
        }
    }
}

/// Runs `claude -p` as a child process: prompt on stdin, stream-json on stdout.
public struct ClaudeProcessRunner: TurnRunning {
    /// Command name looked up via `/usr/bin/env`, or an absolute path launched directly.
    public var claudePath: String
    /// The wall clock of a turn whose request names none (`TurnProfile.wallClock`): the Plan 1 fallback.
    public var maxTurnDuration: Duration
    /// What `ChildEnvironment` filters. Tests inject one; production uses this process's environment.
    public var baseEnvironment: [String: String]
    /// Waits out a turn's wall clock before the engine kills it. Production sleeps; tests inject one that returns when their
    /// condition holds, so the kill is deterministic rather than a race against a real timer.
    /// Production counts awake time (`AwakeTime`): a turn frozen by a system sleep is not killed on wake for the time it slept.
    public var wallClockSleep: @Sendable (Duration) async throws -> Void = { try await AwakeTime.sleep(for: $0) }

    private static let live = LiveCount()
    /// Every agent's turns in flight and what their sweeps could not kill.
    static let registry = TurnRegistry()
    /// Arguments placed before the compiled argv (tests run `/bin/sh -c <script>` as the CLI). Empty in production.
    var leadingArguments: [String] = []

    static let stderrLimit = 4096
    static let killGrace: TimeInterval = 5
    /// After the process exits, how long to wait for stdout EOF (a grandchild may still hold the pipe).
    static let drainGrace: TimeInterval = 2

    public init(claudePath: String = "claude", maxTurnDuration: Duration = .seconds(900),
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.claudePath = claudePath
        self.maxTurnDuration = maxTurnDuration
        self.baseEnvironment = baseEnvironment
    }

    /// Exit code of a process that died of SIGTERM: 143 through a shell wrapper, the signal number itself from Foundation.
    static func isSigterm(_ status: Int32) -> Bool { status == 143 || status == SIGTERM }

    public func waitForChildren() async {
        await waitForChildren(pollInterval: .milliseconds(20))
    }

    public func waitForTurnProcesses(agentId: String, records: URL) async throws -> TurnLeftovers {
        try await Self.registry.waitUntilGone(agentId, records: records, deadline: Self.turnWaitDeadline)
    }

    /// How long a turn waits for the agent's previous turn to be swept before it fails closed: the kill grace, the drains and
    /// the sweep rounds with room to spare.
    static let turnWaitDeadline: Duration = .seconds(60)

    /// `onPoll` runs once per check of the live count; tests use it to prove the wait sleeps between checks.
    func waitForChildren(pollInterval: Duration = .milliseconds(20), onPoll: @escaping @Sendable () -> Void = {}) async {
        // Detached so a cancelled caller (the Ctrl-C path) still waits: Task.sleep would throw at once and spin.
        await Task.detached {
            while true {
                onPoll()
                if Self.live.count == 0 { break }
                try? await Task.sleep(for: pollInterval)
            }
        }.value
    }

    public func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        // Counted before the stream is handed out, so there is no window where a turn exists but is not tracked.
        Self.live.begin()
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { Self.live.end() }
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

    public func control(_ request: TurnRequest, messages: [JSONValue], timeout: Duration) async -> ControlTranscript? {
        let profile = TurnProfileCompiler.profile(for: request)
        guard (try? TurnProfileCompiler.validate(profile)) != nil else { return ControlTranscript(exitStatus: nil, lines: []) }
        var args = TurnProfileCompiler.arguments(profile)
        args.insert(contentsOf: ["--input-format", "stream-json"], at: 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let input = messages.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) + "\n" }.joined()
        let ids = Set(messages.compactMap { $0.objectValue?["request_id"]?.stringValue })
        let claude = claudePath
        let env = ChildEnvironment.make(base: baseEnvironment, extra: profile.environment, engineClaudeVars: profile.environment,
                                        purpose: .claude, allowBuiltinAgentsSwitch: profile.builtinAgentsDisabled)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        return await Task.detached { () -> ControlTranscript? in
            let process = Process()
            if claude.hasPrefix("/") {
                process.executableURL = URL(fileURLWithPath: claude); process.arguments = args
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = [claude] + args
            }
            process.environment = env
            process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory, isDirectory: true)
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            let collected = ControlLines(waitingFor: ids)
            stdout.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil } else { collected.append(data) }
            }
            do { try process.run() } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                return nil
            }
            #if canImport(Darwin)
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            #endif
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            let deadline = AwakeTime.uptime() + seconds
            while AwakeTime.uptime() < deadline, process.isRunning, !collected.done { usleep(20_000) }
            let exitedByItself = !process.isRunning
            try? stdin.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let killAt = AwakeTime.uptime() + Self.killGrace
                while process.isRunning, AwakeTime.uptime() < killAt { usleep(20_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            usleep(50_000)
            stdout.fileHandleForReading.readabilityHandler = nil
            return ControlTranscript(exitStatus: exitedByItself ? process.terminationStatus : nil, lines: collected.lines)
        }.value
    }

    private func execute(_ request: TurnRequest, yield: (StreamEvent) -> Void) async throws {
        var request = request
        // One compiled profile: its argv and its engine-set environment (the only source of `CLAUDE_CODE_*` controls).
        var profile = TurnProfileCompiler.profile(for: request)
        try TurnProfileCompiler.validate(profile)
        let agentId = request.agent.id
        // Nothing of an earlier turn of this agent may still run when this one starts (1a re-review, binding): claim the agent's
        // slot (one step: nothing running, then begin), then kill what earlier turns, of this engine or an earlier one, left.
        try Task.checkCancellation()
        try await Self.registry.claim(agentId, deadline: Self.turnWaitDeadline)
        var claimed = true
        defer { if claimed { Self.registry.end(agentId, survivors: []) } }
        let earlier = try await Task.detached { [records = request.turnRecordDirectory] in
            try records.map { try TurnRecords.reap(agentId: agentId, in: $0) } ?? TurnLeftovers()
        }.value
        if !earlier.survivors.isEmpty { throw TurnError.earlierTurnStillRunning(pids: earlier.survivors) }
        // The scope may be some time old: its link walk again, and the cwd it starts in must be the scope's own. A grant read
        // path that is no longer pinned (a link put in its place) is dropped for this turn, and the settings written again.
        if profile.permission == .sandboxed, var scope = request.sandbox {
            let dropped = try scope.recheckBeforeSpawnDroppingGrants()
            for url in dropped {
                yield(.sandboxNote("@\(request.agent.name): read-path grant \(url.path) left out of this turn at its start: a link or "
                                   + "alias was put where the approved directory was"))
            }
            if !dropped.isEmpty {
                let gone = Set(dropped.map(\.path))
                request.sandbox = scope
                request.addDirs.removeAll { gone.contains($0) }
                profile = TurnProfileCompiler.profile(for: request)
                try TurnProfileCompiler.validate(profile)
                if let path = request.settingsFilePath {
                    try SettingsFile.write(try TurnProfileCompiler.settingsJSON(profile), to: URL(fileURLWithPath: path))
                }
            }
        }
        let args = TurnProfileCompiler.arguments(profile)
        let executable: String, argv: [String]
        if claudePath.hasPrefix("/") {
            executable = claudePath
            argv = [claudePath] + leadingArguments + args
        } else {
            executable = "/usr/bin/env"
            argv = ["env", claudePath] + leadingArguments + args
        }
        let environment = ChildEnvironment.make(base: baseEnvironment, extra: profile.environment,
                                                engineClaudeVars: profile.environment, purpose: .claude, secrets: request.secrets,
                                                allowBuiltinAgentsSwitch: profile.builtinAgentsDisabled)

        // The parent's ends are close-on-exec, so no other child ever holds them; the child's ends are dup'ed onto 0, 1, 2.
        func makePipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { throw CocoaError(.fileWriteUnknown) }
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            return (fds[0], fds[1])
        }
        let inPipe = try makePipe()
        let outPipe: (read: Int32, write: Int32)
        let errPipe: (read: Int32, write: Int32)
        do { outPipe = try makePipe() } catch { close(inPipe.read); close(inPipe.write); throw error }
        do { errPipe = try makePipe() } catch {
            for fd in [inPipe.read, inPipe.write, outPipe.read, outPipe.write] { close(fd) }
            throw error
        }
        // A sandboxed turn's processes are also known by their sandbox: its unremovable marker (Task 2's mechanism).
        let probe = profile.permission == .sandboxed ? request.containmentMarker.map { SandboxProbe(machMarker: $0) } : nil
        // Recorded before the spawn (and the leader added right after), so an engine that dies mid-turn leaves the next one
        // enough to kill what is left (B-I1). A turn that cannot be recorded does not start.
        let since = ProcessTable.startStamp(slack: 1)
        var record = TurnRecord(leader: 0, leaderStart: since, since: since, machMarker: probe?.machMarker)
        let child: TurnChild
        do {
            if let dir = request.turnRecordDirectory { try TurnRecords.add(record, agentId: agentId, in: dir) }
            try Task.checkCancellation()
            child = try TurnChild.spawn(executable: executable, arguments: argv, environment: environment,
                                        workingDirectory: profile.workingDirectory,
                                        stdin: inPipe.read, stdout: outPipe.write, stderr: errPipe.write, probe: probe, since: since)
        } catch {
            for fd in [inPipe.read, inPipe.write, outPipe.read, outPipe.write, errPipe.read, errPipe.write] { close(fd) }
            if let dir = request.turnRecordDirectory { try? TurnRecords.replace(record, with: nil, agentId: agentId, in: dir) }
            throw error
        }
        claimed = false   // from here the sweep below ends the claim, with what it could not kill
        yield(.spawned(pid: child.pid))
        // Fail closed (M8): a leader the records do not know is a hole in the owner-command ancestry check, so a turn whose
        // leader record cannot be written is stopped now and the owner told why.
        var leaderUnrecorded: String?
        if let dir = request.turnRecordDirectory, let start = ProcessTable.entry(child.pid)?.start {
            let withLeader = TurnRecord(leader: child.pid, leaderStart: start, since: since, machMarker: record.machMarker)
            do {
                try TurnRecords.replace(record, with: withLeader, agentId: agentId, in: dir)
                record = withLeader
            } catch {
                leaderUnrecorded = Store.flat("\(error)", max: 300)
                yield(.sandboxNote("@\(request.agent.name): the turn's leader (pid \(child.pid)) could not be recorded "
                                   + "(\(leaderUnrecorded ?? "")); the owner-command guard would not see it, so the turn was stopped"))
                child.terminate(grace: Self.killGrace)
            }
        }
        let unrecorded = leaderUnrecorded
        close(inPipe.read); close(outPipe.write); close(errPipe.write)
        let input = FileHandle(fileDescriptor: inPipe.write, closeOnDealloc: true)
        let stdout = FileHandle(fileDescriptor: outPipe.read, closeOnDealloc: true)
        let stderr = FileHandle(fileDescriptor: errPipe.read, closeOnDealloc: true)

        let (lines, lineSink) = AsyncStream.makeStream(of: String.self)
        let splitter = LineSplitter(sink: lineSink)
        stdout.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; splitter.finish() } else { splitter.append(data) }
        }
        let stderrReader = StderrReader(stderr, limit: Self.stderrLimit)
        stderrReader.start()
        let exit = ExitWaiter()
        // The leader's exit is noticed without reaping it: it stays a zombie until every process of the turn is swept.
        Thread.detachNewThread {
            let status = child.waitForExit()
            exit.signal(status)
            // Stderr is not cut here: the turn drains what is left of it itself once the process is gone (below).
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.drainGrace) {
                stdout.readabilityHandler = nil
                splitter.finish()
            }
        }

        // Write the prompt off-thread: a large prompt can fill the pipe before the child starts reading.
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
        let wallClock = profile.wallClock ?? maxTurnDuration
        let sleep = wallClockSleep
        let watchdog = Task {
            try await sleep(wallClock)
            timedOut.set()
            child.terminate(grace: Self.killGrace)
        }
        defer { watchdog.cancel() }

        var state = TurnStreamState()
        await withTaskCancellationHandler {
            for await line in lines {
                guard unrecorded == nil else { continue }
                if request.emitRawLines { yield(.raw(line)) }
                guard let events = StreamParser.parseAll(line: line) else { continue }
                for event in events {
                    state.apply(event)
                    yield(event)
                }
            }
        } onCancel: {
            child.terminate(grace: Self.killGrace)
        }
        // Stdout can end (or the consumer be cancelled) before the process exits; always reap it.
        if Task.isCancelled { child.terminate(grace: Self.killGrace) }
        let status = await exit.wait()

        // The last of stderr may still be in its pipe when the process is gone; give it until the drain grace (bounded by the
        // clock, not by a count of sleeps, which stretch on a loaded machine).
        let stderrDeadline = AwakeTime.deadline(after: .seconds(Self.drainGrace) + .milliseconds(500))
        while !stderrReader.isClosed, AwakeTime.now < stderrDeadline { try? await Task.sleep(for: .milliseconds(5)) }
        // Not closed in time (a grandchild may hold the pipe, or the handler is slow on a loaded machine): whatever the
        // process wrote before it exited is still in the pipe, so it is read now, without waiting, and nothing is lost.
        // The drain stops the handler first, so no handler read can race it (a no-op once the pipe has closed).
        stderrReader.drain()
        stdout.readabilityHandler = nil
        let stderrTail = stderrReader.text
        // Every process of the turn goes (its group, its session, its watched descendants, whatever carries its marker), then
        // the leader is reaped; off the cooperative pool (it waits between kill rounds). On every path, cancelled or not.
        let left = await withCheckedContinuation { (c: CheckedContinuation<[ProcessEntry], Never>) in
            DispatchQueue.global().async { c.resume(returning: child.finish()) }
        }
        Self.registry.end(agentId, survivors: left)
        if left.isEmpty, let dir = request.turnRecordDirectory { try? TurnRecords.replace(record, with: nil, agentId: agentId, in: dir) }
        if !left.isEmpty {
            FileHandle.standardError.write(Data("brahma: \(left.count) process(es) of @\(request.agent.name)'s turn could not be killed: \(left.map { String($0.pid) }.joined(separator: ", "))\n".utf8))
        }
        if let requested = TurnAudit.effortCap(in: stderrTail) { yield(.effortCapped(requested: requested)) }
        try Task.checkCancellation()
        if let unrecorded { throw TurnError.leaderNotRecorded(reason: unrecorded) }
        let sawResult = state.sawResult
        // The last result is authoritative even if the process lingered past it and had to be killed ...
        if sawResult, !state.hasPendingWork { return }
        // A controlled stop (`--max-budget-usd`, `--max-turns`) is the CLI ending the turn itself, even with a sub-agent still
        // running (probe L-2): the result stands and is booked as the cap it is.
        if sawResult, state.result?.stopReason != nil, !timedOut.isSet, !Self.isSigterm(status) { return }
        // ... unless background work (a workflow, a sub-agent) was still running: an early result then is not the end
        // of the turn. A process that exited by itself (status 0) is the CLI's own decision and stands. The engine's own wall
        // clock is a timeout (failed, backed off, budgeted), never an interruption: an interruption has no backoff and would
        // re-run the turn on every tick for a whole wall clock. Only a kill from outside is an interruption.
        if sawResult, timedOut.isSet { throw TurnError.timedOut }
        if sawResult, status != 0 { throw TurnError.interrupted(pendingTasks: state.pendingTasks.count) }
        if sawResult { return }
        if timedOut.isSet { throw TurnError.timedOut }
        // SIGTERM from outside (a shutdown, a kill) ends the turn without a result; the agent is not at fault.
        if Self.isSigterm(status) { throw TurnError.interrupted(pendingTasks: 0) }
        throw TurnError.exitedWithoutResult(code: status, stderrTail: stderrTail)
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

/// Collects a child's stderr into a bounded tail, never through `FileHandle.availableData`: that raises an uncatchable
/// exception on a read error, and a handler already running when its `readabilityHandler` is cleared still reads. The
/// readability handler and the final `drain()` read the pipe under one lock, each only what `poll` reports is there, so
/// the fd stays blocking, neither reader can wait on the other, and once `drain()` has run a handler still in flight
/// returns without reading.
final class StderrReader: @unchecked Sendable {
    /// Where a readability handler is; tests pause it at `.entered` to force the drain to run while it is in flight.
    enum HandlerPhase: Sendable { case entered, returned }

    private let handle: FileHandle
    private let fd: Int32
    private let tail: TailBuffer
    private let maxRead: Int
    private let onHandler: @Sendable (HandlerPhase) -> Void
    private let lock = NSLock()
    private var stopped = false
    private var eof = false
    private var errors = 0

    init(_ handle: FileHandle, limit: Int, onHandler: @escaping @Sendable (HandlerPhase) -> Void = { _ in }) {
        self.handle = handle
        fd = handle.fileDescriptor
        tail = TailBuffer(limit: limit)
        maxRead = limit * 16
        self.onHandler = onHandler
    }

    func start() {
        // The closure holds `self` until the handler is cleared: at end of file or in `drain()`, which every turn reaches.
        handle.readabilityHandler = { [self] _ in pump() }
    }

    /// The pipe reached end of file (every writer closed it).
    var isClosed: Bool { lock.withLock { eof } }
    /// The last `limit` bytes read.
    var text: String { tail.text }
    /// Reads that failed (EAGAIN, EBADF ...). Always 0: a read happens only when `poll` says it will not block.
    var readErrors: Int { lock.withLock { errors } }

    /// Stops the handler and reads what is in the pipe right now (bounded), without waiting for end of file. Idempotent.
    func drain() {
        handle.readabilityHandler = nil
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            if !eof { readAvailable() }
        }
    }

    private func pump() {
        onHandler(.entered)
        defer { onHandler(.returned) }
        let closed = lock.withLock { () -> Bool in
            guard !stopped, !eof else { return true }
            readAvailable()
            return eof
        }
        if closed { handle.readabilityHandler = nil }
    }

    /// Lock held. Reads while `poll` reports data (or end of file), up to `maxRead` bytes; never blocks.
    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var total = 0
        while total < maxRead {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 0)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return }
            if pfd.revents & Int16(POLLNVAL | POLLERR) != 0 { eof = true; return }
            guard pfd.revents & Int16(POLLIN | POLLHUP) != 0 else { return }
            let n = read(fd, &buffer, min(buffer.count, maxRead - total))
            if n < 0 {
                if errno == EINTR { continue }
                errors += 1; eof = true; return
            }
            if n == 0 { eof = true; return }
            tail.append(Data(buffer[0..<n]))
            total += n
        }
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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// A control session's stdout lines, and whether every awaited `control_response` arrived.
private final class ControlLines: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var _lines: [String] = []
    private var waiting: Set<String>
    static let maxBytes = 1 << 20

    init(waitingFor ids: Set<String>) { waiting = ids }

    func append(_ data: Data) {
        lock.withLock {
            guard buffer.count + data.count < Self.maxBytes else { waiting = []; return }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                _lines.append(line)
                if let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                   obj["type"] as? String == "control_response",
                   let id = (obj["response"] as? [String: Any])?["request_id"] as? String {
                    waiting.remove(id)
                }
            }
        }
    }

    var done: Bool { lock.withLock { waiting.isEmpty } }
    var lines: [String] { lock.withLock { _lines } }
}

/// Number of turns whose child process has not been reaped yet.
private final class LiveCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func begin() { lock.withLock { value += 1 } }
    func end() { lock.withLock { value -= 1 } }
    var count: Int { lock.withLock { value } }
}

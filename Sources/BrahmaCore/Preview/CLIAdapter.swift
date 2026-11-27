import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A CLI preview (Plan 4a Task 5): the surface's `build`, if any, then its `demo`, each run to completion through the runner
/// `deps.runner(for: c)` picks (the sandbox, or a Full company's unsandboxed runner, PR-5), in the fresh export `c.run`, under
/// the context's policy (`PreviewPolicy.oneShot`: it writes only the run).
///
/// The command never writes the output file itself: the runner opens it (`O_NOFOLLOW`) and fills it from the command's pipe,
/// and the engine then caps it at `outputCap` and scrubs it with the store's redactor (`seal`). A file that cannot be scrubbed
/// (no redactor, or one that has not loaded) is removed, never left raw. The build's output goes to the surface's log, sealed
/// the same way; the demo's to `c.outputURL`.
///
/// The result is `ran` (terminal: the runner re-runs it only when `main` moves, the surface changes or a restart is flagged)
/// with `"exit <n>"` or `"timed out after <s> s"`, whatever the exit; a failed build is `failed` and the demo never runs.
/// Every message is engine-composed (never the command's output).
public struct CLIAdapter: PreviewAdapter {
    /// The most a captured output (or a build log) keeps, the truncation marker included.
    public static let outputCap = 1_048_576

    public let deps: PreviewDependencies

    public init(deps: PreviewDependencies) { self.deps = deps }

    public var kind: PreviewKind { .cli }
    public func availability() -> String? { nil }

    public func start(_ c: PreviewContext) async -> PreviewUpdate {
        guard let demo = c.surface.demo else { return PreviewUpdate(status: .failed, message: "a cli preview needs demo") }
        let runner = deps.runner(for: c)
        if let build = c.surface.build {
            let outcome = await runner.run(command: build, cwd: c.run, environment: c.environment, timeout: c.timeouts.build,
                                           outputURL: c.logURL)
            _ = Self.seal(c.logURL, redactor: c.redactor)
            if Task.isCancelled { return PreviewUpdate(status: .stopped, message: nil) }
            if Self.isUnavailable(outcome) { return PreviewUpdate(status: .unavailable, message: UnavailableSandboxRunner.tail) }
            if outcome.timedOut { return PreviewUpdate(status: .failed, message: "build timed out") }
            guard let code = outcome.exitCode else { return PreviewUpdate(status: .failed, message: "build could not run") }
            if code != 0 { return PreviewUpdate(status: .failed, message: "build failed (exit \(code))") }
        }
        let ran = await runDemo(demo, c, runner: runner)
        switch ran.end {
        case .cancelled: return PreviewUpdate(status: .stopped, message: nil)
        case .unavailable: return PreviewUpdate(status: .unavailable, message: UnavailableSandboxRunner.tail)
        case .couldNotRun: return PreviewUpdate(status: .failed, message: "demo could not run")
        case .timedOut: return PreviewUpdate(status: .ran, message: Self.timedOut(c), outputPath: ran.outputPath)
        case .exited(let code): return PreviewUpdate(status: .ran, message: "exit \(code)", outputPath: ran.outputPath)
        }
    }

    /// Nothing keeps running after a start: there is nothing of its own to stop (the runner removes the export).
    public func stop(_ c: PreviewContext, state: PreviewState) async {}

    /// Runs the demo again (not the build) in the run's export: ok when it exits 0, `"<name>: demo exit <n>, <lines> lines"`.
    public func demo(_ c: PreviewContext, state: PreviewState) async -> DemoCapture {
        let name = c.surface.name
        guard let demo = c.surface.demo else { return DemoCapture(ok: false, line: "\(name): no demo") }
        let ran = await runDemo(demo, c, runner: deps.runner(for: c))
        switch ran.end {
        case .exited(let code):
            return DemoCapture(ok: code == 0, line: "\(name): demo exit \(code), \(ran.lines) lines", outputPath: ran.outputPath)
        case .timedOut: return DemoCapture(ok: false, line: "\(name): demo \(Self.timedOut(c))", outputPath: ran.outputPath)
        case .cancelled: return DemoCapture(ok: false, line: "\(name): demo stopped")
        case .unavailable, .couldNotRun: return DemoCapture(ok: false, line: "\(name): demo could not run")
        }
    }

    // MARK: The demo run

    enum End: Equatable { case exited(Int32), timedOut, cancelled, unavailable, couldNotRun }

    struct Ran { var end: End; var outputPath: String?; var lines: Int }

    /// The demo, to completion or `c.timeouts.demo`, its output sealed.
    func runDemo(_ command: String, _ c: PreviewContext, runner: PreviewRoute) async -> Ran {
        let outcome = await runner.run(command: command, cwd: c.run, environment: c.environment, timeout: c.timeouts.demo,
                                       outputURL: c.outputURL)
        let sealed = Self.seal(c.outputURL, redactor: c.redactor)
        let path = sealed.kept ? c.outputURL.path : nil
        if Task.isCancelled { return Ran(end: .cancelled, outputPath: path, lines: sealed.lines) }
        if Self.isUnavailable(outcome) { return Ran(end: .unavailable, outputPath: nil, lines: 0) }
        if outcome.timedOut { return Ran(end: .timedOut, outputPath: path, lines: sealed.lines) }
        guard let code = outcome.exitCode else { return Ran(end: .couldNotRun, outputPath: path, lines: sealed.lines) }
        return Ran(end: .exited(code), outputPath: path, lines: sealed.lines)
    }

    static func timedOut(_ c: PreviewContext) -> String { "timed out after \(c.timeouts.demo.components.seconds) s" }

    /// The runner had no sandbox to run in (`UnavailableSandboxRunner`): nothing ran.
    static func isUnavailable(_ outcome: CheckOutcome) -> Bool {
        outcome.exitCode == nil && !outcome.timedOut && outcome.tail == UnavailableSandboxRunner.tail
    }

    // MARK: Sealing an engine-written output

    /// Makes the engine-written file at `url` safe to keep: opened without following a link and only as a regular file; cut
    /// to `cap` bytes (ending in the truncation marker) when longer; scrubbed in place with `redactor` (`Redactor.scrubFile`;
    /// a lazy loader runs first, as `Store.redact` does). Anything else there, no redactor, one that cannot load, or a scrub
    /// that fails: the file is removed (the entry itself, never what a link points at) and not kept. `lines` counts the kept
    /// file's lines (a last line without a newline counts).
    static func seal(_ url: URL, redactor: Redactor?, cap: Int = outputCap) -> (kept: Bool, lines: Int) {
        func withhold() -> (kept: Bool, lines: Int) {
            var st = stat()
            if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR { unlink(url.path) }
            return (false, 0)
        }
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? (false, 0) : withhold() }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return withhold() }
        if Int(st.st_size) > cap, !truncate(fd, to: cap) { return withhold() }
        guard let redactor else { return withhold() }
        if !redactor.hasLoaded, let load = redactor.takeLoader() { load() }
        do { try redactor.scrubFile(url) } catch { return withhold() }
        // A redaction can be longer than what it replaced.
        guard fstat(fd, &st) == 0 else { return withhold() }
        if Int(st.st_size) > cap, !truncate(fd, to: cap) { return withhold() }
        return (true, lineCount(fd))
    }

    /// Cuts the file to `cap` bytes, the last of them the truncation marker on a line of its own.
    private static func truncate(_ fd: Int32, to cap: Int) -> Bool {
        let marker = Array("\n\(ProcessCheckRunner.truncationMarker)\n".utf8)
        guard cap > marker.count, ftruncate(fd, off_t(cap - marker.count)) == 0 else { return false }
        return marker.withUnsafeBytes { pwrite(fd, $0.baseAddress, marker.count, off_t(cap - marker.count)) } == marker.count
    }

    private static func lineCount(_ fd: Int32) -> Int {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset: off_t = 0, lines = 0, last: UInt8 = UInt8(ascii: "\n")
        while true {
            let n = pread(fd, &buffer, buffer.count, offset)
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { break }
            for byte in buffer[0..<n] where byte == UInt8(ascii: "\n") { lines += 1 }
            last = buffer[n - 1]
            offset += off_t(n)
        }
        return last == UInt8(ascii: "\n") ? lines : lines + 1
    }
}

import Foundation

/// A web preview: the surface's build (if any) to completion, then its server as a long-running process, both under the
/// context's sandbox policy, in the context's fresh export; ready once its URL answers, and only if it listens on the
/// loopback. Every message is engine-composed (never the server's output, which goes only to the log).
public struct WebAdapter: PreviewAdapter {
    /// SIGTERM to a preview's group, then this much awake time before SIGKILL.
    public static let stopGrace: Duration = .seconds(5)
    /// How many times the listen addresses are asked for before an empty answer counts as "could not tell" (deferred minor 3).
    static let listenProbes = 3
    /// One readiness request's own timeout.
    static let probeTimeout: Duration = .seconds(2)

    public let deps: PreviewDependencies

    public init(deps: PreviewDependencies) { self.deps = deps }

    public var kind: PreviewKind { .web }
    public func availability() -> String? { nil }
    public func start(_ c: PreviewContext) async -> PreviewUpdate { await Self.startServer(c, deps: deps) }

    public func stop(_ c: PreviewContext, state: PreviewState) async {
        guard let pid = state.pid, let process = deps.processes.process(pid) else { return }
        await process.terminate(grace: Self.stopGrace)
        deps.processes.remove(pid)
    }

    public static func startServer(_ c: PreviewContext, deps: PreviewDependencies) async -> PreviewUpdate {
        await startServer(c, deps: deps, onSpawn: nil)
    }

    /// The start, in order:
    /// 1. `build`, if set, through `deps.sandbox.run` in `c.run` under `c.policy` with `c.timeouts.build` (output to the log):
    ///    a non-zero exit is `failed("build failed (exit <n>)")`, a timeout `failed("build timed out")`, a run that could not
    ///    happen at all `failed("build could not run")`;
    /// 2. `run` with `{port}` substituted, spawned the same way (its process is put in `deps.processes`; `onSpawn` hears its
    ///    pid); a missing sandbox is `unavailable`;
    /// 3. `GET` of the resolved URL every `poll` until any status answers; an exit first is `failed("exited during start
    ///    (exit <n>)")`, `ready` elapsing is `failed("not reachable at <url> after <s> s")`;
    /// 4. any listen address on the port that is not the loopback is `failed("listens on <addr>; bind to 127.0.0.1 (the
    ///    engine sets HOST and PORT)")`; none known after `listenProbes` asks fails closed the same way ("could not tell");
    /// 5. otherwise `running` at the resolved URL.
    /// Every failure after the spawn terminates the group and removes it from the table first. Cancellation stops the start.
    static func startServer(_ c: PreviewContext, deps: PreviewDependencies, onSpawn: (@Sendable (Int32) async -> Void)?) async -> PreviewUpdate {
        guard let urlText = c.surface.url, let run = c.surface.run, let url = LoopbackURL.resolve(urlText, port: c.port) else {
            return PreviewUpdate(status: .failed, message: "a web preview needs run and url")
        }
        if let build = c.surface.build {
            let outcome = await deps.sandbox.run(command: build, cwd: c.run, environment: c.environment, timeout: c.timeouts.build,
                                                 outputURL: c.logURL, policy: c.policy)
            if Task.isCancelled { return PreviewUpdate(status: .stopped, message: nil) }
            if outcome.timedOut { return PreviewUpdate(status: .failed, message: "build timed out") }
            guard let code = outcome.exitCode else { return PreviewUpdate(status: .failed, message: "build could not run") }
            if code != 0 { return PreviewUpdate(status: .failed, message: "build failed (exit \(code))") }
        }
        let command = run.replacingOccurrences(of: LoopbackURL.placeholder, with: String(c.port))
        let process: any SandboxedProcess
        do {
            process = try deps.sandbox.spawn(command: command, cwd: c.run, environment: c.environment, logURL: c.logURL, policy: c.policy)
        } catch SandboxError.unavailable {
            return PreviewUpdate(status: .unavailable, message: UnavailableSandboxRunner.tail)
        } catch {
            return PreviewUpdate(status: .failed, message: "could not start: \(Store.flat("\(error)", max: 200))")
        }
        deps.processes.insert(process)
        await onSpawn?(process.pid)

        func fail(_ message: String?, status: PreviewStatus = .failed) async -> PreviewUpdate {
            await process.terminate(grace: stopGrace)
            deps.processes.remove(process.pid)
            return PreviewUpdate(status: status, message: message)
        }

        let deadline = AwakeTime.deadline(after: c.timeouts.ready)
        while true {
            if Task.isCancelled { return await fail(nil, status: .stopped) }
            if !process.isAlive() {
                let code = await exitCode(process)
                deps.processes.remove(process.pid)
                return PreviewUpdate(status: .failed, message: "exited during start (exit \(code))")
            }
            let answer = await deps.http.send(method: "GET", url: url, body: nil, timeout: probeTimeout)
            if answer.status != nil { break }
            if AwakeTime.now >= deadline {
                return await fail("not reachable at \(url.absoluteString) after \(c.timeouts.ready.components.seconds) s")
            }
            try? await AwakeTime.sleep(for: c.timeouts.poll)
        }

        // Where it listens: an empty answer means none or "could not tell", so it is asked again, then fails closed.
        var addresses: [String] = []
        for attempt in 0..<listenProbes {
            if attempt > 0 { try? await AwakeTime.sleep(for: c.timeouts.poll) }
            addresses = await offPool { deps.listen.listenAddresses(port: c.port) }
            if !addresses.isEmpty { break }
        }
        let refusalTail = "bind to 127.0.0.1 (the engine sets HOST and PORT)"
        if addresses.isEmpty { return await fail("could not tell where it listens on port \(c.port); \(refusalTail)") }
        if let outside = addresses.first(where: { !LoopbackURL.isLoopback(host: $0) }) {
            return await fail("listens on \(Store.flat(outside, max: 60)); \(refusalTail)")
        }
        return PreviewUpdate(status: .running, message: nil, process: process.pid, resolvedURL: url.absoluteString)
    }

    /// The exit code once the reaper has it (it is reaped right after the leader exits).
    static func exitCode(_ process: any SandboxedProcess) async -> Int32 {
        for _ in 0..<100 {
            if let code = process.exitStatus() { return code }
            try? await AwakeTime.sleep(for: .milliseconds(20))
        }
        return process.exitStatus() ?? -1
    }

    /// Runs a blocking probe (`lsof`) on a thread of its own, never the cooperative pool.
    static func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: body()) }
            thread.name = "brahma-preview-probe"
            thread.start()
        }
    }
}

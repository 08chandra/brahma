import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// A preview adapter whose start ignores nothing but ends only on the test's say-so (Task 9c: a slow preview start at
/// shutdown). `start` opens `entered`, waits until its task is cancelled (the runner's `stopAll` cancels every start), opens
/// `cancelled`, then waits for `mayReturn`.
private final class SlowStartAdapter: PreviewAdapter, @unchecked Sendable {
    let kind: PreviewKind = .cli
    let entered = Gate()
    let cancelled = Gate()
    let mayReturn = Gate()

    func availability() -> String? { nil }

    func start(_ c: PreviewContext) async -> PreviewUpdate {
        entered.open()
        let untilCancelled = Gate()
        await withTaskCancellationHandler { await untilCancelled.wait() } onCancel: { untilCancelled.open() }
        cancelled.open()
        await mayReturn.wait()
        return PreviewUpdate(status: .ran, message: "exit 0")
    }

    func stop(_ c: PreviewContext, state: PreviewState) async {}
}

/// The engine's bounded shutdown (Plan 4a Task 9c): the turn kill and the preview stop run together under one bound, what is
/// still running when it passes is named, and a second quit request kills the recorded groups and records the turns.
@Suite(.scratch) struct EngineShutdownTests {
    /// Two steps that each need the other to have started finish only when they run together.
    @Test func stepsRunConcurrently() async throws {
        let aStarted = Gate(), bStarted = Gate(), bothStarted = Gate()
        let left = await EngineShutdown.run([
            EngineShutdown.Step(name: "a") { aStarted.open(); await bothStarted.wait() },
            EngineShutdown.Step(name: "b") { bStarted.open(); await bothStarted.wait() },
            EngineShutdown.Step(name: "release") { await aStarted.wait(); await bStarted.wait(); bothStarted.open() },
        ], bound: .seconds(20))
        #expect(left == [])
    }

    /// The bound passes: the step still running is named and the others are not. That `run` returns at all is the bound at
    /// work (the gate is never opened before it); no wall-clock assertion, which a loaded test pool would fail.
    @Test func boundNamesWhatIsStillRunning() async throws {
        let never = Gate()
        let left = await EngineShutdown.run([
            EngineShutdown.Step(name: "previews") { await never.wait() },
            EngineShutdown.Step(name: "turn children") {},
        ], bound: .milliseconds(200))
        #expect(left == ["previews"])
        never.open()
    }

    /// An engine with a turn in flight whose child lingers and a preview whose start never ends on its own: the shutdown stops
    /// both together (each side ends only once the other has been asked to stop), well inside the bound, the turn is recorded
    /// `interrupted` and the surface `engine stopped`.
    @Test func turnKillAndPreviewStopRunTogether() async throws {
        let root = try tempDir()
        let data = root.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let store = try Store(path: data.appending(path: "brahma.sqlite").path)
        let slow = SlowStartAdapter()
        var deps = PreviewDependencies.fake()
        var table = PreviewAdapters.defaults(deps)
        table[.cli] = slow
        deps.adapters = table
        let w = try World(store: store, previewDeps: deps)
        let company = try w.company("Acme")
        let devops = try w.hire(company, "devops")
        let f = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        try f.write("README.md", "one")
        try f.git(["add", "-A"])
        try f.git(["commit", "-q", "-m", "change"])
        _ = try store.acceptMainCommit(companyId: company.id)
        let tools = CompanyTools(store: store, companyId: company.id, agentId: devops.id)
        _ = try tools.call(name: "set_preview_command", arguments: ["name": .string("tool"), "kind": .string("cli"), "demo": .string("./demo.sh")])
        // The tool stamps the wall clock; the engine's clock moves past it so the start sees the surface.
        let lag = Date().timeIntervalSince(w.clock.now)
        if lag > -1 { w.clock.advance(lag + 1) }

        // A turn that hangs until the engine cancels it, and children that linger until the preview start has been told to stop.
        let turnRunning = Gate()
        w.fake.script("devops", FakeTurnRunner.Script(gate: Gate()))
        w.fake.onRun = { _ in turnRunning.open() }
        let childrenEntered = Gate()
        let children = Gate()
        w.fake.childrenEntered = childrenEntered
        w.fake.childrenGate = children
        try w.dm(company, devops)
        let waits = Task {
            await slow.cancelled.wait()
            children.open()
        }
        let frees = Task {
            await childrenEntered.wait()
            slow.mayReturn.open()
        }
        let deadline = AwakeTime.deadline(after: .seconds(60))
        while AwakeTime.now < deadline {
            await w.orchestrator.tick()
            if slow.entered.opened, turnRunning.opened { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(slow.entered.opened && turnRunning.opened, "the preview start and the turn are in flight")

        let left = await w.orchestrator.shutdown(bound: .seconds(8))
        #expect(left == [], "both stops ended inside the bound")
        await waits.value
        await frees.value
        let turn = try #require(try w.turns(devops).last)
        #expect(turn.outcome == .interrupted)
        let surface = try #require(try store.previewSurfaces(companyId: company.id).first)
        #expect(try store.previewStates(companyId: company.id)[surface.id]?.message == PreviewRunner.shutdownMessage)
    }

    /// `runForever` cancelled while a turn's children never go: the loop still returns at the bound and names them.
    @Test func runForeverReturnsAtTheBound() async throws {
        let w = try World()
        let never = Gate()
        w.fake.childrenGate = never
        try await w.orchestrator.start()
        let loop = Task { await w.orchestrator.runForever(interval: .milliseconds(20), shutdownBound: .milliseconds(300)) }
        try await Task.sleep(for: .milliseconds(100))
        loop.cancel()
        await loop.value   // returns only because the bound passed: the children's gate is still shut
        #expect(!never.opened)
        never.open()
    }

    /// The second quit request: only recorded groups are signalled (with SIGKILL right away): a check's child under the data
    /// home and a turn's leader under the run directory's turn records, never another process of the owner's. The in-progress
    /// turns are recorded `interrupted` with their agents back to `ready`.
    @Test func forceKillsRecordedGroupsOnlyAndRecordsTurns() async throws {
        let root = try tempDir()
        let data = root.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let store = try Store(path: data.appending(path: "brahma.sqlite").path)
        let w = try World(store: store)
        let company = try w.company("Acme")
        let agent = try w.hire(company, "eng")
        let running = Gate()
        w.fake.script("eng", FakeTurnRunner.Script(gate: Gate()))
        w.fake.onRun = { _ in running.open() }
        try w.dm(company, agent)
        await w.orchestrator.tick()
        await running.wait()
        #expect(try w.agent(agent).state == .running)

        let devnull = open("/dev/null", O_WRONLY)
        defer { close(devnull) }
        func sleeper() throws -> ProcessGroupChild {
            try ProcessGroupChild.spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", "sleep 60"], environment: [:],
                                        workingDirectory: root, output: devnull)
        }
        let recorded = try sleeper()
        let leader = try sleeper()
        let unrecorded = try sleeper()
        let groups = ChildGroups(dir: ChildGroups.directory(runDir: data.appending(path: "run", directoryHint: .isDirectory)), kind: "check")
        try FileManager.default.createDirectory(at: groups.dir, withIntermediateDirectories: true)
        #expect(groups.record(recorded.pid) != nil)
        let turns = w.paths.runDir.appending(path: "turns", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        let start = try #require(ProcessTable.entry(leader.pid)?.start)
        try TurnRecords.add(TurnRecord(leader: leader.pid, leaderStart: start, since: start, machMarker: nil), agentId: agent.id, in: turns)

        let signalled = EngineShutdown.force(store: store, paths: w.paths, now: w.clock.now)
        #expect(signalled.terminated.sorted() == [recorded.pid, leader.pid].sorted())
        let deadline = AwakeTime.deadline(after: .seconds(10))
        while !(recorded.hasExited() && leader.hasExited()), AwakeTime.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(recorded.hasExited())
        #expect(leader.hasExited())
        #expect(!unrecorded.hasExited(), "a process the engine did not record is never signalled")
        unrecorded.signalGroup(SIGKILL)
        _ = recorded.finish()
        _ = leader.finish()
        _ = unrecorded.finish()

        #expect(try w.turns(agent).last?.outcome == .interrupted)
        #expect(try w.agent(agent).state == .ready)
        // The engine's own cancellation still ends the hung turn cleanly.
        _ = await w.orchestrator.shutdown(bound: .seconds(8))
    }
}

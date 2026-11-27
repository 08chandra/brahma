import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaSafety

/// Counts its `stopAll` calls (Task 7c observers).
private actor CountingObserver: EmergencyStopObserver {
    private(set) var reasons: [String] = []
    func stopAll(reason: String) async { reasons.append(reason) }
}

/// A thread-safe count (the fake check's calls).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

/// What a `ChildGroups` observer was told, in order. Waits for an exact event, bounded by awake time (`DispatchTime` does not
/// count sleep), on a thread of its own so no cooperative thread is blocked.
private final class GroupEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [ChildGroups.Event] = []
    private let changed = DispatchSemaphore(value: 0)

    var all: [ChildGroups.Event] { lock.withLock { log } }

    func observe(_ e: ChildGroups.Event) {
        lock.withLock { log.append(e) }
        changed.signal()
    }

    /// The first leader recorded.
    func firstRecorded(within seconds: Int = 60) async throws -> pid_t {
        try await wait(seconds) { log in
            log.lazy.compactMap { if case .recorded(let p) = $0 { p } else { nil } }.first
        }
    }

    /// Returns once `pid`'s record was removed (that event, no other).
    func forgotten(_ pid: pid_t, within seconds: Int = 60) async throws {
        try await wait(seconds) { $0.contains(.forgotten(pid)) ? () : nil }
    }

    private struct TimedOut: Error, CustomStringConvertible {
        let log: [ChildGroups.Event]
        var description: String { "timed out; events so far: \(log)" }
    }

    private func wait<T: Sendable>(_ seconds: Int, _ found: @escaping @Sendable ([ChildGroups.Event]) -> T?) async throws -> T {
        let deadline = DispatchTime.now() + .seconds(seconds)
        let result: Result<T, TimedOut> = await withCheckedContinuation { c in
            Thread {
                while true {
                    let log = self.all
                    if let value = found(log) { c.resume(returning: .success(value)); return }
                    if self.changed.wait(timeout: deadline) == .timedOut, found(self.all) == nil {
                        c.resume(returning: .failure(TimedOut(log: self.all))); return
                    }
                }
            }.start()
        }
        return try result.get()
    }
}

@Suite(.scratch, .serialized) struct EmergencyStopTests {
    // MARK: Engine

    @Test func stopCancelsRunningTurnsAsInterrupted() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let hold = Gate(), started = Gate()
        w.fake.onRun = { _ in started.open() }
        w.fake.script("ceo", .init(gate: hold))
        try w.dm(c, ceo)
        await w.orchestrator.tick()
        await started.wait()
        #expect(await w.orchestrator.runningCount() == 1)

        try w.store.emergencyStop(note: "panic", by: "owner", now: w.clock.now)
        await w.orchestrator.tick()
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(300))
        hold.open()

        #expect(try w.turns(ceo).map(\.outcome) == [.interrupted])
        let agent = try w.agent(ceo)
        #expect(agent.state == .ready, "back to ready, as at quit")
        #expect(agent.consecutiveFailures == 0, "not counted against the agent")
        #expect(try w.pending(ceo) == 1, "its inbox is kept")
    }

    @Test func stopKillsChecksAndRequeuesThem() async throws {
        let w = try World(); let c = try w.company("Acme")
        let mgr = try w.hire(c, "mgr", role: "manager")
        let eng = try w.store.hire(companyId: c.id, name: "eng", role: "engineer", model: "sonnet", managerId: mgr.id)
        let item = try submittedItem(w, c, eng)
        let started = Gate()
        w.checks.onRun { _ in
            started.open()
            // Runs until cancelled, as a real check does until its group is signalled.
            let release = Gate()
            await withTaskCancellationHandler { await release.wait() } onCancel: { release.open() }
            return CheckOutcome(exitCode: nil, timedOut: false, tail: "killed")
        }
        await w.orchestrator.tick()
        await started.wait()

        try w.store.emergencyStop(note: nil, by: "owner", now: w.clock.now)
        await w.orchestrator.tick()
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(300))

        let runs = try runsOf(w, item)
        #expect(runs.map(\.status) == [.queued], "the same run back in the queue: no attempt recorded, never failed (I1)")
        #expect(runs.first?.notBeforeActive == nil, "no delay")
        #expect(try w.store.workItem(id: item.id)?.status == .inReview, "not returned to its holder")
        #expect(w.checks.calls.count == 1)
    }

    /// I1: three stops during one item's check never use up its inconclusive budget; after the resume the check runs at once.
    @Test func threeStopsThenResumeRunsTheCheck() async throws {
        let w = try World(); let c = try w.company("Acme")
        let mgr = try w.hire(c, "mgr", role: "manager")
        let eng = try w.store.hire(companyId: c.id, name: "eng", role: "engineer", model: "sonnet", managerId: mgr.id)
        let item = try submittedItem(w, c, eng)
        let calls = Counter()
        let started = [Gate(), Gate(), Gate()]
        w.checks.onRun { _ in
            let n = calls.next()
            guard n <= 3 else { return CheckOutcome(exitCode: 0, timedOut: false, tail: "ok") }
            started[n - 1].open()
            let release = Gate()
            await withTaskCancellationHandler { await release.wait() } onCancel: { release.open() }
            return CheckOutcome(exitCode: nil, timedOut: false, tail: "killed")
        }
        for round in 1...3 {
            await w.orchestrator.tick()
            await started[round - 1].wait()
            try w.store.emergencyStop(note: nil, by: "owner", now: w.clock.now)
            try await w.cycle()
            let runs = try runsOf(w, item)
            #expect(runs.map(\.status) == [.queued], "round \(round): back in the queue as it was")
            #expect(try w.store.workItem(id: item.id)?.status == .inReview, "round \(round): never handed back")
            try w.store.resumeAfterStop(now: w.clock.now)
        }
        try await w.cycle()
        #expect(w.checks.calls.count == 4, "admitted right after the resume, no 300 s wait")
        let runs = try runsOf(w, item)
        #expect(runs.map(\.status) == [.passed])
        #expect(runs.first?.attempt == 1, "no attempt was spent on the stops")
        let after = try #require(try w.store.workItem(id: item.id))
        #expect(after.status == .inReview); #expect(after.verifiedCommit != nil)
    }

    /// I2: the in-turn poll alone (no tick) cancels a running turn once it reads the stop.
    @Test func pollCancelsTurnWithoutTick() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let hold = Gate(), started = Gate()
        w.fake.onRun = { _ in started.open() }
        w.fake.script("ceo", .init(gate: hold))
        try w.dm(c, ceo)
        await w.orchestrator.tick()
        await started.wait()
        await w.stopPoll.waiting()
        // A poll that reads no stop keeps the turn running.
        w.stopPoll.step()
        await w.stopPoll.waiting()
        #expect(await w.orchestrator.runningCount() == 1)
        try w.store.emergencyStop(note: nil, by: "cli", now: w.clock.now)
        w.stopPoll.step()
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(300))   // no tick in between
        hold.open()
        #expect(try w.turns(ceo).map(\.outcome) == [.interrupted])
        #expect(try w.agent(ceo).state == .ready)
    }

    // MARK: Check and merge process groups (S15)

    /// A real check (`ProcessCheckRunner`, a FakeTools sleeper) is recorded while it runs; signalling the recorded groups the
    /// way `brahma stop` does, with no engine involved, ends it, and its record goes.
    @Test func recordedCheckGroupIsKilledByStop() async throws {
        let dir = try tempDir()
        let events = GroupEvents()
        var made = ChildGroups(dir: dir.appending(path: "children"), kind: "check")
        made.observer = { events.observe($0) }
        let groups = made
        let sleeper = try FakeTools.script("check-sleeper", "sleep 300 & wait")
        let runner = ProcessCheckRunner()
        let output = dir.appending(path: "out.log")
        let run = Task.detached { () async -> CheckOutcome in   // scope-escape: runs the check, no scratch dirs
            await ChildGroups.$current.withValue(groups) { @Sendable () async -> CheckOutcome in
                await runner.run(command: sleeper.path, workingDirectory: dir, timeout: 3600,
                                 outputURL: output, environment: ["PATH": "/usr/bin:/bin"])
            }
        }
        let leader = try await events.firstRecorded()
        let leaders = ChildGroups.liveLeaders(in: groups.dir)
        #expect(leaders.count == 1)
        #expect(leaders == [leader], "the recorded leader, still live: \(events.all)")
        let signalled = EmergencyStop.signalGroups(leaders)
        #expect(signalled.terminated == leaders.sorted())
        let outcome = await run.value
        try await events.forgotten(leader)
        #expect(outcome.exitCode != 0, "\(outcome)")
        #expect(events.all == [.recorded(leader), .forgotten(leader)])
        #expect(ChildGroups.liveLeaders(in: groups.dir).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: groups.dir.path).filter { $0.hasSuffix(".group") }.isEmpty)
    }

    /// A merge's git (`GitCommand.childGroups`) leads its own recorded group: a git stuck mid-command (on its input, standing
    /// in for a hung merge step) is ended by signalling the recorded groups, and the engine's own group is never touched.
    @Test func recordedMergeGitGroupIsKilledByStop() async throws {
        let repo = try tempDir()
        _ = try GitFixture.plainGit(["init", "-q", "-b", "main"], in: repo)
        let events = GroupEvents()
        var made = ChildGroups(dir: try tempDir().appending(path: "children"), kind: "merge")
        made.observer = { events.observe($0) }
        let groups = made
        var git = GitCommand(gitDir: repo.appending(path: ".git"), workTree: repo, commonDir: nil)
        git.tempRoot = try tempDir()
        git.childGroups = groups
        // The config scan before a command runs `git config --list` under the same group, recorded and forgotten first; that
        // short git is not the one under test (killing it, or missing it once it exited, made this pass or fail by timing).
        git.skipsRepositoryCheck = true
        let release = DispatchSemaphore(value: 0)
        let command = git
        let run = Task.detached { () -> String in   // scope-escape: runs one git, no scratch dirs
            let feed: GitCommand.Stdin = .stream({ pipe in
                try pipe.write(Data("partial".utf8))
                release.wait()                           // git waits for the rest of its input
            })
            do { return "status \(try command.run(["hash-object", "--stdin"], allowFailure: true, stdin: feed).status)" }
            catch { return "threw \(error)" }
        }
        let leader = try await events.firstRecorded()
        let leaders = ChildGroups.liveLeaders(in: groups.dir)
        #expect(leaders.count == 1)
        #expect(leaders == [leader], "the recorded git, still live: \(events.all)")
        #expect(!leaders.contains(getpgrp()), "its own group, never the engine's")
        #expect(EmergencyStop.signalGroups(leaders).terminated == leaders.sorted())
        try await events.forgotten(leader)
        release.signal()
        let status = await run.value
        #expect(status != "status 0", "the killed git is not a success: \(status)")
        #expect(ChildGroups.liveLeaders(in: groups.dir).isEmpty)
        #expect(events.all == [.recorded(leader), .forgotten(leader)], "one git, recorded then forgotten")
    }

    @Test func nothingAdmittedWhileStopped() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let eng = try w.hire(c, "eng", role: "engineer")
        _ = try submittedItem(w, c, eng)
        try w.store.emergencyStop(note: nil, by: "cli", now: w.clock.now)
        try w.dm(c, ceo)
        for _ in 0..<3 { try await w.cycle() }
        #expect(w.fake.requests.isEmpty, "no turn")
        #expect(w.checks.calls.isEmpty, "no check")
        #expect(try w.agent(ceo).state == .ready)
        #expect(Scheduler.freeSlots(config: World.config(), running: 0, held: true) == 0)
    }

    /// Final review M1: `brahma mode gates --run` (`ProbeGates.runMissing`) runs no live gate while the owner's stop holds, and
    /// a stop pressed during the run ends it before the next gate.
    @Test func probeGatesRefuseWhileStopped() async throws {
        let store = try Store.inMemory()
        try store.emergencyStop(note: nil, by: "cli", now: Date())
        let idle = RecordingGates()
        await #expect(throws: WorkError.forbidden(ProbeGates.stoppedRefusal)) {
            _ = try await ProbeGates.runMissing(runner: idle, store: store, fingerprint: "fp")
        }
        #expect(idle.asked.isEmpty, "a gate ran while stopped")
        #expect(try store.probeGateRows(fingerprint: "fp").isEmpty)

        try store.resumeAfterStop(now: Date())
        let stopping = StoppingGates(store: store)
        await #expect(throws: WorkError.forbidden(ProbeGates.stoppedRefusal)) {
            _ = try await ProbeGates.runMissing(runner: stopping, store: store, fingerprint: "fp")
        }
        #expect(stopping.asked.count == 1, "gates kept running after the stop: \(stopping.asked)")
    }

    @Test func observersCalledOncePerStop() async throws {
        let observer = CountingObserver()
        let w = try World(stopObservers: [observer])
        _ = try w.company("Acme")
        try w.store.emergencyStop(note: "deploy looks wrong", by: "app", now: w.clock.now)
        for _ in 0..<3 { try await w.cycle() }
        #expect(await observer.reasons == ["stopped by the owner: deploy looks wrong"])
        // Pressing it again while stopped is the same stop.
        try w.store.emergencyStop(note: "again", by: "app", now: w.clock.now)
        try await w.cycle()
        #expect(await observer.reasons.count == 1)
        // A new stop after a resume runs them again.
        try w.store.resumeAfterStop(now: w.clock.now)
        try await w.cycle()
        w.clock.advance(5)
        try w.store.emergencyStop(note: nil, by: "app", now: w.clock.now)
        try await w.cycle(); try await w.cycle()
        #expect(await observer.reasons == ["stopped by the owner: deploy looks wrong", "stopped by the owner"])
    }

    @Test func resumeRestoresScheduling() async throws {
        let w = try World(); let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        try w.store.emergencyStop(note: nil, by: "owner", now: w.clock.now)
        try w.dm(c, ceo)
        try await w.cycle()
        #expect(w.fake.requests.isEmpty)
        #expect(try w.store.resumeAfterStop(now: w.clock.now))
        #expect(try w.store.resumeAfterStop(now: w.clock.now) == false, "idempotent")
        try await w.cycle()
        #expect(try w.turns(ceo).map(\.outcome) == [.succeeded])
    }

    @Test func activeClockFrozenWhileStopped() async throws {
        let w = try World(); let c = try w.company("Acme")
        try await w.cycle()
        w.clock.advance(30); try await w.cycle()
        let before = w.store.activeNow(companyId: c.id)
        #expect(before >= 30)
        try w.store.emergencyStop(note: nil, by: "owner", now: w.clock.now)
        #expect(w.store.isFrozen(companyId: c.id))
        w.clock.advance(30); try await w.cycle()
        w.clock.advance(30); try await w.cycle()
        #expect(w.store.activeNow(companyId: c.id) == before, "frozen, like a hold")
        try w.store.resumeAfterStop(now: w.clock.now)
        #expect(!w.store.isFrozen(companyId: c.id))
        try await w.cycle()
        w.clock.advance(30); try await w.cycle()
        #expect(w.store.activeNow(companyId: c.id) == before + 30, "the stopped time is never counted afterwards")
    }

    @Test func stallReasonFirst() async throws {
        let w = try World(); let c = try w.company("Acme"); _ = try w.hire(c, "ceo")
        try w.store.setHold(reason: .network, detail: "offline", now: w.clock.now)
        let row = try w.store.emergencyStop(note: nil, by: "owner", now: w.clock.now)
        let reasons = try w.store.stallReport(companyId: c.id, now: w.clock.now).reasons
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = w.store.ownerTimeZone(); f.dateFormat = "HH:mm"
        #expect(reasons.first == "stopped by the owner since \(f.string(from: row.since))")
        #expect(reasons.dropFirst().first?.hasPrefix("engine paused") == true)
        #expect(EmergencyStop.statusLine(row, timeZone: w.store.ownerTimeZone()) == "STOPPED by the owner since \(f.string(from: row.since))")
    }

    @Test func migrationSlotFollowsPushBeforeDigests() throws {
        let names = Migrations.migrator().migrations
        let i = try #require(names.firstIndex(of: "v5-stop"))
        #expect(names[i - 1] == "v5-push-2")
        #expect(names[i + 1] == "v5-digests")
        let store = try Store.inMemory()
        let row = try store.emergencyStop(note: "a\nb", by: "owner", now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(row.note == "a b", "flattened to one line")
        #expect(try store.engineStopped() == row)
        // The table holds one row at most.
        #expect(throws: (any Error).self) {
            try store.writer.write { db in try db.execute(sql: "INSERT INTO engineStop(id, since, \"by\") VALUES (2, ?, 'owner')", arguments: [Date()]) }
        }
    }

    // MARK: Owner only

    @Test func ownerOnly() throws {
        // Not a company tool: no tool of an agent's server can stop or resume, and the tools' code never calls either.
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let a = try store.hire(companyId: c.id, name: "ceo", role: "ceo", model: "sonnet")
        let names = CompanyTools(store: store, companyId: c.id, agentId: a.id).specs().map(\.name)
        #expect(!names.contains { $0.contains("stop") || $0.contains("resume") || $0.contains("emergency") }, "\(names)")
        let mcp = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/BrahmaCore/MCP")
        for case let file as URL in try #require(FileManager.default.enumerator(at: mcp, includingPropertiesForKeys: nil))
        where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("emergencyStop(") && !text.contains("resumeAfterStop("), "\(file.lastPathComponent)")
        }
        #expect(throws: EmergencyStopError.invalidActor("agent")) { try store.emergencyStop(note: nil, by: "agent", now: Date()) }

        // From an agent's shell the CLI refuses both.
        let owner = try OwnerTestHome()
        for args in [["stop"], ["resume"]] {
            let r = try cli(args, home: owner.url, extra: ["BRAHMA_AGENT_ID": a.id])
            #expect(r.status != 0, "\(args) ran from an agent's shell")
        }
        let db = try Store(path: ownerPaths(owner.url).database.path)
        #expect(try db.engineStopped() == nil)
    }

    // MARK: CLI without an engine

    @Test func cliStopKillsPidsWithoutEngine() throws {
        let owner = try OwnerTestHome()
        let paths = ownerPaths(owner.url)
        let store = try Store(path: paths.database.path)
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let a = try store.hire(companyId: c.id, name: "ceo", role: "ceo", model: "sonnet")
        try store.transition(agentId: a.id, to: .ready, now: Date()) { _ in true }
        let (_, turn) = try #require(try store.beginTurn(agentId: a.id, now: Date()))
        // A turn's process: the leader of its own group, recorded as the turn's pid and, as the runner does at spawn, under
        // `<runDir>/turns` with its exact start time (Task 9c fix round 2: the stop paths read only that record; the database
        // row carries no start time and is never a source). No engine runs.
        let child = try ProcessGroupChild.spawn(executable: "/bin/sleep", arguments: ["sleep", "300"], environment: [:],
                                                workingDirectory: try tempDir(), output: -1)
        defer { _ = child.signalGroup(SIGKILL); child.finish() }
        try store.setTurnPid(turnId: turn.id, pid: child.pid)
        let turns = paths.runDir.appending(path: "turns", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: turns, withIntermediateDirectories: true)
        let start = try #require(ProcessTable.entry(child.pid)?.start)
        try TurnRecords.add(TurnRecord(leader: child.pid, leaderStart: start, since: start, machMarker: nil), agentId: a.id, in: turns)

        let stop = try cli(["stop", "--note", "test stop"], home: owner.url)
        #expect(stop.status == 0, "\(stop.stderr)")
        #expect(stop.stdout.hasPrefix("STOPPED by the owner since "), "\(stop.stdout)")
        // The CLI waited until the group was gone (or killed it): the leader has exited, unreaped (a zombie of this test).
        #expect(child.hasExited(), "the turn's group survived brahma stop")
        #expect(ProcessGroupChild.exitCode(child.finish()) == 128 + SIGTERM)
        #expect(try store.engineStopped()?.by == "cli")
        #expect(try store.engineStopped()?.note == "test stop")

        // Idempotent; status says so first; resume ends it.
        let again = try cli(["stop"], home: owner.url)
        #expect(again.status == 0, "\(again.stderr)")
        let status = try cli(["status"], home: owner.url)
        #expect(status.stdout.hasPrefix("STOPPED by the owner since "), "\(status.stdout)")
        let resume = try cli(["resume"], home: owner.url)
        #expect(resume.status == 0, "\(resume.stderr)")
        #expect(try store.engineStopped() == nil)
        let after = try cli(["status"], home: owner.url)
        #expect(!after.stdout.contains("STOPPED"))
    }

    /// `brahma stop` with no engine signals the check and merge groups the engine recorded (S15), not only turns.
    @Test func cliStopKillsRecordedCheckAndMergeGroups() throws {
        let owner = try OwnerTestHome()
        let paths = ownerPaths(owner.url)
        _ = try Store(path: paths.database.path)
        let dir = ChildGroups.directory(runDir: paths.runDir)
        var children: [ProcessGroupChild] = []
        defer { for c in children { _ = c.signalGroup(SIGKILL); c.finish() } }
        for kind in ["check", "merge"] {
            let child = try ProcessGroupChild.spawn(executable: "/bin/sleep", arguments: ["sleep", "300"], environment: [:],
                                                    workingDirectory: try tempDir(), output: -1)
            children.append(child)
            #expect(ChildGroups(dir: dir, kind: kind).record(child.pid) != nil)
        }
        let stop = try cli(["stop"], home: owner.url)
        #expect(stop.status == 0, "\(stop.stderr)")
        for child in children {
            #expect(child.hasExited(), "a recorded group survived brahma stop")
            #expect(ProcessGroupChild.exitCode(child.finish()) == 128 + SIGTERM)
        }
        #expect(ChildGroups.liveLeaders(in: dir).isEmpty)
        ChildGroups.removeStale(in: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".group") }.isEmpty)
    }

    // MARK: Stop notice (M1 ruling)

    @Test func stopNoticeIsPushedOncePerStop() async throws {
        let store = try Store.inMemory()
        _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        try store.setPush(provider: .ntfy, topic: "long-random-topic-9f3a")
        let channel = FakePushChannel()
        let d = PushDispatcher(store: store, vault: MemoryVault(), channel: channel, awake: { 1_000_000 })
        let row = try store.emergencyStop(note: "secret note", by: "owner", now: Date(timeIntervalSince1970: 1_800_000_000))
        await d.tick(now: Date(), onlyStopNotice: true)
        await d.tick(now: Date(), onlyStopNotice: true)
        let sent = channel.sent
        #expect(sent.count == 1, "once per stop")
        #expect(sent.first?.body == PushDispatcher.stopNoticeBody(row, timeZone: store.ownerTimeZone()))
        #expect(sent.first?.body.contains("secret note") == false, "the owner's note never leaves")
        #expect(sent.first?.priority == .urgent)
        // A new stop after a resume is a new notice.
        try store.resumeAfterStop(now: Date())
        try store.emergencyStop(note: nil, by: "cli", now: Date(timeIntervalSince1970: 1_800_000_600))
        await d.tick(now: Date(), onlyStopNotice: true)
        #expect(channel.sent.count == 2)
    }

    // MARK: Helpers

    private func runsOf(_ w: World, _ item: WorkItem) throws -> [VerificationRun] {
        try w.store.writer.read { try VerificationRun.filter(Column("itemId") == item.id).order(Column.rowID).fetchAll($0) }
    }

    /// An item submitted for review by `eng` (its check queued).
    private func submittedItem(_ w: World, _ c: Company, _ eng: Agent) throws -> WorkItem {
        let item = try w.store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Do it", checkSpec: CheckSpec(command: "true", paths: ["src/p1"]), status: .ready), now: w.clock.now)
        let tools = CompanyTools(store: w.store, companyId: c.id, agentId: eng.id)
        _ = try tools.call(name: "claim_lease", arguments: ["key": .string(item.key)])
        let wt = GitWorkspace(root: URL(fileURLWithPath: c.workspacePath, isDirectory: true)).worktreePath(key: item.key)
        let file = wt.appending(path: "src/work.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "work".write(to: file, atomically: true, encoding: .utf8)
        _ = try tools.call(name: "submit_for_review", arguments: ["key": .string(item.key), "summary": .string("did it")])
        return item
    }

    private func cli(_ args: [String], home: URL, extra: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = brahmaExecutableURL()
        p.arguments = args
        p.environment = cliEnvironment(home: home).merging(extra) { _, new in new }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

/// A live-gate stand-in whose first gate is when the owner presses stop.
private final class StoppingGates: ProbeGateRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _asked: [String] = []
    let store: Store
    init(store: Store) { self.store = store }
    var asked: [String] { lock.withLock { _asked } }
    func run(gate: String, shape: ProbeShape) async -> GateResult {
        lock.withLock { _asked.append("\(shape.rawValue)/\(gate)") }
        try? store.emergencyStop(note: nil, by: "owner", now: Date())
        return GateResult(gate: gate, shape: shape, passed: false, detail: "fake")
    }
}

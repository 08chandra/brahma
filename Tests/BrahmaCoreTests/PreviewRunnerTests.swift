import Testing
import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore
@testable import BrahmaSafety

/// The engine's preview runner: fresh exports of `main`, restarts on merges (debounced), on changes and on the owner's flag,
/// the crash loop, memory pressure, pauses, failure notices, the safety cap and shutdown. A file-backed store (so exports go
/// under its data home), a real git workspace, FakeSandbox (real processes in their own groups) and fake probes.
@Suite(.scratch) struct PreviewRunnerTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func set(_ v: Bool) { lock.withLock { value = v } }
        var get: Bool { lock.withLock { value } }
    }

    struct Fx {
        let w: World
        let company: Company
        let devops: Agent
        let f: GitFixture
        let sandbox: FakeSandbox
        /// The Full-mode runner (PR-5): only a Full company's previews may reach it.
        let unsandboxed: FakeSandbox
        let http: FakeHTTPProbe
        let listen: FakeListenProbe
        let deps: PreviewDependencies
        let memory = Flag()
        let runner: PreviewRunner

        /// The fakes answer at once, so the ready budget is only a hang bound: nothing here races the clock (X1).
        static let fast = PreviewTimeouts(ready: .seconds(600), poll: .milliseconds(50))

        init(build: String? = nil, run: String = "sleep 300", http: FakeHTTPProbe = FakeHTTPProbe([FakeHTTPProbe.ok()]),
             profile: PermissionProfile = .workspace, config: SchedulerConfig = World.config()) throws {
            let root = try tempDir()
            let data = root.appending(path: "data", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let store = try Store(path: data.appending(path: "brahma.sqlite").path)
            sandbox = FakeSandbox()
            unsandboxed = FakeSandbox()
            self.http = http
            listen = FakeListenProbe()
            deps = PreviewDependencies.fake(sandbox: sandbox, http: http, listen: listen, unsandboxed: unsandboxed)
            w = try World(store: store, config: config, previewDeps: deps)
            company = try w.company("Acme", profile: profile)
            devops = try w.hire(company, "devops")
            f = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            let (memory, paths) = (self.memory, w.paths)
            runner = PreviewRunner(store: store, paths: paths, deps: deps,
                                   sandboxLayout: { SandboxLayout(paths: paths, company: $0, agentHandle: "preview") },
                                   timeouts: Self.fast, memory: { memory.get }, clock: w.clock.function)
            try merge(["index.html": "one"])
            try set("web", build: build, run: run)
        }

        var store: Store { w.store }
        var now: Date { w.clock.now }

        /// Lands `files` on main the engine's way: committed, then accepted by the owner (`acceptMainCommit` records
        /// `mainCommit`). Returns the new main.
        @discardableResult
        func merge(_ files: [String: String]) throws -> String {
            for (path, text) in files { try f.write(path, text) }
            try f.git(["add", "-A"])
            try f.git(["commit", "-q", "-m", "change"])
            return try store.acceptMainCommit(companyId: company.id).head
        }

        @discardableResult
        func set(_ name: String, build: String? = nil, run: String = "sleep 300", url: String = "http://127.0.0.1:{port}/") throws -> PreviewSurface {
            try store.upsertPreviewSurface(companyId: company.id, by: .agent(devops.id),
                                           PreviewDraft(name: name, run: run, url: url, build: build), now: now)
        }

        func surface(_ name: String) throws -> PreviewSurface {
            try #require(try store.previewSurfaces(companyId: company.id).first { $0.name == name })
        }

        func state(_ name: String = "web") throws -> PreviewState {
            let s = try surface(name)
            return try #require(try store.previewStates(companyId: company.id)[s.id])
        }

        var main: String { get throws { try #require(try store.company(id: company.id)?.mainCommit) } }

        /// One pass at the test clock's now, then every start it began has ended.
        func pass() async {
            await runner.reconcile(now: now)
            await runner.waitForStarts()
        }

        var spawns: [FakeSandbox.Call] { sandbox.calls.filter { $0.kind == .spawn } }

        func activity() throws -> [String] {
            try store.writer.read { db in
                try String.fetchAll(db, sql: "SELECT text FROM activityEvent WHERE companyId = ? ORDER BY id", arguments: [company.id])
            }
        }

        func messages() throws -> [Message] {
            try store.writer.read { db in try Message.filter(Column("companyId") == company.id).fetchAll(db) }
        }

        func stop() async { await runner.stopAll() }

        /// Another runner on the same store, as a new engine would have: its own process table and fake sandbox.
        func freshRunner(sandbox: FakeSandbox = FakeSandbox(), memory: @escaping @Sendable () -> Bool = { false }) -> (PreviewRunner, FakeSandbox) {
            let paths = w.paths
            let runner = PreviewRunner(store: store, paths: paths, deps: .fake(sandbox: sandbox, http: http, listen: listen),
                                       sandboxLayout: { SandboxLayout(paths: paths, company: $0, agentHandle: "preview") },
                                       timeouts: Fx.fast, memory: memory, clock: w.clock.function)
            return (runner, sandbox)
        }
    }

    static func alive(_ pid: Int32?) -> Bool { pid.map { kill(-$0, 0) == 0 } ?? false }

    static func waitUntil(_ timeout: Duration = .seconds(60), _ condition: () throws -> Bool) async rethrows -> Bool {
        let deadline = AwakeTime.deadline(after: timeout)
        while AwakeTime.now < deadline {
            if try condition() { return true }
            try? await AwakeTime.sleep(for: .milliseconds(50))
        }
        return try condition()
    }

    static func exists(_ url: URL) -> Bool { var st = stat(); return lstat(url.path, &st) == 0 }

    @Test func startsFromMainInFreshExport() async throws {
        let x = try Fx()
        await x.pass()
        let state = try x.state()
        #expect(state.status == .running, "\(state)")
        #expect(state.commit == (try x.main))
        let port = try #require(state.port)
        #expect(PortAllocator.range.contains(port))
        #expect(state.resolvedURL == "http://127.0.0.1:\(port)/")
        #expect(state.logPath == EngineLayout(workspace: URL(fileURLWithPath: x.company.workspacePath)).previewLog(name: "web").path)
        let spawn = try #require(x.spawns.first)
        let runId = try EngineLayout.previewRunId(surfaceId: try x.surface("web").id, commit: try x.main, start: 1)
        #expect(spawn.cwd.path == EngineExport.directory(store: x.store, company: x.company, runId: runId).path)
        #expect(!spawn.cwd.path.hasPrefix(x.company.workspacePath), "under the data home, never the workspace")
        #expect(!Self.exists(spawn.cwd.appending(path: ".git")))
        #expect(try String(contentsOf: spawn.cwd.appending(path: "index.html"), encoding: .utf8) == "one")
        #expect(spawn.environment["PORT"] == String(port) && spawn.environment["HOST"] == "127.0.0.1")
        #expect(spawn.policy.writable == [spawn.cwd.resolvedForSandbox] && spawn.policy.network == .loopbackListen(allow: spawn.policy.allowedDomains ?? [], ports: [UInt16(port)]))
        #expect(try x.activity().contains("Preview web running at http://127.0.0.1:\(port)/"))
        #expect(x.unsandboxed.calls.isEmpty, "a Workspace company's preview is sandboxed")
        await x.stop()
    }

    @Test func restartsAfterMergeWithDebounce() async throws {
        let x = try Fx()
        await x.pass()
        let first = try x.state()
        let next = try x.merge(["index.html": "two"])
        await x.pass()                               // main moved: seen now
        x.w.clock.advance(1)
        await x.pass()
        #expect(x.spawns.count == 1, "no restart within the debounce")
        #expect(Self.alive(first.pid))
        x.w.clock.advance(5)
        await x.pass()
        #expect(x.spawns.count == 2)
        #expect(await Self.waitUntil { !Self.alive(first.pid) }, "the old group is stopped")
        let state = try x.state()
        #expect(state.status == .running && state.commit == next)
        let cwd = try #require(x.spawns.last?.cwd)
        #expect(try String(contentsOf: cwd.appending(path: "index.html"), encoding: .utf8) == "two")
        #expect(!Self.exists(try #require(x.spawns.first?.cwd)), "the older run dir is deleted")
        await x.stop()
    }

    @Test func previewBuildRewritingGitIgnored() async throws {
        let marker = try tempDir().appending(path: "marker")
        let build = "mkdir -p .git/hooks && echo 'ref: refs/heads/evil' > .git/HEAD && "
            + "printf '[core]\\n\\tfsmonitor = touch \(marker.path)\\n\\thooksPath = .git/hooks\\n' > .git/config && "
            + "printf '#!/bin/sh\\ntouch \(marker.path)\\n' > .git/hooks/post-checkout && chmod +x .git/hooks/post-checkout"
        let x = try Fx(build: build)
        await x.pass()
        #expect(try x.state().status == .running)
        let crafted = try #require(x.spawns.first?.cwd)
        #expect(Self.exists(crafted.appending(path: ".git/HEAD")), "the build did write its .git")
        let next = try x.merge(["index.html": "two", "app.js": "x"])
        await x.pass()
        x.w.clock.advance(6)
        await x.pass()
        let cwd = try #require(x.spawns.last?.cwd)
        #expect(cwd != crafted)
        #expect(try x.state().commit == next)
        #expect(try String(contentsOf: cwd.appending(path: "index.html"), encoding: .utf8) == "two")
        #expect(try String(contentsOf: cwd.appending(path: "app.js"), encoding: .utf8) == "x")
        // The new run's own build wrote a .git again, but nothing crafted ran on the engine's side.
        #expect(!Self.exists(marker), "no crafted git config or hook ran")
        await x.stop()
    }

    @Test func configChangeRestartsThatSurface() async throws {
        let x = try Fx()
        try x.set("api")
        await x.pass()
        await x.pass()                                // one start at a time engine-wide (maxConcurrentBuilds)
        let web = try x.state("web"), api = try x.state("api")
        #expect(web.status == .running && api.status == .running)
        #expect(x.spawns.count == 2)
        x.w.clock.advance(1)
        try x.set("web", run: "sleep 301")
        await x.pass()
        #expect(x.spawns.count == 3 && x.spawns.last?.command == "sleep 301")
        #expect(await Self.waitUntil { !Self.alive(web.pid) })
        #expect(Self.alive(api.pid), "the other surface is untouched")
        #expect(try x.state("api").pid == api.pid)
        let now = try x.state("web")
        #expect(now.status == .running && now.restartRequestedAt == nil)
        await x.stop()
    }

    /// Each server runs until the test lets it exit (a `stop` file in its run dir), so no start races the clock (X1).
    @Test func crashLoopStops() async throws {
        let x = try Fx(run: "while [ ! -e stop ]; do sleep 0.05; done; exit 1")
        for round in 1...3 {
            await x.pass()
            #expect(x.spawns.count == round)
            #expect(try x.state().status == .running)
            let pid = try x.state().pid
            try "".write(to: try #require(x.spawns.last?.cwd).appending(path: "stop"), atomically: true, encoding: .utf8)
            #expect(await Self.waitUntil { !Self.alive(pid) })
            try? await AwakeTime.sleep(for: .milliseconds(100))
            await x.pass()                            // the exit is noticed
            if round < 3 {
                let s = try x.state()
                #expect(s.status == .stopped && s.exits.count == round, "\(s)")
                await x.pass()
                #expect(x.spawns.count == round, "not before the backoff")
                x.w.clock.advance(PreviewRunner.backoff[round - 1])
            }
        }
        let s = try x.state()
        #expect(s.status == .failed && s.message == "exited 3 times in 5 minutes; restart it or wait for the next merge", "\(s)")
        x.w.clock.advance(60)
        await x.pass()
        #expect(x.spawns.count == 3, "no 4th spawn")
        await x.stop()
    }

    @Test func waitsUnderMemoryPressure() async throws {
        let x = try Fx()
        x.memory.set(true)
        await x.pass()
        #expect(x.sandbox.calls.isEmpty)
        #expect(try x.state().message == "waiting: memory pressure")
        x.memory.set(false)
        await x.pass()
        #expect(try x.state().status == .running)
        await x.stop()
    }

    @Test func failureNotifiesSetterWithoutOutput() async throws {
        let x = try Fx(build: "echo SECRET-LOG; exit 3")
        await x.pass()
        let state = try x.state()
        #expect(state.status == .failed && state.message == "build failed (exit 3)")
        let sha7 = String(try x.main.prefix(7))
        let log = try #require(state.logPath)
        #expect(log.hasPrefix("/") && log.hasSuffix(".brahma/preview/logs/web.log"))
        #expect(try String(contentsOfFile: log, encoding: .utf8).contains("SECRET-LOG"), "the output is in the log")
        let dm = try x.messages().filter { $0.senderId == "system" }
        #expect(dm.map(\.text) == ["Preview web failed at \(sha7): build failed (exit 3). Log: \(log)."])
        #expect(try x.activity().contains("Preview web failed at \(sha7): build failed (exit 3)"))
        #expect(try !x.messages().contains { $0.text.contains("SECRET-LOG") })
        #expect(try !x.activity().contains { $0.contains("SECRET-LOG") })
        // A failed surface does not retry by itself.
        x.w.clock.advance(60)
        await x.pass()
        #expect(x.sandbox.calls.count == 1)
        await x.stop()
    }

    /// A start that fails before it builds (a literal port another preview holds) is recorded once: no retry and no second
    /// notice on later passes at the same main.
    @Test func earlyFailureIsNotRetriedEveryPass() async throws {
        let x = try Fx()
        await x.pass()
        let port = try #require(try x.state().port)
        try x.set("api", url: "http://127.0.0.1:\(port)/")
        await x.pass()
        let api = try x.state("api")
        #expect(api.status == .failed && api.message == "port \(port) is used by preview acme/web; use {port} in run and url", "\(api)")
        x.w.clock.advance(30)
        await x.pass()
        await x.pass()
        #expect(x.spawns.count == 1)
        #expect(try x.messages().filter { $0.senderId == "system" }.count == 1)
        await x.stop()
    }

    @Test func pausedCompanyStopsPreviews() async throws {
        let x = try Fx()
        await x.pass()
        let pid = try x.state().pid
        var c = try #require(try x.store.company(id: x.company.id))
        c.status = .paused
        try x.store.updateCompany(c)
        await x.pass()
        #expect(await Self.waitUntil { !Self.alive(pid) })
        #expect(try x.state().status == .stopped)
        await x.pass()
        #expect(x.spawns.count == 1, "nothing starts while paused")
        c.status = .running
        try x.store.updateCompany(c)
        await x.pass()
        #expect(try x.state().status == .running && x.spawns.count == 2)
        await x.stop()
    }

    @Test func ownerRestartFlag() async throws {
        let x = try Fx()
        await x.pass()
        let first = try x.state()
        try x.store.requestPreviewRestart(surfaceId: first.surfaceId, by: .owner, now: x.now)
        await x.pass()
        #expect(x.spawns.count == 2)
        #expect(await Self.waitUntil { !Self.alive(first.pid) })
        let s = try x.state()
        #expect(s.status == .running && s.restartRequestedAt == nil && s.pid != first.pid)
        await x.stop()
    }

    @Test func removedSurfaceIsStopped() async throws {
        let x = try Fx()
        await x.pass()
        let state = try x.state()
        try x.store.removePreviewSurface(companyId: x.company.id, name: "web", by: .agent(x.devops.id), now: x.now)
        await x.pass()
        #expect(await Self.waitUntil { !Self.alive(state.pid) })
        #expect(x.deps.processes.count == 0)
        await x.stop()
    }

    @Test func engineStartRestartsRecordedPreviews() async throws {
        let x = try Fx()
        await x.pass()
        let before = try x.state()
        // Another engine's record: its processes are gone with it (stopped here as a crashed engine's would be).
        await x.runner.stopAll()
        var record = try x.state()
        record.status = .running; record.pid = before.pid
        try x.store.savePreviewState(record)
        let fresh = PreviewRunner(store: x.store, paths: x.w.paths, deps: x.deps,
                                  sandboxLayout: { SandboxLayout(paths: x.w.paths, company: $0, agentHandle: "preview") },
                                  timeouts: Fx.fast, memory: { false }, clock: x.w.clock.function)
        await fresh.reconcile(now: x.now)
        await fresh.waitForStarts()
        let s = try x.state()
        #expect(s.status == .running && s.pid != before.pid && x.spawns.count == 2, "\(s)")
        await fresh.stopAll()
    }

    /// Fix I1 (controller ruling): previews count against the safety cap only, never the plan tier's hard cap, and a running
    /// server alone does not keep the Mac awake.
    @Test func previewsCountInSafetyCap() async throws {
        var cfg = World.config(hardCap: 1)
        cfg.safetyCap = 64
        let x = try Fx(config: cfg)
        let o = x.w.orchestrator
        #expect(await o.previewChildren == 0)
        try await x.w.cycle()
        await o.previewRunner.waitForStarts()
        #expect(try x.state().status == .running)
        #expect(await o.previewChildren == 1, "1 running preview is 1 non-claude child for the safety cap")
        #expect(await o.otherChildren == 0, "and none for the hard cap")
        #expect(await o.awakeWork == 0, "a running preview alone does not hold the sleep guard")
        // With the hard cap at 1 and the preview running, a turn still gets the slot.
        try x.w.dm(x.company, x.devops)
        try await x.w.cycle()
        #expect(try x.w.turns(x.devops).count == 1)
        await o.previewRunner.stopAll()
        #expect(await o.previewChildren == 0)
        // The safety cap still sees it: with a safety cap of 1, the running preview leaves no slot for a turn.
        #expect(Scheduler.freeSlots(config: cfg, running: 0, otherChildren: 0, safetyOnly: 1) == 1)
        var tight = cfg
        tight.safetyCap = 1
        #expect(Scheduler.freeSlots(config: tight, running: 0, otherChildren: 0, safetyOnly: 1) == 0)
        #expect(Scheduler.freeSlots(config: tight, running: 0, otherChildren: 0, safetyOnly: 0) == 1)
    }

    @Test func safetyCapPreviewBlocksTurns() async throws {
        var cfg = World.config(hardCap: 4)
        cfg.safetyCap = 1
        let x = try Fx(config: cfg)
        let o = x.w.orchestrator
        try await x.w.cycle()
        await o.previewRunner.waitForStarts()
        #expect(try x.state().status == .running)
        try x.w.dm(x.company, x.devops)
        try await x.w.cycle()
        #expect(try x.w.turns(x.devops).isEmpty, "the preview fills the safety cap of 1")
        await o.previewRunner.stopAll()
    }

    /// Fix I2: the Full-mode route mirrors the checks' (`Orchestrator.checkRoute`). S6 re-point: `PreviewRunner.unsandboxed`
    /// is gone (spec §7.3); the start resolves `.preview(surfaceId:)` and takes the shared Full route (`runsUnsandboxed`), so the
    /// company's profiles are recorded and the owner-set surface is a second surface the owner set.
    @Test func routingFollowsChecks() throws {
        let x = try Fx()
        let byAgent = try x.surface("web")
        let byOwner = try x.store.upsertPreviewSurface(companyId: x.company.id, by: .owner,
                                                       PreviewDraft(name: "site", run: "sleep 300", url: "http://127.0.0.1:{port}/"), now: x.now)
        #expect(byOwner.setById == "owner")
        func unsandboxed(_ surface: PreviewSurface) -> Bool {
            PrincipalResolver(store: x.store, ceiling: nil).resolve(.preview(surfaceId: surface.id)).runsUnsandboxed
        }
        func profile(_ p: PermissionProfile, roles: [String: PermissionProfile]? = nil) throws {
            try x.store.updateSandbox(companyId: x.company.id, SandboxPatch(profile: p, roleProfiles: roles), userHome: try tempDir())
        }
        try profile(.workspace)
        #expect(!unsandboxed(byAgent))
        #expect(!unsandboxed(byOwner))
        try profile(.sandboxed)
        #expect(!unsandboxed(byAgent))
        try profile(.full)
        #expect(unsandboxed(byAgent), "Full company, Full role")
        #expect(unsandboxed(byOwner), "an owner-set surface follows the company")
        try profile(.full, roles: [x.devops.role: .workspace])
        #expect(!unsandboxed(byAgent), "Full company, non-Full setter role")
        #expect(unsandboxed(byOwner))
    }

    @Test func fullCompanyPreviewRunsUnsandboxed() async throws {
        let x = try Fx(profile: .full)
        await x.pass()
        #expect(try x.state().status == .running)
        #expect(x.sandbox.calls.isEmpty)
        #expect(x.unsandboxed.calls.map(\.kind) == [.spawn])
        await x.stop()
    }

    /// Fix I3 (a): an earlier engine's live group (its runner gone without a stop) is killed by the next runner's first pass,
    /// and the surface restarts.
    @Test func engineStartKillsOrphanGroup() async throws {
        let x = try Fx()
        await x.pass()
        let record = try x.state()
        let orphan = try #require(record.pid)
        #expect(Self.alive(orphan))
        // The spawn recorded the leader's exact start (final review I2): that, not a time window, is what proves it ours.
        #expect(record.pidStart != nil && PreviewRunner.orphanGroup(pid: orphan, pidStart: record.pidStart))
        #expect(EmergencyStop.previewGroups(store: x.store) == [orphan])
        let (fresh, sandbox) = x.freshRunner()
        await fresh.reconcile(now: x.now)
        await fresh.waitForStarts()
        #expect(await Self.waitUntil { !Self.alive(orphan) }, "the orphan group is killed")
        let s = try x.state()
        #expect(s.status == .running && s.pid != orphan && sandbox.spawnedPids.count == 1, "\(s)")
        await fresh.stopAll()
        await x.stop()
    }

    /// Fix I3 (b), final review I2: a recorded pid that is not its group's leader, a reused pid (a live leader of ours whose
    /// start is not the one recorded at the spawn, even one well inside the old `startedAt…updatedAt` window), and a legacy
    /// record with no start are never signalled, by the engine-start recovery or by the stop set; the record still becomes
    /// `stopped`.
    @Test func engineStartSparesForeignProcesses() async throws {
        let x = try Fx(run: "sleep 300 & echo $! > child.pid; wait")
        await x.pass()
        let leader = try #require(try x.state().pid)
        let start = try #require(try x.state().pidStart)
        let cwd = try #require(x.spawns.last?.cwd)
        #expect(await Self.waitUntil { ((try? String(contentsOf: cwd.appending(path: "child.pid"), encoding: .utf8)) ?? "").hasSuffix("\n") })
        let child = try #require(Int32(try String(contentsOf: cwd.appending(path: "child.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let wide = (Date().addingTimeInterval(-3600), Date().addingTimeInterval(3600))
        let cases: [(String, Int32, Double?)] = [
            ("not its group's leader", child, start),
            ("a reused pid: another start inside the old window", leader, start - 0.5),
            ("a reused pid: a later start", leader, start + 1),
            ("a legacy record without a start", leader, nil),
        ]
        for (what, pid, pidStart) in cases {
            var record = try x.state()
            record.status = .running; record.pid = pid; record.pidStart = pidStart; record.startedAt = wide.0; record.updatedAt = wide.1
            try x.store.savePreviewState(record)
            #expect(!PreviewRunner.orphanGroup(pid: pid, pidStart: pidStart), "\(what)")
            #expect(EmergencyStop.previewGroups(store: x.store).isEmpty, "\(what): not in the stop set")
            let (fresh, sandbox) = x.freshRunner(memory: { true })   // under pressure: recovered, not restarted
            await fresh.reconcile(now: x.now)
            await fresh.waitForStarts()
            try? await AwakeTime.sleep(for: .milliseconds(300))
            #expect(kill(child, 0) == 0 && Self.alive(leader), "\(what): pid \(pid) was not signalled")
            let s = try x.state()
            #expect(s.status == .stopped && s.pid == nil && s.pidStart == nil, "\(what): \(s)")
            #expect(sandbox.calls.isEmpty)
        }
        await x.stop()
        #expect(await Self.waitUntil { !Self.alive(leader) })
    }

    /// Final review I2: the record's start follows its pid. A different pid drops it (no start is ever paired with a process it
    /// was not read from); the same pid keeps it. (The database round trip is exact: `engineStartKillsOrphanGroup`.)
    @Test func pidStartFollowsItsPid() throws {
        var state = PreviewState(surfaceId: "s", companyId: "c", pid: 4242, updatedAt: Date(), pidStart: 1_800_000_000.123456)
        state.pid = 4242
        #expect(state.pidStart == 1_800_000_000.123456)
        state.pid = 4243
        #expect(state.pidStart == nil)
        state.pidStart = 5
        state.pid = nil
        #expect(state.pidStart == nil)
    }

    @Test func stopAllOnShutdown() async throws {
        let x = try Fx()
        try x.set("api")
        await x.pass()
        await x.pass()
        let pids = [try x.state("web").pid, try x.state("api").pid]
        #expect(pids.allSatisfy { Self.alive($0) })
        await x.runner.stopAll()
        #expect(await Self.waitUntil(.seconds(600)) { pids.allSatisfy { !Self.alive($0) } }, "no pids alive")
        for name in ["web", "api"] {
            let s = try x.state(name)
            #expect(s.status == .stopped && s.message == "engine stopped" && s.pid == nil)
        }
        #expect(x.deps.processes.count == 0)
    }

    /// L-5lite-A (PR-35 3s): the owner's stop reaches every preview (the observer's `stopAll(reason:)`, whatever note the
    /// owner gave), nothing starts or restarts while it holds, and the pass after the resume starts them as on engine start.
    @Test func emergencyStopStopsPreviews() async throws {
        let x = try Fx()
        try x.set("api")
        await x.pass()
        await x.pass()
        let pids = [try x.state("web").pid, try x.state("api").pid]
        #expect(pids.allSatisfy { Self.alive($0) })
        let spawned = x.spawns.count
        #expect(spawned == 2)
        try x.store.emergencyStop(note: "test", by: "owner", now: x.now)
        await x.runner.stopAll(reason: "stopped by the owner: test")
        // Hang bound only: stopAll returns once every group is reaped.
        #expect(await Self.waitUntil(.seconds(600)) { pids.allSatisfy { !Self.alive($0) } }, "no pids alive")
        for name in ["web", "api"] {
            let s = try x.state(name)
            #expect(s.status == .stopped && s.message == "stopped by the owner" && s.pid == nil, "\(s)")
        }
        #expect(x.deps.processes.count == 0)
        // While stopped: nothing starts, not the stopped surfaces, not after a merge past the debounce, not a flagged one.
        await x.pass()
        let moved = try x.merge(["index.html": "two"])
        await x.pass()
        x.w.clock.advance(PreviewRunner.debounce + 1)
        try x.store.requestPreviewRestart(surfaceId: try x.surface("web").id, by: .owner, now: x.now)
        await x.pass()
        #expect(x.spawns.count == spawned, "nothing spawned while stopped")
        for name in ["web", "api"] { #expect(try x.state(name).message == "stopped by the owner") }
        // Resumed: the next passes start them again (one start at a time), after the debounce for the moved main, as an
        // engine start would.
        try x.store.resumeAfterStop(now: x.now)
        await x.pass()
        x.w.clock.advance(PreviewRunner.debounce + 1)
        await x.pass()
        await x.pass()
        for name in ["web", "api"] {
            let s = try x.state(name)
            #expect(s.status == .running && s.commit == moved && Self.alive(s.pid), "\(s)")
        }
        #expect(x.spawns.count == spawned + 2)
        await x.stop()
    }

    /// L-5lite-A: `brahma stop` (and the app's STOP EVERYTHING) signal the recorded groups themselves, so a wedged engine
    /// cannot keep a preview up: a running preview's group is among them, a record whose start is not exactly its process's
    /// (final review I2: a recycled pid), or that has none, is not.
    @Test func recordedGroupsIncludePreviews() async throws {
        let x = try Fx()
        await x.pass()
        let state = try x.state()
        let pid = try #require(state.pid)
        let start = try #require(state.pidStart)
        #expect(state.status == .running && Self.alive(pid))
        #if canImport(Darwin)
        #expect(EmergencyStop.recordedGroups(store: x.store).contains(pid))
        var record = state
        record.pidStart = start + 0.25
        try x.store.savePreviewState(record)
        #expect(!EmergencyStop.recordedGroups(store: x.store).contains(pid), "a recycled pid is never signalled")
        record.pidStart = nil
        try x.store.savePreviewState(record)
        #expect(!EmergencyStop.recordedGroups(store: x.store).contains(pid), "a record without a start is never signalled")
        record.pidStart = start
        try x.store.savePreviewState(record)
        #expect(EmergencyStop.recordedGroups(store: x.store).contains(pid))
        #endif
        await x.stop()
    }

    /// L-5lite-A: the preview runner is one of the engine's stop observers, and the engine's own stop path reaches it.
    @Test func emergencyStopReachesPreviewsThroughTheEngine() async throws {
        let x = try Fx()
        let o = x.w.orchestrator
        let runner = await o.previewRunner
        #expect(o.stopObservers.contains { ($0 as? PreviewRunner) === runner })
        try await x.w.cycle()
        await o.previewRunner.waitForStarts()
        let pid = try x.state().pid
        #expect(try x.state().status == .running && Self.alive(pid))
        try x.store.emergencyStop(note: nil, by: "owner", now: x.now)
        try await x.w.cycle()
        #expect(await Self.waitUntil(.seconds(600)) { !Self.alive(pid) })
        let s = try x.state()
        #expect(s.status == .stopped && s.message == "stopped by the owner" && s.pid == nil, "\(s)")
        try await x.w.cycle()
        await o.previewRunner.waitForStarts()
        #expect(x.spawns.count == 1, "nothing restarted while stopped")
        try x.store.resumeAfterStop(now: x.now)
        try await x.w.cycle()
        await o.previewRunner.waitForStarts()
        #expect(try x.state().status == .running)
        #expect(x.spawns.count == 2)
        await o.previewRunner.stopAll()
    }

    /// Task 3 M1 (L-5lite-A): a pass in flight when `stopAll` runs brings nothing up after it returns. The pass is held
    /// inside its exit notice for a server that looks dead (an event, `ExitGate`), `stopAll` runs and returns, then the pass
    /// goes on: the flagged surface after it is not started, and the late exit notice writes nothing over the stop.
    @Test func stopAllFencesAPassInFlight() async throws {
        let x = try Fx(run: "sleep 301")
        try x.set("api")
        let gated = GatedSandbox(marker: "sleep 301")
        let deps = PreviewDependencies(sandbox: gated, http: x.http, listen: x.listen, processes: SpawnedProcesses(),
                                       unsandboxed: FakeSandbox())
        let paths = x.w.paths
        let runner = PreviewRunner(store: x.store, paths: paths, deps: deps,
                                   sandboxLayout: { SandboxLayout(paths: paths, company: $0, agentHandle: "preview") },
                                   timeouts: Fx.fast, memory: { false }, clock: x.w.clock.function)
        for _ in 0..<2 {
            await runner.reconcile(now: x.now)
            await runner.waitForStarts()
        }
        let pids = [try x.state("web").pid, try x.state("api").pid]
        #expect(pids.allSatisfy { Self.alive($0) })
        let spawned = gated.inner.calls.filter { $0.kind == .spawn }.count
        try x.store.requestPreviewRestart(surfaceId: try x.surface("api").id, by: .owner, now: x.now)
        gated.gate.playDead()
        let pass = Task { await runner.reconcile(now: x.now) }
        await gated.gate.waitUntilHeld()
        await runner.stopAll()
        gated.gate.release()
        await pass.value
        await runner.waitForStarts()
        #expect(gated.inner.calls.filter { $0.kind == .spawn }.count == spawned, "nothing came up after stopAll returned")
        #expect(await Self.waitUntil(.seconds(600)) { pids.allSatisfy { !Self.alive($0) } }, "no pids alive")
        for name in ["web", "api"] {
            let s = try x.state(name)
            #expect(s.status == .stopped && s.message == "engine stopped" && s.pid == nil, "\(s)")
        }
        #expect(deps.processes.count == 0)
    }

    @Test func digestPreviewLine() {
        let now = Date()
        let surface = PreviewSurface(id: "s1", companyId: "c1", name: "web", position: 0, build: nil, run: "x", url: "http://127.0.0.1:{port}/",
                                     setById: "owner", createdAt: now, updatedAt: now)
        let state = PreviewState(surfaceId: "s1", companyId: "c1", status: .running, commit: "abc1234def5678", port: 47100,
                                 resolvedURL: "http://127.0.0.1:47100/", updatedAt: now)
        #expect(TurnDigest.previewLine([(surface, state)]) == "Previews: web Running http://127.0.0.1:47100/ @abc1234")
        var api = surface; api.id = "s2"; api.name = "api"
        #expect(TurnDigest.previewLine([(surface, state), (api, nil)]) == "Previews: web Running http://127.0.0.1:47100/ @abc1234 · api Idle")
        #expect(TurnDigest.previewLine([]) == nil)
        let many = Array(repeating: (surface, Optional(state)), count: 20)
        #expect((TurnDigest.previewLine(many)?.count ?? 0) <= 400)
    }
}

/// Holds a reconcile pass inside its exit notice (Task 3 M1 test): once `playDead`, the gated servers look dead with exit 0,
/// and the first `terminate` of one (the notice's own stop) waits for `release`, after telling `waitUntilHeld`. Every other
/// `terminate` (the runner's `stopAll`) goes straight to the real process. Events only, no timers.
final class ExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var dead = false, released = false, held = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func playDead() { lock.withLock { dead = true } }
    var looksDead: Bool { lock.withLock { dead && !released } }

    func release() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            released = true
            defer { releaseWaiters = [] }
            return releaseWaiters
        }
        for c in waiters { c.resume() }
    }

    func waitUntilHeld() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if held { return true }
                heldWaiters.append(c)
                return false
            }
            if now { c.resume() }
        }
    }

    /// The first terminate while dead waits for `release`; returns once it may go on.
    func holdFirstTerminate() async {
        let first = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            guard dead, !released, !held else { return (false, []) }
            held = true
            defer { heldWaiters = [] }
            return (true, heldWaiters)
        }
        guard first.0 else { return }
        for c in first.1 { c.resume() }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                if released { return true }
                releaseWaiters.append(c)
                return false
            }
            if go { c.resume() }
        }
    }
}

/// A FakeSandbox whose servers with `marker` in their command go through `ExitGate`.
final class GatedSandbox: SandboxedRunner, @unchecked Sendable {
    let inner = FakeSandbox()
    let gate = ExitGate()
    let marker: String
    init(marker: String) { self.marker = marker }

    func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
             policy: SandboxPolicy) async -> CheckOutcome {
        await inner.run(command: command, cwd: cwd, environment: environment, timeout: timeout, outputURL: outputURL, policy: policy)
    }

    func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        let process = try inner.spawn(command: command, cwd: cwd, environment: environment, logURL: logURL, policy: policy)
        return command.contains(marker) ? GatedProcess(inner: process, gate: gate) : process
    }
}

struct GatedProcess: SandboxedProcess {
    let inner: any SandboxedProcess
    let gate: ExitGate
    var pid: Int32 { inner.pid }
    var leaderStart: Double? { inner.leaderStart }
    func isAlive() -> Bool { gate.looksDead ? false : inner.isAlive() }
    func exitStatus() -> Int32? { gate.looksDead ? 0 : inner.exitStatus() }
    func terminate(grace: Duration) async {
        await gate.holdFirstTerminate()
        await inner.terminate(grace: grace)
    }
}

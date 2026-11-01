import Testing
import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

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
        let http: FakeHTTPProbe
        let listen: FakeListenProbe
        let deps: PreviewDependencies
        let memory = Flag()
        let runner: PreviewRunner

        static let fast = PreviewTimeouts(ready: .seconds(20), poll: .milliseconds(50))

        init(build: String? = nil, run: String = "sleep 300", http: FakeHTTPProbe = FakeHTTPProbe([FakeHTTPProbe.ok()])) throws {
            let root = try tempDir()
            let data = root.appending(path: "data", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let store = try Store(path: data.appending(path: "brahma.sqlite").path)
            sandbox = FakeSandbox()
            self.http = http
            listen = FakeListenProbe()
            deps = PreviewDependencies.fake(sandbox: sandbox, http: http, listen: listen)
            w = try World(store: store, previewDeps: deps)
            company = try w.company("Acme")
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
    }

    static func alive(_ pid: Int32?) -> Bool { pid.map { kill(-$0, 0) == 0 } ?? false }

    static func waitUntil(_ timeout: Duration = .seconds(15), _ condition: () throws -> Bool) async rethrows -> Bool {
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

    @Test func crashLoopStops() async throws {
        let x = try Fx(run: "sleep 1")
        for round in 1...3 {
            await x.pass()
            #expect(x.spawns.count == round)
            let pid = try x.state().pid
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

    @Test func previewsCountInSafetyCap() async throws {
        let x = try Fx()
        #expect(await x.w.orchestrator.otherChildren == 0)
        try await x.w.cycle()
        await x.w.orchestrator.previewRunner.waitForStarts()
        #expect(try x.state().status == .running)
        #expect(await x.w.orchestrator.otherChildren == 1, "1 running preview is 1 non-claude child")
        await x.w.orchestrator.previewRunner.stopAll()
        #expect(await x.w.orchestrator.otherChildren == 0)
    }

    @Test func stopAllOnShutdown() async throws {
        let x = try Fx()
        try x.set("api")
        await x.pass()
        await x.pass()
        let pids = [try x.state("web").pid, try x.state("api").pid]
        #expect(pids.allSatisfy { Self.alive($0) })
        await x.runner.stopAll(reason: "stopped by the owner")
        #expect(await Self.waitUntil { pids.allSatisfy { !Self.alive($0) } }, "no pids alive")
        for name in ["web", "api"] {
            let s = try x.state(name)
            #expect(s.status == .stopped && s.message == "stopped by the owner" && s.pid == nil)
        }
        #expect(x.deps.processes.count == 0)
    }

    // L-5lite: emergencyStopStopsPreviews (EmergencyStopObserver / Store.engineStopped are not built yet, PR-35 3s);
    // `stopAll(reason:)` is covered by stopAllOnShutdown.

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

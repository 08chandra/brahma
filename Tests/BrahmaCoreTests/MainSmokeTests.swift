import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The smoke check on main (Plan L Task 5): a run per new engine-accepted main, in a fresh `.git`-free export under the data
/// home, through the sandbox with a check-shaped policy; the red-main bug; superseding; `mainIsGreen`; who may set it and who
/// may ask for a run. A file-backed store (exports under its data home), a real git workspace and FakeSandbox (real
/// processes, recorded calls). Nothing here races the clock: every run is awaited through the engine's idle wait.
@Suite(.scratch) struct MainSmokeTests {
    struct Fx {
        let w: World
        let company: Company
        let devops: Agent
        let eng: Agent
        let f: GitFixture
        let sandbox: FakeSandbox
        let unsandboxed: FakeSandbox
        let data: URL
        let vault = MemoryVault()

        init(profile: PermissionProfile = .workspace, memory: StubMemory = StubMemory(), config: SchedulerConfig = World.config()) throws {
            let root = try tempDir()
            data = root.appending(path: "data", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let store = try Store(path: data.appending(path: "brahma.sqlite").path)
            sandbox = FakeSandbox()
            unsandboxed = FakeSandbox()
            w = try World(store: store, config: config, memory: memory, vault: vault, smokeSandbox: sandbox, smokeUnsandboxed: unsandboxed)
            company = try w.company("Acme", profile: profile)
            devops = try w.hire(company, "devops-1", role: "devops")
            eng = try w.hire(company, "eng-1", role: "engineer")
            f = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        }

        var store: Store { w.store }

        /// Lands `files` on main the engine's way (committed, then accepted: `mainCommit` records it). Returns the new main.
        @discardableResult
        func merge(_ files: [String: String]) throws -> String {
            for (path, text) in files { try f.write(path, text) }
            try f.git(["add", "-A"])
            try f.git(["commit", "-q", "-m", "change"])
            return try store.acceptMainCommit(companyId: company.id).head
        }

        func setSmoke(_ command: String) throws {
            try store.setSmokeCheck(companyId: company.id, by: devops.id, check: CheckSpec(command: command), now: w.clock.now)
        }

        func current() throws -> Company { try #require(try store.company(id: company.id)) }
        func runs() throws -> [MainSmokeRun] { try store.mainSmokeRuns(companyId: company.id) }
    }

    static func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    @Test func smokeQueuedWhenMainMoves() async throws {
        let fx = try Fx()
        try fx.setSmoke("test -f a.txt && test ! -e .git")
        let head = try fx.merge(["a.txt": "x"])
        try await fx.w.cycle()
        let runs = try fx.runs()
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.reason == .merge); #expect(run.commit == head); #expect(run.status == .passed, "\(run.outputTail ?? "")")
        #expect(run.exitCode == 0); #expect(run.startedAt != nil); #expect(run.finishedAt != nil)
        // Through the sandbox (the company is not Full), in a fresh export under the data home, deleted afterwards.
        #expect(fx.unsandboxed.calls.isEmpty)
        let call = try #require(fx.sandbox.calls.first)
        #expect(fx.sandbox.calls.count == 1); #expect(call.kind == .run)
        #expect(call.command == "test -f a.txt && test ! -e .git")
        #expect(call.cwd.lastPathComponent == run.runId)
        let exports = fx.data.appending(path: "run/exports").resolvingSymlinksInPath().path
        #expect(call.cwd.resolvingSymlinksInPath().path.hasPrefix(exports + "/"))
        #expect(!FileManager.default.fileExists(atPath: call.cwd.path))
        // The check-shaped policy: writes and reads only its export; the registries; the toolchain.
        let dir = URL(fileURLWithPath: SandboxPath.resolve(call.cwd.path), isDirectory: true)
        #expect(call.policy.writable == [dir]); #expect(call.policy.readable == [dir]); #expect(call.policy.toolchain)
        if case .outbound(let allow) = call.policy.network { #expect(allow.contains("registry.npmjs.org")) } else { Issue.record("network \(call.policy.network)") }
        #expect(call.environment["BRAHMA_AGENT_ID"] == fx.devops.id)
        #expect(call.environment["BRAHMA_DEV"] == nil)
        // Main is green; another tick at the same main runs nothing.
        #expect(try ReleasePolicy.mainIsGreen(store: fx.store, company: try fx.current(), at: head) == (true, nil))
        try await fx.w.cycle()
        #expect(try fx.runs().count == 1)
        // A release's own smoke (Task 7's path) is a new row keyed by its release, reused for that release only.
        let release = try await fx.w.orchestrator.runSmoke(companyId: fx.company.id, commit: head, reason: .release, releaseId: "rel-1")
        #expect(release.status == .passed); #expect(release.releaseId == "rel-1"); #expect(release.id != run.id)
        let again = try await fx.w.orchestrator.runSmoke(companyId: fx.company.id, commit: head, reason: .release, releaseId: "rel-1")
        #expect(again.id == release.id); #expect(fx.sandbox.calls.count == 2)
    }

    @Test func redMainFilesOneBugPerStreak() async throws {
        let fx = try Fx()
        try fx.setSmoke("test -f ok.txt")
        let red1 = try fx.merge(["a.txt": "x"])
        try await fx.w.cycle()
        var company = try fx.current()
        let bugId = try #require(company.redBugItemId)
        let bug = try #require(try fx.store.workItem(id: bugId))
        #expect(bug.type == WorkItemType("bug")); #expect(bug.priority == 1); #expect(bug.status == .ready)
        #expect(bug.title == "Main is red at \(red1.prefix(7)): smoke check failed")
        #expect(bug.description == "The engine's smoke check failed on main. Fix main; deploys are blocked until it passes.")
        #expect(bug.checkSpec == company.smokeCheck)
        #expect(try ReleasePolicy.mainIsGreen(store: fx.store, company: company, at: red1)
                == (false, "main is red: the smoke check failed at \(red1.prefix(7)) (exit 1)"))
        // A second red run comments on the same bug; no second bug.
        let red2 = try fx.merge(["b.txt": "y"])
        try await fx.w.cycle()
        company = try fx.current()
        #expect(company.redBugItemId == bugId)
        #expect(try fx.store.workItems(companyId: fx.company.id).filter { $0.title.hasPrefix("Main is red") }.count == 1)
        var texts = try fx.store.itemEvents(itemId: bugId).map(\.text)
        #expect(texts.contains { $0.contains("still red at \(red2.prefix(7))") })
        // Green: one comment, and the bug is no longer the open red bug.
        let green = try fx.merge(["ok.txt": "fixed"])
        try await fx.w.cycle()
        company = try fx.current()
        #expect(company.redBugItemId == nil)
        texts = try fx.store.itemEvents(itemId: bugId).map(\.text)
        #expect(texts.contains("main is green again at \(green.prefix(7))"))
        #expect(try fx.runs().map(\.status) == [.failed, .failed, .passed])
        #expect(try ReleasePolicy.mainIsGreen(store: fx.store, company: company, at: green) == (true, nil))
    }

    @Test func newerSmokeSupersedesQueued() async throws {
        let fx = try Fx()
        try fx.setSmoke("true")
        let head = try fx.merge(["a.txt": "x"])
        let queued = try #require(try fx.store.queueMergeSmokeIfNeeded(companyId: fx.company.id, now: fx.w.clock.now))
        #expect(try fx.store.queueMergeSmokeIfNeeded(companyId: fx.company.id, now: fx.w.clock.now) == nil)
        #expect(try ReleasePolicy.mainIsGreen(store: fx.store, company: try fx.current(), at: head)
                == (false, "the smoke check has not run on main \(head.prefix(7)) yet"))
        let manual = try fx.store.requestManualSmoke(companyId: fx.company.id, by: .owner, now: fx.w.clock.now)
        let old = try #require(try fx.store.mainSmokeRun(id: queued.id))
        #expect(old.status == .error); #expect(old.outputTail == "superseded")
        try await fx.w.cycle()
        let runs = try fx.runs()
        #expect(runs.count == 2)
        #expect(try fx.store.mainSmokeRun(id: manual.id)?.status == .passed)
        #expect(fx.sandbox.calls.count == 1)
        #expect(try fx.store.latestMainSmoke(companyId: fx.company.id)?.id == manual.id)
        // The superseded merge row still holds the commit's merge slot: the tick does not queue it again.
        try await fx.w.cycle()
        #expect(try fx.runs().count == 2)
    }

    @Test func noSmokeCheckIsNotGreen() throws {
        let fx = try Fx()
        let head = try fx.merge(["a.txt": "x"])
        #expect(try ReleasePolicy.mainIsGreen(store: fx.store, company: try fx.current(), at: head)
                == (false, "set_smoke_check first; deploys need a smoke check on main"))
        #expect(ReleasePolicy.validVersion("1.2.0-rc.1+b5")); #expect(!ReleasePolicy.validVersion(".1"))
        #expect(!ReleasePolicy.validVersion("")); #expect(!ReleasePolicy.validVersion(String(repeating: "1", count: 33)))
        #expect(ReleasePolicy.buildTimeout == .seconds(1800)); #expect(ReleasePolicy.stepTimeout == .seconds(900))
    }

    @Test func smokeCheckRoleRule() throws {
        let fx = try Fx()
        let tools = { (a: Agent) in CompanyTools(store: fx.store, companyId: a.companyId, agentId: a.id) }
        func call(_ a: Agent, _ args: [String: JSONValue]) -> String {
            do { return try tools(a).call(name: "set_smoke_check", arguments: args) } catch let e as ToolError { return e.message } catch { return "\(error)" }
        }
        #expect(Self.message { try fx.store.setSmokeCheck(companyId: fx.company.id, by: fx.eng.id, check: CheckSpec(command: "true")) }
                == "set_smoke_check is not available to your role")
        #expect(call(fx.eng, ["command": .string("true")]) == "set_smoke_check is not available to your role")
        #expect(try fx.current().smokeCheck == nil)
        #expect(call(fx.devops, ["command": .string("npm test"), "timeout_seconds": .number(120)])
                == "Smoke check set: npm test (timeout 120s). The engine runs it on every new main and before every deploy.")
        var company = try fx.current()
        #expect(company.smokeCheck == CheckSpec(command: "npm test", timeoutSeconds: 120)); #expect(company.smokeCheckSetById == fx.devops.id)
        let events = try fx.store.recentEvents(companyId: fx.company.id, limit: 5).map(\.text)
        #expect(events.contains("@devops-1 set the smoke check on main: npm test"))
        #expect(call(fx.devops, ["command": .string("x"), "timeout_seconds": .number(4000)]) == "the check timeout must be between 1 and 3600 seconds")
        #expect(call(fx.devops, ["command": .string("  ")]) == "argument command must not be empty")
        // updateCompany keeps it; another company's agent cannot set it.
        try fx.store.updateCompany(fx.company)
        #expect(try fx.current().smokeCheck?.command == "npm test")
        let other = try fx.store.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir())
        let theirs = try fx.store.hire(companyId: other.id, name: "devops-1", role: "devops", model: "m")
        #expect(Self.message { try fx.store.setSmokeCheck(companyId: fx.company.id, by: theirs.id, check: CheckSpec(command: "true")) }
                == "not in your company")
        #expect(call(fx.devops, ["clear": .bool(true)]) == "Smoke check cleared; deploys are blocked until one is set.")
        company = try fx.current()
        #expect(company.smokeCheck == nil); #expect(company.smokeCheckSetById == nil)
    }

    @Test func manualSmokeQueues() throws {
        let fx = try Fx()
        try fx.setSmoke("true")
        let head = try fx.merge(["a.txt": "x"])
        #expect(Self.message { try fx.store.requestManualSmoke(companyId: fx.company.id, by: .agent(fx.devops.id)) }
                == "only the owner can request a smoke run")
        #expect(Self.message { try fx.store.requestManualSmoke(companyId: fx.company.id, by: .system) }
                == "only the owner can request a smoke run")
        let one = try fx.store.requestManualSmoke(companyId: fx.company.id, by: .owner, now: fx.w.clock.now)
        #expect(one.reason == .manual); #expect(one.status == .queued); #expect(one.commit == head)
        // PR-12: every manual request is a new row (the older queued one is superseded).
        let two = try fx.store.requestManualSmoke(companyId: fx.company.id, by: .owner, now: fx.w.clock.now)
        #expect(two.id != one.id)
        #expect(try fx.store.mainSmokeRun(id: one.id)?.status == .error)
        #expect(try fx.store.nextQueuedSmoke(companyId: fx.company.id)?.id == two.id)
        // A run an earlier engine left running is no result at the next start: error, no red bug.
        try fx.store.writer.write { db in try db.execute(sql: "UPDATE mainSmokeRun SET status = 'running' WHERE id = ?", arguments: [two.id]) }
        _ = try fx.store.recoverSmokes(now: fx.w.clock.now)
        let interrupted = try #require(try fx.store.mainSmokeRun(id: two.id))
        #expect(interrupted.status == .error); #expect(interrupted.outputTail == "engine restarted")
        #expect(try fx.current().redBugItemId == nil)
    }

    // MARK: Fix round 1

    /// Polls (bounded; never a race on the result) until `body` holds.
    static func eventually(_ body: () throws -> Bool) async throws {
        for _ in 0..<6000 where try !body() { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func fullModeSmokesRunUnsandboxed() async throws {
        let fx = try Fx(profile: .full)
        try fx.setSmoke("test -f a.txt")
        let head = try fx.merge(["a.txt": "x"])
        try await fx.w.cycle()
        #expect(fx.sandbox.calls.isEmpty); #expect(fx.unsandboxed.calls.count == 1)
        #expect(try fx.runs().first?.status == .passed)
        #expect(try ReleasePolicy.mainIsGreen(store: fx.store, company: try fx.current(), at: head) == (true, nil))
    }

    @Test func smokesWaitForCapacity() async throws {
        let memory = StubMemory(.critical)
        let fx = try Fx(memory: memory)
        try fx.setSmoke("true")
        try fx.merge(["a.txt": "x"])
        try await fx.w.cycle()
        #expect(try fx.runs().map(\.status) == [.queued]); #expect(fx.sandbox.calls.isEmpty)
        memory.set(.normal)
        try await fx.w.cycle()
        #expect(try fx.runs().map(\.status) == [.passed])
        // No free slot (hard cap 0): queued, not started.
        let tight = try Fx(config: World.config(hardCap: 0))
        try tight.setSmoke("true")
        try tight.merge(["a.txt": "x"])
        try await tight.w.cycle()
        #expect(try tight.runs().map(\.status) == [.queued]); #expect(tight.sandbox.calls.isEmpty)
    }

    @Test func shutdownRequeuesMergeSmokeWithoutRedBug() async throws {
        let fx = try Fx()
        try fx.setSmoke("sleep 120")
        try fx.merge(["a.txt": "x"])
        let engine = fx.w.orchestrator
        let loop = Task { await engine.runForever(interval: .milliseconds(20)) }
        try await Self.eventually { !fx.sandbox.calls.isEmpty }
        let cwd = try #require(fx.sandbox.calls.first?.cwd)
        loop.cancel()
        await loop.value
        let run = try #require(try fx.runs().first)
        #expect(try fx.runs().count == 1)
        #expect(run.status == .queued); #expect(run.startedAt == nil)
        #expect(try fx.current().redBugItemId == nil)
        #expect(!FileManager.default.fileExists(atPath: cwd.path))
        // A run that is not a merge run at main is recorded "engine stopped" instead (no result, no red bug).
        let manual = try fx.store.requestManualSmoke(companyId: fx.company.id, by: .owner, now: fx.w.clock.now)
        let stopped = try fx.store.requeueOrError(manual, tail: "engine stopped", now: fx.w.clock.now)
        #expect(stopped.status == .error); #expect(stopped.outputTail == "engine stopped")
        #expect(try fx.current().redBugItemId == nil)
    }

    @Test func orchestratorStartRecoversRunningSmoke() async throws {
        let fx = try Fx()
        try fx.setSmoke("test -f a.txt")
        let head = try fx.merge(["a.txt": "x"])
        // A registered secret (MemoryVault) the stale log leaked: start-up loads the redactor, then scrubs the log.
        try fx.store.setSecret(companyId: fx.company.id, name: "API_TOKEN", value: "tok-0123456789", isTest: false, vault: fx.vault)
        var run = try #require(try fx.store.queueMergeSmokeIfNeeded(companyId: fx.company.id, now: fx.w.clock.now))
        // An earlier engine died mid-run: the row is running, its export and its raw log are left behind.
        let stale = try EngineExport.export(store: fx.store, company: try fx.current(), runId: run.runId, commit: head)
        let log = fx.w.orchestrator.smokeChecks.outputURL(run)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw output tok-0123456789\n".utf8).write(to: log)
        run.status = .running; run.startedAt = fx.w.clock.now; run.outputPath = log.path
        let running = run
        try await fx.store.writer.write { db in try running.update(db) }
        try await fx.w.orchestrator.start()
        let recovered = try #require(try fx.store.mainSmokeRun(id: run.id))
        #expect(recovered.status == .queued)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        // The raw log was scrubbed in place (or removed when it could not be).
        if FileManager.default.fileExists(atPath: log.path) {
            let text = try String(contentsOf: log, encoding: .utf8)
            #expect(!text.contains("tok-0123456789")); #expect(text.contains("[redacted API_TOKEN]"))
        }
        // The same row runs again: main can be green without a new merge.
        try await fx.w.cycle()
        #expect(try fx.store.mainSmokeRun(id: run.id)?.status == .passed)
        #expect(try fx.runs().count == 1)
        #expect(try ReleasePolicy.mainIsGreen(store: fx.store, company: try fx.current(), at: head) == (true, nil))
    }

    @Test func releaseSmokeIsNeverSupersededAndNeedsMain() async throws {
        let fx = try Fx()
        try fx.setSmoke("true")
        let old = try fx.merge(["a.txt": "x"])
        let head = try fx.merge(["b.txt": "y"])
        let queued = try #require(try fx.store.queueMergeSmokeIfNeeded(companyId: fx.company.id, now: fx.w.clock.now))
        let (store, companyId, now) = (fx.store, fx.company.id, fx.w.clock.now)
        // Right after runSmoke's write and before its export, a newer run is queued (the tick, or the owner): the release row
        // must already be running there, so superseding (queued rows only) cannot touch it. No sleeps: the seam runs inline.
        final class Seen: @unchecked Sendable { let lock = NSLock(); var status: MainSmokeStatus?; var supersededBy: String? }
        let seen = Seen()
        var checks = fx.w.orchestrator.smokeChecks
        checks.afterClaim = { run in
            let manual = try? store.requestManualSmoke(companyId: companyId, by: .owner, now: now)
            let status = try? store.mainSmokeRun(id: run.id)?.status
            seen.lock.withLock { seen.status = status; seen.supersededBy = manual?.id }
        }
        let done = try await store.runSmoke(companyId: companyId, commit: head, reason: .release, releaseId: "rel-1", checks: checks,
                                            blocking: Blocking(), clock: { now })
        #expect(seen.lock.withLock { seen.status } == .running)
        #expect(seen.lock.withLock { seen.supersededBy } != nil)
        #expect(done.status == .passed); #expect(done.reason == .release); #expect(done.releaseId == "rel-1")
        #expect(try fx.store.mainSmokeRun(id: done.id)?.status == .passed)
        #expect(fx.sandbox.calls.count == 1)
        #expect(try fx.store.mainSmokeRun(id: queued.id)?.status == .error)   // the queued merge row was superseded instead
        // The commit must be the engine-accepted main (through the engine's entry, which holds the slot).
        let engine = fx.w.orchestrator
        await #expect(throws: WorkError.invalid("\(old.prefix(7)) is not the engine-accepted main")) {
            try await engine.runSmoke(companyId: companyId, commit: old, reason: .release, releaseId: "rel-2")
        }
    }
}

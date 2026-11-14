import Foundation
import Testing
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// Plan L Task 8: the owner's rollback runs the recorded rollback commands once (claimed in one write, never retried by the
/// engine), crash recovery never runs a step again, and the owner's stop interrupts deploys and rollbacks. The Task 7 rig
/// (`ReleaseExecutorTests.Fx`): a file-backed store, a real git workspace, FakeSandbox, FakeHostingAdapter, MemoryVault, a
/// scripted HTTP probe. Nothing contacts a provider; a running step a test acts on is waited for by event, never a timer.
@Suite(.scratch) struct RollbackTests {
    typealias Fx = ReleaseExecutorTests.Fx
    static let token = ReleaseExecutorTests.token

    /// R-1, then R-2 on a newer main, both deployed by the executor.
    static func twoDeployed(_ fx: Fx) async throws -> (Release, Release) {
        let r1 = try fx.proposeAndApprove("0.1.0")
        await fx.advance()
        try fx.merge(["page.txt": "two\n"])
        try fx.passMain()
        let r2 = try fx.proposeAndApprove("0.2.0")
        await fx.advance()
        let (a, b) = (try fx.reload(r1), try fx.reload(r2))
        #expect(a.status == .deployed, "\(a.failedReason ?? "")")
        #expect(b.status == .deployed, "\(b.failedReason ?? "")")
        return (a, b)
    }

    static func rollbackCalls(_ fx: Fx) -> [FakeSandbox.Call] {
        fx.sandbox.calls.filter { $0.command.contains("/node_modules/.bin/fake deploy rollback-") }
    }

    static func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    func request(_ fx: Fx, _ ref: String) throws -> Release {
        try fx.store.requestRollback(companyId: fx.company.id, releaseRef: ref, by: .owner, now: fx.w.clock.now)
    }

    // MARK: Running the recorded plan

    @Test func rollbackRunsRecordedPlanOnly() async throws {
        let fx = try Fx()
        let (r1, r2) = try await Self.twoDeployed(fx)
        let main = try fx.store.company(id: fx.company.id)?.mainCommit
        let head = try fx.f.git(["rev-parse", "main"])
        // The smoke after a rollback has no expected text (the restored site need not carry the current one).
        try fx.store.setDeployConfig(companyId: fx.company.id, by: fx.devops.id, build: ReleaseExecutorTests.build, outputDir: "dist",
                                     smoke: [], expectText: "Text the restored site does not have", now: fx.w.clock.now)
        let before = fx.sandbox.calls.count
        let requested = try request(fx, "R-2")
        #expect(requested.rollbackStatus == .requested)
        #expect(requested.rollbackRequestedAt != nil)
        #expect(requested.rollbackStartedAt == nil)
        // Through the engine's tick (a tracked task, its git and files in Blocking bodies).
        try await fx.w.cycle()
        let back = try fx.reload(r2)
        #expect(back.rollbackStatus == .succeeded, "\(back.rollbackOutputTail ?? "")")
        #expect(back.status == .rolledBack)
        #expect(back.rolledBackAt != nil); #expect(back.rollbackStartedAt != nil); #expect(back.rollbackRequestedAt == nil)
        #expect(back.rollbackOutputTail?.contains("https://fake-rollback-r-2.local") == true)
        // Exactly the recorded steps ran, in R-1's upload, with the token in their environment only; nothing else ran.
        let calls = Array(fx.sandbox.calls.dropFirst(before))
        #expect(calls.count == r2.rollbackPlan.steps.count)
        for (call, step) in zip(calls, r2.rollbackPlan.steps) {
            #expect(Fx.same(call.cwd, try fx.upload(1)))
            #expect(call.command.hasPrefix(ShellQuote.joinArgv(step.argv, rawRefs: []) + " 2>>"), "\(call.command)")
            #expect(call.environment["CLOUDFLARE_API_TOKEN"] == Self.token)
            #expect(!call.command.contains(Self.token))
            #expect(call.policy.network == .outbound(allow: r2.rollbackPlan.network))
        }
        #expect(r2.rollbackPlan.display == r2.rollbackPlan.steps.map { ShellQuote.joinArgv($0.argv, rawRefs: ["CLOUDFLARE_API_TOKEN"]) }
            .joined(separator: "\n"))
        // What went live again is R-1's upload.
        let served = try String(contentsOf: fx.hostRoot.appending(path: "rollback-R-2/dist/index.html"), encoding: .utf8)
        #expect(served.contains("<title>Lumen</title>"))
        #expect(!FileManager.default.fileExists(atPath: fx.hostRoot.appending(path: "rollback-R-2/page.txt").path))
        // main never moves.
        #expect(try fx.store.company(id: fx.company.id)?.mainCommit == main)
        #expect(try fx.f.git(["rev-parse", "main"]) == head)
        // The redacted log is in the workspace; R-1 is untouched.
        let wsLog = EngineLayout(workspace: fx.ws).releaseDir(2).appending(path: "rollback.log")
        #expect(try String(contentsOf: wsLog, encoding: .utf8).contains("https://fake-rollback-r-2.local"))
        #expect(try fx.reload(r1).status == .deployed)
        #expect(try fx.activity().contains("R-2 (release 0.2.0) was rolled back"))
        // Nothing is left to claim; the release no longer rolls back.
        #expect(try fx.store.claimRollback(companyId: fx.company.id, now: fx.w.clock.now) == nil)
        #expect(Self.message { _ = try request(fx, "R-2") } == "R-2 is rolledBack; only deployed, interrupted or failed releases roll back")
        // A proposed release is refused, exactly.
        try fx.merge(["page.txt": "three\n"])
        try fx.passMain()
        let (r3, _) = try fx.propose("0.3.0")
        #expect(Self.message { _ = try request(fx, r3.ref) } == "R-3 is proposed; only deployed, interrupted or failed releases roll back")
        #expect(try fx.reload(r3).rollbackStatus == nil)
        // Only the owner rolls back.
        #expect(Self.message { _ = try fx.store.requestRollback(companyId: fx.company.id, releaseRef: "R-1", by: .agent(fx.devops.id)) }
                == "only the owner can roll back a release")
        #expect(Self.message { _ = try fx.store.requestRollback(companyId: fx.company.id, releaseRef: "R-9", by: .owner) } == "no release R-9")
    }

    @Test func firstReleaseRollbackDeploysPlaceholder() async throws {
        let fx = try Fx()
        let r1 = try fx.proposeAndApprove()
        await fx.advance()
        #expect(try fx.reload(r1).status == .deployed)
        let placeholder = try fx.layout().placeholderDir
        #expect(r1.rollbackPlan.cwdPath == placeholder.path)
        _ = try request(fx, "R-1")
        await fx.advance()
        let back = try fx.reload(r1)
        #expect(back.status == .rolledBack, "\(back.rollbackOutputTail ?? "")")
        let page = try String(contentsOf: placeholder.appending(path: "index.html"), encoding: .utf8)
        #expect(page == Placeholder.html(companyName: "Lumen"))
        let calls = Self.rollbackCalls(fx)
        #expect(calls.count == 1)
        #expect(Fx.same(try #require(calls.first).cwd, placeholder))
        #expect(try FileManager.default.contentsOfDirectory(atPath: placeholder.path) == ["index.html"])
        #expect(try String(contentsOf: fx.hostRoot.appending(path: "rollback-R-1/index.html"), encoding: .utf8) == page)
    }

    @Test func rollbackStartIsAtomic() async throws {
        let fx = try Fx()
        let r1 = try fx.proposeAndApprove()
        await fx.advance()
        // Every change of a release's rollback status is logged as written (a temporary trigger on the writer's connection).
        try await fx.store.writer.write { db in
            try db.execute(sql: "CREATE TEMP TABLE rollbackWrites (status TEXT, requestedAt TEXT, startedAt TEXT)")
            try db.execute(sql: """
                CREATE TEMP TRIGGER rollbackWritesLog AFTER UPDATE ON "release" WHEN NEW.rollbackStatus IS NOT OLD.rollbackStatus
                BEGIN INSERT INTO rollbackWrites VALUES (NEW.rollbackStatus, NEW.rollbackRequestedAt, NEW.rollbackStartedAt); END
                """)
        }
        _ = try request(fx, "R-1")
        async let a: Void = fx.executor.advance(now: fx.w.clock.now)
        async let b: Void = fx.executor.advance(now: fx.w.clock.now)
        _ = await (a, b)
        await fx.advance()
        #expect(Self.rollbackCalls(fx).count == 1)
        let back = try fx.reload(r1)
        #expect(back.status == .rolledBack)
        #expect(back.rollbackRequestedAt == nil); #expect(back.rollbackStartedAt != nil)
        let writes = try await fx.store.writer.write { db in
            try Row.fetchAll(db, sql: "SELECT status, requestedAt, startedAt FROM rollbackWrites ORDER BY rowid")
        }
        #expect(writes.map { $0["status"] as String? } == ["requested", "running", "succeeded"])
        // The claim set `rollbackStartedAt` and cleared `rollbackRequestedAt` in the one write that made it `running`.
        let running = try #require(writes.first { ($0["status"] as String?) == "running" })
        #expect((running["requestedAt"] as String?) == nil)
        #expect((running["startedAt"] as String?) != nil)
        #expect(writes.filter { ($0["status"] as String?) == "requested" }.allSatisfy { ($0["startedAt"] as String?) == nil })
    }

    @Test func failedRollbackNotRetried() async throws {
        let fx = try Fx(configure: { $0.rollbackEnv = ["FAKE_EXIT": "1"] })
        let r1 = try fx.proposeAndApprove()
        await fx.advance()
        #expect(try fx.reload(r1).status == .deployed)
        _ = try request(fx, "R-1")
        await fx.advance()
        let failed = try fx.reload(r1)
        #expect(failed.rollbackStatus == .failed)
        #expect(failed.status == .deployed)
        #expect(failed.rolledBackAt == nil)
        #expect(failed.rollbackOutputTail?.contains("https://fake-rollback-r-1.local") == true)
        #expect(try fx.notices().contains { $0.title == "Rollback of R-1 failed" && $0.body.contains("the deploy step failed (exit 1)") })
        // The engine never retries it by itself.
        for _ in 0..<3 { await fx.advance() }
        try await fx.w.cycle()
        #expect(Self.rollbackCalls(fx).count == 1)
        #expect(try fx.reload(r1).rollbackStatus == .failed)
        // The owner asks again: a second run.
        let again = try request(fx, "R-1")
        #expect(again.rollbackStatus == .requested)
        await fx.advance()
        #expect(Self.rollbackCalls(fx).count == 2)
        #expect(try fx.reload(r1).rollbackStatus == .failed)
    }

    @Test func rollbackTwiceRefusedWhileRequested() async throws {
        let fx = try Fx()
        _ = try fx.proposeAndApprove()
        await fx.advance()
        _ = try request(fx, "R-1")
        #expect(Self.message { _ = try request(fx, "R-1") } == "R-1 is already rolling back")
        try await fx.store.writer.write { db in
            try db.execute(sql: #"UPDATE "release" SET rollbackStatus = 'running' WHERE number = 1"#)
        }
        #expect(Self.message { _ = try request(fx, "R-1") } == "R-1 is already rolling back")
    }

    /// Final-fix2 R1 (m7 residual): a rollback requested before a backup was taken is not carried out after a restore from
    /// that backup. The restore's carry (`RestoreCarry.apply`, what `Restore.restore` writes into the staged snapshot) is applied
    /// to this rig's database; once the owner resumes, the engine's tick runs no provider step and the release stays deployed.
    @Test func restoredRequestedRollbackNeverRuns() async throws {
        let fx = try Fx()
        let (_, r2) = try await Self.twoDeployed(fx)
        let before = fx.sandbox.calls.count
        #expect(try request(fx, "R-2").rollbackStatus == .requested)
        let notes = try await fx.store.writer.write { db in
            try RestoreCarry.apply(.none, to: db, snapshot: "brahma-test.sqlite", now: fx.w.clock.now)
        }
        #expect(notes.contains("Lumen: the rollback of R-2 (release 0.2.0) was requested in the snapshot and is cancelled; "
                               + "request it again"), "\(notes)")
        #expect(try fx.store.resumeAfterStop(now: fx.w.clock.now))
        await fx.advance()
        try await fx.w.cycle()
        let back = try fx.reload(r2)
        #expect(back.rollbackStatus == nil)
        #expect(back.status == .deployed)
        #expect(Self.rollbackCalls(fx).isEmpty)
        #expect(fx.sandbox.calls.count == before, "a provider step ran after the restore")
    }

    @Test func missingPreviousFilesRefused() async throws {
        let fx = try Fx()
        let (_, r2) = try await Self.twoDeployed(fx)
        try FileManager.default.removeItem(at: try fx.upload(1))
        _ = try request(fx, "R-2")
        await fx.advance()
        let back = try fx.reload(r2)
        #expect(back.rollbackStatus == .failed)
        #expect(back.status == .deployed)
        #expect(Self.rollbackCalls(fx).isEmpty)
        #expect(try fx.notices().contains {
            $0.title == "Rollback of R-2 failed" && $0.body.hasPrefix("R-1's files are gone; roll back from the provider dashboard")
        })
    }

    @Test func tamperedRollbackPlanRefused() async throws {
        let fx = try Fx()
        let r1 = try fx.proposeAndApprove()
        await fx.advance()
        // A rollback plan edited in the database (its hash recomputed, so it is self-consistent) is not the recorded one.
        var plan = r1.rollbackPlan
        plan = try DeployPlan(steps: [DeployStep(label: "deploy", argv: ["/bin/sh", "-c", "echo evil"])], stageFrom: [],
                              cwdPath: plan.cwdPath, network: plan.network, tokenSecret: plan.tokenSecret, env: plan.env,
                              build: plan.build, outputDir: plan.outputDir)
        let json = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        try await fx.store.writer.write { db in
            try db.execute(sql: #"UPDATE "release" SET rollbackPlan = ? WHERE id = ?"#, arguments: [json, r1.id])
        }
        _ = try request(fx, "R-1")
        let before = fx.sandbox.calls.count
        await fx.advance()
        let back = try fx.reload(r1)
        #expect(back.rollbackStatus == .failed)
        #expect(fx.sandbox.calls.count == before)
        #expect(try fx.notices().contains { $0.title == "Rollback of R-1 failed" && $0.body.contains("no longer match") })
    }

    @Test func rollbackTargetVerifiedWithTheToken() async throws {
        // Vercel-style (the Task 8 carried-forward rule): the restored deployment is confirmed to be this project's with the
        // token, before anything is rolled back to it; anything else fails closed.
        let fx = try Fx(configure: { $0.verify = true; $0.rollbackEnv = ["FAKE_INSPECT_PROJECT": "evil"] })
        let (r1, r2) = try await Self.twoDeployed(fx)
        #expect(r2.rollbackPlan.steps.map(\.label) == [DeployStep.verifyLabel, "deploy"])
        #expect(r2.rollbackPlan.steps[0].argv.last == r1.deployURL)
        _ = try request(fx, "R-2")
        await fx.advance()
        let back = try fx.reload(r2)
        #expect(back.rollbackStatus == .failed)
        #expect(Self.rollbackCalls(fx).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fx.hostRoot.appending(path: "rollback-R-2").path))
        #expect(try fx.notices().contains { $0.title == "Rollback of R-2 failed" && $0.body.contains("is not a deployment of lumen") })

        // The configured project's own deployment: confirmed, then rolled back to.
        let good = try Fx(configure: { $0.verify = true })
        _ = try await Self.twoDeployed(good)
        let before = good.sandbox.calls.count
        _ = try request(good, "R-2")
        await good.advance()
        let done = try #require(try good.store.release(companyId: good.company.id, ref: "R-2"))
        #expect(done.status == .rolledBack, "\(done.rollbackOutputTail ?? "")")
        let order = good.sandbox.calls.dropFirst(before).filter { $0.command.contains("fake inspect https://fake-r-1.local") || $0.command.contains("fake deploy rollback-") }
        #expect(order.map { $0.command.contains("inspect") } == [true, false])
    }

    /// Final-review I6b: with a provider whose deploy URLs must be verified with the token (Vercel), the site is smoked at
    /// the owner's production URL or at a URL verified in this very run, never at an unverified one: the deploy smokes its
    /// inspected deploy URL; a rollback smokes the target its verify step confirmed, not a URL the rollback printed; a
    /// placeholder rollback (nothing verified) fails closed and says to set the production URL.
    @Test func smokeOnlyVerifiedURLs() async throws {
        let fx = try Fx(configure: { $0.verify = true; $0.smokesDeployURL = true })
        let (_, r2) = try await Self.twoDeployed(fx)
        #expect(r2.productionURL == "https://fake-r-2.local")
        #expect(fx.http.requests.map(\.url.absoluteString) == ["https://fake-r-1.local/", "https://fake-r-2.local/"])
        _ = try request(fx, "R-2")
        await fx.advance()
        let back = try fx.reload(r2)
        #expect(back.status == .rolledBack, "\(back.rollbackOutputTail ?? "")")
        #expect(fx.http.requests.last?.url.absoluteString == "https://fake-r-1.local/", "the verified target, not fake-rollback-r-2")

        // The first release's rollback deploys the placeholder: no URL is verified, so nothing is smoked.
        let first = try Fx(configure: { $0.verify = true; $0.smokesDeployURL = true })
        let r1 = try first.proposeAndApprove()
        await first.advance()
        _ = try request(first, "R-1")
        let smoked = first.http.requests.count
        await first.advance()
        let failed = try first.reload(r1)
        #expect(failed.rollbackStatus == .failed)
        #expect(try first.notices().contains {
            $0.title == "Rollback of R-1 failed" && $0.body.contains("set the production URL in HOSTING")
        }, "\((try? first.notices().map(\.body)) ?? [])")
        #expect(first.http.requests.count == smoked)
    }

    @Test func rollbackRestoresTheRestoredReleasesOutput() async throws {
        // Task 4 M3: R-2's rollback deploys R-1's own output folder, build, commit and version, not the current settings.
        let fx = try Fx()
        let r1 = try fx.proposeAndApprove("0.1.0")
        await fx.advance()
        try fx.store.setDeployConfig(companyId: fx.company.id, by: fx.devops.id, build: "mkdir -p public && echo '<title>Lumen</title>' > public/index.html",
                                     outputDir: "public", smoke: [], expectText: "Lumen", now: fx.w.clock.now)
        try fx.merge(["page.txt": "two\n"])
        try fx.passMain()
        let r2 = try fx.proposeAndApprove("0.2.0")
        await fx.advance()
        #expect(try fx.reload(r2).status == .deployed)
        #expect(r2.outputDir == "public")
        #expect(r2.rollbackPlan.outputDir == "dist")
        #expect(r2.rollbackPlan.build == ReleaseExecutorTests.build)
        #expect(r2.rollbackPlan.cwdPath == (try fx.upload(1)).path)
        // With the real Cloudflare adapter: R-1's folder, commit and version are what the rollback deploys.
        let cf = CloudflarePagesAdapter()
        var settings = try #require(try fx.store.hosting(companyId: fx.company.id))
        settings.accountId = "acct-1"
        let input = Store.rollbackInput(settings: settings, release: 2, commit: r2.commit, version: r2.version, previous: r1,
                                        layout: try fx.layout(), cli: cf.cli)
        let plan = try cf.rollbackPlan(input)
        let argv = try #require(plan.steps.first?.argv)
        #expect(Array(argv.dropFirst().prefix(3)) == ["pages", "deploy", "dist"])
        #expect(argv.contains(r1.commit)); #expect(!argv.contains(r2.commit))
        #expect(argv.contains("Release 0.1.0"))
        _ = try request(fx, "R-2")
        await fx.advance()
        #expect(try fx.reload(r2).status == .rolledBack)
        #expect(FileManager.default.fileExists(atPath: fx.hostRoot.appending(path: "rollback-R-2/dist/index.html").path))
    }

    // MARK: Fix round 1

    func pause(_ fx: Fx, _ paused: Bool) throws {
        try fx.store.writer.write { db in
            try db.execute(sql: "UPDATE company SET status = ? WHERE id = ?", arguments: [paused ? "paused" : "running", fx.company.id])
        }
    }

    @Test func pausedCompanyRollsBackButNeverDeploys() async throws {
        // I1: a paused company's requested rollback runs (rollback-only); an approved deploy in it waits for the resume.
        let fx = try Fx()
        let r1 = try fx.proposeAndApprove()
        await fx.advance()
        #expect(try fx.reload(r1).status == .deployed)
        try pause(fx, true)
        _ = try request(fx, "R-1")
        try await fx.w.cycle()
        let back = try fx.reload(r1)
        #expect(back.status == .rolledBack, "\(back.rollbackOutputTail ?? "")")
        #expect(Self.rollbackCalls(fx).count == 1)
        // Still paused: an approved release is never started.
        try fx.merge(["page.txt": "two\n"])
        try fx.passMain()
        let r2 = try fx.proposeAndApprove("0.2.0")
        try await fx.w.cycle()
        await fx.advance()
        #expect(try fx.reload(r2).status == .approved)
        #expect(try fx.releaseSmokes().filter { $0.releaseId == r2.id }.isEmpty)
        try pause(fx, false)
        try await fx.w.cycle()
        #expect(try fx.reload(r2).status == .deployed)
    }

    @Test func onlyTheLiveReleaseRollsBack() async throws {
        // I2a: only the newest deployed-or-failed release, and never while a release is open.
        let fx = try Fx()
        _ = try await Self.twoDeployed(fx)
        #expect(Self.message { _ = try request(fx, "R-1") } == "R-1 is not the live release; roll back R-2")
        try fx.merge(["page.txt": "three\n"])
        try fx.passMain()
        // Final-review m1: an open proposal's refusal names the ask the owner rejects first.
        let (_, ask3) = try fx.propose("0.3.0")
        #expect(Self.message { _ = try request(fx, "R-2") } == "R-3 is still proposed; reject \(ask3.ref) first")
        #expect(try fx.store.release(companyId: fx.company.id, ref: "R-2")?.rollbackStatus == nil)
        // Approved (not started yet): it runs first.
        _ = try fx.store.ownerDecide(askId: ask3.id, approve: true, now: fx.w.clock.now)
        #expect(Self.message { _ = try request(fx, "R-2") } == "R-3 is still approved; roll back after it finishes")
    }

    /// Final-review I2: a release interrupted while deploying (a stop or a crash) may be partly live. Its own recorded rollback
    /// (the release before it) is the owner's undo: the notice says so, the request is accepted and runs; the older release is
    /// not offered (rolling it back would restore the one before it, two versions back).
    @Test func interruptedReleaseRollsBack() async throws {
        let fx = try Fx()
        let r1 = try fx.proposeAndApprove("0.1.0")
        await fx.advance()
        try fx.merge(["page.txt": "two\n"])
        try fx.passMain()
        let r2 = try fx.proposeAndApprove("0.2.0")
        try setRow(fx, r2, "status = 'deploying', startedAt = CURRENT_TIMESTAMP")
        try await fx.executor.recover(now: fx.w.clock.now)
        #expect(try fx.reload(r2).status == .interrupted)
        #expect(try fx.notices().contains {
            $0.title == "Release 0.2.0 was interrupted"
                && $0.body == "It may be partly live. Run brahma release rollback Lumen R-2 (puts R-1 back) or use Roll back in Releases."
        }, "\((try? fx.notices().map(\.body)) ?? [])")
        #expect(Self.message { _ = try request(fx, "R-1") } == "R-1 is not the live release; roll back R-2")
        #expect(try request(fx, "R-2").rollbackStatus == .requested)
        try await fx.w.cycle()
        let back = try fx.reload(r2)
        #expect(back.rollbackStatus == .succeeded, "\(back.rollbackOutputTail ?? "")")
        #expect(back.status == .rolledBack)
        // R-2's recorded plan ran: R-1's upload went live again.
        let calls = Self.rollbackCalls(fx)
        #expect(calls.count == 1)
        #expect(Fx.same(try #require(calls.first).cwd, try fx.upload(1)))
        #expect(try fx.reload(r1).status == .deployed)
    }

    /// Final-review m1: a release that failed before its deploy step changed nothing live, so it is not "the live release":
    /// it does not roll back, and the release before it still does.
    @Test func failedBeforeDeployingIsNotLive() async throws {
        let fx = try Fx()
        let r1 = try fx.proposeAndApprove("0.1.0")
        await fx.advance()
        #expect(try fx.reload(r1).status == .deployed)
        #expect(try fx.reload(r1).deployStartedAt != nil)
        try fx.store.setSmokeCheck(companyId: fx.company.id, by: fx.devops.id, check: CheckSpec(command: "exit 1"), now: fx.w.clock.now)
        try fx.merge(["page.txt": "two\n"])
        try fx.passMain()
        let r2 = try fx.proposeAndApprove("0.2.0")
        await fx.advance()
        let failed = try fx.reload(r2)
        #expect(failed.status == .failed); #expect(failed.deployStartedAt == nil)
        #expect(Self.message { _ = try request(fx, "R-2") } == "R-2 failed before deploying; nothing to roll back")
        #expect(try request(fx, "R-1").rollbackStatus == .requested)
    }

    @Test func pendingRollbackHoldsDeploysAndProposals() async throws {
        // I2b: while a rollback is requested or running, nothing is proposed, and an approved deploy is not claimed: it runs
        // after the rollback finishes.
        let fx = try Fx()
        let r1 = try fx.proposeAndApprove()
        await fx.advance()
        _ = try request(fx, "R-1")
        try fx.merge(["page.txt": "two\n"])
        try fx.passMain()
        #expect(Self.message { _ = try fx.propose("0.2.0") } == "R-1's rollback is requested")
        await fx.advance()
        #expect(try fx.reload(r1).status == .rolledBack)
        // An approved release and a rollback requested behind it (written straight into the database: the API refuses it).
        let fresh = try Fx()
        let first = try fresh.proposeAndApprove()
        await fresh.advance()
        try fresh.merge(["page.txt": "two\n"])
        try fresh.passMain()
        let second = try fresh.proposeAndApprove("0.2.0")
        try setRow(fresh, first, "rollbackStatus = 'requested', rollbackRequestedAt = CURRENT_TIMESTAMP")
        #expect(try fresh.store.claimRelease(companyId: fresh.company.id, now: fresh.w.clock.now) == nil)
        await fresh.advance()
        #expect(try fresh.reload(first).status == .rolledBack)
        #expect(try fresh.reload(second).status == .approved)
        #expect(try fresh.deploySteps().count == 1)
        await fresh.advance()
        let done = try fresh.reload(second)
        #expect(done.status == .deployed, "\(done.failedReason ?? "")")
    }

    @Test func oneRollbackAtATime() async throws {
        // I2c: two concurrent requests: one wins; another release's request while one is pending is refused.
        let fx = try Fx()
        let (r1, _) = try await Self.twoDeployed(fx)
        let (store, companyId) = (fx.store, fx.company.id)
        let results = await withTaskGroup(of: String?.self) { group -> [String?] in
            for _ in 0..<2 {
                group.addTask { Self.message { _ = try store.requestRollback(companyId: companyId, releaseRef: "R-2", by: .owner) } }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.filter { $0 == nil }.count == 1)
        #expect(results.contains("R-2 is already rolling back"))
        // A rollback pending on another release (written straight into the database) refuses a new request.
        try setRow(fx, r1, "rollbackStatus = 'running'")
        try await fx.store.writer.write { db in try db.execute(sql: #"UPDATE "release" SET rollbackStatus = NULL WHERE number = 2"#) }
        #expect(Self.message { _ = try request(fx, "R-2") } == "R-1's rollback is running")
    }

    @Test func vercelPreviousWithoutURLNeverDeploysPlaceholder() async throws {
        // M1: a previous release with no recorded deploy URL records no rollback commands (never the placeholder); the ask
        // says so, and a rollback request is refused.
        let v = VercelAdapter()
        let layout = ReleaseLayout(root: try tempDir().appending(path: "releases/c1"))
        let s = HostingSettings(companyId: "c1", provider: .vercel, project: "acme", accountId: "team_1", outputDir: "dist", updatedAt: Date())
        let previous = Release(companyId: "c1", number: 1, version: "0.1.0", status: .deployed, provider: .vercel, project: "acme",
                               commit: String(repeating: "a", count: 40), build: nil, outputDir: "dist",
                               plan: try v.deployPlan(DeployInput(settings: s, commit: String(repeating: "a", count: 40), version: "0.1.0",
                                                                  layout: layout, release: 1, cli: v.cli)),
                               rollbackPlan: try v.rollbackPlan(DeployInput(settings: s, commit: String(repeating: "a", count: 40),
                                                                            version: "0.1.0", layout: layout, release: 1, cli: v.cli)),
                               proposedById: "a1", createdAt: Date())
        #expect(previous.deployURL == nil)
        let input = Store.rollbackInput(settings: s, release: 2, commit: String(repeating: "b", count: 40), version: "0.2.0",
                                        previous: previous, layout: layout, cli: v.cli)
        let none = try v.rollbackPlan(input)
        #expect(none.steps.isEmpty)
        #expect(none.cwdPath != layout.placeholderDir.path)
        // No previous release at all: the placeholder, as before.
        #expect(try v.rollbackPlan(Store.rollbackInput(settings: s, release: 1, commit: previous.commit, version: "0.1.0", previous: nil,
                                                       layout: layout, cli: v.cli)).cwdPath == layout.placeholderDir.path)
        let plan = try v.deployPlan(DeployInput(settings: s, commit: String(repeating: "b", count: 40), version: "0.2.0", layout: layout,
                                                release: 2, cli: v.cli))
        let text = Store.deployProposal(settings: s, adapter: v, smokeCheck: CheckSpec(command: "true"), sha7: "bbbbbbb", plan: plan,
                                        rollback: none)
        #expect(text.contains("Rollback recorded now:\nnone: the previous release has no recorded deploy URL; roll back from the provider dashboard"),
                "\(text)")
        // A release recorded so is refused at request time; nothing runs.
        let fx = try Fx()
        let r1 = try fx.proposeAndApprove()
        await fx.advance()
        let json = String(decoding: try JSONEncoder().encode(none), as: UTF8.self)
        try setRow(fx, r1, "rollbackPlan = '\(json.replacingOccurrences(of: "'", with: "''"))'")
        #expect(Self.message { _ = try request(fx, "R-1") } == "R-1 has no recorded rollback; roll back from the provider dashboard")
        #expect(Self.rollbackCalls(fx).isEmpty)
    }

    // MARK: Crash recovery

    func setRow(_ fx: Fx, _ r: Release, _ sql: String) throws {
        try fx.store.writer.write { db in try db.execute(sql: #"UPDATE "release" SET "# + sql + " WHERE id = ?", arguments: [r.id]) }
    }

    @Test func crashDuringRollbackIsInterrupted() async throws {
        let fx = try Fx()
        let r1 = try fx.proposeAndApprove()
        await fx.advance()
        try setRow(fx, r1, "rollbackStatus = 'running', rollbackStartedAt = CURRENT_TIMESTAMP")
        try await fx.executor.recover(now: fx.w.clock.now)
        let back = try fx.reload(r1)
        #expect(back.rollbackStatus == .interrupted)
        #expect(back.status == .deployed)
        #expect(try fx.notices().contains {
            $0.title == "Rollback of R-1 was interrupted" && $0.body == "Check Cloudflare Pages; you can request the rollback again."
        })
        await fx.advance()
        try await fx.w.cycle()
        #expect(Self.rollbackCalls(fx).isEmpty)
        #expect(try fx.reload(r1).rollbackStatus == .interrupted)
        // The owner may ask again.
        #expect(try request(fx, "R-1").rollbackStatus == .requested)
    }

    @Test func crashDuringDeployNeverReruns() async throws {
        let fx = try Fx()
        let approved = try fx.proposeAndApprove()
        try setRow(fx, approved, "status = 'deploying', startedAt = CURRENT_TIMESTAMP")
        // The engine's start runs the recovery.
        try await fx.w.orchestrator.start()
        let r = try fx.reload(approved)
        #expect(r.status == .interrupted)
        #expect(r.failedReason == "the engine stopped during the deploy; check Cloudflare Pages, then propose again")
        #expect(try fx.notices().contains { $0.title == "Release 0.1.0 was interrupted" })
        try await fx.w.cycle()
        await fx.advance()
        #expect(fx.sandbox.calls.isEmpty)
        #expect(try fx.releaseSmokes().isEmpty)
        #expect(try fx.reload(approved).status == .interrupted)
    }

    @Test func crashDuringBuildFailsWithoutRerun() async throws {
        let fx = try Fx()
        let first = try fx.proposeAndApprove("0.1.0")
        try setRow(fx, first, "status = 'building', startedAt = CURRENT_TIMESTAMP")
        try await fx.executor.recover(now: fx.w.clock.now)
        let r = try fx.reload(first)
        #expect(r.status == .failed)
        #expect(r.failedReason == "the engine stopped during build; propose again")
        #expect(try fx.notices().contains { $0.title == "Release 0.1.0 was stopped" && $0.body == "Nothing was deployed." })
        // A release left smoking the deployed site: failed too, never smoked again.
        let second = try fx.proposeAndApprove("0.2.0")
        try setRow(fx, second, "status = 'smoking', startedAt = CURRENT_TIMESTAMP")
        try await fx.executor.recover(now: fx.w.clock.now)
        #expect(try fx.reload(second).status == .failed)
        #expect(try fx.reload(second).failedReason == "the engine stopped during smoke; propose again")
        await fx.advance()
        try await fx.w.cycle()
        #expect(fx.sandbox.calls.isEmpty)
        #expect(fx.http.requests.isEmpty)
        #expect(try fx.releaseSmokes().isEmpty)
    }

    // MARK: The owner's stop

    @Test func emergencyStopInterruptsDeploy() async throws {
        let fx = try Fx(configure: { $0.sleepSeconds = 300 })
        let approved = try fx.proposeAndApprove()
        let running = Task { await fx.executor.advance(now: fx.w.clock.now) }
        await fx.sandbox.waitForSpawn { $0.command.contains("/node_modules/.bin/fake deploy ") }
        let pid = try #require(fx.sandbox.spawnedPids.last)
        _ = try fx.store.emergencyStop(note: "test", by: "owner", now: fx.w.clock.now)
        let started = AwakeTime.now
        await fx.executor.stopAll(reason: "stopped by the owner: test")
        await running.value
        // A hang bound, not a race: the group is gone well inside the grace plus a poll.
        #expect(AwakeTime.now - started < .seconds(6))
        #expect(kill(pid, 0) != 0)
        let r = try fx.reload(approved)
        #expect(r.status == .interrupted)
        #expect(r.failedReason == "stopped by the owner during deploy")
        #expect(try fx.notices().contains { $0.title == "Release 0.1.0 was interrupted" })
        // While the stop holds: nothing is claimed and no main-smoke run starts.
        let manual = try fx.store.requestManualSmoke(companyId: fx.company.id, by: .owner, now: fx.w.clock.now)
        try await fx.w.cycle()
        #expect(try fx.store.mainSmokeRun(id: manual.id)?.status == .queued)
        #expect(fx.smokeSandbox.calls.count == 1)    // only the release's own smoke, before the stop
        // Resumed: still never run again.
        try fx.store.resumeAfterStop(now: fx.w.clock.now)
        await fx.advance()
        #expect(try fx.reload(approved).status == .interrupted)
        #expect(try fx.deploySteps().count == 1)
    }

    @Test func emergencyStopInterruptsRollback() async throws {
        let fx = try Fx(configure: { $0.rollbackEnv = ["FAKE_SLEEP": "300"] })
        let r1 = try fx.proposeAndApprove()
        await fx.advance()
        #expect(try fx.reload(r1).status == .deployed)
        _ = try request(fx, "R-1")
        let running = Task { await fx.executor.advance(now: fx.w.clock.now) }
        await fx.sandbox.waitForSpawn { $0.command.contains("/node_modules/.bin/fake deploy rollback-") }
        let pid = try #require(fx.sandbox.spawnedPids.last)
        // Through the engine's own stop path: the tick sees the stop and runs the observers.
        _ = try fx.store.emergencyStop(note: nil, by: "owner", now: fx.w.clock.now)
        try await fx.w.cycle()
        await running.value
        #expect(kill(pid, 0) != 0)
        let back = try fx.reload(r1)
        #expect(back.rollbackStatus == .interrupted)
        #expect(back.status == .deployed)
        #expect(try fx.notices().contains {
            $0.title == "Rollback of R-1 was interrupted" && $0.body == "Check Cloudflare Pages; you can request the rollback again."
        })
        #expect(try fx.activity().contains { $0.contains("stopped by the owner during rollback") })
        try fx.store.resumeAfterStop(now: fx.w.clock.now)
        await fx.advance()
        #expect(Self.rollbackCalls(fx).count == 1)
        #expect(try fx.reload(r1).rollbackStatus == .interrupted)
    }

    @Test func stopDuringSmokingFails() async throws {
        // Task 7 M12: the owner's stop while the deployed site is smoked: failed (not interrupted), never smoked again.
        let fx = try Fx()
        let store = fx.store
        fx.http.onSend = { _ in _ = try? store.emergencyStop(note: nil, by: "owner", now: Date()) }
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .failed)
        #expect(r.failedReason == "stopped by the owner during smoke")
        #expect(try fx.notices().contains { $0.title == "Release 0.1.0 was stopped" && $0.body.hasPrefix("Run brahma release rollback") })
        fx.http.onSend = nil
        try fx.store.resumeAfterStop(now: fx.w.clock.now)
        let asked = fx.http.requests.count
        await fx.advance()
        #expect(fx.http.requests.count == asked)
        #expect(try fx.deploySteps().count == 1)
    }

    @Test func engineShutdownWhileDeployingInterrupts() async throws {
        // Task 7 M12: the engine shutting down (its task cancelled) while deploying: interrupted, never run again.
        let fx = try Fx(configure: { $0.sleepSeconds = 300 })
        let approved = try fx.proposeAndApprove()
        let running = Task { await fx.executor.advance(now: fx.w.clock.now) }
        await fx.sandbox.waitForSpawn { $0.command.contains("/node_modules/.bin/fake deploy ") }
        let pid = try #require(fx.sandbox.spawnedPids.last)
        running.cancel()
        await running.value
        #expect(kill(pid, 0) != 0)
        let r = try fx.reload(approved)
        #expect(r.status == .interrupted)
        #expect(r.failedReason == "the engine stopped during the deploy; check Cloudflare Pages, then propose again")
        await fx.advance()
        #expect(try fx.deploySteps().count == 1)
    }

    // MARK: Redaction pinned to the token read

    @Test func rotatedTokenStaysRedactedInStepOutput() async throws {
        // The owner rotates the token while a token step runs, and the redactor reloads before the step's output is published:
        // the value the step was given is still redacted everywhere its output lands (deploy and rollback alike).
        let gates = try tempDir()
        let deployGate = gates.appending(path: "deploy"), rollbackGate = gates.appending(path: "rollback")
        let fx = try Fx(configure: {
            $0.echoToken = true
            $0.waitFor = deployGate.path
            $0.rollbackEnv = ["FAKE_WAIT_FOR": rollbackGate.path]
        })
        let marker = "[redacted CLOUDFLARE_API_TOKEN]"
        func rotate(to value: String) throws {
            fx.w.clock.advance(1)
            try fx.store.setSecret(companyId: fx.company.id, name: "CLOUDFLARE_API_TOKEN", value: value, isTest: false,
                                   vault: fx.vault, now: fx.w.clock.now)
            try fx.store.reloadRedactorIfNeeded(vault: fx.vault)
        }
        let approved = try fx.proposeAndApprove()
        let deploying = Task { await fx.executor.advance(now: fx.w.clock.now) }
        await fx.sandbox.waitForSpawn { $0.command.contains("/node_modules/.bin/fake deploy R-1") }
        let rotated = "cf-rotated-token-fedcba9876543210"
        try rotate(to: rotated)
        #expect(fx.store.redactor.apply(Self.token) == Self.token)      // the store's redactor no longer knows the step's value
        try Data().write(to: deployGate)
        await deploying.value
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        let wsDir = EngineLayout(workspace: fx.ws).releaseDir(1)
        let deployTexts = [try String(contentsOf: wsDir.appending(path: "deploy.log"), encoding: .utf8),
                           try String(contentsOf: fx.releaseDir().appending(path: "deploy.log"), encoding: .utf8), r.outputTail ?? ""]
        for text in deployTexts {
            #expect(text.contains("using token \(marker)"), "\(text)")
            #expect(!text.contains(Self.token))
        }
        // The rollback holds the rotated value; it is rotated again mid-step.
        _ = try request(fx, "R-1")
        let rolling = Task { await fx.executor.advance(now: fx.w.clock.now) }
        await fx.sandbox.waitForSpawn { $0.command.contains("/node_modules/.bin/fake deploy rollback-R-1") }
        try rotate(to: "cf-third-token-00112233445566778899")
        #expect(fx.store.redactor.apply(rotated) == rotated)
        try Data().write(to: rollbackGate)
        await rolling.value
        let back = try fx.reload(r)
        #expect(back.status == .rolledBack, "\(back.rollbackOutputTail ?? "")")
        let rollbackTexts = [try String(contentsOf: wsDir.appending(path: "rollback.log"), encoding: .utf8),
                             try String(contentsOf: fx.releaseDir().appending(path: "rollback.log"), encoding: .utf8),
                             back.rollbackOutputTail ?? ""]
        for text in rollbackTexts {
            #expect(text.contains("using token \(marker)"), "\(text)")
            #expect(!text.contains(rotated)); #expect(!text.contains(Self.token))
        }
    }

    // MARK: Agents never write releases

    @Test func releasesDirReadOnlyForAgents() throws {
        let w = try World()
        let company = try w.company("Lumen")
        let eng = try w.hire(company, "eng-1", role: "engineer")
        let item = try w.store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Thing", ownerId: eng.id, status: .ready), now: w.clock.now)
        let layout = SandboxLayout(paths: w.paths, company: company, agentHandle: "eng-1")
        try layout.ensure()
        let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let releases = SandboxPath.resolve(EngineLayout(workspace: ws).releasesDir.path)
        let dataHomeReleases = SandboxPath.resolve(try ReleaseLayout(paths: w.paths, companyId: company.id).root.path)
        for (kind, theItem) in [(TurnKind.work, Optional(item)), (.work, nil), (.review, Optional(item))] {
            let scope = try SandboxScope.forTurn(layout: layout, paths: w.paths, otherWorkspaces: [], backupTargets: [], kind: kind,
                                                 item: theItem, company: company, grants: GrantInputs(), darwinUserTemp: nil,
                                                 userHome: w.userHome)
            let label = "\(kind) \(theItem == nil ? "itemless" : "item")"
            // `.brahma/releases` is write-denied on every turn (agents read only its redacted logs).
            #expect(scope.denyWrite.contains { SandboxPath.resolve($0.path) == releases }, "\(label)")
            for entry in scope.writable {
                let path = SandboxPath.resolve(entry.path)
                #expect(!SandboxPath.overlaps(path, releases), "\(label): \(path)")
                // The data-home releases folder (raw output, uploads, the provider CLI) is in no turn's writable list.
                #expect(!SandboxPath.overlaps(path, dataHomeReleases), "\(label): \(path)")
            }
            #expect(!scope.readable.contains { SandboxPath.overlaps(SandboxPath.resolve($0.path), dataHomeReleases) }, "\(label)")
        }
    }
}

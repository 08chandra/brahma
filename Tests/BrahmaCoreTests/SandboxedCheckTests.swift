import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Engine-run checks through the sandbox: the route the Orchestrator builds (company, purpose and place from the engine's
/// own record of the run), the policy it gets, and the fallbacks. A fake `SandboxedRunner` records what it is asked.
@Suite(.scratch, .serialized) struct SandboxedCheckTests {
    final class FakeSandbox: SandboxedRunner, @unchecked Sendable {
        struct Call: Sendable {
            var command: String
            var cwd: URL
            var environment: [String: String]
            var timeout: Duration
            var outputURL: URL
            var policy: SandboxPolicy
        }
        private let lock = NSLock()
        private var _calls: [Call] = []
        var calls: [Call] { lock.withLock { _calls } }
        var outcome = CheckOutcome(exitCode: 0, timedOut: false, tail: "sandboxed pass")

        func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                 policy: SandboxPolicy) async -> CheckOutcome {
            lock.withLock { _calls.append(Call(command: command, cwd: cwd, environment: environment, timeout: timeout,
                                               outputURL: outputURL, policy: policy)) }
            return outcome
        }

        func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL,
                   policy: SandboxPolicy) throws -> any SandboxedProcess {
            throw SandboxError.unavailable
        }
    }

    /// A company with a real git workspace whose checks go through `SandboxedCheckRunner` with the Orchestrator's route.
    struct S {
        let world: World
        let sandbox = FakeSandbox()
        let fallback = FakeCheckRunner()
        let company: Company
        let eng: Agent, eng2: Agent
        var store: Store { world.store }
        var root: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: true) }
        var git: GitWorkspace { store.gitWorkspace(root: root, companyId: company.id) }

        init(store: Store? = nil, profile: PermissionProfile? = nil) throws {
            let store = try store ?? Store.inMemory()
            let runner = SandboxedCheckRunner(sandbox: sandbox, route: Orchestrator.checkRoute(store: store), fallback: fallback)
            world = try World(store: store, checkRunner: runner)
            var c = try world.company("Acme")
            if let profile {
                try store.updateSandbox(companyId: c.id, SandboxPatch(profile: profile), userHome: try tempDir())
                c = try #require(try store.company(id: c.id))
            }
            company = c
            // The engineer reports to a manager, who reviews (3a Task 9a).
            let mgr = try world.hire(company, "mgr", role: "manager")
            eng = try store.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: mgr.id)
            eng2 = try store.hire(companyId: c.id, name: "eng-2", role: "engineer", model: "sonnet", managerId: mgr.id)
        }

        func tools(_ a: Agent) -> CompanyTools { CompanyTools(store: store, companyId: company.id, agentId: a.id) }

        func write(_ path: String, _ text: String, in dir: URL) throws {
            let url = dir.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func commitMain(_ files: [String: String]) throws {
            for (path, text) in files { try write(path, text, in: root) }
            try GitFixture.plainGit(["add", "-A"], in: root)
            try GitFixture.plainGit(["commit", "-m", "base"], in: root)
            try store.recordMainCommit(companyId: company.id, commit: try GitFixture.plainGit(["rev-parse", "refs/heads/main"], in: root))
        }

        /// An item with `command` as its check, claimed by `eng`, changed and submitted.
        @discardableResult
        func submitted(command: String = "true", by agent: Agent? = nil) throws -> WorkItem {
            let holder = agent ?? eng
            let n = (try store.workItems(companyId: company.id)).count + 1
            let item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Do it \(n)", checkSpec: CheckSpec(command: command, paths: ["src/p\(n)"]), status: .ready),
                now: world.clock.now)
            _ = try tools(holder).call(name: "claim_lease", arguments: ["key": .string(item.key)])
            try write("src/work\(n).txt", "work", in: git.worktreePath(key: item.key))
            _ = try tools(holder).call(name: "submit_for_review", arguments: ["key": .string(item.key), "summary": .string("did it")])
            return item
        }

        func latest(_ i: WorkItem) throws -> VerificationRun { try #require(try store.latestVerification(itemId: i.id)) }

        func cycle() async throws {
            await world.orchestrator.tick()
            try await world.orchestrator.waitUntilIdle(timeout: .seconds(300))
        }
    }

    static func resolved(_ url: URL) -> URL { url.resolvedForSandbox }

    // MARK: Tests

    @Test func checksUseCompanyPolicy() async throws {
        let s = try S()
        try s.store.updateSandbox(companyId: s.company.id, SandboxPatch(allowedDomains: ["*.stripe.com"]), userHome: try tempDir())
        let item = try s.submitted()
        try await s.cycle()
        let run = try s.latest(item)
        #expect(run.status == .passed, "\(run.outputTail ?? "")"); #expect(run.outputTail == "sandboxed pass")
        #expect(s.fallback.calls.isEmpty)
        let call = try #require(s.sandbox.calls.first)
        let checkout = s.git.checkoutPath(runId: run.id)
        #expect(Self.resolved(call.cwd) == Self.resolved(checkout))
        // A check writes only its own checkout — no writable shared cache at all (round 2).
        #expect(call.policy.writable == [Self.resolved(checkout)])
        #expect(call.policy.readable == [Self.resolved(s.root)])
        let company = try #require(try s.store.company(id: s.company.id))
        let domains = CompanyNetwork.scope(company: company, grantDomains: [], grantWebDomains: []).allowedDomains
        #expect(call.policy.network == .outbound(allow: domains)); #expect(domains.contains("*.stripe.com"))
        #expect(call.policy.toolchain)
        #expect(call.environment["BRAHMA_AGENT_ID"] == s.eng.id); #expect(call.timeout == .seconds(600))
        // Nothing of the data home is in the policy but this run's own checkout, and no workspace cache either.
        for entry in call.policy.writable + call.policy.readable {
            #expect(!SandboxPath.isInside(entry.path, Self.resolved(s.world.paths.home).path))
        }
        #expect(!call.policy.writable.contains { $0.path.contains("/.brahma/cache") })
    }

    @Test func fullProfileUsesFallback() async throws {
        let s = try S(profile: .full)
        let item = try s.submitted()
        try await s.cycle()
        #expect(try s.latest(item).status == .passed)
        #expect(s.sandbox.calls.isEmpty); #expect(s.fallback.calls.count == 1)
        #expect(s.fallback.calls.first?.workingDirectory.path == s.git.checkoutPath(runId: try s.latest(item).id).path)
    }

    /// The more restrictive reading: a Full company whose holder's role is sandboxed still runs that holder's checks sandboxed.
    @Test func fullCompanyWithSandboxedHolderRoleStaysSandboxed() async throws {
        let s = try S(profile: .full)
        try s.store.updateSandbox(companyId: s.company.id, SandboxPatch(roleProfiles: ["engineer": .sandboxed]), userHome: try tempDir())
        _ = try s.submitted()
        try await s.cycle()
        #expect(s.sandbox.calls.count == 1); #expect(s.fallback.calls.isEmpty)
        // And a sandboxed company is never relaxed by a Full role.
        let t = try S()
        try t.store.updateSandbox(companyId: t.company.id, SandboxPatch(roleProfiles: ["engineer": .full]), userHome: try tempDir())
        _ = try t.submitted()
        try await t.cycle()
        #expect(t.sandbox.calls.count == 1); #expect(t.fallback.calls.isEmpty)
    }

    // MARK: Straggler sweep (B-I4, fix round 3)

    private static func entry(_ pid: pid_t, start: Double = 2e9) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: 1, pgid: pid, uid: getuid(), start: start, isZombie: false)
    }

    /// N1: the sweep fails closed. An empty process table, or one without this process, cannot rule anything out; a live
    /// process whose sandbox cannot be classified is a survivor. Each makes the run inconclusive.
    @Test func sweepFailsClosedOnUnreadableState() {
        let probe = SandboxProbe(machMarker: "dev.brahma.run.test")
        let empty = SandboxSweep.run(probe: probe, since: 0, rounds: 1, snapshot: { [] }, classify: { _ in .notMine })
        #expect(empty.tableUnreadable && empty.inconclusive)
        let withoutMe = SandboxSweep.run(probe: probe, since: 0, rounds: 1, snapshot: { [Self.entry(99_999)] }, classify: { _ in .notMine })
        #expect(withoutMe.tableUnreadable && withoutMe.inconclusive)
        let table = [Self.entry(getpid(), start: 0), Self.entry(99_998)]
        let unknown = SandboxSweep.run(probe: probe, since: 0, rounds: 1, snapshot: { table }, classify: { _ in .unknown },
                                       alive: { _ in true })
        #expect(unknown.survivors == [99_998] && unknown.inconclusive)
        // An unclassifiable process that has already exited is not a survivor.
        let gone = SandboxSweep.run(probe: probe, since: 0, rounds: 1, snapshot: { table }, classify: { _ in .unknown },
                                    alive: { _ in false })
        #expect(gone.clean)
        // Nothing of ours, everything readable: clean.
        let clean = SandboxSweep.run(probe: probe, since: 0, rounds: 1, snapshot: { table }, classify: { _ in .notMine })
        #expect(clean.clean && !clean.inconclusive)
        // The real classifier: an unsandboxed process (this one's parent shell, say) is never ours.
        #expect(probe.classify(getppid()) == .notMine)
    }

    /// The sweep's default `alive` tells a pid that is gone from a process-table read that failed: a `sysctl` error keeps an
    /// unclassifiable process as a survivor (fail closed); only a pid that is really gone, reused or a zombie drops out.
    @Test func aliveFailsClosedOnALookupError() {
        let p = Self.entry(99_997, start: 5)
        #expect(SandboxSweep.isAlive(p, lookup: { _ in .unreadable }))
        #expect(!SandboxSweep.isAlive(p, lookup: { _ in .absent }))
        #expect(SandboxSweep.isAlive(p, lookup: { _ in .found(p) }))
        var reused = p; reused.start = 6
        #expect(!SandboxSweep.isAlive(p, lookup: { _ in .found(reused) }))
        var zombie = p; zombie.isZombie = true
        #expect(!SandboxSweep.isAlive(p, lookup: { _ in .found(zombie) }))
        // The real lookup: this process is found; a pid no process can have is absent, not an error.
        if case .found(let me) = ProcessTable.lookup(getpid()) { #expect(me.pid == getpid()) } else { Issue.record("this process was not found") }
        #expect(ProcessTable.lookup(-5) == .absent)
        #expect(ProcessTable.lookup(pid_t.max) == .absent)
    }

    /// N1/N2: what a run left behind becomes an owner-visible activity line on its company: killed stragglers are noted (the
    /// outcome stands); unaccounted ones say the run was recorded inconclusive.
    @Test func stragglersAreReportedAsActivity() async throws {
        let s = try S()
        let item = try s.submitted()
        let run = try s.latest(item)
        let checkout = s.git.checkoutPath(runId: run.id)
        Orchestrator.reportStragglers(StragglerReport(checkout: checkout, result: SweepResult(killed: [4242])), store: s.store)
        Orchestrator.reportStragglers(StragglerReport(checkout: checkout, result: SweepResult(survivors: [4343])), store: s.store)
        let lines = try await s.store.writer.read { try ActivityEvent.filter(Column("companyId") == s.company.id).fetchAll($0) }.map(\.text)
        #expect(lines.contains { $0.contains(item.key) && $0.contains("Brahma killed them") }, "\(lines)")
        #expect(lines.contains { $0.contains(item.key) && $0.contains("recorded inconclusive") }, "\(lines)")
    }

    @Test func outsideWorkspaceRefused() async throws {
        let s = try S()
        let route = Orchestrator.checkRoute(store: s.store)
        let elsewhere = try tempDir()
        guard case .refused = route(elsewhere.path) else { Issue.record("a random directory was routed"); return }
        guard case .refused = route(s.root.path) else { Issue.record("the workspace itself was routed"); return }
        // A place shaped like a checkout, for a run that is not running there, is refused too.
        guard case .refused = route(s.git.checkoutPath(runId: "no-such-run").path) else { Issue.record("an unknown run was routed"); return }
        let item = try s.submitted()
        let queued = try s.latest(item)
        guard case .refused = route(s.git.checkoutPath(runId: queued.id).path) else { Issue.record("a queued run was routed"); return }

        let out = try tempDir().appending(path: "out.log")
        let runner = SandboxedCheckRunner(sandbox: s.sandbox, route: route, fallback: s.fallback)
        let outcome = await runner.run(command: "true", workingDirectory: elsewhere, timeout: 5, outputURL: out, environment: [:])
        // The outcome carries the route's precise reason (B-I2c), written to the output file; the generic tail is the fallback.
        #expect(outcome.exitCode == nil && !outcome.timedOut)
        #expect(outcome.tail.contains("no engine record of a check running in"), "\(outcome.tail)")
        #expect(SandboxedCheckRunner.refusedTail == "check directory is outside every company workspace")
        #expect((try? String(contentsOf: out, encoding: .utf8)) == outcome.tail)
        // An empty reason falls back to the generic tail.
        let empty = SandboxedCheckRunner(sandbox: s.sandbox, route: { _ in .refused("") }, fallback: s.fallback)
        let o2 = await empty.run(command: "true", workingDirectory: elsewhere, timeout: 5, outputURL: out, environment: [:])
        #expect(o2.tail == SandboxedCheckRunner.refusedTail)
        #expect(s.sandbox.calls.isEmpty); #expect(s.fallback.calls.isEmpty)
    }

    /// Round 2: a check gets no writable shared cache at all, so its policy names only its own checkout — there is no
    /// `.brahma/cache/shared` for a check to break, writable or otherwise.
    @Test func checkPolicyHasNoWorkspaceCache() async throws {
        let s = try S()
        let item = try s.submitted()
        let run = try s.latest(item)
        let checkout = s.git.checkoutPath(runId: run.id)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try await s.store.writer.write { db in
            try db.execute(sql: "UPDATE verificationRun SET status = 'running', workingDirectory = ? WHERE id = ?",
                           arguments: [checkout.path, run.id])
        }
        guard case .sandboxed(let policy) = Orchestrator.checkRoute(store: s.store)(checkout.path) else {
            Issue.record("the run was not routed to the sandbox"); return
        }
        #expect(policy.writable == [Self.resolved(checkout)])
        #expect(!policy.writable.contains { $0.path.contains("/.brahma/cache") })
        #expect(policy.readable == [s.root.resolvedForSandbox])
    }

    @Test func unavailableRunnerFailsClosed() async throws {
        let dir = try tempDir().resolvedForSandbox
        let policy = SandboxPolicy(writable: [dir], readable: [], network: .none, toolchain: false)
        let fallback = FakeCheckRunner()
        let runner = SandboxedCheckRunner(sandbox: UnavailableSandboxRunner(), route: { _ in .sandboxed(policy) }, fallback: fallback)
        let out = dir.appending(path: "out.log")
        let outcome = await runner.run(command: "true", workingDirectory: dir, timeout: 5, outputURL: out, environment: [:])
        #expect(outcome == CheckOutcome(exitCode: nil, timedOut: false, tail: "sandbox unavailable on this platform"))
        #expect(fallback.calls.isEmpty, "never falls back to running unsandboxed")
        #expect(throws: SandboxError.unavailable) {
            _ = try UnavailableSandboxRunner().spawn(command: "true", cwd: dir, environment: [:], logURL: out, policy: policy)
        }
        // The platform default is Seatbelt where sandbox-exec exists, else the unavailable runner.
        let platform = SandboxRunners.platformDefault(baseline: { SandboxBaseline(userHome: dir, protected: [], darwinUserTemp: nil,
                                                                                   darwinUserCache: nil) }, proxies: EgressProxyPool())
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") { #expect(platform is SeatbeltRunner) }
        else { #expect(platform is UnavailableSandboxRunner) }
        // A baseline that could not be built refuses to run.
        let broken = SeatbeltRunner(baseline: { var b = SandboxBaseline(userHome: dir, protected: [], darwinUserTemp: nil, darwinUserCache: nil)
            b.problem = "no workspaces"; return b }, proxies: EgressProxyPool())
        let refused = await broken.run(command: "true", cwd: dir, environment: [:], timeout: .seconds(5), outputURL: out, policy: policy)
        #expect(refused.exitCode == nil); #expect(refused.tail.contains("no workspaces"))
    }

    /// 3a's places: the sandboxed run's cwd is the engine's checkout (`<home>/run/checkouts/<runId>`, 3a's built path; the
    /// plan's `CheckPaths.runWorktree` no longer exists) and the snapshot is read from `CheckPaths.snapshotDir` under
    /// `<ws>/.brahma/checks`; a tampered snapshot is still refused by 3a's guard before the sandbox runs.
    @Test func checkRunsUseWorkspacePaths() async throws {
        let s = try S()
        try s.commitMain(["scripts/check.sh": "echo base-check\n"])
        let item = try s.submitted(command: "sh scripts/check.sh")
        let snap = try #require(try s.store.checkSnapshot(itemId: item.id, revision: 0))
        #expect(snap.dir == CheckPaths(workspace: s.root).snapshotDir(key: item.key, revision: 0).path)
        #expect(snap.dir.hasPrefix(s.root.appending(path: ".brahma/checks").path + "/"))
        try await s.cycle()
        let run = try s.latest(item)
        #expect(run.status == .passed, "\(run.outputTail ?? "")")
        let call = try #require(s.sandbox.calls.first)
        #expect(Self.resolved(call.cwd) == Self.resolved(s.git.checkoutPath(runId: run.id)))
        #expect(run.workingDirectory == s.git.checkoutPath(runId: run.id).path)

        // The saved baseline is rewritten behind the engine's back: refused before anything runs.
        let second = try s.submitted(command: "sh scripts/check.sh", by: s.eng2)
        try "exit 0\n".write(to: CheckPaths(workspace: s.root).snapshotDir(key: second.key, revision: 0).appending(path: "scripts/check.sh"),
                             atomically: true, encoding: .utf8)
        try await s.cycle()
        let refused = try s.latest(second)
        #expect(refused.status == .error); #expect(refused.outputTail == "check snapshot was modified outside the engine")
        #expect(s.sandbox.calls.count == 1, "the sandbox never ran the tampered check")
    }

    /// Carry-over: a merge-purpose check runs on the engine's `.git`-free export (`<home>/run/exports/<runId>`, 3a's built
    /// path); its policy names only that export and the shared cache, so the engine's merge repository (`<home>/run/merge/
    /// <companyId>.git`) is neither writable nor readable (stricter than the read-only the carry-over asks for).
    @Test func mergeCheckCannotTouchTheMergeRepo() async throws {
        let home = try tempDir().resolvedForSandbox.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try Store(path: home.appending(path: "brahma.sqlite").path)
        let s = try S(store: store)
        let item = try s.submitted()
        let queued = try s.latest(item)
        // Stand in for the merge step: the run is a merge check, running on its export.
        let export = s.git.exportPath(runId: queued.id)
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try "exported\n".write(to: export.appending(path: "f.txt"), atomically: true, encoding: .utf8)
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE verificationRun SET purpose = 'merge', status = 'running', workingDirectory = ? WHERE id = ?",
                           arguments: [export.path, queued.id])
        }
        let mergeRepo = URL(fileURLWithPath: s.git.mergeRepositoryPath.path)
        try FileManager.default.createDirectory(at: mergeRepo.appending(path: "objects"), withIntermediateDirectories: true)
        try "[core]\n\tbare = true\n".write(to: mergeRepo.appending(path: "config"), atomically: true, encoding: .utf8)
        #expect(SandboxPath.isInside(mergeRepo.resolvedForSandbox.path, home.path))

        guard case .sandboxed(let policy) = Orchestrator.checkRoute(store: store)(export.path) else {
            Issue.record("the merge check was not routed to the sandbox"); return
        }
        // A merge check writes only its export: no shared cache (B-I3), so a submission check cannot have left config there
        // that runs during the merge gate.
        #expect(policy.writable == [Self.resolved(export)])
        #expect(policy.readable == [Self.resolved(s.root)])
        for entry in policy.writable + policy.readable {
            #expect(!SandboxPath.overlaps(entry.path, mergeRepo.resolvedForSandbox.path), "\(entry.path) reaches the merge repo")
        }
        // Its submit-purpose twin (same id, wrong place) is refused: the place must match the run's purpose.
        guard case .refused = Orchestrator.checkRoute(store: store)(s.git.checkoutPath(runId: queued.id).path) else {
            Issue.record("a merge run was routed through a checkout path"); return
        }

        // For real, where Seatbelt exists: the export is writable, the merge repository is out of reach.
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
        var baseline = SandboxBaseline.current(paths: BrahmaPaths(home: home, workspaces: s.world.paths.workspaces),
                                               otherWorkspaces: [], backupTargets: [])
        baseline.companyWorkspaces = [Self.resolved(s.root)]
        let fixed = baseline
        let seatbelt = SeatbeltRunner(baseline: { fixed }, proxies: EgressProxyPool())
        let out = try tempDir().appending(path: "out.log")
        let env = ["PATH": "/usr/bin:/bin"]
        let repo = mergeRepo.resolvedForSandbox.path
        let ok = await seatbelt.run(command: "touch built && cat f.txt", cwd: export, environment: env, timeout: .seconds(30),
                                    outputURL: out, policy: SandboxPolicy(writable: policy.writable, readable: policy.readable,
                                                                          network: .none, toolchain: false))
        #expect(ok.exitCode == 0, "\(ok.tail)"); #expect(ok.tail.contains("exported"))
        for command in ["cat '\(repo)/config'", "echo x >> '\(repo)/config'", "touch '\(repo)/objects/planted'", "ls '\(repo)'"] {
            let outcome = await seatbelt.run(command: command, cwd: export, environment: env, timeout: .seconds(30), outputURL: out,
                                             policy: SandboxPolicy(writable: policy.writable, readable: policy.readable, network: .none,
                                                                   toolchain: false))
            #expect(outcome.exitCode != 0, "\(command) reached the merge repository")
        }
        #expect(try String(contentsOf: mergeRepo.appending(path: "config"), encoding: .utf8) == "[core]\n\tbare = true\n")
        #expect(!FileManager.default.fileExists(atPath: mergeRepo.appending(path: "objects/planted").path))
    }

    @Test func ensureRepoExcludesTheSandboxTemp() throws {
        let s = try S()
        let exclude = try String(contentsOf: s.root.appending(path: ".git/info/exclude"), encoding: .utf8)
        let lines = exclude.split(separator: "\n").map(String.init)
        #expect(lines.contains(".brahma/")); #expect(lines.contains(".brahma-tmp/"))
        // Idempotent.
        try s.git.ensureRepo()
        let again = try String(contentsOf: s.root.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(again.split(separator: "\n").filter { $0 == ".brahma-tmp/" }.count == 1)
        // A link planted at the exclude file is replaced, never read through.
        let secret = try tempDir().appending(path: "secret.txt")
        try "do-not-copy".write(to: secret, atomically: true, encoding: .utf8)
        let file = s.root.appending(path: ".git/info/exclude")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)
        try s.git.ensureRepo()
        let rewritten = try String(contentsOf: file, encoding: .utf8)
        #expect(!rewritten.contains("do-not-copy")); #expect(rewritten.contains(".brahma-tmp/"))
        #expect(try String(contentsOf: secret, encoding: .utf8) == "do-not-copy")
    }

    @Test func orchestratorDefaultsToTheSandboxedRunner() async throws {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let o = Orchestrator(store: try Store.inMemory(), runner: FakeTurnRunner(), paths: paths, mcpExecutable: "/x/brahma")
        let runner = await o.checkRunner
        #expect(runner is SandboxedCheckRunner)
    }
}

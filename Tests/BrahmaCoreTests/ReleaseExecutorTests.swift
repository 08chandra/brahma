import Foundation
import Testing
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// The release executor (Plan L Task 7): an owner-approved deploy carried out exactly once — release smoke at the commit,
/// integrity re-render, backup refs, a sandboxed token-free build in a fresh export, a staged upload, the engine-installed
/// CLI, the token only in the deploy step's environment, a smoke of the URL, the record. A file-backed store (exports and
/// releases under its data home), a real git workspace, FakeSandbox (real processes, recorded calls), FakeHostingAdapter
/// (a fake CLI installed by a fake npm, both FakeTools scripts), MemoryVault and a scripted HTTP probe. Nothing contacts a
/// provider; nothing races the clock (runs are awaited; the one running step a test stops is waited for by event).
@Suite(.scratch) struct ReleaseExecutorTests {
    static let token = "cf-live-token-0123456789abcdef"
    static let site = URL(string: "https://lumen.fake.test")!
    static let build = "mkdir -p dist && echo '<title>Lumen</title>' > dist/index.html"

    struct Fx {
        let w: World
        let company: Company
        let devops: Agent
        let f: GitFixture
        let sandbox: FakeSandbox
        let unsandboxed: FakeSandbox
        let smokeSandbox: FakeSandbox
        let http: FakeHTTPProbe
        let vault: MemoryVault
        let root: URL
        let hostRoot: URL
        let fake: FakeHostingAdapter

        init(build: String? = ReleaseExecutorTests.build, smoke: String = "true", profile: PermissionProfile = .workspace,
             deploySandbox: (any SandboxedRunner)? = nil,
             http: FakeHTTPProbe = FakeHTTPProbe([FakeHTTPProbe.ok(200, body: "<html><title>Lumen</title></html>")]),
             files: [String: String] = ["README.md": "Lumen\n"], configure: (inout FakeHostingAdapter) -> Void = { _ in }) throws {
            root = try tempDir()
            let data = root.appending(path: "data", directoryHint: .isDirectory)
            hostRoot = root.appending(path: "host", directoryHint: .isDirectory)
            for dir in [data, hostRoot] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            let store = try Store(path: data.appending(path: "brahma.sqlite").path)
            var fake = FakeHostingAdapter(tokenSecret: "CLOUDFLARE_API_TOKEN", server: ReleaseExecutorTests.site, hostRoot: hostRoot)
            configure(&fake)
            self.fake = fake
            sandbox = FakeSandbox(); unsandboxed = FakeSandbox(); smokeSandbox = FakeSandbox()
            self.http = http
            vault = MemoryVault()
            var deps = ReleaseDependencies.fake(sandbox: sandbox, unsandboxed: unsandboxed, http: http, adapter: fake)
            if let deploySandbox { deps.sandbox = deploySandbox }
            w = try World(store: store, vault: vault, smokeSandbox: smokeSandbox, releaseDeps: deps)
            company = try w.company("Lumen", profile: profile)
            devops = try w.hire(company, "devops-1", role: "devops")
            f = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            try merge(files)
            let now = w.clock.now
            try store.setHosting(companyId: company.id, by: .owner, accountId: "acct-1", now: now)
            try store.setDeployConfig(companyId: company.id, by: devops.id, build: build, outputDir: "dist", smoke: [],
                                      expectText: "Lumen", now: now)
            try store.setSmokeCheck(companyId: company.id, by: devops.id, check: CheckSpec(command: smoke), now: now)
            try store.setSecret(companyId: company.id, name: "CLOUDFLARE_API_TOKEN", value: ReleaseExecutorTests.token, isTest: false,
                                vault: vault, now: now)
            try store.reloadRedactorIfNeeded(vault: vault)
            try passMain()
        }

        var store: Store { w.store }
        var executor: ReleaseExecutor { w.orchestrator.releaseExecutor }
        var ws: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: true) }
        func layout() throws -> ReleaseLayout { try store.releaseLayout(companyId: company.id) }
        func releaseDir(_ n: Int = 1) throws -> URL { try layout().releaseDir(n) }
        func upload(_ n: Int = 1) throws -> URL { try releaseDir(n).appending(path: "upload", directoryHint: .isDirectory) }
        func home(_ n: Int = 1) throws -> URL { try releaseDir(n).appending(path: "home", directoryHint: .isDirectory) }
        func deployTools() throws -> URL { try layout().deployTools(cli: fake.cli) }
        func export(_ r: Release) -> URL {
            EngineExport.directory(store: store, company: company, runId: ReleaseExecutor.exportRunId(r))
        }

        /// Lands `files` on main the engine's way (committed, then accepted). Returns the new main.
        @discardableResult
        func merge(_ files: [String: String]) throws -> String {
            for (path, text) in files { try f.write(path, text) }
            try f.git(["add", "-A"])
            try f.git(["commit", "-q", "-m", "change"])
            return try store.acceptMainCommit(companyId: company.id).head
        }

        /// A passed `merge` smoke run at the engine-accepted main (what proposing needs).
        func passMain() throws {
            let main = try #require(try store.company(id: company.id)?.mainCommit)
            let t = w.clock.now
            try store.writer.write { db in
                try MainSmokeRun(companyId: company.id, commit: main, status: .passed, exitCode: 0, reason: .merge, createdAt: t,
                                 startedAt: t, finishedAt: t).insert(db)
            }
        }

        func propose(_ version: String = "0.1.0") throws -> (Release, Ask) {
            let lookup: HostingAdapters.Lookup = { [fake] _ in fake }
            return try store.proposeDeploy(companyId: company.id, by: devops.id, version: version, notes: nil, now: w.clock.now,
                                           vault: vault, adapters: lookup, npmPresent: true)
        }

        @discardableResult
        func proposeAndApprove(_ version: String = "0.1.0") throws -> Release {
            let (r, ask) = try propose(version)
            _ = try store.ownerDecide(askId: ask.id, approve: true, now: w.clock.now)
            let approved = try reload(r)
            #expect(approved.status == .approved)
            return approved
        }

        func reload(_ r: Release) throws -> Release { try #require(try store.release(companyId: company.id, ref: r.ref)) }
        func advance() async { await executor.advance(now: w.clock.now) }

        /// Calls of `sandbox` whose working directory is `dir`.
        func calls(in dir: URL, of runner: FakeSandbox? = nil) -> [FakeSandbox.Call] {
            (runner ?? sandbox).calls.filter { Self.same($0.cwd, dir) }
        }

        func deploySteps() throws -> [FakeSandbox.Call] {
            try calls(in: upload()).filter { $0.command.contains("/node_modules/.bin/fake deploy ") }
        }

        static func same(_ a: URL, _ b: URL) -> Bool { SandboxPath.resolve(a.path) == SandboxPath.resolve(b.path) }
        static func real(_ url: URL) -> URL { URL(fileURLWithPath: SandboxPath.resolve(url.path), isDirectory: true) }

        func notices() throws -> [OwnerNotice] {
            try store.writer.read { try OwnerNotice.filter(Column("companyId") == company.id).fetchAll($0) }
        }

        func activity() throws -> [String] {
            try store.writer.read { try ActivityEvent.filter(Column("companyId") == company.id).fetchAll($0) }.map(\.text)
        }

        func bugs() throws -> [WorkItem] {
            try store.writer.read { try WorkItem.filter(Column("companyId") == company.id).fetchAll($0) }
                .filter { $0.type == WorkItemType("bug") }
        }

        func releaseSmokes() throws -> [MainSmokeRun] {
            try store.mainSmokeRuns(companyId: company.id).filter { $0.reason == .release }
        }

        func ref(_ name: String) throws -> String? {
            let out = try f.git(["rev-parse", "--verify", "--quiet", name], allowFailure: true)
            return out.isEmpty ? nil : out
        }

        /// The fake CLI installed already (the tools step then has nothing to do): a hard link of the shared script.
        func preinstallTools() throws {
            try FakeTools.install(at: deployTools().appending(path: "node_modules/.bin/fake"), FakeHostingAdapter.cliScript)
        }
    }

    // MARK: The path

    @Test func approvedReleaseDeploysAndRecords() async throws {
        let fx = try Fx()
        let approved = try fx.proposeAndApprove()
        // Through the engine's tick (a tracked release task, its git in Blocking bodies: the idle wait would throw otherwise).
        try await fx.w.cycle()
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        #expect(r.startedAt != nil); #expect(r.deployedAt != nil); #expect(r.finishedAt != nil)
        #expect(r.deployURL == "https://fake-r-1.local")
        #expect(r.productionURL == Self.site.absoluteString)
        #expect(r.smokeStatus == "passed")
        #expect(r.smokeResults.count == 1); #expect(r.smokeResults.first?.ok == true)
        #expect(r.backupRef == "refs/brahma/main-backup")
        // Exactly one release smoke, at the commit, passed.
        let smokes = try fx.releaseSmokes()
        #expect(smokes.count == 1)
        #expect(smokes.first?.commit == r.commit); #expect(smokes.first?.status == .passed); #expect(smokes.first?.releaseId == r.id)
        // The backup ref and the release's own ref (PR-29) name the commit; no git tag is written.
        #expect(try fx.ref("refs/brahma/main-backup") == r.commit)
        #expect(try fx.ref("refs/brahma/releases/0.1.0") == r.commit)
        #expect(try fx.f.git(["tag", "--list"]).isEmpty)
        // What went live is the build's output, uploaded from the staged folder.
        let served = try String(contentsOf: fx.hostRoot.appending(path: "R-1/dist/index.html"), encoding: .utf8)
        #expect(served.contains("<title>Lumen</title>"))
        #expect(fx.http.requests.map(\.url.absoluteString) == ["https://lumen.fake.test/"])
        // The owner hears it; the activity feed says it.
        #expect(try fx.notices().contains { $0.title == "Lumen is live" && $0.body == "https://lumen.fake.test (release 0.1.0)" })
        #expect(try fx.activity().contains("Release 0.1.0 is live at https://lumen.fake.test"))
        // The export is gone, the release's HOME too; the upload stays (a later rollback deploys it again).
        #expect(!FileManager.default.fileExists(atPath: fx.export(r).path))
        #expect(!FileManager.default.fileExists(atPath: try fx.home().path))
        #expect(FileManager.default.fileExists(atPath: try fx.upload().appending(path: "dist/index.html").path))
        // The redacted logs are in the workspace for the owner and agents; the raw step files are gone.
        let wsLog = EngineLayout(workspace: fx.ws).releaseDir(1).appending(path: "deploy.log")
        let log = try String(contentsOf: wsLog, encoding: .utf8)
        #expect(log.contains("https://fake-r-1.local"))
        #expect(log.hasPrefix("$ " + ShellQuote.joinArgv(r.plan.steps[0].argv, rawRefs: [])))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.releaseDir().path).filter { $0.hasPrefix("step-") }.isEmpty)
        // Nothing else is claimable.
        #expect(try fx.store.claimRelease(companyId: fx.company.id, now: fx.w.clock.now) == nil)
    }

    @Test func approvalExecutesOnce() async throws {
        let fx = try Fx()
        let approved = try fx.proposeAndApprove()
        async let a: Void = fx.executor.advance(now: fx.w.clock.now)
        async let b: Void = fx.executor.advance(now: fx.w.clock.now)
        _ = await (a, b)
        await fx.advance()            // and again: nothing is left to carry out
        #expect(try fx.reload(approved).status == .deployed)
        #expect(try fx.deploySteps().count == 1)
        #expect(try fx.releaseSmokes().count == 1)
        #expect(fx.calls(in: fx.export(approved)).count == 1)
        // The claim is conditional on `approved`: a second claim of the same release finds nothing.
        #expect(try fx.store.claimRelease(companyId: fx.company.id, now: fx.w.clock.now) == nil)
    }

    @Test func tokenNeverInBuildEnvironment() async throws {
        let fx = try Fx()
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        let tools = try fx.deployTools()
        let build = try #require(fx.calls(in: fx.export(r)).first)
        let install = try #require(fx.calls(in: tools).first)
        let deploy = try #require(try fx.deploySteps().first)
        // The build and the tools install: no secret at all, BRAHMA_AGENT_ID=release.
        for call in [build, install] {
            #expect(call.environment["CLOUDFLARE_API_TOKEN"] == nil)
            #expect(!call.environment.values.contains { $0.contains(Self.token) })
            #expect(call.environment["BRAHMA_AGENT_ID"] == "release")
            #expect(call.environment["BRAHMA_DEV"] == nil)
        }
        #expect(build.command == Self.build)
        #expect(build.kind == .spawn)
        // The deploy step: the token in its environment only, never in a command (PR-11).
        #expect(deploy.environment["CLOUDFLARE_API_TOKEN"] == Self.token)
        #expect(deploy.environment["BRAHMA_AGENT_ID"] == "release")
        #expect(deploy.environment["FAKE_ACCOUNT"] == "acct-1")
        for call in fx.sandbox.calls + fx.unsandboxed.calls + fx.smokeSandbox.calls { #expect(!call.command.contains(Self.token)) }
        // The install: exactly the pinned package into the engine-only tools folder (PR-8: no npx), writing only there.
        #expect(install.command == "npm install --prefix \(ShellQuote.quote(tools.path)) --no-audit --no-fund fake@1")
        #expect(install.policy.writable == [Fx.real(tools)])
        #expect(install.policy.network == .outbound(allow: fx.fake.toolNetwork))
        #expect(install.policy.toolchain)
        // The build writes and reads only its export; the company's registries; the toolchain (PR-5, PR-19).
        #expect(build.policy.writable == [Fx.real(fx.export(r))]); #expect(build.policy.readable == [Fx.real(fx.export(r))])
        #expect(build.policy.toolchain)
        // The deploy: writes its HOME and upload, reads the upload and the tools, reaches only the plan's hosts.
        #expect(deploy.policy.writable == [Fx.real(try fx.home()), Fx.real(try fx.upload())])
        #expect(deploy.policy.readable == [Fx.real(try fx.upload()), Fx.real(tools)])
        #expect(deploy.policy.network == .outbound(allow: r.plan.network))
        // A second release (main unchanged, still green) finds the tools installed: no second install.
        let second = try fx.proposeAndApprove("0.2.0")
        await fx.advance()
        #expect(try fx.reload(second).status == .deployed)
        #expect(fx.calls(in: tools).count == 1)
    }

    @Test func deployToolsNeverWritableByBuilds() async throws {
        let fx = try Fx()
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        let guarded = [try fx.deployTools(), try fx.upload(), try fx.home()].map { SandboxPath.resolve($0.path) }
        var writable: [URL] = []
        // Every build the executor ran, every main smoke.
        writable += fx.calls(in: fx.export(r)).flatMap(\.policy.writable)
        writable += fx.smokeSandbox.calls.flatMap(\.policy.writable)
        #expect(!writable.isEmpty)
        // A preview server's policy (its own export), and 5-lite's check places (a submission's checkout, a merge's export).
        let git = fx.store.gitWorkspace(root: fx.ws, companyId: fx.company.id)
        writable += PreviewPolicy.server(EngineLayout(workspace: fx.ws), run: git.exportPath(runId: "prev-x"), company: fx.company,
                                         port: 47100).writable
        writable += [git.checkoutPath(runId: "chk-1"), git.exportPath(runId: "chk-1")]
        // An item turn's scope.
        let eng = try fx.w.hire(fx.company, "eng-1", role: "engineer")
        let item = try fx.store.createWorkItem(companyId: fx.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Thing", ownerId: eng.id, status: .ready), now: fx.w.clock.now)
        let layout = SandboxLayout(paths: fx.w.paths, company: fx.company, agentHandle: "eng-1")
        try layout.ensure()
        let scope = try SandboxScope.forTurn(layout: layout, paths: fx.w.paths, otherWorkspaces: [], backupTargets: [], kind: .work,
                                             item: item, company: fx.company, grants: GrantInputs(), darwinUserTemp: nil,
                                             userHome: fx.w.userHome)
        writable += scope.writable
        for entry in writable {
            let path = SandboxPath.resolve(entry.path)
            for g in guarded { #expect(!SandboxPath.overlaps(path, g), "\(path) overlaps \(g)") }
        }
        // `.brahma/releases` is write-denied on every turn (and agents read only its redacted logs).
        let releases = SandboxPath.resolve(EngineLayout(workspace: fx.ws).releasesDir.path)
        #expect(scope.denyWrite.contains { SandboxPath.resolve($0.path) == releases })
        #expect(!scope.writable.contains { SandboxPath.overlaps(SandboxPath.resolve($0.path), releases) })
    }

    @Test func stagedUploadIgnoresRepoConfig() async throws {
        let fx = try Fx(files: ["README.md": "Lumen\n", "wrangler.toml": "name = \"evil\"\n", ".vercel/project.json": "{\"projectId\":\"evil\"}\n",
                                "node_modules/.bin/wrangler": "#!/bin/sh\necho evil\n"],
                        configure: { $0.providerConfigNames = ProviderConfigCheck.wranglerConfigs })
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        let deploy = try #require(try fx.deploySteps().first)
        #expect(Fx.same(deploy.cwd, try fx.upload()))
        // Only the output folder was staged; none of the repo's config or dependency tree.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.upload().path) == ["dist"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.hostRoot.appending(path: "R-1").path) == ["dist"])
        // argv[0] is the engine-installed CLI under the tools folder, never a repo's node_modules.
        let bin = try fx.deployTools().appending(path: "node_modules/.bin/fake").path
        #expect(deploy.command.hasPrefix(ShellQuote.quote(bin) + " deploy R-1"))
        #expect(r.plan.steps.allSatisfy { $0.argv.first == bin })
    }

    @Test func symlinkInOutputRefused() async throws {
        let fx = try Fx(build: "mkdir -p dist && echo x > dist/index.html && ln -s /nonexistent/.ssh/x dist/key")
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .failed)
        #expect(r.failedReason == "output contains a symlink: dist/key")
        #expect(try fx.deploySteps().isEmpty)
        #expect(fx.calls(in: try fx.deployTools()).isEmpty)
        #expect(try fx.bugs().map(\.title) == ["Release 0.1.0 failed: stage (output contains a symlink: dist/key)"])
        // Nothing was deployed, and the owner is told so.
        #expect(try fx.notices().contains { $0.title == "Release 0.1.0 failed" && $0.body == "Nothing was deployed: output contains a symlink: dist/key" })
        #expect(!FileManager.default.fileExists(atPath: fx.export(r).path))
    }

    @Test func envFileInOutputRefused() async throws {
        let fx = try Fx(build: "mkdir -p dist/.well-known && echo x > dist/index.html && echo SECRET=1 > dist/.env.production "
                        + "&& echo junk > dist/.DS_Store && echo contact > dist/.well-known/security.txt")
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .failed)
        #expect(r.failedReason == "output contains dist/.env.production; env files are never deployed")
        #expect(try fx.deploySteps().isEmpty)

        // The stager's rules on their own: dot entries skipped except .well-known; .env refused before that rule (PR-10).
        let base = try tempDir()
        let export = base.appending(path: "export", directoryHint: .isDirectory)
        for (path, text) in ["dist/index.html": "x", "dist/.DS_Store": "junk", "dist/.well-known/security.txt": "contact",
                             "dist/.git/config": "[core]", "dist/a/b.txt": "b", "dist/a/.cache/c": "c", "other/x.txt": "o"] {
            let url = export.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let upload = base.appending(path: "upload", directoryHint: .isDirectory)
        try UploadStager.stage(from: export, dirs: ["dist"], into: upload)
        let staged = (FileManager.default.subpaths(atPath: upload.path) ?? []).filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: upload.appending(path: $0).path, isDirectory: &isDir) && !isDir.boolValue
        }.sorted()
        #expect(staged == ["dist/.well-known/security.txt", "dist/a/b.txt", "dist/index.html"])
        #expect(try String(contentsOf: upload.appending(path: "dist/a/b.txt"), encoding: .utf8) == "b")
        // The whole export (Vercel's "."): the same rules from the root.
        let whole = base.appending(path: "whole", directoryHint: .isDirectory)
        try UploadStager.stage(from: export, dirs: ["."], into: whole)
        #expect(try FileManager.default.contentsOfDirectory(atPath: whole.path).sorted() == ["dist", "other"])

        func refusal(_ dirs: [String] = ["dist"], maxFiles: Int = UploadStager.maxFiles, maxBytes: Int = UploadStager.maxBytes) -> String? {
            let into = base.appending(path: "u-\(UUID().uuidString)", directoryHint: .isDirectory)
            do { try UploadStager.stage(from: export, dirs: dirs, into: into, maxBytes: maxBytes, maxFiles: maxFiles); return nil }
            catch let e as ReleaseError { return e.message } catch { return "\(error)" }
        }
        #expect(refusal(["site"]) == "output_dir site was not produced by the build")
        #expect(refusal(maxFiles: 2) == "output is larger than 500 MB or 20 000 files")
        #expect(refusal(maxBytes: 2) == "output is larger than 500 MB or 20 000 files")
        try Data("A=1".utf8).write(to: export.appending(path: "dist/a/.env"))
        #expect(refusal() == "output contains dist/a/.env; env files are never deployed")
        try FileManager.default.removeItem(at: export.appending(path: "dist/a/.env"))
        try FileManager.default.createSymbolicLink(atPath: export.appending(path: "linked").path, withDestinationPath: "dist")
        #expect(refusal(["linked"]) == "output contains a symlink: linked")
        try FileManager.default.linkItem(at: export.appending(path: "dist/index.html"), to: export.appending(path: "dist/twin.html"))
        #expect(refusal() == "output contains a hard link: dist/index.html")
    }

    @Test func deployOutputRedacted() async throws {
        let fx = try Fx(configure: { $0.echoToken = true })
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        let marker = "[redacted CLOUDFLARE_API_TOKEN]"
        let wsLog = try String(contentsOf: EngineLayout(workspace: fx.ws).releaseDir(1).appending(path: "deploy.log"), encoding: .utf8)
        let rawLog = try String(contentsOf: fx.releaseDir().appending(path: "deploy.log"), encoding: .utf8)
        for text in [wsLog, rawLog, r.outputTail ?? ""] {
            #expect(text.contains("using token \(marker)"), "\(text)")
            #expect(!text.contains(Self.token))
        }
        // No step file kept the raw value anywhere under the release.
        for path in FileManager.default.subpaths(atPath: try fx.releaseDir().path) ?? [] {
            let url = try fx.releaseDir().appending(path: path)
            if let data = FileManager.default.contents(atPath: url.path) { #expect(!String(decoding: data, as: UTF8.self).contains(Self.token), "\(path)") }
        }
    }

    @Test func approvalAfterRedDoesNotDeploy() async throws {
        let fx = try Fx(smoke: "exit 1")
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .failed)
        #expect(r.failedReason == "the smoke check failed at \(r.sha7) just before deploying")
        // Nothing built, staged or deployed; no backup refs moved.
        #expect(fx.sandbox.calls.isEmpty); #expect(fx.unsandboxed.calls.isEmpty)
        #expect(try fx.ref("refs/brahma/main-backup") == nil)
        let smokes = try fx.releaseSmokes()
        #expect(smokes.count == 1); #expect(smokes.first?.status == .failed); #expect(smokes.first?.commit == r.commit)
        #expect(try fx.bugs().map(\.title) == ["Release 0.1.0 failed: smoke on main (exit 1)"])
        #expect(try fx.notices().contains { $0.title == "Release 0.1.0 failed" })
    }

    @Test func deploysRecordedCommitNotNewerMain() async throws {
        let fx = try Fx(build: "mkdir -p dist && cp page.txt dist/index.html", files: ["page.txt": "v1 Lumen\n"])
        let approved = try fx.proposeAndApprove()
        let newer = try fx.merge(["page.txt": "v2 Lumen\n"])
        #expect(newer != approved.commit)
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        #expect(try String(contentsOf: fx.hostRoot.appending(path: "R-1/dist/index.html"), encoding: .utf8) == "v1 Lumen\n")
        // The release smoke ran at the release's own commit (main moved on); the refs name it too.
        #expect(try fx.releaseSmokes().map(\.commit) == [approved.commit])
        #expect(try fx.ref("refs/brahma/main-backup") == approved.commit)
        #expect(try fx.ref("refs/brahma/releases/0.1.0") == approved.commit)
    }

    @Test func commitOffMainRefused() async throws {
        let fx = try Fx()
        let approved = try fx.proposeAndApprove()
        // The engine-accepted main no longer descends from the release's commit.
        let tree = try fx.f.git(["write-tree"])
        let orphan = try fx.f.git(["commit-tree", tree, "-m", "elsewhere"])
        try await fx.store.writer.write { db in
            try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [orphan, fx.company.id])
        }
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .failed)
        #expect(r.failedReason == "R-1's commit is no longer on main")
        #expect(try fx.releaseSmokes().isEmpty)
        #expect(fx.sandbox.calls.isEmpty)
    }

    @Test func buildRewritingGitIgnored() async throws {
        let marker = try tempDir().appending(path: "marker")
        let fx = try Fx(build: "mkdir -p dist && echo ok > dist/index.html && git init -q . && git config core.fsmonitor 'touch \(marker.path)' "
                        + "&& git config core.hooksPath /nonexistent && mkdir -p .vercel && echo '{}' > .vercel/project.json")
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        // The crafted repository changed nothing the engine recorded, and none of its config ever ran.
        #expect(try fx.ref("refs/brahma/main-backup") == approved.commit)
        #expect(try fx.ref("refs/brahma/releases/0.1.0") == approved.commit)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.upload().path) == ["dist"])
        #expect(!FileManager.default.fileExists(atPath: fx.export(r).path))
    }

    @Test func tamperedPlanRefused() async throws {
        // The hosting build changed after approval: the stored build runs, and what was approved goes live.
        let fx = try Fx()
        let approved = try fx.proposeAndApprove()
        try fx.store.setDeployConfig(companyId: fx.company.id, by: fx.devops.id, build: "mkdir -p dist && echo EVIL > dist/index.html",
                                     outputDir: "dist", smoke: [], expectText: "Lumen", now: fx.w.clock.now)
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        #expect(fx.calls(in: fx.export(r)).map(\.command) == [Self.build])
        #expect(try String(contentsOf: fx.hostRoot.appending(path: "R-1/dist/index.html"), encoding: .utf8).contains("Lumen"))

        // The stored plan edited (the hash left as it was): refused before anything is built.
        let edited = try Fx()
        var row = try edited.proposeAndApprove()
        row.plan.steps[0].argv.append("--evil")
        let tampered = row
        try await edited.store.writer.write { db in try tampered.update(db) }
        await edited.advance()
        let refused = try edited.reload(row)
        #expect(refused.status == .failed)
        #expect(refused.failedReason == "the approved commands no longer match; propose again")
        #expect(edited.sandbox.calls.isEmpty)
        #expect(try edited.bugs().map(\.title)
                == ["Release 0.1.0 failed: integrity (the hosting settings or the stored plan changed since approval)"])

        // The owner changed the account after approval: the plan renders differently, fail closed (ruling 2).
        let moved = try Fx()
        let pending = try moved.proposeAndApprove()
        try moved.store.setHosting(companyId: moved.company.id, by: .owner, accountId: "acct-2", now: moved.w.clock.now)
        await moved.advance()
        #expect(try moved.reload(pending).failedReason == "the approved commands no longer match; propose again")
        #expect(moved.sandbox.calls.isEmpty)
    }

    @Test func rerenderReproducesStoredPlan() async throws {
        let fx = try Fx(files: ["README.md": "Lumen\n", "functions/api.js": "export default {}\n"])
        let (r1, _) = try fx.propose()
        let fake = fx.fake
        let again = try ReleaseExecutor.renderPlan(store: fx.store, release: r1, adapter: fake)
        #expect(again == r1.plan); #expect(again.hash == r1.commandsHash)
        // With a previous deployed release, through the real Cloudflare adapter (functions/ decided from the commit, PR-24).
        try await fx.store.writer.write { db in
            try db.execute(sql: "UPDATE release SET status = ?, deployURL = ? WHERE id = ?",
                           arguments: [ReleaseStatus.deployed.rawValue, "https://0123abcd.lumen.pages.dev", r1.id])
        }
        let cf = CloudflarePagesAdapter()
        let (r2, _) = try fx.store.proposeDeploy(companyId: fx.company.id, by: fx.devops.id, version: "0.2.0", notes: nil, now: fx.w.clock.now,
                                                 vault: fx.vault, adapters: { _ in cf }, npmPresent: true)
        #expect(r2.previousReleaseId == r1.id)
        #expect(r2.plan.stageFrom == ["dist", "functions"])
        let rendered = try ReleaseExecutor.renderPlan(store: fx.store, release: r2, adapter: cf)
        #expect(rendered == r2.plan); #expect(rendered.hash == r2.commandsHash)
        // Rendered with the release's stored build and output folder, not the hosting's current ones.
        try fx.store.setDeployConfig(companyId: fx.company.id, by: fx.devops.id, build: "make", outputDir: "public", smoke: [],
                                     expectText: nil, now: fx.w.clock.now)
        #expect(try ReleaseExecutor.renderPlan(store: fx.store, release: r2, adapter: cf) == r2.plan)
        // A different provider or project does not render the same plan.
        try fx.store.setHosting(companyId: fx.company.id, by: .owner, project: "lumen-two", now: fx.w.clock.now)
        #expect(try ReleaseExecutor.renderPlan(store: fx.store, release: r2, adapter: cf) != r2.plan)
    }

    @Test func failedDeployFilesBugAndNotifies() async throws {
        let fx = try Fx(configure: { $0.exitCode = 3 })
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .failed)
        #expect(r.failedReason == "the deploy step failed (exit 3)")
        #expect(r.outputTail?.contains("https://fake-r-1.local") == true)
        let bug = try #require(try fx.bugs().first)
        #expect(try fx.bugs().count == 1)
        #expect(bug.title == "Release 0.1.0 failed: deploy (exit 3)")
        #expect(bug.priority == 1); #expect(bug.checkSpec == nil); #expect(bug.status == .ready)
        #expect(try fx.notices().contains {
            $0.title == "Release 0.1.0 failed" && $0.body == "Run brahma release rollback Lumen R-1 or use Roll back in Releases."
        })
        // No smoke of the site after a failed deploy.
        #expect(fx.http.requests.isEmpty)
    }

    @Test func smokeFailureFailsTheRelease() async throws {
        let fx = try Fx(http: FakeHTTPProbe([FakeHTTPProbe.ok(200, body: "Nothing is here yet")]))
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .failed)
        #expect(r.deployURL == "https://fake-r-1.local")
        #expect(r.smokeStatus == "failed"); #expect(r.smokeResults.first?.ok == false)
        #expect(fx.http.requests.count == DeploySmoke.attempts)
        #expect(try fx.bugs().map(\.title) == ["Release 0.1.0 failed: smoke (GET /: the page does not contain the expected text)"])
    }

    // MARK: Rulings

    @Test func deployURLFromStdoutOnly() async throws {
        // Ruling 4: a URL the CLI prints on stderr (as a streamed build log would) is never the deploy URL.
        let fx = try Fx(configure: { $0.stderrLine = "https://fake-evil.local" })
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        #expect(r.deployURL == "https://fake-r-1.local")
        // stderr is kept in the log for the owner.
        let log = try String(contentsOf: EngineLayout(workspace: fx.ws).releaseDir(1).appending(path: "deploy.log"), encoding: .utf8)
        #expect(log.contains("https://fake-evil.local"))
    }

    @Test func providerConfigRefusedBeforeTokenStep() async throws {
        // Ruling 5: a `.git` between the deploy folder and the release root would configure the CLI; refused, named, and the
        // token never reaches a process.
        let fx = try Fx()
        let approved = try fx.proposeAndApprove()
        try FileManager.default.createDirectory(at: try fx.layout().root.appending(path: ".git"), withIntermediateDirectories: true)
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .failed)
        let reason = try #require(r.failedReason)
        #expect(reason.hasPrefix("refusing to deploy: ") && reason.hasSuffix("/.git would configure the provider CLI"), "\(reason)")
        #expect(try fx.deploySteps().isEmpty)
        for call in fx.sandbox.calls { #expect(call.environment["CLOUDFLARE_API_TOKEN"] == nil) }
        #expect(try fx.bugs().first?.title.hasPrefix("Release 0.1.0 failed: deploy (provider config)") == true)
    }

    @Test func deployURLVerifiedWithTheToken() async throws {
        // Ruling 6 (Vercel): the deploy URL is confirmed by the plan's verify step, token in env only, before it is stored.
        let fx = try Fx(configure: { $0.verify = true })
        let approved = try fx.proposeAndApprove()
        #expect(approved.plan.display.hasSuffix(ShellQuote.joinArgv([try fx.deployTools().appending(path: "node_modules/.bin/fake").path,
                                                                    "inspect", DeployPlan.deployURLPlaceholder], rawRefs: [])))
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .deployed, "\(r.failedReason ?? "")")
        let inspect = try #require(try fx.calls(in: fx.upload()).first { $0.command.contains(" inspect ") })
        #expect(inspect.command.contains("inspect https://fake-r-1.local"))
        #expect(inspect.environment["CLOUDFLARE_API_TOKEN"] == Self.token)
        #expect(!inspect.command.contains(Self.token))

        // A deployment of another project: refused, the URL never stored.
        let foreign = try Fx(configure: { $0.verify = true; $0.inspectProject = "lumen-evil" })
        let pending = try foreign.proposeAndApprove()
        await foreign.advance()
        let refused = try foreign.reload(pending)
        #expect(refused.status == .failed)
        #expect(refused.failedReason == "the deploy URL https://fake-r-1.local is not a deployment of lumen")
        #expect(refused.deployURL == nil)
        #expect(foreign.http.requests.isEmpty)

        // The Vercel adapter's own verify step and its reading of `vercel inspect`.
        let v = VercelAdapter()
        var s = HostingSettings(companyId: "c1", provider: .vercel, project: "acme", accountId: "team_1", outputDir: "dist", updatedAt: Date())
        s.build = nil
        let layout = ReleaseLayout(root: URL(fileURLWithPath: "/h/run/releases/c1"))
        let plan = try v.deployPlan(DeployInput(settings: s, commit: "abcdef1", version: "1.0.0", layout: layout, release: 1, cli: v.cli))
        let bin = layout.deployTools(cli: v.cli).path + "/node_modules/.bin/vercel"
        #expect(plan.verify == [bin, "inspect", DeployPlan.deployURLPlaceholder])
        #expect(plan.verifyArgv(url: URL(string: "https://acme-k3j4h5g6f-t.vercel.app")!) == [bin, "inspect", "https://acme-k3j4h5g6f-t.vercel.app"])
        #expect(plan.display.split(separator: "\n").count == 2)
        #expect(v.verifiesDeployment(output: "  General\n\n    id\tdpl_1\n    name\tacme\n    target\tproduction\n", settings: s))
        #expect(!v.verifiesDeployment(output: "    name\tacme-evil\n", settings: s))
        #expect(!v.verifiesDeployment(output: "    name\tacme\n    name\tother\n", settings: s))
        #expect(!v.verifiesDeployment(output: "Error: not found\n", settings: s))
        // A plan without a verify step hashes as before it existed.
        #expect(try CloudflarePagesAdapter().deployPlan(DeployInput(settings: HostingSettings(companyId: "c1", project: "acme", accountId: "a",
                                                                                              outputDir: "dist", updatedAt: Date()),
                                                                  commit: "abcdef1", version: "1.0.0", layout: layout, release: 1,
                                                                  cli: CloudflarePagesAdapter().cli)).verify == nil)
    }

    @Test func sandboxUnavailableFailsClosed() async throws {
        // PR-5: a Full company's build runs as its checks do (unsandboxed); the token-holding step never does.
        let fx = try Fx(profile: .full, deploySandbox: UnavailableSandboxRunner())
        try fx.preinstallTools()
        let approved = try fx.proposeAndApprove()
        await fx.advance()
        let r = try fx.reload(approved)
        #expect(r.status == .failed)
        #expect(r.failedReason == "sandbox unavailable")
        #expect(fx.calls(in: fx.export(r), of: fx.unsandboxed).count == 1)
        #expect(fx.unsandboxed.calls.count == 1)
        #expect(fx.sandbox.calls.isEmpty)
        #expect(try fx.bugs().map(\.title) == ["Release 0.1.0 failed: deploy (sandbox unavailable)"])
        #expect(!FileManager.default.fileExists(atPath: fx.hostRoot.appending(path: "R-1").path))
    }

    // MARK: The owner's stop

    @Test func emergencyStopInterruptsDeploy() async throws {
        let fx = try Fx(configure: { $0.sleepSeconds = 300 })
        #expect(fx.w.orchestrator.stopObservers.contains { $0 is ReleaseExecutor })
        let approved = try fx.proposeAndApprove()
        let running = Task { await fx.executor.advance(now: fx.w.clock.now) }
        await fx.sandbox.waitForSpawn { $0.command.contains("/node_modules/.bin/fake deploy ") }
        let pid = try #require(fx.sandbox.spawnedPids.last)
        try fx.store.emergencyStop(note: "test", by: "owner", now: fx.w.clock.now)
        await fx.executor.stopAll(reason: "stopped by the owner: test")
        await running.value
        let r = try fx.reload(approved)
        #expect(r.status == .interrupted)
        #expect(r.failedReason == "stopped by the owner: test")
        #expect(fx.executor.processes.count == 0)
        #expect(kill(pid, 0) != 0)
        #expect(!FileManager.default.fileExists(atPath: fx.hostRoot.appending(path: "R-1").path))
        #expect(try fx.notices().contains { $0.title == "Release 0.1.0 was interrupted" })
        #expect(try fx.bugs().isEmpty)
        // Never run again, stopped or not.
        try fx.store.resumeAfterStop(now: fx.w.clock.now)
        await fx.advance()
        #expect(try fx.reload(approved).status == .interrupted)
        #expect(try fx.deploySteps().count == 1)
    }

    @Test func emergencyStopFailsBuild() async throws {
        let fx = try Fx(build: "sleep 300")
        let approved = try fx.proposeAndApprove()
        let running = Task { await fx.executor.advance(now: fx.w.clock.now) }
        await fx.sandbox.waitForSpawn { $0.command == "sleep 300" }
        // Through the engine's own stop path: the tick sees the stop and runs the observers.
        try fx.store.emergencyStop(note: nil, by: "owner", now: fx.w.clock.now)
        try await fx.w.cycle()
        await running.value
        let r = try fx.reload(approved)
        #expect(r.status == .failed)
        #expect(r.failedReason == "stopped by the owner")
        #expect(try fx.deploySteps().isEmpty)
        #expect(try fx.notices().contains { $0.title == "Release 0.1.0 was stopped" && $0.body == "Nothing was deployed." })
    }

    @Test func advanceWhileStoppedClaimsNothing() async throws {
        let fx = try Fx()
        let approved = try fx.proposeAndApprove()
        try fx.store.emergencyStop(note: nil, by: "owner", now: fx.w.clock.now)
        await fx.advance()
        try await fx.w.cycle()
        #expect(try fx.reload(approved).status == .approved)
        #expect(fx.sandbox.calls.isEmpty); #expect(try fx.releaseSmokes().isEmpty)
        try fx.store.resumeAfterStop(now: fx.w.clock.now)
        await fx.advance()
        #expect(try fx.reload(approved).status == .deployed)
    }
}

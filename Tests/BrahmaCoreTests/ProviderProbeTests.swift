import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The owner-run live provider probe (Plan L Task 15, builder-check 9; `brahma hosting probe <company>`), against the fake
/// adapter and FakeSandbox only: nothing here contacts a provider. The real run needs the owner's Vercel token and is never
/// made by a test.
@Suite(.scratch) struct ProviderProbeTests {
    static let token = "vercel-probe-token-0123456789abcdef"

    struct Fx {
        let root: URL
        let paths: BrahmaPaths
        let store: Store
        let company: Company
        let vault: MemoryVault
        let sandbox: FakeSandbox
        let hostRoot: URL
        var fake: FakeHostingAdapter
        let http: FakeHTTPProbe

        init(provider: HostingProviderID = .vercel, token: Bool = true, account: String? = "team_abc123",
             http: FakeHTTPProbe? = nil, configure: (inout FakeHostingAdapter) -> Void = { _ in }) throws {
            root = try tempDir()
            paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            store = try Store(path: paths.database.path)
            company = try store.createCompany(name: "Probe Co", goal: "provider probe", workspacesRoot: paths.workspaces)
            vault = MemoryVault()
            sandbox = FakeSandbox()
            hostRoot = root.appending(path: "host", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
            var adapter = FakeHostingAdapter(id: .vercel, tokenSecret: "VERCEL_TOKEN", server: URL(string: "https://fake-probe.test")!,
                                             hostRoot: hostRoot, verify: true, stageFrom: ["."])
            configure(&adapter)
            fake = adapter
            self.http = http ?? FakeHTTPProbe([FakeHTTPProbe.ok(200, body: "<html>probe page</html>")])
            try store.setHosting(companyId: company.id, by: .owner, provider: provider, accountId: account)
            if token {
                try store.setSecret(companyId: company.id, name: "VERCEL_TOKEN", value: ProviderProbeTests.token, isTest: false, vault: vault)
            }
            try store.reloadRedactorIfNeeded(vault: vault)
        }

        func run(environment: [String: String] = ["PATH": "/usr/bin:/bin", "LANG": "C"], suffix: String = "abc123") async throws -> ProviderProbe.Report {
            let path = try FakeHostingAdapter.tools().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
            var env = environment
            env["PATH"] = path
            let adapter = fake
            return try await ProviderProbe.run(store: store, paths: paths, companyId: company.id, vault: vault, sandbox: sandbox,
                                               http: http, adapters: { _ in adapter }, environment: env, sleep: { _ in }, suffix: suffix)
        }

        func tokenSteps() -> [FakeSandbox.Call] { sandbox.calls.filter { $0.environment["VERCEL_TOKEN"] != nil } }
    }

    @Test func refusedInsideAnAgentTurnWithoutVercelOrWithoutToken() async throws {
        let fx = try Fx()
        await #expect(throws: WorkError.forbidden(ProviderProbe.refusalAgent)) {
            try await fx.run(environment: ["PATH": "/usr/bin:/bin", "BRAHMA_AGENT_ID": "eng-1"])
        }
        let cloudflare = try Fx(provider: .cloudflarePages)
        await #expect(throws: WorkError.invalid(ProviderProbe.refusalProvider)) { try await cloudflare.run() }
        let noToken = try Fx(token: false)
        await #expect(throws: WorkError.invalid(ProviderProbe.refusalToken)) { try await noToken.run() }
        let noAccount = try Fx(account: nil)
        await #expect(throws: WorkError.invalid(ProviderProbe.refusalAccount)) { try await noAccount.run() }
        // Nothing ran for any refusal.
        #expect(fx.sandbox.calls.isEmpty && cloudflare.sandbox.calls.isEmpty && noToken.sandbox.calls.isEmpty && noAccount.sandbox.calls.isEmpty)
    }

    /// The probe installs the CLI token-free, stages a marker page, deploys to a throwaway `brahma-probe-<6>` project with the
    /// token in the environment only, verifies with `inspect`, smokes the marker, removes the project and reports each
    /// verdict; the token never reaches argv or the report (the fake CLI echoes it).
    @Test func deploysMarkerVerifiesAndCleansUp() async throws {
        var fx = try Fx(http: FakeHTTPProbe([FakeHTTPProbe.ok(200, body: "<html>\(ProviderProbe.markerPrefix)abc123 probe</html>")]))
        fx.fake.echoToken = true
        let adapter = fx.fake
        let report = try await fx.run()
        #expect(report.project == "brahma-probe-abc123")
        #expect(ProviderProbe.isProbeProject(report.project))
        #expect(report.ok, "\(report.lines)")
        let text = report.lines.joined(separator: "\n")
        #expect(!text.contains(Self.token), Comment(rawValue: text))
        #expect(text.contains("redacted"), Comment(rawValue: text))
        for line in ["CLI pin", "network hosts", "deploy URL", "Production:", "inspect", "smoke", ".env", "GIT_CEILING", "project removed", "leftover"] {
            #expect(report.lines.contains { $0.localizedCaseInsensitiveContains(line) }, "no verdict for \(line): \(report.lines)")
        }
        // The install ran first, token-free, with the install network only; every token step carries the token in its
        // environment, never its argv, with the deploy network and the fixed env (PR-15: org + project from the env).
        let install = try #require(fx.sandbox.calls.first)
        #expect(install.command.hasPrefix("npm install --prefix "), Comment(rawValue: install.command))
        #expect(install.command.contains(adapter.cli))
        #expect(install.environment["VERCEL_TOKEN"] == nil)
        #expect(install.policy.network == .outbound(allow: adapter.toolNetwork))
        let steps = fx.tokenSteps()
        #expect(steps.count >= 5, "\(steps.map(\.command))")   // project add, deploy, inspect, project rm, project ls
        for step in steps {
            #expect(!step.command.contains(Self.token), Comment(rawValue: step.command))
            #expect(step.environment["VERCEL_TOKEN"] == Self.token)
            #expect(step.environment["BRAHMA_AGENT_ID"] == "probe")
            #expect(step.policy.network == .outbound(allow: adapter.network))
            #expect(step.environment["FAKE_ACCOUNT"] == "team_abc123")
            #expect(step.environment["FAKE_INSPECT_PROJECT"] == "brahma-probe-abc123")
        }
        let commands = steps.map(\.command)
        #expect(commands.contains { $0.contains("/node_modules/.bin/fake project add brahma-probe-abc123") }, "\(commands)")
        #expect(commands.contains { $0.contains("/node_modules/.bin/fake deploy ") }, "\(commands)")
        #expect(commands.contains { $0.contains("/node_modules/.bin/fake inspect https://fake-") }, "\(commands)")
        #expect(commands.contains { $0.contains("/node_modules/.bin/fake project rm brahma-probe-abc123 --yes") }, "\(commands)")
        #expect(commands.contains { $0.contains("/node_modules/.bin/fake project ls") }, "\(commands)")
        // The marker page was what the CLI deployed (from the probe's own upload dir under the releases root).
        let layout = try fx.store.releaseLayout(companyId: fx.company.id)
        let deployed = try #require(try FileManager.default.contentsOfDirectory(atPath: fx.hostRoot.path).first)
        let page = try String(contentsOf: fx.hostRoot.appending(path: deployed).appending(path: "index.html"), encoding: .utf8)
        #expect(page.contains("\(ProviderProbe.markerPrefix)abc123"))
        let dotenv = fx.hostRoot.appending(path: deployed).appending(path: ".env").path
        #expect(FileManager.default.fileExists(atPath: dotenv), "the .env canary is staged with the page")
        for step in steps { #expect(step.cwd.path.hasPrefix(layout.root.path), Comment(rawValue: step.cwd.path)) }
        // The smoke asked the production alias for the marker.
        #expect(fx.http.requests.contains { $0.url.absoluteString.hasPrefix("https://") && $0.url.host == "brahma-probe-abc123.vercel.app" || $0.url.absoluteString.hasPrefix("https://fake-") },
                "\(fx.http.requests.map(\.url))")
        // The probe's working folder is gone afterwards; the installed tools stay (the next deploy reuses them).
        #expect(!FileManager.default.fileExists(atPath: layout.root.appending(path: "probe-abc123").path))
        #expect(FileManager.default.fileExists(atPath: layout.deployTools(cli: adapter.cli).appending(path: "node_modules/.bin/fake").path))
        #expect(report.leftovers.isEmpty)
    }

    /// Leftover `brahma-probe-*` projects the final `project ls` still shows are reported by name; other projects are not.
    @Test func reportsLeftoverProbeProjects() async throws {
        var fx = try Fx()
        fx.fake.projects = ["brahma-probe-old111", "my-real-site", "brahma-probe-abc123"]
        let report = try await fx.run()
        #expect(report.leftovers == ["brahma-probe-abc123", "brahma-probe-old111"], "\(report.leftovers)")
        #expect(report.lines.contains { $0.contains("leftover") && $0.contains("brahma-probe-old111") && !$0.contains("my-real-site") }, "\(report.lines)")
        #expect(!report.ok)
    }

    /// A deploy step that fails is reported with its (redacted) tail; the project is still removed; the smoke is skipped.
    @Test func failedDeployIsReportedAndCleanedUp() async throws {
        var fx = try Fx()
        fx.fake.exitCode = 7
        fx.fake.stderrLine = "boom"
        let report = try await fx.run()
        #expect(!report.ok)
        #expect(report.lines.contains { $0.contains("deploy") && $0.contains("exit 7") }, "\(report.lines)")
        #expect(fx.tokenSteps().contains { $0.command.contains("fake project rm brahma-probe-abc123") })
        #expect(fx.http.requests.isEmpty)
    }

    /// A token the redactor cannot demonstrably replace (too short) is refused before anything runs with it.
    @Test func unredactableTokenRefused() async throws {
        let fx = try Fx(token: false)
        try fx.store.setSecret(companyId: fx.company.id, name: "VERCEL_TOKEN", value: "short", isTest: false, vault: fx.vault)
        try fx.store.reloadRedactorIfNeeded(vault: fx.vault)
        let report = try await fx.run()
        #expect(!report.ok)
        #expect(report.lines.contains { $0.contains("redact") }, "\(report.lines)")
        #expect(fx.tokenSteps().isEmpty)
    }

    @Test func projectNames() {
        let name = ProviderProbe.projectName(suffix: ProviderProbe.randomSuffix())
        #expect(name.hasPrefix(ProviderProbe.projectPrefix))
        #expect(name.count == ProviderProbe.projectPrefix.count + 6)
        #expect(HostingSettings.isValidProject(name))
        #expect(ProviderProbe.isProbeProject(name))
        #expect(!ProviderProbe.isProbeProject("brahma-probe-"))
        #expect(!ProviderProbe.isProbeProject("brahma-probe-ABC123"))
        #expect(!ProviderProbe.isProbeProject("my-site"))
        #expect(ProviderProbe.randomSuffix() != ProviderProbe.randomSuffix())
    }
}

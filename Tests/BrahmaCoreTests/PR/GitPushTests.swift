import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The `push-branch` flow end to end (Plan X8 Task 2): the token's path (Review Focus 4, Ruling X8-17), the fresh visibility
/// read, the scans before any request, and an unknown push reconciled by the branch head.
@Suite(.scratch, .serialized) struct GitPushTests {
    static let repo = GitHubRepoRef(owner: "acme", name: "app")

    /// A gate that records what it was asked, then applies the rules.
    final class RecordingGate: PRActionGate, @unchecked Sendable {
        let inner: RulesGate
        private let lock = NSLock()
        private var seen: [PRActionRequest] = []
        init(_ inner: RulesGate) { self.inner = inner }
        var requests: [PRActionRequest] { lock.withLock { seen } }
        func decide(_ r: PRActionRequest) async -> PRActionDecision {
            lock.withLock { seen.append(r) }
            return await inner.decide(r)
        }
    }

    /// A real runner with its spawns and output recorded, and the helper's bytes read while git runs.
    final class SpyRunner: GitPushRunning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var spawns: [(executable: String, argv: [String], env: [String: String])] = []
        private(set) var outputs: [Data] = []
        private(set) var helperBytes: [Data] = []
        var live = LivePushRunner()

        init(trace: URL) {
            live.traceEnvironment = ["GIT_TRACE": trace.path]
            live.spawnObserver = { [weak self] exe, argv, env in self?.lock.withLock { self?.spawns.append((exe, argv, env)) } }
        }

        func run(args: [String], env: [String: String], credential: TokenHandle?, workingDirectory: URL, timeout: Duration,
                 outputCap: Int) throws -> GitPushProcessResult {
            if let helper = args.first(where: { $0.hasPrefix("credential.helper=/") }),
               let bytes = FileManager.default.contents(atPath: String(helper.dropFirst("credential.helper=".count))) {
                lock.withLock { helperBytes.append(bytes) }
            }
            let r = try live.run(args: args, env: env, credential: credential, workingDirectory: workingDirectory, timeout: timeout,
                                 outputCap: outputCap)
            lock.withLock { outputs += [r.stdout, r.stderr] }
            return r
        }
    }

    /// A company with a real workspace repository: `base` on main, `head` one commit on top (a clean change).
    struct Env {
        let store: Store
        let paths: BrahmaPaths
        let company: Company
        let vault = MemoryVault()
        let base: String
        let fx: GitFixture
        var ws: GitWorkspace { fx.ws }

        init() throws {
            let home = try tempDir()
            paths = BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.workspaces, withIntermediateDirectories: true)
            store = try Store(path: paths.database.path)
            company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            fx = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            try fx.ws.ensureRepo()
            try fx.git(["commit", "-q", "--allow-empty", "-m", "base"])
            base = try fx.git(["rev-parse", "HEAD"])
            _ = try store.reloadRedactorIfNeeded(vault: vault, logFailures: false, force: true)
        }

        func item(_ title: String) throws -> WorkItem {
            try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: .task, title: title))
        }

        /// A commit on `base` (not on any branch the agents see): what the merge queue would have verified.
        func commit(_ files: [String: String]) throws -> String {
            try fx.git(["checkout", "-q", "--detach", base])
            for (p, t) in files { try fx.write(p, t) }
            try fx.git(["add", "-A"])
            try fx.git(["commit", "-q", "-m", "change"])
            let sha = try fx.git(["rev-parse", "HEAD"])
            try fx.git(["checkout", "-q", "main"])
            return sha
        }

        /// One earlier push of the company reached GitHub, so the first-push ask is behind it.
        func seedEarlierPush() throws {
            let earlier = try item("earlier")
            try store.upsertPRLanding(PRLanding(itemId: earlier.id, companyId: company.id, branch: "brahma/\(earlier.key)",
                                                pushedSHA: base, state: .open, updatedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        }

        func stage(github: any GitHubAPI, gate: any PRActionGate, push: GitPush, blobs: any BlobPointerScanning = NoBlobPointers()) -> PushBranchStage {
            PushBranchStage(store: store, github: github, gate: gate, push: push, blobs: blobs,
                            token: PushBranchStage.vaultToken(store: store, vault: vault),
                            knownValues: { [store] in store.knownSecretValues(companyId: $0) })
        }

        func setToken(_ value: String) throws {
            try store.setSecret(companyId: company.id, name: LandingSwitch.tokenSecretName, value: value, isTest: false, vault: vault)
            _ = try store.reloadRedactorIfNeeded(vault: vault, logFailures: false, force: true)
        }
    }

    static func granted() -> RulesGate { RulesGate(granted: [GitHubActionType.pushBranch.name]) }

    // MARK: Review Focus 4

    /// Every place a leaked token could sit, searched for its bytes: files under `dirs` (recursively), the given texts, and
    /// every TEXT column of every table. Returns where it was found.
    static func leaks(of token: String, dirs: [URL], texts: [(String, String)], store: Store) throws -> [String] {
        var found: [String] = []
        let needle = Data(token.utf8)
        let fm = FileManager.default
        for dir in dirs {
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker {
                if let data = fm.contents(atPath: url.path), data.range(of: needle) != nil { found.append(url.path) }
            }
        }
        for (label, text) in texts where text.contains(token) { found.append(label) }
        try store.writer.read { db in
            for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'") {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"") {
                    for (column, value) in row where "\(value)".contains(token) { found.append("\(table).\(column)") }
                }
            }
        }
        return found
    }

    @Test(.tags(.process), .enabled(if: LoopbackGitServer.available))
    func tokenNowhereAfterPush() async throws {
        let token = ["loop", "back", "push", "Kq4Rz8Tw1Yx6"].joined(separator: "-")
        let server = try LoopbackGitServer(token: token)
        defer { server.stop() }
        let bare = try server.bare(Self.repo)
        let env = try Env()
        try env.setToken(token)
        try env.seedEarlierPush()
        let item = try env.item("Add the login page")
        let sha = try env.commit(["src/login.swift": "let login = true\n"])
        let trace = try tempDir().appending(path: "git-trace.log")
        let spy = SpyRunner(trace: trace)
        let callRoot = env.paths.home.appending(path: "tmp/push", directoryHint: .isDirectory)
        var push = GitPush(runner: spy, tempRoot: callRoot)
        push.loopbackRemote = server.base
        let github = FakeGitHub(Self.repo)
        let outcome = await env.stage(github: github, gate: Self.granted(), push: push).run(item: item, repo: Self.repo, verifiedSHA: sha,
                                                                                               base: env.base, git: env.ws)
        guard case .pushed(let payload) = outcome else { Issue.record("not pushed: \(outcome)"); return }
        #expect(payload.sha == sha && payload.ref == "refs/heads/brahma/\(item.key)-add-the-login-page")
        // The server only answers the right credential: the helper delivered it.
        #expect(try GitFixture.plainGit(["rev-parse", "refs/heads/brahma/\(item.key)-add-the-login-page"], in: bare) == sha)
        #expect(server.counts.authorized >= 1)
        #expect(try env.store.prLanding(itemId: item.id)?.state == .pushed)

        // Where it could be: every spawn's argv and environment, git's own trace of every process it started (the credential
        // helper and git-remote-http included), the helper's bytes on disk during the push, git's output, the run dir, the call
        // dirs, the data home, and every text column.
        let trail = String(decoding: FileManager.default.contents(atPath: trace.path) ?? Data(), as: UTF8.self)
        #expect(trail.contains("credential-helper get"), "the trace shows git ran the helper: \(trail.prefix(400))")
        #expect(trail.contains("remote-http"), "and its transport")
        var texts: [(String, String)] = [("git trace", trail), ("outcome", "\(outcome)")]
        for (i, s) in spy.spawns.enumerated() {
            texts.append(("spawn \(i) argv", s.argv.joined(separator: " ")))
            texts.append(("spawn \(i) env", s.env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")))
        }
        for (i, data) in spy.outputs.enumerated() { texts.append(("git output \(i)", String(decoding: data, as: UTF8.self))) }
        for (i, data) in spy.helperBytes.enumerated() { texts.append(("helper \(i)", String(decoding: data, as: UTF8.self))) }
        #expect(spy.spawns.count == 2 && spy.helperBytes.count == 1, "one probe and one push, one helper")
        let dirs = [env.paths.runDir, callRoot, env.paths.home, URL(fileURLWithPath: env.company.workspacePath).appending(path: ".git")]
        let found = try Self.leaks(of: token, dirs: dirs, texts: texts, store: env.store)
        #expect(found.isEmpty, "the token leaked to \(found)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: callRoot.path).isEmpty, "the call dir is gone")

        // Positive control: the scan finds a deliberately broken placement (the token in the child's environment, or on disk).
        var leaky = spy.spawns.last?.env ?? [:]
        leaky["GIT_CONFIG_VALUE_0"] = "AUTHORIZATION: basic \(token)"
        let stray = env.paths.runDir.appending(path: "stray.txt")
        try FileManager.default.createDirectory(at: env.paths.runDir, withIntermediateDirectories: true)
        try "x \(token) y".write(to: stray, atomically: true, encoding: .utf8)
        let control = try Self.leaks(of: token, dirs: [env.paths.runDir], texts: [("leaky env", leaky.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))],
                                     store: env.store)
        #expect(control.contains("leaky env") && control.contains { $0.hasSuffix("stray.txt") }, "\(control)")
    }

    /// The same real push, but the repository has a planted pre-push hook and the remote is the argument's: the hook never runs.
    @Test(.tags(.process), .enabled(if: LoopbackGitServer.available))
    func plantedHookNeverRunsOnARealPush() async throws {
        let token = ["hook", "push", "Vb3Nm7Qp"].joined(separator: "-")
        let server = try LoopbackGitServer(token: token)
        defer { server.stop() }
        let bare = try server.bare(Self.repo)
        let env = try Env()
        let hooks = env.fx.root.appending(path: ".git/hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let marker = env.fx.root.appending(path: ".git/hook-ran")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hooks.appending(path: "pre-push"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appending(path: "pre-push").path)
        let sha = try env.commit(["a.txt": "a\n"])
        var push = GitPush(runner: LivePushRunner(), tempRoot: try tempDir())
        push.loopbackRemote = server.base
        let outcome = try push.run(GitPushRequest(gitCommonDir: env.fx.root.appending(path: ".git"), sha: sha, ref: "refs/heads/brahma/A-1",
                                                  url: Self.repo.pushURL), token: try #require(TokenHandle(value: token)))
        #expect(outcome == .pushed(remoteHead: sha), "\(outcome)")
        #expect(try GitFixture.plainGit(["rev-parse", "refs/heads/brahma/A-1"], in: bare) == sha)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the planted hook ran")
        // A wrong token is a known failure (401), never a pushed branch, and the value is not in the error.
        let wrong = try push.run(GitPushRequest(gitCommonDir: env.fx.root.appending(path: ".git"), sha: sha, ref: "refs/heads/brahma/A-2",
                                                url: Self.repo.pushURL), token: try #require(TokenHandle(value: "not-the-token-1")))
        guard case .failed(let why) = wrong else { Issue.record("a wrong token pushed: \(wrong)"); return }
        #expect(!why.contains("not-the-token-1"))
    }

    /// The visibility is read for every push: a repository made public after a private connect makes the next push an ask.
    @Test func publicRepoAlwaysAsks() async throws {
        let env = try Env()
        try env.setToken(["vis", "token", "Pk2Lm9Xs"].joined(separator: "-"))
        try env.seedEarlierPush()
        let github = FakeGitHub(Self.repo, visibility: "private")   // what the connect saw
        let runner = RecordingPushRunner()
        runner.pushResult = GitPushProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)
        let stage = env.stage(github: github, gate: Self.granted(), push: GitPush(runner: runner, tempRoot: try tempDir()))
        let first = try env.item("First")
        let sha1 = try env.commit(["one.txt": "1\n"])
        runner.pushResult.stdout = Data("*\t\(sha1):refs/heads/brahma/\(first.key)-first\t[new branch]\nDone\n".utf8)
        guard case .pushed = await stage.run(item: first, repo: Self.repo, verifiedSHA: sha1, base: env.base, git: env.ws) else {
            Issue.record("a private repository's push should run within the grant"); return
        }
        github.update(Self.repo) { $0.visibility = "public" }
        let second = try env.item("Second")
        let sha2 = try env.commit(["two.txt": "2\n"])
        let outcome = await stage.run(item: second, repo: Self.repo, verifiedSHA: sha2, base: env.base, git: env.ws)
        guard case .needsOwner(let reason, let payload) = outcome else { Issue.record("a public repository's push ran: \(outcome)"); return }
        #expect(reason.contains("public"), "\(reason)")
        #expect(payload.sha == sha2 && payload.paths == ["two.txt"] && payload.diffstat.contains("1 file changed"))
        #expect(runner.pushes.count == 1, "nothing pushed while the owner is asked")
        #expect(github.requests.filter { $0 == "GET /repos/acme/app" }.count == 2, "read fresh for each push: \(github.requests)")
        // `internal` is not private either.
        github.update(Self.repo) { $0.visibility = "internal" }
        guard case .needsOwner = await stage.run(item: second, repo: Self.repo, verifiedSHA: sha2, base: env.base, git: env.ws) else {
            Issue.record("an internal repository's push ran"); return
        }
        // The company's very first push asks too (rule 2), whatever the visibility.
        let fresh = try Env()
        try fresh.setToken(["first", "token", "Hj5Gf3"].joined(separator: "-"))
        let solo = try fresh.item("Solo")
        let sha3 = try fresh.commit(["s.txt": "s\n"])
        let firstStage = fresh.stage(github: FakeGitHub(Self.repo), gate: Self.granted(), push: GitPush(runner: RecordingPushRunner(), tempRoot: try tempDir()))
        guard case .needsOwner(let why, _) = await firstStage.run(item: solo, repo: Self.repo, verifiedSHA: sha3, base: fresh.base, git: fresh.ws) else {
            Issue.record("the first push ran without asking"); return
        }
        #expect(why.contains("first push"))
    }

    /// Spec §9.4: the scans run immediately before every push, and a hit files no request at all.
    @Test func scansRunBeforeEveryPush() async throws {
        let env = try Env()
        try env.setToken(["scan", "token", "Rt6Yu1Io"].joined(separator: "-"))
        try env.seedEarlierPush()
        let runner = RecordingPushRunner()
        let gate = RecordingGate(Self.granted())
        let github = FakeGitHub(Self.repo)
        let stage = env.stage(github: github, gate: gate, push: GitPush(runner: runner, tempRoot: try tempDir()))
        let leaky = try env.item("Leaky")
        let leakSHA = try env.commit(["config/.env": "AWS=\(PrePushScanTests.awsShaped)\n"])
        let refused = await stage.run(item: leaky, repo: Self.repo, verifiedSHA: leakSHA, base: env.base, git: env.ws)
        #expect(refused == .refused("secret scan: 1 hit (config/.env)"), "\(refused)")
        // The pushed token's own value is a known secret: a change carrying it is refused too.
        let carrying = try env.commit(["notes.txt": "the token is \(["scan", "token", "Rt6Yu1Io"].joined(separator: "-"))\n"])
        guard case .refused(let why) = await stage.run(item: leaky, repo: Self.repo, verifiedSHA: carrying, base: env.base, git: env.ws) else {
            Issue.record("the push token itself was pushed"); return
        }
        #expect(why.hasPrefix("secret scan:") && why.contains("notes.txt"), "\(why)")
        let pointer = try env.item("Pointer")
        let pointerSHA = try env.commit(["assets/v.mp4.brahma-blob": "p\n"])
        let blobStage = env.stage(github: github, gate: gate, push: GitPush(runner: runner, tempRoot: try tempDir()),
                                  blobs: PrePushScanTests.FakeBlobs(found: ["assets/v.mp4.brahma-blob"]))
        let blocked = await blobStage.run(item: pointer, repo: Self.repo, verifiedSHA: pointerSHA, base: env.base, git: env.ws)
        #expect(blocked == .refused("blob pointers: 1 (assets/v.mp4.brahma-blob)"))
        #expect(gate.requests.isEmpty, "no request was filed for a refused scan")
        #expect(runner.calls.isEmpty && github.requests.isEmpty, "nothing ran and GitHub was not asked")
        #expect(try env.store.prLanding(itemId: leaky.id) == nil && env.store.prLanding(itemId: pointer.id) == nil)
        // A clean change files exactly one request, after its own scan.
        let clean = try env.item("Clean")
        let cleanSHA = try env.commit(["ok.txt": "ok\n"])
        _ = await stage.run(item: clean, repo: Self.repo, verifiedSHA: cleanSHA, base: env.base, git: env.ws)
        #expect(gate.requests.count == 1 && gate.requests.first?.payload?.sha == cleanSHA)
    }

    /// An unknown outcome is settled by reading the branch: its head is the commit → pushed; anything else → failed. Never a second push.
    @Test func unknownReconcilesByBranchHead() async throws {
        let env = try Env()
        try env.setToken(["unknown", "token", "Wq8Er4"].joined(separator: "-"))
        try env.seedEarlierPush()
        let runner = RecordingPushRunner()
        runner.pushResult = GitPushProcessResult(status: 128, stdout: Data(), stderr: Data("fatal: the remote end hung up unexpectedly\n".utf8),
                                                 timedOut: false)
        let github = FakeGitHub(Self.repo)
        let stage = env.stage(github: github, gate: Self.granted(), push: GitPush(runner: runner, tempRoot: try tempDir()))
        // It did land.
        let landed = try env.item("Landed")
        let sha = try env.commit(["l.txt": "l\n"])
        let branch = "brahma/\(landed.key)-landed"
        github.update(Self.repo) { $0.branches[branch] = sha }
        guard case .pushed = await stage.run(item: landed, repo: Self.repo, verifiedSHA: sha, base: env.base, git: env.ws) else {
            Issue.record("a landed push was not reconciled as pushed"); return
        }
        #expect(try env.store.prLanding(itemId: landed.id)?.state == .pushed)
        #expect(runner.pushes.count == 1)
        #expect(github.requests.filter { $0.hasSuffix("/branches/\(branch)") }.count == 1)
        // It did not (the branch is missing, or holds something else): failed, recorded, never pushed again.
        for (title, head) in [("Lost", nil as String?), ("Other", env.base)] {
            let item = try env.item(title)
            let sha = try env.commit(["\(title).txt": "x\n"])
            let name = "brahma/\(item.key)-\(title.lowercased())"
            if let head { github.update(Self.repo) { $0.branches[name] = head } }
            let before = runner.pushes.count
            guard case .failed(let why) = await stage.run(item: item, repo: Self.repo, verifiedSHA: sha, base: env.base, git: env.ws) else {
                Issue.record("\(title): an unconfirmed push was taken as landed"); continue
            }
            #expect(why.contains("does not hold"), "\(why)")
            #expect(runner.pushes.count == before + 1, "\(title): pushed once, never retried")
            let landing = try #require(try env.store.prLanding(itemId: item.id))
            #expect(landing.state == .pushing && landing.lastError == why)
        }
    }
}

import Foundation
import Testing
@testable import BrahmaCore

/// The engine-side scans that run before every push (Plan X8 Task 2, spec §9.4): the secret scan over `remote-main..sha`, the
/// blob-pointer check over the tree at `sha`; any hit refuses with the offending paths; a clean change becomes the payload the
/// owner's card shows.
@Suite(.scratch) struct PrePushScanTests {
    /// An AWS-key-shaped value, assembled at run time (no fixture holds a provider key literal).
    static let awsShaped = ["AK", "IA", "ABCDEFGHIJKLMNOP"].joined()

    struct Repo {
        let fx: GitFixture
        let base: String
        var ws: GitWorkspace { fx.ws }

        init() throws {
            fx = try GitFixture(files: ["README.md": "hello\n"])
            try fx.git(["add", "-A"])
            try fx.git(["commit", "-q", "--allow-empty", "-m", "base"])
            base = try fx.git(["rev-parse", "HEAD"])
            try fx.git(["checkout", "-q", "-b", "work"])
        }

        /// Commits `files` on top of the current work branch; returns the new head.
        func commit(_ files: [String: String], message: String = "change") throws -> String {
            for (path, text) in files { try fx.write(path, text) }
            try fx.git(["add", "-A"])
            try fx.git(["commit", "-q", "-m", message])
            return try fx.git(["rev-parse", "HEAD"])
        }
    }

    struct FakeBlobs: BlobPointerScanning {
        var found: [String] = []
        func pointers(inTreeAt sha: String, repo: URL) throws -> [String] { found }
    }

    static let target = PushTarget(itemKey: "A-7", ref: "refs/heads/brahma/A-7-fix", url: "https://github.com/acme/app.git")

    private func run(_ r: Repo, head: String, blobs: FakeBlobs = FakeBlobs(), known: [(String, String)] = []) throws -> PRDecision<PushPayload> {
        try PrePushScan.run(target: Self.target, base: r.base, head: head, git: r.ws, blobs: blobs, knownValues: known)
    }

    @Test func secretHitRefuses() throws {
        let r = try Repo()
        let head = try r.commit(["config/.env": "AWS=\(Self.awsShaped)\n", "src/ok.swift": "let x = 1\n",
                                 "config/known.txt": "token: known-secret-value-123\n"])
        let decision = try run(r, head: head, known: [("DEPLOY_KEY", "known-secret-value-123")])
        guard case .refused(let why) = decision else { Issue.record("a secret was pushed: \(decision)"); return }
        #expect(why.hasPrefix("secret scan: 2 hits ("), "\(why)")
        #expect(why.contains("config/.env") && why.contains("config/known.txt"), "\(why)")
        #expect(!why.contains("src/ok.swift"), "\(why)")
        #expect(!why.contains(Self.awsShaped) && !why.contains("known-secret-value-123"), "the refusal never carries the value")
    }

    @Test func blobPointerRefuses() throws {
        let r = try Repo()
        let head = try r.commit(["assets/video.mp4.brahma-blob": "pointer\n"])
        let decision = try run(r, head: head, blobs: FakeBlobs(found: ["assets/video.mp4.brahma-blob"]))
        #expect(decision == .refused("blob pointers: 1 (assets/video.mp4.brahma-blob)"))
        // The production stand-in (X3a is absent) finds none.
        #expect(try NoBlobPointers().pointers(inTreeAt: head, repo: r.fx.root).isEmpty)
    }

    @Test func cleanTreePasses() throws {
        let r = try Repo()
        let head = try r.commit(["src/a.swift": "let a = 1\n"])
        let decision = try run(r, head: head)
        guard case .allowed(let payload) = decision else { Issue.record("refused: \(decision)"); return }
        #expect(payload.sha == head && payload.ref == Self.target.ref && payload.url == Self.target.url && payload.itemKey == "A-7")
        #expect(payload.paths == ["src/a.swift"])
        #expect(!payload.touchesWorkflows)
    }

    @Test func payloadCarriesDiffstatAndPaths() throws {
        let r = try Repo()
        var files: [String: String] = [:]
        for n in 0..<510 { files[String(format: "gen/f%03d.txt", n)] = "line \(n)\n" }
        files[".github/workflows/zz-last.yml"] = "on: push\n"   // past the 500 shown: still seen
        let head = try r.commit(files)
        guard case .allowed(let payload) = try run(r, head: head) else { Issue.record("refused"); return }
        #expect(payload.paths.count == PrePushScan.maxPaths)
        #expect(payload.paths.first == ".github/workflows/zz-last.yml" || payload.paths.first == "gen/f000.txt")
        #expect(payload.diffstat.contains("511 files changed"), "\(payload.diffstat)")
        #expect(payload.diffstat.contains("511 insertions"), "\(payload.diffstat)")
        #expect(payload.touchesWorkflows, "a workflow change outside the shown paths still counts")
        // Codable round trip: what the card stores is what it shows.
        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(PushPayload.self, from: data) == payload)
    }

    /// Spec §9.3.4: a change under `.github/workflows/` is always an owner ask, whatever the grant says.
    @Test func workflowsPathAsks() async throws {
        let r = try Repo()
        let head = try r.commit([".github/workflows/ci.yml": "on: push\njobs: {}\n"])
        guard case .allowed(let payload) = try run(r, head: head) else { Issue.record("refused"); return }
        #expect(payload.touchesWorkflows)
        #expect(GitHubRules.workflowsPathAsks(payload: payload) != nil)
        let request = PRActionRequest(type: .pushBranch, companyId: "c", itemId: "i", payload: payload, taintedSession: false,
                                      itemTainted: false, externalInput: false, firstUse: false, repoVisibility: "private")
        let gate = RulesGate(granted: [GitHubActionType.pushBranch.name])
        guard case .ask(let reason) = await gate.decide(request) else { Issue.record("a workflow change was not an ask"); return }
        #expect(reason.contains(".github/workflows/"), "\(reason)")
        // The same push without the workflow change runs within the grant.
        var plain = payload
        plain.touchesWorkflows = false
        plain.paths = ["src/a.swift"]
        var auto = request
        auto.payload = plain
        #expect(await gate.decide(auto) == .auto)
        // Case and a leading `./` do not hide it.
        #expect(PrePushScan.touchesWorkflows([".GitHub/Workflows/x.yml"]))
        #expect(PrePushScan.touchesWorkflows(["./.github/workflows/x.yml"]))
        #expect(!PrePushScan.touchesWorkflows([".github/workflowsx/x.yml", "docs/.github/workflows/x.yml"]))
    }
}

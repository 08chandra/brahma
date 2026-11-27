import Foundation
import Testing
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

/// A grant checker a later plan's channel core would stand behind: what the test says is connected and granted.
private struct StubGrantChecker: LandingGrantChecking {
    var status: LandingGrantStatus
    func status(companyId: String) throws -> LandingGrantStatus { status }
}

/// A checker whose channel core is down: `pr` cannot be decided, `local` must not care.
private struct ThrowingGrantChecker: LandingGrantChecking {
    struct Down: Error {}
    func status(companyId: String) throws -> LandingGrantStatus { throw Down() }
}

/// `brahma company landing <co> [local|pr] [--engine-merge]` (Plan X8 Task 1). No github channel exists on this tree, so the
/// production checker refuses PR mode; the in-process tests inject a stub to cover the grant rules and the success path.
@Suite(.scratch) struct LandingCommandTests {
    /// A value with no provider key shape (the test fixtures never hold a real-looking token).
    static let tokenValue = ["push", "token", "value", "123456"].joined(separator: "-")

    @Test func prNeedsChannelAndGrant() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let refused = try brahma(["company", "landing", "Acme", "pr"], home: home)
        #expect(refused.status != 0)
        // The last stderr line is the refusal, exactly (an earlier one may be the dev key-store warning).
        #expect(refused.stderr.hasSuffix("\nbrahma: \(LandingMode.needsChannelText)\n"), "\(refused.stderr)")
        #expect(refused.stderr.contains("PR mode needs a github channel with a grant for push-branch (brahma/), open-pr and comment; see brahma accounts grant"))
        // The token alone is not enough: there is no channel to grant through.
        let stored = try brahma(["secret", "set", "Acme", "GITHUB_PUSH_TOKEN"], home: home, stdin: Self.tokenValue)
        #expect(stored.status == 0, "\(stored.stderr)")
        let still = try brahma(["company", "landing", "Acme", "pr", "--engine-merge"], home: home)
        #expect(still.status != 0); #expect(still.stderr.contains(LandingMode.needsChannelText))
        #expect(try brahma(["company", "landing", "Acme"], home: home).stdout.contains("landing: local"))
        // `local` always succeeds.
        let local = try brahma(["company", "landing", "Acme", "local"], home: home)
        #expect(local.status == 0, "\(local.stderr)"); #expect(local.stdout == "Acme: landing local\n", "\(local.stdout)")
    }

    @Test func engineMergeNeedsMergeGrant() throws {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let granted = StubGrantChecker(status: LandingGrantStatus(channelConnected: true, grantedActions: LandingMode.requiredActionTypes,
                                                                  tokenPresent: true))
        // Everything the plan requires but the merge grant: `--engine-merge` is refused and nothing changes.
        #expect(throws: WorkError.forbidden(LandingMode.needsMergeGrantText)) {
            try LandingSwitch.apply(.pr, engineMerge: true, companyId: c.id, store: store, checker: granted)
        }
        #expect(try store.landing(companyId: c.id) == (.local, engineMerge: false))
        // Without `--engine-merge` the same grants are enough.
        let status = try LandingSwitch.apply(.pr, engineMerge: false, companyId: c.id, store: store, checker: granted)
        #expect(status == granted.status)
        #expect(try store.landing(companyId: c.id) == (.pr, engineMerge: false))
        // With `merge-pr` granted the engine may merge.
        var all = granted
        all.status.grantedActions.insert(LandingMode.engineMergeActionType)
        try LandingSwitch.apply(.pr, engineMerge: true, companyId: c.id, store: store, checker: all)
        #expect(try store.landing(companyId: c.id) == (.pr, engineMerge: true))
        // Each requirement on its own is fatal.
        for broken in [LandingGrantStatus(channelConnected: false, grantedActions: all.status.grantedActions, tokenPresent: true),
                       LandingGrantStatus(channelConnected: true, grantedActions: ["push-branch", "open-pr"], tokenPresent: true),
                       LandingGrantStatus(channelConnected: true, grantedActions: all.status.grantedActions, tokenPresent: false)] {
            #expect(throws: WorkError.forbidden(LandingMode.needsChannelText)) {
                try LandingSwitch.apply(.pr, engineMerge: false, companyId: c.id, store: store, checker: StubGrantChecker(status: broken))
            }
        }
        // `local` never consults the checker (a throwing one cannot stop it), resets engine-merge, and abandons nothing: the
        // landings stay as they are.
        let item = try store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "one"))
        let landing = PRLanding(itemId: item.id, companyId: c.id, branch: "brahma/ACME-1", pushedSHA: String(repeating: "a", count: 40),
                                state: .open, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.upsertPRLanding(landing)
        #expect(try LandingSwitch.apply(.local, engineMerge: true, companyId: c.id, store: store, checker: ThrowingGrantChecker()) == nil)
        #expect(try store.landing(companyId: c.id) == (.local, engineMerge: false))
        #expect(try store.openPRLandings(companyId: c.id) == [landing])
        // The production checker on this tree: no channel, no grants; the token is read from the secret's metadata only.
        let none = try NoChannelGrantChecker(store: store).status(companyId: c.id)
        #expect(none == LandingGrantStatus(channelConnected: false, grantedActions: [], tokenPresent: false))
        let vault = MemoryVault()
        try store.reloadRedactorIfNeeded(vault: vault, logFailures: false)
        try store.setSecret(companyId: c.id, name: LandingSwitch.tokenSecretName, value: Self.tokenValue, isTest: false, vault: vault)
        #expect(try NoChannelGrantChecker(store: store).status(companyId: c.id).tokenPresent)
    }

    @Test func showsStatus() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let shown = try brahma(["company", "landing", "Acme"], home: home)
        #expect(shown.status == 0, "\(shown.stderr)")
        for line in ["landing: local", "engine-merge: off", "github channel: not connected", "grants: none",
                     "token: missing (GITHUB_PUSH_TOKEN)"] {
            #expect(shown.stdout.contains(line), "\(line): \(shown.stdout)")
        }
        #expect(try brahma(["secret", "set", "Acme", "GITHUB_PUSH_TOKEN"], home: home, stdin: Self.tokenValue).status == 0)
        let withToken = try brahma(["company", "landing", "Acme"], home: home)
        #expect(withToken.stdout.contains("token: present (GITHUB_PUSH_TOKEN)"), "\(withToken.stdout)")
        #expect(!withToken.stdout.contains(Self.tokenValue))
        #expect(try brahma(["company", "landing", "Nope"], home: home).status != 0)
    }

    @Test func refusedInsideAgentTurn() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let agentEnv = ["BRAHMA_AGENT_ID": "a1"]
        for c in [["company", "landing", "Acme", "local"], ["company", "landing", "Acme", "pr"], ["company", "landing", "Acme", "pr", "--engine-merge"]] {
            let r = try brahma(c, home: home, env: agentEnv)
            #expect(r.status == 1, "\(c)")
            #expect(r.stderr.contains("brahma: owner commands can't run inside an agent turn"), "\(c): \(r.stderr)")
        }
        // Showing the mode is a read.
        #expect(try brahma(["company", "landing", "Acme"], home: home, env: agentEnv).status == 0)
        // Without an owner key the switch refuses too.
        let bare = try OwnerTestHome(initOwner: false); defer { withExtendedLifetime(bare) {} }
        #expect(try brahma(["company", "landing", "Acme", "local"], home: bare.url).status != 0)
    }
}

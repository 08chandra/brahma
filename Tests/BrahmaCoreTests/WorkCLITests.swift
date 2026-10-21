import Foundation
import Testing
@testable import BrahmaCore
import BrahmaKeychain

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL? = nil, env: [String: String] = [:]) throws
    -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let home = try home ?? tempDir()
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = ["BRAHMA_HOME": home.appending(path: "home").path, "BRAHMA_WORKSPACES": home.appending(path: "ws").path,
             "PATH": "/usr/bin:/bin"]
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

@Suite struct WorkCLITests {
    @Test func companyCreateDryRunPrintsTree() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let r = try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "9", "--dry-run"], home: home)
        #expect(r.status == 0, "\(r.stderr)")
        #expect(r.stdout.contains("ceo (CEO & CPO)")); #expect(r.stdout.contains("    eng-1 (Engineer)"))
        #expect(r.stdout.contains("qa-1 (QA) (vacant)")); #expect(r.stdout.contains("design-1 (Designer) (vacant)"))
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "home/brahma.sqlite").path))
        let big = try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "60", "--dry-run"], home: home)
        #expect(big.stdout.contains("Note: org sizes over 50 are experimental."))
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "3", "--dry-run"], home: home).status != 0)
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "9", "--pack", "nope", "--dry-run"], home: home).status != 0)
    }

    @Test func companyCreateHiresSeatedPlanAndOrgCommands() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let r = try brahma(["company", "create", "Acme", "--goal", "g"], home: home)
        #expect(r.status == 0, "\(r.stderr)")
        #expect(r.stdout.contains("hired 5 of 6"))
        let tree = try brahma(["org", "Acme"], home: home)
        #expect(tree.status == 0, "\(tree.stderr)"); #expect(tree.stdout.contains("ceo (CEO & CPO)"))
        #expect(!tree.stdout.contains("qa-1"))
        let vac = try brahma(["org", "vacancies", "Acme"], home: home)
        #expect(vac.stdout.contains("qa-1")); #expect(vac.stdout.contains("manager: cto"))
        let fill = try brahma(["org", "fill", "Acme", "qa-1"], home: home)
        #expect(fill.status == 0, "\(fill.stderr)")
        #expect(try brahma(["org", "Acme"], home: home).stdout.contains("qa-1 (QA)"))
        let mv = try brahma(["org", "move", "Acme", "qa-1", "--manager", "ceo", "--team", "none"], home: home)
        #expect(mv.status == 0, "\(mv.stderr)")
        #expect(try brahma(["org", "move", "Acme", "ceo", "--manager", "qa-1"], home: home).status != 0)
        let empty = try brahma(["company", "create", "Empty", "--goal", "g", "--agents", "0"], home: home)
        #expect(empty.status == 0); #expect(!empty.stdout.contains("hired"))
    }

    @Test func runRefusesWithoutPassingProbe() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        // PATH has no claude, so the doctor cannot pass and run must refuse before taking the lock.
        let r = try brahma(["run"], home: home)
        #expect(r.status == 1)
        #expect(r.stderr.contains("Run 'brahma doctor' for details.") || r.stdout.contains("Run 'brahma doctor' for details."))
        let d = try brahma(["doctor"], home: home)
        #expect(d.status == 1); #expect(d.stdout.contains("FAIL  version"))
    }

    @Test func ownerCommandsRefuseInsideAgentTurn() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let agentEnv = ["BRAHMA_AGENT_ID": "a1"]
        let cmds: [[String]] = [
            ["company", "create", "X", "--goal", "g"], ["company", "pause", "Acme"], ["company", "resume", "Acme"],
            ["company", "mode", "Acme", "low"], ["company", "weight", "Acme", "2"], ["hire", "Acme", "bob", "--role", "engineer", "--model", "sonnet"],
            ["kill", "Acme", "ceo"], ["pause", "Acme", "ceo"], ["wake", "Acme", "ceo"], ["say", "Acme", "@ceo", "hi"],
            ["org", "move", "Acme", "cto", "--manager", "ceo"], ["org", "fill", "Acme", "qa-1"], ["run"], ["doctor"], ["owner", "init"],
        ]
        for c in cmds {
            let r = try brahma(c, home: home, env: agentEnv)
            #expect(r.status == 1, "\(c)")
            #expect(r.stderr.contains("brahma: owner commands can't run inside an agent turn"), "\(c): \(r.stderr)")
        }
        #expect(try brahma(["org", "Acme"], home: home, env: agentEnv).status == 0)
    }

    @Test func mcpRefusesForeignAgent() throws {
        let home = try tempDir()
        let r = try brahma(["mcp", "--db", home.appending(path: "x.sqlite").path, "--company", "c", "--agent", "b"],
                           home: home, env: ["BRAHMA_AGENT_ID": "a"])
        #expect(r.status == 1)
        #expect(r.stderr.contains("brahma mcp: --agent does not match this turn's agent"))
    }

    @Test func ownerCommandDoesNotCreateKey() throws {
        let home = try OwnerTestHome(initOwner: false)
        for c in [["company", "create", "Acme", "--goal", "g"], ["doctor"], ["run", "--skip-doctor"], ["kill", "Acme", "ceo"]] {
            let r = try brahma(c, home: home.url)
            #expect(r.status == 1, "\(c)")
            #expect(r.stderr.contains("brahma: owner key missing or invalid; run 'brahma owner init' in Terminal or open the app"), "\(c): \(r.stderr)")
        }
        #expect(!FileManager.default.fileExists(atPath: home.url.appending(path: "home/owner.key").path))
    }

    @Test func ownerInitRequiresTTY() throws {
        let home = try OwnerTestHome(initOwner: false)
        let r = try brahma(["owner", "init"], home: home.url)   // stdin/stdout are not a terminal here
        #expect(r.status == 1); #expect(r.stderr.contains("brahma owner init must be run in an interactive terminal"))
        #expect(!FileManager.default.fileExists(atPath: home.url.appending(path: "home/owner.key").path))
        // It also refuses inside an agent turn, even with a terminal.
        let inAgent = try brahma(["owner", "init"], home: home.url, env: ["BRAHMA_AGENT_ID": "a1"])
        #expect(inAgent.status == 1); #expect(inAgent.stderr.contains("owner commands can't run inside an agent turn"))
    }

    @Test func ownerKeyCreatedWith0600AndInitRefusesOverwrite() throws {
        let home = try OwnerTestHome()
        let key = home.url.appending(path: "home/owner.key")
        let attrs = try FileManager.default.attributesOfItem(atPath: key.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        let text = try String(contentsOf: key, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text.count == 64 && text.allSatisfy(\.isHexDigit))
        #expect(try initOwnerKey(home: home.url) != 0)
        #expect(try String(contentsOf: key, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == text)
        #expect(try initOwnerKey(home: home.url, extraArgs: ["--rotate"]) == 0)
        #expect(try String(contentsOf: key, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) != text)
    }

    @Test func ownerInitAfterDeletingKeyNeedsProof() throws {
        let home = try OwnerTestHome()
        let key = home.url.appending(path: "home/owner.key")
        try FileManager.default.removeItem(at: key)
        #expect(try initOwnerKey(home: home.url) != 0)
        #expect(try initOwnerKey(home: home.url, extraArgs: ["--rotate"]) != 0)
        #expect(!FileManager.default.fileExists(atPath: key.path), "no new key without proof")
    }

    @Test func rotateWithoutValidKeyRefused() throws {
        let home = try OwnerTestHome()
        let key = home.url.appending(path: "home/owner.key")
        try Data("tampered\n".utf8).write(to: key)
        #expect(try initOwnerKey(home: home.url, extraArgs: ["--rotate"]) != 0)
        #expect(try String(contentsOf: key, encoding: .utf8) == "tampered\n", "the key must be left untouched")
        let none = try OwnerTestHome(initOwner: false)
        #expect(try initOwnerKey(home: none.url, extraArgs: ["--rotate"]) != 0)
        #expect(!FileManager.default.fileExists(atPath: none.url.appending(path: "home/owner.key").path))
    }

    @Test func rotateWithValidKeySucceeds() throws {
        let home = try OwnerTestHome()
        let key = home.url.appending(path: "home/owner.key")
        let before = try String(contentsOf: key, encoding: .utf8)
        #expect(try initOwnerKey(home: home.url, extraArgs: ["--rotate"]) == 0)
        #expect(try String(contentsOf: key, encoding: .utf8) != before)
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home.url).status == 0)
    }

    @Test func symlinkedHomeResolvesToSameItem() throws {
        let home = try OwnerTestHome()
        let link = home.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.url.appending(path: "home"))
        let r = try brahma(["company", "create", "Acme", "--goal", "g"], home: home.url, env: ["BRAHMA_HOME": link.path])
        #expect(r.status == 0, "\(r.stderr)")
        #expect(try brahma(["pause", "Acme", "ceo"], home: home.url, env: ["BRAHMA_HOME": link.path]).stderr.contains("owner key") == false)
    }

    @Test func symlinkedDBRefused() throws {
        let home = try OwnerTestHome()
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home.url).status == 0)
        let db = home.url.appending(path: "home/brahma.sqlite")
        let moved = home.url.appending(path: "home/real.sqlite")
        try FileManager.default.moveItem(at: db, to: moved)
        try FileManager.default.createSymbolicLink(at: db, withDestinationURL: moved)
        let r = try brahma(["pause", "Acme", "ceo"], home: home.url)
        #expect(r.status == 1); #expect(r.stderr.contains("the database is a symlink or lies outside the data home"))
    }

    @Test func cliWrongKeyAndMissingHashRefusedValidAccepted() throws {
        let home = try OwnerTestHome()
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home.url).status == 0)   // valid key
        let key = home.url.appending(path: "home/owner.key")
        let good = try Data(contentsOf: key)
        try Data("tampered\n".utf8).write(to: key)
        let wrong = try brahma(["pause", "Acme", "ceo"], home: home.url)
        #expect(wrong.status == 1); #expect(wrong.stderr.contains("owner key missing or invalid"))
        try good.write(to: key)
        #expect(!(try brahma(["pause", "Acme", "ceo"], home: home.url).stderr.contains("owner key")))
        KeychainOwnerKeyStore().removeHash(for: ownerPaths(home.url))
        let nohash = try brahma(["pause", "Acme", "ceo"], home: home.url)
        #expect(nohash.status == 1); #expect(nohash.stderr.contains("owner key missing or invalid"))
        // Read-only commands never needed the key.
        #expect(try brahma(["org", "Acme"], home: home.url).status == 0)
    }

    // MARK: MCP turn credentials

    private func seedTurn(_ home: URL) throws -> (paths: BrahmaPaths, company: Company, agent: Agent, turn: Turn, token: String, store: Store) {
        let paths = BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let store = try Store(path: paths.database.path)
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let agent = try store.hire(companyId: company.id, name: "ceo", role: "ceo", model: "sonnet")
        _ = try store.transition(agentId: agent.id, to: .ready)
        let (running, turn) = try #require(try store.beginTurn(agentId: agent.id, now: Store.now()))
        let token = try store.issueTurnCredential(turnId: turn.id)
        return (paths, company, running, turn, token, store)
    }

    private func mcp(_ s: (paths: BrahmaPaths, company: Company, agent: Agent, turn: Turn, token: String, store: Store),
                     home: URL, token: String?, agent: String? = nil, extra: [String] = []) throws -> (status: Int32, stdout: String, stderr: String) {
        var env: [String: String] = [:]
        if let token { env["BRAHMA_TURN_TOKEN"] = token }
        return try brahma(["mcp", "--db", s.paths.database.path, "--company", s.company.id, "--agent", agent ?? s.agent.id] + extra,
                          home: home, env: env)
    }

    @Test func mcpMissingTokenRefused() throws {
        let home = try tempDir(); let s = try seedTurn(home)
        let r = try mcp(s, home: home, token: nil)
        #expect(r.status != 0); #expect(r.stderr.contains("brahma mcp: missing turn credential"))
        #expect(try mcp(s, home: home, token: "deadbeef").status != 0)
    }

    @Test func mcpWrongAgentRefused() throws {
        let home = try tempDir(); let s = try seedTurn(home)
        let other = try s.store.hire(companyId: s.company.id, name: "cto", role: "cto", model: "sonnet")
        let r = try mcp(s, home: home, token: s.token, agent: other.id)
        #expect(r.status != 0); #expect(r.stderr.contains("brahma mcp: turn credential invalid or turn ended"))
        // A credential is bound to its company as well.
        let otherCompany = try s.store.createCompany(name: "Globex", goal: "g", workspacesRoot: s.paths.workspaces)
        let wrongCompany = try brahma(["mcp", "--db", s.paths.database.path, "--company", otherCompany.id, "--agent", s.agent.id],
                                      home: home, env: ["BRAHMA_TURN_TOKEN": s.token])
        #expect(wrongCompany.status != 0); #expect(wrongCompany.stderr.contains("turn credential invalid or turn ended"))
        // Wrong kind or item binding is refused too.
        #expect(try mcp(s, home: home, token: s.token, extra: ["--kind", "review"]).status != 0)
        #expect(try mcp(s, home: home, token: s.token, extra: ["--item", "i1"]).status != 0)
    }

    @Test func mcpEndedTurnRefused() throws {
        let home = try tempDir(); let s = try seedTurn(home)
        #expect(try s.store.finishTurn(id: s.turn.id, outcome: .succeeded, summary: nil, costUSD: nil))
        let r = try mcp(s, home: home, token: s.token)
        #expect(r.status != 0); #expect(r.stderr.contains("turn credential invalid or turn ended"))
    }

    @Test func mcpValidTokenAccepted() throws {
        let home = try tempDir(); let s = try seedTurn(home)
        let r = try mcp(s, home: home, token: s.token)
        #expect(r.status == 0, "\(r.stderr)")
        #expect(s.store.verifyTurnCredential(token: s.token, companyId: s.company.id, agentId: s.agent.id))
        // Recovery closes the turn and the credential with it.
        _ = try s.store.recoverInterruptedTurns()
        #expect(!s.store.verifyTurnCredential(token: s.token, companyId: s.company.id, agentId: s.agent.id))
    }

    @Test func sha256StandardVectors() {
        #expect(SHA256.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}

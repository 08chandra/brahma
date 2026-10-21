import Foundation
import Testing
import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL? = nil, env: [String: String] = [:]) throws
    -> (status: Int32, stdout: String, stderr: String) {
    let url = Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "brahma")
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
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

@Suite struct WorkCLITests {
    @Test func companyCreateDryRunPrintsTree() throws {
        let home = try tempDir()
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
        let home = try tempDir()
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
        let home = try tempDir()
        // PATH has no claude, so the doctor cannot pass and run must refuse before taking the lock.
        let r = try brahma(["run"], home: home)
        #expect(r.status == 1)
        #expect(r.stderr.contains("Run 'brahma doctor' for details.") || r.stdout.contains("Run 'brahma doctor' for details."))
        let d = try brahma(["doctor"], home: home)
        #expect(d.status == 1); #expect(d.stdout.contains("FAIL  version"))
    }

    @Test func ownerCommandsRefuseInsideAgentTurn() throws {
        let home = try tempDir()
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let agentEnv = ["BRAHMA_AGENT_ID": "a1"]
        let cmds: [[String]] = [
            ["company", "create", "X", "--goal", "g"], ["company", "pause", "Acme"], ["company", "resume", "Acme"],
            ["company", "mode", "Acme", "low"], ["company", "weight", "Acme", "2"], ["hire", "Acme", "bob", "--role", "engineer", "--model", "sonnet"],
            ["kill", "Acme", "ceo"], ["pause", "Acme", "ceo"], ["wake", "Acme", "ceo"], ["say", "Acme", "@ceo", "hi"],
            ["org", "move", "Acme", "cto", "--manager", "ceo"], ["org", "fill", "Acme", "qa-1"], ["run"],
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
}

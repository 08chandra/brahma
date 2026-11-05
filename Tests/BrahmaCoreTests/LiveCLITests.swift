import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
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
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

/// `brahma release` (Plan L Task 8): the list and the detail print agent text only through `safe()`, and the owner-write
/// commands refuse an agent's shell. Releases are written straight into the home's database (no deploy ever runs here).
@Suite(.scratch) struct LiveCLITests {
    static let esc = "\u{1B}"
    static let hostile = "\u{1B}[2J\u{1B}]0;pwned\u{07}notes\u{1B}[31m red"

    struct Rig {
        let owner: OwnerTestHome
        let store: Store
        let company: Company
        let agent: Agent
        var home: URL { owner.url }

        init() throws {
            owner = try OwnerTestHome()
            let made = try brahma(["company", "create", "Acme", "--goal", "g"], home: owner.url)
            #expect(made.status == 0, "\(made.stderr)")
            store = try Store(path: ownerPaths(owner.url).database.path)
            company = try #require(try store.companies().first)
            agent = try #require(try store.agents(companyId: company.id).first)
        }

        /// A release row as the executor leaves it; `change` sets what the test needs.
        @discardableResult
        func release(_ number: Int, status: ReleaseStatus, _ change: (inout Release) -> Void = { _ in }) throws -> Release {
            let commit = String(repeating: "\(number)", count: 40)
            let cwd = "/tmp/brahma-release-test/R-\(number)/upload"
            let plan = try DeployPlan(steps: [DeployStep(label: "deploy", argv: ["/opt/fake/bin/wrangler", "pages", "deploy", "dist"])],
                                      stageFrom: ["dist"], cwdPath: cwd, network: ["api.cloudflare.com"],
                                      tokenSecret: "CLOUDFLARE_API_TOKEN", build: "npm run build", outputDir: "dist")
            let rollback = try DeployPlan(steps: [DeployStep(label: "deploy", argv: ["/opt/fake/bin/wrangler", "pages", "deploy", "."])],
                                          stageFrom: [], cwdPath: "/tmp/brahma-release-test/placeholder", network: ["api.cloudflare.com"],
                                          tokenSecret: "CLOUDFLARE_API_TOKEN", build: "npm run build", outputDir: "dist")
            var r = Release(companyId: company.id, number: number, version: "0.\(number).0", status: status, provider: .cloudflarePages,
                            project: "acme", commit: commit, build: "npm run build", outputDir: "dist", plan: plan, rollbackPlan: rollback,
                            notes: LiveCLITests.hostile, proposedById: agent.id, createdAt: Date())
            change(&r)
            try store.writer.write { db in try r.insert(db) }
            return r
        }
    }

    @Test func releaseListAndShowAreSanitized() throws {
        let rig = try Rig()
        try rig.release(1, status: .deployed) {
            $0.deployURL = "https://abcdef12.acme.pages.dev"
            $0.productionURL = "https://acme.pages.dev"
            $0.smokeStatus = "passed"
            $0.smokeResults = [SmokeResult(url: "https://acme.pages.dev/", method: "GET", status: 200, millis: 12,
                                           bodyPrefix: "\(Self.esc)[31mbody", ok: true, error: nil)]
            $0.outputTail = "deployed \(Self.esc)[2Kok"
        }
        try rig.release(2, status: .failed) {
            $0.failedReason = "the deploy step failed \(Self.esc)]0;title\u{07}(exit 1)"
            $0.rollbackStatus = .failed
            $0.rollbackOutputTail = "rollback \(Self.esc)[1mtail"
        }
        let list = try brahma(["release", "Acme"], home: rig.home)
        #expect(list.status == 0, "\(list.stderr)")
        #expect(!list.stdout.contains(Self.esc)); #expect(!list.stdout.contains("\u{07}"))
        let name = rig.agent.name
        let lines = list.stdout.split(separator: "\n").map(String.init)
        #expect(lines.contains("R-2  0.2.0  failed  2222222  -  smoke —  by @\(name)  rollback failed"), "\(list.stdout)")
        #expect(lines.contains("R-1  0.1.0  deployed  1111111  https://acme.pages.dev  smoke passed  by @\(name)"), "\(list.stdout)")
        let main = try #require(try rig.store.company(id: rig.company.id)?.mainCommit)
        #expect(lines.last == "main \(main.prefix(7)): smoke no smoke check", "\(list.stdout)")

        for ref in ["R-1", "R-2"] {
            let show = try brahma(["release", "show", "Acme", ref], home: rig.home)
            #expect(show.status == 0, "\(show.stderr)")
            #expect(!show.stdout.contains(Self.esc), "\(ref)"); #expect(!show.stdout.contains("\u{07}"), "\(ref)")
            #expect(show.stdout.contains("notes"), "\(show.stdout)")
            #expect(show.stdout.contains("/opt/fake/bin/wrangler pages deploy dist"))
            #expect(show.stdout.contains("/opt/fake/bin/wrangler pages deploy ."))
        }
        let one = try brahma(["release", "show", "Acme", "R-1"], home: rig.home).stdout
        #expect(one.contains("GET https://acme.pages.dev/ 200 ok"), "\(one)")
        #expect(one.contains("deployed"), "\(one)")
        let two = try brahma(["release", "show", "Acme", "R-2"], home: rig.home).stdout
        #expect(two.contains("rollback: failed"), "\(two)")
        #expect(two.contains("rollback") && two.contains("tail"), "\(two)")
        #expect(two.contains("(exit 1)"), "\(two)")
        #expect(try brahma(["release", "show", "Acme", "R-9"], home: rig.home).status == 1)
    }

    @Test func rollbackRefusedInAgentShell() throws {
        let rig = try Rig()
        let r = try rig.release(1, status: .deployed)
        let inAgent = try brahma(["release", "rollback", "Acme", "R-1"], home: rig.home, env: ["BRAHMA_AGENT_ID": rig.agent.id])
        #expect(inAgent.status == 1)
        #expect(inAgent.stderr.contains("owner commands can't run inside an agent turn"), "\(inAgent.stderr)")
        let smoke = try brahma(["release", "smoke", "Acme"], home: rig.home, env: ["BRAHMA_AGENT_ID": rig.agent.id])
        #expect(smoke.status == 1)
        #expect(smoke.stderr.contains("owner commands can't run inside an agent turn"), "\(smoke.stderr)")
        let row = try #require(try rig.store.release(companyId: rig.company.id, ref: "R-1"))
        #expect(row.rollbackStatus == nil); #expect(row.rollbackRequestedAt == nil)
        #expect(row.id == r.id)
        // Reading is fine in an agent's shell.
        #expect(try brahma(["release", "Acme"], home: rig.home, env: ["BRAHMA_AGENT_ID": rig.agent.id]).status == 0)
    }

    @Test func rollbackTwiceRefused() throws {
        let rig = try Rig()
        let r = try rig.release(1, status: .deployed)
        let first = try brahma(["release", "rollback", "Acme", "R-1"], home: rig.home)
        #expect(first.status == 0, "\(first.stderr)")
        #expect(first.stdout == "Rolling back R-1; the engine runs:\n\(r.rollbackPlan.display)\n", "\(first.stdout)")
        #expect(try rig.store.release(companyId: rig.company.id, ref: "R-1")?.rollbackStatus == .requested)
        let second = try brahma(["release", "rollback", "Acme", "R-1"], home: rig.home)
        #expect(second.status == 1)
        #expect(second.stderr.contains("R-1 is already rolling back"), "\(second.stderr)")
        try rig.release(2, status: .proposed)
        let proposed = try brahma(["release", "rollback", "Acme", "R-2"], home: rig.home)
        #expect(proposed.status == 1)
        #expect(proposed.stderr.contains("R-2 is proposed; only deployed or failed releases roll back"), "\(proposed.stderr)")
        // The list shows the requested rollback.
        #expect(try brahma(["release", "Acme"], home: rig.home).stdout.contains("rollback requested"))
    }
}

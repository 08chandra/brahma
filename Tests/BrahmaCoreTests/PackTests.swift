import Testing
import Foundation
@testable import BrahmaCore

@Suite(.scratch) struct PackTests {
    private func encoded(_ p: IndustryPack) throws -> Data { try JSONEncoder().encode(p) }

    private var software: IndustryPack { PackCatalog.builtin.pack("software")! }

    @Test func builtinSoftwarePackIsValid() throws {
        let p = try #require(PackCatalog.builtin.pack("software")); try p.validate()
        #expect(p.version == 2); #expect(p.roles.count == 13)
        // Plan L: the ops tools on devops, architect and every executive (including the merged roles).
        for id in ["devops", "architect", "ceo", "cpo", "cto", "ceo-cpo", "cto-architect"] {
            #expect(Set(p.role(id)!.companyTools).isSuperset(of: CompanyToolNames.ops), "\(id)")
        }
        for id in ["director", "manager", "engineer", "designer", "qa", "security"] {
            #expect(Set(p.role(id)!.companyTools).isDisjoint(with: CompanyToolNames.ops), "\(id)")
        }
        #expect(p.roles.allSatisfy { !$0.prompt.isEmpty && $0.prompt.count <= 5000 && $0.prompt.contains($0.title) })
        #expect(p.roles.allSatisfy { $0.prompt.hasSuffix("STATUS: DONE|DONE_WITH_CONCERNS|BLOCKED|NEEDS_CONTEXT") })
        #expect(p.roles.allSatisfy { $0.playbooks.values.allSatisfy { $0.count <= 2500 } })
        #expect(p.itemType("task")?.requiresCheck == true); #expect(p.itemType("spike")?.requiresCheck == false)
        #expect(p.itemType("epic")?.container == true); #expect(p.rolesCovering("cto") == ["cto", "cto-architect"])
        #expect(p.roles.allSatisfy { !$0.models.values.contains("opus") })
        #expect(Set(p.role("engineer")!.playbooks.keys) == ["task", "bug", "spike"])
        #expect(Set(p.role("qa")!.playbooks.keys) == ["bug", "task"])
        #expect(Set(p.role("manager")!.playbooks.keys) == ["story", "epic"])
        #expect(Set(p.role("designer")!.playbooks.keys) == ["story", "spike"])
    }

    @Test func roleWeightsUnchangedFromPlan1() {
        #expect(["ceo", "cto", "cpo", "ceo-cpo", "cto-architect"].allSatisfy { roleWeight($0) == 3 })
        #expect(roleWeight("architect") == 2); #expect(roleWeight("manager") == 1); #expect(roleWeight("director") == 1)
        #expect(["engineer", "designer", "qa", "devops", "security", "nobody"].allSatisfy { roleWeight($0) == 0 })
        #expect(PackCatalog.builtin.roleWeight("manager") == roleWeight("manager"))
    }

    @Test func filePackWithHigherVersionOverrides() throws {
        let dir = try tempDir(); var p = software; p.version = software.version + 1; p.title = "Software v2"
        try encoded(p).write(to: dir.appending(path: "software.json"))
        var lower = software; lower.version = 0; lower.id = "other"; lower.title = "Other"
        try encoded(lower).write(to: dir.appending(path: "other.json"))
        var same = software; same.id = "other"; same.version = 0; same.title = "Ignored"
        try encoded(same).write(to: dir.appending(path: "z.json"))
        let c = try PackCatalog.load(directory: dir)
        #expect(c.pack("software")?.title == "Software v2"); #expect(c.pack("software")?.version == software.version + 1)
        #expect(c.pack("other")?.title == "Other")
        // A lower or equal version never replaces the built-in.
        var old = software; old.title = "Same version"
        let dir2 = try tempDir(); try encoded(old).write(to: dir2.appending(path: "s.json"))
        #expect(try PackCatalog.load(directory: dir2).pack("software")?.title == software.title)
    }

    @Test func filePackAddsNewIndustry() throws {
        let dir = try tempDir(); var p = software; p.id = "marketing"; p.title = "Marketing"
        try encoded(p).write(to: dir.appending(path: "marketing.json"))
        let c = try PackCatalog.load(directory: dir)
        #expect(c.packs.count == 2); #expect(c.pack("marketing")?.title == "Marketing")
        #expect(try PackCatalog.load(directory: dir.appending(path: "missing")).packs.count == 1)
    }

    @Test func minimalJSONPackWithoutNewFieldsLoads() throws {
        let json = """
        {"id":"mini","version":1,"title":"Mini",
         "roles":[{"id":"boss","title":"Boss","kind":"executive","handlePrefix":"boss","prompt":"You are the Boss.",
                   "companyTools":["post_message"],"models":{"low":"opus","balanced":"opus","max":"opus"},"roleWeight":3,"covers":[]},
                  {"id":"worker","title":"Worker","kind":"individual","handlePrefix":"wk","prompt":"You are a Worker.",
                   "companyTools":["post_message"],"models":{"low":"haiku","balanced":"haiku","max":"haiku"},"roleWeight":0,"covers":[]}],
         "itemTypes":[{"id":"task","title":"Task","container":false,"claimable":true,"requiresCheck":true}],
         "org":{"executives":["boss"],"mergedExecutives":[],"mergedBelow":0,"teamLead":"boss","teamMember":"worker",
                "membersPerTeamMax":6,"ratios":[],"director":"boss","smallTeamName":"core"},
         "defaultCadence":"milestone","askApprovers":{"prd":["boss"]},"reservedCategories":["legal"]}
        """
        let dir = try tempDir(); try json.write(to: dir.appending(path: "mini.json"), atomically: true, encoding: .utf8)
        let p = try #require(try PackCatalog.load(directory: dir).pack("mini"))
        #expect(p.connectors.isEmpty); #expect(p.role("boss")?.skills.isEmpty == true)
        #expect(p.role("boss")?.playbooks.isEmpty == true); #expect(p.itemType("task")?.checkTemplate == nil)
        #expect(p.org.teamSupport == nil)
    }

    @Test(arguments: ["bad-model", "unknown-tool", "dangling-ratio", "dup-role", "bad-category", "bad-playbook"])
    func invalidPackRejected(kind: String) throws {
        var p = software
        switch kind {
        case "bad-model": p.roles[0].models["max"] = "gpt"
        case "unknown-tool": p.roles[0].companyTools.append("rm_rf")
        case "dangling-ratio": p.org.ratios[0].reportsTo = "nobody"
        case "dup-role": p.roles.append(p.roles[0])
        case "bad-category": p.reservedCategories = ["Bad Category"]
        default: p.roles[0].playbooks["nonexistent"] = "x"
        }
        #expect(throws: PackError.self) { try p.validate() }
        let dir = try tempDir(); p.id = "broken"
        try encoded(p).write(to: dir.appending(path: "broken.json"))
        do { _ = try PackCatalog.load(directory: dir); Issue.record("expected throw") }
        catch let PackError.invalid(name, _) { #expect(name == "broken.json") }
    }

    @Test func overlongPlaybookAndPromptRejected() {
        var p = software; p.roles[0].playbooks["task"] = String(repeating: "x", count: 2501)
        #expect(throws: PackError.self) { try p.validate() }
        var q = software; q.roles[0].prompt = String(repeating: "x", count: 5001)
        #expect(throws: PackError.self) { try q.validate() }
    }

    @Test func unknownRoleGetsGenericTemplate() {
        let t = PackCatalog.builtin.template(role: "plumber", pack: "software")
        #expect(t.kind == .individual); #expect(t.roleWeight == 0); #expect(t.id == "plumber")
        #expect(t.companyTools == CompanyToolNames.base + CompanyToolNames.work)
        #expect(t.models == ["low": "sonnet", "balanced": "sonnet", "max": "sonnet"])
        #expect(PackCatalog.builtin.template(role: "engineer", pack: "nope").id == "engineer")
        #expect(RoleTemplate.generic("plumber") == t)
        #expect(PackCatalog.builtin.template(role: "ceo", pack: "software").kind == .executive)
    }

    @Test func roleCardMaterializedOnceThenReadFromFile() throws {
        let home = try tempDir()
        let paths = BrahmaPaths(home: home, workspaces: home.appending(path: "ws"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: "/tmp/acme", status: .running,
                              usageMode: .balanced, priorityWeight: 1, createdAt: now)
        let agent = Agent(id: "a1", companyId: "c1", name: "eng-1", role: "engineer", model: "sonnet", sessionId: "s",
                          sessionStarted: false, state: .ready, blocker: nil, requestedBlocker: nil, paused: false,
                          readySince: nil, createdAt: now)
        let t = try #require(PackCatalog.builtin.pack("software")?.role("engineer"))
        let file = RoleCards.path(paths: paths, companyId: "c1", handle: "eng-1")
        #expect(file.path.hasPrefix(paths.companyDir("c1").path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let first = try RoleCards.load(paths: paths, agent: agent, company: company, template: t)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(first.hasPrefix("---\n")); #expect(first.contains("pack: software@\(PackCatalog.builtin.pack("software")!.version)")); #expect(first.contains("id: engineer"))
        #expect(first.contains(t.prompt)); #expect(!first.contains("playbook"))
        try "OWNER EDIT".write(to: file, atomically: true, encoding: .utf8)
        #expect(try RoleCards.load(paths: paths, agent: agent, company: company, template: t) == "OWNER EDIT")
        try String(repeating: "y", count: 10_000).write(to: file, atomically: true, encoding: .utf8)
        #expect(try RoleCards.load(paths: paths, agent: agent, company: company, template: t).count == 6000)
    }

    @Test func pathsHelpers() {
        let p = BrahmaPaths(home: URL(fileURLWithPath: "/h"), workspaces: URL(fileURLWithPath: "/w"))
        #expect(p.packsDir.path == "/h/packs"); #expect(p.checksDir.path == "/h/checks")
        #expect(p.companyDir("c").path == "/h/companies/c")
    }
}

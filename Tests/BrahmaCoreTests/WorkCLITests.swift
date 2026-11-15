import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL? = nil, env: [String: String] = [:]) throws
    -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let home = try home ?? tempDir()
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

@Suite(.scratch) struct WorkCLITests {
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

    @Test func itemsAddListShow() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let org = try brahma(["org", "Acme"], home: home).stdout
        #expect(org.contains("eng-1") && org.contains("cto"), "\(org)")
        // Nothing yet.
        #expect(try brahma(["items", "Acme"], home: home).stdout == "(no work items)\n")
        let add = try brahma(["items", "add", "Acme", "--type", "story", "--title", "Auth epic"], home: home)
        #expect(add.status == 0, "\(add.stderr)"); #expect(add.stdout == "created ACME-1 (story): Auth epic\n")
        let task = try brahma(["items", "add", "Acme", "--title", "Parser\u{1B}[2J", "--description", "line one\nline two", "--criteria", "it parses",
                               "--check", "swift test", "--path", "Sources/Parser", "--path", "Tests", "--timeout", "900", "--tier", "l",
                               "--priority", "1", "--parent", "acme-1", "--owner", "eng-1", "--reviewer", "cto", "--ready"], home: home)
        #expect(task.status == 0, "\(task.stderr)"); #expect(task.stdout.hasPrefix("created ACME-2 (task): Parser"))
        let list = try brahma(["items", "Acme"], home: home)
        #expect(list.status == 0, "\(list.stderr)")
        let lines = list.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0] == "ACME-1  Backlog  story  p2  M  unassigned  Auth epic")
        #expect(lines[1].hasPrefix("ACME-2  Ready  task  p1  L  @eng-1  Parser"))
        #expect(!list.stdout.contains("\u{1B}"), "agent-controlled text is sanitized")
        #expect(try brahma(["items", "list", "Acme", "--status", "ready"], home: home).stdout.split(separator: "\n").count == 1)
        #expect(try brahma(["items", "list", "Acme", "--owner", "cto"], home: home).stdout == "(no work items)\n")
        let show = try brahma(["items", "show", "Acme", "acme-2"], home: home)
        #expect(show.status == 0, "\(show.stderr)")
        #expect(show.stdout.contains("ACME-2  Parser"))
        #expect(show.stdout.contains("type: task  status: Ready  priority: 1  tier: L"))
        #expect(show.stdout.contains("assignee: @eng-1  reviewer: @cto  author: @owner"))
        #expect(show.stdout.contains("parent: ACME-1"))
        #expect(show.stdout.contains("check (revision 0): swift test  timeout: 900s  paths: Sources/Parser, Tests"))
        #expect(show.stdout.contains("    | line one\n    | line two\n"))
        #expect(show.stdout.contains("spec: confirmed by @owner"))
        #expect(show.stdout.contains("created by @owner:"))
        // Edit, depend, confirm.
        let edit = try brahma(["items", "edit", "Acme", "ACME-2", "--status", "blocked", "--reason", "waiting on api", "--timeout", "1200",
                               "--reviewer", "none", "--intensity", "thorough"], home: home)
        #expect(edit.status == 0, "\(edit.stderr)"); #expect(edit.stdout == "updated ACME-2\n")
        let after = try brahma(["items", "show", "Acme", "ACME-2"], home: home).stdout
        #expect(after.contains("status: Blocked")); #expect(after.contains("blocked: waiting on api"))
        #expect(after.contains("reviewer: none")); #expect(after.contains("timeout: 1200s")); #expect(after.contains("(revision 1)"))
        #expect(after.contains("intensity: thorough"))
        let dep = try brahma(["items", "depend", "Acme", "ACME-2", "--on", "ACME-1"], home: home)
        #expect(dep.status == 0, "\(dep.stderr)"); #expect(dep.stdout == "ACME-2 now waits for ACME-1\n")
        #expect(try brahma(["items", "show", "Acme", "ACME-1"], home: home).stdout.contains("blocks: ACME-2 (Blocked) Parser"))
        let cycle = try brahma(["items", "depend", "Acme", "ACME-1", "--on", "ACME-2"], home: home)
        #expect(cycle.status != 0); #expect(cycle.stderr.contains("dependency cycle"))
        let engine = try brahma(["items", "edit", "Acme", "ACME-2", "--status", "done"], home: home)
        #expect(engine.status != 0); #expect(engine.stderr.contains("status done is set by the engine"))
        let confirm = try brahma(["items", "confirm", "Acme", "ACME-1"], home: home)
        #expect(confirm.status == 0, "\(confirm.stderr)"); #expect(confirm.stdout == "confirmed the spec of ACME-1\n")
        // Refusals.
        #expect(try brahma(["items", "show", "Acme", "ACME-99"], home: home).status != 0)
        #expect(try brahma(["items", "add", "Acme", "--title", "x", "--type", "saga"], home: home).stderr.contains("unknown item type"))
        #expect(try brahma(["items", "add", "Acme", "--title", "x", "--owner", "ghost"], home: home).status != 0)
        #expect(try brahma(["items", "add", "Acme", "--title", "x", "--timeout", "5"], home: home).status != 0)
        #expect(try brahma(["items", "add", "Acme", "--title", "x", "--owner", "eng-1", "--reviewer", "eng-1"], home: home).stderr
            .contains("assignee cannot be its reviewer"))
    }

    @Test func itemWriteCommandsRefuseInsideAgentTurn() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        #expect(try brahma(["items", "add", "Acme", "--title", "a"], home: home).status == 0)
        #expect(try brahma(["items", "add", "Acme", "--title", "b"], home: home).status == 0)
        let agentEnv = ["BRAHMA_AGENT_ID": "a1"]
        let cmds: [[String]] = [
            ["items", "add", "Acme", "--title", "x"], ["items", "edit", "Acme", "ACME-1", "--title", "y"],
            ["items", "depend", "Acme", "ACME-1", "--on", "ACME-2"], ["items", "confirm", "Acme", "ACME-1"],
        ]
        for c in cmds {
            let r = try brahma(c, home: home, env: agentEnv)
            #expect(r.status != 0, "\(c)"); #expect(r.stderr.contains("owner commands can't run inside an agent turn"), "\(c)")
        }
        // Reads are fine.
        #expect(try brahma(["items", "list", "Acme"], home: home, env: agentEnv).status == 0)
        #expect(try brahma(["items", "show", "Acme", "ACME-1"], home: home, env: agentEnv).status == 0)
        // Without an owner key, the writes refuse too.
        let bare = try OwnerTestHome(initOwner: false); defer { withExtendedLifetime(bare) {} }
        #expect(try brahma(["items", "add", "Acme", "--title", "x"], home: bare.url).status != 0)
    }

    @Test func mainAcceptCLI() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        let store = try Store(path: home.appending(path: "home/brahma.sqlite").path)
        let company = try #require(try store.companies().first)
        let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let recorded = try #require(company.mainCommit)
        // main is rewritten outside Brahma: the next claim check raises the alert.
        try GitFixture.plainGit(["commit", "--amend", "--allow-empty", "-m", "rewritten"], in: ws)
        let rewritten = try GitFixture.plainGit(["rev-parse", "refs/heads/main"], in: ws)
        #expect(rewritten != recorded)
        #expect(throws: WorkError.self) { try store.prepareRepo(company: company) }
        func open() throws -> Int {
            try store.writer.read { try Ask.filter(Column("kind") == AskKind.engineAlert && Column("status") == AskStatus.pendingOwner.rawValue).fetchCount($0) }
        }
        #expect(try open() == 1)
        // Not from an agent's shell, and not for an unknown company.
        let refused = try brahma(["main", "accept", "Acme"], home: home, env: ["BRAHMA_AGENT_ID": "a1"])
        #expect(refused.status != 0); #expect(refused.stderr.contains("owner commands can't run inside an agent turn"))
        #expect(try store.company(id: company.id)?.mainCommit == recorded)
        #expect(try brahma(["main", "accept", "Nope"], home: home).status != 0)
        // The owner accepts the current head.
        let accepted = try brahma(["main", "accept", "Acme"], home: home)
        #expect(accepted.status == 0, "\(accepted.stderr)"); #expect(accepted.stdout.contains(String(rewritten.prefix(7))))
        #expect(try store.company(id: company.id)?.mainCommit == rewritten)
        #expect(try open() == 0, "the alert is resolved")
        // A quarantine is merged only from the owner's shell, only a quarantine ref is accepted, and only one Brahma made.
        try "q\n".write(to: ws.appending(path: "q.txt"), atomically: true, encoding: .utf8)
        try GitFixture.plainGit(["add", "-A"], in: ws)
        let tree = try GitFixture.plainGit(["write-tree"], in: ws)
        let handMade = try GitFixture.plainGit(["commit-tree", tree, "-p", rewritten, "-m", "q"], in: ws)
        try GitFixture.plainGit(["update-ref", "refs/brahma/quarantine/20261022-120000", handMade], in: ws)
        let notBrahmas = try brahma(["main", "accept", "Acme", "refs/brahma/quarantine/20261022-120000"], home: home)
        #expect(notBrahmas.status != 0); #expect(notBrahmas.stderr.contains("no quarantine"), "\(notBrahmas.stderr)")
        // The engine quarantines the dirty checkout itself (as a merge pass does) and files the ask.
        let current = try #require(try store.company(id: company.id))
        try store.quarantineRoot(company: current, git: store.gitWorkspace(root: ws, companyId: company.id),
                                 expectedMain: rewritten, now: Date(timeIntervalSince1970: 1_800_000_000))
        // The engine's merge checkout belongs under the data home, never in the workspace.
        #expect(store.gitWorkspace(root: ws, companyId: company.id).mergeWorktreePath.path
            .hasPrefix(home.appending(path: "home/run/merge/\(company.id)").path))
        #expect(store.gitWorkspace(root: ws, companyId: company.id).mergeRepositoryPath.path
            == home.appending(path: "home/run/merge/\(company.id).git").path)
        let ref = "refs/brahma/quarantine/20270115-080000"
        let q = try GitFixture.plainGit(["rev-parse", ref], in: ws)
        let agentRef = try brahma(["main", "accept", "Acme", ref], home: home, env: ["BRAHMA_AGENT_ID": "a1"])
        #expect(agentRef.status != 0); #expect(try store.company(id: company.id)?.mainCommit == rewritten)
        #expect(try brahma(["main", "accept", "Acme", "refs/heads/main"], home: home).status != 0)
        let merged = try brahma(["main", "accept", "Acme", ref], home: home)
        #expect(merged.status == 0, "\(merged.stderr)"); #expect(merged.stdout.contains("merged"))
        #expect(try store.company(id: company.id)?.mainCommit == q)
        #expect(try GitFixture.plainGit(["rev-parse", "refs/heads/main"], in: ws) == q)
        // A2: approving Brahma's quarantine ask from the inbox does the same pinned merge; `main accept` then reports it.
        try "r\n".write(to: ws.appending(path: "r.txt"), atomically: true, encoding: .utf8)
        try store.quarantineRoot(company: try #require(try store.company(id: company.id)), git: store.gitWorkspace(root: ws, companyId: company.id),
                                 expectedMain: q, now: Date(timeIntervalSince1970: 1_800_000_100))
        let second = try #require(try store.writer.read { try store.engineQuarantineAsks($0, companyId: company.id) }.first { $0.status == .pendingOwner })
        let ref2 = try #require(second.subjectId.map { String($0.dropFirst("quarantine:".count).prefix { $0 != "@" }) })
        let q2 = try GitFixture.plainGit(["rev-parse", ref2], in: ws)
        let approved = try brahma(["approve", "Acme", second.ref], home: home)
        #expect(approved.status == 0, "\(approved.stderr)"); #expect(approved.stdout.contains("approved")); #expect(approved.stdout.contains("merged"))
        #expect(try GitFixture.plainGit(["rev-parse", "refs/heads/main"], in: ws) == q2)
        let reported = try brahma(["main", "accept", "Acme", ref2], home: home)
        #expect(reported.status == 0, "\(reported.stderr)"); #expect(reported.stdout.contains("already merged"), "\(reported.stdout)")
        // Without an owner key it is refused too.
        let bare = try OwnerTestHome(initOwner: false); defer { withExtendedLifetime(bare) {} }
        #expect(try brahma(["main", "accept", "Acme"], home: bare.url).status != 0)
    }

    // MARK: Inbox

    private let devEnv = ["BRAHMA_DEV": "1"]

    @Test func inboxApproveAnswerRescindFlow() throws {
        // Covers propose, decide, approve, answer, replan and autonomy (rescind is in rescindFlow).
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        #expect(try brahma(["inbox", "Acme"], home: home).stdout == "(inbox is empty)\n")
        let doc = home.appending(path: "ws/acme/docs/arch.md")
        try FileManager.default.createDirectory(at: doc.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "v1".write(to: doc, atomically: true, encoding: .utf8)
        let p = try brahma(["dev", "propose", "Acme", "--by", "eng-1", "--kind", "architecture", "--title", "Layers\u{1B}[2J",
                            "--summary", "how we split it", "--document", "docs/arch.md"], home: home, env: devEnv)
        #expect(p.status == 0, "\(p.stderr)"); #expect(p.stdout.hasPrefix("A-1 pendingInternal"))
        // Not yet in the owner's inbox: the internal approver has it.
        #expect(try brahma(["inbox", "Acme"], home: home).stdout == "(inbox is empty)\n")
        let d = try brahma(["dev", "decide", "Acme", "A-1", "--by", "cto", "--approve", "--note", "ok"], home: home, env: devEnv)
        #expect(d.status == 0, "\(d.stderr)"); #expect(d.stdout.hasPrefix("A-1 pendingOwner"))
        let inbox = try brahma(["inbox", "Acme"], home: home)
        #expect(inbox.status == 0, "\(inbox.stderr)")
        #expect(inbox.stdout.contains("A-1  architecture  -  medium  from @eng-1  Layers"))
        #expect(!inbox.stdout.contains("\u{1B}")); #expect(inbox.stdout.contains("docs/arch.md"))
        #expect(!inbox.stdout.contains("CHANGED SINCE PROPOSED"))
        #expect(try brahma(["status"], home: home).stdout.contains("inbox: 1 waiting"))
        // The document changes after the proposal.
        try "v2".write(to: doc, atomically: true, encoding: .utf8)
        #expect(try brahma(["inbox", "Acme"], home: home).stdout.contains("CHANGED SINCE PROPOSED"))
        let refused = try brahma(["approve", "Acme", "A-1"], home: home)
        #expect(refused.status != 0)
        #expect(refused.stderr.contains("A-1's document changed since it was proposed; read it again and approve with --ack-changed"))
        let ok = try brahma(["approve", "Acme", "A-1", "--ack-changed", "--note", "go"], home: home)
        #expect(ok.status == 0, "\(ok.stderr)"); #expect(ok.stdout.contains("A-1 approved"))
        #expect(try brahma(["approve", "Acme", "A-1"], home: home).stderr.contains("A-1 is already approved"))
        #expect(try brahma(["inbox", "Acme"], home: home).stdout == "(inbox is empty)\n")
        let all = try brahma(["inbox", "Acme", "--all"], home: home).stdout
        #expect(all.contains("A-1") && all.contains("approved"))
        // A question is answered.
        let q = try brahma(["dev", "request", "Acme", "--by", "eng-1", "--title", "Database?", "--question", "Postgres or SQLite?"],
                           home: home, env: devEnv)
        #expect(q.status == 0, "\(q.stderr)")
        let qi = try brahma(["inbox", "Acme"], home: home).stdout
        #expect(qi.contains("A-2  info  -  low  from @eng-1  Database?")); #expect(qi.contains("Postgres or SQLite?"))
        #expect(try brahma(["approve", "Acme", "A-2"], home: home).status != 0)
        let ans = try brahma(["answer", "Acme", "A-2", "SQLite"], home: home)
        #expect(ans.status == 0, "\(ans.stderr)"); #expect(ans.stdout.contains("A-2 answered"))
        #expect(try brahma(["answer", "Acme", "A-2", "again"], home: home).stderr.contains("A-2 is already answered"))
        #expect(try brahma(["answer", "Acme", "A-9", "x"], home: home).stderr.contains("no ask A-9"))
        // Re-plan and reject.
        for n in 3...4 {
            #expect(try brahma(["dev", "propose", "Acme", "--by", "eng-1", "--kind", "architecture", "--title", "T\(n)", "--summary", "s"],
                               home: home, env: devEnv).status == 0)
        }
        let replan = try brahma(["approve", "Acme", "A-3", "--replan", "split it up"], home: home)
        #expect(replan.status == 0, "\(replan.stderr)"); #expect(replan.stdout.contains("A-3 rejected"))
        let reject = try brahma(["approve", "Acme", "A-4", "--reject", "--note", "no"], home: home)
        #expect(reject.status == 0, "\(reject.stderr)"); #expect(reject.stdout.contains("A-4 rejected"))
        // Autonomy presets, and the on/off alias.
        let auto = try brahma(["company", "autonomy", "Acme", "auto"], home: home)
        #expect(auto.status == 0, "\(auto.stderr)"); #expect(auto.stdout.contains("autonomy: auto"))
        #expect(try brahma(["company", "autonomy", "Acme", "nonsense"], home: home).status != 0)
        #expect(try brahma(["company", "auto", "Acme", "off"], home: home).stdout.contains("autonomy: important"))
        #expect(try brahma(["company", "auto", "Acme", "on"], home: home).stdout.contains("autonomy: auto"))
        // A sprint plan is only an FYI under auto.
        #expect(try brahma(["dev", "propose", "Acme", "--by", "eng-1", "--kind", "sprintPlan", "--title", "S1", "--summary", "s"],
                           home: home, env: devEnv).status == 0)
        let fyi = try brahma(["dev", "decide", "Acme", "A-5", "--by", "ceo", "--approve", "--note", "ok"], home: home, env: devEnv)
        #expect(fyi.stdout.hasPrefix("A-5 approved"), "\(fyi.stdout) \(fyi.stderr)")
        #expect(try brahma(["inbox", "Acme"], home: home).stdout.contains("A-5") == false)
        #expect(try brahma(["inbox", "Acme", "--all"], home: home).stdout.contains("FYI"))
    }

    @Test func sprintShowsProgress() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        #expect(try brahma(["sprint", "Acme"], home: home).stdout == "(no open sprint)\n")
        let store = try Store(path: ownerPaths(home).database.path)
        let c = try #require(try store.companies().first)
        let ceo = try #require(try store.agent(companyId: c.id, name: "ceo"))
        let a = try store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Login"))
        let b = try store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Signup\u{1B}[2J"))
        let (sprint, ask) = try store.planSprint(companyId: c.id, by: .agent(ceo.id), goal: "Accounts\u{07}", itemKeys: [a.key, b.key],
                                                 team: nil, cadence: nil, milestoneKey: nil)
        _ = try store.ownerDecide(askId: ask.id, approve: true)
        try store.writer.write { db in _ = try store.engineSetStatus(db: db, itemId: a.id, to: .done, text: "merged", event: .merged, now: Store.now()) }
        let show = try brahma(["sprint", "Acme"], home: home)
        #expect(show.status == 0, "\(show.stderr)")
        #expect(show.stdout.hasPrefix("\(sprint.name) · company · active · 1/2 done · goal: Accounts\n"), "\(show.stdout)")
        #expect(show.stdout.contains("  \(a.key)  Done  Login"))
        #expect(show.stdout.contains("  \(b.key)  Ready  Signup [2J"), "control characters never reach the terminal")
        #expect(!show.stdout.contains("\u{1B}") && !show.stdout.contains("\u{07}"))
        let list = try brahma(["sprint", "list", "Acme"], home: home)
        #expect(list.status == 0, "\(list.stderr)")
        #expect(list.stdout == "\(sprint.name)  company  active  1/2  Accounts\n")
    }

    @Test func inboxPrintsNoControlCharactersFromOptionLabels() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        // Store-time stripping removes control characters from labels...
        let p = try brahma(["dev", "propose", "Acme", "--by", "eng-1", "--kind", "architecture", "--title", "T", "--summary", "s",
                            "--option", "Safe\u{1B}[2J\u{07}", "--option", "Plain"], home: home, env: devEnv)
        #expect(p.status == 0, "\(p.stderr)")
        #expect(try brahma(["dev", "decide", "Acme", "A-1", "--by", "cto", "--approve", "--note", "ok"], home: home, env: devEnv).status == 0)
        let clean = try brahma(["inbox", "Acme"], home: home).stdout
        #expect(clean.contains("option 1: Safe[2J")); #expect(!clean.contains("\u{1B}")); #expect(!clean.contains("\u{07}"))
        // ...and the CLI sanitises again, even for a row written behind the store's back.
        let paths = ownerPaths(home)
        let store = try Store(path: paths.database.path)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE ask SET payload = REPLACE(payload, '\"Plain\"', '\"Evil\\u001b[2J\\u0007\\nforged\"')")
        }
        let raw = try brahma(["inbox", "Acme"], home: home).stdout
        #expect(!raw.contains("\u{1B}")); #expect(!raw.contains("\u{07}"))
        #expect(raw.contains("option 2: Evil"))
        #expect(!raw.contains("\nforged"))
    }

    @Test func devRequiresFlag() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let args = ["dev", "propose", "Acme", "--by", "eng-1", "--kind", "prd", "--title", "T", "--summary", "s"]
        let no = try brahma(args, home: home)
        #expect(no.status != 0); #expect(no.stderr.contains("BRAHMA_DEV=1"))
        #expect(try brahma(args, home: home, env: ["BRAHMA_DEV": "0"]).status != 0)
        #expect(try brahma(args, home: home, env: devEnv).status == 0)
        // The flag alone is not enough: it still needs the owner key.
        let bare = try OwnerTestHome(initOwner: false); defer { withExtendedLifetime(bare) {} }
        #expect(try brahma(args, home: bare.url, env: devEnv).status != 0)
        // And it is hidden from the help.
        #expect(try brahma(["--help"], home: home).stdout.contains(" dev ") == false)
    }

    @Test func rescindFlow() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        #expect(try brahma(["dev", "propose", "Acme", "--by", "eng-1", "--kind", "other", "--category", "pricing", "--title", "Raise prices",
                            "--summary", "s"], home: home, env: devEnv).status == 0)
        // Nothing to rescind while the ask is still pending.
        let early = try brahma(["rescind", "Acme", "A-1", "--note", "nope"], home: home)
        #expect(early.status != 0); #expect(early.stderr.contains("A-1"))
        #expect(try brahma(["dev", "decide", "Acme", "A-1", "--by", "ceo", "--approve", "--note", "ok"], home: home, env: devEnv).status == 0)
        #expect(try brahma(["approve", "Acme", "A-1", "--note", "go"], home: home).stdout.contains("A-1 approved"))
        // A note is required.
        #expect(try brahma(["rescind", "Acme", "A-1"], home: home).status != 0)
        let r = try brahma(["rescind", "Acme", "A-1", "--note", "market changed"], home: home)
        #expect(r.status == 0, "\(r.stderr)"); #expect(r.stdout.contains("A-1 rescinded"))
        let again = try brahma(["rescind", "Acme", "A-1", "--note", "x"], home: home)
        #expect(again.status != 0); #expect(again.stderr.contains("A-1 is already rescinded"))
        #expect(try brahma(["rescind", "Acme", "A-9", "--note", "x"], home: home).stderr.contains("no ask A-9"))
        #expect(try brahma(["inbox", "Acme", "--all"], home: home).stdout.contains("rescinded"))
    }

    @Test func ownerInboxCommandsRefuseInsideAgentTurn() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        #expect(try brahma(["dev", "propose", "Acme", "--by", "eng-1", "--kind", "prd", "--title", "T", "--summary", "s"],
                           home: home, env: devEnv).status == 0)
        let agentEnv = ["BRAHMA_AGENT_ID": "a1", "BRAHMA_DEV": "1"]
        let cmds: [[String]] = [
            ["approve", "Acme", "A-1"], ["approve", "Acme", "A-1", "--reject"], ["answer", "Acme", "A-1", "x"],
            ["rescind", "Acme", "A-1", "--note", "x"],
            ["company", "autonomy", "Acme", "auto"], ["company", "auto", "Acme", "on"],
            ["dev", "propose", "Acme", "--by", "eng-1", "--kind", "prd", "--title", "T", "--summary", "s"],
            ["dev", "decide", "Acme", "A-1", "--by", "ceo", "--approve", "--note", "x"],
        ]
        for c in cmds {
            let r = try brahma(c, home: home, env: agentEnv)
            #expect(r.status != 0, "\(c)"); #expect(r.stderr.contains("owner commands can't run inside an agent turn"), "\(c): \(r.stderr)")
        }
        // Reading the inbox is fine.
        #expect(try brahma(["inbox", "Acme"], home: home, env: agentEnv).status == 0)
    }

    /// `dev claim` goes through the agent's own `claim_lease`: the item is in progress with a lease, and the worktree and
    /// progress file exist. An agent turn (BRAHMA_AGENT_ID) and a missing BRAHMA_DEV are refused.
    @Test func devClaimTakesTheAgentClaimPath() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let add = try brahma(["items", "add", "Acme", "--title", "Parser", "--check", "true", "--owner", "eng-1", "--reviewer", "cto",
                              "--ready"], home: home)
        #expect(add.status == 0, "\(add.stderr)")
        #expect(try brahma(["dev", "claim", "Acme", "ACME-1", "--by", "eng-1"], home: home).stderr.contains("dev commands need BRAHMA_DEV=1"))
        let refused = try brahma(["dev", "claim", "Acme", "ACME-1", "--by", "eng-1"], home: home,
                                 env: ["BRAHMA_AGENT_ID": "a1", "BRAHMA_DEV": "1"])
        #expect(refused.status != 0); #expect(refused.stderr.contains("owner commands can't run inside an agent turn"), "\(refused.stderr)")
        let claimed = try brahma(["dev", "claim", "Acme", "ACME-1", "--by", "eng-1"], home: home, env: devEnv)
        #expect(claimed.status == 0, "\(claimed.stderr)")
        #expect(claimed.stdout.contains("You hold ACME-1 until"), "\(claimed.stdout)")
        #expect(claimed.stdout.contains("Work only in your worktree:") && claimed.stdout.contains("Progress file:"), "\(claimed.stdout)")
        let worktree = try #require(claimed.stdout.components(separatedBy: "Work only in your worktree: ").last?
            .components(separatedBy: " (branch").first)
        #expect(FileManager.default.fileExists(atPath: worktree), "no worktree at \(worktree)")
        let show = try brahma(["items", "show", "Acme", "ACME-1"], home: home).stdout
        #expect(show.contains("In progress"), "\(show)")
        // A second claim of the same item is the tool's own refusal.
        let again = try brahma(["dev", "claim", "Acme", "ACME-1", "--by", "eng-1"], home: home, env: devEnv)
        #expect(again.status != 0)
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
        HomeFileOwnerKeyStore().removeHash(for: ownerPaths(home.url))
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

    @Test func mcpReviewModeComesFromTheCredential() throws {
        let home = try tempDir(); let s = try seedTurn(home)
        let a = try s.store.createWorkItem(companyId: s.company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "a"))
        let b = try s.store.createWorkItem(companyId: s.company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "b"))
        // A work token cannot be turned into a review server by a flag, whatever item it names.
        #expect(try mcp(s, home: home, token: s.token, extra: ["--review-item", a.key]).status != 0)
        // A review token needs no flag: the credential alone says review of item a.
        try s.store.setTurnContext(turnId: s.turn.id, kind: .review, itemId: a.id)
        let token = try s.store.issueTurnCredential(turnId: s.turn.id, kind: "review", itemId: a.id)
        #expect(try mcp(s, home: home, token: token).status == 0)
        #expect(try mcp(s, home: home, token: token, extra: ["--review-item", a.key]).status == 0)
        // A flag naming another item, an unknown key, or no valid token at all is refused before any item is looked up.
        let other = try mcp(s, home: home, token: token, extra: ["--review-item", b.key])
        #expect(other.status != 0); #expect(other.stderr.contains("does not match this turn's credential"))
        #expect(try mcp(s, home: home, token: token, extra: ["--review-item", "NOPE-9"]).status != 0)
        let bad = try mcp(s, home: home, token: "deadbeef", extra: ["--review-item", "NOPE-9"])
        #expect(bad.status != 0); #expect(bad.stderr.contains("turn credential invalid or turn ended"))
    }

    @Test func whyCLI() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        // Nothing is ready: it says so, and `why` is read-only (no owner key needed).
        let why = try brahma(["why", "Acme"], home: home)
        #expect(why.status == 0, "\(why.stderr)")
        #expect(why.stdout == "0 running.\nno Ready items in the backlog\n", Comment(rawValue: why.stdout))
        #expect(try brahma(["status"], home: home).stdout.contains("  0 running: no Ready items in the backlog"))
        let add = try brahma(["items", "add", "Acme", "--title", "Parser", "--check", "true", "--ready"], home: home)
        #expect(add.status == 0, "\(add.stderr)")
        // A Ready item and idle agents: the next dispatch pass hands it out, which is not a stall.
        let ready = try brahma(["why", "Acme"], home: home).stdout
        #expect(ready == "0 running.\n", Comment(rawValue: ready))
        #expect(try brahma(["why", "Nope"], home: home).status != 0)
        // `org acting` is an owner write.
        let acting = try brahma(["org", "acting", "Acme", "cto"], home: home)
        #expect(acting.status == 0, "\(acting.stderr)"); #expect(acting.stdout == "@cto is acting CEO of Acme\n")
        let bare = try OwnerTestHome(initOwner: false); defer { withExtendedLifetime(bare) {} }
        #expect(try brahma(["org", "acting", "Acme", "cto"], home: bare.url).status != 0)
    }

    @Test func sha256StandardVectors() {
        #expect(SHA256.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }
}

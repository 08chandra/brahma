import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite(.scratch) struct SprintTests {
    private struct W {
        let store: Store, company: Company
        let ceo: Agent, cto: Agent, cpo: Agent, mgr: Agent, eng1: Agent, eng2: Agent
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        init(name: String = "Acme", preset: AutonomyPreset = .important, extraAgents: Int = 0) throws {
            let s = try Store.inMemory()
            let c = try s.createCompany(name: name, goal: "g", workspacesRoot: try tempDir())
            func hire(_ n: String, _ role: String, team: String? = nil, manager: String? = nil) throws -> Agent {
                try s.hire(companyId: c.id, name: n, role: role, model: "sonnet", managerId: manager, team: team)
            }
            store = s; company = c
            ceo = try hire("ceo", "ceo"); cto = try hire("cto", "cto"); cpo = try hire("cpo", "cpo")
            mgr = try hire("mgr-1", "manager", team: "core", manager: cto.id)
            eng1 = try hire("eng-1", "engineer", team: "core", manager: mgr.id)
            eng2 = try hire("eng-2", "engineer", team: "core", manager: mgr.id)
            for i in 0..<extraAgents { _ = try hire("x-\(i)", "engineer", team: "other") }
            _ = try s.createChannel(companyId: c.id, name: "team-core", members: [mgr.id, eng1.id, eng2.id])
            try s.setAutonomy(companyId: c.id, preset)
        }

        func approveGates() throws {
            for kind in [AskKind.prd, .architecture] {
                let a = try store.propose(companyId: company.id, by: .agent(ceo.id), kind: kind, title: kind.title, summary: "s", now: now)
                _ = try store.ownerDecide(askId: a.id, approve: true, now: now)
            }
        }

        @discardableResult
        func item(_ title: String, owner: Agent? = nil, status: WorkItemStatus = .backlog) throws -> WorkItem {
            try store.createWorkItem(companyId: company.id, by: .owner,
                                     draft: WorkItemDraft(type: .task, title: title, ownerId: owner?.id, team: "core", status: status), now: now)
        }

        func plan(_ keys: [String], by: Agent? = nil, goal: String = "Ship login", team: String? = "core", cadence: CadenceKind? = nil,
                  milestone: String? = nil) throws -> (Sprint, Ask) {
            try store.planSprint(companyId: company.id, by: .agent((by ?? mgr).id), goal: goal, itemKeys: keys, team: team, cadence: cadence,
                                 milestoneKey: milestone, now: now)
        }

        func decide(_ ask: Ask, by: Agent? = nil, approve: Bool = true) throws -> Ask {
            try store.internalDecide(askId: ask.id, by: .agent((by ?? cpo).id), approve: approve, note: "ok", now: now)
        }

        func fresh(_ s: Sprint) throws -> Sprint { try #require(try store.sprint(id: s.id)) }
        func fresh(_ i: WorkItem) throws -> WorkItem { try #require(try store.workItem(id: i.id)) }
        func fresh(_ a: Ask) throws -> Ask { try #require(try store.ask(id: a.id)) }

        func dms(_ a: String, _ b: String = "system") throws -> [String] {
            guard let ch = try store.channel(companyId: company.id, name: "dm:" + [a, b].sorted().joined(separator: ":")) else { return [] }
            return try store.messages(channelId: ch.id, limit: 100).map(\.text)
        }

        func posts(_ channel: String) throws -> [Message] {
            guard let ch = try store.channel(companyId: company.id, name: channel) else { return [] }
            return try store.messages(channelId: ch.id, limit: 100)
        }

        func done(_ item: WorkItem) throws {
            try store.writer.write { db in _ = try store.engineSetStatus(db: db, itemId: item.id, to: .done, text: "merged", event: .merged, now: now) }
        }

        /// Puts agents back to sleep (as after their turns), so a later wake is visible.
        func sleep(_ agents: [Agent]) throws {
            try store.writer.write { db in
                for a in agents { try db.execute(sql: "UPDATE agent SET state = 'sleeping', readySince = NULL WHERE id = ?", arguments: [a.id]) }
            }
        }

        func start(_ keys: [String]) throws -> Sprint {
            let (s, a) = try plan(keys)
            _ = try decide(a)
            let started = try fresh(s)
            #expect(started.status == .active)
            return started
        }
    }

    // MARK: Planning and gates

    @Test func planWithoutGatesNeedsOwner() throws {
        let w = try W(preset: .auto)
        let a = try w.item("A")
        // Gates block only irreversible work: the plan is filed, says which gates are missing and always needs the owner.
        let (sprint, ask) = try w.plan([a.key])
        #expect(sprint.status == .pendingApproval)
        #expect(ask.kind == .sprintPlan)
        #expect(ask.summary.hasPrefix("Gates not yet approved: PRD, Architecture."))
        let decided = try w.decide(ask)
        #expect(decided.status == .pendingOwner, "auto would otherwise approve a sprint plan as an FYI")
        #expect(try w.fresh(sprint).status == .pendingApproval)
        _ = try w.store.ownerDecide(askId: ask.id, approve: true, now: w.now)
        #expect(try w.fresh(sprint).status == .active)
        // With the gates approved, the same preset lets the C-suite approve it.
        let w2 = try W(preset: .auto)
        try w2.approveGates()
        let b = try w2.item("B")
        let (_, ask2) = try w2.plan([b.key])
        #expect(!ask2.summary.contains("Gates not yet approved"))
        #expect(try w2.decide(ask2).status == .approved)
    }

    @Test func planRefusals() throws {
        let w = try W()
        try w.approveGates()
        let a = try w.item("A"), b = try w.item("B")
        try w.done(b)
        #expect(throws: WorkError.notFound("unknown item ACME-99")) { try w.plan(["ACME-99"]) }
        #expect(throws: WorkError.conflict("\(b.key) is done")) { try w.plan([b.key]) }
        #expect(throws: WorkError.invalid("a milestone needs milestone_key")) { try w.plan([a.key], cadence: .milestone) }
        #expect(throws: WorkError.forbidden("plan_sprint is for managers and executives")) { try w.plan([a.key], by: w.eng1) }
        // The planned item is taken.
        let (s, _) = try w.plan([a.key])
        #expect(s.name == "Sprint 1")
        #expect(try w.fresh(a).sprintId == s.id)
        #expect(try w.store.itemEvents(itemId: a.id).contains { $0.kind == .sprintChanged && $0.text == "added to Sprint 1" })
        #expect(throws: WorkError.conflict("\(a.key) is already in Sprint 1")) { try w.plan([a.key], by: w.ceo, team: nil) }
    }

    @Test func planActivatesAfterCSuiteWithFYI() throws {
        let w = try W()
        try w.approveGates()
        let a = try w.item("A", owner: w.eng1), b = try w.item("B"), c = try w.item("C", status: .ready)
        let (sprint, ask) = try w.plan([a.key, b.key, c.key])
        #expect(ask.status == .pendingInternal && ask.internalApproverId == w.cpo.id)
        #expect(sprint.askId == ask.id)
        // The tool reply names who it waits on.
        let reply = try CompanyTools(store: w.store, companyId: w.company.id, agentId: w.mgr.id)
            .call(name: "plan_sprint", arguments: ["goal": .string("More"), "items": .array([.string(try w.item("D").key)]), "team": .string("ops")])
        #expect(reply == "Planned Sprint 2 (A-4); waiting on @cpo.")
        let decided = try w.decide(ask)
        #expect(decided.status == .approved && decided.fyi)
        let active = try w.fresh(sprint)
        #expect(active.status == .active)
        #expect(active.startedAt == w.now)
        #expect(active.startedActive == w.store.activeNow(companyId: w.company.id))
        #expect(try [a, b, c].map { try w.fresh($0).status } == [.ready, .ready, .ready])
        let post = try #require(try w.posts("team-core").last)
        #expect(post.senderId == "system")
        #expect(post.text == "Sprint 1 started: Ship login (3 items)")
        // A system post never wakes anybody.
        #expect(try w.store.agent(id: w.eng2.id)?.state == .sleeping)
        #expect(try w.store.sprints(companyId: w.company.id, statuses: [.active]).map(\.id) == [sprint.id])
        #expect(try w.store.sprints(companyId: w.company.id, statuses: [.pendingApproval]).map(\.name) == ["Sprint 2"])
    }

    @Test func everythingPresetNeedsOwner() throws {
        let w = try W(preset: .everything)
        try w.approveGates()
        let a = try w.item("A")
        let (sprint, ask) = try w.plan([a.key])
        #expect(try w.decide(ask).status == .pendingOwner)
        #expect(try w.fresh(sprint).status == .pendingApproval)
        #expect(try w.fresh(a).status == .backlog)
        _ = try w.store.ownerDecide(askId: ask.id, approve: true, now: w.now)
        #expect(try w.fresh(sprint).status == .active)
        #expect(try w.fresh(a).status == .ready)
    }

    @Test func rejectedPlanFreesItems() throws {
        let w = try W()
        try w.approveGates()
        let a = try w.item("A"), b = try w.item("B")
        let (sprint, ask) = try w.plan([a.key, b.key])
        _ = try w.decide(ask, approve: false)
        #expect(try w.fresh(sprint).status == .rejected)
        #expect(try w.fresh(a).sprintId == nil && w.fresh(b).sprintId == nil)
        #expect(try w.fresh(a).status == .backlog)
        #expect(try w.store.itemEvents(itemId: a.id).contains { $0.kind == .sprintChanged && $0.text == "removed from Sprint 1 (plan rejected)" })
        // The team can plan again, with the same items.
        let (again, _) = try w.plan([a.key, b.key])
        #expect(again.name == "Sprint 2")
    }

    @Test func onlyOneOpenSprintPerTeam() throws {
        let w = try W()
        try w.approveGates()
        let a = try w.item("A"), b = try w.item("B"), c = try w.item("C")
        let (s1, _) = try w.plan([a.key])
        #expect(throws: WorkError.conflict("Sprint 1 is still open for core")) { try w.plan([b.key]) }
        // Another team, and the company as a whole, are separate.
        let (s2, _) = try w.plan([b.key], team: "ops")
        let (s3, _) = try w.plan([c.key], by: w.ceo, team: nil)
        #expect(throws: WorkError.conflict("Sprint 3 is still open for the company")) { try w.plan([try w.item("D").key], by: w.ceo, team: nil) }
        #expect([s1.name, s2.name, s3.name] == ["Sprint 1", "Sprint 2", "Sprint 3"])
    }

    @Test func crossCompanySprintRefused() throws {
        let w = try W()
        try w.approveGates()
        let a = try w.item("A")
        let sprint = try w.start([a.key])
        let other = try w.store.createCompany(name: "Other", goal: "g", workspacesRoot: try tempDir())
        let spy = try w.store.hire(companyId: other.id, name: "mgr-9", role: "manager", model: "m")
        #expect(throws: WorkError.forbidden("not in your company")) {
            try w.store.closeSprint(sprintId: sprint.id, by: .agent(spy.id), summary: "x", lessons: "", now: w.now)
        }
        #expect(throws: WorkError.forbidden("not in your company")) {
            try w.store.planSprint(companyId: w.company.id, by: .agent(spy.id), goal: "g", itemKeys: [a.key], team: nil, cadence: nil,
                                   milestoneKey: nil, now: w.now)
        }
        // A key of another company is just unknown.
        let foreign = try w.store.createWorkItem(companyId: other.id, by: .owner, draft: WorkItemDraft(type: .task, title: "F"), now: w.now)
        _ = foreign
        #expect(throws: WorkError.notFound("unknown item \(a.key)")) {
            try w.store.planSprint(companyId: other.id, by: .agent(spy.id), goal: "g", itemKeys: [a.key], team: nil, cadence: nil,
                                   milestoneKey: nil, now: w.now)
        }
        #expect(try w.fresh(sprint).status == .active)
    }

    // MARK: Completion and timeboxes

    @Test func sprintCompletesWhenAllItemsDone() throws {
        let w = try W()
        try w.approveGates()
        let a = try w.item("A"), b = try w.item("B")
        let sprint = try w.start([a.key, b.key])
        try w.done(a)
        #expect(try w.fresh(sprint).status == .active)
        try w.sleep([w.mgr])
        try w.done(b)
        #expect(try w.fresh(sprint).status == .review)
        #expect(try w.dms("mgr-1").contains("Sprint 1 is complete. Call close_sprint with the review summary and retro lessons."))
        // The DM wakes the lead.
        #expect(try w.store.agent(id: w.mgr.id)?.state == .ready)
    }

    @Test func milestoneCadenceCompletesOnMilestone() throws {
        let w = try W()
        try w.approveGates()
        let a = try w.item("A"), m = try w.item("Milestone")
        let (s, ask) = try w.plan([a.key], cadence: .milestone, milestone: m.key)
        #expect(s.cadence == .milestone && s.milestoneItemId == m.id)
        #expect(try w.fresh(m).sprintId == s.id, "the milestone item is part of the sprint")
        _ = try w.decide(ask)
        try w.done(m)
        #expect(try w.fresh(s).status == .review)
        #expect(try w.fresh(a).status != .done)
    }

    @Test func timeboxByActiveDaysAndByTurns() throws {
        let w = try W()
        try w.approveGates()
        let a = try w.item("A")
        let sprint = try w.start([a.key])
        let cid = w.company.id
        try w.store.advanceActive(companyId: cid, by: 4 * 86_400)
        #expect(try w.store.enforceTimeboxes(now: w.now) == 0)
        // Paused days pass on the wall clock but not in active time.
        var paused = w.company; paused.status = .paused
        try w.store.updateCompany(paused)
        for h in 0...48 { try w.store.accrueActiveTime(now: w.now.addingTimeInterval(Double(h) * 3600)) }
        #expect(try w.store.enforceTimeboxes(now: w.now.addingTimeInterval(48 * 3600)) == 0)
        #expect(try w.fresh(sprint).status == .active)
        try w.store.advanceActive(companyId: cid, by: 86_400)
        #expect(try w.store.enforceTimeboxes(now: w.now) == 1)
        #expect(try w.fresh(sprint).status == .review)
        #expect(try w.dms("mgr-1").contains("Sprint 1 reached its timebox (5 active days). Call close_sprint; unfinished items carry over."))

        // By turns: 200 team work turns since the start; infra turns and other teams' turns don't count.
        let w2 = try W()
        try w2.approveGates()
        let s2 = try w2.start([try w2.item("B").key])
        func turns(_ n: Int, _ agent: Agent, infra: Bool = false, kind: TurnKind = .work, reset: Bool = false) throws {
            try w2.store.writer.write { db in
                for _ in 0..<n {
                    var t = Turn(id: UUID().uuidString, agentId: agent.id, companyId: w2.company.id, startedAt: w2.now.addingTimeInterval(1),
                                 endedAt: w2.now.addingTimeInterval(2), outcome: infra ? .failed : .succeeded, summary: nil, costUSD: nil,
                                 infra: infra, kind: kind)
                    if reset { t.sessionResetReason = "size" }
                    try t.insert(db)
                }
            }
        }
        // A turn whose session was reset still did work: only infra turns are left out.
        try turns(148, w2.eng1); try turns(2, w2.eng1, reset: true); try turns(49, w2.eng2); try turns(30, w2.eng2, infra: true); try turns(30, w2.ceo)
        try turns(10, w2.eng1, kind: .review)
        #expect(try w2.store.enforceTimeboxes(now: w2.now) == 0)
        try turns(1, w2.mgr)
        #expect(try w2.store.enforceTimeboxes(now: w2.now) == 1)
        #expect(try w2.fresh(s2).status == .review)
        #expect(try w2.dms("mgr-1").contains("Sprint 1 reached its timebox (200 team turns). Call close_sprint; unfinished items carry over."))
    }

    // MARK: Standups

    @Test func engineStandupFromItemEvents() throws {
        let w = try W()
        try w.approveGates()
        let a = try w.item("A", owner: w.eng1), b = try w.item("B", owner: w.eng1), c = try w.item("C", owner: w.eng2)
        let d = try w.item("D", owner: w.eng2)
        let sprint = try w.start([a.key, b.key, c.key, d.key])
        #expect(try w.store.postStandups(now: w.now) == 0, "not a day yet")
        try w.done(a)
        try w.store.writer.write { db in
            _ = try w.store.engineSetStatus(db: db, itemId: b.id, to: .inProgress, now: w.now)
            _ = try w.store.recordItemEvent(db: db, item: try #require(try WorkItem.fetchOne(db, key: b.id)), actor: "system",
                                            kind: .verificationFailed, text: "check failed (exit 1)", now: w.now)
            _ = try w.store.engineSetStatus(db: db, itemId: c.id, to: .inReview, now: w.now)
            _ = try w.store.engineSetStatus(db: db, itemId: d.id, to: .blocked, now: w.now)
            try db.execute(sql: "UPDATE workItem SET blockedReason = ? WHERE id = ?", arguments: ["waiting on the\nAPI keys", d.id])
        }
        let before = try w.posts("team-core").count
        try w.sleep([w.mgr, w.eng1, w.eng2])
        try w.store.advanceActive(companyId: w.company.id, by: Sprint.standupInterval)
        #expect(try w.store.postStandups(now: w.now) == 1)
        let posts = try w.posts("team-core")
        #expect(posts.count == before + 1)
        let post = try #require(posts.last)
        #expect(post.senderId == "system")
        #expect(post.text == """
            Standup — core — Sprint 1 (1/4 done)
            @mgr-1 — no item activity
            @eng-1 — done: \(a.key) · in progress: \(b.key) (check failed) · blocked: none
            @eng-2 — done: none · in progress: \(c.key) (in review) · blocked: \(d.key) (waiting on the API keys)
            """)
        #expect(try w.fresh(sprint).lastStandupActive == w.store.activeNow(companyId: w.company.id))
        // Nobody woke for it, and the next standup is a day later; yesterday's done items are not repeated.
        #expect(try w.store.agent(id: w.eng1.id)?.state == .sleeping)
        #expect(try w.store.postStandups(now: w.now) == 0)
        try w.store.advanceActive(companyId: w.company.id, by: Sprint.standupInterval)
        #expect(try w.store.postStandups(now: w.now) == 1)
        #expect(try w.posts("team-core").last?.text.contains("@eng-1 — done: none · in progress: \(b.key) (check failed)") == true)
    }

    @Test func sprintTextIsRedactedRawFirst() throws {
        let w = try W()
        try w.approveGates()
        let s = "sprint-secret\nline-two-42"
        try w.store.setSecret(companyId: w.company.id, name: "SPRINT_KEY", value: s, isTest: false, vault: MemoryVault().with(w.company.id, "SPRINT_KEY", s))
        _ = try w.store.reloadRedactorIfNeeded(vault: MemoryVault().with(w.company.id, "SPRINT_KEY", s))
        let a = try w.item("A")
        let (planned, ask) = try w.plan([a.key], goal: "Ship \(s) today")
        #expect(try w.fresh(planned).goal == "Ship [redacted SPRINT_KEY] today")
        _ = try w.decide(ask)
        let closed = try w.store.closeSprint(sprintId: planned.id, by: .agent(w.mgr.id), summary: "Used \(s) once",
                                             lessons: "Never paste \(s)\n- Rotate keys", now: w.now)
        #expect(closed.sprint.summary?.contains("[redacted SPRINT_KEY]") == true)
        let notes = try String(contentsOf: NotesFile.path(workspace: URL(fileURLWithPath: w.company.workspacePath), team: "core"), encoding: .utf8)
        #expect(notes.contains("[redacted SPRINT_KEY]")); #expect(!notes.contains("sprint-secret")); #expect(!notes.contains("line-two-42"))
        let everything = try dumpDatabase(w.store)
        #expect(!everything.contains("sprint-secret")); #expect(!everything.contains("line-two-42"))
    }

    // MARK: Close and notes

    @Test func closeWritesSummaryAndRetroNotes() throws {
        let w = try W()
        try w.approveGates()
        try w.store.setOwnerTimeZone("Asia/Kolkata")
        let a = try w.item("A"), b = try w.item("B")
        let sprint = try w.start([a.key, b.key])
        try w.done(a)
        #expect(throws: WorkError.forbidden("close_sprint is for managers and executives")) {
            try w.store.closeSprint(sprintId: sprint.id, by: .agent(w.eng1.id), summary: "x", lessons: "", now: w.now)
        }
        let closed = try w.store.closeSprint(sprintId: sprint.id, by: .agent(w.mgr.id), summary: "Login works.\nSignup slipped.",
                                             lessons: "Smaller stories\n- Write checks first", now: w.now)
        #expect(closed.sprint.status == .closed && closed.sprint.closedAt == w.now)
        #expect(closed.notesProblem == nil)
        #expect(closed.sprint.summary == "Sprint 1 closed: 1 of 2 items done. Carried over: \(b.key).\nLogin works.\nSignup slipped.")
        #expect(try w.fresh(b).sprintId == nil)
        #expect(try w.fresh(a).sprintId == sprint.id)
        // The agent's words are quoted in the system post.
        let general = try #require(try w.posts("general").last)
        #expect(general.senderId == "system"
                && general.text == "Sprint 1 closed: 1 of 2 items done. Carried over: \(b.key).\n    | Login works.\n    | Signup slipped.")
        #expect(try w.store.events(afterId: 0, companyId: w.company.id).contains { $0.kind == .work && $0.text == "Sprint 1 closed: 1 of 2 items done. Carried over: \(b.key)." })
        let notes = try String(contentsOf: NotesFile.path(workspace: URL(fileURLWithPath: w.company.workspacePath), team: "core"), encoding: .utf8)
        // 1_800_000_000 is 2027-01-15 08:00 UTC, 13:30 in Kolkata.
        #expect(notes == "## Sprint 1 retro — 2027-01-15\n- Smaller stories\n- Write checks first\n")
        #expect(throws: WorkError.conflict("Sprint 1 is closed")) {
            try w.store.closeSprint(sprintId: sprint.id, by: .agent(w.mgr.id), summary: "x", lessons: "", now: w.now)
        }
        // The digest names the team's notes file.
        let ctx = try TurnContext.load(store: w.store, paths: BrahmaPaths(home: try tempDir(), workspaces: try tempDir()), agent: w.eng1, company: w.company)
        #expect(ctx.notesPath == NotesFile.path(workspace: URL(fileURLWithPath: w.company.workspacePath), team: "core").path)
        let text = TurnDigest.render(ctx, agent: w.eng1, company: w.company)
        #expect(text.contains("Your notes: \(ctx.notesPath ?? "")"))
        #expect(!text.contains("Sprint: "), "no open sprint")
    }

    @Test func digestShowsOpenSprint() throws {
        let w = try W()
        try w.approveGates()
        let a = try w.item("A"), b = try w.item("B")
        _ = try w.start([a.key, b.key])
        try w.done(a)
        let ctx = try TurnContext.load(store: w.store, paths: BrahmaPaths(home: try tempDir(), workspaces: try tempDir()), agent: w.eng1, company: w.company)
        let text = TurnDigest.render(ctx, agent: w.eng1, company: w.company)
        #expect(text.contains("Sprint: Sprint 1 · active · 1/2 done · goal: Ship login"))
        #expect(!text.contains("Your notes:"), "no notes file yet")
    }

    @Test func notesFileIsCapped() throws {
        let dir = try tempDir()
        let path = NotesFile.path(workspace: dir, team: "core")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let utc = TimeZone(identifier: "UTC")!
        let line = String(repeating: "x", count: 99)
        for n in 1...30 {
            try NotesFile.append(workspace: dir, team: "core", heading: "S\(n)", lines: Array(repeating: line, count: 5), date: date, timeZone: utc)
        }
        let text = try String(contentsOf: path, encoding: .utf8)
        #expect(text.utf8.count <= NotesFile.cap)
        let first = try #require(text.components(separatedBy: "\n").first)
        #expect(first.hasPrefix("_Earlier notes trimmed: ") && first.hasSuffix(" sections removed on 2027-01-15._"))
        #expect(text.contains("## S30\n"))
        #expect(!text.contains("## S1\n"))
        let kept = text.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.count
        #expect(first == "_Earlier notes trimmed: \(30 - kept) sections removed on 2027-01-15._")
        // One oversize section is cut at a line boundary.
        let big = NotesFile.path(workspace: dir, team: "big")
        try NotesFile.append(workspace: dir, team: "big", heading: "Huge", lines: Array(repeating: line, count: 200), date: date, timeZone: utc)
        let cut = try String(contentsOf: big, encoding: .utf8)
        #expect(cut.utf8.count <= NotesFile.cap)
        #expect(cut.hasPrefix("## Huge\n"))
        #expect(cut.hasSuffix("\n…\n"))
        #expect(cut.components(separatedBy: "\n").allSatisfy { $0.isEmpty || $0 == "…" || $0 == line || $0 == "## Huge" })
    }

    @Test func notesNeverWrittenThroughALink() throws {
        let w = try W()
        try w.approveGates()
        let fm = FileManager.default
        let ws = URL(fileURLWithPath: w.company.workspacePath, isDirectory: true)
        let outside = try tempDir()
        let secret = outside.appending(path: "secret.md")
        try "outside\n".write(to: secret, atomically: true, encoding: .utf8)
        let notes = NotesFile.path(workspace: ws, team: "core")
        try fm.createDirectory(at: notes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: notes, withDestinationURL: secret)
        let s1 = try w.start([try w.item("A").key])
        let closed = try w.store.closeSprint(sprintId: s1.id, by: .agent(w.mgr.id), summary: "ok", lessons: "Keep it small", now: w.now)
        // The outside file is untouched (and never read into the notes); a fresh notes file takes the link's place.
        #expect(try String(contentsOf: secret, encoding: .utf8) == "outside\n")
        var st = stat()
        #expect(lstat(notes.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG)
        #expect(try String(contentsOf: notes, encoding: .utf8) == "## Sprint 1 retro — \(NotesFile.day(w.now, w.store.ownerTimeZone()))\n- Keep it small\n")
        #expect(closed.notesProblem == nil)
        let alerts = try w.store.writer.read { db in
            try Ask.filter(Column("companyId") == w.company.id && Column("kind") == AskKind.engineAlert).fetchAll(db)
        }
        #expect(alerts.count == 1 && alerts[0].title.contains("core.md"), "\(alerts.map(\.title))")

        // A notes directory that is a link is refused: the close still stands, and the lessons are kept in the log.
        try fm.removeItem(at: notes.deletingLastPathComponent())
        try fm.createSymbolicLink(at: notes.deletingLastPathComponent(), withDestinationURL: outside)
        let s2 = try w.start([try w.item("B").key])
        let second = try w.store.closeSprint(sprintId: s2.id, by: .agent(w.mgr.id), summary: "ok", lessons: "Write checks first", now: w.now)
        #expect(second.sprint.status == .closed)
        #expect(second.notesProblem?.contains("symbolic link") == true, "\(second.notesProblem ?? "nil")")
        #expect(try fm.contentsOfDirectory(atPath: outside.path) == ["secret.md"])
        let errors = try w.store.writer.read { db in
            try ActivityEvent.filter(Column("companyId") == w.company.id && Column("kind") == ActivityKind.error.rawValue).fetchAll(db).map(\.text)
        }
        #expect(errors.contains { $0.contains("Sprint 2") && $0.contains("    | - Write checks first") }, "\(errors)")
        let reply = try CompanyTools(store: w.store, companyId: w.company.id, agentId: w.mgr.id)
            .call(name: "close_sprint", arguments: ["sprint": .string(try w.start([try w.item("C").key]).name), "summary": .string("ok"),
                                                    "lessons": .string("More tests")])
        #expect(reply.contains("could not be added to the team's notes"), "\(reply)")
    }

    // MARK: Rescind

    @Test func rescindReversesSprintPlan() throws {
        let w = try W(preset: .everything)
        try w.approveGates()
        let a = try w.item("A"), b = try w.item("B", status: .ready), c = try w.item("C")
        let (sprint, ask) = try w.plan([a.key, b.key, c.key])
        _ = try w.decide(ask)
        _ = try w.store.ownerDecide(askId: ask.id, approve: true, now: w.now)
        #expect(try w.fresh(sprint).status == .active)
        try w.store.writer.write { db in _ = try w.store.engineSetStatus(db: db, itemId: c.id, to: .inProgress, now: w.now) }
        _ = try w.store.ownerRescind(askId: ask.id, note: "not now", now: w.now)
        let closed = try w.fresh(sprint)
        #expect(closed.status == .closed)
        #expect(closed.summary == "cancelled: \(ask.ref) rescinded by the owner")
        // Engine-written: a known, clean author for the retro and the handbook's Sprint summaries (Plan ML Task 5).
        #expect(closed.closedById == "system")
        #expect(MemoryIngest.retroTaint(closed, closedAt: try #require(closed.closedAt)) { _ in "tainted" } == nil)
        #expect(try [a, b, c].map { try w.fresh($0).sprintId } == [nil, nil, nil])
        #expect(try w.fresh(a).status == .backlog && w.fresh(b).status == .backlog)
        #expect(try w.fresh(c).status == .inProgress, "work already started is left alone")
    }

    @Test func rescindArchitectureRegatesPendingPlans() throws {
        // More than eight agents: the architecture gate stands on its own.
        let w = try W(extraAgents: 3)
        try w.approveGates()
        let a = try w.item("A"), b = try w.item("B")
        let active = try w.start([a.key])
        let (pending, plan) = try w.plan([b.key], by: w.ceo, team: nil)
        #expect(plan.status == .pendingInternal)
        let arch = try #require(try w.store.asks(companyId: w.company.id).first { $0.kind == .architecture })
        try w.sleep([w.mgr])
        _ = try w.store.ownerRescind(askId: arch.id, note: "redo", now: w.now)
        let rejected = try w.fresh(plan)
        #expect(rejected.status == .rejected && rejected.ownerNote == "gate \(arch.ref) was rescinded")
        #expect(try w.fresh(pending).status == .rejected)
        #expect(try w.fresh(b).sprintId == nil)
        #expect(try w.fresh(active).status == .active)
        #expect(try w.dms("mgr-1").contains("\(arch.ref) (Architecture) was rescinded; new sprint plans need the owner until a new one is approved."))
        #expect(try w.store.agent(id: w.mgr.id)?.state == .ready)
    }
}

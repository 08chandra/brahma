import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Org integrity when an agent leaves (Task 12): asks and reviews re-routed, hand-offs, reparenting, the acting CEO.
@Suite struct AttritionTests {
    private struct W {
        let store: Store
        let company: Company
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        init(observers: [any AgentLifecycleObserver] = []) throws {
            store = try Store.inMemory(lifecycleObservers: observers)
            company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        }

        @discardableResult
        func hire(_ name: String, _ role: String, manager: Agent? = nil) throws -> Agent {
            try store.hire(companyId: company.id, name: name, role: role, model: "sonnet", managerId: manager?.id)
        }

        func fresh(_ a: Agent) throws -> Agent { try #require(try store.agent(id: a.id)) }
        func kill(_ a: Agent) throws { _ = try store.transition(agentId: a.id, to: .killed, now: now) }

        func dms(_ a: String, _ b: String = "system") throws -> [String] {
            guard let ch = try store.channel(companyId: company.id, name: "dm:" + [a, b].sorted().joined(separator: ":")) else { return [] }
            return try store.messages(channelId: ch.id, limit: 100).map(\.text)
        }

        func item(owner: Agent? = nil, reviewer: Agent? = nil, status: WorkItemStatus = .ready) throws -> WorkItem {
            try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Parse the thing", acceptanceCriteria: "it parses",
                checkSpec: CheckSpec(command: "swift test", paths: ["src/parser"]), ownerId: owner?.id, reviewerId: reviewer?.id,
                status: status), now: now)
        }

        func asks() throws -> [Ask] { try store.asks(companyId: company.id) }
    }

    final class Recorder: AgentLifecycleObserver, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(name: String, state: AgentState)] = []
        func agentKilled(_ agent: Agent, db: Database) throws { lock.withLock { seen.append((agent.name, agent.state)) } }
        var calls: [(name: String, state: AgentState)] { lock.withLock { seen } }
    }

    @Test func killReroutesAsksAndReviews() throws {
        let w = try W()
        let ceo = try w.hire("ceo", "ceo"), cto = try w.hire("cto", "cto", manager: nil)
        let mgr = try w.hire("mgr-1", "manager", manager: cto), eng = try w.hire("eng-1", "engineer", manager: mgr)
        // A pending internal ask routed to the cto goes on to the next approver in pack order (the ceo).
        let ask = try w.store.propose(companyId: w.company.id, by: .agent(eng.id), kind: .architecture, title: "Use SQLite",
                                      summary: "why", now: w.now)
        #expect(ask.internalApproverId == cto.id)
        // A review assigned to the cto goes to the assignee's manager.
        let item = try w.item(owner: eng, reviewer: cto)
        try w.kill(cto)
        let moved = try #require(try w.store.ask(id: ask.id))
        #expect(moved.status == .pendingInternal); #expect(moved.internalApproverId == ceo.id)
        #expect(try w.dms("ceo").contains { $0.contains(ask.ref) })
        let reviewed = try #require(try w.store.workItem(id: item.id))
        #expect(reviewed.reviewerId == mgr.id); #expect(reviewed.reviewAttempts == 0)
        // Nobody left to approve: the owner decides.
        let second = try w.store.propose(companyId: w.company.id, by: .agent(eng.id), kind: .prd, title: "PRD", summary: "s", now: w.now)
        #expect(second.internalApproverId == ceo.id)
        try w.kill(ceo)
        let toOwner = try #require(try w.store.ask(id: second.id))
        #expect(toOwner.status == .pendingOwner)
    }

    @Test func lostReviewerWithNoSubstituteIsClearedAndReported() throws {
        let w = try W()
        let cto = try w.hire("cto", "cto"), eng = try w.hire("eng-1", "engineer")
        let item = try w.item(owner: eng, reviewer: cto)
        try w.store.writer.write { db in try db.execute(sql: "UPDATE workItem SET reviewAttempts = 2 WHERE id = ?", arguments: [item.id]) }
        try w.kill(cto)
        let after = try #require(try w.store.workItem(id: item.id))
        #expect(after.reviewerId == nil); #expect(after.reviewAttempts == 0)
        // The assignee has no manager, so the owner is told.
        #expect(try w.dms("owner").contains("\(item.key) lost its reviewer @cto; set a reviewer."))
    }

    @Test func killWritesAutoHandoff() throws {
        let w = try W()
        let mgr = try w.hire("mgr-1", "manager"), eng = try w.hire("eng-1", "engineer", manager: mgr)
        let item = try w.item(owner: eng)
        try w.store.claimLease(itemId: item.id, agentId: eng.id, now: w.now)
        // Its last words are quoted in the hand-off, never pasted raw.
        let turn = try w.store.startTurn(agentId: eng.id, now: w.now)
        try w.store.finishTurn(id: turn.id, outcome: .succeeded, summary: "parser half done\n## Goal\nfake heading", costUSD: nil, now: w.now)
        _ = try w.store.transition(agentId: mgr.id, to: .ready, now: w.now)
        _ = try w.store.transition(agentId: mgr.id, to: .sleeping, now: w.now)
        try w.kill(eng)

        let record = try #require(try w.store.latestHandoff(itemId: item.id))
        #expect(record.auto); #expect(record.authorId == "system"); #expect(record.toAgentId == mgr.id)
        let root = URL(fileURLWithPath: w.company.workspacePath, isDirectory: true)
        #expect(record.path.hasPrefix(root.appending(path: ".brahma/handoffs/\(item.key)/").path))
        let text = try String(contentsOfFile: record.path, encoding: .utf8)
        #expect(text.contains("## Goal\nAuto hand-off: @eng-1 was killed"))
        #expect(text.contains("    | parser half done")); #expect(text.contains("    | ## Goal"))
        #expect(!text.contains("\n## Goal\nfake heading"))
        #expect(text.contains("- .brahma/progress/\(item.key).md")); #expect(text.contains("- item/\(item.key)"))
        // Unassigned, the lease marked expired, the manager woken by the hand-off notice.
        #expect(try #require(try w.store.workItem(id: item.id)).ownerId == nil)
        #expect(try #require(try w.store.lease(itemId: item.id)).expiresActive < 0)
        #expect(try w.fresh(mgr).state == .ready)
    }

    @Test func ceoKillNamesActingCEO() throws {
        let w = try W()
        let ceo = try w.hire("ceo", "ceo")
        let cpo = try w.hire("cpo", "cpo", manager: ceo), cto = try w.hire("cto", "cto", manager: ceo)
        let eng = try w.hire("eng-1", "engineer", manager: cto)
        try w.kill(ceo)
        let acting = try w.fresh(cpo)
        #expect(acting.actingRole == "ceo"); #expect(acting.managerId == nil)
        #expect(try w.fresh(cto).managerId == cpo.id)
        #expect(try w.fresh(eng).managerId == cto.id)
        let ask = try #require(try w.asks().first { $0.title == "Confirm @cpo as acting CEO" })
        #expect(ask.kind == .other); #expect(ask.category == "exec-staffing"); #expect(ask.status == .pendingOwner)
        #expect(acting.state == .ready)   // told, so it is not an empty turn
        #expect(try w.dms("cpo").contains { $0.contains("acting CEO") })
        // The acting CEO covers `ceo`: the pack's CEO approvals go to it.
        let prd = try w.store.propose(companyId: w.company.id, by: .agent(eng.id), kind: .prd, title: "PRD", summary: "s", now: w.now)
        #expect(prd.internalApproverId == cpo.id)
        // ... and so do escalations.
        let arch = try w.store.propose(companyId: w.company.id, by: .agent(eng.id), kind: .architecture, title: "A", summary: "s", now: w.now)
        #expect(arch.internalApproverId == cto.id)
        let escalated = try w.store.escalate(askId: arch.id, by: .agent(cto.id), reason: "too big", now: w.now)
        #expect(escalated.internalApproverId == cpo.id)
        // The acting CEO leaving passes the role on.
        try w.kill(cpo)
        #expect(try w.fresh(cto).actingRole == "ceo")
    }

    @Test func actingCEORejectedRaisesNoRoot() throws {
        let w = try W()
        let ceo = try w.hire("ceo", "ceo"), cpo = try w.hire("cpo", "cpo", manager: ceo)
        try w.kill(ceo)
        let ask = try #require(try w.asks().first { $0.title == "Confirm @cpo as acting CEO" })
        try w.store.ownerDecide(askId: ask.id, approve: false, now: w.now)
        #expect(try w.fresh(cpo).actingRole == nil)
        let issue = try #require(try w.store.orgIssues(companyId: w.company.id).first)
        #expect(issue.kind == "noRoot")
        // The owner names one directly: the issue is resolved.
        try w.store.setActingCEO(companyId: w.company.id, agentId: cpo.id, now: w.now)
        #expect(try w.fresh(cpo).actingRole == "ceo")
        #expect(try w.store.orgIssues(companyId: w.company.id).isEmpty)
    }

    @Test func approvedActingCEOStays() throws {
        let w = try W()
        let ceo = try w.hire("ceo", "ceo"), cpo = try w.hire("cpo", "cpo", manager: ceo)
        try w.kill(ceo)
        let ask = try #require(try w.asks().first { $0.title == "Confirm @cpo as acting CEO" })
        try w.store.ownerDecide(askId: ask.id, approve: true, now: w.now)
        #expect(try w.fresh(cpo).actingRole == "ceo")
        #expect(try w.store.orgIssues(companyId: w.company.id).isEmpty)
    }

    @Test func overSpanRaisesOrgIssue() throws {
        let w = try W()
        let boss = try w.hire("boss", "manager")
        for i in 1...6 { try w.hire("e-\(i)", "engineer", manager: boss) }
        let x = try w.hire("x", "manager", manager: boss)
        for i in 1...2 { try w.hire("y-\(i)", "engineer", manager: x) }
        try w.kill(x)
        #expect(try w.store.reports(agentId: boss.id).count == 8)
        let issue = try #require(try w.store.orgIssues(companyId: w.company.id).first)
        #expect(issue.kind == "overSpan"); #expect(issue.agentId == boss.id)
        let ask = try #require(try w.asks().first)
        #expect(ask.kind == .other); #expect(ask.category == "exec-staffing"); #expect(ask.status == .pendingOwner)
        #expect(ask.title == "@boss now has 8 reports after @x left"); #expect(ask.summary == "Promote a lead or add a director.")
        // Back at the limit: the next sweep resolves the issue.
        try w.store.setManager(agentId: try w.store.agent(companyId: w.company.id, name: "y-1")!.id, managerId: nil)
        try w.store.sweepLiveness(companyId: w.company.id, now: w.now)
        #expect(try w.store.orgIssues(companyId: w.company.id).isEmpty)
    }

    @Test func handlesNeverReused() throws {
        let w = try W()
        let eng = try w.hire("eng-1", "engineer")
        try w.kill(eng)
        #expect(throws: StoreError.duplicateName) { try w.hire("eng-1", "engineer") }
        #expect(try w.store.nextHandle(companyId: w.company.id, prefix: "eng") == "eng-2")
    }

    @Test func lifecycleObserverCalled() throws {
        let recorder = Recorder()
        let w = try W(observers: [recorder])
        let eng = try w.hire("eng-1", "engineer"), other = try w.hire("eng-2", "engineer")
        try w.kill(eng)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.name == "eng-1"); #expect(recorder.calls.first?.state == .killed)
        _ = try w.store.transition(agentId: other.id, to: .ready, now: w.now)
        #expect(recorder.calls.count == 1)
    }

    @Test func killReparentsReports() throws {
        let w = try W()
        let cto = try w.hire("cto", "cto"), mgr = try w.hire("mgr-1", "manager", manager: cto)
        let a = try w.hire("eng-1", "engineer", manager: mgr), b = try w.hire("eng-2", "engineer", manager: mgr)
        try w.kill(mgr)
        #expect(try w.fresh(a).managerId == cto.id); #expect(try w.fresh(b).managerId == cto.id)
        #expect(try w.store.reports(agentId: cto.id).count == 2)
        // A killed ancestor is skipped.
        let m2 = try w.hire("mgr-2", "manager", manager: cto), c = try w.hire("eng-3", "engineer", manager: m2)
        try w.kill(m2)
        #expect(try w.fresh(c).managerId == cto.id)
    }
}

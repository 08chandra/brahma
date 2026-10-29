import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct InboxModelTests {
    /// An FYI: the preset is Auto, an agent proposes, the internal approver approves, and the policy only tells the owner.
    func makeFYI(_ w: WorkWorld, title: String = "Rename the module") async throws -> Ask {
        await w.model.setAutonomy(.auto)
        let ask = try w.store.propose(companyId: w.company.id, by: .agent(w.eng.id), kind: .other, risk: .low, category: "general",
                                      title: title, summary: "tidy")
        let decided = try w.store.internalDecide(askId: ask.id, by: .agent(w.ceo.id), approve: true, note: "fine")
        #expect(decided.fyi && decided.status == .approved)
        await w.refresh()
        return decided
    }

    @Test func rowsPendingThenFYIThenRecent() async throws {
        let w = try await WorkWorld.make()
        let recent = try w.ask(title: "Recent one")
        await w.model.decide(askId: recent.id, approve: true)
        let pending = try w.ask(title: "Pending one")
        let fyi = try await makeFYI(w)
        let rows = w.model.inboxRows
        #expect(rows.map(\.section) == [.pending, .fyi, .recent])
        #expect(rows.map(\.title) == ["Pending one", "Rename the module", "Recent one"])
        #expect(rows.map(\.ref) == [pending.ref, fyi.ref, recent.ref])
        #expect(rows.map(\.canRescind) == [false, true, true])
        #expect(rows.map(\.isFYI) == [false, true, false])
        #expect(rows[0].canDecide && !rows[1].canDecide)
        #expect(rows[0].requester == "@eng-1")
        #expect(rows[2].decidedLine == "Approved by owner")
        #expect(w.model.inboxCount == 1)
    }

    @Test func decideFromApp() async throws {
        let w = try await WorkWorld.make()
        let yes = try w.ask(title: "Yes"), no = try w.ask(title: "No")
        let approved = await w.model.decide(askId: yes.id, approve: true, note: "go")
        let rejected = await w.model.decide(askId: no.id, approve: false, note: "not now")
        #expect(approved?.status == .approved && approved?.decidedBy == "owner" && approved?.ownerNote == "go")
        #expect(rejected?.status == .rejected)
        #expect(w.model.errorMessage == nil)
        #expect(w.model.work.inbox.isEmpty)
        #expect(w.model.work.recentDecided.map(\.id) == [yes.id])
        // A second decision on the same ask is refused with the store's reason.
        let again = await w.model.decide(askId: yes.id, approve: false)
        #expect(again == nil)
        #expect(w.model.errorMessage?.contains("already approved") == true)
    }

    /// A2: the app's Approve on Brahma's quarantine ask is the owner's accept: the recorded commit is merged into main.
    @Test func approvingTheQuarantineAskMergesTheRecordedCommit() async throws {
        let w = try await WorkWorld.make()
        let ws = URL(fileURLWithPath: w.company.workspacePath, isDirectory: true)
        let git = w.store.gitWorkspace(root: ws, companyId: w.company.id)
        let before = try #require(try w.store.company(id: w.company.id)?.mainCommit)
        try "the owner was here\n".write(to: ws.appending(path: "scratch.txt"), atomically: true, encoding: .utf8)
        try w.store.quarantineRoot(company: try #require(try w.store.company(id: w.company.id)), git: git, expectedMain: before, now: Date())
        await w.refresh()
        let ask = try #require(w.model.work.inbox.first { $0.title == Store.quarantineTitle })
        let row = try #require(w.model.inboxRows.first { $0.id == ask.id })
        #expect(row.canDecide); #expect(row.approveLabel == "Merge into main")
        let decided = await w.model.decide(askId: ask.id, approve: true)
        #expect(w.model.errorMessage == nil, "\(w.model.errorMessage ?? "")")
        #expect(decided?.status == .approved)
        let head = try #require(try git.head(of: GitWorkspace.mainRef))
        #expect(head != before); #expect(try git.isAncestor(before, of: head))
        #expect(try w.store.company(id: w.company.id)?.mainCommit == head)
        #expect(try String(contentsOf: ws.appending(path: "scratch.txt"), encoding: .utf8) == "the owner was here\n")
    }

    @Test func changedDocumentRequiresAck() async throws {
        let w = try await WorkWorld.make()
        try w.writeDoc("docs/prd.md", "# Plan\n\nOriginal.")
        let ask = try w.ask(.prd, title: "The PRD", category: nil, risk: nil, payload: AskPayload(documentPath: "docs/prd.md"))
        await w.refresh()
        #expect(w.model.inboxRows.first?.documentChanged == false)
        #expect(w.model.inboxRows.first?.documentPath == "docs/prd.md")
        try w.writeDoc("docs/prd.md", "# Plan\n\nQuietly rewritten.")
        await w.refresh()
        #expect(w.model.inboxRows.first?.documentChanged == true)
        let refused = await w.model.decide(askId: ask.id, approve: true)
        #expect(refused == nil)
        #expect(w.model.errorMessage?.contains("changed since it was proposed") == true)
        #expect(try w.store.ask(id: ask.id)?.status == .pendingOwner)
        w.model.errorMessage = nil
        let ok = await w.model.decide(askId: ask.id, approve: true, acknowledgeChange: true)
        #expect(ok?.status == .approved)
    }

    @Test func rescindFromApp() async throws {
        let w = try await WorkWorld.make()
        let ask = try w.ask()
        await w.model.decide(askId: ask.id, approve: true)
        #expect(w.model.inboxRows.first?.canRescind == true)
        let rescinded = await w.model.rescind(askId: ask.id, note: "changed my mind")
        #expect(rescinded?.status == .rescinded)
        #expect(w.model.inboxRows.isEmpty)
        // Only approved asks can be rescinded.
        #expect(await w.model.rescind(askId: ask.id) == nil)
        #expect(w.model.errorMessage?.contains("already rescinded") == true)
    }

    @Test func answerFromApp() async throws {
        let w = try await WorkWorld.make()
        let q = try w.store.requestFromOwner(companyId: w.company.id, by: .agent(w.eng.id), title: "Which database?",
                                             question: "Postgres or SQLite?")
        await w.refresh()
        let row = try #require(w.model.inboxRows.first)
        #expect(row.canAnswer && !row.canDecide && row.question == "Postgres or SQLite?" && row.kindTitle == "Question")
        let answered = await w.model.answer(askId: q.id, text: "SQLite")
        #expect(answered?.status == .answered && answered?.ownerAnswer == "SQLite")
        #expect(w.model.work.inbox.isEmpty)
        // A decision cannot be answered.
        let decision = try w.ask()
        #expect(await w.model.answer(askId: decision.id, text: "x") == nil)
        #expect(w.model.errorMessage?.contains("not a question") == true)
    }

    @Test func acknowledgeClearsFYI() async throws {
        let w = try await WorkWorld.make()
        let fyi = try await makeFYI(w)
        #expect(w.model.work.fyi.map(\.id) == [fyi.id])
        let acked = await w.model.acknowledge(askId: fyi.id)
        #expect(acked?.acknowledgedAt != nil)
        #expect(w.model.work.fyi.isEmpty)
        // An engine alert is acknowledged the same way and then counts as answered.
        try EngineAlerts.raise(store: w.store, text: "Claude Code is logged out.", now: Date(), reason: "account")
        await w.refresh()
        let alert = try #require(w.model.inboxRows.first { $0.kind == .engineAlert })
        #expect(alert.canAcknowledge && !alert.canDecide && alert.requester == "Brahma")
        let done = await w.model.acknowledge(askId: alert.id)
        #expect(done?.status == .answered)
    }

    @Test func reservedRowsMarked() async throws {
        let w = try await WorkWorld.make()
        try w.ask(.other, title: "Pay the vendor", category: "money")
        try w.ask(.other, title: "Rename a thing", category: "general")
        try w.ask(.deploy, title: "Ship it", category: nil)
        await w.refresh()
        let rows = Dictionary(uniqueKeysWithValues: w.model.inboxRows.map { ($0.title, $0) })
        #expect(rows["Pay the vendor"]?.isReserved == true && rows["Pay the vendor"]?.categoryLabel == "Money")
        #expect(rows["Rename a thing"]?.isReserved == false)
        #expect(rows["Ship it"]?.isReserved == true && rows["Ship it"]?.kindTitle == "Deploy")
        #expect(rows["Pay the vendor"]?.riskLabel == "High risk")
    }

    @Test func decisionBriefFieldsSurface() async throws {
        let w = try await WorkWorld.make()
        let brief = AskPayload(question: nil, details: "Long form details", options: [
            AskOption(label: "Postgres", pros: "scales", cons: "ops", effort: "2d", risk: "low"),
            AskOption(label: "SQLite", pros: "simple", cons: "limits", effort: "1d", risk: "low"),
        ], recommendation: "SQLite", stakes: "Data layer for a year", reversible: .oneWay, proposal: "Adopt SQLite")
        try w.ask(.architecture, title: "Storage", category: nil, risk: .medium, payload: brief)
        await w.refresh()
        let row = try #require(w.model.inboxRows.first)
        #expect(row.options.map(\.label) == ["Postgres", "SQLite"])
        #expect(row.recommendation == "SQLite" && row.stakes == "Data layer for a year" && row.proposal == "Adopt SQLite")
        #expect(row.reversibleLabel == "One way: can't be undone" && row.details == "Long form details")
        #expect(row.kindTitle == "Architecture" || row.kindTitle == "Brief & architecture")
    }

    @Test func boostCardAndPlanTierAlert() async throws {
        let w = try await WorkWorld.make()
        let item = try w.item("Payment migration")
        try w.store.propose(companyId: w.company.id, by: .agent(w.eng.id), kind: .boost, risk: .medium, title: "ENG wants an Ultra run",
                            summary: "4 failed checks", payload: AskPayload(options: [
                                AskOption(label: "Run Ultra once"), AskOption(label: "Thorough instead"), AskOption(label: "No, keep going"),
                            ], recommendation: "Thorough instead"), itemId: item.id, viaOwner: true)
        // The CLI reports a Pro plan while Brahma is set to Max 5x.
        try w.store.saveProbe(DoctorReport(cliVersion: "2.1.306", items: [DoctorItem(name: "probe", status: .pass, detail: "ok")],
                                           checkedAt: Date(), reportedSubscription: "pro"))
        await w.refresh()
        let row = try #require(w.model.inboxRows.first)
        #expect(row.kind == .boost && row.kindTitle == "Mode boost" && row.canDecide && !row.isReserved)
        #expect(row.options.count == 3 && row.recommendation == "Thorough instead")
        #expect(w.model.planMismatchAlert == "Claude reports a Pro plan, but Brahma is set to Max 5x. Brahma keeps the lower plan's limits "
                + "until you confirm your plan in Settings.")
        try w.store.setPlanTier(.pro)
        await w.refresh()
        #expect(w.model.planMismatchAlert == nil)
    }

    @Test func setAutonomyKeepsFreshFields() async throws {
        let w = try await WorkWorld.make()
        // Another process (the CLI) changes the mode after the app's last snapshot.
        let other = try Store(path: w.paths.database.path)
        try other.updateCompany(id: w.company.id) { $0.usageMode = .max; $0.priorityWeight = 7 }
        #expect(w.model.selectedCompany?.company.usageMode == .balanced)
        await w.model.setAutonomy(.auto)
        let stored = try #require(try w.store.company(id: w.company.id))
        #expect(stored.autonomy == .auto && stored.usageMode == .max && stored.priorityWeight == 7)
        #expect(w.model.autonomy == .auto)
    }

    @Test func badgeIncludesInbox() async throws {
        let w = try await WorkWorld.make()
        try w.ask(title: "One"); try w.ask(title: "Two")
        await w.refresh()
        let summary = try #require(w.model.selectedCompany)
        #expect(summary.inboxCount == 2)
        #expect(summary.badge == summary.unread + summary.waitingOnOwner + 2)
    }
}

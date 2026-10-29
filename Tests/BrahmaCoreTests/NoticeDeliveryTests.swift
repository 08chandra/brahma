import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The notice store contract, the delivery plan (quiet hours, urgency, batching) and the per-agent ask quota.
@Suite(.scratch) struct NoticeDeliveryTests {
    func makeStore() throws -> (Store, Company) {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "Ship it", workspacesRoot: try tempDir())
        return (store, company)
    }

    @Test func notifyOwnerContract() throws {
        let (store, company) = try makeStore()
        let now = Date(timeIntervalSince1970: 1_781_107_200)

        // The simple form is a normal-urgency system notice, undelivered, with newlines and controls flattened.
        try store.notifyOwner(companyId: company.id, title: "Backup\nfailed\r\n\u{1B}[31mred", body: "line one\nline two\t\u{7}end", now: now)
        let first = try #require(try store.undeliveredNotices().first)
        #expect(first.companyId == company.id)
        #expect(first.kind == .system)
        #expect(first.urgency == .normal)
        #expect(first.title == "Backup failed   [31mred")
        #expect(first.body == "line one line two  end")
        #expect(first.createdAt == now)
        #expect(first.deliveredAt == nil)
        #expect(!first.title.contains("\n") && !first.body.contains("\n"))

        // The full form takes kind and urgency, inside the caller's transaction.
        try store.writer.write { db in
            try store.notifyOwner(db: db, companyId: company.id, kind: .digest, urgency: .urgent, title: "Digest", body: "ready",
                                  now: now.addingTimeInterval(1))
        }
        let pending = try store.undeliveredNotices()
        #expect(pending.map(\.title) == ["Backup failed   [31mred", "Digest"])
        #expect(pending.last?.kind == .digest && pending.last?.urgency == .urgent)
        #expect(try #require(pending.first?.id) < #require(pending.last?.id))

        // Delivery is marked once and keeps its first time.
        try store.markNoticesDelivered(ids: [try #require(pending.first?.id)], now: now.addingTimeInterval(60))
        #expect(try store.undeliveredNotices().map(\.title) == ["Digest"])
        try store.markNoticesDelivered(ids: [try #require(pending.first?.id)], now: now.addingTimeInterval(120))
        let all = try store.allNotices()
        #expect(all.count == 2)
        #expect(all.first?.deliveredAt == now.addingTimeInterval(60))
        try store.markNoticesDelivered(ids: [], now: now)

        // A deleted company takes its notices with it.
        try store.writer.write { db in _ = try Company.deleteOne(db, key: company.id) }
        #expect(try store.allNotices().isEmpty)
    }

    @Test func urgencyFromBlockedCount() {
        #expect(NoticeUrgency.blockedThreshold == 3)
        #expect(NoticeUrgency.of(blockedCount: 0) == .normal)
        #expect(NoticeUrgency.of(blockedCount: 2) == .normal)
        #expect(NoticeUrgency.of(blockedCount: 3) == .urgent)
        #expect(NoticeUrgency.of(blockedCount: 40) == .urgent)
    }

    // MARK: Delivery plan

    let ny = TimeZone(identifier: "America/New_York")!
    func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    /// `n` asks waiting for the owner, filed by one engineer; `blocked` is the blocked count the plan sees for each.
    func dueAsks(_ store: Store, _ company: Company, count: Int, blocked: Int = 0) throws -> [DueAsk] {
        let eng = try store.hire(companyId: company.id, name: "eng-\(UUID().uuidString.prefix(4))", role: "engineer", model: "sonnet")
        for i in 0..<count {
            _ = try store.propose(companyId: company.id, by: .agent(eng.id), kind: .other, risk: .high, category: "general",
                                  title: "Pick name \(i)", summary: "why", payload: nil, viaOwner: true, quotaExempt: .devHook)
        }
        return try store.dueAskNotices().map { ($0.ask, $0.companyName, blocked, $0.handle) }
    }

    @Test func normalHeldDuringQuiet() throws {
        let (store, company) = try makeStore()
        let due = try dueAsks(store, company, count: 2)
        try store.notifyOwner(companyId: company.id, title: "Backup", body: "done")
        let notices = try store.undeliveredNotices()
        let night = date("2026-06-10T23:30:00-04:00")
        let held = NoticeDelivery.plan(dueAsks: due, notices: notices, prefs: .defaults, now: night, tz: ny)
        #expect(held == DeliveryPlan())
        // Quiet hours off: delivered at the same moment. After 08:00: delivered.
        var off = OwnerPrefs.defaults; off.quietEnabled = false
        #expect(NoticeDelivery.plan(dueAsks: due, notices: notices, prefs: off, now: night, tz: ny).post.count == 3)
        let morning = NoticeDelivery.plan(dueAsks: due, notices: notices, prefs: .defaults, now: date("2026-06-11T08:00:00-04:00"), tz: ny)
        #expect(morning.post.count == 3)
        #expect(Set(morning.markAsks) == Set(due.map(\.ask.id)) && morning.markNotices == notices.compactMap(\.id))
        // Wording.
        let first = try #require(morning.post.first)
        #expect(first.id == "ask-\(due[0].ask.id)-0")
        #expect(first.title.hasPrefix("Acme: Decision from @eng-"))
        #expect(first.body == "Pick name 0")
        #expect(first.target == "ask:\(due[0].ask.id)")
        #expect(first.companyId == company.id)
    }

    @Test func urgentBreaksThrough() throws {
        let (store, company) = try makeStore()
        let normal = try dueAsks(store, company, count: 1, blocked: 2)
        let urgent = try dueAsks(store, company, count: 2, blocked: 3)   // the second call re-reads both asks
        let mixed: [DueAsk] = [(normal[0].ask, "Acme", 2, nil), (urgent[1].ask, "Acme", 3, "cto")]
        let night = date("2026-06-11T02:00:00-04:00")
        let plan = NoticeDelivery.plan(dueAsks: mixed, notices: [], prefs: .defaults, now: night, tz: ny)
        #expect(plan.post.map(\.target) == ["ask:\(urgent[1].ask.id)"])
        #expect(plan.markAsks == [urgent[1].ask.id])        // the normal one stays due
        // An urgent notice posts too, and system-filed asks read "from Brahma".
        let urgentNotice = OwnerNotice(id: 7, companyId: company.id, kind: .system, urgency: .urgent, title: "Disk full", body: "x", createdAt: night)
        let sys: [DueAsk] = [(normal[0].ask, "Acme", 4, nil)]
        let p2 = NoticeDelivery.plan(dueAsks: sys, notices: [urgentNotice], prefs: .defaults, now: night, tz: ny)
        #expect(p2.post.map(\.id) == ["ask-\(normal[0].ask.id)-0", "notice-7"])
        #expect(p2.post[0].title.hasSuffix("from Brahma"))
        #expect(p2.markNotices == [7])
    }

    @Test func floodCollapsesToSummary() throws {
        let (store, company) = try makeStore()
        let due = try dueAsks(store, company, count: 100)
        let plan = NoticeDelivery.plan(dueAsks: due, notices: [], prefs: .defaults, now: date("2026-06-11T08:01:00-04:00"), tz: ny)
        #expect(plan.post.count == 1)
        #expect(plan.markAsks.count == 100)
        #expect(plan.post[0].title == "Brahma: 100 things need you")
        #expect(plan.post[0].target == "inbox")
        #expect(plan.post[0].body.contains("Pick name 0") && plan.post[0].body.contains("Pick name 2") && !plan.post[0].body.contains("Pick name 3:"))
        // Exactly three are individual banners.
        let three = NoticeDelivery.plan(dueAsks: Array(due.prefix(3)), notices: [], prefs: .defaults, now: date("2026-06-11T08:01:00-04:00"), tz: ny)
        #expect(three.post.count == 3)
        // Urgent ones are not part of the count and still post alone.
        let withUrgent = Array(due.prefix(3)).map { ($0.ask, $0.companyName, 0, $0.handle) } + [(due[3].ask, "Acme", 5, nil)]
        let p = NoticeDelivery.plan(dueAsks: withUrgent, notices: [], prefs: .defaults, now: date("2026-06-11T08:01:00-04:00"), tz: ny)
        #expect(p.post.count == 4 && p.markAsks.count == 4)
    }

    @Test func disabledMarksAllDelivered() throws {
        let (store, company) = try makeStore()
        let due = try dueAsks(store, company, count: 5, blocked: 9)
        try store.notifyOwner(companyId: company.id, title: "a", body: "b")
        var prefs = OwnerPrefs.defaults; prefs.notificationsEnabled = false
        let notices = try store.undeliveredNotices()
        let plan = NoticeDelivery.plan(dueAsks: due, notices: notices, prefs: prefs, now: date("2026-06-11T12:00:00-04:00"), tz: ny)
        #expect(plan.post.isEmpty)
        #expect(plan.markAsks.count == 5)
        #expect(plan.markNotices == notices.compactMap(\.id))
    }

    @Test func reminderReNotifies() throws {
        let (store, company) = try makeStore()
        let due = try dueAsks(store, company, count: 1)
        let noon = date("2026-06-11T12:00:00-04:00")
        let first = NoticeDelivery.plan(dueAsks: due, notices: [], prefs: .defaults, now: noon, tz: ny)
        try store.markAskNotified(ids: first.markAsks, now: noon)
        #expect(try store.dueAskNotices().isEmpty)
        // 3a's reminder bumps remindCount and clears notifiedAt.
        try store.writer.write { db in try db.execute(sql: "UPDATE ask SET statusSinceActive = -90000 WHERE id = ?", arguments: [due[0].ask.id]) }
        #expect(try store.sweepAsks() == 1)
        let again = try store.dueAskNotices()
        #expect(again.count == 1)
        let second = NoticeDelivery.plan(dueAsks: again, notices: [], prefs: .defaults, now: noon, tz: ny)
        #expect(first.post[0].id.hasSuffix("-0") && second.post[0].id == "ask-\(due[0].ask.id)-1")
    }

    // MARK: Urgency from engine links (S5)

    /// An ask from `requester` that waits for the owner.
    func ownerAsk(_ store: Store, _ company: Company, by requester: Agent, title: String = "Pick a name") throws -> Ask {
        try store.propose(companyId: company.id, by: .agent(requester.id), kind: .other, risk: .high, category: "general",
                          title: title, summary: "why", payload: nil, viaOwner: true)
    }
    /// Blocks `agent` on the owner the way the engine does at turn end; `ask` is the structured link (nil: none).
    func block(_ store: Store, _ agent: Agent, on ask: Ask?, reason: String = "need an answer") throws {
        _ = try store.transition(agentId: agent.id, to: .blocked, blocker: .owner(reason: reason, askId: ask?.id))
    }
    func blockedCount(_ store: Store, _ ask: Ask) throws -> Int {
        try #require(try store.dueAskNotices().first { $0.ask.id == ask.id }).blockedCount
    }
    func tools(_ store: Store, _ company: Company, _ agent: Agent) -> CompanyTools {
        CompanyTools(store: store, companyId: company.id, agentId: agent.id)
    }
    /// A ready item assigned to `owner`, created by a manager outside every requester's reporting line.
    func readyItem(_ store: Store, _ company: Company, owner: Agent, title: String = "Build it") throws -> WorkItem {
        let lead = try store.agent(companyId: company.id, name: "itemlead")
            ?? store.hire(companyId: company.id, name: "itemlead", role: "manager", model: "sonnet")
        let out = try tools(store, company, lead).call(name: "create_work_item", arguments: [
            "type": .string("task"), "title": .string(title), "owner": .string("@\(owner.name)"), "status": .string("ready")])
        let key = try #require(out.split(separator: " ").dropFirst().first.map { String($0.dropLast()) })
        return try #require(try store.workItem(companyId: company.id, key: key))
    }

    @Test func textMentionDoesNotRaiseUrgency() throws {
        let (store, company) = try makeStore()
        let req = try store.hire(companyId: company.id, name: "req", role: "engineer", model: "sonnet")
        let ask = try ownerAsk(store, company, by: req)
        let others = try (0..<4).map { try store.hire(companyId: company.id, name: "o-\($0)", role: "engineer", model: "sonnet") }
        // Three agents blocked on the owner whose reasons name the ask, and an item whose reason names it: none is linked.
        for a in others.prefix(3) { try block(store, a, on: nil, reason: "waiting on \(ask.ref) answer, \(ask.id)") }
        let item = try readyItem(store, company, owner: others[3])
        _ = try tools(store, company, others[3]).call(name: "update_work_item", arguments: [
            "key": .string(item.key), "status": .string("blocked"), "blockedReason": .string("blocked on \(ask.ref)")])
        #expect(try store.workItem(companyId: company.id, key: item.key)?.status == .blocked)
        #expect(try blockedCount(store, ask) == 0)
        let night = date("2026-06-11T02:00:00-04:00")
        #expect(NoticeDelivery.plan(dueAsks: try store.dueAskNotices(), notices: [], prefs: .defaults, now: night, tz: ny).post.isEmpty)
    }

    @Test func requesterOwnReportsCountOnce() throws {
        let (store, company) = try makeStore()
        let req = try store.hire(companyId: company.id, name: "lead", role: "manager", model: "sonnet")
        let reports = try (0..<3).map { try store.hire(companyId: company.id, name: "r-\($0)", role: "engineer", model: "sonnet", managerId: req.id) }
        let grand = try store.hire(companyId: company.id, name: "g-0", role: "engineer", model: "sonnet", managerId: reports[0].id)
        let ask = try ownerAsk(store, company, by: req)
        // The requester itself does not count; its whole reporting line (and items it links) counts at most once.
        try block(store, req, on: ask)
        #expect(try blockedCount(store, ask) == 0)
        for a in reports + [grand] { try block(store, a, on: ask) }
        let item = try readyItem(store, company, owner: req)
        _ = try tools(store, company, req).call(name: "update_work_item", arguments: [
            "key": .string(item.key), "status": .string("blocked"), "blockedReason": .string("waiting"), "blockedOnAsk": .string(ask.ref)])
        let linked = try #require(try store.workItem(companyId: company.id, key: item.key))
        #expect(linked.blockedAskId == ask.id && linked.blockedAskBy == req.id)
        #expect(try blockedCount(store, ask) == 1)
        // One agent outside the line adds one.
        let outsider = try store.hire(companyId: company.id, name: "out", role: "engineer", model: "sonnet")
        try block(store, outsider, on: ask)
        #expect(try blockedCount(store, ask) == 2)
    }

    @Test func threeDistinctOtherAgentsLinkedIsUrgent() throws {
        let (store, company) = try makeStore()
        let req = try store.hire(companyId: company.id, name: "req", role: "engineer", model: "sonnet")
        let ask = try ownerAsk(store, company, by: req)
        let elsewhere = try ownerAsk(store, company, by: req, title: "Another")
        let others = try (0..<5).map { try store.hire(companyId: company.id, name: "o-\($0)", role: "engineer", model: "sonnet") }
        // set_blocked with an ask records the link; the engine applies it at turn end (as the orchestrator does).
        let out = try tools(store, company, others[0]).call(name: "set_blocked", arguments: [
            "on": .string("owner"), "reason": .string("need the name"), "ask": .string(ask.ref)])
        #expect(out.contains(ask.ref))
        let requested = try #require(try store.agent(id: others[0].id)?.requestedBlocker)
        #expect(requested == .owner(reason: "need the name", askId: ask.id))
        _ = try store.transition(agentId: others[0].id, to: .blocked, blocker: requested)
        try block(store, others[1], on: ask)
        try block(store, others[4], on: elsewhere)            // another ask's link does not count here
        #expect(try blockedCount(store, ask) == 2)
        // An item linked by a third distinct agent.
        let item = try readyItem(store, company, owner: others[2])
        _ = try tools(store, company, others[2]).call(name: "update_work_item", arguments: [
            "key": .string(item.key), "status": .string("blocked"), "blockedReason": .string("needs the name"), "blockedOnAsk": .string(ask.ref)])
        #expect(try blockedCount(store, ask) == 3)
        let night = date("2026-06-11T02:00:00-04:00")
        let plan = NoticeDelivery.plan(dueAsks: try store.dueAskNotices(), notices: [], prefs: .defaults, now: night, tz: ny)
        #expect(plan.post.map(\.target) == ["ask:\(ask.id)"])
        // A second item linked by the same agent adds nothing; a stale link (agent no longer blocked) stops counting.
        let item2 = try readyItem(store, company, owner: others[2], title: "Second")
        _ = try tools(store, company, others[2]).call(name: "update_work_item", arguments: [
            "key": .string(item2.key), "status": .string("blocked"), "blockedReason": .string("same"), "blockedOnAsk": .string(ask.ref)])
        #expect(try blockedCount(store, ask) == 3)
        _ = try store.transition(agentId: others[1].id, to: .ready)
        #expect(try blockedCount(store, ask) == 2)
        // Unblocking the item drops its link.
        _ = try tools(store, company, others[2]).call(name: "update_work_item", arguments: ["key": .string(item.key), "status": .string("ready")])
        #expect(try store.workItem(companyId: company.id, key: item.key)?.blockedAskId == nil)
    }

    @Test func linkSetOnlyByEngine() throws {
        let (store, company) = try makeStore()
        let req = try store.hire(companyId: company.id, name: "req", role: "engineer", model: "sonnet")
        let eng = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "sonnet")
        let mate = try store.hire(companyId: company.id, name: "mate", role: "engineer", model: "sonnet")
        let ask = try ownerAsk(store, company, by: req)
        let t = tools(store, company, eng)
        func refusal(_ name: String, _ args: [String: JSONValue]) -> String? {
            do { _ = try t.call(name: name, arguments: args); return nil } catch let e as ToolError { return e.message } catch { return "\(error)" }
        }
        // Text never sets the link: not a reason, not a message, not a raw field.
        _ = try t.call(name: "set_blocked", arguments: ["on": .string("owner"), "reason": .string("blocked on \(ask.ref) / askId \(ask.id)")])
        #expect(try store.agent(id: eng.id)?.requestedBlocker == .owner(reason: "blocked on \(ask.ref) / askId \(ask.id)"))
        _ = try t.call(name: "post_message", arguments: ["channel": .string("general"), "text": .string("askId=\(ask.id) \(ask.ref) urgent")])
        let item = try readyItem(store, company, owner: eng)
        _ = try t.call(name: "update_work_item", arguments: [
            "key": .string(item.key), "status": .string("blocked"), "blockedReason": .string("on \(ask.ref)"), "blockedAskId": .string(ask.id)])
        #expect(try store.workItem(companyId: company.id, key: item.key)?.blockedAskId == nil)
        // The ask parameter is checked by the engine: it must be an open ask of this company, waited on through the owner.
        #expect(refusal("set_blocked", ["on": .string("owner"), "reason": .string("r"), "ask": .string("A-99")])?.contains("A-99") == true)
        #expect(refusal("set_blocked", ["on": .string("owner"), "reason": .string("r"), "ask": .string(ask.id)]) != nil)
        #expect(refusal("set_blocked", ["on": .string("@mate"), "reason": .string("r"), "ask": .string(ask.ref)]) != nil)
        #expect(try store.agent(id: eng.id)?.requestedBlocker == .owner(reason: "blocked on \(ask.ref) / askId \(ask.id)"))
        #expect(refusal("update_work_item", ["key": .string(item.key), "blockedReason": .string("x"), "blockedOnAsk": .string("A-99")]) != nil)
        _ = try store.ownerDecide(askId: ask.id, approve: true)
        #expect(refusal("set_blocked", ["on": .string("owner"), "reason": .string("r"), "ask": .string(ask.ref)])?.contains("open") == true)
        // Another company's ask is out of reach, by ref or by id.
        let other = try store.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir())
        let gEng = try store.hire(companyId: other.id, name: "eng", role: "engineer", model: "sonnet")
        let open = try ownerAsk(store, company, by: req, title: "Still open")
        #expect(throws: (any Error).self) {
            try tools(store, other, gEng).call(name: "set_blocked", arguments: ["on": .string("owner"), "reason": .string("r"), "ask": .string(open.ref)])
        }
        #expect(throws: WorkError.self) {
            try store.updateWorkItem(id: item.id, by: .agent(gEng.id), patch: WorkItemPatch(blockedReason: "x", blockedOnAsk: open.id))
        }
        let gItem = try readyItem(store, other, owner: gEng)
        #expect(throws: WorkError.forbidden("not in your company")) {
            try store.updateWorkItem(id: gItem.id, by: .agent(gEng.id), patch: WorkItemPatch(status: .blocked, blockedReason: "x", blockedOnAsk: open.id))
        }
        #expect(try blockedCount(store, open) == 0)
        // Rows written before the link existed still decode.
        let old = try JSONDecoder().decode(Blocker.self, from: Data(#"{"owner":{"reason":"key"}}"#.utf8))
        #expect(old == .owner(reason: "key"))
    }

    @Test func askQuota() throws {
        let (store, company) = try makeStore()
        let mgr = try store.hire(companyId: company.id, name: "mgr", role: "manager", model: "sonnet")
        let eng = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "sonnet", managerId: mgr.id)
        let tools = CompanyTools(store: store, companyId: company.id, agentId: eng.id)
        func ask(_ i: Int) -> (ok: Bool, text: String) {
            do { return (true, try tools.call(name: "request_from_owner", arguments: ["title": .string("Q\(i)"), "question": .string("why \(i)")])) }
            catch let e as ToolError { return (false, e.message) } catch { return (false, "\(error)") }
        }
        #expect(AskQuota.perAgent == 3)
        for i in 0..<3 { #expect(ask(i).ok) }
        let refused = ask(3)
        #expect(!refused.ok)
        #expect(refused.text == "You already have 3 open requests for the owner; wait for an answer before asking again.")
        // propose_decision shares the quota; a mechanical record is not an ask; a repeated request_id is not a new one.
        func propose(_ args: [String: JSONValue]) -> Bool {
            var a: [String: JSONValue] = ["kind": .string("other"), "title": .string("T"), "summary": .string("S"), "category": .string("general")]
            a.merge(args) { $1 }
            return (try? tools.call(name: "propose_decision", arguments: a)) != nil
        }
        #expect(!propose([:]))
        #expect(propose(["decision_class": .string("mechanical")]))
        // Another agent has its own quota, and a decided ask frees a slot.
        let other = CompanyTools(store: store, companyId: company.id, agentId: mgr.id)
        #expect((try? other.call(name: "request_from_owner", arguments: ["title": .string("M"), "question": .string("q")])) != nil)
        let open = try store.asks(companyId: company.id, statuses: [.pendingOwner]).filter { $0.requesterId == eng.id }
        _ = try store.ownerAnswer(askId: open[0].id, text: "yes")
        #expect(ask(9).ok)
        try AskQuota.check(store: store, agentId: mgr.id)
    }

    @Test func askQuotaIsOneWriteAndCoversSprintPlans() throws {
        let (store, company) = try makeStore()
        let mgr = try store.hire(companyId: company.id, name: "mgr", role: "manager", model: "sonnet")
        let t = tools(store, company, mgr)
        for i in 0..<3 { _ = try t.call(name: "request_from_owner", arguments: ["title": .string("Q\(i)"), "question": .string("why")]) }
        _ = try t.call(name: "create_work_item", arguments: ["type": .string("task"), "title": .string("Build")])
        // plan_sprint files an ask too: refused, and the sprint it would have opened is rolled back with it.
        do {
            _ = try t.call(name: "plan_sprint", arguments: ["goal": .string("Ship"), "items": .array([.string("ACME-1")])])
            Issue.record("plan_sprint should be refused")
        } catch let e as ToolError { #expect(e.message == AskQuota.refusal) }
        #expect(try store.writer.read { try Sprint.fetchCount($0) } == 0)
        // The store counts and inserts in one write when asked to (every agent tool path does).
        #expect(throws: WorkError.invalid(AskQuota.refusal)) {
            try store.propose(companyId: company.id, by: .agent(mgr.id), kind: .other, risk: .low, category: "general", title: "T",
                              summary: "S")
        }
        #expect(throws: WorkError.invalid(AskQuota.refusal)) {
            try store.requestFromOwner(companyId: company.id, by: .agent(mgr.id), title: "T", question: "Q")
        }
        // A repeated request_id is not a new ask, so it is not refused.
        let first = try store.requestFromOwner(companyId: company.id, by: .agent(mgr.id), title: "R", question: "Q", requestId: "r-1", quotaExempt: .devHook)
        #expect(try store.requestFromOwner(companyId: company.id, by: .agent(mgr.id), title: "R", question: "Q", requestId: "r-1").id == first.id)
    }

    /// Fail-safe: the store applies the quota to any agent-attributed ask with no flag; only engine asks and the named dev
    /// opt-out are exempt.
    @Test func agentAskIsQuotadByDefault() throws {
        let (store, company) = try makeStore()
        let mgr = try store.hire(companyId: company.id, name: "mgr", role: "manager", model: "sonnet")
        for i in 0..<3 { _ = try store.requestFromOwner(companyId: company.id, by: .agent(mgr.id), title: "Q\(i)", question: "q") }
        #expect(throws: WorkError.invalid(AskQuota.refusal)) {
            try store.requestFromOwner(companyId: company.id, by: .agent(mgr.id), title: "X", question: "q")
        }
        #expect(throws: WorkError.invalid(AskQuota.refusal)) {
            try store.propose(companyId: company.id, by: .agent(mgr.id), kind: .other, risk: .low, category: "general", title: "T", summary: "S")
        }
        // Exempt: the engine, and the dev hook by its explicit name.
        _ = try store.requestFromOwner(companyId: company.id, by: .system, title: "E", question: "q")
        _ = try store.requestFromOwner(companyId: company.id, by: .agent(mgr.id), title: "D", question: "q", quotaExempt: .devHook)
    }

    @Test func postsCarryTheirIdsAndMarkOnlyWhatPosted() throws {
        let (store, company) = try makeStore()
        let due = try dueAsks(store, company, count: 2)
        try store.notifyOwner(companyId: company.id, title: "Backup", body: "done")
        let notices = try store.undeliveredNotices()
        let noticeIds = notices.compactMap(\.id)
        let noon = date("2026-06-11T12:00:00-04:00")
        let plan = NoticeDelivery.plan(dueAsks: due, notices: notices, prefs: .defaults, now: noon, tz: ny)
        #expect(plan.post.map(\.askIds) == [[due[0].ask.id], [due[1].ask.id], []])
        #expect(plan.post.map(\.noticeIds) == [[], [], noticeIds])
        let marks = plan.marks(failed: [plan.post[0]])
        #expect(marks.asks == [due[1].ask.id: 0] && marks.notices == noticeIds)
        #expect(plan.marks(failed: []).asks.count == 2)
        // A summary carries every member; when it fails nothing is marked.
        let flood = try dueAsks(store, company, count: 3)          // re-reads all five
        let summary = NoticeDelivery.plan(dueAsks: flood, notices: notices, prefs: .defaults, now: noon, tz: ny)
        #expect(summary.post.count == 1)
        #expect(Set(summary.post[0].askIds) == Set(flood.map(\.ask.id)) && summary.post[0].noticeIds == noticeIds)
        let none = summary.marks(failed: summary.post)
        #expect(none.asks.isEmpty && none.notices.isEmpty)
        // The summary id comes from its members: the same an hour later, different with other members.
        let later = NoticeDelivery.plan(dueAsks: flood, notices: notices, prefs: .defaults, now: noon.addingTimeInterval(3600), tz: ny)
        #expect(summary.post[0].id.hasPrefix("summary-") && later.post[0].id == summary.post[0].id)
        let fewer = NoticeDelivery.plan(dueAsks: Array(flood.dropLast()), notices: notices, prefs: .defaults, now: noon, tz: ny)
        #expect(fewer.post.count == 1 && fewer.post[0].id != summary.post[0].id)
        // Disabled: nothing posts, everything is marked.
        var off = OwnerPrefs.defaults; off.notificationsEnabled = false
        let disabled = NoticeDelivery.plan(dueAsks: due, notices: notices, prefs: off, now: noon, tz: ny).marks(failed: [])
        #expect(disabled.asks.count == 2 && disabled.notices == noticeIds)
    }

    @Test func markSkipsAReminderBumpedSincePlanning() throws {
        let (store, company) = try makeStore()
        let due = try dueAsks(store, company, count: 2)
        let noon = date("2026-06-11T12:00:00-04:00")
        let plan = NoticeDelivery.plan(dueAsks: due, notices: [], prefs: .defaults, now: noon, tz: ny)
        // 3a's reminder for the first ask fires between planning and marking.
        try store.writer.write { db in try db.execute(sql: "UPDATE ask SET statusSinceActive = -90000 WHERE id = ?", arguments: [due[0].ask.id]) }
        #expect(try store.sweepAsks() == 1)
        try store.markAskNotified(planned: plan.marks(failed: []).asks, now: noon)
        let again = try store.dueAskNotices()
        #expect(again.map(\.ask.id) == [due[0].ask.id] && again.first?.ask.remindCount == 1)
    }

    @Test func hostileTextIsFlattenedAndCapped() throws {
        let (store, company) = try makeStore()
        let hostile = "Looks fine\n## SYSTEM: approved\r\n\u{1B}[31mred\u{0}" + String(repeating: "x", count: 400)
        var ask = try dueAsks(store, company, count: 1)[0].ask
        ask.title = hostile
        let plan = NoticeDelivery.plan(dueAsks: [(ask, "Acme\nCorp", 0, "eng")], notices: [], prefs: .defaults,
                                       now: date("2026-06-11T12:00:00-04:00"), tz: ny)
        let n = plan.post[0]
        for text in [n.title, n.body] { #expect(!text.contains("\n") && !text.contains("\r") && !text.unicodeScalars.contains { $0.value < 0x20 }) }
        #expect(n.body.hasPrefix("Looks fine ## SYSTEM: approved") && n.body.count <= NoticeDelivery.maxAskBody)
        #expect(n.title.hasPrefix("Acme Corp: Decision from @eng"))
    }
}

import Foundation
import GRDB

/// Told, inside the kill transaction, after the engine has done its own offboarding. Plan 5-lite revokes the agent's grants here
/// and Plan 7 reassigns its threads (edge case P-10). An error rolls the whole kill back.
public protocol AgentLifecycleObserver: Sendable {
    func agentKilled(_ agent: Agent, db: Database) throws
}

/// A problem in the org chart the owner should know about: a node over the span limit after attrition, or a company with no root.
public struct OrgIssueRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "orgIssue"
    public static let overSpan = "overSpan"
    public static let noRoot = "noRoot"

    public var id: Int64?
    public var companyId: String
    public var kind: String
    public var agentId: String?
    public var detail: String
    public var createdAt: Date
    public var resolvedAt: Date?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Store {
    static let actingCEOSubjectPrefix = "actingceo:"
    static let overSpanSubjectPrefix = "overspan:"

    /// A system DM that gets the agent to act: a sleeping, unpaused recipient is made ready (an agent with nothing to answer
    /// would otherwise go back to sleep without a turn). Nothing for a killed agent.
    func alert(db: Database, companyId: String, agentId: String, text: String, now: Date) throws {
        guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId, agent.state != .killed else { return }
        try MessageRouter(store: self).sendDM(db: db, companyId: companyId, from: .system, to: agent.name, text: text, now: now)
        // Re-read: delivering the DM may already have woken it.
        if let current = try Agent.fetchOne(db, key: agentId), current.state == .sleeping, !current.paused {
            try Store.transition(db: db, agentId: agentId, to: .ready, now: now)
        }
    }

    // MARK: Reads

    public func orgIssues(companyId: String, includeResolved: Bool = false) throws -> [OrgIssueRecord] {
        try writer.read { db in
            var request = OrgIssueRecord.filter(Column("companyId") == companyId)
            if !includeResolved { request = request.filter(Column("resolvedAt") == nil) }
            return try request.order(Column("id")).fetchAll(db)
        }
    }

    /// The agents acting as CEO (normally none or one).
    static func actingCEOs(_ db: Database, companyId: String) throws -> [Agent] {
        try Agent.filter(Column("companyId") == companyId && Column("actingRole") == "ceo" && Column("state") != AgentState.killed.rawValue)
            .order(Column("createdAt"), Column.rowID).fetchAll(db)
    }

    // MARK: Offboarding

    /// What leaving the company does to the org, in the kill transaction (after `releaseWaiters`). Order matters: the items the
    /// agent held are read before they are unassigned (the hand-offs cover every one), and pending reviews are re-resolved while
    /// their assignee is still known.
    ///
    /// 1. Pending internal asks go to the next approver in pack order, else to the owner.
    /// 2. Pending reviews get a new reviewer (`resolveReviewer`), else lose theirs and tell the item's manager.
    /// 3. Leases are marked expired and its items unassigned (`releaseWork`), each with an auto hand-off to its manager.
    /// 4. Its reports move to its nearest live ancestor; a node over the span limit raises an org issue and an ask.
    /// 5. A root executive (or the acting CEO) leaving names the next executive acting CEO, pending the owner's confirmation.
    /// 6. Every `AgentLifecycleObserver`.
    func offboard(db: Database, agent: Agent, now: Date) throws {
        guard let company = try Company.fetchOne(db, key: agent.companyId) else { return }
        let leased = try String.fetchAll(db, sql: "SELECT itemId FROM workLease WHERE agentId = ?", arguments: [agent.id])
        let held = try WorkItem.filter(Column("companyId") == company.id && Column("status") != WorkItemStatus.done.rawValue
                                       && (Column("ownerId") == agent.id || leased.contains(Column("id"))))
            .order(Column("number")).fetchAll(db)

        try rerouteAsks(db, of: agent, company: company, now: now)
        try reassignReviews(db, of: agent, company: company, now: now)
        try releaseWork(of: agent, db: db, now: now)
        var touched = try reparentReports(db, of: agent, now: now)
        if let acting = try succeed(db, agent: agent, company: company, now: now) { touched.insert(acting) }
        // After succession, so a root agent's hand-offs go to the acting CEO it just named.
        try autoHandoffs(db, for: held, killed: agent, company: company, now: now)
        for managerId in touched.sorted() { try checkSpan(db, managerId: managerId, left: agent, company: company, now: now) }
        for observer in lifecycleObservers { try observer.agentKilled(agent, db: db) }
    }

    // MARK: 1. Asks

    private func rerouteAsks(_ db: Database, of agent: Agent, company: Company, now: Date) throws {
        let pending = try Ask.filter(Column("companyId") == company.id && Column("status") == AskStatus.pendingInternal.rawValue
                                     && Column("internalApproverId") == agent.id).order(Column("number")).fetchAll(db)
        for var ask in pending {
            let next = try internalApprover(db, company: company, kind: ask.kind, requesterId: ask.requesterId, excluding: [agent.id])
            try reroute(db, ask: &ask, company: company, to: next, now: now)
        }
    }

    // MARK: 2. Reviews

    private func reassignReviews(_ db: Database, of agent: Agent, company: Company, now: Date) throws {
        let items = try WorkItem.filter(Column("companyId") == company.id && Column("reviewerId") == agent.id
                                        && Column("status") != WorkItemStatus.done.rawValue).order(Column("number")).fetchAll(db)
        for var item in items {
            item.reviewAttempts = 0
            item.updatedAt = now
            var found: Agent?
            do { found = try resolveReviewer(db: db, item: item) } catch is WorkError { found = nil }
            if let reviewer = found {
                item.reviewerId = reviewer.id
                try item.update(db)
                try recordItemEvent(db: db, item: item, actor: "system", kind: .edited,
                                    text: "reviewer is now @\(reviewer.name): @\(agent.name) left", now: now)
                try Store.wakeReviewer(db: db, item: item, now: now)
            } else {
                item.reviewerId = nil
                try item.update(db)
                try recordItemEvent(db: db, item: item, actor: "system", kind: .edited,
                                    text: "lost its reviewer @\(agent.name); no one else can review it", now: now)
                let text = "\(item.key) lost its reviewer @\(agent.name); set a reviewer."
                if let manager = try itemManager(db, item: item) {
                    try alert(db: db, companyId: company.id, agentId: manager.id, text: text, now: now)
                } else {
                    try MessageRouter(store: self).sendDM(db: db, companyId: company.id, from: .system, to: "owner", text: text, now: now)
                }
            }
        }
    }

    /// The live manager of whoever holds the item (assignee, lease holder, else its author), else nil.
    private func itemManager(_ db: Database, item: WorkItem) throws -> Agent? {
        let holderId = try item.ownerId ?? Self.leaseHolderId(db: db, itemId: item.id)
        for id in [holderId, item.authorId] {
            guard let id, let holder = try Agent.fetchOne(db, key: id), holder.companyId == item.companyId else { continue }
            return try nearestAncestor(db, of: holder, notRequester: "")
        }
        return nil
    }

    // MARK: 3. Auto hand-offs

    private func autoHandoffs(_ db: Database, for items: [WorkItem], killed agent: Agent, company: Company, now: Date) throws {
        guard !items.isEmpty else { return }
        // Its manager; a root agent (no live ancestor) hands over to the acting CEO, else to the owner.
        var manager = try nearestAncestor(db, of: agent, notRequester: "")
        if manager == nil { manager = try Store.actingCEOs(db, companyId: company.id).first(where: { $0.id != agent.id }) }
        let summary = try Turn.filter(Column("agentId") == agent.id && Column("summary") != nil)
            .order(Column("startedAt").desc, Column.rowID.desc).fetchOne(db)?.summary ?? ""
        for item in items {
            // The agent's own last words are quoted, never mixed into the engine's text.
            var questions: [String] = []
            if !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                questions.append(ReviewDigest.quote(summary, maxChars: ReviewDigest.maxSummary))
            }
            let draft = HandoffDraft(goal: "Auto hand-off: @\(agent.name) was killed", openQuestions: questions,
                                     fileRefs: [".brahma/progress/\(item.key).md", "item/\(item.key)"],
                                     toAgentId: manager?.id)
            do {
                // The row the hand-off describes: the item as it stood while the agent held it.
                let handoff = try writeHandoff(db: db, item: item, authorId: "system", authorHandle: "system", draft: draft, auto: true, now: now)
                if manager == nil {
                    try MessageRouter(store: self).sendDM(
                        db: db, companyId: company.id, from: .system, to: "owner",
                        text: "@\(agent.name) was killed and nobody manages them: \(item.key) is unassigned. Auto hand-off: \(handoff.path)",
                        now: now)
                }
            } catch {
                // A workspace that cannot be written never keeps an agent from being killed.
                try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .error,
                                  text: "could not write the auto hand-off of \(item.key): \(error)", createdAt: now).insert(db)
            }
        }
    }

    // MARK: 4. Reparent

    /// Moves every report of the agent to its nearest live ancestor (none: they become roots). Returns the new manager.
    private func reparentReports(_ db: Database, of agent: Agent, now: Date) throws -> Set<String> {
        let heir = try nearestAncestor(db, of: agent, notRequester: "")
        try db.execute(sql: "UPDATE agent SET managerId = ? WHERE managerId = ?", arguments: [heir?.id, agent.id])
        return heir.map { [$0.id] } ?? []
    }

    /// A node over `OrgGenerator.maxReports` (attrition may push it there): an org issue and an owner ask, once per count.
    private func checkSpan(_ db: Database, managerId: String, left agent: Agent, company: Company, now: Date) throws {
        guard let manager = try Agent.fetchOne(db, key: managerId), manager.state != .killed else { return }
        let n = try Agent.filter(Column("managerId") == managerId && Column("state") != AgentState.killed.rawValue).fetchCount(db)
        guard n > OrgGenerator.maxReports else { return }
        let title = "@\(manager.name) now has \(n) reports after @\(agent.name) left"
        let open = try OrgIssueRecord.filter(Column("companyId") == company.id && Column("kind") == OrgIssueRecord.overSpan
                                             && Column("agentId") == managerId && Column("resolvedAt") == nil).fetchCount(db)
        if open == 0 {
            var issue = OrgIssueRecord(id: nil, companyId: company.id, kind: OrgIssueRecord.overSpan, agentId: managerId, detail: title,
                                       createdAt: now, resolvedAt: nil)
            try issue.insert(db)
        }
        _ = try propose(db: db, companyId: company.id, by: .system, kind: .other, risk: nil, category: "exec-staffing", title: title,
                        summary: "Promote a lead or add a director.", payload: nil, document: nil, itemId: nil,
                        subjectId: Store.overSpanSubjectPrefix + managerId, supersedes: nil,
                        requestId: "overspan:\(managerId):\(n)", decisionClass: .taste, viaOwner: true, now: now)
    }

    // MARK: 5. Succession

    /// Names the next executive acting CEO when the departed was the root executive or the acting CEO. Returns that agent.
    private func succeed(_ db: Database, agent: Agent, company: Company, now: Date) throws -> String? {
        let pack = catalog.pack(company.packId)
        let execRoles = (pack?.org.executives ?? []) + (pack?.org.mergedExecutives ?? [])
        // `agent.managerId` is the row as it was killed: the root executive had none.
        guard (agent.managerId == nil && execRoles.contains(agent.role)) || agent.actingRole == "ceo" else { return nil }
        let live = try Agent.filter(Column("companyId") == company.id && Column("id") != agent.id
                                    && Column("state") != AgentState.killed.rawValue)
            .order(Column("createdAt"), Column.rowID).fetchAll(db)
        // Someone else still covers the CEO: nothing to fill.
        let ceoRoles = Set(pack?.rolesCovering("ceo") ?? [])
        if live.contains(where: { ceoRoles.contains($0.role) || $0.actingRole == "ceo" }) { return nil }
        // The next executive in pack order; one already at the top is preferred, so no root has to move under its own report.
        let ranked = live.compactMap { a in execRoles.firstIndex(of: a.role).map { (a, $0) } }
            .sorted { ($0.0.managerId == nil ? 0 : 1, $0.1) < ($1.0.managerId == nil ? 0 : 1, $1.1) }
        guard let next = ranked.first?.0 else {
            try raiseNoRoot(db, company: company, agentId: nil, detail: "@\(agent.name) left and no executive can act as CEO", now: now)
            return nil
        }
        try db.execute(sql: "UPDATE agent SET actingRole = 'ceo' WHERE id = ?", arguments: [next.id])
        try reparentRoots(db, companyId: company.id, under: next)
        try ActivityEvent(companyId: company.id, agentId: next.id, turnId: nil, kind: .work,
                          text: "@\(next.name) is acting CEO after @\(agent.name) left (waiting for the owner to confirm)",
                          createdAt: now).insert(db)
        _ = try propose(db: db, companyId: company.id, by: .system, kind: .other, risk: nil, category: "exec-staffing",
                        title: "Confirm @\(next.name) as acting CEO",
                        summary: "@\(agent.name) left. @\(next.name) acts as CEO and the other top-level agents report to them. "
                            + "Reject to clear it (the company then has no root until you name one with `brahma org acting`).",
                        payload: nil, document: nil, itemId: nil, subjectId: Store.actingCEOSubjectPrefix + next.id, supersedes: nil,
                        requestId: "actingceo:\(next.id)", decisionClass: .taste, viaOwner: true, now: now)
        try alert(db: db, companyId: company.id, agentId: next.id,
                                   text: "@\(agent.name) left the company. You are acting CEO until the owner confirms or names someone else; "
                                       + "the other top-level agents now report to you.", now: now)
        return next.id
    }

    /// Every other live top-level agent reports to `next`, except one that sits above `next` (that would be a cycle).
    private func reparentRoots(_ db: Database, companyId: String, under next: Agent) throws {
        let above = Set(try managerChain(db, of: next.id).map(\.id))
        let roots = try Agent.filter(Column("companyId") == companyId && Column("managerId") == nil && Column("id") != next.id
                                     && Column("state") != AgentState.killed.rawValue).fetchAll(db)
        for root in roots where !above.contains(root.id) {
            try db.execute(sql: "UPDATE agent SET managerId = ? WHERE id = ?", arguments: [next.id, root.id])
        }
    }

    private func raiseNoRoot(_ db: Database, company: Company, agentId: String?, detail: String, now: Date) throws {
        let open = try OrgIssueRecord.filter(Column("companyId") == company.id && Column("kind") == OrgIssueRecord.noRoot
                                             && Column("resolvedAt") == nil).fetchCount(db)
        guard open == 0 else { return }
        var issue = OrgIssueRecord(id: nil, companyId: company.id, kind: OrgIssueRecord.noRoot, agentId: agentId, detail: detail,
                                   createdAt: now, resolvedAt: nil)
        try issue.insert(db)
        try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .error, text: "org: \(detail)", createdAt: now).insert(db)
    }

    /// The owner rejected the confirmation of an acting CEO: the role is cleared and the company has no root.
    func actingCEODeclined(_ db: Database, ask: Ask, now: Date) throws {
        guard ask.kind == .other, let subject = ask.subjectId, subject.hasPrefix(Store.actingCEOSubjectPrefix) else { return }
        let id = String(subject.dropFirst(Store.actingCEOSubjectPrefix.count))
        guard let agent = try Agent.fetchOne(db, key: id), agent.companyId == ask.companyId, agent.actingRole == "ceo",
              let company = try Company.fetchOne(db, key: ask.companyId) else { return }
        try db.execute(sql: "UPDATE agent SET actingRole = NULL WHERE id = ?", arguments: [id])
        try raiseNoRoot(db, company: company, agentId: id, detail: "the owner declined @\(agent.name) as acting CEO; the company has no CEO",
                        now: now)
    }

    // MARK: Owner: name the acting CEO

    /// The owner names the acting CEO directly (`brahma org acting`). Any other acting CEO is cleared, open confirmations are
    /// settled, and a `noRoot` issue is resolved. The agent is told.
    @discardableResult
    public func setActingCEO(companyId: String, agentId: String, now: Date = Store.now()) throws -> Agent {
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId else { throw StoreError.notFound }
            guard agent.state != .killed else { throw OrgError.managerKilled }
            try db.execute(sql: "UPDATE agent SET actingRole = NULL WHERE companyId = ? AND actingRole = 'ceo'", arguments: [companyId])
            try db.execute(sql: "UPDATE agent SET actingRole = 'ceo' WHERE id = ?", arguments: [agentId])
            // With no real CEO in the company the acting one is the top of the org, as in a succession: it is detached from
            // its own manager and the other top-level agents report to it (never one that sat above it).
            let ceoRoles = Set(catalog.pack(try requireCompany(db, companyId).packId)?.rolesCovering("ceo") ?? [])
            let realCEO = try Agent.filter(Column("companyId") == companyId && Column("id") != agentId
                                           && Column("state") != AgentState.killed.rawValue).fetchAll(db)
                .contains { ceoRoles.contains($0.role) }
            if !realCEO {
                try db.execute(sql: "UPDATE agent SET managerId = NULL WHERE id = ?", arguments: [agentId])
                try reparentRoots(db, companyId: companyId, under: agent)
            }
            try db.execute(sql: "UPDATE orgIssue SET resolvedAt = ? WHERE companyId = ? AND kind = ? AND resolvedAt IS NULL",
                           arguments: [now, companyId, OrgIssueRecord.noRoot])
            let open = try Ask.filter(Column("companyId") == companyId && Column("status") == AskStatus.pendingOwner.rawValue
                                      && Column("subjectId") != nil).order(Column("number")).fetchAll(db)
            for var ask in open {
                guard let subject = ask.subjectId, subject.hasPrefix(Store.actingCEOSubjectPrefix) else { continue }
                let same = subject == Store.actingCEOSubjectPrefix + agentId
                ask.ownerNote = same ? "named directly by the owner" : "the owner named @\(agent.name) instead"
                ask.ownerDecidedAt = now
                try settle(db, ask: &ask, status: same ? .approved : .superseded, decidedBy: "owner", tellRequesterToo: false, now: now)
            }
            try ActivityEvent(companyId: companyId, agentId: agentId, turnId: nil, kind: .work,
                              text: "@\(agent.name) is acting CEO (named by the owner)", createdAt: now).insert(db)
            try alert(db: db, companyId: companyId, agentId: agentId,
                                       text: "The owner named you acting CEO.", now: now)
            return try Agent.fetchOne(db, key: agentId) ?? agent
        }
    }
}

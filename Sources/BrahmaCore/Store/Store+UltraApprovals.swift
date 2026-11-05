import Foundation
import GRDB

/// What routing one Ultra request came to.
public struct UltraRouting: Equatable, Sendable {
    public var ask: Ask
    public var route: UltraRoute
    /// An open or approved-and-unused run already existed: nothing new was filed.
    public var existing: Bool
}

extension Store {
    /// Routes one Ultra run for `item` (design §3.6 approval table), in the caller's transaction: an owner `boost` ask with the
    /// card text and its three options (expiring after one active day), or a `boost` ask approved by Brahma policy with an
    /// owner FYI. One open or unused run per item: a second request gets the first. Never a reserved matter.
    func routeUltra(db: Database, company: Company, item: WorkItem, by sender: Sender, variant: UltraVariant, origin: UltraOrigin,
                    reason: String, now: Date) throws -> UltraRouting {
        let boosts = try Ask.filter(Column("companyId") == company.id && Column("kind") == AskKind.boost && Column("itemId") == item.id)
            .order(Column("createdAt")).fetchAll(db)
        if let open = boosts.first(where: { $0.status.isPending }) {
            return UltraRouting(ask: open, route: open.status == .pendingOwner ? .ownerAsk : .policy, existing: true)
        }
        for b in boosts where b.status == .approved {
            guard try UltraReservation.filter(Column("askId") == b.id).fetchCount(db) == 0 else { continue }
            return UltraRouting(ask: b, route: b.decidedBy == "owner" ? .ownerApproved : .policy, existing: true)
        }
        let route = UltraApproval.route(variant, preset: company.autonomy, origin: origin, escalated: try Store.ultraEscalated(db: db, item: item))
        let per = try Store.calibration(db).pctPerDollar
        let allowance = try Store.ultraAllowance(db: db, companyId: company.id, now: now)
        let card = UltraApproval.cardText(key: item.key, title: item.title, reason: reason, variant: variant, pctPerDollar: per,
                                          allowanceLeftShare: allowance.map { $0.totalLE > 0 ? $0.leftLE / $0.totalLE : 0 })
        let title = origin == .failurePath ? "Ultra for \(item.key) after repeated failures" : "\(variant.title) for \(item.key)"
        var ask = try propose(db: db, companyId: company.id, by: sender, kind: .boost, risk: origin == .failurePath ? .high : nil,
                              category: nil, title: title, summary: card,
                              payload: AskPayload(question: "Allow one \(variant.title) run on \(item.key)?", details: card,
                                                  options: UltraApproval.options, proposal: variant.rawValue),
                              document: nil, itemId: item.id, subjectId: item.id, supersedes: nil, requestId: nil, decisionClass: .taste,
                              viaOwner: true, announce: route == .ownerAsk, now: now)
        ask.expiresActive = ask.createdActive + UltraApproval.expirySeconds
        try ask.update(db)
        if route == .policy {
            ask.fyi = true
            try settle(db, ask: &ask, status: .approved, decidedBy: "policy:\(company.autonomy.rawValue)", now: now)
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .approval,
                              text: "FYI: \(ask.ref) \(variant.title) for \(item.key) approved by Brahma policy under \(company.autonomy.rawValue): "
                                  + Store.flat(reason, max: 200),
                              createdAt: now).insert(db)
        }
        return UltraRouting(ask: ask, route: route, existing: false)
    }

    /// The item was escalated by the engine (counted failures or review rejections raised its floor): Ultra-small then needs the
    /// owner under `important`.
    static func ultraEscalated(db: Database, item: WorkItem) throws -> Bool {
        let texts = try String.fetchAll(db, sql: """
            SELECT text FROM workItemEvent WHERE itemId = ? AND kind = 'modeEscalated' AND actorId = 'system'
            """, arguments: [item.id])
        return texts.contains { $0.hasPrefix(failureEscalationPrefix) || $0.hasPrefix(rejectionEscalationPrefix) }
    }

    /// Whether `agentId` is a manager or executive above the item's assignee (its chain).
    static func inItemChain(db: Database, agent: Agent, item: WorkItem, catalog: PackCatalog, company: Company) throws -> Bool {
        let kind = catalog.template(role: agent.role, pack: company.packId).kind
        guard kind == .manager || kind == .executive else { return false }
        guard let ownerId = item.ownerId, var next = try Agent.fetchOne(db, key: ownerId)?.managerId else { return false }
        var seen = Set<String>()
        while seen.insert(next).inserted {
            if next == agent.id { return true }
            guard let up = try Agent.fetchOne(db, key: next)?.managerId else { return false }
            next = up
        }
        return false
    }
}

extension Store {
    // MARK: Gate inputs and status (F9)

    /// The plan tier the engine uses for Ultra: the configured tier against what the doctor's `get_usage` reported.
    public func planTierResolution() -> PlanTierEffective {
        PlanTierEffective.resolve(configured: planTier(), reported: (try? latestProbe())?.reportedSubscription)
    }

    /// The hard gates' inputs the store can read (design §3.6), for `company` under `profile`. `fingerprint`: the running CLI
    /// build whose Ultra probe gates count (nil: none); `running`: the company's turns in flight that hold its slots (not the
    /// asking turn). The fresh reading (gate 6), the agent's trust and taint are the caller's.
    public func ultraGateInputs(company: Company, profile: PermissionProfile, fingerprint: String?, running: Int, now: Date) -> UltraGateInputs {
        var g = UltraGateInputs()
        g.profile = profile
        if let fingerprint { g.passedGates = (try? passedProbeGates(fingerprint: fingerprint, shape: .ultra)) ?? [] }
        // U-1 checks that the Ultra shape's init `tools` contain `Workflow` (and records them).
        g.initToolsHaveWorkflow = g.passedGates.contains("U-1")
        let probe = try? latestProbe()
        g.cliVersion = probe?.cliVersion
        let info = try? latestRateLimit()
        g.overageStatus = info?.overageStatus
        g.isUsingOverage = info?.isUsingOverage ?? false
        let tier = planTierResolution()
        g.planTier = tier.tier
        g.planTierConfirmed = tier.confirmed
        let cal = (try? usageCalibration()) ?? UsageCalibration()
        g.weekWindows = cal.week.samples.count
        g.fiveHourWindows = cal.fiveHour.samples.count
        g.pctPerDollar = cal.pctPerDollar
        g.pctPerDollar5h = cal.pctPerDollar5h
        if let pace = UsageGate.pace(info, reserve: company.ownerReserve ?? (1 - weeklyShare()), now: now) {
            g.pace = pace.state
            g.sevenDayUtil = pace.used
            g.allowedWeek = pace.allowed
        }
        g.openReservationLE = openReservationLE()
        g.allowanceLeftLE = (try? ultraAllowance(companyId: company.id, now: now))?.leftLE
        let today = (try? ultraRunsToday(companyId: company.id, now: now)) ?? (all: 0, full: 0)
        g.ultraRunsToday = today.all
        g.fullUltraRunsToday = today.full
        g.runningUltra = (try? runningUltraCount()) ?? 0
        g.freeSlots = g.planTier.modeCap(company.usageMode) - running
        g.usageMode = company.usageMode
        return g
    }

    /// The CLI build whose probe gates were checked last (the stall explainer's guess when no engine is asked).
    public func lastProbedFingerprint() -> String? {
        try? writer.read { db in
            guard try db.tableExists("probeGate") else { return nil }
            return try String.fetchOne(db, sql: "SELECT cliFingerprint FROM probeGate ORDER BY checkedAt DESC LIMIT 1")
        }
    }

    /// `UltraStatus.explain` for a company read from the store alone (`brahma mode ultra-status`, the stall explainer): its
    /// running agents hold its slots.
    public func ultraStatus(companyId: String, fingerprint: String?, now: Date = Store.now()) -> [String] {
        guard let company = try? company(id: companyId) else { return [] }
        let running = (try? writer.read { db in
            try Agent.filter(Column("companyId") == companyId && Column("state") == AgentState.running.rawValue).fetchCount(db)
        }) ?? 0
        return UltraStatus.explain(ultraGateInputs(company: company, profile: company.permissionProfile,
                                                   fingerprint: fingerprint ?? lastProbedFingerprint(), running: running, now: now))
    }

    /// Items of the company with an approved Ultra run waiting: the stall explainer says why it has not run.
    func itemsWaitingForUltra(db: Database, companyId: String) throws -> [String] {
        guard try db.tableExists("ultraReservation") else { return [] }
        return try String.fetchAll(db, sql: """
            SELECT DISTINCT w.key FROM ask a JOIN workItem w ON w.id = a.itemId
            WHERE a.companyId = ? AND a.kind = 'boost' AND a.status = 'approved' AND w.status IN ('ready', 'inProgress')
              AND NOT EXISTS (SELECT 1 FROM ultraReservation r WHERE r.askId = a.id)
            UNION SELECT key FROM workItem WHERE companyId = ? AND intensity = 'ultra' AND status IN ('ready', 'inProgress')
            ORDER BY 1
            """, arguments: [companyId, companyId])
    }
}

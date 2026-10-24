import Foundation

/// A turn the work-mode policy does not let start: the no-launch rule (`overBudgetItem` set) or a model pin outside the
/// allowlist.
struct ModeNotLaunched: Error { var reason: String; var overBudgetItem: String? }

extension Orchestrator {
    /// Everything `ModePolicy.select` reads for one turn (design §3.1), from the store and the latest usage reading.
    /// `itemBudget`: the turn is the leaseholder's on an item it is working (ready or in progress), so the item's remaining
    /// budget caps it and the no-launch rule applies. Any other turn about the item (its assignee after the item was blocked over
    /// budget, answering DMs) runs without it (fix 1 C1).
    nonisolated func modeInputs(kind: TurnKind, agent: Agent, company: Company, template: RoleTemplate, deciding: ModelContext,
                                facts: ItemModeFacts?, hasItem: Bool, itemBudget: Bool, sessionModel: String?,
                                sessionTokens: Int) -> ModeInputs {
        var i = ModeInputs()
        i.turnKind = kind
        i.hasItem = hasItem
        i.leadRole = template.kind == .manager || template.kind == .executive
        i.decidingPRD = deciding.decidingPRD
        i.decidingArchitecture = deciding.decidingArchitecture
        i.agentModel = agent.model
        i.roleModel = template.models[company.usageMode.rawValue]
        i.usageMode = company.usageMode
        // The configured plan tier always (owner answer Q-M1); the CLI's report only earns a doctor warning.
        i.planTier = store.planTier()
        let now = clock()
        if let info = try? store.latestRateLimit() {
            i.fiveHourUtil = info.fiveHourUtilization
            i.overageAllowed = info.overageStatus == "allowed" || info.isUsingOverage
            let reserve = company.ownerReserve ?? (1 - store.weeklyShare())
            i.pace = UsageGate.pace(info, reserve: reserve, now: now)?.state ?? .onPace
        }
        i.opusScarce = (try? store.opusScarce(now: now)) ?? false
        i.calibration = (try? store.modeCalibration()) ?? ModeCalibration()
        i.subagentGate = SubagentGate.passed(profile: turnProfile(agent: agent, company: company))
        i.trust = agent.trustLevel
        if let f = facts {
            i.tier = f.tier
            i.priority = f.priority
            i.riskTags = f.riskTags
            i.blockingCount = f.blockingCount
            i.intensity = f.item.intensity
            i.rungFloor = f.item.rungFloor
            i.planWritten = f.planWritten
            i.replanRequested = f.replanRequested
            i.p2OnlyFix = f.p2OnlyFix
            if kind == .work || kind == .plan, itemBudget { i.budgetLeftLE = f.budgetLeftLE }
            if kind.isReview { i.reviewSpendCapped = (try? store.reviewSpendCapped(item: f.item)) ?? false }
        }
        i.sessionModel = sessionModel
        i.sessionTokens = sessionTokens
        return i
    }

    /// Escalation before a leaseholder's turn picks its rung (design §3.3): failed checks that count (real, a new commit, a diff
    /// in the item's scope) and review rejections raise the item's floor once per claim, effort first; budget-capped stops in a
    /// row tell the manager; R4 plus two more counted failures on a confirmed L or P0 item proposes Ultra to the owner.
    nonisolated func escalate(itemId: String, agent: Agent, git: GitWorkspace, now: Date) {
        guard let f = try? store.itemModeFacts(itemId: itemId, holderId: agent.id) else { return }
        let budgetLeft: Double? = Self.budgetApplies(f.item) ? f.budgetLeftLE : nil
        let runs = (try? store.failedRuns(itemId: itemId, since: f.claimedAt)) ?? []
        let claimed = PathOverlap.claimed(f.item)
        var previous = f.item.baseCommit
        var submissions: [FailedSubmission] = []
        for r in runs {
            let touches = r.real ? Self.touchesScope(git: git, from: previous, to: r.commit, claimed: claimed) : false
            submissions.append(FailedSubmission(commit: r.commit, touchesScope: touches, real: r.real))
            if r.real { previous = r.commit }
        }
        let counted = ModePolicy.countedFailures(submissions)
        guard let state = try? store.escalationState(itemId: itemId, since: f.claimedAt) else { return }
        let level = (try? store.lastWorkRung(itemId: itemId, agentId: agent.id)) ?? 1
        let capped = (try? store.cappedInRow(itemId: itemId)) ?? 0
        let cal = (try? store.modeCalibration()) ?? ModeCalibration()
        let actions = ModePolicy.escalation(
            counted: counted, escalatedSinceClaim: state.failures, currentLevel: level, floor: f.item.rungFloor,
            tierL: f.tier == .l, p0: f.priority == 0, mP0OrRisk: f.tier == .m && (f.priority == 0 || !f.riskTags.isEmpty),
            rejections: f.reviewRejections, rejectionsApplied: state.rejections, cappedInRow: capped, budgetLeftLE: budgetLeft,
            estimate: { l in
                let r = ModeRung.at(level: l)
                return cal.estimate(rung: r, model: r.isOpus ? "opus" : "sonnet", effort: r.effort)
            },
            ultraProposed: state.ultra)
        guard !actions.isEmpty else { return }
        let kind = counted >= ModePolicy.escalationFailures && !state.failures ? "failures" : "rejections"
        attempt { try store.applyEscalation(itemId: itemId, actions: actions, kind: kind, since: f.claimedAt, now: now) }
    }

    /// The item's budget binds its leaseholder's turns only while it is being worked.
    nonisolated static func budgetApplies(_ item: WorkItem) -> Bool { item.status == .inProgress || item.status == .ready }

    /// The diff from the previous failing commit (or the item's base) touches the item's claimed paths. An item that claims the
    /// whole repo, or a diff git cannot produce, counts as touching it.
    nonisolated static func touchesScope(git: GitWorkspace, from: String?, to commit: String, claimed: [String]) -> Bool {
        if claimed == [PathOverlap.wholeRepo] { return true }
        guard let base = from, base != commit, let changes = try? git.nameStatus(base: base, head: commit) else { return true }
        let paths = changes.entries.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
        return paths.contains { p in claimed.contains { PathOverlap.overlaps(path: $0, p) } }
    }
}

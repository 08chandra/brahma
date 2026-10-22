import Foundation
import Testing
@testable import BrahmaCore

/// The work-mode selection policy as a pure table (design §3.2–§3.4; Task 14c).
@Suite struct ModePolicyTests {
    /// A work turn on a confirmed item of `tier`, balanced usage mode, max5x, on pace, plenty of budget.
    private func work(_ tier: EffortTier = .s, _ edit: (inout ModeInputs) -> Void = { _ in }) -> ModeInputs {
        var i = ModeInputs()
        i.turnKind = .work
        i.hasItem = true
        i.tier = tier
        i.budgetLeftLE = 100
        edit(&i)
        return i
    }

    private func pick(_ i: ModeInputs) -> ModeDecision { ModePolicy.select(i) }

    @Test func noticeIsQuickHaikuLow() {
        var i = ModeInputs(); i.turnKind = .notice
        let d = pick(i)
        #expect(d.mode == .quick); #expect(d.model == "haiku"); #expect(d.effort == .low); #expect(d.rung == .r0)
        #expect(d.maxTurns == 10); #expect(d.maxBudgetUSD == 0.30); #expect(d.wallClock == .seconds(300))
    }

    @Test func itemlessIsQuickSonnetLow() {
        var i = ModeInputs(); i.turnKind = .work; i.hasItem = false
        let d = pick(i)
        #expect(d.mode == .quick); #expect(d.model == "sonnet"); #expect(d.effort == .low)
        // A role whose card names haiku for the usage mode runs its small rungs on haiku.
        i.roleModel = "haiku"
        #expect(pick(i).model == "haiku")
    }

    @Test func tierSStandard() {
        let d = pick(work(.s))
        #expect(d.mode == .standard); #expect(d.rung == .r1); #expect(d.model == "sonnet"); #expect(d.effort == .medium)
        #expect(d.maxTurns == 40); #expect(d.maxBudgetUSD == 2.00); #expect(d.wallClock == .seconds(1200))
        #expect(!d.planFirst)
    }

    @Test func tierMRiskOrP0IsDeep() {
        #expect(pick(work(.m)).rung == .r1)
        for edit: (inout ModeInputs) -> Void in [{ $0.riskTags = ["sensitivePath"] }, { $0.priority = 0 }, { $0.blockingCount = 2 }] {
            let d = pick(work(.m, edit))
            #expect(d.mode == .deep); #expect(d.rung == .r2); #expect(d.model == "sonnet"); #expect(d.effort == .high)
            #expect(d.maxTurns == 60); #expect(d.maxBudgetUSD == 5.00); #expect(d.wallClock == .seconds(1800))
        }
        #expect(pick(work(.m) { $0.blockingCount = 1 }).rung == .r1)
    }

    @Test func tierLConfirmedIsOpusMediumPlanFirst() {
        var i = work(.l)
        i.planFirstGate = true
        let d = pick(i)
        #expect(d.rung == .r3); #expect(d.model == "opus"); #expect(d.effort == .medium); #expect(d.mode == .deep)
        #expect(d.maxBudgetUSD == 8.00)
        #expect(d.planFirst)
        i.planWritten = true
        #expect(!pick(i).planFirst, "a plan written since the claim is not repeated")
        // Probe V-4 failed on this CLI version: Plan-first does not compile, and the reason says so.
        let gated = pick(work(.l))
        #expect(!gated.planFirst); #expect(gated.reason.contains("V-4"))
        #expect(ModeGates.planFirst == false)
        // The plan turn itself: the item's session model, effort medium, Plan caps.
        var plan = work(.l); plan.turnKind = .plan; plan.sessionModel = "opus"
        let p = pick(plan)
        #expect(p.mode == .plan); #expect(p.model == "opus"); #expect(p.effort == .medium)
        #expect(p.maxTurns == 25); #expect(p.maxBudgetUSD == 4.00); #expect(p.wallClock == .seconds(900))
        #expect(p.quotas == ModeQuotas(posts: 3, itemsCreated: 0, comments: 5, highRisk: 0))
    }

    @Test func agentAuthoredTierLNotOpusUntilConfirmed() {
        // The engine passes the effective tier: an unconfirmed (or self-confirmed) L counts as at most M.
        let unconfirmed = pick(work(.m))
        #expect(unconfirmed.model == "sonnet"); #expect(unconfirmed.rung == .r1)
        #expect(EffectiveSpec.tier(stored: .l, confirmedBy: nil, holderId: "eng") == .m)
        #expect(EffectiveSpec.tier(stored: .l, confirmedBy: "eng:individual", holderId: "eng") == .m)
        #expect(EffectiveSpec.tier(stored: .l, confirmedBy: "eng:manager", holderId: "eng") == .m, "the holder cannot vouch for itself")
        #expect(EffectiveSpec.tier(stored: .l, confirmedBy: "mgr:manager", holderId: "eng") == .l)
        #expect(EffectiveSpec.tier(stored: .l, confirmedBy: "owner:owner", holderId: "eng") == .l)
        #expect(EffectiveSpec.priority(stored: 0, confirmedBy: nil, holderId: "eng") == 2)
        #expect(EffectiveSpec.priority(stored: 0, confirmedBy: "mgr:executive", holderId: "eng") == 0)
        #expect(EffectiveSpec.priority(stored: 3, confirmedBy: nil, holderId: "eng") == 3, "a lower priority always counts")
        #expect(pick(work(EffectiveSpec.tier(stored: .l, confirmedBy: "mgr:manager", holderId: "eng"))).model == "opus")
    }

    @Test func selfLinkedDependentsDontCountForBlocking() {
        // Blocking is the effective count (self-authored, self-linked dependents excluded by the store); one is not enough.
        #expect(pick(work(.m) { $0.blockingCount = 1 }).rung == .r1)
        #expect(pick(work(.m) { $0.blockingCount = 2 }).rung == .r2)
        var max = work(.m) { $0.blockingCount = 1; $0.usageMode = .max }
        #expect(pick(max).rung == .r1, "Max mode boosts only effective critical-path work")
        max.blockingCount = 2
        #expect(pick(max).rung == .r3)
    }

    @Test func prdArchitectureR3NoPlanFirst() {
        for edit: (inout ModeInputs) -> Void in [{ $0.decidingPRD = true }, { $0.decidingArchitecture = true }] {
            var i = work(.s, edit); i.planFirstGate = true
            let d = pick(i)
            #expect(d.rung == .r3); #expect(d.model == "opus"); #expect(!d.planFirst)
        }
    }

    @Test func reviewNeverHasTaskOrWorkflow() {
        var i = ModeInputs(); i.turnKind = .review; i.subagentGate = true; i.tier = .s
        let std = pick(i)
        #expect(std.mode == .standard); #expect(std.model == "sonnet"); #expect(std.subagents == .off)
        i.tier = .l
        let deep = pick(i)
        #expect(deep.rung == .r3); #expect(deep.model == "opus"); #expect(deep.subagents == .off)
        i.tier = .s; i.riskTags = ["flagged"]
        #expect(pick(i).rung == .r3)
        i.turnKind = .audit
        #expect(pick(i).subagents == .off)
        // The compiled review profile has no Task, Agent or Workflow whatever the decision said.
        #expect(TurnKind.review.isReview && TurnKind.audit.isReview)
    }

    @Test func twoCountedFailuresEscalateOneRung() {
        let failures = [FailedSubmission(commit: "a", touchesScope: true, real: true),
                        FailedSubmission(commit: "b", touchesScope: true, real: true)]
        #expect(ModePolicy.countedFailures(Array(failures.prefix(1))) == 1)
        #expect(ModePolicy.countedFailures(failures) == 2)
        func esc(_ counted: Int, level: Int, floor: Int = 0, tierL: Bool = false, risky: Bool = false) -> [EscalationAction] {
            ModePolicy.escalation(counted: counted, escalatedSinceClaim: false, currentLevel: level, floor: floor, tierL: tierL,
                                  p0: false, mP0OrRisk: risky, rejections: 0, rejectionsApplied: false, cappedInRow: 0,
                                  budgetLeftLE: nil, estimate: { _ in 0 }, ultraProposed: false)
        }
        #expect(esc(1, level: 1).isEmpty, "one counted failure changes nothing")
        #expect(esc(2, level: 1) == [.raiseFloor(to: 2, opus: false, reason: "2 counted failed checks")])
        #expect(esc(2, level: 2).isEmpty, "R2 → R3 only for confirmed L or risky/P0 M")
        #expect(esc(2, level: 2, risky: true) == [.raiseFloor(to: 3, opus: true, reason: "2 counted failed checks")])
        #expect(esc(2, level: 3, tierL: true) == [.raiseFloor(to: 4, opus: false, reason: "2 counted failed checks")])
        #expect(esc(2, level: 3, risky: true).isEmpty, "R3 → R4 only for confirmed tier L")
        // Once per claim.
        #expect(ModePolicy.escalation(counted: 2, escalatedSinceClaim: true, currentLevel: 1, floor: 2, tierL: false, p0: false,
                                      mP0OrRisk: false, rejections: 0, rejectionsApplied: false, cappedInRow: 0, budgetLeftLE: nil,
                                      estimate: { _ in 0 }, ultraProposed: false).isEmpty)
        // At R4 with two more counted failures on a confirmed L or P0 item the engine proposes Ultra (an owner ask).
        #expect(esc(2, level: 4, floor: 4, tierL: true) == [.proposeUltra(reason: "2 counted failed checks at R4")])
        #expect(ModePolicy.nextFloor(from: 0, tierL: false, mP0OrRisk: false) == 1)
    }

    @Test func identicalResubmitDoesNotEscalate() {
        let same = [FailedSubmission(commit: "a", touchesScope: true, real: true),
                    FailedSubmission(commit: "a", touchesScope: true, real: true)]
        #expect(ModePolicy.countedFailures(same) == 1)
        let outOfScope = [FailedSubmission(commit: "a", touchesScope: true, real: true),
                          FailedSubmission(commit: "b", touchesScope: false, real: true)]
        #expect(ModePolicy.countedFailures(outOfScope) == 1, "a diff outside the item's scope does not count")
    }

    @Test func flakyInconclusiveInfraNeverEscalate() {
        let noise = [FailedSubmission(commit: "a", touchesScope: true, real: false),
                     FailedSubmission(commit: "b", touchesScope: true, real: false),
                     FailedSubmission(commit: "c", touchesScope: true, real: false)]
        #expect(ModePolicy.countedFailures(noise) == 0)
        let mixed = [FailedSubmission(commit: "a", touchesScope: true, real: true),
                     FailedSubmission(commit: "b", touchesScope: true, real: false),
                     FailedSubmission(commit: "a", touchesScope: true, real: true)]
        #expect(ModePolicy.countedFailures(mixed) == 1, "a flaky run in between does not make the same commit new")
    }

    @Test func noProgressDoesNotEscalate() {
        // The watchdog's no-progress and loop stops are not failed checks: zero counted failures, no escalation.
        #expect(ModePolicy.escalation(counted: 0, escalatedSinceClaim: false, currentLevel: 1, floor: 0, tierL: true, p0: true,
                                      mP0OrRisk: true, rejections: 0, rejectionsApplied: false, cappedInRow: 0, budgetLeftLE: nil,
                                      estimate: { _ in 0 }, ultraProposed: false).isEmpty)
        // Two budget-capped stops in a row: a manager notice, no rung change.
        #expect(ModePolicy.escalation(counted: 0, escalatedSinceClaim: false, currentLevel: 1, floor: 0, tierL: false, p0: false,
                                      mP0OrRisk: false, rejections: 0, rejectionsApplied: false, cappedInRow: 2, budgetLeftLE: nil,
                                      estimate: { _ in 0 }, ultraProposed: false) == [.turnCapTooSmall])
    }

    @Test func rungFloorSurvivesReclaim() {
        // The floor is an item field: a new claimant (no session yet) starts at it.
        let d = pick(work(.s) { $0.rungFloor = 2 })
        #expect(d.rung == .r2); #expect(d.reason.contains("floor R2"))
    }

    @Test func mergeResetsFloor() {
        #expect(pick(work(.s) { $0.rungFloor = 0 }).rung == .r1)
        #expect(WorkItemStatus.done.resetsRungFloor)
        #expect(!WorkItemStatus.inProgress.resetsRungFloor)
    }

    @Test func p2OnlyFixLowersEffortNotModel() {
        var i = work(.m) { $0.rungFloor = 3; $0.sessionModel = "opus"; $0.riskTags = [] }
        #expect(pick(i).model == "opus"); #expect(pick(i).effort == .medium)
        i.rungFloor = 4
        #expect(pick(i).effort == .high)
        i.p2OnlyFix = true
        let d = pick(i)
        #expect(d.model == "opus", "the model is not lowered mid-session"); #expect(d.effort == .medium, "base R1's effort")
    }

    @Test func sessionModelFixedEffortVaries() {
        // Sonnet session: an opus rung without an explicit escalation keeps Sonnet (high effort).
        let max = pick(work(.m) { $0.sessionModel = "sonnet"; $0.usageMode = .max; $0.priority = 0 })
        #expect(max.model == "sonnet"); #expect(max.rung == .r2); #expect(!max.cacheBreak)
        // An explicit escalation to Opus (floor ≥ R3) does change it, as a cache break.
        let esc = pick(work(.m) { $0.sessionModel = "sonnet"; $0.rungFloor = 3 })
        #expect(esc.model == "opus"); #expect(esc.cacheBreak)
        // Opus session: a Sonnet rung keeps Opus at low effort.
        let down = pick(work(.s) { $0.sessionModel = "opus" })
        #expect(down.model == "opus"); #expect(down.rung == .opusLow); #expect(down.effort == .low); #expect(!down.cacheBreak)
        // Same session model: only the effort follows the rung.
        let same = pick(work(.m) { $0.sessionModel = "sonnet"; $0.riskTags = ["hotPath"] })
        #expect(same.model == "sonnet"); #expect(same.effort == .high)
    }

    @Test func cacheBreakInEstimate() {
        var i = work(.m) { $0.sessionModel = "sonnet"; $0.rungFloor = 3; $0.sessionTokens = 200_000 }
        // R3 ≈ 3.7 × $0.54 = $2.00 plus 200k × $10/M = $2.00 of cache writes: $4.00 does not fit in $3.
        i.budgetLeftLE = 3.0
        let d = pick(i)
        #expect(d.model == "sonnet", "stepping down below opus removes the cache break"); #expect(!d.cacheBreak)
        #expect(d.reason.contains("held at"))
        i.budgetLeftLE = 4.5
        #expect(pick(i).model == "opus")
    }

    @Test func escalationHeldByBudget() {
        let held = ModePolicy.escalation(counted: 2, escalatedSinceClaim: false, currentLevel: 1, floor: 0, tierL: false, p0: false,
                                         mP0OrRisk: false, rejections: 0, rejectionsApplied: false, cappedInRow: 0, budgetLeftLE: 0.5,
                                         estimate: { _ in 0.92 }, ultraProposed: false)
        guard case .heldByBudget(let why)? = held.first else { Issue.record("not held: \(held)"); return }
        #expect(why.contains("R2"))
        // The selection steps down too, and says so.
        let d = pick(work(.m) { $0.riskTags = ["hotPath"]; $0.budgetLeftLE = 0.6 })
        #expect(d.rung == .r1); #expect(d.reason.contains("held at R1 by budget"))
        #expect(d.maxBudgetUSD == 0.6, "the cap never exceeds what the item has left")
    }

    @Test func belowQuickEstimateNotLaunched() {
        let d = pick(work(.s) { $0.budgetLeftLE = 0.1 })
        #expect(!d.launch); #expect(d.reason.contains("not launched"))
        #expect(!pick(work(.s) { $0.budgetLeftLE = 0 }).launch)
        #expect(pick(work(.s) { $0.budgetLeftLE = 0.6 }).launch)
    }

    @Test func lowUsageModeCapsR2AndOpusLow() {
        let l = pick(work(.l) { $0.usageMode = .low })
        #expect(l.rung == .opusLow); #expect(l.model == "opus"); #expect(l.effort == .low)
        let m = pick(work(.m) { $0.usageMode = .low; $0.rungFloor = 4 })
        #expect(m.rung == .r2); #expect(m.model == "sonnet")
        let prd = pick(work(.s) { $0.usageMode = .low; $0.decidingPRD = true })
        #expect(prd.rung == .opusLow)
    }

    @Test func maxUsageModeBoostsP0() {
        #expect(pick(work(.m) { $0.usageMode = .max; $0.priority = 0 }).rung == .r3)
        #expect(pick(work(.s) { $0.usageMode = .max; $0.priority = 0 }).rung == .r2)
        #expect(pick(work(.l) { $0.usageMode = .max; $0.priority = 0 }).rung == .r4)
        #expect(pick(work(.s) { $0.usageMode = .max }).rung == .r1, "no boost without P0 or the critical path")
    }

    @Test func paceAheadClampsEffortAndNoUltra() {
        let d = pick(work(.m) { $0.pace = .ahead; $0.riskTags = ["hotPath"]; $0.rungFloor = 3 })
        #expect(d.rung == .r2, "no rung above base"); #expect(d.effort == .medium, "effort −1")
        #expect(pick(work(.s) { $0.pace = .ahead }).effort == .low)
        #expect(pick(work(.s) { $0.pace = .ahead }).mode != .ultra)
    }

    @Test func paceClosedCapsR1IgnoresFloor() {
        let d = pick(work(.m) { $0.pace = .closed; $0.rungFloor = 2; $0.priority = 0; $0.planFirstGate = true })
        #expect(d.rung == .r1); #expect(d.reason.contains("floor ignored")); #expect(!d.planFirst)
        let l = pick(work(.l) { $0.pace = .closed })
        #expect(l.rung == .opusLow, "Opus-required work runs at opus-low")
    }

    @Test func overageAllowedClampsAllModes() {
        let d = pick(work(.m) { $0.overageAllowed = true; $0.riskTags = ["hotPath"] })
        #expect(d.rung == .r1); #expect(d.subagents == .off)
        #expect(pick(work(.l) { $0.overageAllowed = true }).rung == .opusLow)
        var review = ModeInputs(); review.turnKind = .review; review.tier = .l; review.overageAllowed = true
        #expect(pick(review).rung == .r1)
        #expect(pick(work(.s) { $0.overageAllowed = true }).reason.contains("extra usage is on"))
    }

    @Test func proTierClamps() {
        let d = pick(work(.m) { $0.planTier = .pro; $0.rungFloor = 4 })
        #expect(d.rung == .r2)
        #expect(pick(work(.l) { $0.planTier = .pro }).rung == .opusLow)
        #expect(PlanTier.pro.maxRung == 2); #expect(!PlanTier.pro.allowsTask); #expect(!PlanTier.pro.allowsUltra)
        #expect(UltraCaps.of(.pro).perCompanyDay == 0); #expect(UltraCaps.of(.max5x).slots == 3)
    }

    @Test func fiveHourHighRemovesTask() {
        let d = pick(work(.s) { $0.fiveHourUtil = 0.9; $0.subagentGate = true })
        #expect(d.subagents == .off); #expect(d.effort == .low)
        let ok = pick(work(.s) { $0.fiveHourUtil = 0.5; $0.subagentGate = true })
        #expect(ok.subagents == .forced(model: "haiku", depth: 1, concurrent: 2))
    }

    @Test func opusScarceFallsToSonnetHigh() {
        let d = pick(work(.l) { $0.opusScarce = true })
        #expect(d.rung == .r2); #expect(d.model == "sonnet"); #expect(d.effort == .high)
        #expect(pick(work(.s) { $0.opusScarce = true; $0.decidingArchitecture = true }).model == "opus")
    }

    @Test func xhighMaxNeverAutomatic() {
        for tier in EffortTier.allCases {
            for mode in UsageMode.allCases {
                for floor in 0...4 {
                    for kind in [TurnKind.work, .review, .notice, .plan] {
                        var i = work(tier) { $0.usageMode = mode; $0.rungFloor = floor; $0.priority = 0; $0.blockingCount = 3 }
                        i.turnKind = kind
                        let d = pick(i)
                        #expect(d.effort <= .high); #expect(d.maxEffortLevel <= .high); #expect(d.mode != .ultra)
                    }
                }
            }
        }
    }

    @Test func subagentGateOffMeansNoTask() {
        #expect(!SubagentGate.passed(profile: .workspace)); #expect(!SubagentGate.passed(profile: .full))
        #expect(pick(work(.m)).subagents == .off)
        #expect(pick(work(.m) { $0.riskTags = ["hotPath"] }).subagents == .off)
        // Once a gate passes (5-lite), Standard forces haiku workers and Deep sonnet workers, depth 1.
        #expect(pick(work(.s) { $0.subagentGate = true }).subagents == .forced(model: "haiku", depth: 1, concurrent: 2))
        #expect(pick(work(.m) { $0.subagentGate = true; $0.priority = 0 }).subagents == .forced(model: "sonnet", depth: 1, concurrent: 3))
        #expect(pick(work(.s) { $0.subagentGate = true; $0.usageMode = .low }).subagents == .off)
    }

    @Test func trustT0CapsR1() {
        let d = pick(work(.m) { $0.trust = "T0"; $0.riskTags = ["hotPath"]; $0.subagentGate = true })
        #expect(d.rung == .r1); #expect(d.subagents == .off)
    }

    @Test func reasonsRecorded() {
        let d = pick(work(.m) { $0.riskTags = ["migration"]; $0.pace = .ahead; $0.rungFloor = 3 })
        #expect(d.reasons.count >= 3)
        #expect(d.reasons.contains { $0.hasPrefix("tier M") })
        #expect(d.reasons.contains { $0.hasPrefix("floor R3") })
        #expect(d.reasons.contains { $0.hasPrefix("ahead of pace") })
        #expect(d.summary.hasPrefix("Deep R2"))
        // An owner pin outside the allowlist is refused, and nothing launches.
        let pinned = pick(work(.s) { $0.agentModel = "fable" })
        #expect(!pinned.launch); #expect(pinned.refusal == "model fable is not allowed in Brahma turns")
        #expect(pick(work(.s) { $0.agentModel = "haiku" }).model == "haiku")
    }

    /// Fix 1 C2: opus being scarce never lifts a turn above the extra-usage or closed-pace clamp.
    @Test func opusScarceNeverLiftsTheOverageOrClosedClamp() {
        let cases: [(EffortTier, (inout ModeInputs) -> Void)] = [
            (.l, { $0.overageAllowed = true; $0.opusScarce = true }),
            (.l, { $0.pace = .closed; $0.opusScarce = true }),
            (.m, { $0.overageAllowed = true; $0.opusScarce = true; $0.rungFloor = 3 }),
            (.m, { $0.pace = .closed; $0.opusScarce = true; $0.rungFloor = 4 }),
            (.m, { $0.overageAllowed = true; $0.opusScarce = true; $0.riskTags = ["hotPath"]; $0.usageMode = .max; $0.priority = 0 }),
        ]
        for (tier, edit) in cases {
            let d = pick(work(tier, edit))
            #expect(d.rung.level <= 1 && !d.rung.isOpus, "\(d.rung) \(d.reason)")
            #expect(d.model == "sonnet")
        }
        // Without the clamps it still falls to Sonnet high.
        #expect(pick(work(.l) { $0.opusScarce = true }).rung == .r2)
    }

    /// Fix 1 Q3: a manager's or executive's itemless turn keeps Quick's model and effort but gets Standard caps, so a lead can
    /// break work down; everyone else's stays Quick.
    @Test func leadItemlessTurnsGetStandardCaps() {
        var i = ModeInputs(); i.turnKind = .work; i.hasItem = false
        let ic = pick(i)
        #expect(ic.maxTurns == 10); #expect(ic.quotas == ModeCaps.quick.quotas)
        i.leadRole = true
        let lead = pick(i)
        #expect(lead.mode == .quick); #expect(lead.rung == .r0); #expect(lead.effort == .low)
        #expect(lead.maxTurns == 40); #expect(lead.maxBudgetUSD == 2.00); #expect(lead.wallClock == .seconds(1200))
        #expect(lead.quotas == ModeCaps.standard.quotas); #expect(lead.reason.contains("Standard caps"))
        // A lead's notice turn is still plain Quick.
        i.turnKind = .notice
        #expect(pick(i).maxTurns == 10)
    }

    /// Fix 1 minor: the plan turn is bound by the extra-usage, closed-pace and Pro clamps like a work turn.
    @Test func planTurnIsClamped() {
        var plan = work(.l); plan.turnKind = .plan
        #expect(pick(plan).model == "opus")
        for edit: (inout ModeInputs) -> Void in [{ $0.overageAllowed = true }, { $0.pace = .closed }, { $0.planTier = .pro }] {
            var i = plan; edit(&i)
            let d = pick(i)
            #expect(d.mode == .plan); #expect(d.rung == .opusLow); #expect(d.effort == .low, "\(d.reason)")
            #expect(d.reason.contains("plan turn held at opus-low"))
        }
        var m = work(.m) { $0.riskTags = ["migration"]; $0.intensity = .thorough }; m.turnKind = .plan; m.overageAllowed = true
        let d = pick(m)
        #expect(d.rung == .r1); #expect(d.model == "sonnet"); #expect(d.effort == .medium)
    }

    @Test func calibrationReplacesThePrior() {
        var cal = ModeCalibration()
        #expect(abs(cal.estimate(rung: .r1, model: "sonnet", effort: .medium) - 0.54) < 1e-9)
        #expect(abs(cal.estimate(rung: .r0, model: "haiku", effort: .low) - 0.027) < 1e-9)
        for _ in 0..<3 { cal.record(model: "claude-sonnet-5-5", effort: .medium, costLE: 1.0) }
        #expect(abs(cal.estimate(rung: .r1, model: "sonnet", effort: .medium) - 1.0) < 1e-9)
        #expect(ModeCaps.quick.quotas == ModeQuotas(posts: 3, itemsCreated: 1, comments: 5))
        #expect(ModeCaps.deep.budgetLE(opus: true) == 8.00)
    }
}

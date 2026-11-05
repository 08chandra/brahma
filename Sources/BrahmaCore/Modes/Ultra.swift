import Foundation

// Ultra (Task 14u; design agent-modes-design.md §2.2–§2.3, §3.6–§3.8). Claude's workflow engine under Brahma's caps: one
// approved run of an inline Workflow script on the sandboxed profile, admitted only when every hard gate holds, with its cap
// reserved up front and charged in full when it is killed. Everything here is pure; the orchestrator gathers the inputs.

/// The two Ultra variants. They are enforced only by the budget cap, the workflow concurrency variable and the engine's
/// agent-count kill; `workflowSizeGuideline` and the digest line are advisory.
public enum UltraVariant: String, Codable, CaseIterable, Sendable {
    /// Ultra-small: size `small`, $4 LE, killed past 5 workflow agents.
    case small = "ultra_small"
    /// Ultra: size `medium`, $15 LE, killed past 10 workflow agents.
    case full = "ultra"

    public var title: String { self == .small ? "Ultra-small" : "Ultra" }
    /// Settings `workflowSizeGuideline`.
    public var sizeGuideline: String { self == .small ? "small" : "medium" }
    /// `--max-budget-usd`, and what a killed run is charged at least.
    public var capLE: Double { self == .small ? 4.00 : 15.00 }
    /// Distinct `workflow_progress[].agentId`s above which the watchdog stops the turn (`stopReason=agentCap`).
    public var agentKill: Int { self == .small ? 5 : 10 }

    /// Both variants: 45 minutes of wall clock.
    public static let wallClock: Duration = .seconds(45 * 60)
    /// `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`: the wall clock less five minutes (40 min), so the CLI gives up on background
    /// work before the engine kills the turn.
    public static let bgCeiling: Duration = wallClock - .seconds(5 * 60)
    public static var bgCeilingMilliseconds: Int { Int(bgCeiling.components.seconds) * 1000 }
    public static let maxTurns = 100
    /// The forced worker model of every Ultra sub-agent and workflow agent.
    public static let workerModel = "sonnet"
    public static let maxConcurrentSubagents = 3

    /// `ultra_small`, `ultra-small`, `ultrasmall` or `ultra`; nil otherwise.
    public init?(requested raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "ultra_small", "ultrasmall": self = .small
        case "ultra": self = .full
        default: return nil
        }
    }
}

/// The Ultra caps per plan tier (design §3.6, pinned numbers).
public struct UltraCaps: Equatable, Sendable {
    /// `ultraShare`'s default: the share of the company's weekly share (in $LE) Ultra may use.
    public var share: Double
    /// Ultra runs per company per owner-calendar day.
    public var perCompanyDay: Int
    /// Of those, full Ultra runs (max5x: at most one).
    public var fullPerCompanyDay: Int
    /// Ultra turns running at once, engine-wide.
    public var concurrent: Int
    /// `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS`.
    public var workflowAgents: Int
    /// Slots one Ultra turn takes: `1 + workflowAgents`. Admission needs one more free (for reviews and the critical path).
    public var slots: Int

    public static let max5x = UltraCaps(share: 0.15, perCompanyDay: 2, fullPerCompanyDay: 1, concurrent: 1, workflowAgents: 2, slots: 3)
    public static let max20x = UltraCaps(share: 0.15, perCompanyDay: 6, fullPerCompanyDay: 6, concurrent: 2, workflowAgents: 4, slots: 5)
    public static let pro = UltraCaps(share: 0, perCompanyDay: 0, fullPerCompanyDay: 0, concurrent: 0, workflowAgents: 0, slots: 0)

    public static func of(_ tier: PlanTier) -> UltraCaps {
        switch tier {
        case .max5x: max5x
        case .max20x: max20x
        case .pro: pro
        }
    }
}

/// What an Ultra turn runs with, carried on its `ModeDecision` (`workflow`).
public struct UltraWorkflow: Equatable, Sendable {
    public var variant: UltraVariant
    public var approver: UltraApprover
    /// `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS` (2 on max5x, 4 on max20x).
    public var maxConcurrentAgents: Int

    public init(variant: UltraVariant, approver: UltraApprover, maxConcurrentAgents: Int) {
        self.variant = variant; self.approver = approver; self.maxConcurrentAgents = maxConcurrentAgents
    }
}

/// Who approved the run: named in the digest line, never claimed falsely.
public enum UltraApprover: String, Codable, Sendable, Equatable {
    case owner, policy

    /// `owner` or `Brahma policy`, as the digest line names it.
    public var digestName: String { self == .owner ? "owner" : "Brahma policy" }
}

/// An Ultra run the engine admitted for this turn (`ModeInputs.ultra`): `ModePolicy.select` compiles R5 from it.
public struct UltraAdmission: Equatable, Sendable {
    public var variant: UltraVariant
    public var approver: UltraApprover
    public var workflowAgents: Int
    /// The eligibility basis (`UltraEligibility.basis`), for the turn's mode reason.
    public var basis: String

    public init(variant: UltraVariant, approver: UltraApprover, workflowAgents: Int, basis: String) {
        self.variant = variant; self.approver = approver; self.workflowAgents = workflowAgents; self.basis = basis
    }
}

// MARK: Eligibility

/// Ultra eligibility (design §3.6), on effective values only: a self-authored or unconfirmed tier, priority or type never
/// qualifies (`EffectiveSpec`).
public enum UltraEligibility {
    /// Item types (as the confirmed spec names them) that qualify by themselves.
    public static let types: Set<String> = ["audit", "migration", "research-spike", "spike", "broad-refactor", "refactor"]

    /// Why the item qualifies, or nil when it does not: a confirmed tier L; a confirmed P0 blocking at least two; a confirmed
    /// qualifying type; or the R4 escalation trigger (the failure path).
    public static func basis(_ i: ModeInputs) -> String? {
        guard i.turnKind == .work, i.hasItem else { return nil }
        if i.tier == .l { return "confirmed tier L" }
        if i.priority == 0, i.blockingCount >= 2 { return "confirmed P0 blocking \(i.blockingCount)" }
        if let t = i.itemType.map(normalize), types.contains(t) { return "confirmed \(t) item" }
        if i.ultraTrigger { return "R4 escalation (repeated counted failures)" }
        return nil
    }

    /// Nil when eligible, else the refusal.
    public static func check(_ i: ModeInputs) -> String? {
        basis(i) == nil ? "not eligible: needs a confirmed tier L, a confirmed P0 blocking 2+, a confirmed audit, migration, "
            + "research spike or broad refactor, or the R4 escalation" : nil
    }

    static func normalize(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
    }
}

// MARK: Hard gates

/// One failed hard gate: its number (1–10, design §3.6) and the one reason string recorded on the turn.
public struct UltraRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    public var gate: Int
    public var reason: String

    public init(gate: Int, reason: String) { self.gate = gate; self.reason = reason }
    public var description: String { reason }
}

/// Everything the hard gates read, gathered by the engine right before admission.
public struct UltraGateInputs: Equatable, Sendable {
    // 1. Profile and probes.
    public var profile: PermissionProfile = .workspace
    /// Probe gates passed for this CLI fingerprint and the Ultra shape.
    public var passedGates: Set<String> = []
    /// The init `tools` of the Ultra shape (recorded by U-1) contain `Workflow`.
    public var initToolsHaveWorkflow = false
    /// The CLI version, for the explainer.
    public var cliVersion: String? = nil
    // 2. Overage: admitted only on positive evidence that extra usage is off.
    public var overageStatus: String? = nil
    public var isUsingOverage = false
    /// `get_usage`'s `rate_limits.extra_usage.is_enabled` (the fresh reading; nil: not read).
    public var extraUsageEnabled: Bool? = nil
    // 3. Plan tier.
    public var planTier: PlanTier = .max5x
    public var planTierConfirmed = false
    // 4. Calibration.
    public var weekWindows = 0
    public var fiveHourWindows = 0
    public var pctPerDollar: Double? = nil
    public var pctPerDollar5h: Double? = nil
    // 5. Weekly pace.
    public var pace: PaceState? = nil
    public var sevenDayUtil: Double? = nil
    public var allowedWeek: Double? = nil
    // 6. Five hours: the fresh `get_usage` reading (nil: none could be taken).
    public var freshFiveHourUtil: Double? = nil
    /// Unspent cap of every open Ultra reservation, engine-wide.
    public var openReservationLE: Double = 0
    // 7. Allowance.
    public var allowanceLeftLE: Double? = nil
    // 8. Caps.
    public var ultraRunsToday = 0
    public var fullUltraRunsToday = 0
    public var runningUltra = 0
    // 9. Slots: the company's free slots under its usage-mode cap, this turn not counted as running.
    public var freeSlots = 0
    // 10. Mode and trust.
    public var usageMode: UsageMode = .balanced
    public var trust = "T1"
    public var sessionTainted = false
    /// The role card's rung cap (nil: none); a role capped below R5 never runs Ultra.
    public var roleMaxRung: Int? = nil

    public init() {}
}

public enum UltraGate {
    /// Gate 6: the fresh five-hour reading must be at most this...
    public static let fiveHourNow = 0.60
    /// ...and the projection with every open reservation and this run's cap (p80) at most this.
    public static let fiveHourProjected = 0.85
    /// The probe gates gate 1 needs: every gate of the Ultra shape (fix round 1, I3: Ultra stays off until `brahma mode gates
    /// --run` recorded every Ultra gate passed). V-9 is Task 3's nested-claude canary probe, pending the owner.
    public static var requiredGates: [String] { ProbeGates.catalog(.ultra) }
    /// `overageStatus` values that say extra usage is off (S27: anything else, or nothing, is not evidence).
    public static let overageOff: Set<String> = ["rejected", "disabled", "not_allowed", "off"]
    /// The trust levels that may run Ultra (fail closed: an unknown level may not).
    public static let trustedLevels: Set<String> = ["T1", "T2", "T3", "T4"]

    /// The hard gates in order; the first that fails refuses the run with its one reason. A refusal runs the computed
    /// non-Ultra rung (`ModeInputs.ultraRefusal`).
    public static func admit(_ variant: UltraVariant, _ i: UltraGateInputs) -> Result<UltraVariant, UltraRefusal> {
        if let first = failures(variant, i).first { return .failure(first) }
        return .success(variant)
    }

    /// The gates up to `through` (inclusive) that fail, in order. `skipFresh`: gate 6 is not judged (the engine takes the
    /// fresh reading only once everything cheaper has passed).
    public static func failures(_ variant: UltraVariant, _ i: UltraGateInputs, through last: Int = 10,
                                skipFresh: Bool = false) -> [UltraRefusal] {
        var out: [UltraRefusal] = []
        let caps = UltraCaps.of(i.planTier)
        let cap = variant.capLE
        func fail(_ gate: Int, _ why: String) { if gate <= last { out.append(UltraRefusal(gate: gate, reason: why)) } }
        // 1. Profile and probes.
        if i.profile != .sandboxed {
            fail(1, "Ultra runs only on the sandboxed profile")
        } else if let missing = requiredGates.first(where: { !i.passedGates.contains($0) }) {
            fail(1, "probe gate \(missing) failing for claude \(i.cliVersion ?? "?")")
        } else if !i.initToolsHaveWorkflow {
            fail(1, "the CLI offers no Workflow tool")
        }
        // 2. No overage possible, on positive evidence (S27): the fresh reading says extra usage is off, or the CLI's status is a
        // known "off" and no overage is in use. Nothing or an unknown status fails closed (before the fresh reading is taken,
        // only a positive "on" is judged).
        if i.overageStatus == "allowed" || i.isUsingOverage || i.extraUsageEnabled == true {
            fail(2, "extra usage is on")
        } else if !skipFresh, i.extraUsageEnabled != false, !(i.overageStatus.map(overageOff.contains) ?? false) {
            fail(2, "extra usage status unknown (\(i.overageStatus ?? "none"))")
        }
        // 3. Plan tier.
        if i.planTier == .pro {
            fail(3, "the Pro plan has no Ultra")
        } else if !i.planTierConfirmed {
            fail(3, "plan tier not confirmed")
        }
        // 4. Calibrated.
        let windows = min(i.weekWindows, i.fiveHourWindows)
        if windows < UsageCalibration.minWindows || i.pctPerDollar == nil || i.pctPerDollar5h == nil {
            fail(4, "not calibrated yet (\(windows)/\(UsageCalibration.minWindows) windows)")
        }
        // 5. Weekly pace, with every open reservation and this cap at p80.
        if let pace = i.pace, pace == .ahead || pace == .closed {
            fail(5, pace == .closed ? "weekly pace closed" : "ahead of the weekly pace")
        } else if let per = i.pctPerDollar, let used = i.sevenDayUtil, let allowed = i.allowedWeek,
                  used + (i.openReservationLE + cap) * per > allowed + 1e-9 {
            fail(5, "the run would pass the weekly pace (\(pct(used + (i.openReservationLE + cap) * per)) of \(pct(allowed)) allowed)")
        } else if i.sevenDayUtil == nil || i.allowedWeek == nil {
            fail(5, "no weekly usage reading")
        }
        // 6. Five hours, from a fresh reading.
        if !skipFresh {
            if let now = i.freshFiveHourUtil {
                if now > fiveHourNow + 1e-9 {
                    fail(6, "5-hour use \(pct(now)) is above \(pct(fiveHourNow))")
                } else if let per = i.pctPerDollar5h, now + (i.openReservationLE + cap) * per > fiveHourProjected + 1e-9 {
                    fail(6, "5-hour projection \(pct(now + (i.openReservationLE + cap) * per)) would pass \(pct(fiveHourProjected))")
                }
            } else {
                fail(6, "no fresh 5-hour reading (get_usage)")
            }
        }
        // 7. The Ultra allowance.
        if let left = i.allowanceLeftLE {
            if left + 1e-9 < cap { fail(7, "allowance used") }
        } else {
            fail(7, "allowance unknown until calibrated")
        }
        // 8. Caps.
        if i.ultraRunsToday >= caps.perCompanyDay {
            fail(8, "\(i.ultraRunsToday) Ultra run(s) today already (at most \(caps.perCompanyDay))")
        } else if variant == .full, i.fullUltraRunsToday >= caps.fullPerCompanyDay {
            fail(8, "\(i.fullUltraRunsToday) full Ultra run(s) today already (at most \(caps.fullPerCompanyDay))")
        }
        if i.runningUltra >= caps.concurrent { fail(8, "another Ultra turn is running (at most \(caps.concurrent) at once)") }
        // 9. Slots, one left free.
        if i.freeSlots < caps.slots + 1 {
            if i.planTier == .max5x, i.usageMode != .max, i.planTier.modeCap(i.usageMode) < caps.slots + 1 {
                fail(9, "needs the Max usage mode")
            } else {
                fail(9, "no free slots (\(max(0, i.freeSlots)) free, Ultra needs \(caps.slots + 1))")
            }
        }
        // 10. Mode and trust.
        if i.usageMode == .low { fail(10, "Low usage mode") }
        if !trustedLevels.contains(i.trust) { fail(10, "trust \(i.trust)") }
        if let cap = i.roleMaxRung, cap < ModeRung.r5.level { fail(10, "the role is capped at R\(cap)") }
        if i.sessionTainted { fail(10, "the session read outside content") }
        return out
    }

    static func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

// MARK: Approval

/// Where an Ultra request came from (design §3.6 approval table).
public enum UltraOrigin: Equatable, Sendable {
    /// The item's assignee asked (`request_mode`).
    case assignee
    /// A manager or executive in the item's chain asked (`request_mode`): the endorsement Ultra-small needs under `important`.
    case lead
    /// The engine proposed it after repeated counted failures (§3.3): always the owner's.
    case failurePath
    /// The owner set the item's intensity to Ultra: one run of either variant, approved.
    case ownerIntensity
}

public enum UltraRoute: Equatable, Sendable {
    /// An owner `boost` ask.
    case ownerAsk
    /// Approved by Brahma policy; the owner gets an FYI.
    case policy
    /// Already the owner's decision.
    case ownerApproved
}

public enum UltraApproval {
    /// The approval table (design §3.6). Ultra is never a reserved matter: gate 2 guarantees it spends no money.
    public static func route(_ variant: UltraVariant, preset: AutonomyPreset, origin: UltraOrigin, escalated: Bool) -> UltraRoute {
        switch origin {
        case .ownerIntensity: return .ownerApproved
        case .failurePath: return .ownerAsk
        case .assignee, .lead: break
        }
        switch preset {
        case .everything: return .ownerAsk
        case .auto: return .policy
        case .important: return variant == .small && origin == .lead && !escalated ? .policy : .ownerAsk
        }
    }

    public static let runOnce = "Run Ultra once"
    public static let keepGoing = "No, keep going"
    /// Approve or reject: the owner's decision has no third path, so the brief's "Thorough instead" is not offered (fix round
    /// 1, M1; the owner can still set the item's intensity to Thorough).
    public static var options: [AskOption] { [AskOption(label: runOnce), AskOption(label: keepGoing)] }
    /// A boost ask expires after one active day.
    public static let expirySeconds: Double = 86_400

    /// `"<KEY> '<title>' wants an Ultra run: <reason>. Up to $<cap> LE ≈ <pct>% of this week (Ultra allowance left: <n>%)."`
    public static func cardText(key: String, title: String, reason: String, variant: UltraVariant, pctPerDollar: Double?,
                                allowanceLeftShare: Double?) -> String {
        let pct = pctPerDollar.map { "\(Int((variant.capLE * $0 * 100).rounded()))" } ?? "?"
        let left = allowanceLeftShare.map { "\(Int((max(0, $0) * 100).rounded()))" } ?? "?"
        return "\(key) '\(Store.flat(title, max: 120))' wants an Ultra run: \(Store.flat(reason, max: 300)). Up to "
            + "$\(TurnProfileCompiler.money(variant.capLE)) LE ≈ \(pct)% of this week (Ultra allowance left: \(left)%)."
    }
}

// MARK: Digest, accounting, plan tier

public enum UltraDigest {
    /// The engine's line in the Ultra turn's digest: the Workflow tool's description wants an explicit opt-in, and this names
    /// the real approver (never the owner when policy approved).
    public static func line(_ w: UltraWorkflow) -> String {
        "This turn is opted into multi-agent orchestration (approved by: \(w.approver.digestName)): you may use the Workflow tool "
            + "with an inline script. Hard cap $\(TurnProfileCompiler.money(w.variant.capLE)) LE; at most \(w.variant.agentKill) "
            + "agents, or the turn is stopped."
    }
}

public enum UltraAccounting {
    /// `stopReason` of a turn the watchdog stopped for spawning too many workflow agents.
    public static let agentCapStop = "agentCap"

    /// What an Ultra turn is charged: its own cost when it ended by itself; max(its cost, the cap) when it was killed (the
    /// watchdog, the wall clock, the owner's stop, SIGTERM with no result, or background work still pending).
    public static func charge(cost: Double?, cap: Double, killed: Bool) -> Double {
        let own = max(0, cost ?? 0)
        return killed ? max(own, cap) : own
    }

}

/// The plan tier the engine uses (design §3.7, owner answer 2026-10-21): the configured tier, unless the CLI's
/// `get_usage.subscription_type` disagrees, in which case the lower of the two, with an engine alert asking the owner to
/// confirm. The CLI reports `max` for both Max plans, so `max` agrees with max5x and max20x.
public struct PlanTierEffective: Equatable, Sendable {
    public var tier: PlanTier
    /// The CLI's report agrees with the configured tier.
    public var confirmed: Bool
    /// The alert text when they disagree.
    public var mismatch: String?

    static func rank(_ t: PlanTier) -> Int {
        switch t {
        case .pro: 0
        case .max5x: 1
        case .max20x: 2
        }
    }

    public static func resolve(configured: PlanTier, reported: String?) -> PlanTierEffective {
        guard let raw = reported?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return PlanTierEffective(tier: configured, confirmed: false, mismatch: nil)
        }
        let r = raw.lowercased()
        if r == "max", configured != .pro { return PlanTierEffective(tier: configured, confirmed: true, mismatch: nil) }
        guard let tier = PlanTier(reportedSubscription: raw) else {
            return PlanTierEffective(tier: configured, confirmed: false,
                                     mismatch: "the CLI reports the unknown plan '\(Store.flat(raw, max: 40))'; Brahma is set to \(configured.rawValue)")
        }
        if tier == configured { return PlanTierEffective(tier: configured, confirmed: true, mismatch: nil) }
        let lower = rank(tier) < rank(configured) ? tier : configured
        return PlanTierEffective(tier: lower, confirmed: false,
                                 mismatch: "the CLI reports a \(tier.rawValue) plan but Brahma is set to \(configured.rawValue); using "
                                     + "\(lower.rawValue) until you confirm your plan (brahma settings plan)")
    }
}

// MARK: Status (F9)

/// Why Ultra cannot run for a company right now (F9): shown by `brahma doctor`, the stall explainer and
/// `brahma mode ultra-status <co>`. Empty when the gates that do not depend on one run would all pass.
public enum UltraStatus {
    public static func explain(_ i: UltraGateInputs, variant: UltraVariant = .small) -> [String] {
        // Gate 6 needs a fresh reading per run, and the per-run caps (gate 8) change by the hour: the explainer reports the
        // standing reasons.
        var out: [String] = []
        for f in UltraGate.failures(variant, i, skipFresh: true) where f.gate != 8 {
            let text: String
            switch f.gate {
            case 9 where f.reason.hasPrefix("needs the Max"): text = "needs the Max usage mode"
            case 9: text = "no free slots"
            default: text = f.reason
            }
            if !out.contains(text) { out.append(text) }
        }
        return out
    }
}

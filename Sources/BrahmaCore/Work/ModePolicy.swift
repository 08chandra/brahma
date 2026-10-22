import Foundation

// Work modes (Task 14c; design agent-modes-design.md §2–§3). The engine decides and agents can only ask: `ModePolicy.select` is
// pure code with one reason string per step, and `TurnProfileCompiler` is the only place its decision becomes argv, settings and
// engine environment. Ultra (R5) and sub-agents on the sandboxed profile are Plan 5-lite's; nothing here selects them.

/// The intensity of one turn. Plan-first is a modifier: the plan turn itself runs as `plan`.
public enum WorkMode: String, Codable, CaseIterable, Sendable {
    case quick, standard, deep, plan, ultra

    public var title: String {
        switch self {
        case .quick: "Quick"
        case .standard: "Standard"
        case .deep: "Deep"
        case .plan: "Plan"
        case .ultra: "Ultra"
        }
    }
}

/// `--effort`. `xhigh` and `max` are never chosen automatically.
public enum Effort: String, Codable, CaseIterable, Sendable, Comparable {
    case low, medium, high, xhigh, max

    var index: Int { Effort.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Effort, b: Effort) -> Bool { a.index < b.index }

    /// One step lower per `steps`, never below `low`.
    public func lowered(by steps: Int) -> Effort { Effort.allCases[Swift.max(0, index - Swift.max(0, steps))] }
}

/// A rung is a (model, effort) pair. `opusLow` is used when an Opus-required turn is clamped.
public enum ModeRung: String, Codable, CaseIterable, Sendable {
    case r0, r1, r2, r3, r4, opusLow

    /// Stored on the turn (`turn.rung`); opus-low is stored as 3 with effort `low`.
    public var level: Int {
        switch self {
        case .r0: 0
        case .r1: 1
        case .r2: 2
        case .r3, .opusLow: 3
        case .r4: 4
        }
    }

    public var isOpus: Bool { self == .r3 || self == .r4 || self == .opusLow }

    public var effort: Effort {
        switch self {
        case .r0, .opusLow: .low
        case .r1, .r3: .medium
        case .r2, .r4: .high
        }
    }

    public var label: String { self == .opusLow ? "opus-low" : "R\(level)" }

    /// Estimated cost relative to R1 (Sonnet medium); calibration replaces it (design §2.1).
    public var costFactor: Double {
        switch self {
        case .r0: 0.5
        case .r1: 1
        case .r2: 1.7
        case .opusLow: 1.9
        case .r3: 3.7
        case .r4: 5.1
        }
    }

    public static func at(level: Int) -> ModeRung {
        switch level {
        case ...0: .r0
        case 1: .r1
        case 2: .r2
        case 3: .r3
        default: .r4
        }
    }

    /// One rung up, effort first (R4 stays R4).
    var up: ModeRung {
        switch self {
        case .r0: .r1
        case .r1: .r2
        case .r2, .opusLow: .r3
        case .r3, .r4: .r4
        }
    }

    /// One rung down by cost.
    var down: ModeRung? {
        switch self {
        case .r0: nil
        case .r1: .r0
        case .r2: .r1
        case .opusLow: .r2
        case .r3: .opusLow
        case .r4: .r3
        }
    }

    var mode: WorkMode {
        switch self {
        case .r0: .quick
        case .r1: .standard
        case .r2, .r3, .r4, .opusLow: .deep
        }
    }
}

/// Sub-agents (`Task`): off on every 3a profile. `forced` is what the compiler emits once the sub-agent gate passes (5-lite).
public enum SubagentPolicy: Equatable, Sendable {
    case off
    case forced(model: String, depth: Int, concurrent: Int)
}

/// Per-turn MCP quotas, counted inside the turn's `brahma mcp` process (design §4.1). `highRisk` nil means no quota.
public struct ModeQuotas: Equatable, Sendable {
    public var posts: Int
    public var itemsCreated: Int
    public var comments: Int
    public var highRisk: Int?

    public init(posts: Int, itemsCreated: Int, comments: Int, highRisk: Int? = nil) {
        self.posts = posts; self.itemsCreated = itemsCreated; self.comments = comments; self.highRisk = highRisk
    }

    public static let postsVariable = "BRAHMA_MCP_QUOTA_POSTS"
    public static let itemsVariable = "BRAHMA_MCP_QUOTA_ITEMS"
    public static let commentsVariable = "BRAHMA_MCP_QUOTA_COMMENTS"
    public static let highRiskVariable = "BRAHMA_MCP_QUOTA_HIGHRISK"

    /// The `BRAHMA_MCP_QUOTA_*` entries of the per-turn MCP config.
    public var environment: [String: String] {
        var env = [Self.postsVariable: "\(posts)", Self.itemsVariable: "\(itemsCreated)", Self.commentsVariable: "\(comments)"]
        if let highRisk { env[Self.highRiskVariable] = "\(highRisk)" }
        return env
    }

    /// Read back by `brahma mcp`; nil when the turn carries no quotas (Plan 1 turns, review turns).
    public init?(environment env: [String: String]) {
        func value(_ name: String) -> Int? { env[name].flatMap { Int($0) }.map { max(0, $0) } }
        guard let posts = value(Self.postsVariable), let items = value(Self.itemsVariable),
              let comments = value(Self.commentsVariable) else { return nil }
        self.init(posts: posts, itemsCreated: items, comments: comments, highRisk: value(Self.highRiskVariable))
    }
}

/// One row of the mode table (design §2.2): what the compiler emits for a mode.
public struct ModeCaps: Equatable, Sendable {
    public var maxTurns: Int
    /// The `--max-budget-usd` cap before the item's remaining $LE lowers it; opus turns of Deep and Plan get the larger one.
    public var budgetSonnetLE: Double
    public var budgetOpusLE: Double
    public var wallClock: Duration
    public var quotas: ModeQuotas

    public static let quick = ModeCaps(maxTurns: 10, budgetSonnetLE: 0.30, budgetOpusLE: 0.30, wallClock: .seconds(5 * 60),
                                       quotas: ModeQuotas(posts: 3, itemsCreated: 1, comments: 5))
    public static let standard = ModeCaps(maxTurns: 40, budgetSonnetLE: 2.00, budgetOpusLE: 2.00, wallClock: .seconds(20 * 60),
                                          quotas: ModeQuotas(posts: 10, itemsCreated: 3, comments: 20))
    public static let deep = ModeCaps(maxTurns: 60, budgetSonnetLE: 5.00, budgetOpusLE: 8.00, wallClock: .seconds(30 * 60),
                                      quotas: ModeQuotas(posts: 10, itemsCreated: 5, comments: 20))
    public static let plan = ModeCaps(maxTurns: 25, budgetSonnetLE: 2.00, budgetOpusLE: 4.00, wallClock: .seconds(15 * 60),
                                      quotas: ModeQuotas(posts: 3, itemsCreated: 0, comments: 5, highRisk: 0))
    /// Data only (5-lite): Ultra-small $4 / Ultra $15, 100 turns, 45 min.
    public static let ultra = ModeCaps(maxTurns: 100, budgetSonnetLE: 15.00, budgetOpusLE: 15.00, wallClock: .seconds(45 * 60),
                                       quotas: ModeQuotas(posts: 15, itemsCreated: 3, comments: 40))

    public static func of(_ mode: WorkMode) -> ModeCaps {
        switch mode {
        case .quick: quick
        case .standard: standard
        case .deep: deep
        case .plan: plan
        case .ultra: ultra
        }
    }

    public func budgetLE(opus: Bool) -> Double { opus ? budgetOpusLE : budgetSonnetLE }
}

/// The Ultra caps per plan tier (design §3.6). Data only: Ultra arrives with the sandbox (5-lite).
public struct UltraCaps: Equatable, Sendable {
    public var share: Double
    public var perCompanyDay: Int
    public var concurrent: Int
    public var workflowAgents: Int
    public var slots: Int

    public static func of(_ tier: PlanTier) -> UltraCaps {
        switch tier {
        case .max5x: UltraCaps(share: 0.15, perCompanyDay: 2, concurrent: 1, workflowAgents: 2, slots: 3)
        case .max20x: UltraCaps(share: 0.15, perCompanyDay: 6, concurrent: 2, workflowAgents: 4, slots: 5)
        case .pro: UltraCaps(share: 0, perCompanyDay: 0, concurrent: 0, workflowAgents: 0, slots: 0)
        }
    }
}

/// The models a Brahma turn may name, owner pins included (design §4.1).
public enum ModelAllowlist {
    public static let models: Set<String> = ["haiku", "sonnet", "opus", "claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]

    public static func allows(_ model: String) -> Bool { models.contains(model) }

    public static func refusal(_ model: String) -> String { "model \(model) is not allowed in Brahma turns" }

    /// `haiku`, `sonnet` or `opus` for an allowlisted alias or id; the raw value otherwise.
    public static func family(_ model: String) -> String {
        let m = model.lowercased()
        for f in ["haiku", "sonnet", "opus"] where m == f || m.contains("-\(f)-") || m.hasPrefix("\(f)-") { return f }
        return m
    }
}

/// What the live probes of this CLI version showed (Task 14c step 1, Claude Code 2.1.308). A gate that has not passed keeps the
/// feature off; the doctor's mode-canary re-checks what it can for free on every CLI version.
public enum ModeGates {
    /// V-4: plan mode under the real argv. On 2.1.308 an absolute `plansDirectory` was ignored (the plan went to
    /// `~/.claude/plans`) and a non-read-only MCP tool (a post) was refused in plan mode, so Plan-first stays off.
    public static let planFirst = false
    /// L-4: `total_cost_usd` is cumulative over `--resume` and `--max-budget-usd` is per process: the per-mode caps are on.
    public static let perModeCaps = true
}

/// The sub-agent gate (design §3.9): `Task` compiles on only when L-2, V-2/V-8, V-3 and V-5 pass, and on the workspace profile
/// also V-9, which cannot pass while agent Bash is unsandboxed. So it is always off in 3a.
public enum SubagentGate {
    public static func passed(profile: PermissionProfile) -> Bool { false }

    public static let workspaceDetail = "off on the workspace profile: sub-agents arrive with the sandbox (5-lite)"
}

/// $LE per work turn per (model, effort): an EMA learned from finished turns (design §3.8.7). Before it has data, the rung's
/// relative cost times `r1Prior`.
public struct ModeCalibration: Codable, Equatable, Sendable {
    public var ema: [String: Double] = [:]
    public var samples: [String: Int] = [:]

    public init() {}

    /// One Sonnet-medium work turn at current list prices (design §2.1).
    public static let r1Prior = 0.54
    /// Haiku relative to Sonnet at the same effort (R0 haiku ≈ 0.05× vs 0.5× for Sonnet).
    public static let haikuFactor = 0.1
    public static let alpha = 0.3
    public static let minSamples = 3

    static func key(model: String, effort: Effort) -> String { "\(ModelAllowlist.family(model))/\(effort.rawValue)" }

    /// The expected $LE of one turn at `rung` run on `model` with `effort`.
    public func estimate(rung: ModeRung, model: String, effort: Effort) -> Double {
        let k = Self.key(model: model, effort: effort)
        if let v = ema[k], (samples[k] ?? 0) >= Self.minSamples { return v }
        let base = Self.r1Prior * rung.costFactor
        return ModelAllowlist.family(model) == "haiku" ? base * Self.haikuFactor : base
    }

    public mutating func record(model: String, effort: Effort, costLE: Double) {
        guard costLE.isFinite, costLE >= 0 else { return }
        let k = Self.key(model: model, effort: effort)
        let n = samples[k] ?? 0
        ema[k] = n == 0 ? costLE : (1 - Self.alpha) * (ema[k] ?? costLE) + Self.alpha * costLE
        samples[k] = n + 1
    }
}

/// Everything `ModePolicy.select` reads, derived by the engine (design §3.1). Tier, priority and blocking are the
/// **effective** values: a spec nobody trusted counts as tier ≤ M and priority ≥ 2, and self-linked dependents do not count.
public struct ModeInputs: Equatable, Sendable {
    public var turnKind: TurnKind = .work
    /// False for a work turn with no current item (itemless work).
    public var hasItem = false
    public var decidingPRD = false
    public var decidingArchitecture = false
    public var tier: EffortTier? = nil
    public var priority = 2
    public var riskTags: Set<String> = []
    public var blockingCount = 0
    public var intensity: WorkIntensity = .auto
    public var rungFloor = 0
    /// The model of the (agent, item) session's first work turn; nil before it, and for review turns.
    public var sessionModel: String? = nil
    /// The session's transcript size, for the cache-break estimate of a model change.
    public var sessionTokens = 0
    /// `auto`, or the owner's pin (kept, but still allowlisted).
    public var agentModel = "auto"
    /// The role card's model for the company's usage mode (`haiku` makes the Sonnet rungs run on Haiku; `opus` raises the base
    /// rung to R3).
    public var roleModel: String? = nil
    public var roleMaxRung: Int? = nil
    public var trust = "T1"
    public var usageMode: UsageMode = .balanced
    public var planTier: PlanTier = .max5x
    public var pace: PaceState = .onPace
    public var fiveHourUtil: Double? = nil
    /// `overageStatus == "allowed"` or `isUsingOverage`.
    public var overageAllowed = false
    public var subagentGate = false
    public var opusScarce = false
    /// The item's remaining tier budget in $LE (tier cap + boost − spent); nil when the turn has no item budget.
    public var budgetLeftLE: Double? = nil
    public var calibration = ModeCalibration()
    /// A plan was written since the item was claimed.
    public var planWritten = false
    /// Probe V-4 passed for this CLI version.
    public var planFirstGate = ModeGates.planFirst
    /// Two review rejections since the claim and no plan since: a replan turn is due.
    public var replanRequested = false
    /// Review spend on the item passed 25% of its tier $LE.
    public var reviewSpendCapped = false
    /// The last review requested changes and every finding was P2.
    public var p2OnlyFix = false

    public init() {}
}

/// What one turn runs with (design §3.2 step 7). Stored on the turn as `mode`, `rung`, `effort` and `modeReason`.
public struct ModeDecision: Equatable, Sendable {
    public var mode: WorkMode
    public var rung: ModeRung
    public var model: String
    public var effort: Effort
    /// The settings cap on the main loop's effort (the turn's effort).
    public var maxEffortLevel: Effort
    /// This work turn should be a plan turn first (only when probe V-4 passed).
    public var planFirst = false
    public var subagents: SubagentPolicy = .off
    /// `--max-budget-usd`: the mode cap, lowered to what the item has left.
    public var maxBudgetUSD: Double
    public var maxTurns: Int
    public var wallClock: Duration
    public var quotas: ModeQuotas
    public var reasons: [String]
    /// The no-launch rule: false when the item cannot afford even a Quick turn.
    public var launch = true
    /// Set when the pinned model is not allowed; nothing launches.
    public var refusal: String? = nil
    /// The model differs from the session's: an explicit escalation to Opus, recorded as a cache break.
    public var cacheBreak = false

    /// `Deep R2 · tier M with risk tags · held by pace`.
    public var reason: String { reasons.joined(separator: "; ") }
    public var summary: String { ([mode.title + " " + rung.label] + reasons.prefix(3)).joined(separator: " · ") }
}

/// The outcome of one escalation check (design §3.3).
public enum EscalationAction: Equatable, Sendable {
    /// Raise the item's floor to this level (effort first); `opus` when it crosses to Opus (a cache break).
    case raiseFloor(to: Int, opus: Bool, reason: String)
    /// The escalation would exceed the item's budget: not applied; the manager is told.
    case heldByBudget(reason: String)
    /// `--max-budget-usd` stopped two turns in a row: the manager is told; no rung change.
    case turnCapTooSmall
    /// R4 and two more counted failures on a confirmed tier L or P0 item: the engine proposes Ultra (always an owner ask).
    case proposeUltra(reason: String)
}

/// One failed submission since the claim, as the counted-failure rule sees it.
public struct FailedSubmission: Equatable, Sendable {
    public var commit: String
    /// The diff since the previous failing commit (or the base) touches the item's claimed paths.
    public var touchesScope: Bool
    /// Both the run and its re-run failed for real: not flaky, inconclusive or infrastructure.
    public var real: Bool

    public init(commit: String, touchesScope: Bool, real: Bool) {
        self.commit = commit; self.touchesScope = touchesScope; self.real = real
    }
}

public enum ModePolicy {
    /// List-price 1-hour cache writes per million tokens (2× input), for the cache-break part of `est`.
    public static let cacheWritePerMTokLE: [String: Double] = ["haiku": 2.0, "sonnet": 6.0, "opus": 10.0]
    /// Review spend past this share of the tier's $LE drops reviews to Standard.
    public static let reviewSpendShare = 0.25
    /// Five-hour utilization at which `Task` is off and effort drops a step.
    public static let fiveHourHigh = 0.85
    public static let replanRejections = 2
    public static let escalationFailures = 2

    static let planRiskTags: Set<String> = ["migration", "hotPath"]

    // MARK: Select

    public static func select(_ i: ModeInputs) -> ModeDecision {
        var reasons: [String] = []
        let pin = i.agentModel == "auto" ? nil : i.agentModel
        if let pin, !ModelAllowlist.allows(pin) {
            var d = decision(.quick, rung: .r0, model: pin, effort: .low, i: i, reasons: [ModelAllowlist.refusal(pin)])
            d.launch = false
            d.refusal = ModelAllowlist.refusal(pin)
            return d
        }
        // The ladder's models are Sonnet and Opus. A role whose card names haiku for the usage mode keeps it for its Quick (R0)
        // turns only; a role card can raise the base rung (opus) but never lower a work rung.
        let quickModel = i.roleModel.map(ModelAllowlist.family) == "haiku" ? "haiku" : "sonnet"
        let small = "sonnet"
        func model(_ rung: ModeRung) -> String { pin ?? (rung.isOpus ? "opus" : rung == .r0 ? quickModel : small) }

        // 1. Kind gate.
        switch i.turnKind {
        case .notice where !(i.decidingPRD || i.decidingArchitecture):
            reasons.append("notice turn: Quick (haiku low)")
            return decision(.quick, rung: .r0, model: pin ?? "haiku", effort: .low, i: i, reasons: reasons)
        case .review, .audit:
            return review(i, pin: pin, small: small)
        case .work where !i.hasItem && !(i.decidingPRD || i.decidingArchitecture):
            reasons.append("itemless work: Quick (\(model(.r0)) low)")
            return decision(.quick, rung: .r0, model: model(.r0), effort: .low, i: i, reasons: reasons)
        default:
            break
        }

        // 2. Base rung, from the effective tier, priority, risk and blocking.
        var opusRequired = false
        var planFirst = false
        var base = ModeRung.r1
        if i.decidingPRD || i.decidingArchitecture {
            base = .r3; opusRequired = true
            reasons.append("\(i.decidingPRD ? "PRD" : "architecture") decision: R3")
        } else {
            switch i.tier {
            case .l?:
                base = .r3; opusRequired = true; planFirst = !i.planWritten
                reasons.append("confirmed tier L: R3")
            case .m?:
                let risky = !i.riskTags.isEmpty || i.priority == 0 || i.blockingCount >= 2
                base = risky ? .r2 : .r1
                planFirst = !i.riskTags.isDisjoint(with: planRiskTags) && !i.planWritten
                if risky {
                    var why: [String] = []
                    if !i.riskTags.isEmpty { why.append("risk " + i.riskTags.sorted().joined(separator: ",")) }
                    if i.priority == 0 { why.append("P0") }
                    if i.blockingCount >= 2 { why.append("blocks \(i.blockingCount)") }
                    reasons.append("tier M (\(why.joined(separator: ", "))): R2")
                } else {
                    reasons.append("tier M: R1")
                }
            default:
                reasons.append("tier \(i.tier?.label ?? "S"): R1")
            }
        }
        if i.roleModel.map(ModelAllowlist.family) == "opus", base.level < 3 {
            base = .r3
            reasons.append("role default opus: R3")
        }
        if i.intensity == .thorough, base.level < 2 {
            base = .r2
            reasons.append("intensity Thorough: R2")
        }
        if i.replanRequested {
            planFirst = true
            reasons.append("\(replanRejections) review rejections: replan")
        }
        if i.turnKind == .plan { return planTurn(i, base: base, pin: pin, small: small, reasons: reasons) }
        var rung = base

        // 3. Floor (set only by escalation and request_mode).
        if i.rungFloor > rung.level {
            rung = ModeRung.at(level: i.rungFloor)
            reasons.append("floor R\(min(i.rungFloor, 4))")
        }
        let explicitOpus = i.rungFloor >= 3

        // 4. Usage mode.
        var subagentsAllowed = true
        switch i.usageMode {
        case .low:
            subagentsAllowed = false
            if rung.level > 2 || rung.isOpus {
                rung = opusRequired ? .opusLow : .r2
                reasons.append("Low usage mode: \(rung.label)")
            }
            if planFirst, i.tier != .l { planFirst = false; reasons.append("Low usage mode: Plan-first only for tier L") }
        case .balanced:
            break
        case .max:
            if i.priority == 0 || i.blockingCount >= 2, rung != .r4 {
                rung = rung.up
                reasons.append("Max usage mode: +1 rung for \(i.priority == 0 ? "P0" : "critical path")")
            }
        }

        // 5. Pressure clamps: applied last, can only lower.
        var effortSteps = 0
        func clamp(_ r: ModeRung, maxLevel: Int) -> ModeRung {
            if r.level <= maxLevel && !(r.isOpus && maxLevel < 3) { return r }
            return opusRequired ? .opusLow : ModeRung.at(level: maxLevel)
        }
        func lower(_ a: ModeRung, _ b: ModeRung) -> ModeRung { b.costFactor < a.costFactor ? b : a }
        if i.overageAllowed {
            let r = clamp(rung, maxLevel: 1)
            if r != rung { rung = lower(rung, r) }
            subagentsAllowed = false
            if planFirst, i.tier != .l { planFirst = false }
            reasons.append("extra usage is on: at most \(rung.isOpus ? "opus-low" : "R1"), no sub-agents")
        }
        if i.planTier == .pro {
            let r = clamp(rung, maxLevel: PlanTier.pro.maxRung ?? 2)
            if r != rung { rung = lower(rung, r); reasons.append("Pro plan: \(rung.label)") }
            subagentsAllowed = false
        }
        switch i.pace {
        case .closed:
            rung = lower(rung, clamp(base, maxLevel: 1))
            subagentsAllowed = false
            planFirst = false
            reasons.append("weekly pace closed: \(rung.label), floor ignored")
        case .ahead:
            if rung.costFactor > base.costFactor { rung = base }
            effortSteps += 1
            if planFirst, i.tier != .l { planFirst = false }
            reasons.append("ahead of pace: no rung above base, effort −1")
        default:
            break
        }
        if let u = i.fiveHourUtil, u >= fiveHourHigh {
            subagentsAllowed = false
            effortSteps += 1
            reasons.append("5-hour use \(Int((u * 100).rounded()))%: effort −1")
        }
        if i.opusScarce, rung.isOpus, !(i.decidingPRD || i.decidingArchitecture) {
            rung = .r2
            reasons.append("opus scarce: R2")
        }

        if let cap = i.roleMaxRung, rung.level > cap {
            rung = lower(rung, clamp(rung, maxLevel: cap))
            reasons.append("role max \(rung.label)")
        }
        if i.trust == "T0" {
            rung = lower(rung, clamp(rung, maxLevel: 1))
            subagentsAllowed = false
            reasons.append("trust T0: at most R1")
        }

        // The model of an (agent, item) session is fixed after its first work turn; only an explicit escalation to Opus
        // changes it (a cache break). Otherwise the session model stays and only the effort follows the rung.
        let session = pin == nil ? i.sessionModel.map(ModelAllowlist.family) : nil
        if let session, session != ModelAllowlist.family(model(rung)) {
            if rung.isOpus, explicitOpus {
                reasons.append("explicit escalation to opus (cache break)")
            } else if session == "opus" {
                rung = .opusLow
                reasons.append("session model opus kept: opus-low")
            } else {
                if rung.isOpus { rung = .r2 }
                reasons.append("session model \(session) kept")
            }
        }
        /// The model a rung runs on in this session: an opus session stays on opus, any other keeps its model unless the rung
        /// is an (explicitly escalated) opus rung.
        func runModel(_ r: ModeRung) -> String {
            if let pin { return pin }
            guard let session else { return model(r) }
            if session == "opus" { return "opus" }
            return r.isOpus ? "opus" : session
        }

        // Budget: step down until the estimate fits; below a Quick turn nothing launches.
        func est(_ r: ModeRung) -> Double {
            let m = runModel(r)
            var e = i.calibration.estimate(rung: r, model: m, effort: r.effort)
            if let session, session != ModelAllowlist.family(m) {
                e += Double(i.sessionTokens) * (cacheWritePerMTokLE[ModelAllowlist.family(m)] ?? 0) / 1_000_000
            }
            return e
        }
        var launch = true
        if let left = i.budgetLeftLE {
            let start = rung
            while est(rung) > left, let next = rung.down {
                // An opus session never steps down to Sonnet mid-session (that would be a model change).
                if session == "opus", !next.isOpus { break }
                rung = next
            }
            if rung != start { reasons.append("held at \(rung.label) by budget") }
            if est(rung) > left || left <= 0 {
                launch = false
                reasons.append(String(format: "budget left $%.2f is below a Quick turn: not launched", max(0, left)))
            }
        }
        let chosenModel = runModel(rung)
        let cacheBreak = session.map { $0 != ModelAllowlist.family(chosenModel) } ?? false

        // Effort, then the mode and its caps.
        var effort = rung.effort.lowered(by: effortSteps)
        if i.p2OnlyFix, i.rungFloor > base.level, base.effort < effort {
            effort = base.effort
            reasons.append("P2-only fix: base effort \(effort.rawValue) at the floor's model")
        }
        if planFirst, !i.planFirstGate {
            planFirst = false
            reasons.append("Plan-first off: probe V-4 has not passed")
        }
        let mode = rung.mode
        var subagents = SubagentPolicy.off
        if subagentsAllowed, i.subagentGate, mode == .standard || mode == .deep {
            subagents = mode == .standard ? .forced(model: "haiku", depth: 1, concurrent: 2) : .forced(model: "sonnet", depth: 1, concurrent: 3)
        } else if !i.subagentGate {
            reasons.append("sub-agents off (gate)")
        }
        var d = decision(mode, rung: rung, model: chosenModel, effort: effort, i: i, reasons: reasons)
        d.planFirst = planFirst
        d.subagents = subagents
        d.cacheBreak = cacheBreak
        if subagents != .off { d.quotas.highRisk = 1 }
        if !launch { d.launch = false }
        return d
    }

    /// Review and audit turns: Standard, or Deep at R3 for an effective tier L or a flagged or sensitive item; never Task or
    /// Workflow; past the review spend cap Standard. They are fresh clean-context sessions, so the session rule does not apply.
    static func review(_ i: ModeInputs, pin: String?, small: String) -> ModeDecision {
        var reasons: [String] = []
        let deep = i.tier == .l || i.riskTags.contains("flagged") || i.riskTags.contains("sensitivePath")
        var rung = ModeRung.r1
        if deep, i.reviewSpendCapped {
            reasons.append("review spend past \(Int(reviewSpendShare * 100))% of the tier budget: Standard")
        } else if deep {
            rung = .r3
            reasons.append("review of \(i.tier == .l ? "tier L" : "a flagged item"): Deep R3")
        } else {
            reasons.append("review: Standard")
        }
        if rung.isOpus, i.overageAllowed || i.pace == .closed || i.opusScarce || i.planTier == .pro || i.usageMode == .low {
            rung = i.overageAllowed || i.pace == .closed ? .r1 : .r2
            reasons.append("clamped to \(rung.label)")
        }
        var effort = rung.effort
        if i.pace == .ahead { effort = effort.lowered(by: 1) }
        var d = decision(rung.mode, rung: rung, model: pin ?? (rung.isOpus ? "opus" : small), effort: effort, i: i, reasons: reasons)
        d.subagents = .off
        return d
    }

    /// The plan turn of Plan-first (design §2.4): the item's session model (else the base rung's), effort medium, Plan caps.
    static func planTurn(_ i: ModeInputs, base: ModeRung, pin: String?, small: String, reasons: [String]) -> ModeDecision {
        let model = pin ?? i.sessionModel ?? (base.isOpus ? "opus" : small)
        var d = decision(.plan, rung: base, model: model, effort: .medium, i: i, reasons: reasons + ["plan turn: medium"])
        d.subagents = .off
        return d
    }

    static func decision(_ mode: WorkMode, rung: ModeRung, model: String, effort: Effort, i: ModeInputs,
                         reasons: [String]) -> ModeDecision {
        let caps = ModeCaps.of(mode)
        var budget = caps.budgetLE(opus: ModelAllowlist.family(model) == "opus")
        if let left = i.budgetLeftLE, i.turnKind == .work || i.turnKind == .plan { budget = min(budget, max(0, left)) }
        return ModeDecision(mode: mode, rung: rung, model: model, effort: effort, maxEffortLevel: effort, maxBudgetUSD: budget,
                            maxTurns: caps.maxTurns, wallClock: caps.wallClock, quotas: caps.quotas, reasons: reasons)
    }

    // MARK: Escalation (design §3.3–3.4)

    /// Failed checks that count toward escalation: real failures (not flaky, inconclusive or infrastructure) whose diff touches
    /// the item's scope and whose commit differs from the previous failing commit. Identical resubmits do not count.
    public static func countedFailures(_ failures: [FailedSubmission]) -> Int {
        var count = 0
        var previous: String?
        for f in failures {
            defer { if f.real { previous = f.commit } }
            guard f.real, f.touchesScope, f.commit != previous else { continue }
            count += 1
        }
        return count
    }

    /// The next floor after an escalation from `level`, effort first: R1→R2; R2→R3 only for a confirmed tier L or a tier M item
    /// that is P0 or has a risk tag; R3→R4 only for a confirmed tier L. Nil when the item may not climb further.
    public static func nextFloor(from level: Int, tierL: Bool, mP0OrRisk: Bool) -> Int? {
        switch level {
        case ...1: return max(level + 1, 1)
        case 2: return tierL || mP0OrRisk ? 3 : nil
        case 3: return tierL ? 4 : nil
        default: return nil
        }
    }

    /// What the engine does about an item before its holder's next turn. `escalatedSinceClaim`: failure escalations already
    /// applied since the claim (one per claim); `rejections`: review rejections since the claim, and whether they already
    /// raised the floor; `cappedInRow`: consecutive `--max-budget-usd` stops on the item.
    public static func escalation(counted: Int, escalatedSinceClaim: Bool, currentLevel: Int, floor: Int, tierL: Bool,
                                  p0: Bool, mP0OrRisk: Bool, rejections: Int, rejectionsApplied: Bool, cappedInRow: Int,
                                  budgetLeftLE: Double?, estimate: (Int) -> Double, ultraProposed: Bool) -> [EscalationAction] {
        var actions: [EscalationAction] = []
        let from = max(currentLevel, floor)
        func raise(_ why: String) {
            guard let to = nextFloor(from: from, tierL: tierL, mP0OrRisk: mP0OrRisk) else { return }
            if let left = budgetLeftLE, estimate(to) > left {
                actions.append(.heldByBudget(reason: "\(why): R\(to) would exceed the budget left ($\(String(format: "%.2f", max(0, left))))"))
                return
            }
            actions.append(.raiseFloor(to: to, opus: to >= 3 && from < 3, reason: why))
        }
        if counted >= escalationFailures, !escalatedSinceClaim {
            if floor >= 4, tierL || p0 {
                if !ultraProposed { actions.append(.proposeUltra(reason: "\(counted) counted failed checks at R4")) }
            } else {
                raise("\(counted) counted failed checks")
            }
        }
        if rejections >= replanRejections, !rejectionsApplied, actions.isEmpty { raise("\(rejections) review rejections") }
        if cappedInRow == 2 { actions.append(.turnCapTooSmall) }
        return actions
    }
}

/// The spec values that count for intensity (design §3.1): a stored tier or priority counts only when a manager, executive, the
/// owner or the engine set or confirmed it (`specConfirmedBy` is `<id>:<role kind>`), and that confirmer is not the current lease
/// holder. Otherwise the item counts as at most tier M and at least priority 2.
public enum EffectiveSpec {
    static let trustedRoles: Set<String> = ["manager", "executive", "owner", "system"]

    public static func trusted(confirmedBy: String?, holderId: String?) -> Bool {
        guard let confirmedBy else { return false }
        let parts = confirmedBy.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, trustedRoles.contains(parts[1]) else { return false }
        return parts[0] != holderId
    }

    public static func tier(stored: EffortTier, confirmedBy: String?, holderId: String?) -> EffortTier {
        if trusted(confirmedBy: confirmedBy, holderId: holderId) { return stored }
        return stored == .l ? .m : stored
    }

    public static func priority(stored: Int, confirmedBy: String?, holderId: String?) -> Int {
        if trusted(confirmedBy: confirmedBy, holderId: holderId) { return stored }
        return max(stored, 2)
    }
}

extension WorkItemStatus {
    /// An item that reaches `done` (merged) starts any later life at floor 0 (design §3.4).
    public var resetsRungFloor: Bool { self == .done }
}

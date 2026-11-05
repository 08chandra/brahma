import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Task 14u: Ultra admission, reservation, slots and the watchdog, and the per-shape gates of the sandboxed fan-out shapes.
// Kept apart from `Orchestrator.swift`, whose turn only calls into these.

/// An Ultra run admitted for one turn: the approval it uses, and what `ModePolicy.select` compiles from it.
struct UltraPlan: Sendable {
    var run: PendingUltraRun
    var admission: UltraAdmission
    var caps: UltraCaps
}

/// The canary key's shape of a sandboxed turn (Task 3's gate): the settings shape, and for a fan-out shape its launch shape
/// too. A Task turn's settings equal a plain turn's (its tools travel in argv), and Ultra-small's equal Ultra's (they differ in
/// strings only), so each fan-out shape gets its own key and stays blocked until a pass is recorded for exactly it.
public enum CanaryShape {
    public static func key(_ settings: ClaudeSettings, launch: String?) -> String {
        guard let launch else { return settings.shape() }
        return StableHash.fnv1a64(settings.shape() + "|" + launch)
    }

    /// `task`, `ultra-small` or `ultra` for a decision that fans out; nil otherwise.
    public static func launch(_ d: ModeDecision?) -> String? {
        guard let d else { return nil }
        if let w = d.workflow { return w.variant == .small ? "ultra-small" : "ultra" }
        return d.subagents != .off ? "task" : nil
    }
}

extension Orchestrator {
    // MARK: Probe gates

    /// The running CLI's fingerprint (a `stat`), the key of every probe gate; nil without a canary gate (no CLI to verify).
    nonisolated func probeFingerprint() -> String? {
        guard let gate = sandboxCanary else { return nil }
        return try? gate.fingerprint(gate.claudePath).key
    }

    nonisolated func passedProbeGates(_ shape: ProbeShape, fingerprint: String?) -> Set<String> {
        guard let fingerprint else { return [] }
        return (try? store.passedProbeGates(fingerprint: fingerprint, shape: shape)) ?? []
    }

    // MARK: Admission

    /// Before `ModePolicy.select` on a leaseholder's work turn: the item's approved Ultra run, if any, is admitted when the item is
    /// eligible (effective values) and every hard gate holds, the fresh `get_usage` last. Otherwise the refusal is returned
    /// (the turn runs the computed rung and records it). Nothing is written here: the reservation is made only once the turn
    /// passed the sandbox gate (`reserveUltraRun`).
    /// `relayedTaint`: the turn reads what a tainted session wrote, so it is tainted at launch (fix round 1, I2: gate 10 counts it).
    nonisolated func ultraPreflight(kind: TurnKind, itemBudget: Bool, facts: ItemModeFacts?, inputs: ModeInputs, agent: Agent,
                                    company: Company, profile: PermissionProfile,
                                    relayedTaint: Bool = false) async -> (plan: UltraPlan?, refusal: String?, trigger: Bool) {
        guard kind == .work, itemBudget, let f = facts, let run = try? store.pendingUltraRun(itemId: f.item.id) else { return (nil, nil, false) }
        var i = inputs
        i.ultraTrigger = run.origin == .failurePath
        guard let basis = UltraEligibility.basis(i) else { return (nil, UltraEligibility.check(i), i.ultraTrigger) }
        var g = await ultraGateInputs(company: company, agent: agent, profile: profile)
        if relayedTaint { g.sessionTainted = true }
        g.roleMaxRung = inputs.roleMaxRung
        if let first = UltraGate.failures(run.variant, g, skipFresh: true).first { return (nil, first.reason, i.ultraTrigger) }
        // Gate 6, from a reading taken now (zero inference): only once everything cheaper passed.
        let fresh = await ControlProbe.getUsage(runner: runner, paths: paths, hookExecutable: mcpExecutable)
        g.freshFiveHourUtil = fresh?.fiveHourUtil
        g.extraUsageEnabled = fresh?.extraUsageEnabled
        switch UltraGate.admit(run.variant, g) {
        case .failure(let refusal):
            return (nil, refusal.reason, i.ultraTrigger)
        case .success(let variant):
            let caps = UltraCaps.of(g.planTier)
            return (UltraPlan(run: run, admission: UltraAdmission(variant: variant, approver: run.approver, workflowAgents: caps.workflowAgents,
                                                                  basis: basis), caps: caps), nil, i.ultraTrigger)
        }
    }

    /// Everything the hard gates read except the fresh reading (design §3.6): the store's part, this CLI build's Ultra probe
    /// gates and the company's free slots (this turn already holds one).
    nonisolated func ultraGateInputs(company: Company, agent: Agent, profile: PermissionProfile) async -> UltraGateInputs {
        let now = clock()
        let slots = await ultraFreeSlots(company: company, includingAsking: true)
        var g = store.ultraGateInputs(company: company, profile: profile, fingerprint: probeFingerprint(), running: 0, freeSlots: slots, now: now)
        if let mismatch = store.planTierResolution().mismatch { notePlanTierMismatch(mismatch, now: now) }
        g.trust = agent.trustLevel
        g.sessionTainted = ((try? store.agent(id: agent.id)) ?? nil)?.sessionTainted ?? true
        return g
    }

    /// The CLI's plan disagrees with the configured one: the lower is used and the owner is asked to confirm, once while open.
    nonisolated func notePlanTierMismatch(_ text: String, now: Date) {
        attempt {
            try store.writer.write { db in
                let open = try Ask.filter(Column("kind") == AskKind.engineAlert && Column("status") == AskStatus.pendingOwner.rawValue
                                          && Column("subjectId") == EngineAlerts.askSubject(reason: Self.planTierAlertReason)).fetchCount(db)
                guard open == 0 else { return }
                try EngineAlerts.raise(store: store, db: db, text: "Plan tier: \(text).", now: now, reason: Self.planTierAlertReason)
            }
        }
    }

    static let planTierAlertReason = "plan-tier"

    /// The company's own status for `UltraStatus.explain` (F9): the standing gates, judged for Ultra-small.
    public nonisolated func ultraStatus(companyId: String) async -> [String] {
        guard let company = try? store.company(id: companyId) else { return [] }
        let g = store.ultraGateInputs(company: company, profile: company.permissionProfile, fingerprint: probeFingerprint(), running: 0,
                                      freeSlots: await ultraFreeSlots(company: company, includingAsking: false), now: clock())
        return UltraStatus.explain(g)
    }

    // MARK: Reservation and slots

    /// Reserves the admitted run's cap (and consumes its approval), and holds the extra slots its workflow agents take. Gate 9
    /// is judged again and its slots taken in one actor step (fix round 2, N4: two companies' Ultra turns cannot both pass on
    /// the slots left), then the count gates in the reserving transaction (S28); a refusal of either gives the slots back.
    nonisolated func reserveUltraRun(_ plan: UltraPlan, turnId: String, company: Company, itemId: String) async throws {
        try await claimUltraSlots(company: company, caps: plan.caps)
        do {
            try store.reserveUltra(turnId: turnId, companyId: company.id, itemId: itemId, run: plan.run, caps: plan.caps, now: clock())
        } catch {
            await occupySlots(companyId: company.id, extra: -max(0, plan.caps.slots - 1))
            throw error
        }
    }

    /// Gate 9 and the slot claim, atomic on the actor.
    func claimUltraSlots(company: Company, caps: UltraCaps) throws {
        let free = ultraFreeSlots(company: company, includingAsking: true)
        guard free >= caps.slots + 1 else {
            throw UltraRefusal(gate: 9, reason: "no free slots (\(max(0, free)) free, Ultra needs \(caps.slots + 1))")
        }
        occupySlots(companyId: company.id, extra: max(0, caps.slots - 1))
    }

    /// After an Ultra turn: its extra slots are free again; a run that never launched gives its approval back.
    nonisolated func endUltraRun(_ plan: UltraPlan, turnId: String, companyId: String, launched: Bool) async {
        await occupySlots(companyId: companyId, extra: -max(0, plan.caps.slots - 1))
        if !launched { attempt { try store.cancelUltraReservation(turnId: turnId, now: clock()) } }
    }

    func companyRunning(_ companyId: String) -> Int { runningByCompany[companyId] ?? 0 }

    /// Gate 9's free slots, counted as the scheduler counts them (fix round 1, I4): the company's usage-mode cap under the
    /// engine's hard cap (`SchedulerConfig.modeCap`), and the engine-wide room (`Scheduler.freeSlots`: the hard and safety caps,
    /// memory pressure, checks and merges in flight), whichever is smaller. `includingAsking`: the asking turn already holds one
    /// slot of each, which is not counted against it.
    func ultraFreeSlots(company: Company, includingAsking: Bool) -> Int {
        var cfg = config
        cfg.planTier = store.planTier()
        let own = includingAsking ? 1 : 0
        let companyFree = cfg.modeCap(company.usageMode) - max(0, companyRunning(company.id) - own)
        let globalFree = Scheduler.freeSlots(config: cfg, running: max(0, runningCount() - own), otherChildren: otherChildren,
                                             pressure: memory.current)
        return min(companyFree, globalFree)
    }

    func occupySlots(companyId: String, extra: Int) {
        let n = (runningByCompany[companyId] ?? 0) + extra
        runningByCompany[companyId] = n > 0 ? n : nil
    }

    // MARK: Watchdog and charging

    /// The agent-count kill (design §3.8.2): SIGINT to the turn's leader first; the runner then ends its whole group (SIGTERM,
    /// then SIGKILL after its grace), workflow agents included, when the turn's stream is dropped.
    nonisolated static func interruptLeader(_ pid: Int32?) {
        guard let pid, pid > 1, pid != getpid() else { return }
        _ = kill(pid, SIGINT)
    }

    /// The least an Ultra turn is charged: its cap when it was killed (the agent-count kill, the owner's stop or a quit, the
    /// wall clock, SIGTERM with no result, background work still pending); nil when it ended by itself.
    nonisolated static func ultraChargeFloor(_ plan: UltraPlan?, end: TurnEnd, runnerError: (any Error)?, agentCapped: Bool) -> Double? {
        guard let plan else { return nil }
        var killed = agentCapped || end.outcome == .interrupted
        if case .timedOut? = runnerError as? TurnError { killed = true }
        return killed ? plan.run.variant.capLE : nil
    }

    // MARK: Fan-out shapes (per-shape canary gating)

    /// Whether the sandbox canary passed for this fan-out shape's own key. If not, its canary is asked for in the background
    /// (never holding the agent: the turn falls back to the computed non-fan-out rung) and false is returned.
    nonisolated func fanOutVerified(gate: SandboxCanaryGate, settings: ClaudeSettings, launch: String, company: Company) async -> Bool {
        guard let key = try? await canaryKey(gate: gate, shape: CanaryShape.key(settings, launch: launch)) else { return false }
        if (try? store.sandboxVerified(key)) == true { return true }
        await requestCanary(key, settings: settings, company: company, launch: launch)
        return false
    }

    /// Schedules a canary run for a key no agent waits on (a fan-out shape's), logged once per key.
    func requestCanary(_ key: SandboxCanaryKey, settings: ClaudeSettings, company: Company, launch: String) {
        if canarySettings[key.text] == nil { canarySettings[key.text] = settings }
        if canaryLogged.insert(key.text).inserted {
            attempt {
                try store.appendEvent(ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .usage,
                                                    text: "sandbox not verified for the \(launch) shape (claude \(key.cliVersion ?? "?")); "
                                                        + "checking; until then those turns run without it",
                                                    createdAt: clock()))
            }
        }
        scheduleCanary(key)
    }

    /// The inputs with the fan-out shape `launch` taken away: Ultra refused (with why), or sub-agents off.
    nonisolated static func withoutFanOut(_ i: ModeInputs, launch: String) -> ModeInputs {
        var i = i
        if launch == "task" {
            i.subagentGate = false
        } else {
            i.ultra = nil
            i.ultraRefusal = "sandbox canary has not passed for the \(launch) shape"
        }
        return i
    }
}

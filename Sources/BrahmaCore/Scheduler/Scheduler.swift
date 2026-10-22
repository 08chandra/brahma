import Foundation

public struct SchedulerConfig: Sendable {
    /// The user's own ceiling (`brahma run --hard-cap`); the plan tier's hard cap applies as well.
    public var hardCap: Int = 16
    public var safetyCap: Int = SafetyCap.current
    public var turnBudgetPerHour: Int = 30
    /// Per-mode concurrency caps come from the plan tier. The orchestrator re-reads the stored tier every tick.
    public var planTier: PlanTier = .max5x
    /// Weekly owner reserve (`1 - weeklyShare`); a company may override it. The orchestrator re-reads the stored
    /// share every tick.
    public var ownerReserve: Double = UsageGate.defaultReserve

    public init() {}

    public var effectiveHardCap: Int { min(hardCap, planTier.hardCap) }

    public func modeCap(_ m: UsageMode) -> Int { min(planTier.modeCap(m), hardCap) }
}

public struct Candidate: Sendable {
    public var agent: Agent
    public var company: Company
    public var blockingCount: Int

    public init(agent: Agent, company: Company, blockingCount: Int) {
        self.agent = agent
        self.company = company
        self.blockingCount = blockingCount
    }
}

public enum Scheduler {
    /// Pure: picks which ready agents to start now. Weighted round-robin across companies, bounded by the
    /// global cap (min of hard and safety caps) and each company's usage-mode cap.
    ///
    /// - `held`: an engine hold (or, later, an owner stop) admits nothing. `pressure == .critical` admits nothing;
    ///   `.warning` halves the global cap (never below 1).
    /// - `otherChildren`: child processes that are not turns (checks, merges) and count against the same cap.
    /// - `paceClosed`: companies shut only by the weekly pace; their critical-path candidates
    ///   (`blockingCount > 0`) are still admitted.
    /// - `paceStrict`: pace-closed companies whose spend has reached the owner's reserve (`util >= 1 - reserve`);
    ///   the critical-path exemption ends there and nothing is admitted.
    public static func select(candidates: [Candidate], runningByCompany: [String: Int], config: SchedulerConfig,
                              usage: (Company) -> UsageDecision, otherChildren: Int = 0,
                              pressure: MemoryPressure = .normal, held: Bool = false,
                              paceClosed: Set<String> = [], paceStrict: Set<String> = []) -> [Agent] {
        if held || pressure == .critical { return [] }
        var cap = min(config.effectiveHardCap, config.safetyCap)
        if pressure == .warning { cap = max(1, cap / 2) }
        var globalFree = cap - runningByCompany.values.reduce(0, +) - otherChildren
        if globalFree <= 0 { return [] }

        var companies: [String: Company] = [:]
        var queues: [String: [Candidate]] = [:]
        var gateOpen: [String: Bool] = [:]
        for cand in candidates where cand.company.status == .running {
            let id = cand.company.id
            if gateOpen[id] == nil { gateOpen[id] = usage(cand.company) == .open }
            guard gateOpen[id] == true else { continue }
            if paceStrict.contains(id) { continue }
            if paceClosed.contains(id), cand.blockingCount <= 0 { continue }
            companies[id] = cand.company
            queues[id, default: []].append(cand)
        }
        for id in queues.keys {
            queues[id]!.sort { a, b in
                if a.blockingCount != b.blockingCount { return a.blockingCount > b.blockingCount }
                let (ra, rb) = (roleWeight(a.agent.role), roleWeight(b.agent.role))
                if ra != rb { return ra > rb }
                let (sa, sb) = (a.agent.readySince ?? .distantFuture, b.agent.readySince ?? .distantFuture)
                if sa != sb { return sa < sb }
                return a.agent.name < b.agent.name
            }
        }
        var assigned = Dictionary(uniqueKeysWithValues: queues.keys.map { ($0, runningByCompany[$0] ?? 0) })
        var taken: [String: Int] = [:]
        var result: [Agent] = []

        while globalFree > 0 {
            let eligible = companies.values.filter {
                (taken[$0.id] ?? 0) < queues[$0.id]!.count && assigned[$0.id]! < config.modeCap($0.usageMode)
            }
            func ratio(_ c: Company) -> Double { Double(assigned[c.id]!) / Double(max(1, c.priorityWeight)) }
            guard let pick = eligible.min(by: { a, b in
                let (ra, rb) = (ratio(a), ratio(b))
                return ra != rb ? ra < rb : a.name < b.name
            }) else { break }
            let i = taken[pick.id] ?? 0
            result.append(queues[pick.id]![i].agent)
            taken[pick.id] = i + 1
            assigned[pick.id]! += 1
            globalFree -= 1
        }
        return result
    }
}

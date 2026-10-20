import Foundation

public struct SchedulerConfig: Sendable {
    public var hardCap: Int = 16
    public var safetyCap: Int = SafetyCap.current
    public var turnBudgetPerHour: Int = 30

    public init() {}

    public func modeCap(_ m: UsageMode) -> Int {
        switch m {
        case .low: return 2
        case .balanced: return 6
        case .max: return hardCap
        }
    }
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
    public static func select(candidates: [Candidate], runningByCompany: [String: Int], config: SchedulerConfig,
                              usage: (Company) -> UsageDecision) -> [Agent] {
        var globalFree = min(config.hardCap, config.safetyCap) - runningByCompany.values.reduce(0, +)
        if globalFree <= 0 { return [] }

        var companies: [String: Company] = [:]
        var queues: [String: [Candidate]] = [:]
        var gateOpen: [String: Bool] = [:]
        for cand in candidates where cand.company.status == .running {
            let id = cand.company.id
            if gateOpen[id] == nil { gateOpen[id] = usage(cand.company) == .open }
            guard gateOpen[id] == true else { continue }
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

import Foundation
import BrahmaCore

/// A small, fast, seedable generator (SplitMix64): the same seed gives the same stream on every platform.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A deterministic demo company for the map: the 3a generator's org with seeded states, items, blockers, vacancies and one
/// sprint meeting. Nothing here touches a store.
public enum SyntheticCompany {
    static let epoch = Date(timeIntervalSince1970: 1_799_971_200)

    static let itemTitles = ["Wire up sync retry", "Fix flaky checkout test", "Draft launch plan", "Tune the ranking query",
                             "Migrate the billing table", "Review onboarding copy", "Profile cold start", "Add audit export",
                             "Cut the release branch", "Triage inbound bugs", "Design the empty state", "Harden the upload path"]
    static let ownerReasons = ["approve the launch budget", "pick a pricing tier", "confirm the vendor contract",
                               "sign off on the release plan", "choose between the two designs"]

    public static func make(agents n: Int, seed: UInt64 = 42, companyId: String = "demo")
        -> (agents: [Agent], pack: IndustryPack, vacancies: [Vacancy], meetings: [Meeting], currentItems: [String: String],
            blockers: [String: String]) {
        let pack = SoftwarePack.pack
        let count = Swift.min(OrgGenerator.range.upperBound, Swift.max(OrgGenerator.range.lowerBound, n))
        let plan = try! OrgGenerator.generate(goal: "", count: count, pack: pack)
        var rng = SplitMix64(seed: seed)

        func id(_ handle: String) -> String { "\(companyId)-\(handle)" }
        var agents = plan.agents.enumerated().map { i, p in
            var a = Agent(id: id(p.handle), companyId: companyId, name: p.handle, role: p.role, model: "sonnet",
                          sessionId: "s-\(p.handle)", sessionStarted: false, state: .ready, paused: false,
                          createdAt: epoch.addingTimeInterval(Double(i)))
            a.managerId = p.managerHandle.map(id)
            a.team = p.team
            return a
        }
        let total = agents.count
        let hasReports = Set(agents.compactMap(\.managerId))

        // States by quota: 5 % killed (leaves of the tree, never the root), 10 % blocked, 30 % running, 30 % ready and the
        // rest sleeping, each group drawn by the seeded shuffle.
        let killedCount = Int((Double(total) * 0.05).rounded())
        let blockedCount = Int((Double(total) * 0.10).rounded())
        let runningCount = Int((Double(total) * 0.30).rounded())
        let readyCount = Int((Double(total) * 0.30).rounded())
        var leaves = agents.indices.filter { $0 != 0 && !hasReports.contains(agents[$0].id) }
        leaves.shuffle(using: &rng)
        var rest = Array(agents.indices)
        for i in leaves.prefix(killedCount) { agents[i].state = .killed }
        let killedSet = Set(leaves.prefix(killedCount))
        rest.removeAll { killedSet.contains($0) }
        rest.shuffle(using: &rng)
        var cursor = 0
        func assign(_ state: AgentState, _ k: Int) {
            for i in rest[cursor..<Swift.min(rest.count, cursor + k)] { agents[i].state = state }
            cursor += k
        }
        assign(.blocked, blockedCount)
        assign(.running, runningCount)
        assign(.ready, readyCount)
        assign(.sleeping, rest.count)

        let handles = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var blockers: [String: String] = [:]
        for i in agents.indices where agents[i].state == .blocked {
            switch Int.random(in: 0..<3, using: &rng) {
            case 0: agents[i].blocker = .owner(reason: ownerReasons.randomElement(using: &rng)!)
            case 1:
                let other = agents[(i + 1 + Int.random(in: 0..<Swift.max(1, total - 1), using: &rng)) % total]
                agents[i].blocker = other.id == agents[i].id ? .owner(reason: ownerReasons[0]) : .agent(other.id)
            default:
                let n = 100 + Int.random(in: 0..<400, using: &rng)
                agents[i].blocker = .workItem(id: "w-\(n)", key: "BRH-\(n)")
            }
            blockers[agents[i].id] = BlockerText.describe(agents[i].blocker, handles: handles)
        }

        // About 40 % of the agents carry a current item; killed ones do not.
        var items: [String: String] = [:]
        var living = agents.indices.filter { agents[$0].state != .killed }
        living.shuffle(using: &rng)
        for (k, i) in living.prefix(Int((Double(total) * 0.4).rounded())).enumerated() {
            items[agents[i].id] = "BRH-\(100 + k) \(itemTitles.randomElement(using: &rng)!)"
        }

        // One open seat per 25 agents under the living managers, in turn.
        let managers = agents.filter { hasReports.contains($0.id) && $0.state != .killed }
        var vacancies: [Vacancy] = []
        for v in 0..<(total / 25) {
            let manager = managers.isEmpty ? nil : managers[v % managers.count]
            vacancies.append(Vacancy(id: "vac-\(v + 1)", role: "engineer", roleTitle: "Engineer", managerId: manager?.id,
                                     team: manager?.team, note: "", source: .org))
        }

        // One sprint-planning meeting for the first team with two living members.
        var order: [String] = [], byTeam: [String: [String]] = [:]
        for a in agents where a.state != .killed {
            guard let t = a.team, !t.isEmpty else { continue }
            if byTeam[t] == nil { order.append(t) }
            byTeam[t, default: []].append(a.id)
        }
        var meetings: [Meeting] = []
        if let team = order.first(where: { (byTeam[$0]?.count ?? 0) >= 2 }), let ids = byTeam[team] {
            meetings.append(Meeting(id: "sprint-1", kind: .sprintPlanning, title: "SPRINT 1 PLANNING",
                                    participantIds: Array(ids.prefix(8))))
        }
        return (agents, pack, vacancies, meetings, items, blockers)
    }
}

/// Seeded message traffic over a company: 80 % within a team, 15 % to the sender's manager, 5 % across teams; 5 % of the
/// facts are hand-offs. Killed agents neither send nor receive.
public struct SyntheticTraffic: Sendable {
    private var rng: SplitMix64
    private var carry = 0.0
    private var rowId: Int64 = 0

    public init(seed: UInt64) { rng = SplitMix64(seed: seed) }

    /// Facts for `(from, to]` at `rate` per second, plus `burst.size` facts for every multiple of `burst.every` seconds
    /// (since the epoch) inside the window. Facts come back in time order.
    public mutating func facts(from: Date, to: Date, agents: [Agent], rate: Double,
                               burst: (every: TimeInterval, size: Int)? = (10, 200)) -> [MapFact] {
        let span = to.timeIntervalSince(from)
        let live = agents.filter { $0.state != .killed }
        guard span > 0, live.count >= 2 else { return [] }
        carry += Swift.max(0, rate) * span
        var n = Int(carry)
        carry -= Double(n)
        if let burst, burst.every > 0 {
            let crossed = Int((to.timeIntervalSince1970 / burst.every).rounded(.down)
                              - (from.timeIntervalSince1970 / burst.every).rounded(.down))
            if crossed > 0 { n += crossed * Swift.max(0, burst.size) }
        }
        guard n > 0 else { return [] }

        var teams: [String: [Agent]] = [:]
        for a in live { if let t = a.team, !t.isEmpty { teams[t, default: []].append(a) } }
        let liveIds = Set(live.map(\.id))
        var siblings: [String: [Agent]] = [:]
        for a in live where (a.team ?? "").isEmpty { if let m = a.managerId { siblings[m, default: []].append(a) } }

        var times = (0..<n).map { _ in from.addingTimeInterval(span * Double.random(in: 0..<1, using: &rng)) }
        times.sort()
        return times.map { fact(at: $0, live: live, teams: teams, siblings: siblings, liveIds: liveIds) }
    }

    private mutating func fact(at time: Date, live: [Agent], teams: [String: [Agent]], siblings: [String: [Agent]],
                               liveIds: Set<String>) -> MapFact {
        rowId += 1
        let sender = live.randomElement(using: &rng)!
        // The sender's unit: its team, or for someone with no team (executives, directors) the agents under the same manager.
        let unit = (sender.team ?? "").isEmpty ? (sender.managerId.flatMap { siblings[$0] } ?? []) : (sender.team.flatMap { teams[$0] } ?? [])
        let mates = unit.filter { $0.id != sender.id && $0.id != sender.managerId }
        let manager = sender.managerId.flatMap { liveIds.contains($0) ? $0 : nil }

        if Double.random(in: 0..<1, using: &rng) < 0.05 {
            let to: String? = Bool.random(using: &rng) ? mates.randomElement(using: &rng)?.id ?? manager : manager
            return .handoff(HandoffFlow(rowId: rowId, id: "syn-h-\(rowId)", itemKey: "BRH-\(100 + Int(rowId % 400))",
                                        authorId: sender.id, toAgentId: to, createdAt: time))
        }

        let roll = Double.random(in: 0..<1, using: &rng)
        if roll >= 0.80 && roll < 0.95, let manager {
            return dm(sender, manager, time)
        }
        if roll >= 0.95 {
            let others = live.filter { $0.id != sender.id && $0.team != sender.team }
            if let other = others.randomElement(using: &rng) { return dm(sender, other.id, time) }
        }
        // Within the team: a post in the team channel naming up to two teammates (none: a broadcast from the lead).
        if let team = sender.team, !mates.isEmpty {
            var named: [String] = []
            for _ in 0..<Int.random(in: 0...2, using: &rng) {
                if let m = mates.randomElement(using: &rng)?.id, !named.contains(m) { named.append(m) }
            }
            return .message(MessageFlow(rowId: rowId, messageId: "syn-m-\(rowId)", companyId: sender.companyId,
                                        senderId: sender.id, channelId: "syn-ch-\(team)", channelName: "team-\(team)",
                                        channelKind: .channel, kind: "text", recipientIds: named, team: team, createdAt: time))
        }
        if let mate = mates.randomElement(using: &rng) { return dm(sender, mate.id, time) }
        if let manager { return dm(sender, manager, time) }
        let other = live.randomElement(using: &rng)!
        return dm(sender, other.id == sender.id ? live[0].id : other.id, time)
    }

    private func dm(_ sender: Agent, _ to: String, _ time: Date) -> MapFact {
        .message(MessageFlow(rowId: rowId, messageId: "syn-m-\(rowId)", companyId: sender.companyId, senderId: sender.id,
                             channelId: "syn-dm-\(rowId)", channelName: "dm:\(sender.name)", channelKind: .dm, kind: "text",
                             recipientIds: [to], team: nil, createdAt: time))
    }
}

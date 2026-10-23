import Foundation

public enum OrgGenerator {
    public static let range = 5...500
    public static let maxReports = 7

    private struct Node {
        var role: String
        var rank: Int          // creation order class: exec, director, lead, ratio, member, support
        var team: String?
        var parent: Int?
        var seq: Int
    }

    private static func ceilDiv(_ a: Int, _ b: Int) -> Int { (a + b - 1) / b }

    static func directorsNeeded(_ c: Int) -> Int {
        c <= maxReports ? 0 : ceilDiv(c, maxReports) + directorsNeeded(ceilDiv(c, maxReports))
    }

    public static func generate(goal: String, count: Int, pack: IndustryPack) throws -> OrgPlan {
        guard range.contains(count) else { throw OrgError.countOutOfRange }
        let org = pack.org
        let merged = count < org.mergedBelow
        let execs = merged ? org.mergedExecutives : org.executives

        func covering(_ role: String) -> Int? {
            execs.firstIndex { $0 == role || pack.role($0)?.covers.contains(role) == true }
        }
        let leadExec = covering("cto") ?? (execs.count > 1 ? execs.count - 1 : 0)
        let ratios = org.ratios.filter { covering($0.role) == nil }

        var teams = 1, members = 0, support = org.teamSupport == nil ? 0 : 1
        var ratioCounts: [Int] = []
        func ratioCount(_ r: RoleRatio, _ t: Int) -> Int { count >= r.minAgents ? ceilDiv(t, r.teamsPer) : 0 }

        if merged {
            ratioCounts = ratios.map { ratioCount($0, 1) }
            members = count - execs.count - support - ratioCounts.reduce(0, +)
        } else {
            let r = count - execs.count
            var t = 1
            while true {
                let sup = org.teamSupport == nil ? 0 : t
                let rc = ratios.map { ratioCount($0, t) }
                var children = [Int](repeating: 0, count: execs.count)
                for i in execs.indices where i != 0 { children[0] += 1 }
                children[leadExec] += t
                for (i, ratio) in ratios.enumerated() { children[covering(ratio.reportsTo) ?? 0] += rc[i] }
                let dirs = children.reduce(0) { $0 + directorsNeeded($1) }
                let m = r - (t + sup + rc.reduce(0, +) + dirs)
                if m <= org.membersPerTeamMax * t || t > count { teams = t; support = sup; ratioCounts = rc; members = m; break }
                t += 1
            }
        }
        members = max(members, 0)

        // Build the tree.
        var nodes: [Node] = []
        func add(_ role: String, _ rank: Int, team: String? = nil, parent: Int? = nil) -> Int {
            nodes.append(Node(role: role, rank: rank, team: team, parent: parent, seq: nodes.count))
            return nodes.count - 1
        }
        var execIdx: [Int] = []
        for (i, e) in execs.enumerated() { execIdx.append(add(e, 0, parent: i == 0 ? nil : execIdx[0])) }

        var childrenOf: [Int: [Int]] = [:]   // exec node -> ordered children (leads, then ratios)
        func teamName(_ i: Int) -> String { merged ? org.smallTeamName : "team-\(i)" }
        var perTeam = [Int](repeating: members / teams, count: teams)
        for i in 0..<(members % teams) { perTeam[i] += 1 }
        for t in 1...teams {
            let lead: Int
            if merged { lead = execIdx[leadExec]; nodes[lead].team = teamName(t) }
            else { lead = add(org.teamLead, 2, team: teamName(t)); childrenOf[execIdx[leadExec], default: []].append(lead) }
            for _ in 0..<perTeam[t - 1] { _ = add(org.teamMember, 4, team: teamName(t), parent: lead) }
            if support > 0, let s = org.teamSupport { _ = add(s, 5, team: teamName(t), parent: lead) }
        }
        for (i, ratio) in ratios.enumerated() {
            let boss = execIdx[covering(ratio.reportsTo) ?? 0]
            for _ in 0..<ratioCounts[i] { childrenOf[boss, default: []].append(add(ratio.role, 3)) }
        }
        // Split over-wide managers under directors.
        func group(_ kids: [Int], under parent: Int) {
            if kids.count <= maxReports { for k in kids { nodes[k].parent = parent }; return }
            let k = ceilDiv(kids.count, maxReports)
            var dirs: [Int] = []
            var cursor = 0
            for d in 0..<k {
                let size = kids.count / k + (d < kids.count % k ? 1 : 0)
                let dir = add(org.director, 1)
                for c in kids[cursor..<(cursor + size)] { nodes[c].parent = dir }
                dirs.append(dir)
                cursor += size
            }
            group(dirs, under: parent)
        }
        for e in execIdx { if let kids = childrenOf[e] { group(kids, under: e) } }

        // Creation order: executives, directors, leads, other ratio roles, members, support.
        let order = nodes.indices.sorted { (nodes[$0].rank, nodes[$0].seq) < (nodes[$1].rank, nodes[$1].seq) }
        var handleOf = [Int: String]()
        var counters: [String: Int] = [:]
        for i in order {
            let n = nodes[i]
            let template = pack.role(n.role) ?? .generic(n.role)
            if n.rank == 0 { handleOf[i] = template.handlePrefix; continue }
            counters[template.handlePrefix, default: 0] += 1
            handleOf[i] = "\(template.handlePrefix)-\(counters[template.handlePrefix]!)"
        }
        let agents = order.map { i -> PlannedAgent in
            let n = nodes[i]
            let template = pack.role(n.role) ?? .generic(n.role)
            return PlannedAgent(handle: handleOf[i]!, role: n.role, managerHandle: n.parent.flatMap { handleOf[$0] },
                                team: n.team, title: template.title)
        }
        return OrgPlan(goal: goal, agents: agents)
    }

    /// Splits a full plan into the agents to seat now and the vacancies to fill when work calls for them.
    public static func staff(plan: OrgPlan, pack: IndustryPack, readyWidth: Int, seatBudget: Int)
        -> (seated: OrgPlan, vacancies: [PlannedAgent]) {
        let triggers = Set(pack.triggerRoles)
        let leadCount = Set(plan.agents.compactMap(\.team)).count
        let cap = min(plan.agents.count, seatBudget, max(6, readyWidth + leadCount))
        var seatedAgents: [PlannedAgent] = []
        var vacancies: [PlannedAgent] = []
        for a in plan.agents {
            if !triggers.contains(a.role), seatedAgents.count < cap { seatedAgents.append(a) } else { vacancies.append(a) }
        }
        // A seated agent whose manager is vacant reports to its nearest seated ancestor.
        let seatedHandles = Set(seatedAgents.map(\.handle))
        let manager = Dictionary(plan.agents.map { ($0.handle, $0.managerHandle) }, uniquingKeysWith: { f, _ in f })
        for i in seatedAgents.indices {
            var m = seatedAgents[i].managerHandle
            var steps = 0
            while let c = m, !seatedHandles.contains(c), steps <= plan.agents.count { m = manager[c] ?? nil; steps += 1 }
            seatedAgents[i].managerHandle = m
        }
        return (OrgPlan(goal: plan.goal, agents: seatedAgents), vacancies)
    }
}

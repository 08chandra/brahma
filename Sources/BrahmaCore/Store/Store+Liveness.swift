import Foundation
import GRDB

/// A cycle of agents waiting on each other. `members` are agent ids in cycle order, comma-joined; `signature` is the sorted ids.
public struct DeadlockRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "deadlock"

    public var id: Int64?
    public var companyId: String
    public var signature: String
    public var members: String
    public var detectedActive: Double
    /// An agent id, or "owner".
    public var escalatedTo: String?
    public var ownerEscalated: Bool = false
    public var resolvedAt: Date?

    public var memberIds: [String] { members.split(separator: ",").map(String.init) }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Store {
    // MARK: Sweep

    /// The tick's liveness pass for one company (the orchestrator calls it every `Liveness.scanInterval` active seconds):
    /// deadlock detection and item aging. Nothing runs while the company's clock is frozen.
    public func sweepLiveness(companyId: String, now: Date = Store.now()) throws {
        guard !isFrozen(companyId: companyId) else { return }
        try writer.write { db in
            guard let company = try Company.fetchOne(db, key: companyId) else { return }
            let active = try Store.activeNow(db: db, companyId: companyId)
            try sweepDeadlocks(db, company: company, active: active, now: now)
            try sweepAging(db, company: company, active: active, now: now)
            try resolveOverSpan(db, company: company, now: now)
        }
    }

    // MARK: Deadlocks

    private func waitEdges(_ db: Database, companyId: String) throws -> [WaitEdge] {
        let live = try Agent.filter(Column("companyId") == companyId && Column("state") != AgentState.killed.rawValue).fetchAll(db)
        let liveIds = Set(live.map(\.id))
        var edges: [WaitEdge] = []
        func add(_ from: String, _ to: String?, _ via: String?) {
            guard let to, to != from, liveIds.contains(to), liveIds.contains(from) else { return }
            if !edges.contains(where: { $0.from == from && $0.to == to }) { edges.append(WaitEdge(from: from, to: to, via: via)) }
        }
        func owner(of item: WorkItem) throws -> String? { try item.ownerId ?? Store.leaseHolderId(db: db, itemId: item.id) }
        for a in live where a.state == .blocked {
            switch a.blocker {
            case .agent(let x)?: add(a.id, x, nil)
            case .workItem(let id, _)?:
                if let item = try WorkItem.fetchOne(db, key: id), item.status != .done {
                    add(a.id, try owner(of: item), item.key)
                    // An item waiting for review also waits on its reviewer.
                    if item.reviewerId != nil, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workItem WHERE id = ? AND \(Store.pendingReviewWhere)",
                                                              arguments: [item.id]) ?? 0 > 0 {
                        add(a.id, item.reviewerId, item.key)
                    }
                }
            default: break
            }
        }
        // The holder of a leased item waits for the owners of that item's undone dependencies.
        for lease in try WorkLease.filter(Column("companyId") == companyId).order(Column("acquiredAt")).fetchAll(db) {
            let deps = try WorkItem.fetchAll(db, sql: """
                SELECT dep.* FROM workItemDependency d JOIN workItem dep ON dep.id = d.dependsOnId
                WHERE d.itemId = ? AND dep.status <> 'done' ORDER BY dep.number
                """, arguments: [lease.itemId])
            for dep in deps { add(lease.agentId, try owner(of: dep), dep.key) }
        }
        return edges
    }

    /// Ancestors of the agent (manager first), at most `AskLifecycle.maxAncestorHops`.
    func managerChain(_ db: Database, of id: String) throws -> [Agent] {
        var chain: [Agent] = []
        var seen: Set<String> = [id]
        var next = try Agent.fetchOne(db, key: id)?.managerId
        for _ in 0..<AskLifecycle.maxAncestorHops {
            guard let m = next, seen.insert(m).inserted, let a = try Agent.fetchOne(db, key: m) else { break }
            chain.append(a)
            next = a.managerId
        }
        return chain
    }

    /// The nearest live ancestor all members share (members excluded), else nil.
    private func lowestCommonManager(_ db: Database, members: [String]) throws -> Agent? {
        guard let first = members.first else { return nil }
        let chains = try members.map { try managerChain(db, of: $0) }
        let others = chains.dropFirst().map { Set($0.map(\.id)) }
        let memberSet = Set(members)
        return chains[0].first { a in a.state != .killed && !memberSet.contains(a.id) && others.allSatisfy { $0.contains(a.id) } && a.id != first }
    }

    private func sweepDeadlocks(_ db: Database, company: Company, active: Double, now: Date) throws {
        let edges = try waitEdges(db, companyId: company.id)
        var cycles: [String: [String]] = [:]
        var order: [String] = []
        for raw in WaitForGraph.cycles(edges: edges) {
            // Written from the member with the smallest handle, so the message reads the same however ids sort.
            var names: [String: String] = [:]
            for id in raw { names[id] = try Agent.fetchOne(db, key: id)?.name ?? id }
            let start = raw.indices.min { (names[raw[$0]] ?? "") < (names[raw[$1]] ?? "") } ?? 0
            let c = Array(raw[start...] + raw[..<start])
            let sig = WaitForGraph.signature(c)
            if cycles[sig] == nil { cycles[sig] = c; order.append(sig) }
        }
        let open = try DeadlockRecord.filter(Column("companyId") == company.id && Column("resolvedAt") == nil).order(Column("id")).fetchAll(db)
        for var row in open {
            if cycles[row.signature] == nil {
                row.resolvedAt = now
                try row.update(db)
                try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .work,
                                  text: "deadlock resolved: \(try handles(db, row.memberIds))", createdAt: now).insert(db)
            } else if !row.ownerEscalated, active - row.detectedActive >= Liveness.deadlockOwnerAfter {
                row.ownerEscalated = true
                try row.update(db)
                let text = "Deadlock unresolved after \(StallExplainer.age(active - row.detectedActive)): "
                    + (try deadlockText(db, cycle: row.memberIds, edges: edges))
                try MessageRouter(store: self).sendDM(db: db, companyId: company.id, from: .system, to: "owner", text: text, now: now)
            }
        }
        let known = Set(open.map(\.signature))
        for sig in order where !known.contains(sig) {
            guard let cycle = cycles[sig] else { continue }
            let text = try deadlockText(db, cycle: cycle, edges: edges)
            var row = DeadlockRecord(id: nil, companyId: company.id, signature: sig, members: cycle.joined(separator: ","),
                                     detectedActive: active, escalatedTo: nil, ownerEscalated: false, resolvedAt: nil)
            if let manager = try lowestCommonManager(db, members: cycle) {
                row.escalatedTo = manager.id
                try alert(db: db, companyId: company.id, agentId: manager.id, text: text, now: now)
            } else {
                row.escalatedTo = "owner"
                row.ownerEscalated = true
                try MessageRouter(store: self).sendDM(db: db, companyId: company.id, from: .system, to: "owner", text: text, now: now)
            }
            try row.insert(db)
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .error,
                              text: "deadlock: \(try handles(db, cycle + [cycle[0]]))", createdAt: now).insert(db)
        }
    }

    private func handles(_ db: Database, _ ids: [String]) throws -> String {
        try ids.map { "@" + (try Agent.fetchOne(db, key: $0)?.name ?? "?") }.joined(separator: " → ")
    }

    /// `Deadlock: @a waits on @b, @b waits on @a (via KEY). Break it by answering one of them or reassigning.` Only handles and
    /// item keys, which the engine writes, appear.
    private func deadlockText(_ db: Database, cycle: [String], edges: [WaitEdge]) throws -> String {
        var parts: [String] = []
        var keys: [String] = []
        for (i, id) in cycle.enumerated() {
            let to = cycle[(i + 1) % cycle.count]
            parts.append("@\(try Agent.fetchOne(db, key: id)?.name ?? "?") waits on @\(try Agent.fetchOne(db, key: to)?.name ?? "?")")
            if let via = edges.first(where: { $0.from == id && $0.to == to })?.via, !keys.contains(via) { keys.append(via) }
        }
        let via = keys.isEmpty ? "" : " (via \(keys.joined(separator: ", ")))"
        return "Deadlock: \(parts.joined(separator: ", "))\(via). Break it by answering one of them or reassigning."
    }

    public func openDeadlocks(companyId: String) throws -> [DeadlockRecord] {
        try writer.read { db in
            try DeadlockRecord.filter(Column("companyId") == companyId && Column("resolvedAt") == nil).order(Column("id")).fetchAll(db)
        }
    }

    // MARK: Item aging

    private func sweepAging(_ db: Database, company: Company, active: Double, now: Date) throws {
        let items = try WorkItem.fetchAll(db, sql: """
            SELECT * FROM workItem WHERE companyId = ? AND status = 'inProgress' AND id NOT IN (SELECT itemId FROM workLease)
            ORDER BY number
            """, arguments: [company.id])
        var current: Set<String> = []
        for item in items {
            // The last real change: aging's own events don't count as one.
            guard let touched = try Double.fetchOne(db, sql: "SELECT MAX(createdActive) FROM workItemEvent WHERE itemId = ? AND kind <> 'aging'",
                                                    arguments: [item.id]) else { continue }
            let idle = active - touched
            let level = Liveness.itemAging.filter { idle >= $0 }.count
            guard level > 0 else { continue }
            current.insert(item.id)
            let done = try Int.fetchOne(db, sql: "SELECT level FROM agingNotice WHERE companyId = ? AND subject = ?",
                                        arguments: [company.id, item.id]) ?? 0
            guard level > done else { continue }
            for lvl in (done + 1)...level { try notifyAging(db, item: item, level: lvl, idle: idle, company: company, now: now) }
            try db.execute(sql: "INSERT OR REPLACE INTO agingNotice(companyId, subject, level) VALUES (?, ?, ?)",
                           arguments: [company.id, item.id, level])
        }
        // An item that changed, got a lease or left `inProgress` starts over.
        let noted = try String.fetchAll(db, sql: "SELECT subject FROM agingNotice WHERE companyId = ?", arguments: [company.id])
        for subject in noted where !current.contains(subject) {
            try db.execute(sql: "DELETE FROM agingNotice WHERE companyId = ? AND subject = ?", arguments: [company.id, subject])
        }
    }

    private func notifyAging(_ db: Database, item: WorkItem, level: Int, idle: Double, company: Company, now: Date) throws {
        // Level 1: the assignee's manager. Level 2: the next ancestor. With nobody left, the owner.
        var chain: [Agent] = []
        for id in [item.ownerId, item.authorId] {
            guard let id, let a = try Agent.fetchOne(db, key: id), a.companyId == company.id else { continue }
            chain = try managerChain(db, of: a.id).filter { $0.state != .killed }
            break
        }
        let target = chain.count >= level ? chain[level - 1] : nil
        let holder = try item.ownerId.flatMap { try Agent.fetchOne(db, key: $0)?.name }.map { " (@\($0))" } ?? " (unassigned)"
        let text = "\(item.key)\(holder) has been In progress with no lease and no activity for \(StallExplainer.age(idle)). "
            + "Check on it or reassign it."
        try recordItemEvent(db: db, item: item, actor: "system", kind: .aging, text: "no activity for \(StallExplainer.age(idle)) (level \(level))",
                            onlyAlsoNotify: true, now: now)
        if let target {
            try alert(db: db, companyId: company.id, agentId: target.id, text: text, now: now)
        } else {
            try MessageRouter(store: self).sendDM(db: db, companyId: company.id, from: .system, to: "owner", text: text, now: now)
        }
    }

    /// An over-span issue ends when the node is back at the limit or gone.
    private func resolveOverSpan(_ db: Database, company: Company, now: Date) throws {
        for var issue in try OrgIssueRecord.filter(Column("companyId") == company.id && Column("kind") == OrgIssueRecord.overSpan
                                                   && Column("resolvedAt") == nil).fetchAll(db) {
            guard let id = issue.agentId else { continue }
            let manager = try Agent.fetchOne(db, key: id)
            let n = try Agent.filter(Column("managerId") == id && Column("state") != AgentState.killed.rawValue).fetchCount(db)
            if manager == nil || manager?.state == .killed || n <= OrgGenerator.maxReports {
                issue.resolvedAt = now
                try issue.update(db)
            }
        }
    }
}

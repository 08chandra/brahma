import Foundation
import GRDB

extension Store {
    /// Why this company has little or nothing running, read in one transaction. `memory` is the orchestrator's own reading
    /// (a CLI process has none).
    public func stallReport(companyId: String, now: Date = Store.now(), memory: MemoryPressure = .normal) throws -> StallReport {
        let input = try writer.read { db -> StallInput in
            guard let company = try Company.fetchOne(db, key: companyId) else { throw StoreError.notFound }
            var input = StallInput()
            let active = try Store.activeNow(db: db, companyId: companyId)
            let live = try Agent.filter(Column("companyId") == companyId && Column("state") != AgentState.killed.rawValue).fetchAll(db)
            input.running = live.filter { $0.state == .running }.count
            for a in live { input.stateCounts[a.state.rawValue, default: 0] += 1 }
            input.companyPaused = company.status == .paused
            if let hold = try EngineHold.fetchOne(db, key: 1) {
                input.hold = StallHold(reason: hold.reason.rawValue, detail: hold.detail, since: hold.since)
            }
            input.memory = memory
            if let json = try String.fetchOne(db, sql: "SELECT report FROM engineProbe WHERE id = 1"),
               let report = try? JSONDecoder().decode(DoctorReport.self, from: Data(json.utf8)), !report.ok {
                input.doctorOk = false
                input.doctorDetail = report.items.first { $0.status == .fail }.map { "\($0.name): \($0.detail)" } ?? "failed"
            }
            let info = try Store.latestRateLimit(db: db)
            let share = try Double.fetchOne(db, sql: "SELECT weeklyShare FROM ownerSettings WHERE id = 1") ?? 0.7
            input.usage = UsageGate.evaluateFiveHour(info, mode: company.usageMode, now: now)
            input.overageAllowed = info.map { $0.overageStatus == "allowed" || $0.isUsingOverage } ?? false
            input.pace = UsageGate.pace(info, reserve: company.ownerReserve ?? (1 - share), now: now)

            var groups: [String: Int] = [:]
            for a in live where a.state == .blocked {
                switch a.blocker {
                case .agent(let id)?: groups["@" + (try Agent.fetchOne(db, key: id)?.name ?? "?"), default: 0] += 1
                case .workItem(_, let key)?: groups[key, default: 0] += 1
                case .owner?: groups["you", default: 0] += 1
                case .usageLimit?: groups["usage limit", default: 0] += 1
                default: break
                }
            }
            input.blockerGroups = groups.map { StallBlockerGroup(target: $0.key, count: $0.value) }
            let asks = try Ask.filter(Column("companyId") == companyId && Column("status") == AskStatus.pendingOwner.rawValue).fetchAll(db)
            input.ownerAskCount = asks.count
            input.oldestOwnerAsk = asks.map { max(0, active - $0.statusSinceActive) }.max() ?? 0
            for row in try DeadlockRecord.filter(Column("companyId") == companyId && Column("resolvedAt") == nil)
                .order(Column("id")).fetchAll(db) {
                input.deadlocks.append(try row.memberIds.map { try Agent.fetchOne(db, key: $0)?.name ?? "?" })
            }
            let ready = try WorkItem.filter(Column("companyId") == companyId
                                            && Column("status") == WorkItemStatus.ready.rawValue).order(Column("number")).fetchAll(db)
            input.readyItems = ready.count
            for item in ready {
                // Only the path rules: a Ready item the dispatch pass skips because another one is still in progress or in review.
                if let why = try pathRefusal(db, item: item) {
                    input.readyHeldBack += 1
                    if input.readyHeldBackExample == nil { input.readyHeldBackExample = why }
                }
            }
            let leased = Set(try String.fetchAll(db, sql: "SELECT agentId FROM workLease WHERE companyId = ?", arguments: [companyId]))
            input.idleAgents = live.filter { ($0.state == .ready || $0.state == .sleeping) && !$0.paused && !leased.contains($0.id) }.count
            let blocked = try WorkItem.filter(Column("companyId") == companyId
                                              && Column("status") == WorkItemStatus.blocked.rawValue).fetchAll(db)
            let long = blocked.compactMap { item in item.blockedSinceActive.map { (item, active - $0) } }
                .filter { $0.1 >= Liveness.blockedLong }
            input.longBlockedCount = long.count
            if let oldest = long.max(by: { $0.1 < $1.1 }) { input.oldestBlockedKey = oldest.0.key; input.oldestBlockedAge = oldest.1 }
            return input
        }
        return StallExplainer.explain(input, timeZone: ownerTimeZone(), now: now)
    }
}

import Foundation
import GRDB

/// A single-writer lease: the one agent allowed to change an item, working in its own git worktree. The expiry counts
/// company-active seconds, so a pause, a hold or a closed app never ages it.
public struct WorkLease: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workLease"
    /// Renewed to `activeNow + ttl` after each successful turn of the holder; an `inReview` item's lease never expires.
    public static let ttl: TimeInterval = 7200

    public var itemId: String
    public var companyId: String
    public var agentId: String
    public var acquiredAt: Date
    public var expiresActive: Double
    /// Plan C2a: the item branch's head when the lease was claimed (`recordClaimHead`): where the taint record of a turn that
    /// claimed it starts.
    public var claimHead: String? = nil

    public init(itemId: String, companyId: String, agentId: String, acquiredAt: Date, expiresActive: Double) {
        self.itemId = itemId; self.companyId = companyId; self.agentId = agentId
        self.acquiredAt = acquiredAt; self.expiresActive = expiresActive
    }

    /// For display only: when the lease runs out, if the company stays active.
    public func expiresAt(activeNow: Double, now: Date) -> Date { now.addingTimeInterval(max(expiresActive - activeNow, 0)) }
}

extension Store {
    // MARK: Reads

    public func lease(itemId: String) throws -> WorkLease? {
        try writer.read { db in try WorkLease.fetchOne(db, key: itemId) }
    }

    public func lease(agentId: String) throws -> WorkLease? {
        try writer.read { db in try WorkLease.filter(Column("agentId") == agentId).fetchOne(db) }
    }

    public func leases(companyId: String) throws -> [WorkLease] {
        try writer.read { db in try WorkLease.filter(Column("companyId") == companyId).order(Column("acquiredAt")).fetchAll(db) }
    }

    /// The lease on the item with this key, if any.
    public func lease(companyId: String, key: String) throws -> WorkLease? {
        try writer.read { db in
            try WorkLease.fetchOne(db, sql: """
                SELECT workLease.* FROM workLease JOIN workItem ON workItem.id = workLease.itemId
                WHERE workItem.companyId = ? AND workItem.key = ?
                """, arguments: [companyId, key.uppercased()])
        }
    }

    // MARK: Owner setting: hot paths

    static let maxHotPaths = 100

    /// Globs that serialize merges: lockfiles, manifests, migrations, routers. The owner may replace them.
    public func hotPaths() -> [String] {
        (try? writer.read { db in try Store.hotPaths(db: db) }) ?? WorkPolicy.defaultHotPaths
    }

    static func hotPaths(db: Database) throws -> [String] {
        guard let json = try String.fetchOne(db, sql: "SELECT hotPaths FROM ownerSettings WHERE id = 1"),
              let globs = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return WorkPolicy.defaultHotPaths }
        return globs
    }

    /// `nil` goes back to `WorkPolicy.defaultHotPaths`.
    public func setHotPaths(_ globs: [String]?) throws {
        if let globs {
            do { try CheckSpec.validatePaths(globs, what: "hot", max: Self.maxHotPaths) } catch let e as WorkError { throw SettingsError.invalid(e.message) }
        }
        let json = globs.map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data("[]".utf8), as: UTF8.self) }
        try writer.write { db in
            try Store.ensureOwnerSettings(db)
            try db.execute(sql: "UPDATE ownerSettings SET hotPaths = ? WHERE id = 1", arguments: [json])
        }
    }

    // MARK: Claim

    /// Takes the lease on an item: the only way an agent starts work. One transaction, so concurrent claims on the same
    /// item (or by the same agent) leave exactly one lease. `engine` marks a claim the engine made for an idle agent.
    /// Refusals are `WorkError.conflict` with the message the agent sees.
    @discardableResult
    public func claimLease(itemId: String, agentId: String, engine: Bool = false, now: Date = Store.now()) throws -> WorkLease {
        // A refusal is returned, not thrown, so the reap of an expired lease it may have done first is kept.
        let outcome: Result<WorkLease, WorkError> = try writer.write { db in
            do { return .success(try claimLease(db: db, itemId: itemId, agentId: agentId, engine: engine, now: now)) }
            catch let e as WorkError { return .failure(e) }
        }
        return try outcome.get()
    }

    func claimLease(db: Database, itemId: String, agentId: String, engine: Bool, now: Date) throws -> WorkLease {
        guard var item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
        let actor = try resolveActor(db, .agent(agentId), companyId: item.companyId)
        let active = try Self.activeNow(db: db, companyId: item.companyId)
        // An expired lease is reaped on the spot, so a claim never waits for the next tick.
        if let held = try WorkLease.fetchOne(db, key: itemId), try Self.isExpired(db, held, item: item, active: active) {
            try reapOne(db, held, now: now)
            item = try WorkItem.fetchOne(db, key: itemId) ?? item
        }
        if let reason = try claimRefusal(db, item: item, agentId: agentId, active: active, now: now) { throw WorkError.conflict(reason) }
        if item.ownerId == nil { item.ownerId = agentId }
        item.status = .inProgress
        item.everStarted = true
        if item.firstClaimedAt == nil { item.firstClaimedAt = now; item.firstClaimedActive = active }
        item.blockedReason = nil; item.blockedSinceActive = nil; item.blockedAskId = nil; item.blockedAskBy = nil
        item.statusBeforeBlock = nil
        item.stopReason = nil
        item.failedChecksSinceClaim = 0
        item.updatedAt = now
        try item.update(db)
        let lease = WorkLease(itemId: item.id, companyId: item.companyId, agentId: agentId, acquiredAt: now,
                              expiresActive: active + WorkLease.ttl)
        try lease.insert(db)
        try recordItemEvent(db: db, item: item, actor: engine ? "system" : agentId, kind: .leaseClaimed,
                            text: engine ? "assigned by the engine" : "claimed by @\(actor.handle)", now: now)
        return lease
    }

    /// Why `agentId` cannot take the item's lease now, or nil. The order is the order of the messages' precedence.
    func claimRefusal(_ db: Database, item: WorkItem, agentId: String, active: Double, now: Date) throws -> String? {
        guard let company = try Company.fetchOne(db, key: item.companyId) else { return "\(item.key) belongs to no company" }
        guard let def = catalog.pack(company.packId)?.itemType(item.type.rawValue), !def.container, def.claimable else {
            return "\(item.key) is a \(item.type.rawValue); claim one of its tasks"
        }
        let held = try WorkLease.fetchOne(db, key: item.id)
        if let held {
            if held.agentId == agentId { return "you already hold \(item.key); release it first" }
            let handle = try Agent.fetchOne(db, key: held.agentId)?.name ?? "?"
            let until = Self.clockTime(db, held.expiresAt(activeNow: active, now: now))
            return "\(item.key) is leased by @\(handle) until \(until)"
        }
        guard item.status == .ready || item.status == .inProgress else { return "\(item.key) is \(item.status.rawValue)" }
        let waits = try String.fetchAll(db, sql: """
            SELECT dep.key FROM workItemDependency d JOIN workItem dep ON dep.id = d.dependsOnId
            WHERE d.itemId = ? AND dep.status <> 'done' ORDER BY dep.number
            """, arguments: [item.id])
        if !waits.isEmpty { return "\(item.key) waits on \(waits.joined(separator: ", "))" }
        if def.requiresCheck, item.checkSpec == nil {
            return "\(item.key) has no executable check yet; ask its author or reviewer to add one"
        }
        if let other = try WorkLease.filter(Column("agentId") == agentId).fetchOne(db),
           let key = try String.fetchOne(db, sql: "SELECT key FROM workItem WHERE id = ?", arguments: [other.itemId]) {
            return "you already hold \(key); release it first"
        }
        if let owner = item.ownerId, owner != agentId {
            return "\(item.key) is assigned to @\(try Agent.fetchOne(db, key: owner)?.name ?? "?")"
        }
        if item.reviewerId == agentId { return "you are this item's reviewer" }
        return try pathRefusal(db, item: item)
    }

    /// The path-overlap guard and the hot-path rule against the company's items in progress or in review.
    func pathRefusal(_ db: Database, item: WorkItem) throws -> String? {
        let others = try WorkItem.filter(Column("companyId") == item.companyId && Column("id") != item.id
            && [WorkItemStatus.inProgress.rawValue, WorkItemStatus.inReview.rawValue].contains(Column("status")))
            .order(Column("number")).fetchAll(db)
        guard !others.isEmpty else { return nil }
        let mine = PathOverlap.claimed(item)
        for other in others {
            if let path = PathOverlap.firstOverlap(mine, PathOverlap.claimed(other)) {
                return "\(item.key) overlaps \(other.key) (\(path)); wait until it merges"
            }
        }
        let hot = try Self.hotPaths(db: db)
        func hotPath(_ paths: [String]) -> String? { paths.first { p in hot.contains { WorkPolicy.globMatches($0, p) } } }
        if let mineHot = hotPath(mine) {
            for other in others {
                if let theirs = hotPath(PathOverlap.claimed(other)) {
                    return "\(item.key) touches a hot path (\(mineHot)) and \(other.key) already does (\(theirs)); wait until it merges"
                }
            }
        }
        return nil
    }

    private static func isExpired(_ db: Database, _ lease: WorkLease, item: WorkItem, active: Double) throws -> Bool {
        if try Agent.fetchOne(db, key: lease.agentId)?.state == .killed { return true }
        return lease.expiresActive < active && item.status != .inReview
    }

    /// `HH:mm` in the owner's zone, readable inside a transaction.
    static func clockTime(_ db: Database, _ date: Date) -> String {
        let id = (try? String.fetchOne(db, sql: "SELECT timeZone FROM ownerSettings WHERE id = 1")) ?? nil
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = id.flatMap { TimeZone(identifier: $0) } ?? .current
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    // MARK: Release

    /// The holder gives the item back: the lease goes, an `inProgress` item returns to `ready`. `undoOwner` also clears
    /// the assignee when this very claim set it (a claim whose worktree could not be created).
    @discardableResult
    public func releaseLease(itemId: String, agentId: String, note: String?, undoOwner: Bool = false,
                             now: Date = Store.now()) throws -> WorkItem {
        try writer.write { db in
            guard var item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
            let actor = try resolveActor(db, .agent(agentId), companyId: item.companyId)
            guard let lease = try WorkLease.fetchOne(db, key: itemId), lease.agentId == agentId else {
                throw WorkError.forbidden("you do not hold \(item.key)")
            }
            try Store.refuseWhileMerging(db: db, item: item)
            guard item.status != .inReview else {
                throw WorkError.conflict("\(item.key) is in review; the engine releases its lease when the review ends")
            }
            try cancelMerge(db: db, itemId: itemId, now: now)
            try lease.delete(db)
            try Store.endSecretUses(db: db, itemId: itemId, now: now)
            try Store.releaseKBLeases(db: db, itemId: itemId)
            if item.status == .inProgress { item.status = .ready }
            if undoOwner, item.ownerId == agentId { item.ownerId = nil }
            item.updatedAt = now
            try item.update(db)
            var text = "released by @\(actor.handle)"
            if let rawNote = note {
                let note = try redact(rawNote)   // raw, before flattening, so a multi-line secret still matches
                let flat = note.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !flat.isEmpty { text += ": " + String(flat.prefix(500)) }
            }
            try recordItemEvent(db: db, item: item, actor: agentId, kind: .leaseReleased, text: text, now: now)
            return item
        }
    }

    // MARK: Renew, expire, reap

    /// After a successful holder turn: every lease of the agent runs to `activeNow + ttl` (killed-marked ones stay expired).
    static func renewLeases(db: Database, agentId: String, now: Date) throws {
        guard let agent = try Agent.fetchOne(db, key: agentId) else { return }
        let active = try activeNow(db: db, companyId: agent.companyId)
        try db.execute(sql: "UPDATE workLease SET expiresActive = ? WHERE agentId = ? AND expiresActive >= 0",
                       arguments: [active + WorkLease.ttl, agentId])
    }

    /// Takes back leases past their active-time expiry (never on an `inReview` item) and leases of killed holders.
    /// An `inProgress` item returns to `ready`; the assignee stays. The rows are deleted here; the orchestrator removes
    /// each worktree afterwards (keeping the branch). Returns what was reaped.
    @discardableResult
    public func reapLeases(now: Date) throws -> [WorkLease] {
        try writer.write { db in
            let due = try WorkLease.fetchAll(db, sql: """
                SELECT l.* FROM workLease l
                JOIN workItem i ON i.id = l.itemId
                JOIN agent a ON a.id = l.agentId
                LEFT JOIN companyActivity ca ON ca.companyId = l.companyId
                WHERE a.state = 'killed' OR (l.expiresActive < COALESCE(ca.activeSeconds, 0) AND i.status <> 'inReview')
                ORDER BY l.acquiredAt
                """)
            for lease in due { try reapOne(db, lease, now: now) }
            return due
        }
    }

    private func reapOne(_ db: Database, _ lease: WorkLease, now: Date) throws {
        try lease.delete(db)
        try Store.endSecretUses(db: db, itemId: lease.itemId, now: now)
        try Store.releaseKBLeases(db: db, itemId: lease.itemId)
        guard var item = try WorkItem.fetchOne(db, key: lease.itemId) else { return }
        let holder = try Agent.fetchOne(db, key: lease.agentId)
        var text = "lease of @\(holder?.name ?? "?") expired"
        if item.status == .inProgress {
            item.status = .ready
            item.updatedAt = now
            try item.update(db)
            text += "; back to Ready"
        }
        try recordItemEvent(db: db, item: item, actor: "system", kind: .leaseExpired, text: text,
                            alsoNotify: [holder?.managerId].compactMap { $0 }, now: now)
    }

    // MARK: Kill

    /// Part of killing an agent, in the same transaction: its leases are marked expired (the next tick reaps them and
    /// removes the worktrees) and it is unassigned from every item that is not done.
    func releaseWork(of agent: Agent, db: Database, now: Date) throws {
        try db.execute(sql: "UPDATE workLease SET expiresActive = -1 WHERE agentId = ?", arguments: [agent.id])
        try Store.endSecretUses(db: db, agentId: agent.id, now: now)
        let owned = try WorkItem.filter(Column("ownerId") == agent.id && Column("status") != WorkItemStatus.done.rawValue)
            .order(Column("number")).fetchAll(db)
        for var item in owned {
            item.ownerId = nil
            item.updatedAt = now
            try item.update(db)
            try recordItemEvent(db: db, item: item, actor: "system", kind: .assigned, text: "unassigned: @\(agent.name) was killed",
                                alsoNotify: [agent.managerId].compactMap { $0 }, now: now)
        }
    }

    // MARK: Engine dispatch

    /// For an idle individual contributor: takes the lease on the next claimable ready item, in one transaction. Items
    /// qualify when their assignee is the agent or nobody and their team is the agent's or none; the agent is not the
    /// item's reviewer; and `claimLease` would accept it (dependencies done, a check where the type needs one, no
    /// overlapping item in flight). Ordered by priority, then age. `skipping` holds items reaped this tick.
    func engineClaimNext(agentId: String, skipping: Set<String> = [], now: Date) throws -> (lease: WorkLease, item: WorkItem, wasUnowned: Bool)? {
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.state == .ready || agent.state == .sleeping, !agent.paused,
                  let company = try Company.fetchOne(db, key: agent.companyId), company.status == .running,
                  catalog.template(role: agent.role, pack: company.packId).kind == .individual,
                  try WorkLease.filter(Column("agentId") == agentId).fetchCount(db) == 0 else { return nil }
            let candidates = try WorkItem.fetchAll(db, sql: """
                SELECT * FROM workItem WHERE companyId = ? AND status = 'ready' AND (ownerId IS NULL OR ownerId = ?)
                ORDER BY priority, createdAt, number LIMIT 60
                """, arguments: [agent.companyId, agentId])
            let active = try Self.activeNow(db: db, companyId: agent.companyId)
            for item in candidates where !skipping.contains(item.id) && (item.team == nil || item.team == agent.team) {
                guard try claimRefusal(db, item: item, agentId: agentId, active: active, now: now) == nil else { continue }
                let lease = try claimLease(db: db, itemId: item.id, agentId: agentId, engine: true, now: now)
                guard let claimed = try WorkItem.fetchOne(db, key: item.id) else { return nil }
                return (lease, claimed, item.ownerId == nil)
            }
            return nil
        }
    }

    /// Companies that have at least one ready item, for the dispatch pass.
    func companiesWithReadyItems() throws -> Set<String> {
        try writer.read { db in Set(try String.fetchAll(db, sql: "SELECT DISTINCT companyId FROM workItem WHERE status = 'ready'")) }
    }

    // MARK: Critical path

    /// Per agent: reviews waiting on it (an item the engine has checked and nobody has decided) plus audits routed to it and
    /// not yet done. These count as work others wait on, so the reviewer is admitted while the weekly pace is closed.
    func pendingReviewCounts() throws -> [String: Int] {
        try writer.read { db in
            var counts: [String: Int] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT reviewerId AS id, COUNT(*) AS n FROM workItem WHERE reviewerId IS NOT NULL AND \(Store.pendingReviewWhere)
                GROUP BY reviewerId
                """) {
                if let id = String.fromDatabaseValue(row["id"]) { counts[id, default: 0] += Int.fromDatabaseValue(row["n"]) ?? 0 }
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT auditorId AS id, COUNT(*) AS n FROM reviewAudit WHERE auditorId IS NOT NULL AND auditedAt IS NULL GROUP BY auditorId
                """) {
                if let id = String.fromDatabaseValue(row["id"]) { counts[id, default: 0] += Int.fromDatabaseValue(row["n"]) ?? 0 }
            }
            return counts
        }
    }

    /// Per agent: undone items that depend on items it owns or leases (a dependent the agent itself wrote and linked does
    /// not count), one query. The scheduler adds the agents blocked on it.
    func blockingCounts() throws -> [String: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT a.agentId AS agentId, COUNT(DISTINCT dep.id) AS n FROM (
                    SELECT ownerId AS agentId, id AS itemId FROM workItem WHERE ownerId IS NOT NULL AND status <> 'done'
                    UNION
                    SELECT agentId, itemId FROM workLease
                ) a
                JOIN workItemDependency d ON d.dependsOnId = a.itemId
                JOIN workItem dep ON dep.id = d.itemId AND dep.status <> 'done'
                WHERE NOT (d.linkedBy = a.agentId AND dep.authorId = a.agentId)
                GROUP BY a.agentId
                """)
            return Dictionary(rows.map { (String.fromDatabaseValue($0["agentId"]) ?? "", Int.fromDatabaseValue($0["n"]) ?? 0) },
                              uniquingKeysWith: { a, _ in a })
        }
    }
}

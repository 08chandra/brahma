import Foundation
import GRDB

/// One admitted Ultra run (`ultraReservation`, `"v5-modes"`; design §3.8.1). Its cap is reserved when it is admitted and counts
/// against the company's Ultra allowance, the 7-day projection and every other turn's 5-hour check until it is released down
/// to what the turn was charged.
public struct UltraReservation: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ultraReservation"

    public var turnId: String
    public var companyId: String
    public var itemId: String?
    public var variant: UltraVariant
    public var capLE: Double
    /// `owner` or `policy`.
    public var approvedBy: String
    /// The approved `boost` ask the run used (nil: the owner's Ultra intensity).
    public var askId: String?
    public var createdAt: Date
    public var releasedAt: Date?
    public var actualLE: Double?

    public var isOpen: Bool { releasedAt == nil }
}

/// An approved Ultra run an item has not used yet: an approved `boost` ask with no reservation, or the owner's Ultra intensity.
public struct PendingUltraRun: Equatable, Sendable {
    public var variant: UltraVariant
    public var approver: UltraApprover
    public var origin: UltraOrigin
    public var askId: String?
}

extension Store {
    // MARK: Reservations

    /// Reserves the run's cap for `turnId` and consumes its approval, in one transaction: the item's budget grows by the cap
    /// once (`budgetBoostLE`), the owner's Ultra intensity (one run) goes back to `auto`, and the item records who approved it.
    ///
    /// S28: the count gates are judged again inside this transaction (the database's writer is the one serialization point), so
    /// two admissions racing for the last concurrent slot, the day's last run or the allowance's last cap cannot both reserve:
    /// the loser gets the `UltraRefusal` and runs the computed rung. `caps`: the plan tier's caps (nil: the count gates are not
    /// re-judged, for callers that only consume an approval).
    @discardableResult
    func reserveUltra(turnId: String, companyId: String, itemId: String, run: PendingUltraRun, caps: UltraCaps? = nil,
                      now: Date) throws -> UltraReservation {
        try writer.write { db in
            if let existing = try UltraReservation.fetchOne(db, key: turnId) { return existing }
            if let caps { try Store.recheckUltraCounts(db: db, companyId: companyId, variant: run.variant, caps: caps, now: now) }
            let r = UltraReservation(turnId: turnId, companyId: companyId, itemId: itemId, variant: run.variant, capLE: run.variant.capLE,
                                     approvedBy: run.approver.rawValue, askId: run.askId, createdAt: now, releasedAt: nil, actualLE: nil)
            try r.insert(db)
            if var item = try WorkItem.fetchOne(db, key: itemId), item.companyId == companyId {
                item.budgetBoostLE += run.variant.capLE
                if run.origin == .ownerIntensity, item.intensity == .ultra { item.intensity = .auto }
                item.updatedAt = now
                try item.update(db)
                try recordItemEvent(db: db, item: item, actor: "system", kind: .modeEscalated,
                                    text: "\(run.variant.title) run started (approved by \(run.approver.digestName)); budget +$"
                                        + TurnProfileCompiler.money(run.variant.capLE) + " LE for it", now: now)
            }
            return r
        }
    }

    /// Gates 7 and 8 again, in the reserving transaction (S28).
    static func recheckUltraCounts(db: Database, companyId: String, variant: UltraVariant, caps: UltraCaps, now: Date) throws {
        let running = try UltraReservation.filter(Column("releasedAt") == nil).fetchCount(db)
        if running >= caps.concurrent {
            throw UltraRefusal(gate: 8, reason: "another Ultra turn is running (at most \(caps.concurrent) at once)")
        }
        let tz = try String.fetchOne(db, sql: "SELECT timeZone FROM ownerSettings WHERE id = 1").flatMap(TimeZone.init(identifier:)) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let today = try UltraReservation.filter(Column("companyId") == companyId && Column("createdAt") >= calendar.startOfDay(for: now)).fetchAll(db)
        if today.count >= caps.perCompanyDay {
            throw UltraRefusal(gate: 8, reason: "\(today.count) Ultra run(s) today already (at most \(caps.perCompanyDay))")
        }
        let full = today.filter { $0.variant == .full }.count
        if variant == .full, full >= caps.fullPerCompanyDay {
            throw UltraRefusal(gate: 8, reason: "\(full) full Ultra run(s) today already (at most \(caps.fullPerCompanyDay))")
        }
        guard let allowance = try ultraAllowance(db: db, companyId: companyId, now: now), allowance.leftLE + 1e-9 >= variant.capLE else {
            throw UltraRefusal(gate: 7, reason: "allowance used")
        }
    }

    /// Releases the reservation of `turnId` down to `actualLE` (in the caller's transaction). Idempotent.
    static func releaseUltra(db: Database, turnId: String, actualLE: Double, now: Date) throws {
        guard var r = try UltraReservation.fetchOne(db, key: turnId), r.isOpen else { return }
        r.releasedAt = now
        r.actualLE = max(0, actualLE)
        try r.update(db)
    }

    /// A reservation of a turn that did not launch after all: released at zero, its approval given back (the item's boost is
    /// taken off again, the owner's intensity restored).
    func cancelUltraReservation(turnId: String, now: Date) throws {
        try writer.write { db in
            guard let r = try UltraReservation.fetchOne(db, key: turnId), r.isOpen else { return }
            if let itemId = r.itemId, var item = try WorkItem.fetchOne(db, key: itemId) {
                item.budgetBoostLE = max(0, item.budgetBoostLE - r.capLE)
                if r.askId == nil, r.approvedBy == UltraApprover.owner.rawValue { item.intensity = .ultra }
                item.updatedAt = now
                try item.update(db)
            }
            try r.delete(db)
        }
    }

    /// Open reservations whose turn is no longer in progress (an engine that died mid-run): released, charged in full, as a
    /// killed run is (design §3.8.3).
    func releaseOrphanUltraReservations(now: Date) throws {
        try writer.write { db in
            guard try db.tableExists("ultraReservation") else { return }
            let rows = try UltraReservation.filter(Column("releasedAt") == nil).fetchAll(db)
            for r in rows {
                let outcome = try String.fetchOne(db, sql: "SELECT outcome FROM turn WHERE id = ?", arguments: [r.turnId])
                guard outcome != TurnOutcome.inProgress.rawValue else { continue }
                let cost = try Double.fetchOne(db, sql: "SELECT costLE FROM turn WHERE id = ?", arguments: [r.turnId]) ?? nil
                try Store.releaseUltra(db: db, turnId: r.turnId, actualLE: UltraAccounting.charge(cost: cost, cap: r.capLE, killed: true),
                                       now: now)
            }
        }
    }

    public func ultraReservations(companyId: String) throws -> [UltraReservation] {
        try writer.read { db in
            try UltraReservation.filter(Column("companyId") == companyId).order(Column("createdAt")).fetchAll(db)
        }
    }

    public func ultraReservation(turnId: String) throws -> UltraReservation? {
        try writer.read { db in try UltraReservation.fetchOne(db, key: turnId) }
    }

    static func openUltraReservationLE(db: Database) throws -> Double {
        guard try db.tableExists("ultraReservation") else { return 0 }
        return try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(capLE), 0) FROM ultraReservation WHERE releasedAt IS NULL") ?? 0
    }

    /// Ultra turns running now, engine-wide (open reservations).
    public func runningUltraCount() throws -> Int {
        try writer.read { db in try UltraReservation.filter(Column("releasedAt") == nil).fetchCount(db) }
    }

    /// The company's Ultra runs since the start of the owner's calendar day: all, and the full-Ultra ones.
    public func ultraRunsToday(companyId: String, now: Date) throws -> (all: Int, full: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ownerTimeZone()
        let start = calendar.startOfDay(for: now)
        return try writer.read { db in
            let rows = try UltraReservation.filter(Column("companyId") == companyId && Column("createdAt") >= start).fetchAll(db)
            return (rows.count, rows.filter { $0.variant == .full }.count)
        }
    }

    // MARK: Allowance

    /// The company's Ultra allowance this week (design §3.6 gate 7): `ultraShare` × the weekly share in $LE (the share over
    /// `pctPerDollar`), the Ultra actuals of the last seven days and the open reservations, and what is left. Nil until the
    /// calibration knows `pctPerDollar`.
    public func ultraAllowance(companyId: String, now: Date) throws -> (totalLE: Double, usedLE: Double, leftLE: Double)? {
        try writer.read { db in try Store.ultraAllowance(db: db, companyId: companyId, now: now) }
    }

    static func ultraAllowance(db: Database, companyId: String, now: Date) throws -> (totalLE: Double, usedLE: Double, leftLE: Double)? {
        guard let company = try Company.fetchOne(db, key: companyId) else { return nil }
        guard let per = try Store.calibration(db).pctPerDollar, per > 0 else { return nil }
        let weekly = try Double.fetchOne(db, sql: "SELECT weeklyShare FROM ownerSettings WHERE id = 1") ?? 0.7
        let share = company.ownerReserve.map { 1 - $0 } ?? weekly
        let total = company.ultraShare * share / per
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let actual = try Double.fetchOne(db, sql: """
            SELECT COALESCE(SUM(actualLE), 0) FROM ultraReservation WHERE companyId = ? AND releasedAt IS NOT NULL AND createdAt >= ?
            """, arguments: [companyId, weekAgo]) ?? 0
        let open = try Double.fetchOne(db, sql: """
            SELECT COALESCE(SUM(capLE), 0) FROM ultraReservation WHERE companyId = ? AND releasedAt IS NULL
            """, arguments: [companyId]) ?? 0
        return (total, actual + open, total - actual - open)
    }

    /// `brahma settings ultra-share <co> <0–50>`: the owner's share of the company's weekly share for Ultra (0 turns it off).
    public func setUltraShare(companyId: String, percent: Int) throws {
        guard (0...50).contains(percent) else { throw SettingsError.invalid("ultra share must be between 0 and 50 percent") }
        try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw StoreError.notFound }
            try db.execute(sql: "UPDATE company SET ultraShare = ? WHERE id = ?", arguments: [Double(percent) / 100, companyId])
        }
    }

    // MARK: Approved runs

    /// The approved Ultra run the item's next work turn may use: the oldest approved `boost` ask with no reservation (its
    /// variant in `payload.proposal`; the failure path's has none and is a full Ultra), else the owner's Ultra intensity.
    public func pendingUltraRun(itemId: String) throws -> PendingUltraRun? {
        try writer.read { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { return nil }
            let asks = try Ask.filter(Column("itemId") == itemId && Column("kind") == AskKind.boost
                                      && Column("status") == AskStatus.approved.rawValue).order(Column("createdAt")).fetchAll(db)
            for ask in asks where try UltraReservation.filter(Column("askId") == ask.id).fetchCount(db) == 0 {
                let variant = ask.payload?.proposal.flatMap(UltraVariant.init(requested:)) ?? .full
                let origin: UltraOrigin = ask.requesterId == "system" ? .failurePath : ask.requesterId == item.ownerId ? .assignee : .lead
                return PendingUltraRun(variant: variant, approver: ask.decidedBy == "owner" ? .owner : .policy, origin: origin, askId: ask.id)
            }
            if item.intensity == .ultra { return PendingUltraRun(variant: .full, approver: .owner, origin: .ownerIntensity, askId: nil) }
            return nil
        }
    }
}

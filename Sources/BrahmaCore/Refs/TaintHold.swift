import Foundation
import GRDB

/// Final wave B1, controller Ruling 23: a turn whose end could not record its taint (`Store.recordTurnTaints` incomplete, or
/// `markHeldItemsIfTainted` failed) is fail-open if nothing else happens: its tainted commits and items would read clean. The
/// engine instead holds the turn's company (no turn, no dispatch, no merge of it starts), raises one owner alert per company
/// ("couldn't record taint after a turn — company held", de-duplicated), and retries the record every tick. The hold lifts
/// only when the retry succeeds, or when the owner clears it (`clearTaintHolds`, the owner principal). The row carries what
/// the retry needs; the orchestrator keeps the hold in memory as well, so a hold whose row could not be written either (the
/// same failing database) still holds while the engine runs.
public struct TaintHold: Codable, Equatable, Sendable {
    public var turnId: String
    public var companyId: String
    public var agentId: String
    /// What `recordTurnTaints` takes: the items held as the turn started (id → head then), every one of them, the turn's own
    /// leased item and the session's taint source (nil: the session was clean, so only the held-item mark is retried).
    public var heldAtStart: [String: String]
    public var heldItemsAtStart: [String]
    public var leasedItemId: String?
    public var source: String?
    /// Whether the held-item mark (`markHeldItemsIfTainted`) is retried too (a holder turn, not a review).
    public var markItems: Bool
    public var createdAt: Date

    public init(turnId: String, companyId: String, agentId: String, heldAtStart: [String: String], heldItemsAtStart: [String],
                leasedItemId: String?, source: String?, markItems: Bool, createdAt: Date) {
        self.turnId = turnId; self.companyId = companyId; self.agentId = agentId; self.heldAtStart = heldAtStart
        self.heldItemsAtStart = heldItemsAtStart; self.leasedItemId = leasedItemId; self.source = source; self.markItems = markItems
        self.createdAt = createdAt
    }
}

extension Store {
    /// The owner alert's text (one per company, however many turns are held).
    public static let taintHoldText = "Brahma couldn't record taint after a turn — company held. No turn of this company starts until "
        + "the record is written (it is retried every few seconds) or you clear the hold: brahma vouch taint-hold <company>."

    /// The reason keying a company's taint-hold alert.
    static func taintHoldReason(_ companyId: String) -> String { "taint-hold:\(companyId)" }

    /// Records the hold (its row, unless one for the turn exists) and raises the company's alert when it had no hold before
    /// (`alert` false: the owner was already alerted for it). Throws when the database refuses (the orchestrator's in-memory
    /// hold still holds, and it writes the row again every tick).
    public func holdForTaint(_ hold: TaintHold, now: Date, alert: Bool = true) throws {
        if refHooks.failTaintHoldWrite { throw WorkError.conflict("injected: the taint hold could not be written") }
        let payload = String(decoding: try JSONEncoder().encode(hold), as: UTF8.self)
        try writer.write { db in
            let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taintHold WHERE companyId = ?", arguments: [hold.companyId]) ?? 0
            try db.execute(sql: """
                INSERT OR IGNORE INTO taintHold (turnId, companyId, agentId, payload, createdAt) VALUES (?, ?, ?, ?, ?)
                """, arguments: [hold.turnId, hold.companyId, hold.agentId, payload, now])
            guard alert, before == 0, try Company.fetchOne(db, key: hold.companyId) != nil else { return }
            try EngineAlerts.raise(store: self, db: db, text: Self.taintHoldText, now: now, reason: Self.taintHoldReason(hold.companyId),
                                   companyId: hold.companyId)
        }
    }

    /// Every hold the database records (oldest first).
    public func taintHolds() throws -> [TaintHold] {
        if refHooks.failTaintHoldRead { throw WorkError.conflict("injected: the taint holds could not be read") }
        return try writer.read { db in
            // A row whose payload can't be decoded still holds its company (fail closed): only the retry needs the payload.
            try Row.fetchAll(db, sql: "SELECT turnId, companyId, agentId, payload, createdAt FROM taintHold ORDER BY createdAt, rowid").map { row in
                let payload: String = row["payload"]
                return (try? JSONDecoder().decode(TaintHold.self, from: Data(payload.utf8)))
                    ?? TaintHold(turnId: row["turnId"], companyId: row["companyId"], agentId: row["agentId"], heldAtStart: [:],
                                 heldItemsAtStart: [], leasedItemId: nil, source: "an unreadable hold record", markItems: true,
                                 createdAt: row["createdAt"])
            }
        }
    }

    /// The companies a recorded hold holds.
    public func taintHeldCompanies() throws -> Set<String> {
        try writer.read { db in Set(try String.fetchAll(db, sql: "SELECT DISTINCT companyId FROM taintHold")) }
    }

    /// The retry: the turn's taint record and (for a holder turn) its held-item mark, again, the mark forced (whether the session
    /// was tainted can no longer be told). Returns whether both were written; when they were, the hold's row is deleted (and the
    /// company's alert answers itself "resolved" once it has no hold left). Never throws.
    public func retryTaintHold(_ hold: TaintHold, home: URL?, now: Date) -> Bool {
        if let source = hold.source {
            guard recordTurnTaints(companyId: hold.companyId, agentId: hold.agentId, turnId: hold.turnId, heldAtStart: hold.heldAtStart,
                                   heldItemsAtStart: hold.heldItemsAtStart, leasedItemId: hold.leasedItemId, source: source, now: now)
            else { return false }
        }
        if hold.markItems {
            do {
                try markHeldItemsIfTainted(agentId: hold.agentId, turnId: hold.turnId, heldAtStart: hold.heldItemsAtStart, home: home,
                                           force: true)
            } catch {
                return false
            }
        }
        do {
            try writer.write { db in
                try db.execute(sql: "DELETE FROM taintHold WHERE turnId = ?", arguments: [hold.turnId])
                try Self.resolveTaintHoldAlertIfFree(db, store: self, companyId: hold.companyId, now: now)
            }
            return true
        } catch {
            return false
        }
    }

    /// The owner clears every taint hold of the company (owner only: the principal and the agent-process guard). Returns how many
    /// turns' holds were cleared. What those turns' records lack stays unrecorded: the owner accepts that.
    @discardableResult
    public func clearTaintHolds(companyId: String, now: Date, owner: OwnerPrincipal) throws -> Int {
        try ProcessRole.refuseInAgentProcess()
        _ = try requireOwner(owner)
        return try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw WorkError.notFound("no such company") }
            try db.execute(sql: "DELETE FROM taintHold WHERE companyId = ?", arguments: [companyId])
            let cleared = db.changesCount
            if cleared > 0 {
                try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .access,
                                  text: "Owner cleared the taint hold (\(cleared) turn(s) whose taint could not be recorded)", createdAt: now).insert(db)
            }
            try Self.resolveTaintHoldAlertIfFree(db, store: self, companyId: companyId, now: now)
            return cleared
        }
    }

    private static func resolveTaintHoldAlertIfFree(_ db: Database, store: Store, companyId: String, now: Date) throws {
        let left = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taintHold WHERE companyId = ?", arguments: [companyId]) ?? 0
        if left == 0 { try store.resolveEngineAlerts(db, reasons: [taintHoldReason(companyId)], now: now) }
    }
}

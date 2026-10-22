import Foundation
import GRDB

/// One assignee request for a stronger work mode (W6). Kept for `request_id` dedupe and rate limiting.
public struct ModeRequestRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "modeRequest"

    public var id: Int64?
    public var companyId: String
    public var itemId: String
    public var agentId: String
    public var requestId: String?
    public var mode: String
    /// The turn the agent was in when it asked; the change applies from the next one.
    public var turnId: String?
    public var createdActive: Double
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct ModeRequestResult: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case raised, alreadyThere, duplicate, ultraUnavailable }
    public var kind: Kind
    /// Text for the agent.
    public var message: String
}

extension Store {
    /// An assignee may raise its own item to R2 (Deep) at most. The change is stored as the item's `rungFloor` and is read when
    /// the next turn starts, so it never alters the turn that asked. Limits: one request per item per three of the agent's
    /// turns, three per agent per active day, and a repeated `requestId` is answered with the first outcome. Ultra is not
    /// available until the sandbox lands (5-lite); the engine's failure-path Ultra goes through `fileFailurePathBoost`.
    public static let modeRequestTurnGap = 3
    public static let modeRequestsPerDay = 3
    public static let requestableFloor = 2

    @discardableResult
    public func requestMode(companyId: String, by agentId: String, itemKey: String, mode: String, reason: String,
                            requestId: String? = nil, now: Date = Store.now()) throws -> ModeRequestResult {
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard agent.state != .killed else { throw WorkError.forbidden("this agent is not active in the company") }
            guard let item = try WorkItem.filter(Column("companyId") == companyId && Column("key") == itemKey.uppercased()).fetchOne(db) else {
                throw WorkError.notFound("no work item \(itemKey.uppercased())")
            }
            guard item.ownerId == agentId else { throw WorkError.forbidden("only the item's assignee can request a mode") }
            let m = mode.trimmingCharacters(in: .whitespaces).lowercased()
            guard m == "deep" || m == "ultra" else { throw WorkError.invalid("mode must be deep or ultra") }
            let why = reason.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !why.isEmpty else { throw WorkError.invalid("a reason is required") }
            guard why.count <= 1000 else { throw WorkError.invalid("the reason is longer than 1000 characters") }
            let rid = requestId?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100).description
            if let rid, !rid.isEmpty,
               try ModeRequestRecord.filter(Column("itemId") == item.id && Column("agentId") == agentId && Column("requestId") == rid).fetchCount(db) > 0 {
                return ModeRequestResult(kind: .duplicate, message: "Request \(rid) was already recorded for \(item.key); nothing changed.")
            }
            if m == "ultra" {
                return ModeRequestResult(kind: .ultraUnavailable, message: "Ultra arrives with the sandbox (5-lite)")
            }
            let active = try Store.activeNow(db: db, companyId: companyId)
            let today = try ModeRequestRecord.filter(Column("agentId") == agentId && Column("createdActive") > active - 86_400).fetchCount(db)
            guard today < Store.modeRequestsPerDay else {
                throw WorkError.conflict("you have made \(Store.modeRequestsPerDay) mode requests today; ask your manager instead")
            }
            if let last = try ModeRequestRecord.filter(Column("itemId") == item.id && Column("agentId") == agentId)
                .order(Column("id").desc).fetchOne(db) {
                let since: Int
                if let turnId = last.turnId {
                    since = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM turn WHERE agentId = ? AND rowid > (SELECT rowid FROM turn WHERE id = ?)
                        """, arguments: [agentId, turnId]) ?? 0
                } else {
                    since = try Turn.filter(Column("agentId") == agentId && Column("startedAt") > last.createdAt).fetchCount(db)
                }
                guard since >= Store.modeRequestTurnGap else {
                    throw WorkError.conflict("one mode request per item per \(Store.modeRequestTurnGap) turns; try again after \(Store.modeRequestTurnGap - since) more")
                }
            }
            if item.rungFloor >= Store.requestableFloor {
                return ModeRequestResult(kind: .alreadyThere,
                                         message: "\(item.key) is already at R\(item.rungFloor) or above; no change needed.")
            }
            let turn = try Turn.filter(Column("agentId") == agentId && Column("outcome") == TurnOutcome.inProgress.rawValue)
                .order(Column("startedAt").desc, Column.rowID.desc).fetchOne(db)
            var record = ModeRequestRecord(id: nil, companyId: companyId, itemId: item.id, agentId: agentId, requestId: rid.flatMap { $0.isEmpty ? nil : $0 },
                                           mode: m, turnId: turn?.id, createdActive: active, createdAt: now)
            try record.insert(db)
            try db.execute(sql: "UPDATE workItem SET rungFloor = ?, updatedAt = ? WHERE id = ?",
                           arguments: [Store.requestableFloor, now, item.id])
            try recordItemEvent(db: db, item: item, actor: agentId, kind: .modeEscalated,
                                text: "@\(agent.name) asked for Deep mode (R2) from the next turn: \(why)", now: now)
            return ModeRequestResult(kind: .raised,
                                     message: "Mode raised to Deep (R2) for \(item.key); it applies from your next turn, not this one.")
        }
    }

    public func modeRequests(itemId: String) throws -> [ModeRequestRecord] {
        try writer.read { db in try ModeRequestRecord.filter(Column("itemId") == itemId).order(Column("id")).fetchAll(db) }
    }
}

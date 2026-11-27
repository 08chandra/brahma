import Foundation
import GRDB

/// One move of `main` by the merge queue, as `docs/measure/metrics.md` defines a landing (controller ruling R13): a `mergeBatch`
/// row with `landCommit` set and `step` at or after `landed`. Tasks 3, 4 and 6 and `linkItem` read landings only through here.
public struct Landing: Equatable, Sendable {
    public var batchId: String
    /// The batch's number (`B-<n>`).
    public var number: Int
    /// The commit `main` moved to.
    public var landCommit: String
    /// `main` when the batch was built on it (`mergeBatch.base`).
    public var baseCommit: String?
    /// The landing time: `mergeBatch.finishedAt`, else `updatedAt` (a batch landed but not yet at `done`).
    public var finishedAt: Date
    /// The items that landed, in `landedIds` order.
    public var items: [LandedItem]
}

/// An item that landed in a batch: `mergeRequest.itemId` for one id of `mergeBatch.landedIds` (request ids, never item ids).
public struct LandedItem: Equatable, Sendable {
    public var itemId: String
    public var key: String
    public var requestId: String
    /// The commit that carries the item: `mergeBatch.candidates[requestId]` (= `mergeRequest.mergedCommit`).
    public var mergedCommit: String?
    /// `mergeRequest.finishedAt` (stamped when the landing is recorded), else the landing's time.
    public var landedAt: Date
}

extension Store {
    /// The steps at or after `landed`: `main` has moved. `landCommit` is written one step earlier (`checked`), before it moves.
    static let landedSteps: [MergeStep] = MergeStep.allCases.filter { $0.order >= MergeStep.landed.order }

    /// The company's landings whose landing time falls in the window, in batch order.
    public func landings(companyId: String, in window: MeasureWindow) throws -> [Landing] {
        try writer.read { db in try Self.landings(db, companyId: companyId, in: window) }
    }

    /// True when `itemId` is a landed item of one of the company's landings.
    public func hasLanded(companyId: String, itemId: String) throws -> Bool {
        try writer.read { db in try Self.hasLanded(db, companyId: companyId, itemId: itemId) }
    }

    static func hasLanded(_ db: Database, companyId: String, itemId: String) throws -> Bool {
        try landings(db, companyId: companyId, in: nil).contains { landing in landing.items.contains { $0.itemId == itemId } }
    }

    /// `window` nil: every landing of the company.
    static func landings(_ db: Database, companyId: String, in window: MeasureWindow?) throws -> [Landing] {
        let steps = landedSteps.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        var sql = "SELECT * FROM mergeBatch WHERE companyId = ? AND landCommit IS NOT NULL AND step IN (\(steps))"
        var arguments: StatementArguments = [companyId]
        if let window {
            sql += " AND COALESCE(finishedAt, updatedAt) >= ? AND COALESCE(finishedAt, updatedAt) < ?"
            arguments += [window.since, window.until]
        }
        sql += " ORDER BY number"
        let batches = try MergeBatch.fetchAll(db, sql: sql, arguments: arguments)
        let requestIds = Array(Set(batches.flatMap(\.landedIds)))
        var requests: [String: MergeRequest] = [:]
        var keys: [String: String] = [:]
        // Chunked: SQLite's bound-parameter limit is 999 on older builds.
        for chunk in stride(from: 0, to: requestIds.count, by: 500).map({ Array(requestIds[$0..<min($0 + 500, requestIds.count)]) }) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            let rows = try MergeRequest.fetchAll(db, sql: "SELECT * FROM mergeRequest WHERE companyId = ? AND id IN (\(marks))",
                                                 arguments: StatementArguments([companyId]) + StatementArguments(chunk))
            for r in rows { requests[r.id] = r }
            let itemIds = rows.map(\.itemId)
            guard !itemIds.isEmpty else { continue }
            let itemMarks = itemIds.map { _ in "?" }.joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: "SELECT id, key FROM workItem WHERE companyId = ? AND id IN (\(itemMarks))",
                                        arguments: StatementArguments([companyId]) + StatementArguments(itemIds)) {
                keys[row["id"]] = row["key"]
            }
        }
        return batches.compactMap { b -> Landing? in
            guard let landCommit = b.landCommit else { return nil }
            let finishedAt = b.finishedAt ?? b.updatedAt
            let items = b.landedIds.compactMap { requestId -> LandedItem? in
                // A landed request id with no request row (or an item row gone) is not an item: it is left out, never guessed.
                guard let r = requests[requestId], let key = keys[r.itemId] else { return nil }
                return LandedItem(itemId: r.itemId, key: key, requestId: requestId, mergedCommit: b.candidates[requestId] ?? r.mergedCommit,
                                  landedAt: r.finishedAt ?? finishedAt)
            }
            return Landing(batchId: b.id, number: b.number, landCommit: landCommit, baseCommit: b.base, finishedAt: finishedAt, items: items)
        }
    }
}

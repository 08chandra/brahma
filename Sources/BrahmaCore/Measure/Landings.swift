import Foundation
import GRDB

/// One move of `main` by the merge queue, as `docs/measure/metrics.md` defines a landing (controller rulings R13, R24): a
/// `mergeBatch` row with `landCommit` set, `step` at or after `landed`, and at least one landed item — a `landedIds` request that is
/// `merged` with `batchId` = the batch. `landCommit`/`landedIds` are written at `checked`, before `main` moves, and the abort paths
/// after `checked` (stopped, main moved, blocked, off main, a git error, recovery abandoning the batch) finish the batch to `done`
/// with both still set and requeue its requests; such a batch has no merged request of its own and is not a landing. Tasks 3, 4
/// and 6 and `linkItem` read landings only through here.
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
    /// The items that landed, in `landedIds` order; never empty.
    public var items: [LandedItem]
}

/// An item that landed in a batch: `mergeRequest.itemId` for one id of `mergeBatch.landedIds` (request ids, never item ids) whose
/// request is `merged` with `batchId` = that batch (ruling R24). A request requeued from an abandoned batch keeps its id in that
/// batch's `landedIds`; it lands, once, in the batch that merged it.
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

    /// True when `itemId` is a landed item of one of the company's landings (ruling R24: its request merged by that batch).
    public func hasLanded(companyId: String, itemId: String) throws -> Bool {
        try writer.read { db in try Self.hasLanded(db, companyId: companyId, itemId: itemId) }
    }

    static func hasLanded(_ db: Database, companyId: String, itemId: String) throws -> Bool {
        try landings(db, companyId: companyId, in: nil).contains { landing in landing.items.contains { $0.itemId == itemId } }
    }

    /// `window` nil: every landing of the company. Callers that read other tables for the same landings use this inside their own
    /// read, so the landings and the rows they join come from one snapshot.
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
                // Ruling R24: only a request this batch merged. A request requeued from it (status back to `queued`, or merged
                // later by another batch) is not its item. A landed request id with no request row (or an item row gone) is left
                // out, never guessed.
                guard let r = requests[requestId], r.status == .merged, r.batchId == b.id, let key = keys[r.itemId] else { return nil }
                return LandedItem(itemId: r.itemId, key: key, requestId: requestId, mergedCommit: b.candidates[requestId] ?? r.mergedCommit,
                                  landedAt: r.finishedAt ?? finishedAt)
            }
            // A batch with no request it merged never moved `main`: not a landing.
            guard !items.isEmpty else { return nil }
            return Landing(batchId: b.id, number: b.number, landCommit: landCommit, baseCommit: b.base, finishedAt: finishedAt, items: items)
        }
    }
}

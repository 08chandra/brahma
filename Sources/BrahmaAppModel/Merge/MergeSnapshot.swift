import Foundation
import BrahmaCore

/// The selected company's merge queue (Plan 4a Task 8b), read off-main with the snapshot: the open requests in queue order, the
/// newest closed ones, the owner's settings, `main`, the hold and the batch the engine is still finishing from its journal.
public struct MergeSnapshot: Equatable, Sendable {
    /// Queued, running and landing, oldest first (the queue's order).
    public var open: [MergeRequest]
    /// Merged, bounced, failed and cancelled, newest first, at most `recentShown`.
    public var recent: [MergeRequest]
    public var settings: MergeSettings
    public var mainCommit: String?
    /// `Company.mergeHold`: why the queue is not taking batches, engine-written.
    public var hold: String?
    public var unfinishedBatch: MergeBatch?

    public static let recentShown = 20
    /// How many requests are read for the history (newest first after the read).
    static let readLimit = 10_000

    public static let empty = MergeSnapshot(open: [], recent: [], settings: MergeSettings(), mainCommit: nil, hold: nil, unfinishedBatch: nil)

    public init(open: [MergeRequest], recent: [MergeRequest], settings: MergeSettings, mainCommit: String?, hold: String?,
                unfinishedBatch: MergeBatch?) {
        self.open = open; self.recent = recent; self.settings = settings; self.mainCommit = mainCommit; self.hold = hold
        self.unfinishedBatch = unfinishedBatch
    }

    public static func load(store: Store, companyId: String) throws -> MergeSnapshot {
        guard let company = try store.company(id: companyId) else { return .empty }
        var m = MergeSnapshot.empty
        let all = try store.mergeRequests(companyId: companyId, limit: readLimit)
        m.open = all.filter { $0.status.isOpen }
        m.recent = Array(all.filter { !$0.status.isOpen }.reversed().prefix(recentShown))
        m.settings = MergeSettings(mainCheck: company.mainCheck, batchSize: company.mergeBatchSize, strategy: company.mergeStrategy)
        m.mainCommit = company.mainCommit
        m.hold = company.mergeHold
        m.unfinishedBatch = try store.openMergeBatches(companyId: companyId).first
        return m
    }
}

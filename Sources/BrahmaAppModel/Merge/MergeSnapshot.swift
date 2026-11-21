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
    /// The open set is small by design (one request per approved item); this only bounds a runaway read.
    static let openLimit = 1000

    public static let empty = MergeSnapshot(open: [], recent: [], settings: MergeSettings(), mainCommit: nil, hold: nil, unfinishedBatch: nil)

    public init(open: [MergeRequest], recent: [MergeRequest], settings: MergeSettings, mainCommit: String?, hold: String?,
                unfinishedBatch: MergeBatch?) {
        self.open = open; self.recent = recent; self.settings = settings; self.mainCommit = mainCommit; self.hold = hold
        self.unfinishedBatch = unfinishedBatch
    }

    public static func load(store: Store, companyId: String) throws -> MergeSnapshot {
        guard let company = try store.company(id: companyId) else { return .empty }
        var m = MergeSnapshot.empty
        // Two bounded reads: the open set in queue order (never dependent on the history window), and the newest closed ones.
        m.open = try store.mergeRequests(companyId: companyId, statuses: MergeRequestStatus.allCases.filter(\.isOpen), limit: openLimit)
        m.recent = try store.recentMergeRequests(companyId: companyId, limit: recentShown)
        m.settings = MergeSettings(mainCheck: company.mainCheck, batchSize: company.mergeBatchSize, strategy: company.mergeStrategy)
        m.mainCommit = company.mainCommit
        m.hold = company.mergeHold
        m.unfinishedBatch = try store.openMergeBatches(companyId: companyId).first
        return m
    }
}

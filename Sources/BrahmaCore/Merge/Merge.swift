import Foundation
import GRDB

/// How the queue lands a candidate on `main` (Plan 4a): both rebase the item's commits onto `main` first.
public enum MergeStrategy: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case ff, merge

    public var title: String {
        switch self {
        case .ff: "Rebase + fast-forward"
        case .merge: "Rebase + merge commit"
        }
    }
}

/// A company's merge settings, as the queue reads them.
public struct MergeSettings: Equatable, Sendable {
    /// The check run on every candidate besides the item's own pinned check; nil: none.
    public var mainCheck: CheckSpec?
    public var batchSize: Int
    public var strategy: MergeStrategy
    public static let batchRange = 1...8
    public static let defaultBatchSize = 1

    public init(mainCheck: CheckSpec? = nil, batchSize: Int = MergeSettings.defaultBatchSize, strategy: MergeStrategy = .ff) {
        self.mainCheck = mainCheck; self.batchSize = batchSize; self.strategy = strategy
    }
}

public enum MergeRequestStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case queued, running, landing, merged, bounced, failed, cancelled

    public var title: String {
        switch self {
        case .queued: "Queued"
        case .running: "Merging"
        case .landing: "Landing"
        case .merged: "Merged"
        case .bounced: "Bounced"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    /// Still on its way into `main`: queued, being checked or being landed.
    public var isOpen: Bool { self == .queued || self == .running || self == .landing }

    /// The statuses `isOpen` holds for, as raw values (SQL).
    static let openRaw: [String] = allCases.filter(\.isOpen).map(\.rawValue)
}

/// Why a request did not land.
public enum MergeFailure: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case conflict, itemCheckFailed, mainCheckFailed, secretFound, snapshotTampered, engineError, mainMoved
}

/// One approved item's turn in the merge queue. Written only by the engine (`Store.enqueueApproved` and the engine writes in
/// `Store+MergeQueue`); never reachable from `CompanyTools`.
public struct MergeRequest: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mergeRequest"

    public var id: String
    public var companyId: String
    public var itemId: String
    /// Per company, in enqueue order; `ref` is `M-<number>`.
    public var number: Int
    public var status: MergeRequestStatus
    /// The item's verified commit when it was approved: what the request is pinned to.
    public var headCommit: String
    public var checkRevision: Int? = nil
    public var baseCommit: String? = nil
    public var candidateCommit: String? = nil
    public var mergedCommit: String? = nil
    public var batchId: String? = nil
    public var failure: MergeFailure? = nil
    /// An engine-written reason (never agent output).
    public var detail: String? = nil
    /// Conflicting file names, JSON in the column (agent-controlled text: quote before showing it).
    public var conflictFiles: [String] = []
    public var outputTail: String? = nil
    public var outputPath: String? = nil
    public var attempts: Int = 0
    public var requeues: Int = 0
    public var inconclusive: Int = 0
    public var retryRequestedAt: Date? = nil
    public var enqueuedAt: Date
    public var startedAt: Date? = nil
    public var finishedAt: Date? = nil

    public var ref: String { "M-\(number)" }

    public init(id: String = UUID().uuidString, companyId: String, itemId: String, number: Int, status: MergeRequestStatus = .queued,
                headCommit: String, checkRevision: Int? = nil, enqueuedAt: Date) {
        self.id = id; self.companyId = companyId; self.itemId = itemId; self.number = number; self.status = status
        self.headCommit = headCommit; self.checkRevision = checkRevision; self.enqueuedAt = enqueuedAt
    }

    // `conflictFiles` is a JSON array in one TEXT column.
    public init(row: Row) throws {
        id = row["id"]; companyId = row["companyId"]; itemId = row["itemId"]; number = row["number"]; status = row["status"]
        headCommit = row["headCommit"]; checkRevision = row["checkRevision"]; baseCommit = row["baseCommit"]
        candidateCommit = row["candidateCommit"]; mergedCommit = row["mergedCommit"]; batchId = row["batchId"]
        failure = row["failure"]; detail = row["detail"]
        let json: String = row["conflictFiles"] ?? "[]"
        conflictFiles = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        outputTail = row["outputTail"]; outputPath = row["outputPath"]
        attempts = row["attempts"]; requeues = row["requeues"]; inconclusive = row["inconclusive"]
        retryRequestedAt = row["retryRequestedAt"]; enqueuedAt = row["enqueuedAt"]; startedAt = row["startedAt"]
        finishedAt = row["finishedAt"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id; container["companyId"] = companyId; container["itemId"] = itemId; container["number"] = number
        container["status"] = status; container["headCommit"] = headCommit; container["checkRevision"] = checkRevision
        container["baseCommit"] = baseCommit; container["candidateCommit"] = candidateCommit
        container["mergedCommit"] = mergedCommit; container["batchId"] = batchId; container["failure"] = failure
        container["detail"] = detail
        container["conflictFiles"] = String(decoding: (try? JSONEncoder().encode(conflictFiles)) ?? Data("[]".utf8), as: UTF8.self)
        container["outputTail"] = outputTail; container["outputPath"] = outputPath
        container["attempts"] = attempts; container["requeues"] = requeues; container["inconclusive"] = inconclusive
        container["retryRequestedAt"] = retryRequestedAt; container["enqueuedAt"] = enqueuedAt
        container["startedAt"] = startedAt; container["finishedAt"] = finishedAt
    }
}

/// One check execution of the merge queue: a candidate's pinned item check, the company's main check, or the main check at
/// the base (`mainAtBase`, to tell a red main from a red candidate).
public struct MergeRun: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mergeRun"

    public enum Kind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible { case main, item, mainAtBase }

    public var id: String
    public var companyId: String
    public var batchId: String? = nil
    public var requestId: String? = nil
    /// How many of the batch's requests (in order) the candidate carries.
    public var prefix: Int? = nil
    public var candidateCommit: String? = nil
    public var kind: Kind? = nil
    public var itemId: String? = nil
    public var command: String? = nil
    public var scriptHash: String? = nil
    public var status: VerificationStatus? = nil
    public var attempt: Int = 1
    public var flaky: Bool = false
    public var exitCode: Int? = nil
    public var outputPath: String? = nil
    public var outputTail: String? = nil
    public var startedAt: Date? = nil
    public var finishedAt: Date? = nil

    public init(id: String = UUID().uuidString, companyId: String, batchId: String? = nil, requestId: String? = nil,
                prefix: Int? = nil, candidateCommit: String? = nil, kind: Kind? = nil, itemId: String? = nil,
                command: String? = nil, scriptHash: String? = nil, status: VerificationStatus? = nil, attempt: Int = 1,
                flaky: Bool = false, exitCode: Int? = nil, outputPath: String? = nil, outputTail: String? = nil,
                startedAt: Date? = nil, finishedAt: Date? = nil) {
        self.id = id; self.companyId = companyId; self.batchId = batchId; self.requestId = requestId; self.prefix = prefix
        self.candidateCommit = candidateCommit; self.kind = kind; self.itemId = itemId; self.command = command
        self.scriptHash = scriptHash; self.status = status; self.attempt = attempt; self.flaky = flaky; self.exitCode = exitCode
        self.outputPath = outputPath; self.outputTail = outputTail; self.startedAt = startedAt; self.finishedAt = finishedAt
    }
}

/// What the orientation shows an agent about its item's merge: the item's latest request and, while it waits, its place.
public struct MergeOrientation: Equatable, Sendable {
    public var request: MergeRequest
    /// 1 = next; nil unless the request is queued.
    public var position: Int?

    /// Conflict files shown in the conflict brief of an orientation (3a's brief keeps its own list).
    public static let maxConflictFiles = 20

    public static func load(store: Store, item: WorkItem) throws -> MergeOrientation? {
        guard let request = try store.latestMergeRequest(itemId: item.id) else { return nil }
        // A request that landed or was withdrawn is history once the item is not waiting on it any more.
        if request.status == .merged || request.status == .cancelled { return nil }
        let position = request.status == .queued ? try store.mergePosition(of: request) : nil
        return MergeOrientation(request: request, position: position)
    }
}

import Foundation
import GRDB

/// Why a work operation was refused. The message is shown to the agent or the owner.
public enum WorkError: Error, Equatable, Sendable {
    case notFound(String)
    case forbidden(String)
    case invalid(String)
    case conflict(String)

    public var message: String {
        switch self {
        case .notFound(let m), .forbidden(let m), .invalid(let m), .conflict(let m): m
        }
    }
}

/// A pack-defined item type id (`ItemTypeDef.id`). The five software types are constants; other packs define their own.
public struct WorkItemType: RawRepresentable, Hashable, Codable, Sendable, DatabaseValueConvertible, ExpressibleByStringLiteral,
                            CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public static let epic = WorkItemType("epic")
    public static let story = WorkItemType("story")
    public static let task = WorkItemType("task")
    public static let bug = WorkItemType("bug")
    public static let spike = WorkItemType("spike")
}

/// Exactly these six statuses; `inReview` and `done` are written only by the engine.
public enum WorkItemStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case backlog, ready, inProgress, inReview, done, blocked

    public var title: String {
        switch self {
        case .backlog: "Backlog"
        case .ready: "Ready"
        case .inProgress: "In progress"
        case .inReview: "In review"
        case .done: "Done"
        case .blocked: "Blocked"
        }
    }
}

public enum EffortTier: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case s, m, l

    public var label: String { rawValue.uppercased() }
}

/// How an item's work is judged: a shell command run by the engine in a clean checkout.
public struct CheckSpec: Codable, Equatable, Sendable {
    public var command: String
    public var timeoutSeconds: Int = 600
    /// Repo-relative paths the check reads or covers (also the item's claimed paths).
    public var paths: [String] = []
    public var maxTimeout: Int = 3600

    public static let maxCommandLength = 2000
    public static let maxPaths = 50

    public init(command: String, timeoutSeconds: Int = 600, paths: [String] = [], maxTimeout: Int = 3600) {
        self.command = command; self.timeoutSeconds = timeoutSeconds; self.paths = paths; self.maxTimeout = maxTimeout
    }

    /// A list of repo-relative paths or globs: at most `maxPaths`, none empty, absolute or climbing out with "..".
    static func validatePaths(_ paths: [String], what: String, max limit: Int = CheckSpec.maxPaths) throws {
        if paths.count > limit {
            let subject = what == "check" ? "a check" : what == "hot" ? "the hot-path list" : "an item"
            throw WorkError.invalid("\(subject) lists at most \(limit) paths")
        }
        for p in paths {
            if p.isEmpty { throw WorkError.invalid("a \(what) path is empty") }
            if p.hasPrefix("/") { throw WorkError.invalid("\(what) path '\(p)' must be relative") }
            if p.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
                throw WorkError.invalid("\(what) path '\(p)' must not contain '..'")
            }
        }
    }

    public func validate() throws {
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw WorkError.invalid("the check command is empty") }
        if command.count > Self.maxCommandLength {
            throw WorkError.invalid("the check command is longer than \(Self.maxCommandLength) characters")
        }
        guard maxTimeout >= 1 else { throw WorkError.invalid("the check's maximum timeout must be at least 1 second") }
        let ceiling = min(maxTimeout, 3600)
        guard (1...ceiling).contains(timeoutSeconds) else {
            throw WorkError.invalid("the check timeout must be between 1 and \(ceiling) seconds")
        }
        try Self.validatePaths(paths, what: "check")
    }
}

public struct WorkItem: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workItem"

    public var id: String
    public var companyId: String
    public var number: Int
    /// `<PREFIX>-<n>`, unique per company.
    public var key: String
    public var type: WorkItemType
    public var title: String
    public var description: String = ""
    public var acceptanceCriteria: String = ""
    public var checkSpec: CheckSpec? = nil
    public var checkRevision: Int = 0
    public var reviewFlags: [String] = []
    public var status: WorkItemStatus
    public var blockedReason: String? = nil
    /// Company-active seconds when the item entered `blocked`.
    public var blockedSinceActive: Double? = nil
    /// 0 is most urgent; the default is 2.
    public var priority: Int = 2
    public var points: Int? = nil
    public var tier: EffortTier = .m
    /// Agent id, "owner" or "system".
    public var authorId: String
    /// The assignee's agent id (the item's "owner" in the data model).
    public var ownerId: String? = nil
    public var reviewerId: String? = nil
    public var team: String? = nil
    public var parentId: String? = nil
    public var sprintId: String? = nil
    public var linkedBranch: String? = nil
    public var notes: String? = nil
    public var everStarted: Bool = false
    public var firstClaimedAt: Date? = nil
    public var firstClaimedActive: Double? = nil
    public var verifiedRevision: Int? = nil
    public var verifiedCommit: String? = nil
    public var reviewRound: Int = 0
    public var reviewedRound: Int = 0
    public var submitSummary: String? = nil
    public var createdAt: Date
    public var updatedAt: Date
    public var doneAt: Date? = nil
    /// `auto` (default), `thorough` or `ultra`. Set only by the owner or a manager, never through a tool schema.
    public var intensity: WorkIntensity = .auto
    /// Raised only by engine escalation.
    public var rungFloor: Int = 0
    public var budgetBoostLE: Double = 0
    /// "<id>:<role kind>" of whoever set or confirmed the spec; nil until someone trusted did.
    public var specConfirmedBy: String? = nil
    /// Optional globs the item changes besides its check's `paths`; both together are its claimed paths (none = the whole repo).
    public var touchPaths: [String] = []
    /// Where the item's branch started (recorded by the engine at claim); weakening is measured against it, never the live `main`.
    public var baseCommit: String? = nil
    /// Review turns that ended without a decision (an escalation at `Store.maxReviewAttempts`).
    public var reviewAttempts: Int = 0
    /// Where an approved item is on its way into `main`. Written only by the engine.
    public var mergeState: MergeState = .none
    public var mergedCommit: String? = nil

    /// The id of whoever confirmed the spec, without the role.
    public var specConfirmerId: String? { specConfirmedBy?.split(separator: ":").first.map(String.init) }
}

/// An item's progress into `main` after review: approved and waiting, or re-verifying after a rebase.
public enum MergeState: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case none, pending, verifying
}

public enum WorkIntensity: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case auto, thorough, ultra
}

/// Fields for a new item. Everything but type and title is optional.
public struct WorkItemDraft: Sendable {
    public var type: WorkItemType
    public var title: String
    public var description: String = ""
    public var acceptanceCriteria: String = ""
    public var checkSpec: CheckSpec? = nil
    public var priority: Int = 2
    public var points: Int? = nil
    public var tier: EffortTier = .m
    public var ownerId: String? = nil
    public var reviewerId: String? = nil
    public var team: String? = nil
    public var parentId: String? = nil
    /// `backlog` (default) or `ready`.
    public var status: WorkItemStatus = .backlog
    public var intensity: WorkIntensity = .auto
    public var touchPaths: [String] = []

    public init(type: WorkItemType, title: String, description: String = "", acceptanceCriteria: String = "",
                checkSpec: CheckSpec? = nil, priority: Int = 2, points: Int? = nil, tier: EffortTier = .m,
                ownerId: String? = nil, reviewerId: String? = nil, team: String? = nil, parentId: String? = nil,
                status: WorkItemStatus = .backlog, intensity: WorkIntensity = .auto, touchPaths: [String] = []) {
        self.touchPaths = touchPaths
        self.type = type; self.title = title; self.description = description; self.acceptanceCriteria = acceptanceCriteria
        self.checkSpec = checkSpec; self.priority = priority; self.points = points; self.tier = tier; self.ownerId = ownerId
        self.reviewerId = reviewerId; self.team = team; self.parentId = parentId; self.status = status
        self.intensity = intensity
    }
}

/// Changes to an item. A plain optional is "leave alone"; a double optional (`.some(nil)`) clears the field.
public struct WorkItemPatch: Sendable {
    public var type: WorkItemType?
    public var title: String?
    public var description: String?
    public var acceptanceCriteria: String?
    public var checkSpec: CheckSpec??
    public var priority: Int?
    public var points: Int??
    public var tier: EffortTier?
    public var ownerId: String??
    public var reviewerId: String??
    public var team: String??
    public var parentId: String??
    public var status: WorkItemStatus?
    public var blockedReason: String?
    public var notes: String??
    public var linkedBranch: String??
    public var intensity: WorkIntensity?
    public var touchPaths: [String]?

    public init(type: WorkItemType? = nil, title: String? = nil, description: String? = nil, acceptanceCriteria: String? = nil,
                checkSpec: CheckSpec?? = nil, priority: Int? = nil, points: Int?? = nil, tier: EffortTier? = nil,
                ownerId: String?? = nil, reviewerId: String?? = nil, team: String?? = nil, parentId: String?? = nil,
                status: WorkItemStatus? = nil, blockedReason: String? = nil, notes: String?? = nil,
                linkedBranch: String?? = nil, intensity: WorkIntensity? = nil, touchPaths: [String]? = nil) {
        self.touchPaths = touchPaths
        self.type = type; self.title = title; self.description = description; self.acceptanceCriteria = acceptanceCriteria
        self.checkSpec = checkSpec; self.priority = priority; self.points = points; self.tier = tier; self.ownerId = ownerId
        self.reviewerId = reviewerId; self.team = team; self.parentId = parentId; self.status = status
        self.blockedReason = blockedReason; self.notes = notes; self.linkedBranch = linkedBranch; self.intensity = intensity
    }

    /// The edit categories this patch touches, for the policy check.
    var touchesSpec: Bool {
        type != nil || title != nil || description != nil || acceptanceCriteria != nil || checkSpec != nil || priority != nil
            || points != nil || tier != nil || reviewerId != nil || team != nil || parentId != nil || touchPaths != nil
    }
    var touchesOwner: Bool { ownerId != nil }
    var touchesNotes: Bool { notes != nil }
    var touchesBranch: Bool { linkedBranch != nil }
    var touchesStatus: Bool { status != nil || blockedReason != nil }
}

public struct WorkItemFilter: Sendable {
    public var statuses: Set<WorkItemStatus>? = nil
    public var ownerId: String? = nil
    public var reviewerId: String? = nil
    public var team: String? = nil
    public var type: WorkItemType? = nil
    public var parentId: String? = nil
    public var limit: Int = 5000

    public init(statuses: Set<WorkItemStatus>? = nil, ownerId: String? = nil, reviewerId: String? = nil, team: String? = nil,
                type: WorkItemType? = nil, parentId: String? = nil, limit: Int = 5000) {
        self.statuses = statuses; self.ownerId = ownerId; self.reviewerId = reviewerId; self.team = team; self.type = type
        self.parentId = parentId; self.limit = limit
    }
}

public enum WorkEventKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case created, statusChanged, edited, checkEdited, assigned, commented, dependencyAdded, dependencyDone
    case leaseClaimed, leaseReleased, leaseExpired, submitted, verificationPassed, verificationFailed
    case reviewApproved, changesRequested, merged, mergeConflict, handoffWritten, budgetExceeded, watchdog, aging
    case sprintChanged
    // Work modes (W3).
    case planWritten, planTurnWrote, modeEscalated, specConfirmed

    /// Events that count as an agent making progress (the watchdog resets on them).
    public static let progress: Set<WorkEventKind> = [
        .created, .statusChanged, .edited, .checkEdited, .assigned, .dependencyAdded, .leaseClaimed, .submitted,
        .reviewApproved, .changesRequested, .handoffWritten,
    ]

    /// Kinds that also appear in the company activity feed.
    static let feed: Set<WorkEventKind> = [
        .statusChanged, .submitted, .verificationPassed, .verificationFailed, .reviewApproved, .merged, .mergeConflict,
        .budgetExceeded, .watchdog, .leaseExpired, .aging,
    ]
}

public struct WorkItemEvent: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "workItemEvent"

    public var id: Int64?
    public var companyId: String
    public var itemId: String
    /// Agent id, "owner" or "system".
    public var actorId: String
    public var kind: WorkEventKind
    public var text: String
    public var createdAt: Date
    public var createdActive: Double

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// One agent's pending copy of an item event.
public struct WorkNotice: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "workNotice"

    public var id: Int64?
    public var agentId: String
    public var eventId: Int64
    public var deliveredTurnId: String?
    /// True only for events the recipient must act on (`WakePolicy.noticeWakes`); other notices ride along in a later turn.
    public var wakes: Bool = false
    /// Waking notices for managers and executives are debounced: not due before this company-active time.
    public var wakeAfterActive: Double? = nil

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

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
    /// The open ask this blocked item waits for, and the agent that linked it (`update_work_item` with `blockedOnAsk`, checked
    /// by the store). Set only with `blocked` and cleared whenever the item leaves it; owner-notice urgency counts it.
    public var blockedAskId: String? = nil
    public var blockedAskBy: String? = nil
    /// The status a human task (Plan L Task 9) blocked the item from; restored when the task is done or declined (an
    /// `inProgress` item only while its lease still exists, else `ready`). Meaningful only while `blockedAskId` is the task.
    public var statusBeforeBlock: WorkItemStatus? = nil
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
    /// Why the engine last stopped work on the item: `budget`, `no-progress`, `loop`, `failed-checks` or `timebox`.
    /// Cleared at the next claim.
    public var stopReason: String? = nil
    /// The current approval is the engine's risk-tiered auto-approval (tier S, small diff), not a reviewer's.
    public var autoApproved: Bool = false
    /// "<id>:<role kind>" of whoever last set the tier (at creation or by an edit), as `specConfirmedBy`. Risk-tiered review
    /// (9c) trusts a tier S only when the engine, the owner or a lead other than the item's implementers set it.
    public var tierSetBy: String? = nil
    /// "<id>:<role kind>" of whoever last set or edited the check: the item's last check editor.
    public var checkSpecSetBy: String? = nil
    /// Failed (non-inconclusive) check outcomes since the latest claim; the third takes the item back (loop guard, 14b).
    public var failedChecksSinceClaim: Int = 0
    /// The item branch's head as the engine last recorded it: at claim, at the end of each of the holder's turns and after an
    /// engine rebase (Task 4-wire). `submit_for_review` refuses a branch that is not a fast-forward of it.
    public var leaseHeadCommit: String? = nil
    /// The branch was found moved outside the holder's turns (its head at a turn's start was not `leaseHeadCommit`, or a turn
    /// rewrote it without submitting): submits are refused until a manager or the owner re-adopts it (`readoptBranch`).
    public var branchMoved: Bool = false
    /// Who held the lease when `branchMoved` was set (nil when nobody did): re-adopting is refused to that agent and needs
    /// its direct manager, an executive or the owner, whoever holds the item since. Cleared only with the flag.
    public var branchMovedHolderId: String? = nil
    /// A session that had read outside content created, edited or worked on the item (Task 10 fix round 2, S18): its readers
    /// are tainted, its review frames it as untrusted and it is never auto-approved. Sticky until the item is done.
    public var taintedOrigin: Bool = false
    /// Where an imported item came from (Plan X8, `"vX5-pr"`; see `ItemOrigin`): the issue's URL, unique per company, its
    /// author's login, whether that author was trusted when the snapshot was taken (false for an item created inside Brahma:
    /// "has an origin" is `originURL != nil`), and the issue number or identifier. Read them through `origin`.
    public var originURL: String? = nil
    public var originAuthor: String? = nil
    public var originTrusted: Bool = false
    public var originId: String? = nil

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
    /// An ask id the item is blocked on (with status `blocked`, or on an item that already is). The store checks it.
    public var blockedOnAsk: String?
    public var notes: String??
    public var linkedBranch: String??
    public var intensity: WorkIntensity?
    public var touchPaths: [String]?

    public init(type: WorkItemType? = nil, title: String? = nil, description: String? = nil, acceptanceCriteria: String? = nil,
                checkSpec: CheckSpec?? = nil, priority: Int? = nil, points: Int?? = nil, tier: EffortTier? = nil,
                ownerId: String?? = nil, reviewerId: String?? = nil, team: String?? = nil, parentId: String?? = nil,
                status: WorkItemStatus? = nil, blockedReason: String? = nil, blockedOnAsk: String? = nil, notes: String?? = nil,
                linkedBranch: String?? = nil, intensity: WorkIntensity? = nil, touchPaths: [String]? = nil) {
        self.blockedOnAsk = blockedOnAsk
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
    var touchesStatus: Bool { status != nil || blockedReason != nil || blockedOnAsk != nil }
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
    /// The item's branch has fallen far behind `main` (merge safety); an FYI, never waking.
    case branchBehind
    /// The engine could not merge an approved item `Store.maxMergeFailures` times in a row; it went back to its holder.
    case mergeFailed
    /// An approved item was put in the merge queue (Plan 4a): `queued to merge as M-<n> (position <p>)`.
    case mergeQueued
    // Work modes (W3).
    case planWritten, planTurnWrote, modeEscalated, specConfirmed
    // Human tasks (Plan L Task 9): the owner did or declined the task the item was blocked on. Both wake the assignee.
    case humanTaskDone, humanTaskDeclined
    /// Plan C Task C3b: a message named the item (an inline chip or an attachment); `sourceMessageId` is that message. An FYI,
    /// never waking; its text names no conversation (backlinks are per reader, `Store.backlinks`).
    case referenced
    /// Plan C Task C5b: the owner left an inline review comment (or a revert request) on the item's diff; the body is the
    /// `commented` event beside it. Wakes the lease holder (else the assignee).
    case reviewComment

    /// Events that count as an agent making progress (the watchdog resets on them).
    public static let progress: Set<WorkEventKind> = [
        .created, .statusChanged, .edited, .checkEdited, .assigned, .dependencyAdded, .leaseClaimed, .submitted,
        .reviewApproved, .changesRequested, .handoffWritten,
    ]

    /// Kinds that also appear in the company activity feed.
    static let feed: Set<WorkEventKind> = [
        .statusChanged, .submitted, .verificationPassed, .verificationFailed, .reviewApproved, .merged, .mergeConflict,
        .mergeFailed, .mergeQueued, .budgetExceeded, .watchdog, .leaseExpired, .aging, .humanTaskDone, .humanTaskDeclined,
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
    /// Written by a session that had read outside content (I2).
    public var taintedOrigin: Bool = false
    /// Plan C Task C3b: the message a `referenced` event came from.
    public var sourceMessageId: String? = nil

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

import Foundation
import BrahmaCore

/// What an item's last check run (and merge) looks like to the owner.
public enum CheckText {
    public static func label(status: VerificationStatus?, flaky: Bool = false, mergeState: MergeState = .none,
                             hasCheck: Bool = true) -> String {
        if mergeState != .none { return "Merging" }
        guard let status else { return hasCheck ? "No check run yet" : "No check" }
        switch status {
        case .queued: return "Check queued"
        case .running: return "Checking"
        case .passed: return flaky ? "Check passed (flaky)" : "Check passed"
        case .failed: return "Check failed"
        case .timedOut: return "Check timed out"
        case .inconclusive: return "Check inconclusive"
        case .error: return "Check error"
        }
    }
}

public enum IntensityText {
    public static func title(_ i: WorkIntensity) -> String {
        switch i {
        case .auto: "Auto"
        case .thorough: "Thorough"
        case .ultra: "Ultra"
        }
    }

    /// The note shown when an agent-authored tier L or P0/P1 item has not been confirmed by a manager or the owner.
    public static let unconfirmedNote = "unconfirmed: runs as M until a manager confirms"
}

/// One line of the backlog, board or a picker.
public struct ItemRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var key: String
    public var title: String
    public var type: String
    public var depth: Int
    public var status: WorkItemStatus
    public var statusTitle: String
    public var priority: Int
    public var priorityLabel: String
    public var tier: String
    public var assignee: String?
    public var reviewer: String?
    public var team: String?
    public var sprintName: String?
    public var checkLabel: String
    /// "Thorough" or "Ultra"; nil for Auto.
    public var intensityChip: String?
    public var intensity: WorkIntensity
    /// Nil when the spec was set or confirmed by someone the engine trusts; else the note that tier L / P0 run as M.
    public var unconfirmedNote: String?
    public var reviewFlags: [String]
    public var blockedReason: String?
    public var hasChildren: Bool
}

public enum ItemRows {
    /// Priority first (0 is most urgent), then creation order.
    private static func before(_ a: WorkItem, _ b: WorkItem) -> Bool {
        a.priority != b.priority ? a.priority < b.priority : a.number < b.number
    }

    public static func row(_ item: WorkItem, depth: Int = 0, handles: [String: String], run: VerificationRun?,
                           sprints: [String: String] = [:], hasChildren: Bool = false) -> ItemRow {
        var note: String?
        if item.specConfirmedBy == nil, item.tier == .l || item.priority < 2 { note = IntensityText.unconfirmedNote }
        return ItemRow(
            id: item.id, key: item.key, title: item.title, type: item.type.rawValue, depth: depth, status: item.status,
            statusTitle: item.status.title, priority: item.priority, priorityLabel: "P\(item.priority)", tier: item.tier.label,
            assignee: item.ownerId.map { handles[$0] ?? $0 }, reviewer: item.reviewerId.map { handles[$0] ?? $0 },
            team: item.team, sprintName: item.sprintId.flatMap { sprints[$0] },
            checkLabel: CheckText.label(status: run?.status, flaky: run?.flaky ?? false, mergeState: item.mergeState,
                                        hasCheck: item.checkSpec != nil),
            intensityChip: item.intensity == .auto ? nil : IntensityText.title(item.intensity)
                + (item.specConfirmedBy == nil ? " (unconfirmed)" : ""),
            intensity: item.intensity, unconfirmedNote: note, reviewFlags: item.reviewFlags, blockedReason: item.blockedReason,
            hasChildren: hasChildren)
    }

    /// The backlog as a tree: a parent, then its children, each level by priority and creation. Done items are left out unless
    /// asked for; an item whose parent is not shown becomes a root.
    public static func backlog(items: [WorkItem], handles: [String: String], runs: [String: VerificationRun] = [:],
                               sprints: [Sprint] = [], includeDone: Bool = false) -> [ItemRow] {
        let shown = items.filter { includeDone || $0.status != .done }
        let ids = Set(shown.map(\.id))
        var children: [String: [WorkItem]] = [:]
        var roots: [WorkItem] = []
        for item in shown {
            if let p = item.parentId, ids.contains(p), p != item.id { children[p, default: []].append(item) } else { roots.append(item) }
        }
        let names = Dictionary(sprints.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [ItemRow] = []
        var visited = Set<String>()
        func walk(_ item: WorkItem, _ depth: Int) {
            guard visited.insert(item.id).inserted else { return }
            let kids = (children[item.id] ?? []).sorted(by: before)
            out.append(row(item, depth: depth, handles: handles, run: runs[item.id], sprints: names, hasChildren: !kids.isEmpty))
            for k in kids { walk(k, depth + 1) }
        }
        for r in roots.sorted(by: before) { walk(r, 0) }
        return out
    }
}

public struct BoardColumn: Equatable, Identifiable, Sendable {
    public var status: WorkItemStatus
    public var title: String
    public var rows: [ItemRow]
    public var id: WorkItemStatus { status }
}

public enum BoardColumns {
    public static let order: [WorkItemStatus] = [.ready, .inProgress, .inReview, .blocked, .done]
    /// The Done column shows the newest this many.
    public static let doneLimit = 30

    /// One column per status in `order`. With `sprintId` only that sprint's items are shown.
    public static func make(items: [WorkItem], handles: [String: String], runs: [String: VerificationRun] = [:],
                            sprints: [Sprint] = [], sprintId: String? = nil) -> [BoardColumn] {
        let names = Dictionary(sprints.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let scoped = sprintId == nil ? items : items.filter { $0.sprintId == sprintId }
        return order.map { status in
            var picked = scoped.filter { $0.status == status }
            if status == .done {
                picked.sort { ($0.doneAt ?? $0.updatedAt) > ($1.doneAt ?? $1.updatedAt) }
                picked = Array(picked.prefix(doneLimit))
            } else {
                picked.sort { $0.priority != $1.priority ? $0.priority < $1.priority : $0.number < $1.number }
            }
            let rows = picked.map { ItemRows.row($0, handles: handles, run: runs[$0.id], sprints: names) }
            return BoardColumn(status: status, title: status.title, rows: rows)
        }
    }
}

public enum SprintText {
    public static func statusTitle(_ s: SprintStatus) -> String {
        switch s {
        case .pendingApproval: "awaiting approval"
        case .active: "active"
        case .review: "in review"
        case .closed: "closed"
        case .rejected: "rejected"
        }
    }

    /// "Sprint 3 · core · active · 5/9 done".
    public static func line(_ sprint: Sprint, items: [WorkItem]) -> String {
        let mine = items.filter { $0.sprintId == sprint.id }
        let done = mine.filter { $0.status == .done }.count
        return "\(sprint.name) · \(sprint.scopeLabel) · \(statusTitle(sprint.status)) · \(done)/\(mine.count) done"
    }
}

public enum HoldText {
    public static func banner(_ hold: EngineHold) -> String {
        switch hold.reason {
        case .network: "Offline — Brahma paused all agents and will resume when the connection returns."
        case .account: "Claude Code is logged out or the plan changed. Log in with claude in Terminal, then press Retry."
        case .cli: "Claude Code changed (\(hold.detail)). Brahma is checking it before scheduling again."
        case .disk: "Disk space is low (\(hold.detail)). Brahma resumes at 6 GB free."
        }
    }

    /// Only an account or CLI hold has something to retry.
    public static func canRetry(_ hold: EngineHold) -> Bool { hold.reason == .account || hold.reason == .cli }
}

public enum OrgErrorText {
    public static func message(_ error: Error) -> String {
        guard let e = error as? OrgError else {
            if let w = error as? WorkError { return w.message }
            if case StoreError.notFound = error { return "That agent no longer exists." }
            return "\(error)"
        }
        switch e {
        case .cycle: return "That would make a reporting loop: a manager cannot report to someone below them."
        case .tooManyReports(let manager, let count):
            return "@\(manager) would have \(count) direct reports; the limit is \(OrgGenerator.maxReports)."
        case .managerKilled: return "That manager has left the company."
        case .countOutOfRange: return "Agents must be 0 (add them later) or 5–500"
        case .unknownPack: return "That industry pack isn't installed."
        case .invalidPlan(let issues): return issues.map(\.message).joined(separator: "; ")
        }
    }
}

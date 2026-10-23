import Foundation
import BrahmaCore

/// The owner's new-item and edit-item form. Nothing here can set `inReview`, `done` or a check result.
public struct ItemForm: Equatable, Sendable {
    public var type: String = WorkItemType.task.rawValue
    public var title = ""
    public var description = ""
    public var acceptanceCriteria = ""
    /// The shell command the engine runs to judge the work; empty for none.
    public var checkCommand = ""
    public var checkTimeoutSeconds = 600
    /// One glob per line.
    public var touchPaths = ""
    public var priority = 2
    public var tier: EffortTier = .m
    public var intensity: WorkIntensity = .auto
    /// Assignee handle, without "@".
    public var assignee = ""
    public var reviewer = ""
    /// Parent item key such as "ACME-3".
    public var parentKey = ""
    public var startReady = false

    public static let priorities = Array(0...4)
    /// The store's limits, repeated so the form can refuse before writing.
    static let maxTitle = 200
    static let maxDescription = 20_000
    static let maxCriteria = 10_000

    public init() {}

    public init(item: WorkItem, handles: [String: String], parentKey: String = "") {
        type = item.type.rawValue; title = item.title; description = item.description
        acceptanceCriteria = item.acceptanceCriteria
        checkCommand = item.checkSpec?.command ?? ""; checkTimeoutSeconds = item.checkSpec?.timeoutSeconds ?? 600
        touchPaths = item.touchPaths.joined(separator: "\n")
        priority = item.priority; tier = item.tier; intensity = item.intensity
        assignee = item.ownerId.flatMap { handles[$0] } ?? ""
        reviewer = item.reviewerId.flatMap { handles[$0] } ?? ""
        self.parentKey = parentKey
        startReady = item.status == .ready
    }

    public var trimmedTitle: String {
        title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var touchPathList: [String] {
        touchPaths.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var checkSpec: CheckSpec? {
        let c = checkCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? nil : CheckSpec(command: c, timeoutSeconds: checkTimeoutSeconds, paths: [])
    }

    static func handle(_ raw: String) -> String? {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("@") { h.removeFirst() }
        return h.isEmpty ? nil : h.lowercased()
    }

    /// The first thing wrong with the form, or nil.
    public func validate(knownHandles: Set<String> = []) -> String? {
        if trimmedTitle.isEmpty { return "Title is required" }
        if trimmedTitle.count > Self.maxTitle { return "Title is longer than \(Self.maxTitle) characters" }
        if type.trimmingCharacters(in: .whitespaces).isEmpty { return "Type is required" }
        if !Self.priorities.contains(priority) { return "Priority must be between P0 (most urgent) and P4" }
        if description.count > Self.maxDescription { return "Description is longer than \(Self.maxDescription) characters" }
        if acceptanceCriteria.count > Self.maxCriteria {
            return "Acceptance criteria are longer than \(Self.maxCriteria) characters"
        }
        if !checkCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if checkCommand.count > CheckSpec.maxCommandLength {
                return "The check command is longer than \(CheckSpec.maxCommandLength) characters"
            }
            if !(1...3600).contains(checkTimeoutSeconds) { return "The check timeout must be between 1 and 3600 seconds" }
        }
        if let a = Self.handle(assignee), !knownHandles.isEmpty, !knownHandles.contains(a) { return "@\(a) isn't in this company" }
        if let r = Self.handle(reviewer), !knownHandles.isEmpty, !knownHandles.contains(r) { return "@\(r) isn't in this company" }
        if let a = Self.handle(assignee), a == Self.handle(reviewer) { return "The assignee can't also review the item" }
        for p in touchPathList {
            if p.hasPrefix("/") { return "Path \(p) must be relative to the repository" }
            if p.split(separator: "/").contains("..") { return "Path \(p) must not contain .." }
        }
        return nil
    }
}


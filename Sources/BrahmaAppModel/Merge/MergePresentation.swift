import Foundation
import BrahmaCore

/// A merge chip's color (Global Constraints "Color tokens"): queued `ready`; running/landing `running` (pulse); merged
/// `success`; bounced `danger`; failed and held `warning`; cancelled `text2`.
public enum MergeTone: Sendable {
    case ready, running, success, danger, warning, muted

    public init(_ status: MergeRequestStatus) {
        switch status {
        case .queued: self = .ready
        case .running, .landing: self = .running
        case .merged: self = .success
        case .bounced: self = .danger
        case .failed: self = .warning
        case .cancelled: self = .muted
        }
    }
}

public struct MergeRow: Equatable, Identifiable, Sendable {
    public var id: String
    /// `M-<n>`.
    public var ref: String
    public var itemKey: String
    /// "@handle" of the item's holder, or "—".
    public var holder: String
    public var statusTitle: String
    public var tone: MergeTone
    /// 1 = next to be claimed; nil unless queued.
    public var position: Int?
    /// One engine-composed line: where it stands, what landed, or why it failed or bounced (conflict names are agent-controlled:
    /// one line each, at most `MergeOrientation.maxConflictFiles`; `Text(verbatim:)`).
    public var detail: String
    public var when: String
    /// Only a `failed` request is retried from here; a bounce goes back to its holder.
    public var canRetry: Bool
    public var status: MergeRequestStatus
}

public enum MergeRows {
    /// Running and landing first, then the queue in order, then the history newest first.
    public static func make(_ m: MergeSnapshot, itemKeys: [String: String], holders: [String: String], handles: [String: String],
                            timeZone: TimeZone = .current) -> [MergeRow] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let queued = m.open.filter { $0.status == .queued }
        let active = m.open.filter { $0.status != .queued }
        func row(_ r: MergeRequest) -> MergeRow {
            let position = queued.firstIndex(where: { $0.id == r.id }).map { $0 + 1 }
            let holder = holders[r.itemId].map { "@" + (handles[$0] ?? $0) } ?? "—"
            return MergeRow(id: r.id, ref: r.ref, itemKey: itemKeys[r.itemId] ?? r.itemId, holder: holder,
                            statusTitle: r.status.title.uppercased(), tone: MergeTone(r.status), position: position,
                            detail: detail(r, position: position), when: f.string(from: r.finishedAt ?? r.startedAt ?? r.enqueuedAt),
                            canRetry: r.status == .failed, status: r.status)
        }
        return (active + queued + m.recent).map(row)
    }

    static func detail(_ r: MergeRequest, position: Int?) -> String {
        switch r.status {
        case .queued: return position.map { ordinal($0) + " in queue" } ?? "queued"
        case .running: return "merging " + sha7(r.headCommit)
        case .landing: return "landing " + sha7(r.candidateCommit ?? r.headCommit)
        case .merged: return r.mergedCommit.map { "main at " + sha7($0) } ?? "merged"
        case .cancelled: return "cancelled"
        case .bounced, .failed:
            if r.failure == .conflict, !r.conflictFiles.isEmpty {
                let shown = r.conflictFiles.prefix(MergeOrientation.maxConflictFiles).map(oneLine)
                let more = r.conflictFiles.count - shown.count
                return "conflicts in " + shown.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
            }
            return r.detail.map(oneLine) ?? r.failure.map(failureTitle) ?? r.status.title.lowercased()
        }
    }

    static func failureTitle(_ f: MergeFailure) -> String {
        switch f {
        case .conflict: "conflicts"
        case .itemCheckFailed: "item check failed"
        case .mainCheckFailed: "main check failed"
        case .secretFound: "secret found"
        case .snapshotTampered: "snapshot tampered"
        case .engineError: "engine error"
        case .mainMoved: "main moved"
        }
    }

    static func sha7(_ s: String) -> String { String(s.prefix(7)) }

    /// One line, control characters out, cut at `RendererCaps.maxLineBytes`.
    static func oneLine(_ s: String) -> String {
        let flat = String(s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
        return RendererCaps.truncateLine(Substring(flat))
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }
}

/// The queue panel's header strip: held (with the engine's reason and a Resume button), busy, or idle; `main`'s head and any
/// batch the engine is still finishing from its journal.
public struct MergeHeader: Equatable, Sendable {
    public var title: String
    public var tone: MergeTone
    public var detail: String
    public var canResume: Bool

    public init(title: String, tone: MergeTone, detail: String, canResume: Bool) {
        self.title = title; self.tone = tone; self.detail = detail; self.canResume = canResume
    }

    public static func make(_ m: MergeSnapshot) -> MergeHeader {
        if let hold = m.hold { return MergeHeader(title: "QUEUE HELD", tone: .warning, detail: hold, canResume: true) }
        var detail = m.mainCommit.map { "main at " + MergeRows.sha7($0) } ?? "no main yet"
        if let b = m.unfinishedBatch { detail = "batch #\(b.number) at \(b.step.rawValue) · " + detail }
        guard !m.open.isEmpty else { return MergeHeader(title: "QUEUE IDLE", tone: .muted, detail: detail, canResume: false) }
        return MergeHeader(title: "\(m.open.count) IN QUEUE", tone: .ready, detail: detail, canResume: false)
    }
}

/// The owner's merge settings sheet. Text fields hold what was typed; `validate` names the first rule broken and `settings` is
/// what `Store.setMergeSettings` is given (a blank command clears the main check).
public struct MergeSettingsForm: Equatable, Sendable {
    public var batchSize: String
    public var strategy: MergeStrategy
    public var mainCheckCommand: String
    public var timeoutSeconds: String

    public static let batchSizeMessage = "Batch size must be 1–8"
    public static let timeoutMessage = "Timeout must be 1–3600 seconds"
    public static let timeoutRange = 1...3600
    public static let defaultTimeout = CheckSpec(command: "").timeoutSeconds

    public init(_ s: MergeSettings) {
        batchSize = String(s.batchSize)
        strategy = s.strategy
        mainCheckCommand = s.mainCheck?.command ?? ""
        timeoutSeconds = String(s.mainCheck?.timeoutSeconds ?? Self.defaultTimeout)
    }

    var command: String { mainCheckCommand.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func validate() -> String? {
        guard let n = Int(batchSize.trimmingCharacters(in: .whitespaces)), MergeSettings.batchRange.contains(n) else {
            return Self.batchSizeMessage
        }
        if !command.isEmpty {
            guard let t = Int(timeoutSeconds.trimmingCharacters(in: .whitespaces)), Self.timeoutRange.contains(t) else {
                return Self.timeoutMessage
            }
        }
        return nil
    }

    public var settings: MergeSettings {
        let batch = Int(batchSize.trimmingCharacters(in: .whitespaces)) ?? MergeSettings.defaultBatchSize
        let timeout = Int(timeoutSeconds.trimmingCharacters(in: .whitespaces)) ?? Self.defaultTimeout
        let check = command.isEmpty ? nil : CheckSpec(command: command, timeoutSeconds: timeout)
        return MergeSettings(mainCheck: check, batchSize: batch, strategy: strategy)
    }
}

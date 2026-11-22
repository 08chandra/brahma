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
    /// The item's title (agent-controlled: `Text(verbatim:)`), or "" when the item is gone.
    public var title: String
    /// "@handle" of the item's holder, or "—".
    public var holder: String
    public var statusTitle: String
    public var tone: MergeTone
    /// 1 = next to be claimed; nil unless queued.
    public var position: Int?
    /// One engine-composed line: where it stands, what landed, or why it failed or bounced (conflict names are agent-controlled:
    /// one line each, at most `MergeOrientation.maxConflictFiles`; `Text(verbatim:)`).
    public var detail: String
    /// The commit the row is about, sha7: what landed, else the candidate being landed, else the pinned verified head.
    public var commit: String
    /// When the request was queued (the QUEUED column), `yyyy-MM-dd HH:mm` in the owner's zone.
    public var when: String
    /// Only a `failed` request is retried from here; a bounce goes back to its holder.
    public var canRetry: Bool
    public var status: MergeRequestStatus
}

public enum MergeRows {
    /// Running and landing first, then the queue in order, then the history newest first.
    public static func make(_ m: MergeSnapshot, itemKeys: [String: String], itemTitles: [String: String] = [:], holders: [String: String],
                            handles: [String: String], timeZone: TimeZone = .current) -> [MergeRow] {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let queued = m.open.filter { $0.status == .queued }
        let active = m.open.filter { $0.status != .queued }
        func row(_ r: MergeRequest) -> MergeRow {
            let position = queued.firstIndex(where: { $0.id == r.id }).map { $0 + 1 }
            let holder = holders[r.itemId].map { "@" + (handles[$0] ?? $0) } ?? "—"
            return MergeRow(id: r.id, ref: r.ref, itemKey: itemKeys[r.itemId] ?? r.itemId, title: itemTitles[r.itemId].map(oneLine) ?? "",
                            holder: holder, statusTitle: r.status.title.uppercased(), tone: MergeTone(r.status), position: position,
                            detail: detail(r, position: position), commit: sha7(r.mergedCommit ?? r.candidateCommit ?? r.headCommit),
                            when: f.string(from: r.enqueuedAt), canRetry: r.status == .failed, status: r.status)
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
    /// One line: the hold's reason (engine-written) when held, then any unfinished batch, then `main`'s head.
    public var detail: String
    public var canResume: Bool
    /// `MAIN <sha7>`, or `MAIN —` before the first engine-accepted commit.
    public var main: String
    /// `BATCH <n>`: the owner's batch size.
    public var batch: String
    /// The strategy's title ("Rebase + fast-forward").
    public var strategy: String
    /// `MAIN CHECK <command>` (agent-controlled: `Text(verbatim:)`, one trimmed line), or `MAIN CHECK NONE`.
    public var mainCheck: String
    /// Whether a main check is set (the chip's weight; never read off the text, a command may end in "NONE").
    public var hasMainCheck: Bool
    /// `HELD: <reason>` while the queue is held (a `warning` chip with the Resume button).
    public var held: String?
    /// `BATCH AT <STEP>` while the engine is still finishing a batch from its journal (a `running` chip).
    public var unfinishedBatch: String?

    public init(title: String, tone: MergeTone, detail: String, canResume: Bool, main: String = "MAIN —", batch: String = "BATCH 1",
                strategy: String = MergeStrategy.ff.title, mainCheck: String = "MAIN CHECK NONE", hasMainCheck: Bool = false,
                held: String? = nil, unfinishedBatch: String? = nil) {
        self.title = title; self.tone = tone; self.detail = detail; self.canResume = canResume
        self.main = main; self.batch = batch; self.strategy = strategy; self.mainCheck = mainCheck; self.hasMainCheck = hasMainCheck
        self.held = held; self.unfinishedBatch = unfinishedBatch
    }

    public static func make(_ m: MergeSnapshot) -> MergeHeader {
        var detail = m.mainCommit.map { "main at " + MergeRows.sha7($0) } ?? "no main yet"
        if let b = m.unfinishedBatch { detail = "batch #\(b.number) at \(b.step.rawValue) · " + detail }
        var h = MergeHeader(title: "QUEUE IDLE", tone: .muted, detail: detail, canResume: false,
                            main: "MAIN " + (m.mainCommit.map(MergeRows.sha7) ?? "—"), batch: "BATCH \(m.settings.batchSize)",
                            strategy: m.settings.strategy.title,
                            mainCheck: "MAIN CHECK " + (m.settings.mainCheck.map { MergeRows.oneLine($0.command).trimmingCharacters(in: .whitespaces) } ?? "NONE"),
                            hasMainCheck: m.settings.mainCheck != nil,
                            unfinishedBatch: m.unfinishedBatch.map { "BATCH AT " + $0.step.rawValue.uppercased() })
        if let hold = m.hold {
            // Held: the reason first, and still `main` and any unfinished batch (they matter most now).
            h.title = "QUEUE HELD"; h.tone = .warning; h.detail = hold + " · " + detail; h.canResume = true; h.held = "HELD: " + hold
        } else if !m.open.isEmpty {
            h.title = "\(m.open.count) IN QUEUE"; h.tone = .ready
        }
        return h
    }
}

/// The item inspector's MERGE strip (Plan 4a Task 10): the item's branch against `main`, its pinned verified commit, its latest
/// merge request (any status: a merged item reads MERGED, which is what Done means) and, for a failed or bounced check, the
/// redacted tail the engine stored. A conflict shows the engine's conflict line only (3a's brief to the holder has the files).
public struct ItemMergeDetail: Equatable, Sendable {
    public var branch: BranchInfo?
    public var verifiedCommit: String?
    public var request: MergeRequest?
    /// 1 = next to be claimed; nil unless the request is queued.
    public var position: Int?

    public init(branch: BranchInfo? = nil, verifiedCommit: String? = nil, request: MergeRequest? = nil, position: Int? = nil) {
        self.branch = branch; self.verifiedCommit = verifiedCommit; self.request = request; self.position = position
    }

    /// Reads the store and (when the workspace is a repository) git: call it off the main actor.
    public static func load(store: Store, item: WorkItem, workspace: String) throws -> ItemMergeDetail {
        var d = ItemMergeDetail(verifiedCommit: item.verifiedCommit)
        if let request = try store.latestMergeRequest(itemId: item.id) {
            d.request = request
            d.position = request.status == .queued ? try store.mergePosition(of: request) : nil
        }
        let root = URL(fileURLWithPath: workspace, isDirectory: true)
        if !workspace.isEmpty, FileManager.default.fileExists(atPath: root.appending(path: ".git").path),
           item.everStarted || item.linkedBranch != nil {
            d.branch = try BranchInspector.info(git: GitWorkspace(root: root), key: item.key)
        }
        return d
    }

    // MARK: Presentation

    /// `item/ACME-3 @abc1234`, or `item/ACME-3 (gone)` once the branch is deleted (landed), or "—" before any work.
    public var branchLine: String {
        guard let b = branch else { return "—" }
        return b.branch + (b.head.map { " @" + MergeRows.sha7($0) } ?? " (gone)")
    }
    /// `2 / 0` (ahead / behind), or "—".
    public var aheadBehind: String { branch.flatMap { $0.head == nil ? nil : "\($0.ahead) / \($0.behind)" } ?? "—" }
    /// `3 files +10 −2`, or "—".
    public var diffLine: String {
        guard let b = branch, b.head != nil else { return "—" }
        return "\(b.diff.files) \(b.diff.files == 1 ? "file" : "files") +\(b.diff.insertions) −\(b.diff.deletions)"
    }
    public var verifiedLine: String { verifiedCommit.map(MergeRows.sha7) ?? "—" }
    /// The request's status chip label (`MERGED`), or nil when the item has never been queued.
    public var statusTitle: String? { request.map { $0.status.title.uppercased() } }
    public var tone: MergeTone? { request.map { MergeTone($0.status) } }
    /// Where it stands or what happened: `MergeRows.detail`'s line (`2nd in queue`, `main at abc1234`, `conflicts in a.swift`).
    public var mergeLine: String? { request.map { MergeRows.detail($0, position: position) } }
    /// The redacted output tail of a failed or bounced check; nil for a conflict (its files are on `mergeLine`).
    public var failureTail: String? {
        guard let r = request, r.status == .failed || r.status == .bounced, r.failure != .conflict,
              let tail = r.outputTail, !tail.isEmpty else { return nil }
        return tail
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

import Foundation
import Observation
import BrahmaCore

/// The owner's replay (Plan ML Task 9): an agent's day in the agent inspector (REPLAY) or an item's history in the item
/// inspector (HISTORY). The timeline is read on demand off the main actor and kept in memory only (ruling 5: nothing it reads
/// is stored). Agent text is shown with `Text(verbatim:)`; a transcript is sanitized line by line and cut to
/// `transcriptLineCap` lines.
@MainActor @Observable
public final class ReplayModel {
    public nonisolated static let transcriptLineCap = 2000

    public let companyId: String
    public private(set) var subject: ReplaySubject
    /// The owner's time zone: the day stepper and every time shown.
    public let timeZone: TimeZone
    /// Only lines of this kind; nil shows them all.
    public var kindFilter: ReplayKind?
    /// Every line of the subject, oldest first (at most `Replay.maxEntries`).
    public private(set) var allEntries: [ReplayEntry] = []
    public private(set) var isLoading = false
    public private(set) var loaded = false
    /// The last failure, verbatim.
    public var error: String?
    /// The open transcript pane: its turn, its sanitized text, and whether it was cut.
    public private(set) var transcript: String?
    public private(set) var transcriptTurnId: String?
    public private(set) var transcriptTruncated = false

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let paths: BrahmaPaths
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var generation = 0
    /// The newest load whose result is shown.
    @ObservationIgnored private var applied = 0
    @ObservationIgnored private var transcriptGeneration = 0

    public init(store: Store, paths: BrahmaPaths, companyId: String, subject: ReplaySubject, timeZone: TimeZone,
                clock: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.paths = paths
        self.companyId = companyId
        self.subject = subject
        self.timeZone = timeZone
        self.clock = clock
    }

    // MARK: Reads

    /// The lines shown (the kind filter applied).
    public var entries: [ReplayEntry] {
        guard let kindFilter else { return allEntries }
        return allEntries.filter { $0.kind == kindFilter }
    }

    /// The agent's day (`yyyy-MM-dd` in the owner's time zone); nil for an item's history.
    public var day: String? {
        if case .agentDay(_, let day) = subject { return day }
        return nil
    }

    /// The day stepper's ▶: never past today.
    public var canStepForward: Bool {
        guard let day else { return false }
        return day < Replay.dayString(clock(), tz: timeZone)
    }

    /// Whether the timeline was cut to the newest `Replay.maxEntries`.
    public var isCapped: Bool { allEntries.count >= Replay.maxEntries }

    /// `HH:mm:ss` for a day; `MM-dd HH:mm` for an item's history (it spans days).
    public func time(_ e: ReplayEntry) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = day == nil ? "MM-dd HH:mm" : "HH:mm:ss"
        return f.string(from: e.at)
    }

    // MARK: Actions

    /// Reads the subject's timeline again. Loads may overlap (the launch target starts one, Reload another): a result is
    /// shown only for the subject still shown, and never over a newer one.
    public func load() async {
        generation += 1
        let mine = generation
        let (store, companyId, subject, tz) = (self.store, self.companyId, self.subject, self.timeZone)
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        let result = await Task.detached { Result { try Replay.timeline(store: store, companyId: companyId, subject: subject, tz: tz) } }.value
        guard subject == self.subject, mine > applied else { return }
        applied = mine
        switch result {
        case .success(let lines):
            allEntries = lines
            error = nil
        case .failure(let failure):
            allEntries = []
            error = (failure as? WorkError)?.message ?? "Couldn't read the replay: \(failure)"
        }
        loaded = true
    }

    /// The day stepper (◀ ▶): `delta` calendar days in the owner's time zone; never past today.
    public func stepDay(by delta: Int) async {
        guard case .agentDay(let agentId, let day) = subject,
              let moved = Replay.day(day, adding: delta, tz: timeZone),
              moved <= Replay.dayString(clock(), tz: timeZone) || delta < 0 else { return }
        subject = .agentDay(agentId: agentId, day: moved)
        closeTranscript()
        await load()
    }

    /// Opens a turn's captured transcript in the pane: its records rendered, every line sanitized
    /// (`TerminalText.sanitize`), at most `transcriptLineCap` lines. Returns the text shown (empty when it can't be read; the
    /// reason is in `error`).
    @discardableResult
    public func openTranscript(turnId: String) async -> String {
        transcriptGeneration += 1
        let mine = transcriptGeneration
        let (store, paths, companyId) = (self.store, self.paths, self.companyId)
        do {
            let (text, cut) = try await Task.detached { () -> (String, Bool) in
                let raw = try TranscriptCapture.read(turnId: turnId, companyId: companyId, store: store, paths: paths)
                return Self.pane(raw)
            }.value
            guard mine == transcriptGeneration else { return text }
            transcript = text
            transcriptTurnId = turnId
            transcriptTruncated = cut
            return text
        } catch {
            guard mine == transcriptGeneration else { return "" }
            transcript = nil
            transcriptTurnId = nil
            transcriptTruncated = false
            self.error = (error as? WorkError)?.message ?? "Couldn't read the transcript: \(error)"
            return ""
        }
    }

    public func closeTranscript() {
        transcriptGeneration += 1
        transcript = nil
        transcriptTurnId = nil
        transcriptTruncated = false
    }

    /// The pane's text: each record rendered (a record that carries no conversation is left out), every line sanitized, cut
    /// to `transcriptLineCap` lines.
    nonisolated static func pane(_ raw: String) -> (String, Bool) {
        var lines: [String] = []
        var cut = false
        outer: for record in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let rendered = TranscriptCapture.renderRecord(String(record)) else { continue }
            for line in rendered.split(separator: "\n", omittingEmptySubsequences: false) {
                if lines.count == transcriptLineCap { cut = true; break outer }
                lines.append(TerminalText.sanitize(String(line)))
            }
        }
        return (lines.joined(separator: "\n"), cut)
    }
}

/// The ways into a replay: the agent inspector's REPLAY tab, the item inspector's HISTORY tab and the `replay:` launch
/// targets. Owner surfaces only.
extension AppModel {
    /// Opens the agent's day (`yyyy-MM-dd` in the owner's time zone; default today) and starts loading it.
    @discardableResult
    public func openReplay(agentId: String, day: String? = nil) -> ReplayModel? {
        let day = day ?? Replay.dayString(clock(), tz: ownerTimeZone)
        return openReplay(.agentDay(agentId: agentId, day: day))
    }

    /// Opens an item's history (by key, in the selected company) and starts loading it.
    @discardableResult
    public func openReplay(itemKey: String) -> ReplayModel? {
        guard let item = item(key: itemKey) else {
            errorMessage = "No item \(itemKey.uppercased())"
            return nil
        }
        return openReplay(.item(itemId: item.id))
    }

    private func openReplay(_ subject: ReplaySubject) -> ReplayModel? {
        guard let companyId = selectedCompanyId else { return nil }
        let model = ReplayModel(store: store, paths: paths, companyId: companyId, subject: subject, timeZone: ownerTimeZone,
                                clock: clock)
        replay = model
        Task { await model.load() }
        return model
    }

    public func closeReplay() { replay = nil }

    /// Whether the agent inspector shows REPLAY for `agentId`.
    public func isReplaying(agentId: String) -> Bool {
        if case .agentDay(let id, _)? = replay?.subject { return id == agentId }
        return false
    }

    /// Whether the item inspector shows HISTORY for `itemId`.
    public func isReplaying(itemId: String) -> Bool {
        if case .item(let id)? = replay?.subject { return id == itemId }
        return false
    }
}

import Foundation
import Observation
import BrahmaCore

/// Plan C Task C6b: the CHANGES tab (collab design §1.6, Codex-style live diffs). The board of every leased worktree, and for the
/// selected item its live diff in the chosen compare mode, streamed from C5b's `LiveChanges` while the tab or a live ref body is
/// visible (`start`/`stop`), re-parsed off the main actor on every yield with the scroll stop kept, with the owner's inline
/// comments placed as markers (`DiffAnchoring.relocate`) or counted as outdated per file.
///
/// Every string shown — paths, hunk headers, lines, summaries, titles, comment text — is the engine's gated final string
/// (`Store.finishChanges`, `changesBoard`, `diffComments`; Rulings 53–56); nothing is transformed after the gate. The stored values
/// come from the injected loader on every subscription and refresh; a loader that throws refuses (nothing is shown).
///
/// Fix round 1: files and comments are matched on the engine's identity (`ChangedFile.patchIndex`, the section's index in the
/// patch), never on the path text (I-1); a stream that ends is shown STALE and resubscribed with backoff, the generic refusal after
/// `maxRetries` (I-2); the board reloads on its own cadence (`ChangesLimits.idleInterval`), never on the app tick (I-3); the
/// header chips (TAINTED with a gated reason, LIVE/STALE, UNCOMMITTED, TRUNCATED, HIDDEN CHARACTERS) follow every yield (I-4,
/// M-3); nothing is read without the minted owner principal (M-1).
@MainActor @Observable public final class ChangesTabModel {
    /// Where the view mode is kept, per company: `brahma.changes.mode.<companyId>` (JSON, every access `try?`).
    public static let modeKeyPrefix = "brahma.changes.mode."
    /// `"The stored secrets can't be read, so no changes are shown."`
    public static let refusedText = "The stored secrets can't be read, so no changes are shown."
    /// Ruling C6b-2: the parse disagreed with the engine's sections; nothing of the diff is drawn.
    public nonisolated static let unverifiedText = "diff couldn't be verified"
    /// Stream ends in a row (no yield between them) before the model gives up with the generic refusal (with `backoff`, about 15 s
    /// of patience: a git call that timed out or was starved under load recovers; a refusal costs no git work per attempt).
    public static let maxRetries = 5
    /// The board's reload cadence while the model runs: the engine's idle cadence (one diff per worktree per 10 s, within the
    /// "≤ 1 recompute per 2 s per (item, compare)" cap).
    public static let boardInterval: Duration = ChangesLimits.idleInterval

    @ObservationIgnored let store: Store
    @ObservationIgnored let live: LiveChanges
    public let companyId: String
    /// Ruling C6-2(b) / M-1: nil in a process with no owner surface — the model then refuses every read.
    @ObservationIgnored let owner: OwnerPrincipal?
    @ObservationIgnored let knownValues: @Sendable () throws -> [(name: String, value: String)]
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let clock: @Sendable () -> Date

    /// Every leased worktree's live changes vs `main` (the engine's rows), and the same as the view draws them.
    public private(set) var board: [BoardRow] = []
    public private(set) var rows: [BoardRowView] = []
    /// Board reloads so far (tests: the cadence holds).
    public private(set) var boardLoads = 0
    public private(set) var selectedKey: String?
    public private(set) var compare: CompareMode = .main
    /// `base`, `r<n>`…, `head`, `worktree` of the selected item (the compare picker).
    public private(set) var revisions: [ItemRevision] = []
    public private(set) var snapshot: ChangesSnapshot?
    public private(set) var diff: DiffModel?
    /// The snapshot's files as the file list draws them (engine paths and summaries; `fileIndex` into `diff`).
    public private(set) var files: [ChangedFileRow] = []
    public private(set) var changeStops: [DiffStop] = []
    public private(set) var stopIndex: Int?
    /// The selected item's review comments (resolved ones included), and the unresolved ones of this compare placed on the
    /// diff; `outdated` counts, per path, those whose line is not in the diff any more.
    public private(set) var comments: [DiffComment] = []
    public private(set) var markers: [DiffAnchor: [DiffComment]] = [:]
    public private(set) var outdated: [String: Int] = [:]
    /// The diff was opened from a show answer (`params["at"]`) and has changed since the agent showed it.
    public var changedSinceShown = false
    /// Between `start()` and `stop()` (or the model giving up): the stream runs (or is being retried) for the selected item.
    public private(set) var isRunning = false
    /// The stream is open and what is shown is its latest yield; false once it ended (the view shows STALE) or before the first yield.
    public private(set) var isLive = false
    /// Stream ends since the last yield (the retry backoff grows with it).
    public private(set) var retryAttempt = 0
    /// The header chips of the shown diff, gated as final strings and rebuilt on every yield.
    public private(set) var chips: [RefChip] = []
    /// The engine's words when the board or the stream can't be read (never a value), or nil.
    public private(set) var error: String?

    private var modeStorage: DiffViewMode
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var boardTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var shownAt: String?
    /// The values the running subscription was gated with (the chips are gated with the same).
    @ObservationIgnored private var known: [(name: String, value: String)] = []

    public init(store: Store, live: LiveChanges, companyId: String, owner: OwnerPrincipal?,
                knownValues: @escaping @Sendable () throws -> [(name: String, value: String)],
                defaults: UserDefaults = .standard, clock: @escaping @Sendable () -> Date = { Store.now() }) {
        self.store = store; self.live = live; self.companyId = companyId; self.owner = owner; self.knownValues = knownValues
        self.defaults = defaults; self.clock = clock
        modeStorage = Self.loadMode(companyId: companyId, defaults: defaults)
    }

    // MARK: View mode

    /// Unified or split, saved per company as it changes.
    public var mode: DiffViewMode {
        get { modeStorage }
        set {
            modeStorage = newValue
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.modeKeyPrefix + companyId) }
        }
    }

    static func loadMode(companyId: String, defaults: UserDefaults) -> DiffViewMode {
        guard let data = defaults.data(forKey: modeKeyPrefix + companyId), let mode = try? JSONDecoder().decode(DiffViewMode.self, from: data) else {
            return .unified
        }
        return mode
    }

    // MARK: Selection

    /// Selects a board row (nil clears): the compare returns to `main`, what was shown is dropped, and the stream follows while
    /// running.
    public func select(_ key: String?) {
        guard key != selectedKey else { return }
        reset()
        selectedKey = key
        compare = .main
        shownAt = nil
        resubscribe()
        if isRunning, key != nil { Task { await refreshItem() } }
    }

    /// A live diff ref opened in the OPENED tab: that item in that compare; `shownAt` is the patch hash it was shown at (a show
    /// answer's `params["at"]`), against which `changedSinceShown` is set on every yield.
    public func show(key: String, compare: CompareMode, shownAt: String? = nil) {
        self.shownAt = shownAt
        guard key != selectedKey || compare != self.compare else {
            changedSinceShown = shownAt.flatMap { at in snapshot.map { at != $0.patchHash } } ?? false
            return
        }
        reset()
        selectedKey = key
        self.compare = compare
        resubscribe()
        if isRunning { Task { await refreshItem() } }
    }

    public func setCompare(_ m: CompareMode) {
        guard m != compare else { return }
        compare = m
        clearShown()
        resubscribe()
    }

    private func clearShown() {
        snapshot = nil
        diff = nil
        files = []
        changeStops = []
        stopIndex = nil
        markers = [:]
        outdated = [:]
        chips = []
        changedSinceShown = false
        isLive = false
        retryAttempt = 0
    }

    private func reset() {
        clearShown()
        revisions = []
        comments = []
        error = nil
    }

    // MARK: Navigation

    /// The stop the view scrolls to.
    public var currentStop: DiffStop? {
        guard let i = stopIndex, changeStops.indices.contains(i) else { return nil }
        return changeStops[i]
    }

    public func nextChange() { stopIndex = DiffStops.next(stopIndex, count: changeStops.count) }
    public func previousChange() { stopIndex = DiffStops.previous(stopIndex, count: changeStops.count) }

    // MARK: Anchors

    /// The anchor of the line at `index` of hunk `hunk` of `diff.files[fileIndex]` on `side` (`old`/`new`), with the ENGINE's
    /// display path (the snapshot's), the header as numbers only and the shown text: what a review draft and the engine's
    /// `addDiffComment` take. Nil when that line has no number on that side or the file is not the snapshot's.
    public func anchor(fileIndex: Int, hunk: Int, index: Int, side: String) -> DiffAnchor? {
        guard side == "old" || side == "new", let diff, let snapshot, diff.files.indices.contains(fileIndex), diff.files[fileIndex].hunks.indices.contains(hunk),
              diff.files[fileIndex].hunks[hunk].lines.indices.contains(index),
              let file = snapshot.files.first(where: { $0.patchIndex == fileIndex }) else { return nil }
        let h = diff.files[fileIndex].hunks[hunk]
        let line = h.lines[index]
        guard let number = side == "old" ? line.oldNo : line.newNo else { return nil }
        return DiffAnchor(path: file.path, side: side, line: number, hunkHeader: DiffAnchoring.headerRange(h.header) ?? h.header, lineText: line.text)
    }

    // MARK: The stream

    /// Subscribes to the selected item's live changes (`LiveChanges.watch`) and starts the board's reload loop. Called when the
    /// CHANGES tab or a live ref body becomes visible. Without an owner principal nothing is read (M-1).
    public func start() {
        guard !isRunning else { return }
        guard owner != nil else {
            error = OwnerPrincipal.refusal
            return
        }
        isRunning = true
        retryAttempt = 0
        resubscribe()
        boardTask?.cancel()
        boardTask = Task { [weak self] in
            // N-5 / R2-2: the model is held only inside the `do` scope, around its reload; the strong reference ends before the
            // sleep, and the weak one is re-checked after it (a dropped model ends the loop).
            while !Task.isCancelled {
                do {
                    guard let model = self, model.isRunning else { return }
                    await model.refreshBoard()
                }
                try? await Task.sleep(for: Self.boardInterval)
            }
        }
        if selectedKey != nil { Task { await refreshItem() } }
    }

    /// Cancels the stream, the retry and the board loop (the engine's loop stops once no observer is left). What was shown stays
    /// until the next start, marked not live.
    public func stop() {
        isRunning = false
        isLive = false
        generation += 1
        watchTask?.cancel()
        watchTask = nil
        retryTask?.cancel()
        retryTask = nil
        boardTask?.cancel()
        boardTask = nil
        if snapshot != nil { rebuildChips() }
    }

    private func resubscribe() {
        generation += 1
        watchTask?.cancel()
        watchTask = nil
        retryTask?.cancel()
        retryTask = nil
        guard isRunning, let key = selectedKey, owner != nil else { return }
        let gen = generation
        let (live, companyId, compare, loader) = (self.live, self.companyId, self.compare, self.knownValues)
        watchTask = Task { [weak self] in
            let known: [(name: String, value: String)]
            do {
                known = try await Task.detached { try loader() }.value
            } catch {
                // Ruling 53: without the stored values nothing is gated, so nothing is shown.
                self?.refuse(gen)
                return
            }
            self?.known = known
            let stream = await live.watch(companyId: companyId, key: key, compare: compare, reader: .owner, knownValues: known)
            for await snapshot in stream {
                if Task.isCancelled { break }
                // R2-3: decoded paths are gated as their final display strings with the same known values.
                let parsed = await Task.detached(priority: .userInitiated) {
                    DiffModel.parse(patch: snapshot.patch, gate: GlobalSearch.TextGate(knownValues: known))
                }.value
                guard let self, !Task.isCancelled else { break }
                self.apply(snapshot, parsed, gen: gen)
            }
            guard let self, !Task.isCancelled else { return }
            self.streamEnded(gen)
        }
    }

    private func refuse(_ gen: Int) {
        guard gen == generation else { return }
        error = Self.refusedText
    }

    /// I-2: the stream ended (access refused, the item or worktree gone, a git failure): what is shown is no longer live. Up to
    /// `maxRetries` resubscriptions with backoff; past that the generic refusal, and the model stops (a new `start()` tries again).
    private func streamEnded(_ gen: Int) {
        guard gen == generation else { return }
        isLive = false
        retryAttempt += 1
        if snapshot != nil { rebuildChips() }
        guard retryAttempt <= Self.maxRetries else {
            error = Store.refUnavailable
            isRunning = false
            watchTask = nil
            boardTask?.cancel()
            boardTask = nil
            return
        }
        let wait = Self.backoff(retryAttempt)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard let self, !Task.isCancelled, gen == self.generation, self.isRunning else { return }
            self.resubscribe()
        }
    }

    /// 500 ms, 1 s, 2 s, … (doubling; never over 30 s).
    public static func backoff(_ attempt: Int) -> Duration {
        let n = max(1, min(attempt, 7))
        return min(.milliseconds(500 << (n - 1)), .seconds(30))
    }

    /// A yield: the snapshot and its parse, the scroll stop kept on the same file when it still exists, the "changed since shown"
    /// flag, the chips and the markers.
    private func apply(_ snapshot: ChangesSnapshot, _ parsed: DiffModel, gen: Int) {
        guard gen == generation else { return }
        isLive = true
        retryAttempt = 0
        // Ruling C6b-2: the parse must agree with the engine's sections before anything of it is drawn.
        if let problem = Self.verify(parsed, against: snapshot) {
            self.snapshot = snapshot
            diff = nil
            files = []
            changeStops = []
            stopIndex = nil
            markers = [:]
            outdated = [:]
            changedSinceShown = shownAt.map { $0 != snapshot.patchHash } ?? false
            error = problem
            rebuildChips()
            return
        }
        let previous: (DiffStop, DiffModel)? = currentStop.flatMap { stop in diff.map { (stop, $0) } }
        self.snapshot = snapshot
        diff = parsed
        files = ChangesFiles.rows(snapshot, diff: parsed)
        changeStops = parsed.changeStops
        error = nil
        if let (stop, old) = previous {
            stopIndex = DiffStops.relocate(stop, from: old, in: parsed).flatMap { moved in changeStops.firstIndex(of: moved) }
        } else {
            stopIndex = nil
        }
        changedSinceShown = shownAt.map { $0 != snapshot.patchHash } ?? false
        rebuildChips()
        placeMarkers()
    }

    /// Ruling C6b-2: nil when `diff`'s sections are the engine's (`sectionPaths`: the same count, the same path at every index) and
    /// (R2-1) every hunk of every section has the engine's line counts and (N3-1) start lines (`sectionHunks`), else
    /// `unverifiedText`: a parse that reads any line or hunk header differently from the engine never has its markers or numbers drawn.
    public nonisolated static func verify(_ diff: DiffModel, against snapshot: ChangesSnapshot) -> String? {
        verify(diff, paths: snapshot.sectionPaths, hunks: snapshot.sectionHunks)
    }

    /// C7a fix round 1 (I-1): the same check against any engine identity (`ChangesPatch.identity` of a static diff or commit).
    public nonisolated static func verify(_ diff: DiffModel, paths: [String], hunks: [[HunkSpan]]) -> String? {
        guard diff.files.map(\.path) == paths, spans(diff) == hunks else { return unverifiedText }
        return nil
    }

    /// R2-1: the app parse's start lines (N3-1) and line counts per file and hunk, in the engine's `HunkSpan` terms.
    public nonisolated static func spans(_ diff: DiffModel) -> [[HunkSpan]] {
        diff.files.map { file in
            file.hunks.map { h in
                HunkSpan(oldStart: h.oldStart, newStart: h.newStart, old: h.lines.filter { $0.oldNo != nil }.count, new: h.lines.filter { $0.newNo != nil }.count,
                         shown: h.lines.filter { $0.oldNo != nil || $0.newNo != nil }.count)
            }
        }
    }

    // MARK: Chips

    private func rebuildChips() {
        guard let snapshot else { chips = []; return }
        chips = Self.chips(for: snapshot, diff: diff, live: isLive, gate: GlobalSearch.TextGate(knownValues: known))
    }

    /// The header chips of a shown diff (color tokens: UNCOMMITTED, TAINTED, TRUNCATED and HIDDEN CHARACTERS `warning`; LIVE
    /// `running`; STALE `text2`). The taint reason is gated as a final string (nil → the bare chip).
    public nonisolated static func chips(for snapshot: ChangesSnapshot, diff: DiffModel?, live: Bool, gate: GlobalSearch.TextGate) -> [RefChip] {
        var out: [RefChip] = []
        if snapshot.target == "worktree" { out.append(RefChip(text: "UNCOMMITTED", tone: .warn)) }
        out.append(live ? RefChip(text: "LIVE", tone: .busy) : RefChip(text: "STALE", tone: .idle))
        if snapshot.tainted {
            out.append(RefChip(text: gate.final("TAINTED · \(snapshot.taintReason ?? "outside content")", max: SafeTitle.max) ?? "TAINTED", tone: .warn))
        }
        if snapshot.truncated { out.append(RefChip(text: "TRUNCATED", tone: .warn)) }
        if diff?.hasHidden == true { out.append(RefChip(text: "HIDDEN CHARACTERS", tone: .warn)) }
        return out
    }

    // MARK: Board, revisions and comments

    /// Reloads the board and the selected item's revisions and comments now (an owner action: the tab opened, a review posted).
    public func refresh() async {
        await refreshBoard()
        await refreshItem()
    }

    /// Reloads the board (`Store.changesBoard`: one diff per leased worktree) off the main actor. On its own cadence while the
    /// model runs (`boardInterval`), never on the app tick (I-3).
    public func refreshBoard() async {
        guard owner != nil else { error = OwnerPrincipal.refusal; return }
        let (store, companyId, loader, now) = (self.store, self.companyId, self.knownValues, clock())
        let gen = generation
        do {
            let board = try await Task.detached { () -> [BoardRow] in
                let known = try loader()
                return try store.changesBoard(companyId: companyId, reader: .owner, knownValues: known, now: now)
            }.value
            boardLoads += 1
            self.board = board
            rows = BoardRows.make(board, now: now)
            if error == Self.refusedText { error = nil }
        } catch {
            // M-7: a failure of a stale load never overwrites the state of what is selected now.
            guard gen == generation else { return }
            self.error = (error as? WorkError)?.message ?? Self.refusedText
        }
    }

    /// Reloads the selected item's revisions and comments off the main actor (no git diff: engine records and `diffComments`).
    public func refreshItem() async {
        guard owner != nil else { error = OwnerPrincipal.refusal; return }
        guard let key = selectedKey else { return }
        let (store, companyId, loader) = (self.store, self.companyId, self.knownValues)
        let gen = generation
        do {
            let (revisions, comments) = try await Task.detached { () -> ([ItemRevision], [DiffComment]) in
                let known = try loader()
                let revisions = try store.itemRevisions(companyId: companyId, key: key)
                let comments = try store.diffComments(companyId: companyId, key: key, reader: .owner, knownValues: known)
                return (revisions, comments)
            }.value
            guard key == selectedKey else { return }
            self.revisions = revisions
            self.comments = comments
            placeMarkers()
        } catch {
            // M-7: the key may have changed meanwhile; only the current selection's error is shown.
            guard gen == generation, key == selectedKey else { return }
            self.error = (error as? WorkError)?.message ?? Self.refusedText
        }
    }

    /// The unresolved comments of this compare on the diff: each at the line `DiffAnchoring.relocate` finds for its text within
    /// the re-anchor window, in the section the engine's file identity names (`patchIndex`, never the path text: I-1), keyed by the
    /// anchor the view draws (the engine's display path, the header as numbers only); the rest count as outdated per path.
    private func placeMarkers() {
        guard let snapshot, let diff else {
            markers = [:]
            outdated = [:]
            return
        }
        let canonical = compare.ref(key: snapshot.key).canonical
        var placed: [DiffAnchor: [DiffComment]] = [:]
        var stale: [String: Int] = [:]
        for c in comments where c.resolvedAt == nil && c.compare == canonical {
            guard let file = snapshot.files.first(where: { $0.path == c.path }), let section = file.patchIndex, diff.files.indices.contains(section),
                  let line = DiffAnchoring.relocate(c, in: snapshot.patch, sectionIndex: section),
                  let anchor = Self.anchor(in: diff.files[section], path: file.path, side: c.side, line: line) else {
                stale[c.path, default: 0] += 1
                continue
            }
            placed[anchor, default: []].append(c)
        }
        markers = placed
        outdated = stale
    }

    /// The anchor of `line` on `side` of the parsed `file`, carrying the engine's display `path`; nil when that line is not shown.
    static func anchor(in file: DiffFile, path: String, side: String, line: Int) -> DiffAnchor? {
        for hunk in file.hunks {
            if let l = hunk.lines.first(where: { (side == "old" ? $0.oldNo : $0.newNo) == line }) {
                return DiffAnchor(path: path, side: side, line: line, hunkHeader: DiffAnchoring.headerRange(hunk.header) ?? hunk.header, lineText: l.text)
            }
        }
        return nil
    }
}

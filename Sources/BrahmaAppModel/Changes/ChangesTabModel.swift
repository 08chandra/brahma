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
@MainActor @Observable public final class ChangesTabModel {
    /// Where the view mode is kept, per company: `brahma.changes.mode.<companyId>` (JSON, every access `try?`).
    public static let modeKeyPrefix = "brahma.changes.mode."
    /// `"The stored secrets can't be read, so no changes are shown."`
    public static let refusedText = "The stored secrets can't be read, so no changes are shown."

    @ObservationIgnored let store: Store
    @ObservationIgnored let live: LiveChanges
    public let companyId: String
    @ObservationIgnored let knownValues: @Sendable () throws -> [(name: String, value: String)]
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let clock: @Sendable () -> Date

    /// Every leased worktree's live changes vs `main` (the engine's rows), and the same as the view draws them.
    public private(set) var board: [BoardRow] = []
    public private(set) var rows: [BoardRowView] = []
    public private(set) var selectedKey: String?
    public private(set) var compare: CompareMode = .main
    /// `base`, `r<n>`…, `head`, `worktree` of the selected item (the compare picker).
    public private(set) var revisions: [ItemRevision] = []
    public private(set) var snapshot: ChangesSnapshot?
    public private(set) var diff: DiffModel?
    public private(set) var changeStops: [DiffStop] = []
    public private(set) var stopIndex: Int?
    /// The selected item's review comments (resolved ones included), and the unresolved ones of this compare placed on the
    /// diff; `outdated` counts, per path, those whose line is not in the diff any more.
    public private(set) var comments: [DiffComment] = []
    public private(set) var markers: [DiffAnchor: [DiffComment]] = [:]
    public private(set) var outdated: [String: Int] = [:]
    /// The diff was opened from a show answer (`params["at"]`) and has changed since the agent showed it.
    public var changedSinceShown = false
    /// Between `start()` and `stop()`: the stream runs for the selected item.
    public private(set) var isRunning = false
    /// The engine's words when the board or the stream can't be read (never a value), or nil.
    public private(set) var error: String?

    private var modeStorage: DiffViewMode
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var shownAt: String?

    public init(store: Store, live: LiveChanges, companyId: String, knownValues: @escaping @Sendable () throws -> [(name: String, value: String)],
                defaults: UserDefaults = .standard, clock: @escaping @Sendable () -> Date = { Store.now() }) {
        self.store = store; self.live = live; self.companyId = companyId; self.knownValues = knownValues; self.defaults = defaults; self.clock = clock
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
        if isRunning, key != nil { Task { await refresh() } }
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
        if isRunning { Task { await refresh() } }
    }

    public func setCompare(_ m: CompareMode) {
        guard m != compare else { return }
        compare = m
        snapshot = nil
        diff = nil
        changeStops = []
        stopIndex = nil
        markers = [:]
        outdated = [:]
        changedSinceShown = false
        resubscribe()
    }

    private func reset() {
        snapshot = nil
        diff = nil
        changeStops = []
        stopIndex = nil
        revisions = []
        comments = []
        markers = [:]
        outdated = [:]
        changedSinceShown = false
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

    // MARK: The stream

    /// Subscribes to the selected item's live changes (`LiveChanges.watch`) and loads the board. Called when the CHANGES tab or a
    /// live ref body becomes visible.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        resubscribe()
        Task { await refresh() }
    }

    /// Cancels the stream (the engine's loop stops once no observer is left). What was shown stays until the next start.
    public func stop() {
        isRunning = false
        generation += 1
        watchTask?.cancel()
        watchTask = nil
    }

    private func resubscribe() {
        generation += 1
        watchTask?.cancel()
        watchTask = nil
        guard isRunning, let key = selectedKey else { return }
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
            let stream = await live.watch(companyId: companyId, key: key, compare: compare, reader: .owner, knownValues: known)
            for await snapshot in stream {
                if Task.isCancelled { break }
                let parsed = await Task.detached(priority: .userInitiated) { DiffModel.parse(patch: snapshot.patch) }.value
                guard let self, !Task.isCancelled else { break }
                self.apply(snapshot, parsed, gen: gen)
            }
        }
    }

    private func refuse(_ gen: Int) {
        guard gen == generation else { return }
        error = Self.refusedText
    }

    /// A yield: the snapshot and its parse, the scroll stop kept on the same file when it still exists, the "changed since shown"
    /// flag and the markers.
    private func apply(_ snapshot: ChangesSnapshot, _ parsed: DiffModel, gen: Int) {
        guard gen == generation else { return }
        let previous: (DiffStop, DiffModel)? = currentStop.flatMap { stop in diff.map { (stop, $0) } }
        self.snapshot = snapshot
        diff = parsed
        changeStops = parsed.changeStops
        error = nil
        if let (stop, old) = previous {
            stopIndex = DiffStops.relocate(stop, from: old, in: parsed).flatMap { moved in changeStops.firstIndex(of: moved) }
        } else {
            stopIndex = nil
        }
        changedSinceShown = shownAt.map { $0 != snapshot.patchHash } ?? false
        placeMarkers()
    }

    // MARK: Board, revisions and comments

    /// Reloads the board, and the selected item's revisions and comments, off the main actor (the stored values loaded now).
    public func refresh() async {
        let (store, companyId, key, loader, now) = (self.store, self.companyId, selectedKey, self.knownValues, clock())
        do {
            let (board, revisions, comments) = try await Task.detached { () -> ([BoardRow], [ItemRevision], [DiffComment]) in
                let known = try loader()
                let board = try store.changesBoard(companyId: companyId, reader: .owner, knownValues: known, now: now)
                guard let key else { return (board, [], []) }
                let revisions = try store.itemRevisions(companyId: companyId, key: key)
                let comments = try store.diffComments(companyId: companyId, key: key, reader: .owner, knownValues: known)
                return (board, revisions, comments)
            }.value
            guard key == selectedKey else { return }
            self.board = board
            rows = BoardRows.make(board, now: now)
            self.revisions = revisions
            self.comments = comments
            placeMarkers()
            if error == Self.refusedText { error = nil }
        } catch let e as WorkError {
            error = e.message
        } catch {
            self.error = Self.refusedText
        }
    }

    /// The unresolved comments of this compare on the diff: each at the line `DiffAnchoring.relocate` finds for its text within
    /// the re-anchor window, keyed by the anchor the view draws (the header as numbers only); the rest count as outdated per path.
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
            guard let line = DiffAnchoring.relocate(c, in: snapshot.patch), let anchor = Self.anchor(in: diff, path: c.path, side: c.side, line: line) else {
                stale[c.path, default: 0] += 1
                continue
            }
            placed[anchor, default: []].append(c)
        }
        markers = placed
        outdated = stale
    }

    /// The anchor of `line` on `side` of `path` in the parsed diff, or nil when that line is not shown.
    static func anchor(in diff: DiffModel, path: String, side: String, line: Int) -> DiffAnchor? {
        guard let file = diff.files.first(where: { $0.path == path }) else { return nil }
        for hunk in file.hunks {
            if let l = hunk.lines.first(where: { (side == "old" ? $0.oldNo : $0.newNo) == line }) {
                return DiffAnchor(path: path, side: side, line: line, hunkHeader: DiffAnchoring.headerRange(hunk.header) ?? hunk.header, lineText: l.text)
            }
        }
        return nil
    }
}

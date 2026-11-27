import Foundation
import Observation
import BrahmaCore

/// One row of the MEASURE table: a metric (depth 0) or one of its detail rows (depth 1 and deeper, shown while their metric is
/// expanded). `value` is the metric's `display` string verbatim (so the denominator is always shown); `secondary` marks a value
/// that is not a measured number (`insufficient data`, `not measured`, `not applicable`). Every string has passed `MapText.clean`.
public struct MeasureRow: Equatable, Sendable, Identifiable {
    /// The path of metric ids and detail indexes down to this row (`greenMain`, `greenMain/0`): unique within one report.
    public var id: String
    public var label: String
    public var value: String
    public var basis: String
    public var depth: Int
    public var secondary: Bool
    /// The row has detail rows under it.
    public var expandable: Bool
    public var expanded: Bool
}

/// Budget › MEASURE (Plan X6a Task 8): the selected company's `brahma measure` report, computed off the main actor with the same
/// `Measure.report` the CLI runs, over the window the owner picks (7 days, 28 days, all). The app model measures again when the
/// work or usage snapshot changes while Budget is shown (`AppModel.refreshSnapshot`), at most once a minute (ruling R43); the
/// picker, Refresh and opening Budget measure at once. Leaving a company or window cancels its run. A failure shows the CLI's
/// own text.
@MainActor @Observable
public final class MeasureModel {
    /// The window picker's choices; `days28` is the CLI's default window (`MeasureWindow.defaultDays`).
    public enum Span: String, CaseIterable, Sendable, Identifiable {
        case days7, days28, all
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .days7: return "7 days"
            case .days28: return "28 days"
            case .all: return "All"
            }
        }
    }

    /// Computes one report; runs off the main actor. `live` in the app.
    public typealias Compute = @Sendable (_ store: Store, _ paths: BrahmaPaths, _ companyId: String, _ span: Span, _ now: Date)
        throws -> MeasureReport

    public nonisolated static let title = "MEASURE"
    /// Agent-controlled text is cut to these many characters (`MapText.clean`); a metric's value is never that long.
    nonisolated static let labelMax = 200
    nonisolated static let valueMax = 400
    nonisolated static let basisMax = 2000

    /// How often a work or usage change may measure (ruling R43): at most once per `interval` seconds of `uptime`, with at most
    /// one run queued for the end of the interval. `sleep` waits that long (tests give a door of their own).
    public struct Throttle: Sendable {
        public var interval: TimeInterval
        public var uptime: @Sendable () -> TimeInterval
        public var sleep: @Sendable (TimeInterval) async throws -> Void
        public init(interval: TimeInterval = 60, uptime: @escaping @Sendable () -> TimeInterval,
                    sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
            self.interval = interval; self.uptime = uptime; self.sleep = sleep
        }
        public static let live = Throttle(uptime: { AwakeTime.uptime() }, sleep: { try await Task.sleep(for: .seconds($0)) })
    }

    public private(set) var companyId: String?
    public private(set) var report: MeasureReport?
    public private(set) var window: Span = .days28
    public private(set) var isLoading = false
    public var errorMessage: String?
    /// Expanded rows, by `MeasureRow.id`.
    public private(set) var expanded: Set<String> = []
    /// One row per metric, with the detail rows of every expanded row under it; rebuilt when the report or an expansion changes.
    public private(set) var rows: [MeasureRow] = []
    /// `yyyy-MM-dd HH:mm…yyyy-MM-dd HH:mm` in the report's time zone (the owner's), as the CLI's header shows it; nil before a report.
    public private(set) var windowLine: String?
    /// The report's company name, cleaned; nil before a report.
    public private(set) var companyLine: String?

    /// One computation: its task (cancelled when the owner leaves its company or window) and what it measures.
    private struct Run {
        let task: Task<Result<MeasureReport, any Error>, Never>
        let companyId: String
        let span: Span
    }

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let paths: BrahmaPaths
    @ObservationIgnored private let compute: Compute
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let throttle: Throttle
    @ObservationIgnored private var current: Run?
    /// Bumped by every run; a run whose number is no longer the newest is dropped when it ends.
    @ObservationIgnored private var generation = 0
    /// A load of the same company and window arrived while it was computing: compute once more when it ends.
    @ObservationIgnored private var reloadPending = false
    /// `throttle.uptime()` when the last run started.
    @ObservationIgnored private var lastMeasured: TimeInterval?
    /// The one run queued for the end of the throttle interval.
    @ObservationIgnored private var delayed: Task<Void, Never>?

    public init(store: Store, paths: BrahmaPaths, compute: @escaping Compute = MeasureModel.live,
                clock: @escaping @Sendable () -> Date = { .now }, throttle: Throttle = .live) {
        self.store = store
        self.paths = paths
        self.compute = compute
        self.clock = clock
        self.throttle = throttle
    }

    /// The CLI's report: the company's workspace repository, the window the CLI would parse, `Measure.report`.
    public nonisolated static let live: Compute = { store, paths, companyId, span, now in
        guard let company = try store.company(id: companyId) else { throw MeasureError.unknownCompany(companyId) }
        let window: MeasureWindow
        switch span {
        // Both spans start at the owner's midnight (ruling R44), as the CLI's default does.
        case .days7: window = MeasureWindow.lastDays(7, now: now, tz: store.ownerTimeZone())
        case .days28: window = try MeasureWindow.parse(nil, now: now, companyCreated: company.createdAt, tz: store.ownerTimeZone())
        case .all: window = try MeasureWindow.parse("all", now: now, companyCreated: company.createdAt, tz: store.ownerTimeZone())
        }
        let git = GitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), exportHome: paths.home)
        return try Measure.report(store: store, git: git, companyId: company.id, window: window, now: now)
    }

    /// Shows `companyId` (opening Budget): measured at once. Another company cancels the run and the queued run of the one
    /// before, and drops its report and expansions.
    public func show(companyId: String) async {
        if self.companyId != companyId {
            current?.task.cancel()
            delayed?.cancel()
            delayed = nil
            self.companyId = companyId
            expanded = []
            apply(report: nil)
            errorMessage = nil
        }
        await load()
    }

    /// The picker: shows `span`, measured at once (the run of the old window is cancelled). The window shown measures nothing.
    public func setWindow(_ span: Span) async {
        guard span != window else { return }
        current?.task.cancel()
        window = span
        await load()
    }

    /// A work or usage change (ruling R43): a run already queued absorbs this change; else it measures at once when the last
    /// run started at least `throttle.interval` ago, else queues one run for the end of the interval.
    public func changed() {
        guard companyId != nil else { return }
        // Checked first: the queued run measures this change; measuring now as well would be a second run (final review #4(b)).
        guard delayed == nil else { return }
        let now = throttle.uptime()
        guard let last = lastMeasured, now - last < throttle.interval else {
            Task { await load() }
            return
        }
        let (wait, sleep) = (throttle.interval - (now - last), throttle.sleep)
        delayed = Task { [weak self] in
            do { try await sleep(wait) } catch { return }   // cancelled: another company was shown, or a run measured first
            // A sleep that did not end on cancellation still never measures for a cancelled queue (final review #4(c)).
            guard !Task.isCancelled, let self else { return }
            self.delayed = nil
            await self.load()
        }
    }

    /// Stops the run in flight and the queued run (`AppModel.reopenStore`: the store they read is being replaced). Nothing they
    /// would have shown arrives later; a cancelled run is not an error.
    public func cancel() {
        current?.task.cancel()
        delayed?.cancel()
        delayed = nil
        reloadPending = false
    }

    /// Measures the shown company over the shown window now (Refresh), off the main actor. A load of the same company and window
    /// while that one computes is folded into one more run after it. A run for another company or window is cancelled and
    /// its result dropped whenever it ends: the new run does not wait for it. A cancelled run is not an error.
    public func load() async {
        guard let companyId else { return }
        let span = window
        if let current, current.companyId == companyId, current.span == span {
            reloadPending = true
            return
        }
        current?.task.cancel()
        // This run measures now: the queued one has nothing left to measure (final review #4(a); Refresh absorbs it).
        delayed?.cancel()
        delayed = nil
        reloadPending = false
        generation += 1
        let mine = generation
        lastMeasured = throttle.uptime()
        let (now, store, paths, compute) = (clock(), self.store, self.paths, self.compute)
        let task = Task.detached { Result<MeasureReport, any Error> { try compute(store, paths, companyId, span, now) } }
        current = Run(task: task, companyId: companyId, span: span)
        isLoading = true
        let result = await task.value
        guard mine == generation else { return }   // superseded: the newer run owns the panel
        current = nil
        isLoading = false
        switch result {
        case .success(let measured):
            apply(report: measured)
            errorMessage = nil
        case .failure(let error) where error is CancellationError:
            break
        case .failure(let error):
            apply(report: nil)
            errorMessage = Self.errorText(error)
        }
        if reloadPending { await load() }
    }

    /// The CLI's text for `error` (it prints `brahma: \(error)`), cleaned: an error can carry a company or workspace name.
    nonisolated static func errorText(_ error: any Error) -> String {
        MapText.clean("\(error)", max: basisMax)
    }

    /// Expands or folds a row's detail rows.
    public func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rows = Self.rows(report, expanded: expanded)
    }

    // MARK: Presentation

    private func apply(report: MeasureReport?) {
        self.report = report
        rows = Self.rows(report, expanded: expanded)
        windowLine = report.map(Self.windowText)
        companyLine = report.map { MapText.clean($0.company, max: Self.labelMax) }
    }

    static func rows(_ report: MeasureReport?, expanded: Set<String>) -> [MeasureRow] {
        guard let report else { return [] }
        var out: [MeasureRow] = []
        func add(_ m: MetricValue, id: String, depth: Int) {
            let open = expanded.contains(id)
            out.append(MeasureRow(id: id, label: MapText.clean(m.label, max: labelMax),
                                  value: MapText.clean(m.display, max: valueMax),
                                  basis: MapText.clean(m.basis, max: basisMax), depth: depth,
                                  secondary: m.status != .ok, expandable: !m.detail.isEmpty, expanded: open))
            guard open else { return }
            for (i, d) in m.detail.enumerated() { add(d, id: "\(id)/\(i)", depth: depth + 1) }
        }
        for m in report.metrics { add(m, id: m.id.rawValue, depth: 0) }
        return out
    }

    /// One formatter per time zone, made on first use (main actor only).
    private static var formatters: [String: DateFormatter] = [:]

    static func windowText(_ report: MeasureReport) -> String {
        let f: DateFormatter
        if let hit = formatters[report.timeZone] {
            f = hit
        } else {
            f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: report.timeZone) ?? TimeZone(identifier: "UTC") ?? .current
            f.dateFormat = "yyyy-MM-dd HH:mm"
            formatters[report.timeZone] = f
        }
        return "\(f.string(from: report.window.since))…\(f.string(from: report.window.until))"
    }

    /// The table's footnote, as the CLI's.
    public nonisolated static let footnote = "Definitions and sources: \(MeasureReport.definitions). A rate with fewer than "
        + "\(MetricValue.minEvents) events is insufficient data; nothing is estimated."
}

extension AppModel {
    /// Budget › MEASURE, made on first use, pointed at the selected company (and measured).
    @discardableResult
    public func ensureMeasure() -> MeasureModel? {
        guard let companyId = selectedCompanyId else { return nil }
        let model = measure ?? MeasureModel(store: store, paths: paths, compute: measureCompute, throttle: measureThrottle)
        measure = model
        // Opening Budget measures; a second ensure while that runs (the view's own task) adds nothing.
        if model.companyId != companyId || !model.isLoading { Task { await model.show(companyId: companyId) } }
        return model
    }

    /// Called when a refreshed snapshot's work or usage differs: measures again while Budget shows the selected company, at
    /// most once a minute (ruling R43, `MeasureModel.changed()`).
    func measureAfterChange(companyId: String?) {
        guard sidebarSelection == .budget, let measure, let companyId, measure.companyId == companyId else { return }
        measure.changed()
    }
}

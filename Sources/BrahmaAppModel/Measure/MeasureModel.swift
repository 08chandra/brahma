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
/// work or usage snapshot changes while Budget is shown (`AppModel.refreshSnapshot`). A failure shows the CLI's own text.
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

    public private(set) var companyId: String?
    public private(set) var report: MeasureReport?
    public private(set) var window: Span = .days28
    public private(set) var isLoading = false
    public var errorMessage: String?
    /// Expanded rows, by `MeasureRow.id`.
    public private(set) var expanded: Set<String> = []

    @ObservationIgnored private let store: Store
    @ObservationIgnored private let paths: BrahmaPaths
    @ObservationIgnored private let compute: Compute
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// A change arrived while a report was computing: compute once more when it ends.
    @ObservationIgnored private var reloadPending = false

    public init(store: Store, paths: BrahmaPaths, compute: @escaping Compute = MeasureModel.live,
                clock: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.paths = paths
        self.compute = compute
        self.clock = clock
    }

    /// The CLI's report: the company's workspace repository, the window the CLI would parse, `Measure.report`.
    public nonisolated static let live: Compute = { store, paths, companyId, span, now in
        guard let company = try store.company(id: companyId) else { throw MeasureError.unknownCompany(companyId) }
        let window: MeasureWindow
        switch span {
        case .days7: window = MeasureWindow(since: now.addingTimeInterval(-7 * 86_400), until: now)
        case .days28: window = try MeasureWindow.parse(nil, now: now, companyCreated: company.createdAt, tz: store.ownerTimeZone())
        case .all: window = try MeasureWindow.parse("all", now: now, companyCreated: company.createdAt, tz: store.ownerTimeZone())
        }
        let git = GitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), exportHome: paths.home)
        return try Measure.report(store: store, git: git, companyId: company.id, window: window, now: now)
    }

    /// Shows `companyId`: another company drops the shown report and expansions first. Always measures.
    public func show(companyId: String) async {
        if self.companyId != companyId {
            self.companyId = companyId
            report = nil
            errorMessage = nil
            expanded = []
        }
        await load()
    }

    /// The picker: shows `span`, measured now. The window already shown measures nothing.
    public func setWindow(_ span: Span) async {
        guard span != window else { return }
        window = span
        await load()
    }

    /// Measures the shown company over the shown window, off the main actor. A call while one runs is folded into one more run
    /// after it, so a burst of changes measures at most twice. A result for a company or window the owner has since left is dropped.
    public func load() async {
        guard companyId != nil else { return }
        if isLoading {
            reloadPending = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        repeat {
            reloadPending = false
            guard let companyId else { return }
            let (span, now, store, paths, compute) = (window, clock(), self.store, self.paths, self.compute)
            let result: Result<MeasureReport, any Error> = await Task.detached {
                Result { try compute(store, paths, companyId, span, now) }
            }.value
            guard companyId == self.companyId, span == window else {
                reloadPending = true
                continue
            }
            switch result {
            case .success(let measured):
                report = measured
                errorMessage = nil
            case .failure(let error):
                report = nil
                errorMessage = Self.errorText(error)
            }
        } while reloadPending
    }

    /// The CLI's text for `error` (it prints `brahma: \(error)`), cleaned: an error can carry a company or workspace name.
    nonisolated static func errorText(_ error: any Error) -> String {
        MapText.clean("\(error)", max: basisMax)
    }

    /// Expands or folds a row's detail rows.
    public func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Presentation

    /// The report's company name, cleaned; nil before a report.
    public var companyLine: String? { report.map { MapText.clean($0.company, max: Self.labelMax) } }

    /// One row per metric, with the detail rows of every expanded row under it.
    public var rows: [MeasureRow] {
        guard let report else { return [] }
        var out: [MeasureRow] = []
        func add(_ m: MetricValue, id: String, depth: Int) {
            let open = expanded.contains(id)
            out.append(MeasureRow(id: id, label: MapText.clean(m.label, max: Self.labelMax),
                                  value: MapText.clean(m.display, max: Self.valueMax),
                                  basis: MapText.clean(m.basis, max: Self.basisMax), depth: depth,
                                  secondary: m.status != .ok, expandable: !m.detail.isEmpty, expanded: open))
            guard open else { return }
            for (i, d) in m.detail.enumerated() { add(d, id: "\(id)/\(i)", depth: depth + 1) }
        }
        for m in report.metrics { add(m, id: m.id.rawValue, depth: 0) }
        return out
    }

    /// `yyyy-MM-dd HH:mm…yyyy-MM-dd HH:mm` in the report's time zone (the owner's), as the CLI's header shows it.
    public var windowLine: String? {
        guard let report else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: report.timeZone) ?? TimeZone(identifier: "UTC") ?? .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
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
        let model = measure ?? MeasureModel(store: store, paths: paths, compute: measureCompute)
        measure = model
        // Opening Budget measures; a second ensure while that runs (the view's own task) adds nothing.
        if model.companyId != companyId || !model.isLoading { Task { await model.show(companyId: companyId) } }
        return model
    }

    /// Called when a refreshed snapshot's work or usage differs: measures again while Budget shows the selected company.
    func measureAfterChange(companyId: String?) {
        guard sidebarSelection == .budget, let measure, let companyId, measure.companyId == companyId else { return }
        Task { await measure.load() }
    }
}

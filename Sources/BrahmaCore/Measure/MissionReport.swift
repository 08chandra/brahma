import Foundation

/// The mission subset of `brahma measure` (Plan X6a Task 7; spec §10 row 5 (2)): what a long run is judged on, in this order —
/// items landed, owner touches, usage per landed item, green-main, turns wasted on rate limits, reserve breaches and idle while
/// actionable. Every row is the full report's own measurement (the same function, the same window, the same basis); the last
/// two rows come from the `safety` metric's rows of the same names. Nothing is computed here that the full report does not.
public enum MissionReport {
    /// The subset, in the order it is printed.
    public static let ids: [MetricId] = [.itemsLanded, .ownerTouches, .usagePerLanded, .greenMain, .wastedRateLimitTurns,
                                         .reserveBreaches, .idleActionable]

    /// The value of `subset` a mission report carries (its markdown header reads `# mission <company>`).
    public static let subset = "mission"

    public static func make(store: Store, git: GitWorkspace, companyId: String, window: MeasureWindow, now: Date) throws -> MeasureReport {
        guard let company = try store.company(id: companyId) else { throw MeasureError.unknownCompany(companyId) }
        let ctx = MeasureContext(store: store, git: git, company: company, window: window, now: now)
        let safety = try UsageMetrics.safety(ctx)
        func row(_ label: String, as id: MetricId) -> MetricValue {
            guard var value = safety.detail.first(where: { $0.label == label }) else {
                return .notMeasured(id, reason: "the safety metric has no '\(label)' row")
            }
            value.id = id
            value.label = id.label
            return value
        }
        var metrics: [MetricValue] = []
        for id in ids {
            if Task.isCancelled { throw CancellationError() }
            switch id {
            case .itemsLanded: metrics.append(try itemsLanded(ctx))
            case .wastedRateLimitTurns: metrics.append(row(UsageMetrics.wastedLabel, as: id))
            case .reserveBreaches: metrics.append(row(UsageMetrics.breachesLabel, as: id))
            default: metrics.append(try Measure.function(for: id)(ctx))
            }
        }
        return MeasureReport(companyId: company.id, company: company.name, window: window, timeZone: store.ownerTimeZone().identifier,
                             metrics: metrics, generatedAt: now, brahmaBuild: Measure.build, subset: subset)
    }

    /// The landed items of the window's landings (rulings R13/R24): a count, never insufficient; zero is a measured zero.
    static func itemsLanded(_ ctx: MeasureContext) throws -> MetricValue {
        let landings = try ctx.store.landings(companyId: ctx.companyId, in: ctx.window)
        let items = landings.reduce(0) { $0 + $1.items.count }
        return .count(.itemsLanded, Double(items),
                      basis: "items merged by the merge queue's landings in the window (\(landings.count) landing\(landings.count == 1 ? "" : "s"))")
    }
}

/// `brahma measure <company> --compare <baseline>` (owner ruling R7(e)): two reports over the same window, with the same metric
/// ids, side by side; each value is the one its own report shows, with its own denominator. The owner runs the same backlog in
/// a one-agent company (the baseline) and compares; nothing here runs anything. A baseline that does not exist, or that has no
/// landing in the window, is `not measured: <reason>` in every baseline cell, and its report is null (ruling R42(c)).
public struct MeasureComparison: Codable, Equatable, Sendable {
    /// The company being measured.
    public var report: MeasureReport
    /// The baseline as the owner named it.
    public var baselineName: String
    /// The baseline's report over the same window; nil when the baseline is not measured (`baselineNotMeasured` says why).
    public var baseline: MeasureReport?
    /// Why the baseline column is not measured, or nil when it is.
    public var baselineNotMeasured: String?

    public init(report: MeasureReport, baselineName: String, baseline: MeasureReport?, baselineNotMeasured: String?) {
        self.report = report; self.baselineName = baselineName; self.baseline = baseline; self.baselineNotMeasured = baselineNotMeasured
    }

    /// The baseline named `query` (a company name or slug, as `brahma measure` resolves one), or nil.
    public static func baselineCompany(_ store: Store, _ query: String) throws -> Company? {
        let q = query.lowercased()
        return try store.companies().first { $0.name.lowercased() == q || $0.slug == q }
    }

    /// Both reports over `report`'s window, the baseline's built by `measure` (the full report or the mission subset, as the
    /// first one was). The baseline column is not measured when the company does not exist or has no landing in the window.
    public static func make(store: Store, report: MeasureReport, baselineName: String,
                            measure: (Company) throws -> MeasureReport) throws -> MeasureComparison {
        guard let company = try baselineCompany(store, baselineName) else {
            return MeasureComparison(report: report, baselineName: baselineName, baseline: nil,
                                     baselineNotMeasured: "no company named '\(baselineName)'")
        }
        guard !(try store.landings(companyId: company.id, in: report.window)).isEmpty else {
            return MeasureComparison(report: report, baselineName: company.name, baseline: nil,
                                     baselineNotMeasured: "\(company.name) has no landings in the window")
        }
        return MeasureComparison(report: report, baselineName: company.name, baseline: try measure(company), baselineNotMeasured: nil)
    }

    /// `# measure <company> vs <baseline> (baseline) — <window>`, one row per metric of the first report (and its detail rows,
    /// matched to the baseline's by label), the first report's value then the baseline's. A detail row one side lacks is
    /// `not measured: no '<label>' row in <company>'s report` on that side. Plain text: the CLI passes every line through `safe()`.
    public func markdown() -> String {
        var lines = ["# \(report.subset ?? "measure") \(report.company) vs \(baselineName) (baseline) — \(report.windowText)"]
        lines.append("time zone \(report.zoneForDisplay.identifier) · generated \(MeasureReport.iso(report.generatedAt)) · brahma \(report.brahmaBuild)"
                     + " · the same window and metric ids for both; each value carries its own denominator")
        lines.append("")
        lines.append("| metric | \(cell(report.company)) | \(cell(baselineName)) (baseline) |")
        lines.append("|---|---|---|")
        let notMeasured = baselineNotMeasured.map { "not measured: \($0)" }
        func missing(_ label: String, in company: String) -> String { "not measured: no '\(label)' row in \(company)'s report" }
        func row(_ label: String, _ a: MetricValue?, _ b: MetricValue?, depth: Int) {
            let indent = depth == 0 ? "" : String(repeating: "  ", count: depth) + "↳ "
            let left = a.map(\.display) ?? missing(label, in: report.company)
            let right = notMeasured ?? b.map(\.display) ?? missing(label, in: baselineName)
            lines.append("| \(indent)\(cell(label)) | \(cell(left)) | \(cell(right)) |")
            let mine = a?.detail ?? [], other = b?.detail ?? []
            for d in mine { row(d.label, d, other.first { $0.label == d.label }, depth: depth + 1) }
            for d in other where !mine.contains(where: { $0.label == d.label }) { row(d.label, nil, d, depth: depth + 1) }
        }
        for m in report.metrics { row(m.label, m, baseline?.metrics.first { $0.id == m.id }, depth: 0) }
        lines.append("")
        lines.append("Definitions and sources: \(MeasureReport.definitions) (the baseline procedure: \"Single-agent baseline\"). "
                     + "Each report's basis: `brahma measure <company>`, or --format json, which carries both reports in full.")
        return lines.joined(separator: "\n") + "\n"
    }

    private func cell(_ s: String) -> String { s.isEmpty ? "—" : s.replacingOccurrences(of: "|", with: "\\|") }

    /// ISO 8601 dates, sorted keys, pretty-printed; `decode` gives back an equal comparison.
    public func json() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> MeasureComparison {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(MeasureComparison.self, from: data)
    }
}

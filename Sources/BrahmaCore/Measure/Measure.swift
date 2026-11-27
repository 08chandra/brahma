import Foundation

/// What `brahma measure` refuses with.
public enum MeasureError: Error, Equatable, CustomStringConvertible {
    /// `--since` was neither `YYYY-MM-DD` nor `all`.
    case badSince(String)
    /// `--since` names a day after `now`.
    case sinceAfterNow(String)
    case unknownCompany(String)
    /// `--day` was not a `YYYY-MM-DD` day.
    case badDay(String)
    /// `--day` names a day that has not begun in the owner's time zone.
    case dayAfterToday(String)
    /// `--log-owner-minutes` outside 1…1440.
    case badMinutes(Int)
    /// `--verify-landings`: the company's workspace has no `main` branch (or no repository) to audit.
    case noMainBranch(String)
    /// `--verify-landings`: the repository holds a `shallow` or `info/grafts` file, which rewrites where history ends.
    case plantedHistory(String)
    /// `--verify-landings`: first-parent history ends at a commit whose object has a parent (the history is cut).
    case historyCut(String)
    /// `--verify-landings`: a merge batch is moving `main`.
    case mergeBatchOpen
    /// `--soak-verify`: the file is missing, unreadable or not a soak checkpoint (Task 7).
    case badCheckpoint(String)
    /// `--soak-verify`: the checkpoint was taken of another company.
    case checkpointOfAnotherCompany(String)
    /// `--soak-checkpoint` / `--soak-verify`: the directory the owner named does not exist.
    case noSuchDirectory(String)
    /// `--soak-checkpoint` / `--soak-verify`: whether an engine runs could not be read (the lock file could not be opened).
    case engineStateUnreadable(String)

    public var description: String {
        switch self {
        case .badSince(let s): return "--since must be a date (YYYY-MM-DD) or 'all', not '\(s)'"
        case .sinceAfterNow(let s): return "--since '\(s)' is after today; nothing can have happened yet"
        case .unknownCompany(let id): return "no company with id \(id)"
        case .noMainBranch(let id): return "the workspace of company \(id) has no main branch to audit"
        case .plantedHistory(let id):
            return "the repository of company \(id) holds a .git/shallow or .git/info/grafts file, which rewrites its history; remove it, then audit again"
        case .historyCut(let root): return "main's history ends at \(root), which has a parent: the history is cut and cannot be audited"
        case .mergeBatchOpen: return "a merge batch is open; run again after it finishes"
        case .badCheckpoint(let why): return "not a soak checkpoint: \(why)"
        case .checkpointOfAnotherCompany(let name):
            return "the checkpoint was taken of another company; verify it with 'brahma measure <that company> --soak-verify', not \(name)"
        case .noSuchDirectory(let path): return "the directory \(path) does not exist; make it first"
        case .engineStateUnreadable(let why): return "cannot tell whether an engine is running: \(why)"
        case .badDay(let s): return "--day must be a date (YYYY-MM-DD), not '\(s)'"
        case .dayAfterToday(let s): return "--day '\(s)' is after today; owner time can be logged only for a day that has begun"
        case .badMinutes(let n):
            return "--log-owner-minutes must be a whole number of minutes from 1 to \(MeasureRecorder.maxOwnerMinutesPerLog), not \(n)"
        }
    }
}

/// The window one report covers: `[since, until)`, whole seconds (so the report's JSON round-trips through ISO 8601).
public struct MeasureWindow: Codable, Equatable, Sendable {
    public var since: Date
    public var until: Date

    /// The default window, in days back from `now`.
    public static let defaultDays = 28

    public init(since: Date, until: Date) { self.since = since.wholeSeconds; self.until = until.wholeSeconds }

    /// `nil`: the last `defaultDays` days. `all`: since the company was created. `YYYY-MM-DD`: midnight of that day in the owner's
    /// time zone (`ownerSettings.timeZone`). `until` is always `now`.
    public static func parse(_ since: String?, now: Date, companyCreated: Date, tz: TimeZone) throws -> MeasureWindow {
        let until = now.wholeSeconds
        guard let since else { return MeasureWindow(since: until.addingTimeInterval(-Double(defaultDays) * 86_400), until: until) }
        // Given but empty is a mistake, not the default.
        let raw = since.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw MeasureError.badSince(since) }
        if raw == "all" { return MeasureWindow(since: min(companyCreated, until), until: until) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard raw.count == 10, let day = f.date(from: raw), f.string(from: day) == raw else { throw MeasureError.badSince(raw) }
        guard day <= until else { throw MeasureError.sinceAfterNow(raw) }
        return MeasureWindow(since: day, until: until)
    }
}

extension Date {
    /// Truncated to the second: what ISO 8601 without fractions carries.
    var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

/// One company's metrics over one window, as the CLI prints it (`markdown()`) and as the app and tests read it (`json()`).
public struct MeasureReport: Codable, Equatable, Sendable {
    public var companyId: String
    public var company: String
    public var window: MeasureWindow
    /// The owner's time zone (`ownerSettings.timeZone`), the zone the markdown shows the window in.
    public var timeZone: String
    public var metrics: [MetricValue]
    public var generatedAt: Date
    public var brahmaBuild: String
    /// nil: the full report (`MetricId.all`). `mission`: the mission subset (`MissionReport`, Task 7); the markdown header names it.
    public var subset: String?

    public init(companyId: String, company: String, window: MeasureWindow, timeZone: String, metrics: [MetricValue], generatedAt: Date,
                brahmaBuild: String, subset: String? = nil) {
        self.companyId = companyId; self.company = company; self.window = window; self.timeZone = timeZone; self.metrics = metrics
        self.generatedAt = generatedAt.wholeSeconds; self.brahmaBuild = brahmaBuild; self.subset = subset
    }

    /// Where every metric is defined.
    public static let definitions = "docs/measure/metrics.md"

    /// `# measure <company> — <since>…<until>`, a line of provenance, one table row per metric with its detail rows indented
    /// under it, and the link to the definitions. The company name is not sanitized here: the CLI passes every line through `safe()`.
    public func markdown() -> String {
        let zone = zoneForDisplay
        var lines = ["# \(subset ?? "measure") \(company) — \(windowText)"]
        lines.append("time zone \(zone.identifier) · generated \(Self.iso(generatedAt)) · brahma \(brahmaBuild)")
        lines.append("")
        lines.append("| metric | value | basis |")
        lines.append("|---|---|---|")
        func cell(_ s: String) -> String { s.isEmpty ? "—" : s.replacingOccurrences(of: "|", with: "\\|") }
        func row(_ m: MetricValue, depth: Int) {
            let indent = depth == 0 ? "" : String(repeating: "  ", count: depth) + "↳ "
            lines.append("| \(indent)\(cell(m.label)) | \(cell(m.display)) | \(cell(m.basis)) |")
            for d in m.detail { row(d, depth: depth + 1) }
        }
        for m in metrics { row(m, depth: 0) }
        lines.append("")
        lines.append("Definitions and sources: \(Self.definitions). A rate with fewer than \(MetricValue.minEvents) events is "
                     + "`insufficient data`; nothing is estimated.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The owner's zone the window is shown in (UTC when the stored name is unknown).
    var zoneForDisplay: TimeZone { TimeZone(identifier: timeZone) ?? TimeZone(identifier: "UTC") ?? .current }

    /// `2026-11-01 00:00…2026-11-27 14:05` in the owner's zone.
    var windowText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zoneForDisplay
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(f.string(from: window.since))…\(f.string(from: window.until))"
    }

    /// ISO 8601 dates, sorted keys, pretty-printed: `decode` gives back an equal report.
    public func json() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> MeasureReport {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(MeasureReport.self, from: data)
    }

    /// `2026-11-27T22:05:00Z` (a fresh formatter each time: the class is not Sendable).
    public static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

/// What every metric function reads: the company's own store rows (every query `WHERE companyId = ?`) and the company's own
/// workspace repository, never another company's.
public struct MeasureContext: Sendable {
    public let store: Store
    public let git: GitWorkspace
    public let company: Company
    public let window: MeasureWindow
    public let now: Date
    public var companyId: String { company.id }
}

/// `brahma measure`'s frame (Plan X6a Task 1). `report` runs one function per `MetricId`, in `MetricId.all`'s order. Tasks 3–5
/// add the functions one file at a time (`extension Measure { static func greenMain(_ ctx: MeasureContext) throws -> MetricValue }`)
/// and point `function(for:)` at them; until then a metric is `not applicable: not built yet`.
public enum Measure {
    public typealias MetricFunction = @Sendable (MeasureContext) throws -> MetricValue

    /// The version string the report carries. The CLI has no version constant yet; `dev` until one exists.
    public static let build = "dev"

    public static func report(store: Store, git: GitWorkspace, companyId: String, window: MeasureWindow, now: Date) throws -> MeasureReport {
        guard let company = try store.company(id: companyId) else { throw MeasureError.unknownCompany(companyId) }
        let ctx = MeasureContext(store: store, git: git, company: company, window: window, now: now)
        // Between metrics: a report the app no longer wants (its company or window was left) stops here (`MeasureModel`).
        let metrics = try MetricId.all.map { id -> MetricValue in
            if Task.isCancelled { throw CancellationError() }
            return try function(for: id)(ctx)
        }
        return MeasureReport(companyId: company.id, company: company.name, window: window, timeZone: store.ownerTimeZone().identifier,
                             metrics: metrics, generatedAt: now, brahmaBuild: build)
    }

    /// The function for every id of `MetricId.all`, by name (`MeasureScopeTests.everyMetricIdHasAFunction` holds the table complete).
    /// A metric not built yet maps to `notBuilt`; a task wires its functions here.
    static let functions: [MetricId: MetricFunction] = [
        .greenMain: { try LandingMetrics.greenMain($0) },
        // One detector per run: its patch-id cache lives for this report only.
        .revertRate: { try ReviewMetrics.revertRate($0, detector: RevertDetector(git: $0.git)) },
        .reviewCatch: { try ReviewMetrics.reviewCatch($0) },
        .escapeRate: { try ReviewMetrics.escapeRate($0) },
        .usagePerLanded: { try UsageMetrics.usagePerLanded($0) },
        .ownerTouches: { try UsageMetrics.ownerTouches($0) },
        .firstPass: { try LandingMetrics.firstPass($0) },
        .queueHealth: { try LandingMetrics.queueHealth($0) },
        .safety: { try UsageMetrics.safety($0) },
        .nonCode: { try UsageMetrics.nonCode($0) },
        .modelRanking: { try UsageMetrics.modelRanking($0) },
        .idleActionable: { try UsageMetrics.idleActionable($0) },
        .itemsPerDollar: { try UsageMetrics.itemsPerDollar($0) },
        .itemsPerPlanHour: { try UsageMetrics.itemsPerPlanHour($0) },
        .ownerMinutes: { try UsageMetrics.ownerMinutes($0) },
    ]

    /// The function that measures `id`; an id the table does not know is `not built yet`.
    static func function(for id: MetricId) -> MetricFunction { functions[id] ?? notBuilt(id) }

    static func notBuilt(_ id: MetricId) -> MetricFunction { { _ in .notApplicable(id, reason: "not built yet") } }
}

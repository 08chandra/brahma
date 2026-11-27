import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma measure <company> [--since <YYYY-MM-DD|all>] [--format md|json]` (Plan X6a): the company's metrics over one window,
/// every number with its denominator (`docs/measure/metrics.md`). Read-only, but it reads every agent's records, so it runs only
/// from the owner's shell: never inside an agent turn. The one write: `--log-owner-minutes <n> [--day YYYY-MM-DD]` adds the
/// owner's own time to that day's counter (owner ruling R7(d)), the only source of the owner-minutes metric.
struct MeasureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "measure",
        abstract: "Measure a company: every metric with its denominator over a window (default the last 28 days). Owner shell only.",
        discussion: "Definitions and sources: docs/measure/metrics.md.")

    enum Format: String, ExpressibleByArgument, CaseIterable { case md, json }

    @Argument(help: "Company name or slug.") var company: String
    @Option(help: "Start of the window: a date (YYYY-MM-DD, midnight in the owner's time zone) or 'all' (since the company was created). Default: the last \(MeasureWindow.defaultDays) days.")
    var since: String?
    @Option(help: "md (a table, the default) or json.") var format: Format?
    @Option(name: .customLong("log-owner-minutes"),
            help: "Log minutes of your own time spent on this company (1-\(MeasureRecorder.maxOwnerMinutesPerLog)), added to the day's total; prints no report.")
    var logOwnerMinutes: Int?
    @Option(help: "With --log-owner-minutes: the day the minutes belong to (YYYY-MM-DD in your time zone). Default: today.")
    var day: String?

    func run() throws {
        let owner = try requireOwnerShell(quietly: false)
        let (store, _) = try openStore()
        let c = try resolveCompanyOrExplain(store, company)
        let now = Date()
        if let minutes = logOwnerMinutes {
            // A log is a write, not a report: the report's flags are refused, never silently ignored.
            guard since == nil, format == nil else { throw fail("--log-owner-minutes takes only --day; it prints no report (no --since or --format)") }
            do {
                let dayKey = try MeasureRecorder.ownerLogDay(day, now: now, tz: store.ownerTimeZone())
                try store.logOwnerMinutes(companyId: c.id, minutes: minutes, day: dayKey, owner: owner)
                print(safe("Logged \(minutes) owner minute\(minutes == 1 ? "" : "s") for \(c.name) on \(dayKey)."))
            } catch let error as MeasureError { throw fail("\(error)") } catch let error as WorkError { throw fail("\(error)") }
            return
        }
        guard day == nil else { throw fail("--day is only for --log-owner-minutes") }
        let window: MeasureWindow
        do {
            window = try MeasureWindow.parse(since, now: now, companyCreated: c.createdAt, tz: store.ownerTimeZone())
        } catch { throw fail("\(error)") }
        let git = GitWorkspace(root: URL(fileURLWithPath: c.workspacePath, isDirectory: true))
        let report: MeasureReport
        do { report = try Measure.report(store: store, git: git, companyId: c.id, window: window, now: now) } catch { throw fail("\(error)") }
        switch format ?? .md {
        case .md:
            // Line by line: `safe()` turns newlines into spaces, and the company name is in the header.
            print(safeLines(report.markdown()), terminator: "")
        case .json:
            // JSON escapes every control character itself.
            print(String(decoding: try report.json(), as: UTF8.self))
        }
    }
}

/// Multi-line engine text for the terminal: every line sanitized, the line structure kept.
func safeLines(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false).map { safe(String($0)) }.joined(separator: "\n")
}

/// `resolveCompany`, with an unknown name told what to do: the companies that exist and the command that lists them.
func resolveCompanyOrExplain(_ store: Store, _ query: String) throws -> Company {
    let q = query.lowercased()
    let all = try store.companies()
    if !all.contains(where: { $0.name.lowercased() == q || $0.slug == q }) {
        let hint = all.isEmpty
            ? "no companies exist yet; create one with 'brahma company create <name> --goal <goal>'"
            : "companies: " + all.map { "\($0.name) (\($0.slug))" }.joined(separator: ", ") + "; see 'brahma company list'"
        throw fail("no company named '\(query)'; \(hint)")
    }
    return try resolveCompany(store, query)
}

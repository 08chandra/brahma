import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma measure <company> [--since <YYYY-MM-DD|all>] [--format md|json]` (Plan X6a): the company's metrics over one window,
/// every number with its denominator (`docs/measure/metrics.md`). Read-only, but it reads every agent's records, so it runs only
/// from the owner's shell: never inside an agent turn. The one write: `--log-owner-minutes <n> [--day YYYY-MM-DD]` adds the
/// owner's own time to that day's counter (owner ruling R7(d)), the only source of the owner-minutes metric.
/// `--verify-landings` (Task 6): the landing audit of `main`'s first-parent history (`LandingAudit`); exit 0 when every commit is
/// verified, owner-accepted or imported, 1 otherwise.
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
    @Flag(name: .customLong("verify-landings"),
          help: "Audit main instead of reporting: every first-parent commit back to the company's first must be a verified queue landing, owner-accepted or imported (exit 0), else each unverified commit is listed (exit 1). With --since <date>: from the last landing before it.")
    var verifyLandings = false

    func run() throws {
        let owner = try requireOwnerShell(quietly: false)
        let (store, paths) = try openStore()
        let c: Company
        do { c = try resolveCompanyOrExplain(store, company) } catch let exit as ExitCode {
            // The audit's exit 2 is "could not audit" (ruling R38); the message is already printed.
            throw verifyLandings ? ExitCode(Self.couldNotAudit) : exit
        }
        let now = Date()
        // The audit is read-only: the write flags are refused with it, never silently ignored.
        guard !verifyLandings || (logOwnerMinutes == nil && day == nil) else {
            _ = fail("--verify-landings is a read-only audit; it takes no --log-owner-minutes or --day")
            throw ExitCode(Self.couldNotAudit)
        }
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
        if verifyLandings { return try audit(store, c, paths: paths, now: now) }
        let window: MeasureWindow
        do {
            window = try MeasureWindow.parse(since, now: now, companyCreated: c.createdAt, tz: store.ownerTimeZone())
        } catch { throw fail("\(error)") }
        let git = GitWorkspace(root: URL(fileURLWithPath: c.workspacePath, isDirectory: true), exportHome: paths.home)
        let report: MeasureReport
        do { report = try Measure.report(store: store, git: git, companyId: c.id, window: window, now: now) } catch { throw fail("\(error)") }
        switch format ?? .md {
        case .md:
            // Line by line: `safe()` turns newlines into spaces, and the company name is in the header.
            print(terminalEscaped(safeLines(report.markdown())), terminator: "")
        case .json:
            // JSON escapes C0 controls itself, but not DEL, C1, line separators or bidi controls: those are escaped here.
            print(terminalEscaped(String(decoding: try report.json(), as: UTF8.self)))
        }
    }
}

extension MeasureCommand {
    /// The audit's exit code when it could not audit (ruling R38): no main, an unknown company, a git failure, planted history
    /// files, a merge batch moving `main`, a bad `--since`. 0 is every commit classified; 1 is unverified commits or a bounded
    /// walk.
    static let couldNotAudit: Int32 = 2

    /// `--verify-landings`: the audit's lines through `safe()` (commit subjects are agent-controlled), or its JSON with the
    /// subjects sanitized; either way the scalars `safe()` keeps but a terminal acts on are escaped (`terminalEscaped`).
    func audit(_ store: Store, _ c: Company, paths: BrahmaPaths, now: Date) throws {
        var since: Date?
        if let raw = self.since, raw != "all" {
            do {
                since = try MeasureWindow.parse(raw, now: now, companyCreated: c.createdAt, tz: store.ownerTimeZone()).since
            } catch { _ = fail("\(error)"); throw ExitCode(Self.couldNotAudit) }
        }
        let git = GitWorkspace(root: URL(fileURLWithPath: c.workspacePath, isDirectory: true), exportHome: paths.home)
        var result: LandingAuditResult
        do { result = try LandingAudit.run(store: store, git: git, companyId: c.id, since: since) } catch {
            _ = fail("\(error)")
            throw ExitCode(Self.couldNotAudit)
        }
        switch format ?? .md {
        case .md:
            for line in result.lines() { print(terminalEscaped(safe(line))) }
        case .json:
            result.subjects = result.subjects.mapValues(TerminalText.sanitize)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(terminalEscaped(String(decoding: try encoder.encode(result), as: UTF8.self)))
        }
        guard result.allClassified else { throw ExitCode.failure }
    }
}

/// Scalars a terminal may act on that JSON leaves raw and `safe()` does not touch: DEL and C1 controls, the line and paragraph
/// separators, bidi embeddings, overrides and isolates.
func isTerminalHazard(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x7F...0x9F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069: return true
    default: return false
    }
}

/// `text` with every `isTerminalHazard` scalar written as `\uXXXX`: inert on a terminal, and inside a JSON string the same
/// character after decoding.
func terminalEscaped(_ text: String) -> String {
    var out = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
        if isTerminalHazard(scalar) { out.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars) } else { out.append(scalar) }
    }
    return String(out)
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

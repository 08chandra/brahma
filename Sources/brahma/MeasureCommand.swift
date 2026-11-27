import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma measure <company> [--since <YYYY-MM-DD|all>] [--format md|json]` (Plan X6a): the company's metrics over one window,
/// every number with its denominator (`docs/measure/metrics.md`). Read-only, but it reads every agent's records, so it runs only
/// from the owner's shell: never inside an agent turn. The one write: `--log-owner-minutes <n> [--day YYYY-MM-DD]` adds the
/// owner's own time to that day's counter (owner ruling R7(d)), the only source of the owner-minutes metric.
/// `--verify-landings` (Task 6): the landing audit of `main`'s first-parent history (`LandingAudit`); exit 0 when every commit is
/// verified, owner-accepted or imported, 1 otherwise.
/// Task 7: `--mission` (the mission subset), `--compare <baseline>` (the single-agent baseline side by side, ruling R7(e)),
/// `--soak-checkpoint <file>` and `--soak-verify <file>` (the soak harness; `scripts/soak/run-72h.sh` runs them). The modes are
/// exclusive (`--mission --compare` excepted); a combination is refused with exit 2. `--print-day` prints today in the owner's
/// time zone, the day `--since` reads (the soak script records its start day with it).
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
    @Flag(help: "Only the mission subset: items landed, owner touches, usage per landed item, green-main, turns wasted on rate limits, reserve breaches, idle while actionable.")
    var mission = false
    @Option(help: "A baseline company (a one-agent company run on the same backlog) shown beside this one: the same window and metrics, each with its own denominator. A missing baseline, or one with no landings in the window, is 'not measured'.")
    var compare: String?
    @Option(name: .customLong("soak-checkpoint"),
            help: "Soak harness: write this company's checkpoint (main, item branches, leases, releases, open merges, running turns) to <file> (0600), in a directory that exists.")
    var soakCheckpoint: String?
    @Option(name: .customLong("soak-verify"),
            help: "Soak harness: judge the company now against the checkpoint in <file>: exit 0 pass, 1 fail, 3 wait (the engine is not running or has not settled), 2 could not verify.")
    var soakVerify: String?
    @Flag(name: .customLong("print-day"),
          help: "Print today's date (YYYY-MM-DD) in your time zone, the zone --since reads, and nothing else.")
    var printDay = false

    /// The audit and the soak modes say "could not run" with exit 2 (ruling R38): their exit 1 means unverified or failed.
    var exitTwoMode: Bool { verifyLandings || soakCheckpoint != nil || soakVerify != nil || printDay }

    func run() throws {
        // Combinations are refused before anything is read or written.
        if let refusal = modeRefusal() {
            _ = fail(refusal)
            throw ExitCode(Self.couldNotAudit)
        }
        let owner: OwnerPrincipal
        let store: Store, paths: BrahmaPaths
        do {
            owner = try requireOwnerShell(quietly: false)
            (store, paths) = try openStore()
        } catch let exit as ExitCode {
            // Task 6 review #14: under the audit (and the soak modes) a refusal or an unopenable store is "could not run".
            throw exitTwoMode ? ExitCode(Self.couldNotAudit) : exit
        } catch {
            guard exitTwoMode else { throw error }
            _ = fail("\(error)")
            throw ExitCode(Self.couldNotAudit)
        }
        let c: Company
        do { c = try resolveCompanyOrExplain(store, company) } catch let exit as ExitCode {
            // The audit's exit 2 is "could not audit" (ruling R38); the message is already printed.
            throw exitTwoMode ? ExitCode(Self.couldNotAudit) : exit
        }
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
        if printDay {
            print(Store.measureDay(now, in: store.ownerTimeZone()))
            return
        }
        if verifyLandings { return try audit(store, c, paths: paths, now: now) }
        if let file = soakCheckpoint { return try checkpoint(store, c, paths: paths, file: file, now: now) }
        if let file = soakVerify { return try soak(store, c, paths: paths, file: file, now: now) }
        let window: MeasureWindow
        do {
            window = try MeasureWindow.parse(since, now: now, companyCreated: c.createdAt, tz: store.ownerTimeZone())
        } catch { throw fail("\(error)") }
        func measure(_ company: Company) throws -> MeasureReport {
            let git = GitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), exportHome: paths.home)
            return mission ? try MissionReport.make(store: store, git: git, companyId: company.id, window: window, now: now)
                : try Measure.report(store: store, git: git, companyId: company.id, window: window, now: now)
        }
        let report: MeasureReport
        do { report = try measure(c) } catch { throw fail("\(error)") }
        if let baseline = compare { return try compareWith(store, c, report: report, baseline: baseline, measure: measure) }
        switch format ?? .md {
        case .md:
            // Line by line: `safe()` turns newlines into spaces, and the company name is in the header.
            print(terminalEscaped(safeLines(report.markdown())), terminator: "")
        case .json:
            // JSON escapes C0 controls itself, but not DEL, C1, line separators or bidi controls: those are escaped here.
            print(terminalEscaped(String(decoding: try report.json(), as: UTF8.self)))
        }
    }

    /// Why this combination of modes and flags is refused, or nil. The modes (`--verify-landings`, `--log-owner-minutes`,
    /// `--soak-checkpoint`, `--soak-verify`, `--mission`, `--compare`) are exclusive, except `--mission --compare` (the mission
    /// subset side by side); each refuses the flags it would ignore.
    func modeRefusal() -> String? {
        var modes: [String] = []
        if verifyLandings { modes.append("--verify-landings") }
        if logOwnerMinutes != nil { modes.append("--log-owner-minutes") }
        if soakCheckpoint != nil { modes.append("--soak-checkpoint") }
        if soakVerify != nil { modes.append("--soak-verify") }
        if mission { modes.append("--mission") }
        if compare != nil { modes.append("--compare") }
        if printDay { modes.append("--print-day") }
        if modes.count > 1, Set(modes) != ["--mission", "--compare"] {
            if verifyLandings, logOwnerMinutes != nil, modes.count == 2 {
                return "--verify-landings is a read-only audit; it takes no --log-owner-minutes or --day"
            }
            return "\(modes.joined(separator: " and ")) cannot be combined"
        }
        if verifyLandings, day != nil { return "--verify-landings is a read-only audit; it takes no --log-owner-minutes or --day" }
        if soakCheckpoint != nil, since != nil || format != nil || day != nil {
            return "--soak-checkpoint writes a file and prints one line; it takes no --since, --format or --day"
        }
        if soakVerify != nil, since != nil || day != nil { return "--soak-verify judges the company now; it takes no --since or --day" }
        if mission || compare != nil, day != nil { return "--day is only for --log-owner-minutes" }
        if printDay, since != nil || format != nil || day != nil { return "--print-day prints one date; it takes no --since, --format or --day" }
        return nil
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
            let data: Data
            do { data = try encoder.encode(result) } catch {
                // Task 6 review #14: an output that cannot be made is "could not audit".
                _ = fail("\(error)")
                throw ExitCode(Self.couldNotAudit)
            }
            print(terminalEscaped(String(decoding: data, as: UTF8.self)))
        }
        guard result.allClassified else { throw ExitCode.failure }
    }

    /// `--soak-checkpoint <file>`: the checkpoint written 0600 into the directory the owner named; one line printed. Anything
    /// that stops it is exit 2.
    func checkpoint(_ store: Store, _ c: Company, paths: BrahmaPaths, file: String, now: Date) throws {
        let url = URL(fileURLWithPath: file).standardizedFileURL
        let git = GitWorkspace(root: URL(fileURLWithPath: c.workspacePath, isDirectory: true), exportHome: paths.home)
        let cp: SoakCheckpoint
        do {
            cp = try SoakCheckpoint.take(store: store, git: git, companyId: c.id, now: now, engineStartedAt: try SoakEngine.startedAt(paths: paths))
            try cp.write(to: url)
        } catch {
            _ = fail("\(error)")
            throw ExitCode(Self.couldNotAudit)
        }
        let engine = cp.engineStartedAt.map { "engine started \(MeasureReport.iso($0))" } ?? "no engine running"
        print(terminalEscaped(safe("soak checkpoint written: \(url.path) (main \(cp.mainTip.prefix(7)); \(cp.itemHeads.count) item branches, "
                                   + "\(cp.verifiedCommits.count) verified commits, \(cp.leases.count) leases, \(cp.openBatches.count) open merge batches, "
                                   + "\(cp.runningTurns.count) running turns; \(engine))")))
    }

    /// `--soak-verify <file>`: the seven checks, one line each (or the verdict as JSON). Exit 0 pass, 1 fail, 3 wait, 2 when it
    /// could not verify (no such file, another company's checkpoint, a store or git error).
    func soak(_ store: Store, _ c: Company, paths: BrahmaPaths, file: String, now: Date) throws {
        let url = URL(fileURLWithPath: file).standardizedFileURL
        let git = GitWorkspace(root: URL(fileURLWithPath: c.workspacePath, isDirectory: true), exportHome: paths.home)
        let verdict: SoakVerdict
        var output = ""
        do {
            let before = try SoakCheckpoint.read(from: url)
            guard before.companyId == c.id else { throw MeasureError.checkpointOfAnotherCompany(c.name) }
            verdict = try SoakVerify.run(before, store: store, git: git, now: now, engineStartedAt: try SoakEngine.startedAt(paths: paths),
                                         settle: SoakVerify.settle(environment: ProcessInfo.processInfo.environment))
            switch format ?? .md {
            case .md: output = verdict.lines().map { terminalEscaped(safe($0)) }.joined(separator: "\n") + "\n"
            case .json: output = terminalEscaped(String(decoding: try verdict.json(), as: UTF8.self)) + "\n"
            }
        } catch {
            _ = fail("\(error)")
            throw ExitCode(Self.couldNotAudit)
        }
        print(output, terminator: "")
        switch verdict.result {
        case .pass: return
        case .fail: throw ExitCode.failure
        case .wait: throw ExitCode(SoakVerify.waitExitCode)
        }
    }

    /// `--compare <baseline>`: both reports over this one's window, side by side (`MeasureComparison`). Comparing a company with
    /// itself is refused (exit 2).
    func compareWith(_ store: Store, _ c: Company, report: MeasureReport, baseline: String,
                     measure: (Company) throws -> MeasureReport) throws {
        if let same = try MeasureComparison.baselineCompany(store, baseline), same.id == c.id {
            _ = fail("--compare needs another company than \(c.name): the baseline is a one-agent company run on the same backlog")
            throw ExitCode(Self.couldNotAudit)
        }
        let both: MeasureComparison
        do { both = try MeasureComparison.make(store: store, report: report, baselineName: baseline, measure: measure) } catch { throw fail("\(error)") }
        switch format ?? .md {
        case .md: print(terminalEscaped(safeLines(both.markdown())), terminator: "")
        case .json: print(terminalEscaped(String(decoding: try both.json(), as: UTF8.self)))
        }
    }
}

/// Scalars a terminal may act on that JSON leaves raw and `safe()` does not touch: DEL and C1 controls, the line and paragraph
/// separators, bidi embeddings, overrides and isolates, and the bidi marks (U+200E, U+200F, the Arabic letter mark U+061C).
func isTerminalHazard(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x7F...0x9F, 0x061C, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069: return true
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

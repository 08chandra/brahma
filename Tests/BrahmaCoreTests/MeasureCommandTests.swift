import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

/// `brahma measure <co> [--since <date|all>] [--format md|json]` (Plan X6a Task 1): read-only, refused inside an agent turn, its
/// JSON decodes back to the report, an unknown company is told what to do.
@Suite(.scratch) struct MeasureCommandTests {
    struct Rig {
        let owner: OwnerTestHome
        let store: Store
        let company: Company
        var home: URL { owner.url }

        init() throws {
            owner = try OwnerTestHome()
            let made = try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: owner.url)
            #expect(made.status == 0, "\(made.stderr)")
            store = try Store(path: ownerPaths(owner.url).database.path)
            // The owner's zone is what `--since` reads; pinned so the dates below are exact.
            try store.setOwnerTimeZone("UTC")
            company = try #require(try store.companies().first)
        }
    }

    @Test func markdownAndJSON() throws {
        let rig = try Rig()
        let md = try brahma(["measure", "Acme"], home: rig.home)
        #expect(md.status == 0, "\(md.stderr)")
        #expect(md.stdout.hasPrefix("# measure Acme — "), "\(md.stdout)")
        // Every metric is built (Tasks 3–5): with nothing landed and nothing recorded each says so.
        let built = Set(MetricId.all)
        for id in MetricId.all where !built.contains(id) { #expect(md.stdout.contains("| \(id.label) | not applicable: not built yet |"), "\(id.rawValue)") }
        #expect(md.stdout.contains("| \(MetricId.greenMain.label) | not measured: no landings in the window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.firstPass.label) | not measured: no landings in the window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.queueHealth.label) | 0 |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.revertRate.label) | not measured: no landings in the window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.reviewCatch.label) | not measured: no landings or review events in the window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.escapeRate.label) | not measured: no landings in the window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.usagePerLanded.label) | not measured: no landings in the window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.ownerTouches.label) | not measured: no landings in the window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.safety.label) | 0 (target 0) |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.nonCode.label) | not applicable: landGate items and rubric checks absent |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.modelRanking.label) | not measured: no landings in the window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.idleActionable.label) | not measured: no active-seconds records in window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.itemsPerDollar.label) | not measured: no landings in the window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.itemsPerPlanHour.label) | not measured: no active-seconds records in window |"), "\(md.stdout)")
        #expect(md.stdout.contains("| \(MetricId.ownerMinutes.label) | not measured: no owner-time records |"), "\(md.stdout)")
        #expect(md.stdout.contains("docs/measure/metrics.md"))
        #expect(md.stdout.split(separator: "\n").count > 15, "the table is printed line by line, not flattened")

        let js = try brahma(["measure", "acme", "--format", "json"], home: rig.home)
        #expect(js.status == 0, "\(js.stderr)")
        let data = Data(js.stdout.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let report = try MeasureReport.decode(data)
        #expect(report.company == "Acme" && report.companyId == rig.company.id)
        #expect(report.metrics.map(\.id) == MetricId.all)
        #expect(report.metrics.filter { !built.contains($0.id) }.allSatisfy { $0.status == .notApplicable(reason: "not built yet") })
        #expect(report.metrics.first { $0.id == .greenMain }?.status == .notMeasured(reason: "no landings in the window"))
        #expect(report.metrics.first { $0.id == .queueHealth }?.status == .ok)
        #expect(report.metrics.first { $0.id == .revertRate }?.status == .notMeasured(reason: "no landings in the window"))
        #expect(report.metrics.first { $0.id == .reviewCatch }?.status == .notMeasured(reason: "no landings or review events in the window"))
        #expect(report.metrics.first { $0.id == .escapeRate }?.status == .notMeasured(reason: "no landings in the window"))
        #expect(report.metrics.first { $0.id == .ownerMinutes }?.status == .notMeasured(reason: "no owner-time records"))
        #expect(report.metrics.first { $0.id == .nonCode }?.status == .notApplicable(reason: "landGate items and rubric checks absent"))
        #expect(!report.metrics.contains { $0.status == .notApplicable(reason: "not built yet") })
        #expect(["UTC", "GMT"].contains(report.timeZone), "Foundation names the UTC zone GMT: \(report.timeZone)")
        // The JSON decodes back to the same report: re-encoding it gives the same bytes, and decoding those the same value.
        let again = try report.json()
        #expect(again == data)
        #expect(try MeasureReport.decode(again) == report)
        // The table rows are the same in both formats (the header carries the run's own generation time).
        let mdRows = md.stdout.split(separator: "\n").filter { $0.hasPrefix("|") }
        let jsRows = report.markdown().split(separator: "\n").filter { $0.hasPrefix("|") }
        #expect(mdRows == jsRows)
    }

    @Test func sinceParses() throws {
        let rig = try Rig()
        func window(_ args: [String]) throws -> MeasureWindow {
            let r = try brahma(["measure", "Acme", "--format", "json"] + args, home: rig.home)
            #expect(r.status == 0, "\(args): \(r.stderr)")
            return try MeasureReport.decode(Data(r.stdout.utf8)).window
        }
        let day = try window(["--since", "2025-11-01"])
        #expect(day.since == Date(timeIntervalSince1970: 1_761_955_200), "midnight UTC on 2025-11-01") // 2025-11-01T00:00:00Z
        #expect(day.until > day.since)
        let all = try window(["--since", "all"])
        #expect(all.since == Date(timeIntervalSince1970: rig.company.createdAt.timeIntervalSince1970.rounded(.down)))
        let dflt = try window([])
        #expect(abs(dflt.until.timeIntervalSince(dflt.since) - 28 * 86_400) < 1)
        // The markdown header shows the window in the owner's zone.
        let md = try brahma(["measure", "Acme", "--since", "2025-11-01"], home: rig.home)
        #expect(md.stdout.hasPrefix("# measure Acme — 2025-11-01 00:00…"), "\(md.stdout)")
        // Refused: not a date, a date in the future. Nothing is printed on stdout.
        for bad in ["2025-13-45", "yesterday", "2999-01-01", ""] {
            let r = try brahma(["measure", "Acme", "--since", bad], home: rig.home)
            #expect(r.status == 1, "\(bad)")
            #expect(r.stderr.contains("--since") && r.stderr.contains("'\(bad)'"), "\(bad): \(r.stderr)")
            #expect(r.stdout.isEmpty)
        }
    }

    @Test func refusedInsideAgentTurn() throws {
        let rig = try Rig()
        let r = try brahma(["measure", "Acme"], home: rig.home, env: ["BRAHMA_AGENT_ID": "a1"])
        #expect(r.status == 1)
        #expect(r.stderr.contains("owner commands can't run inside an agent turn"), "\(r.stderr)")
        #expect(r.stdout.isEmpty)
        let nokey = try OwnerTestHome(initOwner: false)
        let k = try brahma(["measure", "Acme"], home: nokey.url)
        #expect(k.status == 1 && k.stderr.contains("owner key missing or invalid"), "\(k.stderr)")
    }

    /// `--log-owner-minutes <n> [--day YYYY-MM-DD]` (owner ruling R7(d)): the owner's own time, the one write `measure` makes. It
    /// adds to that day's counter and the report then reads it; refused inside an agent turn; a bad day or count is refused and
    /// writes nothing.
    @Test func logOwnerMinutesThenMeasure() throws {
        let rig = try Rig()
        let before = try brahma(["measure", "Acme", "--format", "json", "--since", "all"], home: rig.home)
        #expect(try MeasureReport.decode(Data(before.stdout.utf8)).metrics.first { $0.id == .ownerMinutes }?.status
                == .notMeasured(reason: "no owner-time records"))

        let today = Store.measureDay(Date(), in: TimeZone(identifier: "UTC")!)
        let logged = try brahma(["measure", "Acme", "--log-owner-minutes", "25"], home: rig.home)
        #expect(logged.status == 0, "\(logged.stderr)")
        #expect(logged.stdout.contains("Logged 25 owner minutes for Acme on \(today)"), "\(logged.stdout)")
        let dated = try brahma(["measure", "Acme", "--log-owner-minutes", "5", "--day", today], home: rig.home)
        #expect(dated.status == 0, "\(dated.stderr)")
        #expect(try store(rig).counters(companyId: rig.company.id, name: MeasureCounter.ownerInterventionSeconds,
                                         in: MeasureWindow(since: rig.company.createdAt, until: Date().addingTimeInterval(86_400))) == 30 * 60)

        // The report reads the log: no landing yet, so not measured with the minutes in the detail.
        let after = try brahma(["measure", "Acme", "--format", "json", "--since", "all"], home: rig.home)
        let metric = try #require(try MeasureReport.decode(Data(after.stdout.utf8)).metrics.first { $0.id == .ownerMinutes })
        #expect(metric.status == .notMeasured(reason: "no landings in the window"))
        #expect(metric.detail.first { $0.label == "owner minutes logged" }?.numerator == 30)

        // Refused: inside an agent turn; zero or negative minutes; a malformed or future day; --day alone.
        let agent = try brahma(["measure", "Acme", "--log-owner-minutes", "5"], home: rig.home, env: ["BRAHMA_AGENT_ID": "a1"])
        #expect(agent.status == 1 && agent.stderr.contains("owner commands can't run inside an agent turn"), "\(agent.stderr)")
        for bad in [["--log-owner-minutes", "0"], ["--log-owner-minutes", "-3"], ["--log-owner-minutes", "5", "--day", "2026-13-01"],
                    ["--log-owner-minutes", "5", "--day", "2999-01-01"], ["--day", today],
                    ["--log-owner-minutes", "5", "--format", "json"], ["--log-owner-minutes", "5", "--format", "md"],
                    ["--log-owner-minutes", "5", "--since", "all"]] {
            let r = try brahma(["measure", "Acme"] + bad, home: rig.home)
            #expect(r.status != 0, "\(bad)")
            #expect(r.stdout.isEmpty, "\(bad): \(r.stdout)")
        }
        #expect(try store(rig).counters(companyId: rig.company.id, name: MeasureCounter.ownerInterventionSeconds,
                                         in: MeasureWindow(since: rig.company.createdAt, until: Date().addingTimeInterval(86_400))) == 30 * 60)
    }

    /// `--verify-landings` (Task 6): exit 0 when every first-parent commit of `main` is verified, owner-accepted or imported;
    /// exit 1, listing each unverified commit by short sha and subject, otherwise. The subject is agent-controlled: terminal
    /// escapes in it are neutralised. The flag takes no write flags with it.
    @Test func verifyLandingsExitCodes() throws {
        let rig = try Rig()
        let clean = try brahma(["measure", "Acme", "--verify-landings"], home: rig.home)
        #expect(clean.status == 0, "\(clean.stderr)")
        #expect(clean.stdout == "landings verified: none to verify (0/0); owner-accepted 0; imported 1\n", "\(clean.stdout)")
        let js = try brahma(["measure", "Acme", "--verify-landings", "--format", "json", "--since", "all"], home: rig.home)
        #expect(js.status == 0, "\(js.stderr)")
        let decoded = try JSONDecoder().decode(LandingAuditResult.self, from: Data(js.stdout.utf8))
        #expect(decoded.commits == 1 && decoded.imported.count == 1 && decoded.unverified.isEmpty, "\(decoded)")

        // A commit made straight on main, outside the queue, its subject carrying terminal escapes.
        let ws = URL(fileURLWithPath: rig.company.workspacePath, isDirectory: true)
        try "outside\n".write(to: ws.appending(path: "outside.txt"), atomically: true, encoding: .utf8)
        try GitFixture.plainGit(["add", "--", "outside.txt"], in: ws)
        try GitFixture.plainGit(["commit", "-q", "--no-verify", "-m", "sneak \u{1b}[2J\u{1b}]0;owned\u{07}in"], in: ws)
        let sha = try GitFixture.plainGit(["rev-parse", "HEAD"], in: ws)
        let dirty = try brahma(["measure", "Acme", "--verify-landings"], home: rig.home)
        #expect(dirty.status == 1, "\(dirty.stdout) \(dirty.stderr)")
        #expect(dirty.stdout.hasPrefix("landings verified: 0% (0/1); owner-accepted 0; imported 1\n"), "\(dirty.stdout)")
        #expect(dirty.stdout.contains("unverified: \(sha.prefix(7)) sneak"), "\(dirty.stdout)")
        #expect(!dirty.stdout.contains("\u{1b}") && !dirty.stdout.contains("\u{07}"), "escapes reach the terminal: \(dirty.stdout.debugDescription)")

        // Refused, exit 2 (could not audit): with the write flags, a bad --since, an unknown company. Nothing on stdout.
        for bad in [["--log-owner-minutes", "5"], ["--day", "2025-11-01"]] {
            let r = try brahma(["measure", "Acme", "--verify-landings"] + bad, home: rig.home)
            #expect(r.status == 2 && r.stdout.isEmpty, "\(bad): \(r.stdout)")
            #expect(r.stderr.contains("--verify-landings"), "\(bad): \(r.stderr)")
        }
        let badSince = try brahma(["measure", "Acme", "--verify-landings", "--since", "yesterday"], home: rig.home)
        #expect(badSince.status == 2 && badSince.stdout.isEmpty && badSince.stderr.contains("--since"), "\(badSince.stderr)")
        let unknown = try brahma(["measure", "Nope", "--verify-landings"], home: rig.home)
        #expect(unknown.status == 2 && unknown.stdout.isEmpty && unknown.stderr.contains("no company named 'Nope'"), "\(unknown.stderr)")
        let agent = try brahma(["measure", "Acme", "--verify-landings"], home: rig.home, env: ["BRAHMA_AGENT_ID": "a1"])
        #expect(agent.status == 1 && agent.stderr.contains("owner commands can't run inside an agent turn") && agent.stdout.isEmpty)
        #expect(try brahma(["measure", "--help"], home: rig.home).stdout.contains("--verify-landings"))
    }

    /// `--verify-landings --since <date>` (review #9): with no landing before the date the walk still reaches the first commit;
    /// a planted `.git/shallow` is refused with exit 2 (review #2, ruling R38).
    @Test func verifyLandingsSinceAndPlantedHistory() throws {
        let rig = try Rig()
        let since = try brahma(["measure", "Acme", "--verify-landings", "--since", "2025-11-01"], home: rig.home)
        #expect(since.status == 0 && since.stdout == "landings verified: none to verify (0/0); owner-accepted 0; imported 1\n",
                "\(since.stdout) \(since.stderr)")
        let ws = URL(fileURLWithPath: rig.company.workspacePath, isDirectory: true)
        let root = try GitFixture.plainGit(["rev-parse", "refs/heads/main"], in: ws)
        let shallow = ws.appending(path: ".git/shallow")
        try "\(root)\n".write(to: shallow, atomically: true, encoding: .utf8)
        let refused = try brahma(["measure", "Acme", "--verify-landings"], home: rig.home)
        #expect(refused.status == 2 && refused.stdout.isEmpty, "\(refused.stdout)")
        #expect(refused.stderr.contains("shallow"), "\(refused.stderr)")
        #expect(FileManager.default.fileExists(atPath: shallow.path))
    }

    /// X6a-2 / review #3: a subject carrying ESC, CSI (U+009B), DEL and a bidi override (U+202E) reaches neither the markdown nor
    /// the JSON raw: C0/C1/DEL become spaces, the bidi override is written `\u202e`; the JSON still decodes.
    @Test func verifyLandingsEscapesSubjects() throws {
        let rig = try Rig()
        let ws = URL(fileURLWithPath: rig.company.workspacePath, isDirectory: true)
        try "x\n".write(to: ws.appending(path: "x.txt"), atomically: true, encoding: .utf8)
        try GitFixture.plainGit(["add", "--", "x.txt"], in: ws)
        try GitFixture.plainGit(["commit", "-q", "--no-verify", "-m", "a\u{1b}[31mb\u{9b}2Jc\u{7f}d\u{202e}gnp.exe"], in: ws)
        let hazards: [Character] = ["\u{1b}", "\u{9b}", "\u{7f}", "\u{202e}"]
        let md = try brahma(["measure", "Acme", "--verify-landings"], home: rig.home)
        #expect(md.status == 1)
        #expect(!hazards.contains { md.stdout.contains($0) }, "\(md.stdout.debugDescription)")
        #expect(md.stdout.contains("a [31mb 2Jc d\\u202egnp.exe"), "\(md.stdout.debugDescription)")
        let js = try brahma(["measure", "Acme", "--verify-landings", "--format", "json"], home: rig.home)
        #expect(js.status == 1)
        #expect(!hazards.contains { js.stdout.contains($0) }, "\(js.stdout.debugDescription)")
        let decoded = try JSONDecoder().decode(LandingAuditResult.self, from: Data(js.stdout.utf8))
        #expect(decoded.subjects.values.first == "a [31mb 2Jc d\u{202e}gnp.exe", "\(decoded.subjects)")
    }

    /// A fresh handle on the rig's database (the CLI wrote through its own).
    func store(_ rig: Rig) throws -> Store { try Store(path: ownerPaths(rig.home).database.path) }

    @Test func unknownCompanyIsActionable() throws {
        let rig = try Rig()
        let r = try brahma(["measure", "Nope"], home: rig.home)
        #expect(r.status == 1)
        #expect(r.stderr.hasPrefix("brahma: "), "\(r.stderr)")
        #expect(r.stderr.contains("no company named 'Nope'"), "\(r.stderr)")
        // It names the companies that exist and the command that lists them.
        #expect(r.stderr.contains("Acme"), "\(r.stderr)")
        #expect(r.stderr.contains("brahma company list"), "\(r.stderr)")
        #expect(r.stdout.isEmpty)
        // The help lists the command.
        #expect(try brahma(["--help"], home: rig.home).stdout.contains("measure"))
        let h = try brahma(["measure", "--help"], home: rig.home)
        #expect(h.status == 0 && h.stdout.contains("--since") && h.stdout.contains("--format") && h.stdout.contains("--log-owner-minutes"), "\(h.stdout)")
    }
}

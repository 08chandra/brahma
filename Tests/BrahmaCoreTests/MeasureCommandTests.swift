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

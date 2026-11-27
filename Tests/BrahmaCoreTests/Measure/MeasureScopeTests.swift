import Foundation
import Testing
@testable import BrahmaCore

/// Every `measure` query is company-scoped (Plan X6a): a second company sharing the database never changes the first one's
/// numbers. Store-only: the companies' workspace paths do not exist (git-derived metrics are stubbed until Task 3; their git leg is
/// `MeasureScopeGitTests`).
@Suite(.scratch) struct MeasureScopeTests {
    /// `acme` alone, then `acme` beside a `zeta` with twice as many landed items: every metric of `acme` (id, label, status,
    /// numerator, denominator, basis, detail) is equal between the two runs.
    @Test func otherCompanyNeverCounted() throws {
        let now = MeasureFixtures.t0
        let window = try MeasureWindow.parse("all", now: now, companyCreated: now.addingTimeInterval(-30 * 86_400), tz: TimeZone(identifier: "UTC")!)

        let alone = try Store.inMemory()
        let acme1 = try MeasureFixtures.seed(alone, name: "Acme", landed: 24, now: now)
        let single = try Measure.report(store: alone, git: GitWorkspace(root: URL(fileURLWithPath: acme1.workspacePath)),
                                        companyId: acme1.id, window: window, now: now)

        let shared = try Store.inMemory()
        let acme2 = try MeasureFixtures.seed(shared, name: "Acme", landed: 24, now: now)
        let zeta = try MeasureFixtures.seed(shared, name: "Zeta", landed: 48, now: now)
        #expect(try shared.companies().count == 2)
        let both = try Measure.report(store: shared, git: GitWorkspace(root: URL(fileURLWithPath: acme2.workspacePath)),
                                      companyId: acme2.id, window: window, now: now)
        // The fixture's landed items look landed: done, with their landing time and merged commit, nothing actionable.
        let landed = try shared.workItems(companyId: acme2.id)
        #expect(landed.count == 24)
        #expect(landed.allSatisfy { $0.status == .done && $0.doneAt != nil && $0.mergedCommit != nil && $0.mergeState == .none && $0.leaseHeadCommit == nil })

        #expect(both.metrics == single.metrics)
        #expect(both.metrics.map(\.id) == MetricId.all)
        #expect(both.company == "Acme" && both.companyId == acme2.id)
        // Zeta's own report is scoped the same way: the frame is the same shape, the company is Zeta's.
        let z = try Measure.report(store: shared, git: GitWorkspace(root: URL(fileURLWithPath: zeta.workspacePath)),
                                   companyId: zeta.id, window: window, now: now)
        #expect(z.company == "Zeta" && z.companyId == zeta.id)
        #expect(z.metrics.map(\.id) == MetricId.all)
    }

    @Test func reportFrameNamesEveryMetricInOrder() throws {
        let now = MeasureFixtures.t0
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let window = try MeasureWindow.parse(nil, now: now, companyCreated: acme.createdAt, tz: TimeZone(identifier: "UTC")!)
        let r = try Measure.report(store: store, git: GitWorkspace(root: URL(fileURLWithPath: acme.workspacePath)),
                                   companyId: acme.id, window: window, now: now)
        #expect(r.metrics.map(\.id) == MetricId.all)
        #expect(r.metrics.map(\.label) == MetricId.all.map(\.label))
        // Task 1 ships the frame: a metric not built yet says so, with its reason. Task 3's three are built.
        let built: Set<MetricId> = [.greenMain, .firstPass, .queueHealth]
        for m in r.metrics where !built.contains(m.id) {
            #expect(m.status == .notApplicable(reason: "not built yet"), "\(m.id.rawValue)")
            #expect(m.display == "not applicable: not built yet")
        }
        for m in r.metrics where built.contains(m.id) { #expect(m.status != .notApplicable(reason: "not built yet"), "\(m.id.rawValue)") }
        #expect(r.window == window && r.generatedAt == now)
        #expect(!r.brahmaBuild.isEmpty)
        // The markdown names the company, every metric, and the definitions page.
        let md = r.markdown()
        #expect(md.hasPrefix("# measure Acme — "), "\(md)")
        for id in MetricId.all where !built.contains(id) { #expect(md.contains("| \(id.label) | not applicable: not built yet |"), "\(id.rawValue)") }
        for id in built { #expect(md.contains("| \(id.label) | "), "\(id.rawValue)") }
        #expect(md.contains("docs/measure/metrics.md"))
        // JSON round-trips to an equal report.
        let encoded = try r.json()
        let back = try MeasureReport.decode(encoded)
        #expect(back == r)
    }

    /// The report's function table names every metric id (a new id cannot be forgotten); an id outside `all` is `not built yet`.
    @Test func everyMetricIdHasAFunction() throws {
        for id in MetricId.all { #expect(Measure.functions[id] != nil, "\(id.rawValue)") }
        #expect(Measure.functions.count == MetricId.all.count)
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let window = try MeasureWindow.parse("all", now: MeasureFixtures.t0, companyCreated: acme.createdAt, tz: TimeZone(identifier: "UTC")!)
        let ctx = MeasureContext(store: store, git: GitWorkspace(root: URL(fileURLWithPath: acme.workspacePath)), company: acme,
                                 window: window, now: MeasureFixtures.t0)
        let stray = MetricId(rawValue: "stray")
        #expect(try Measure.function(for: stray)(ctx).status == .notApplicable(reason: "not built yet"))
    }

    @Test func unknownCompanyIsAnError() throws {
        let store = try Store.inMemory()
        let window = try MeasureWindow.parse("all", now: MeasureFixtures.t0, companyCreated: MeasureFixtures.t0, tz: .current)
        #expect(throws: MeasureError.self) {
            try Measure.report(store: store, git: GitWorkspace(root: URL(fileURLWithPath: "/nonexistent")), companyId: "nope",
                               window: window, now: MeasureFixtures.t0)
        }
    }

    @Test func windowParses() throws {
        let utc = TimeZone(identifier: "UTC")!
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_764_250_000.75) // 2025-11-27T13:26:40.75Z
        let created = Date(timeIntervalSince1970: 1_700_000_000.5)
        // Default: the last 28 days, whole seconds.
        let d = try MeasureWindow.parse(nil, now: now, companyCreated: created, tz: utc)
        #expect(d.until == Date(timeIntervalSince1970: 1_764_250_000))
        #expect(d.since == Date(timeIntervalSince1970: 1_764_250_000 - 28 * 86_400))
        #expect(MeasureWindow.defaultDays == 28)
        // all: the company's creation (whole seconds).
        let all = try MeasureWindow.parse("all", now: now, companyCreated: created, tz: utc)
        #expect(all.since == Date(timeIntervalSince1970: 1_700_000_000) && all.until == d.until)
        // A date: midnight in the owner's zone.
        let utcDay = try MeasureWindow.parse("2025-11-01", now: now, companyCreated: created, tz: utc)
        #expect(utcDay.since == Date(timeIntervalSince1970: 1_761_955_200)) // 2025-11-01T00:00:00Z
        let laDay = try MeasureWindow.parse("2025-11-01", now: now, companyCreated: created, tz: la)
        #expect(laDay.since == Date(timeIntervalSince1970: 1_761_955_200 + 7 * 3600)) // PDT on Nov 1
        // Refused: not a date, a date after now.
        #expect(throws: MeasureError.self) { try MeasureWindow.parse("2025-13-45", now: now, companyCreated: created, tz: utc) }
        #expect(throws: MeasureError.self) { try MeasureWindow.parse("yesterday", now: now, companyCreated: created, tz: utc) }
        // Given but empty is refused, never the default.
        #expect(throws: MeasureError.badSince("")) { try MeasureWindow.parse("", now: now, companyCreated: created, tz: utc) }
        #expect(throws: MeasureError.badSince("  ")) { try MeasureWindow.parse("  ", now: now, companyCreated: created, tz: utc) }
        #expect(throws: MeasureError.self) { try MeasureWindow.parse("2999-01-01", now: now, companyCreated: created, tz: utc) }
    }
}

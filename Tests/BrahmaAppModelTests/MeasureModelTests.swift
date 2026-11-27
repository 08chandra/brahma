import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

/// How many times a `MeasureModel.Compute` ran, and what it last answered (tests swap the answer between loads).
final class ComputeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _runs = 0
    private var _spans: [MeasureModel.Span] = []
    private var _answer: Result<MeasureReport, MeasureError>?

    var runs: Int { lock.withLock { _runs } }
    var spans: [MeasureModel.Span] { lock.withLock { _spans } }
    var answer: Result<MeasureReport, MeasureError>? {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }

    /// Counts every run, then answers with `answer`, or with the live report when it is nil.
    var compute: MeasureModel.Compute {
        { [self] store, paths, companyId, span, now in
            let answer: Result<MeasureReport, MeasureError>? = lock.withLock { _runs += 1; _spans.append(span); return _answer }
            switch answer {
            case .success(let report)?: return report
            case .failure(let error)?: throw error
            case nil: return try MeasureModel.live(store, paths, companyId, span, now)
            }
        }
    }
}

/// Plan X6a Task 8: Budget › MEASURE — `Measure.report` computed off the main actor, every value its `display` string verbatim
/// (so the denominator is always shown), refreshed when the app's work or usage snapshot changes, the CLI's error text, and the
/// 7 / 28 days / all window picker.
@MainActor @Suite(.scratch) struct MeasureModelTests {
    /// Whole seconds, a minute ahead of the wall clock, so a company made in the test is older than the window's end.
    nonisolated static let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 60).rounded(.down))

    /// A report with a measured rate, a rate over too few events, a refusal and a count, and detail rows under the first.
    nonisolated static func sample(companyId: String) -> MeasureReport {
        let window = MeasureWindow(since: now.addingTimeInterval(-28 * 86_400), until: now)
        let detail = [
            MetricValue.rate(.greenMain, label: "via main runs", numerator: 30, denominator: 31, unit: .ratio, basis: "main kind"),
            MetricValue.rate(.greenMain, label: "via batch runs", numerator: 8, denominator: 8, unit: .ratio, basis: "item kind"),
        ]
        return MeasureReport(companyId: companyId, company: "Acme", window: window, timeZone: "UTC", metrics: [
            .rate(.greenMain, numerator: 38, denominator: 39, unit: .ratio, basis: "landings in the window", detail: detail),
            .rate(.firstPass, numerator: 3, denominator: 4, unit: .ratio, basis: "landed items"),
            .notMeasured(.ownerMinutes, reason: "no owner-time records"),
            .count(.safety, 0, basis: "cap overruns", target: 0),
            .rate(.usagePerLanded, numerator: 48, denominator: 40, unit: .usd, basis: "$LE (subscription)"),
        ], generatedAt: now, brahmaBuild: "dev")
    }

    @Test func displaysDenominators() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let probe = ComputeProbe()
        let report = Self.sample(companyId: acme.id)
        probe.answer = .success(report)
        let model = MeasureModel(store: store, paths: paths, compute: probe.compute, clock: { Self.now })
        #expect(model.report == nil && model.rows.isEmpty, "nothing before the first load")

        await model.show(companyId: acme.id)
        #expect(model.report == report)
        #expect(model.errorMessage == nil)
        // One row per metric, each value its `display` string verbatim: every rate shows its raw pair.
        #expect(model.rows.map(\.label) == report.metrics.map(\.label))
        #expect(model.rows.map(\.value) == report.metrics.map(\.display))
        #expect(model.rows[0].value == "97.4% (38/39)")
        #expect(model.rows[4].value == "$1.20 per landed item (48.00/40)")
        #expect(model.rows[0].basis == "landings in the window")
        // Too few events and a refusal are secondary text; a measured value is not.
        #expect(model.rows[1].value == "insufficient data (n=4)")
        #expect(model.rows.map(\.secondary) == [false, true, true, false, false])
        #expect(model.rows[2].value == "not measured: no owner-time records")
        // Detail rows are folded until their metric is expanded, and fold again.
        #expect(model.rows[0].expandable && !model.rows[1].expandable)
        model.toggle(model.rows[0].id)
        #expect(model.rows.count == report.metrics.count + 2)
        #expect(model.rows[1].value == "96.8% (30/31)" && model.rows[1].depth == 1 && model.rows[1].label == "via main runs")
        #expect(model.rows[2].value == "insufficient data (n=8)" && model.rows[2].secondary)
        model.toggle(model.rows[0].id)
        #expect(model.rows.count == report.metrics.count)

        // Agent-controlled text (a role, a model name in a detail label or basis) loses controls and bidi overrides.
        var hostile = report
        hostile.company = "Ac\u{202E}me\u{0007}"
        hostile.metrics[0].label = "eng\u{202E}ineer\u{0000}\nrole"
        hostile.metrics[0].basis = "basis\u{2066}x\u{2069}\u{001B}[31m"
        probe.answer = .success(hostile)
        await model.load()
        #expect(model.rows[0].label == "engineer role")
        #expect(model.rows[0].basis == "basisx [31m")
        #expect(model.companyLine == "Acme")
        #expect(model.rows[0].value == "97.4% (38/39)")

        // The live report over a real company: every row is the metric's display string.
        probe.answer = nil
        await model.load()
        let live = try #require(model.report)
        #expect(live.metrics.map(\.id) == MetricId.all)
        #expect(model.rows.map(\.value) == live.metrics.map(\.display))
    }

    @Test func refreshesOnTopics() async throws {
        let world = try await WorkWorld.make()
        let app = world.model
        let probe = ComputeProbe()
        probe.answer = .success(Self.sample(companyId: world.company.id))
        app.measureCompute = probe.compute
        #expect(app.measure == nil, "nothing is measured before Budget is opened")
        await world.refresh()
        #expect(probe.runs == 0)

        app.apply(.budget)
        let measure = try #require(app.measure)
        try await eventually { measure.report != nil && !measure.isLoading }
        #expect(measure.companyId == world.company.id)
        let opened = probe.runs
        #expect(opened == 1)

        // A tick with nothing new does not measure again.
        await world.refresh()
        await world.refresh()
        #expect(probe.runs == opened)

        // Work changed: measured again.
        try world.item("New work")
        await world.refresh()
        try await eventually { probe.runs == opened + 1 && !measure.isLoading }

        // Usage changed: measured again.
        try world.store.saveRateLimit(RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false,
                                                    fiveHourUtilization: 0.2, sevenDayUtilization: 0.4, observedAt: Self.now))
        await world.refresh()
        try await eventually { probe.runs == opened + 2 && !measure.isLoading }

        // Off Budget, a change is not measured.
        app.select(.missionControl)
        try world.item("More work")
        await world.refresh()
        #expect(probe.runs == opened + 2)
    }

    @Test func errorShowsCLIText() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let model = MeasureModel(store: store, paths: paths, clock: { Self.now })

        // The live path over a company that does not exist: the CLI's own words (`brahma: <text>`, without the prefix).
        await model.show(companyId: "no-such-company")
        #expect(model.errorMessage == MeasureError.unknownCompany("no-such-company").description)
        #expect(model.errorMessage == "no company with id no-such-company")
        #expect(model.report == nil && model.rows.isEmpty)

        // A failure after a good report keeps nothing stale on screen: the error replaces it.
        let probe = ComputeProbe()
        let failing = MeasureModel(store: store, paths: paths, compute: probe.compute, clock: { Self.now })
        probe.answer = .success(Self.sample(companyId: acme.id))
        await failing.show(companyId: acme.id)
        #expect(failing.report != nil && failing.errorMessage == nil)
        probe.answer = .failure(.noMainBranch("acme\u{202E}\u{0007}"))
        await failing.load()
        #expect(failing.errorMessage == "the workspace of company acme has no main branch to audit")
        #expect(failing.report == nil && failing.rows.isEmpty)
        // A good load clears the error.
        probe.answer = .success(Self.sample(companyId: acme.id))
        await failing.load()
        #expect(failing.errorMessage == nil && failing.report != nil)
    }

    @Test func windowPickerChangesWindow() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let probe = ComputeProbe()
        let model = MeasureModel(store: store, paths: paths, compute: probe.compute, clock: { Self.now })
        #expect(MeasureModel.Span.allCases == [.days7, .days28, .all])
        #expect(MeasureModel.Span.allCases.map(\.title) == ["7 days", "28 days", "All"])
        #expect(model.window == .days28, "the CLI's default window")

        await model.show(companyId: acme.id)
        let until = Self.now
        #expect(model.report?.window == MeasureWindow(since: until.addingTimeInterval(-28 * 86_400), until: until))

        await model.setWindow(.days7)
        #expect(model.window == .days7)
        #expect(model.report?.window == MeasureWindow(since: until.addingTimeInterval(-7 * 86_400), until: until))

        await model.setWindow(.all)
        let created = try #require(try store.company(id: acme.id)).createdAt
        #expect(model.report?.window == MeasureWindow(since: min(created, until), until: until))
        #expect(probe.spans == [.days28, .days7, .all])

        // Picking the window already shown measures nothing.
        await model.setWindow(.all)
        #expect(probe.runs == 3)
    }
}

import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

/// Release rows for presentation tests (no database).
enum ReleaseFixtures {
    static func plan(_ arg: String) throws -> DeployPlan {
        try DeployPlan(steps: [DeployStep(label: "deploy", argv: ["/opt/fake/bin/wrangler", "pages", "deploy", arg])],
                       stageFrom: ["dist"], cwdPath: "/tmp/brahma-release-test/upload", network: ["api.cloudflare.com"],
                       tokenSecret: "CLOUDFLARE_API_TOKEN", build: "npm run build", outputDir: "dist")
    }

    static func release(_ number: Int, _ status: ReleaseStatus, companyId: String = "c", proposer: String = "a1",
                        _ change: (inout Release) -> Void = { _ in }) throws -> Release {
        var r = Release(companyId: companyId, number: number, version: "0.\(number).0", status: status, provider: .cloudflarePages,
                        project: "acme", commit: String(repeating: "\(number)", count: 40), build: "npm run build", outputDir: "dist",
                        plan: try plan("dist"), rollbackPlan: try plan("."), proposedById: proposer,
                        createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(number)))
        change(&r)
        return r
    }
}

@MainActor @Suite(.scratch) struct ReleasesPresentationTests {
    @Test func rowsAndRollbackFlag() throws {
        var snap = ReleasesSnapshot.empty
        snap.releases = [try ReleaseFixtures.release(3, .deployed) { $0.productionURL = "https://acme.pages.dev"; $0.smokeStatus = "passed" },
                         try ReleaseFixtures.release(2, .rolledBack),
                         try ReleaseFixtures.release(1, .deployed)]
        var rows = ReleaseRows.make(snap, handles: ["a1": "devops-1"])
        #expect(rows.map(\.ref) == ["R-3", "R-2", "R-1"])
        #expect(rows[0].version == "release 0.3.0")
        #expect(rows[0].statusTitle == "DEPLOYED")
        #expect(rows[0].commit == "3333333")
        #expect(rows[0].url == "https://acme.pages.dev")
        #expect(rows[0].proposer == "@devops-1")
        #expect(rows[0].smoke == "PASSED")
        #expect(rows[0].rollbackDisplay == snap.releases[0].rollbackPlan.display)
        #expect(rows.map(\.canRollBack) == [true, false, false])  // only the live release

        // A release that failed once its deploy step started may have changed what is live: it is the live one.
        let started = Date(timeIntervalSince1970: 1_800_000_100)
        snap.releases = [try ReleaseFixtures.release(2, .failed) { $0.deployStartedAt = started }, try ReleaseFixtures.release(1, .deployed)]
        #expect(ReleaseRows.make(snap, handles: [:]).map(\.canRollBack) == [true, false])
        // Final-review m1: one that failed before deploying changed nothing; the release before it is still live.
        snap.releases = [try ReleaseFixtures.release(2, .failed), try ReleaseFixtures.release(1, .deployed)]
        #expect(ReleaseRows.make(snap, handles: [:]).map(\.canRollBack) == [false, true])
        // Final-review I2: an interrupted deploy may be partly live: its own rollback is offered, never the older release's.
        snap.releases = [try ReleaseFixtures.release(2, .interrupted), try ReleaseFixtures.release(1, .deployed)]
        #expect(ReleaseRows.make(snap, handles: [:]).map(\.canRollBack) == [true, false])

        snap.releases = [try ReleaseFixtures.release(2, .proposed), try ReleaseFixtures.release(1, .deployed)]
        rows = ReleaseRows.make(snap, handles: [:])
        #expect(rows.map(\.canRollBack) == [false, false])  // proposed; and an open release blocks rollbacks

        snap.releases = [try ReleaseFixtures.release(1, .deployed) { $0.rollbackStatus = .running }]
        rows = ReleaseRows.make(snap, handles: [:])
        #expect(rows[0].canRollBack == false && rows[0].rollbackTitle == "ROLLING BACK")

        snap.releases = [try ReleaseFixtures.release(1, .deployed) { $0.rollbackStatus = .failed }]
        rows = ReleaseRows.make(snap, handles: [:])
        #expect(rows[0].canRollBack && rows[0].rollbackTitle == "ROLLBACK FAILED")
    }

    @Test func releaseURLShowsHostAndOpensHTTPSOnly() throws {
        var snap = ReleasesSnapshot.empty
        snap.releases = [try ReleaseFixtures.release(4, .deployed) { $0.productionURL = "https://Acme.pages.dev/x?y=1" },
                         try ReleaseFixtures.release(3, .deployed) { $0.deployURL = "http://acme.example/" },
                         try ReleaseFixtures.release(2, .deployed) { $0.deployURL = "javascript:alert(1)" },
                         try ReleaseFixtures.release(1, .proposed)]
        let rows = ReleaseRows.make(snap, handles: [:])
        #expect(rows.map(\.urlHost) == ["acme.pages.dev", "acme.example", "—", "—"])
        #expect(rows[0].openURL?.absoluteString == "https://Acme.pages.dev/x?y=1")
        #expect(rows[1].openURL == nil && rows[2].openURL == nil && rows[3].openURL == nil)
    }

    @Test func mainHealthTitles() throws {
        let head = "abc1234def5678"
        var snap = ReleasesSnapshot.empty
        #expect(MainHealth.make(snap, mainHead: head) == MainHealth(title: "NO SMOKE CHECK", tone: .idle))
        snap.smokeCheck = CheckSpec(command: "npm test")
        #expect(MainHealth.make(snap, mainHead: head) == MainHealth(title: "SMOKE NOT RUN @abc1234", tone: .warn))
        snap.latestMainSmoke = MainSmokeRun(companyId: "c", commit: head, status: .passed, reason: .merge, createdAt: Date())
        #expect(MainHealth.make(snap, mainHead: head) == MainHealth(title: "SMOKE PASSED @abc1234", tone: .good))
        snap.latestMainSmoke?.status = .failed
        snap.redBugKey = "ACME-9"
        #expect(MainHealth.make(snap, mainHead: head) == MainHealth(title: "MAIN RED @abc1234 · BUG ACME-9", tone: .bad))
        // A result at an older commit says nothing about the head.
        snap.latestMainSmoke?.commit = "0000000aaaa"
        #expect(MainHealth.make(snap, mainHead: head).title == "SMOKE NOT RUN @abc1234")
    }

    @Test func hostingFormValidation() {
        var form = HostingForm(nil, companySlug: "acme")
        #expect(form.provider == .default && form.project == "acme" && form.accountId == "" && form.productionURL == "")
        #expect(form.validate() == nil)
        form.project = "Bad Name"
        #expect(form.validate() == "project names are 2–58 lowercase letters, digits and dashes")
        form.project = "acme"
        form.productionURL = "http://acme.pages.dev"
        #expect(form.validate() == "production URL must start with https://")
        form.productionURL = "https://acme.pages.dev"
        form.accountId = "bad id!"
        #expect(form.validate() == "account ID must be 1–64 letters, digits, dashes or underscores")
        form.accountId = "0123456789abcdef0123456789abcdef"
        #expect(form.validate() == nil)
        let saved = HostingSettings(companyId: "c", provider: .vercel, project: "shop", accountId: "team_1",
                                    productionURL: "https://shop.vercel.app", updatedAt: Date())
        let loaded = HostingForm(saved, companySlug: "acme")
        #expect(loaded.provider == .vercel && loaded.project == "shop" && loaded.accountId == "team_1"
                && loaded.productionURL == "https://shop.vercel.app")
    }

    /// Task 13: the PATH TO LIVE strip's milestone chips, from the core report; nothing without a report, LIVE in success.
    @Test func milestoneChips() {
        #expect(MilestoneChips.make(nil).isEmpty)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let report = MilestoneReport(
            milestones: [Milestone(name: "goal", at: t0), Milestone(name: "prd", at: t0.addingTimeInterval(52 * 60)),
                         Milestone(name: "firstMerge", at: t0.addingTimeInterval(2 * 3600)), Milestone(name: "live", at: t0.addingTimeInterval(3 * 3600 + 600))],
            phases: [MilestonePhase(from: "goal", to: "prd", costLE: 3.1, ownerTouches: 2),
                     MilestonePhase(from: "prd", to: "firstMerge", costLE: 4, ownerTouches: 0),
                     MilestonePhase(from: "firstMerge", to: "live", costLE: 7.7, ownerTouches: 5),
                     MilestonePhase(from: "live", to: "now", costLE: 0, ownerTouches: 0)],
            totalLE: 14.8, totalTouches: 7)
        let chips = MilestoneChips.make(report)
        #expect(chips.map(\.title) == ["GOAL 0:00", "PRD +0:52", "FIRST MERGE +2:00", "LIVE +3:10", "$14.80 · 7 TOUCHES"])
        #expect(chips.map(\.tone) == [.muted, .muted, .muted, .success, .ready])
        #expect(chips.map(\.id) == ["goal", "prd", "firstMerge", "live", "totals"])
        // Only a goal: the strip shows it and the totals.
        let fresh = MilestoneReport(milestones: [Milestone(name: "goal", at: t0)], phases: [MilestonePhase(from: "goal", to: "now", costLE: 0, ownerTouches: 0)],
                                    totalLE: 0, totalTouches: 0)
        #expect(MilestoneChips.make(fresh).map(\.title) == ["GOAL 0:00", "$0.00 · 0 TOUCHES"])
    }

    @Test func vercelNote() {
        var form = HostingForm(nil, companySlug: "acme")
        #expect(form.providerNote == nil)
        form.provider = .vercel
        #expect(form.providerNote == "Vercel's free Hobby plan is for non-commercial use. " + VercelAdapter.projectNote(project: form.project))
    }
}

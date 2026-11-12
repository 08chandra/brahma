import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan L Task 13: the scorecard (`CompanyMilestones`) is computed from existing rows — the company, gate asks, item events,
/// preview activity, releases, human tasks, turns and owner messages — with no table of its own.
@Suite(.scratch) struct MilestoneTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    /// A small (combined-gate) company with the owner's kickoff, a gate approval, turns, a human task, a merge, a preview,
    /// optionally a deployed release, and a posted launch announcement.
    struct W {
        let store: Store
        let company: Company
        let ceo: Agent
        let eng: Agent
        let vault = MemoryVault()

        init(deploy: Bool = true) throws {
            store = try Store.inMemory()
            var c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            c.createdAt = MilestoneTests.t0
            try store.updateCompany(c)
            company = c
            ceo = try store.hire(companyId: c.id, name: "ceo", role: "ceo-cpo", model: "sonnet")
            eng = try store.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "haiku")

            // Turns: 1.0 and 2.5 before the gate (and one with no cost), 4.0 after it.
            try turn(at: MilestoneTests.at(5), usd: 1.0)
            try turn(at: MilestoneTests.at(20), usd: 2.5)
            try turn(at: MilestoneTests.at(30), usd: nil)
            try turn(at: MilestoneTests.at(60), usd: 4.0)
            // The owner's kickoff.
            _ = try MessageRouter(store: store).post(companyId: c.id, channel: "#general", from: .owner, text: "@ceo go", now: MilestoneTests.at(15))
            // A human task done by the owner before the gate.
            let stripe = try store.fileTemplateTask(companyId: c.id, requesterId: "system", template: .stripeTestKeys, now: MilestoneTests.at(20))
            try store.completeHumanTask(companyId: c.id, askId: stripe.id,
                                        values: ["STRIPE_TEST_SECRET_KEY": "sk_test_abc", "STRIPE_TEST_PUBLISHABLE_KEY": "pk_test_abc"],
                                        vault: vault, now: MilestoneTests.at(40))
            // The combined gate: one prd ask, approved by the owner at +0:52.
            let prd = try store.propose(companyId: c.id, by: .agent(ceo.id), kind: .prd, title: "Brief", summary: "s", viaOwner: true,
                                        now: MilestoneTests.at(10))
            try store.ownerDecide(askId: prd.id, approve: true, now: MilestoneTests.at(52))
            // First merge at +2:00.
            let item = try store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Skeleton"))
            try store.writer.write { db in
                var e = WorkItemEvent(companyId: c.id, itemId: item.id, actorId: "system", kind: .merged, text: "merged",
                                      createdAt: MilestoneTests.at(120), createdActive: 0)
                try e.insert(db)
            }
            // First preview running at +3:00 (the runner's activity line).
            try store.appendEvent(ActivityEvent(companyId: c.id, agentId: nil, turnId: nil, kind: .preview,
                                                text: "Preview web running at http://127.0.0.1:47100/", createdAt: MilestoneTests.at(180)))
            if deploy {
                try release(1, deployedAt: MilestoneTests.at(240))
                let post = try store.fileTemplateTask(companyId: c.id, requesterId: "system", template: .launchPost,
                                                      args: ["text": "We launched"], now: MilestoneTests.at(250))
                try store.completeHumanTask(companyId: c.id, askId: post.id, values: ["posted_url": "https://x.com/acme/status/1"],
                                            vault: vault, now: MilestoneTests.at(300))
            }
        }

        func turn(at: Date, usd: Double?) throws {
            let t = Turn(id: UUID().uuidString, agentId: eng.id, companyId: company.id, startedAt: at, endedAt: at.addingTimeInterval(60),
                         outcome: .succeeded, summary: nil, costUSD: usd)
            try store.writer.write { db in try t.insert(db) }
        }

        func release(_ number: Int, deployedAt: Date) throws {
            let plan = try DeployPlan(steps: [DeployStep(label: "deploy", argv: ["/opt/fake/bin/wrangler", "pages", "deploy", "dist"])],
                                      stageFrom: ["dist"], cwdPath: "/tmp/brahma-release-test/upload", network: ["api.cloudflare.com"],
                                      tokenSecret: "CLOUDFLARE_API_TOKEN", build: "npm run build", outputDir: "dist")
            var r = Release(companyId: company.id, number: number, version: "0.\(number).0", status: .deployed, provider: .cloudflarePages,
                            project: "acme", commit: String(repeating: "\(number)", count: 40), build: "npm run build", outputDir: "dist",
                            plan: plan, rollbackPlan: plan, proposedById: ceo.id, createdAt: deployedAt.addingTimeInterval(-600))
            r.deployedAt = deployedAt
            r.productionURL = "https://acme.pages.dev"
            try store.writer.write { db in try r.insert(db) }
        }

        func report(now: Date = MilestoneTests.at(360)) throws -> MilestoneReport {
            try CompanyMilestones.load(store: store, companyId: company.id, now: now)
        }
    }

    @Test func computedFromRows() throws {
        let w = try W()
        let r = try w.report()
        #expect(r.milestones.map(\.name) == ["goal", "prd", "architecture", "firstMerge", "firstPreview", "live", "firstPost"])
        #expect(r.milestones[0].at == Self.t0)
        #expect(r.milestones[1].at == Self.at(52))
        #expect(r.milestones[2].at == Self.at(52), "under the combined gate the architecture milestone is the prd approval")
        #expect(r.milestones[3].at == Self.at(120))
        #expect(r.milestones[4].at == Self.at(180))
        #expect(r.milestones[5].at == Self.at(240))
        #expect(r.milestones[6].at == Self.at(300))
        // One phase per milestone after the goal, then the phase that runs to now.
        #expect(r.phases.map(\.to) == ["prd", "architecture", "firstMerge", "firstPreview", "live", "firstPost", "now"])
        #expect(r.phases.map(\.from) == ["goal", "prd", "architecture", "firstMerge", "firstPreview", "live", "firstPost"])

        // Without a deploy there is no live milestone (and here no post either).
        let dry = try W(deploy: false).report()
        #expect(dry.milestones.map(\.name) == ["goal", "prd", "architecture", "firstMerge", "firstPreview"])
        #expect(!dry.milestones.contains { $0.name == "live" })
        // An unknown company is an empty report.
        let none = try CompanyMilestones.load(store: w.store, companyId: "nope", now: Self.at(1))
        #expect(none.milestones.isEmpty && none.phases.isEmpty && none.totalLE == 0 && none.totalTouches == 0)
    }

    @Test func costAndTouchesPerPhase() throws {
        let w = try W()
        let r = try w.report()
        let prd = try #require(r.phases.first { $0.to == "prd" })
        #expect(prd.costLE == 3.5, "turns at +5 and +20 count; the nil cost at +30 counts 0")
        #expect(prd.ownerTouches == 3, "the gate approval, the owner's kickoff and the human task done")
        let merge = try #require(r.phases.first { $0.to == "firstMerge" })
        #expect(merge.costLE == 4.0)
        #expect(merge.ownerTouches == 0)
        let arch = try #require(r.phases.first { $0.to == "architecture" })
        #expect(arch.costLE == 0 && arch.ownerTouches == 0, "a zero-length phase")
        let post = try #require(r.phases.first { $0.to == "firstPost" })
        #expect(post.ownerTouches == 1, "the launch post done at +5:00")
        #expect(r.totalLE == 7.5)
        #expect(r.totalTouches == 4)
        #expect(r.phases.map(\.costLE).reduce(0, +) == r.totalLE)
        #expect(r.phases.map(\.ownerTouches).reduce(0, +) == r.totalTouches)
    }

    @Test func textLines() throws {
        let w = try W()
        let r = try w.report()
        let lines = r.lines(now: Self.at(360))
        #expect(r.lines().contains("now           +?   $0.00   0 touches"), "without now the last phase's end is unknown")
        #expect(lines.first == "goal           0:00", "\(lines)")
        #expect(lines.contains("prd           +0:52   $3.50   3 touches"), "\(lines)")
        #expect(lines.contains("architecture  +0:52   $0.00   0 touches"), "\(lines)")
        #expect(lines.contains("firstMerge    +2:00   $4.00   0 touches"), "\(lines)")
        #expect(lines.contains("live          +4:00   $0.00   0 touches"), "\(lines)")
        #expect(lines.contains("now           +6:00   $0.00   0 touches"), "\(lines)")
        #expect(lines.last == "total $7.50, 4 owner touches", "\(lines)")
        #expect(MilestoneReport.elapsed(0) == "0:00")
        #expect(MilestoneReport.elapsed(52 * 60) == "0:52")
        #expect(MilestoneReport.elapsed(26 * 3600 + 5 * 60) == "26:05")
        #expect(MilestoneReport.elapsed(-5) == "0:00")
        // The strip's chip titles.
        #expect(r.chipTitles() == ["GOAL 0:00", "PRD +0:52", "ARCHITECTURE +0:52", "FIRST MERGE +2:00", "FIRST PREVIEW +3:00",
                                   "LIVE +4:00", "FIRST POST +5:00"])
        #expect(r.totalsTitle == "$7.50 · 4 TOUCHES")
    }
}

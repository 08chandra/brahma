import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C4c: who answers an Ask (`ShowRouting`), and the candidates a target is given (`ShowCandidates`).
@Suite(.scratch) struct ShowRoutingTests {
    /// `RefFixture` (company ENG: cto, eng-1, qa-2, eng-3) with a ready item `ENG-2` that eng-3 holds.
    struct World {
        let fx: RefFixture
        let item: WorkItem
        var store: Store { fx.store }
        var c: Company { fx.c }

        init(holder: Bool = true) throws {
            fx = try RefFixture()
            let s = fx.store
            // The fixture's ENG-1 (in review, claiming the whole repository) is done, so ENG-2 can be leased.
            let done = fx.item.id
            try s.writer.write { db in try db.execute(sql: "UPDATE workItem SET status = 'done' WHERE id = ?", arguments: [done]) }
            item = try s.createWorkItem(companyId: fx.c.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Checkout flow", checkSpec: CheckSpec(command: "true", paths: ["src"]), status: .ready))
            if holder { _ = try s.claimLease(itemId: item.id, agentId: fx.eng3.id, engine: true, now: fx.now) }
        }

        func state(_ a: Agent, _ state: AgentState, paused: Bool = false) throws {
            try store.writer.write { db in
                try db.execute(sql: "UPDATE agent SET state = ?, paused = ? WHERE id = ?", arguments: [state.rawValue, paused, a.id])
            }
        }

        func reviewer(_ a: Agent) throws {
            try store.writer.write { db in try db.execute(sql: "UPDATE workItem SET reviewerId = ? WHERE id = ?", arguments: [a.id, item.id]) }
        }

        func result(_ refs: [String], query: String) throws -> ShowResult {
            let hits = try refs.map { ShowHit(ref: try fx.ref($0), title: $0, subtitle: "", snippet: nil, at: nil, group: .top, score: 0.9) }
            let (normalized, stripped) = ShowQuery.normalize(query)
            return ShowResult(normalized: normalized, stripped: stripped, filters: SearchFilters(), answer: nil, hits: hits, topScore: 0.9,
                              intent: .request, groupTotals: [:])
        }

        func route(_ refs: [String], _ query: String, kind: ShowKind = .show, handle: String? = nil) throws -> RoutedTarget {
            try ShowRouting.target(result: try result(refs, query: query), kind: kind, explicitHandle: handle, attachedRef: nil,
                                   store: store, companyId: c.id)
        }
    }

    @Test func routesToHolderWhenSleeping() throws {
        let w = try World()
        try w.state(w.fx.eng3, .sleeping)
        let t = try w.route([w.item.key], "why is checkout slow")
        #expect(t == RoutedTarget(target: .agent(w.fx.eng3.id), reason: "holds \(w.item.key)", busy: false))
        // Ready counts as idle too; an ordinary (non-explain) Ask goes to the concierge whatever it hits.
        try w.state(w.fx.eng3, .ready)
        #expect(try w.route([w.item.key], "why is checkout slow").target == .agent(w.fx.eng3.id))
        #expect(try w.route([w.item.key], "checkout flow").target == .concierge)
        #expect(try w.route([w.item.key], "checkout flow", kind: .explain).target == .agent(w.fx.eng3.id))
    }

    @Test func routesToIdleReviewerWhenHolderRunning() throws {
        let w = try World()
        try w.state(w.fx.eng3, .running)
        try w.reviewer(w.fx.qa2)
        try w.state(w.fx.qa2, .sleeping)
        let t = try w.route([w.item.key], "how does checkout work")
        #expect(t == RoutedTarget(target: .agent(w.fx.qa2.id), reason: "reviewer of \(w.item.key); @eng-3 is busy", busy: false))
        // The last committer when there is no reviewer; the holder (busy) when nobody else is.
        try w.store.writer.write { db in try db.execute(sql: "UPDATE workItem SET reviewerId = NULL WHERE id = ?", arguments: [w.item.id]) }
        try w.store.recordCommitAuthors(companyId: w.c.id, itemId: w.item.id, agentId: w.fx.eng1.id, turnId: nil,
                                        shas: [String(repeating: "a", count: 40)], now: w.fx.now)
        let committer = try w.route([w.item.key], "explain the checkout")
        #expect(committer == RoutedTarget(target: .agent(w.fx.eng1.id), reason: "last committed on \(w.item.key); @eng-3 is busy", busy: false))
        try w.store.writer.write { db in try db.execute(sql: "DELETE FROM turnCommit") }
        #expect(try w.route([w.item.key], "why") == RoutedTarget(target: .agent(w.fx.eng3.id), reason: "holds \(w.item.key); busy", busy: true))
    }

    @Test func fileHitRoutesViaTouchPaths() throws {
        let w = try World()
        try w.state(w.fx.eng3, .sleeping)
        try w.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET touchPaths = ? WHERE id = ?", arguments: [#"["src/checkout.tsx"]"#, w.item.id])
        }
        let t = try w.route(["src/checkout.tsx"], "why is this file slow")
        #expect(t.target == .agent(w.fx.eng3.id) && t.reason == "holds \(w.item.key)")
        // A file no item covers: the agent the engine recorded for the newest commit on the path.
        let sha = try w.fx.git.git(["rev-parse", "main"])
        try w.store.recordCommitAuthors(companyId: w.c.id, itemId: nil, agentId: w.fx.qa2.id, turnId: nil, shas: [sha], now: w.fx.now)
        let a = try w.route(["src/a.ts"], "explain a.ts")
        #expect(a == RoutedTarget(target: .agent(w.fx.qa2.id), reason: "made the last commit on this file", busy: false))
    }

    @Test func artifactRoutesToPublisher() throws {
        let w = try World(holder: false)
        _ = try w.fx.seedArtifact(9, title: "Landing page", publishedById: w.fx.qa2.id)
        let t = try w.route(["AR-9"], "explain this page", kind: .explain)
        #expect(t == RoutedTarget(target: .agent(w.fx.qa2.id), reason: "published AR-9", busy: false))
        // An owner-published artifact has no agent to ask: the concierge.
        _ = try w.fx.seedArtifact(10, title: "Owner page")
        #expect(try w.route(["AR-10"], "explain this page", kind: .explain).target == .concierge)
    }

    @Test func fallbackGoesToConcierge() throws {
        let w = try World(holder: false)
        // Nothing an agent owns among the hits: a message, a run of the mill Ask, an empty result. Never the CTO.
        let message = "msg:\(w.fx.engMessage.id)"
        for (refs, q) in [([message], "why is the cart slow"), ([String](), "how does billing work"), ([w.item.key], "show checkout")] {
            let t = try w.route(refs, q)
            #expect(t == RoutedTarget(target: .concierge, reason: ShowRouting.conciergeReason, busy: false), "\(q)")
        }
        // The Tab cycle: Brahma first, then the agents the rules name.
        let w2 = try World()
        try w2.state(w2.fx.eng3, .sleeping)
        let alts = try ShowRouting.alternatives(result: try w2.result([w2.item.key], query: "checkout"), kind: .show, attachedRef: nil,
                                                store: w2.store, companyId: w2.c.id)
        #expect(alts.map(\.target) == [.concierge, .agent(w2.fx.eng3.id)])
    }

    @Test func explicitHandleWins() throws {
        let w = try World()
        try w.state(w.fx.eng3, .sleeping)
        try w.state(w.fx.cto, .running)
        let t = try w.route([w.item.key], "why is checkout slow", handle: "@cto")
        #expect(t == RoutedTarget(target: .agent(w.fx.cto.id), reason: "you asked @cto", busy: true))
        #expect(throws: WorkError.self) { _ = try w.route([], "why", handle: "@nobody") }
    }

    @Test func pausedAndKilledSkipped() throws {
        let w = try World()
        try w.reviewer(w.fx.qa2)
        // The holder is paused (skipped even though idle); the reviewer answers.
        try w.state(w.fx.eng3, .sleeping, paused: true)
        try w.state(w.fx.qa2, .running)
        let t = try w.route([w.item.key], "why is checkout slow")
        #expect(t == RoutedTarget(target: .agent(w.fx.qa2.id), reason: "reviewer of \(w.item.key)", busy: true))
        // The reviewer killed too: nobody usable is left, so the concierge.
        try w.state(w.fx.qa2, .killed)
        #expect(try w.route([w.item.key], "why is checkout slow").target == .concierge)
        // An explicit handle of a paused agent is refused.
        #expect(throws: WorkError.self) { _ = try w.route([], "why", handle: "@eng-3") }
    }

    @Test func candidatesFilteredByTargetAccess() throws {
        let w = try World()
        let result = try w.result(["F-1", "F-2", w.item.key], query: "plans")
        let gate = GlobalSearch.TextGate(knownValues: [])
        let forEng3 = try ShowCandidates.lines(result: result, for: .agent(w.fx.eng3.id), store: w.store, companyId: w.c.id, gate: gate)
        #expect(forEng3.hiddenCount == 1)
        #expect(!forEng3.lines.contains { $0.hasPrefix("F-1") })
        #expect(forEng3.lines.contains { $0.hasPrefix("F-2") } && forEng3.lines.contains { $0.hasPrefix(w.item.key) })
        #expect(forEng3.lines.last == "1 more the owner can see")
        // The concierge reads what the owner reads (not secrets): nothing hidden.
        let forConcierge = try ShowCandidates.lines(result: result, for: .concierge, store: w.store, companyId: w.c.id, gate: gate)
        #expect(forConcierge.hiddenCount == 0 && forConcierge.lines.count == 3)
        // A missing ref is hidden the same way (no existence oracle), and a line holding a stored value is left out.
        let missing = try ShowCandidates.lines(result: try w.result(["F-99", w.item.key], query: "x"), for: .agent(w.fx.eng3.id),
                                               store: w.store, companyId: w.c.id, gate: gate)
        #expect(missing.hiddenCount == 1 && missing.lines.last == "1 more the owner can see")
        let secret = GlobalSearch.TextGate(knownValues: [(name: "K", value: "Checkout flow")])
        let gated = try ShowCandidates.lines(result: try w.result([w.item.key], query: "x"), for: .concierge, store: w.store,
                                             companyId: w.c.id, gate: secret)
        #expect(!gated.lines.joined().contains("Checkout flow"))
    }
}

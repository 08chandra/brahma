import Foundation
import GRDB
@testable import BrahmaCore

/// Store-level fixtures for the `measure` tests (Plan X6a). Everything is written straight to the tables the metrics read, with
/// the engine's own record types, so a test controls every number. Tasks 3–5 extend this file (asks, messages, runs, counters);
/// Task 1 keeps to companies, items, landings and facts.
enum MeasureFixtures {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A company row written directly (no workspace is created: a measure fixture is store-only unless a test gives it a real
    /// `GitFixture` workspace). `workspacePath` defaults to a path that does not exist.
    @discardableResult
    static func company(_ store: Store, name: String, workspacePath: String? = nil, createdAt: Date = t0) throws -> Company {
        let slug = Store.slug(for: name)
        let company = Company(id: UUID().uuidString, name: name, slug: slug, goal: "measure fixture",
                              workspacePath: workspacePath ?? "/nonexistent/measure-fixture/\(slug)-\(UUID().uuidString)",
                              status: .running, usageMode: .balanced, priorityWeight: 1, createdAt: createdAt)
        try store.writer.write { db in try company.insert(db) }
        return company
    }

    /// `count` ready tasks authored by the owner.
    static func items(_ store: Store, company: Company, count: Int, now: Date = t0) throws -> [WorkItem] {
        try (0..<count).map { n in
            try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Item \(n + 1)", checkSpec: CheckSpec(command: "true"), tier: .m, status: .ready), now: now)
        }
    }

    /// A landing as the journal records it: one `mergeBatch` at `done` whose `landedIds` are the ids of one merged `mergeRequest`
    /// per item (request ids, never item ids — inventory §2.1), each request `merged` with its own `mergedCommit`, enqueued at
    /// `enqueuedAt` and finished at `landedAt`.
    @discardableResult
    static func land(_ store: Store, company: Company, items: [WorkItem], number: Int, enqueuedAt: Date, landedAt: Date)
        throws -> (batch: MergeBatch, requests: [MergeRequest]) {
        func sha(_ seed: String) -> String { String(seed.utf8.map { String(format: "%02x", $0) }.joined().prefix(40)).padding(toLength: 40, withPad: "0", startingAt: 0) }
        let batchId = UUID().uuidString
        var requests: [MergeRequest] = []
        var candidates: [String: String] = [:]
        for (i, item) in items.enumerated() {
            var r = MergeRequest(companyId: company.id, itemId: item.id, number: number * 100 + i + 1, status: .merged,
                                 headCommit: sha("head-\(number)-\(i)"), enqueuedAt: enqueuedAt)
            r.batchId = batchId
            r.baseCommit = sha("base-\(number)")
            r.candidateCommit = sha("cand-\(number)-\(i)")
            r.mergedCommit = r.candidateCommit
            r.startedAt = enqueuedAt
            r.finishedAt = landedAt
            candidates[r.id] = r.candidateCommit ?? ""
            requests.append(r)
        }
        var batch = MergeBatch(id: batchId, companyId: company.id, number: number, step: .done, requestIds: requests.map(\.id),
                               startedAt: enqueuedAt)
        batch.base = sha("base-\(number)")
        batch.candidates = candidates
        batch.landCommit = requests.last?.mergedCommit
        batch.landedIds = requests.map(\.id)
        batch.updatedAt = landedAt
        batch.finishedAt = landedAt
        let rows = requests, b = batch
        try store.writer.write { db in
            for r in rows { try r.insert(db) }
            try b.insert(db)
        }
        return (batch, requests)
    }

    /// The item's `itemFact` row (what `OutcomeFactsObserver` writes when an item completes), with the numbers a test wants.
    @discardableResult
    static func fact(_ store: Store, item: WorkItem, firstPass: Bool = true, costLE: Double = 1, turnsUsed: Int = 2,
                     tokensUsed: Int = 1000, cycleActiveSeconds: Int? = 600, reviewRejections: Int = 0, completedAt: Date = t0)
        throws -> ItemFact {
        let f = ItemFact(itemId: item.id, companyId: item.companyId, type: item.type.rawValue, tier: item.tier.rawValue,
                         ownerId: item.ownerId, reviewerId: item.reviewerId, firstPass: firstPass, verificationRuns: 1,
                         failedRuns: firstPass ? 0 : 1, flakyRuns: 0, inconclusiveRuns: 0, reworkRounds: reviewRejections,
                         reviewRejections: reviewRejections, turnsUsed: turnsUsed, tokensUsed: tokensUsed, tierMaxTurns: 10,
                         tierMaxTokens: 100_000, cycleActiveSeconds: cycleActiveSeconds, blockedActiveSeconds: 0,
                         checkAuthorId: "owner", checkAuthorRole: "owner", mergeConflicts: 0, costLE: costLE, tierMaxCostLE: 10,
                         reviewCostLE: 0.1, autoMerged: false, audited: false, auditVerdict: nil, rungAtPass: 1, modesUsed: "balanced",
                         completedAt: completedAt)
        try store.writer.write { db in try f.save(db) }
        return f
    }

    /// A company with `landed` items landed in one batch, each with a fact. Tasks 3–5 add asks, messages and runs here.
    @discardableResult
    static func seed(_ store: Store, name: String, landed: Int, workspacePath: String? = nil, now: Date = t0) throws -> Company {
        let company = try company(store, name: name, workspacePath: workspacePath, createdAt: now.addingTimeInterval(-30 * 86_400))
        let items = try items(store, company: company, count: landed, now: now.addingTimeInterval(-10 * 86_400))
        if !items.isEmpty {
            try land(store, company: company, items: items, number: 1, enqueuedAt: now.addingTimeInterval(-5 * 86_400),
                     landedAt: now.addingTimeInterval(-4 * 86_400))
            for (i, item) in items.enumerated() {
                try fact(store, item: item, firstPass: i % 2 == 0, costLE: Double(i + 1), completedAt: now.addingTimeInterval(-4 * 86_400))
            }
        }
        return company
    }
}

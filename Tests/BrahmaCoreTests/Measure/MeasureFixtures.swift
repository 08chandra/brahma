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
    /// `enqueuedAt` and finished at `landedAt`. The items are left as `finishMerge(.merged)` leaves them (`Store+Merge.swift`,
    /// `engineSetStatus(… .done)`): `status = done`, `doneAt = updatedAt = landedAt`, `mergeState = none`, `mergedCommit`,
    /// `leaseHeadCommit = nil`. Before a landing an item is `inReview` with `mergeState = pending`; the fixture's items start `ready`
    /// (never claimed), which the measure metrics do not read.
    /// `step` other than `done` (Task 2): the journal row as a batch that stopped there (`checked`: landCommit written, `main`
    /// not moved; `recorded`: landed, `finishedAt` not yet stamped) — the items are still marked as above.
    @discardableResult
    static func land(_ store: Store, company: Company, items: [WorkItem], number: Int, enqueuedAt: Date, landedAt: Date,
                     step: MergeStep = .done) throws -> (batch: MergeBatch, requests: [MergeRequest]) {
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
        var batch = MergeBatch(id: batchId, companyId: company.id, number: number, step: step, requestIds: requests.map(\.id),
                               startedAt: enqueuedAt)
        batch.base = sha("base-\(number)")
        batch.candidates = candidates
        batch.landCommit = requests.last?.mergedCommit
        batch.landedIds = requests.map(\.id)
        batch.updatedAt = landedAt
        batch.finishedAt = landedAt
        let rows = requests, b = batch
        try store.writer.write { db in
            for r in rows {
                try r.insert(db)
                guard var item = try WorkItem.fetchOne(db, key: r.itemId) else { throw FakeError(description: "no item \(r.itemId)") }
                item.status = .done
                item.doneAt = landedAt
                item.updatedAt = landedAt
                item.mergeState = .none
                item.mergedCommit = r.mergedCommit
                item.leaseHeadCommit = nil
                try item.update(db)
            }
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

    // MARK: Task 3 — runs, smoke, bounces

    /// Gives (or takes away) the company's main check: with one set, the merge queue records a `main`-kind `mergeRun` per
    /// tested candidate (inventory §2.3).
    static func setMainCheck(_ store: Store, company: Company, _ spec: CheckSpec? = CheckSpec(command: "true")) throws {
        try store.writer.write { db in
            guard var c = try Company.fetchOne(db, key: company.id) else { throw FakeError(description: "no company \(company.id)") }
            c.mainCheck = spec
            try c.update(db)
        }
    }

    /// One `mergeRun` of a batch as `MergeQueue.runCheck` records it (`blamedRun`, MergeQueue.swift): an `item` run names the
    /// request and item it checks; a `main` run names the owning member of the prefix it checked — `request`, else the batch's
    /// last landed request (the last member of the prefix that landed); a `mainAtBase` run names none. `candidateCommit`
    /// defaults to the batch's `landCommit` (the candidate that landed). A flake re-run is a second row at `attempt: 2,
    /// flaky: true` beside the failed first attempt (every passing re-run is recorded flaky).
    @discardableResult
    static func mergeRun(_ store: Store, company: Company, batch: MergeBatch, kind: MergeRun.Kind, request: MergeRequest? = nil,
                         candidateCommit: String? = nil, attempt: Int = 1, flaky: Bool = false, status: VerificationStatus = .passed,
                         finishedAt: Date) throws -> MergeRun {
        var owner = request
        if kind == .main, owner == nil, let last = batch.landedIds.last ?? batch.requestIds.last {
            owner = try store.writer.read { db in try MergeRequest.fetchOne(db, key: last) }
        }
        let run = MergeRun(companyId: company.id, batchId: batch.id, requestId: kind == .mainAtBase ? nil : owner?.id,
                           prefix: batch.requestIds.count, candidateCommit: candidateCommit ?? batch.landCommit, kind: kind,
                           itemId: kind == .mainAtBase ? nil : owner?.itemId, command: "true",
                           status: status, attempt: attempt, flaky: flaky, exitCode: status == .passed ? 0 : 1,
                           startedAt: finishedAt.addingTimeInterval(-10), finishedAt: finishedAt)
        try store.writer.write { db in try run.insert(db) }
        return run
    }

    /// A smoke run of `main` at `commit` (`mainSmokeRun`, inventory §2.4). One `merge` run per commit (the partial unique index).
    @discardableResult
    static func mainSmokeRun(_ store: Store, company: Company, commit: String, status: MainSmokeStatus, reason: MainSmokeReason = .merge,
                             finishedAt: Date) throws -> MainSmokeRun {
        let run = MainSmokeRun(companyId: company.id, commit: commit, status: status, exitCode: status == .passed ? 0 : 1, reason: reason,
                               createdAt: finishedAt.addingTimeInterval(-20), startedAt: finishedAt.addingTimeInterval(-10), finishedAt: finishedAt)
        try store.writer.write { db in try run.insert(db) }
        return run
    }

    /// One `verificationRun` of an item's check (inventory §2.5).
    @discardableResult
    static func verificationRun(_ store: Store, company: Company, item: WorkItem, purpose: VerificationPurpose = .submit,
                                status: VerificationStatus = .passed, attempt: Int = 1, flaky: Bool = false, finishedAt: Date)
        throws -> VerificationRun {
        let run = VerificationRun(id: UUID().uuidString, companyId: company.id, itemId: item.id, checkRevision: 1, scriptHash: "",
                                  commit: String(repeating: "a", count: 40), command: "true", workingDirectory: "", timeoutSeconds: 60,
                                  purpose: purpose, attempt: attempt, status: status, flaky: flaky, exitCode: status == .passed ? 0 : 1,
                                  createdAt: finishedAt.addingTimeInterval(-20), startedAt: finishedAt.addingTimeInterval(-10),
                                  finishedAt: finishedAt)
        try store.writer.write { db in try run.insert(db) }
        return run
    }

    /// A request of `batch` that the bisection bounced (`Store.bounceMerge`): `status = bounced`, `failure`, `finishedAt` = the
    /// bounce time, and the batch's `requestIds` grown by it (it is never in `landedIds`). A request bounced for a failed check was
    /// a checked candidate, so it joins `candidates` too (written at `rebased`); one bounced on a conflict never got a candidate.
    /// The item is left as it was.
    @discardableResult
    static func bounce(_ store: Store, company: Company, batch: MergeBatch, item: WorkItem, number: Int,
                       failure: MergeFailure = .itemCheckFailed, enqueuedAt: Date, bouncedAt: Date) throws -> MergeRequest {
        var r = MergeRequest(companyId: company.id, itemId: item.id, number: number, status: .bounced,
                             headCommit: String(repeating: "b", count: 40), enqueuedAt: enqueuedAt)
        r.batchId = batch.id
        r.failure = failure
        r.startedAt = enqueuedAt
        r.finishedAt = bouncedAt
        let row = r
        try store.writer.write { db in
            try row.insert(db)
            guard var b = try MergeBatch.fetchOne(db, key: batch.id) else { throw FakeError(description: "no batch \(batch.id)") }
            b.requestIds.append(row.id)
            if failure == .itemCheckFailed || failure == .mainCheckFailed { b.candidates[row.id] = String(repeating: "c", count: 40) }
            try b.update(db)
        }
        return r
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

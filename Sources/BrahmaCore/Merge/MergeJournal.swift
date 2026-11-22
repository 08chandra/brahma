import Foundation
import GRDB

/// Where one batch of the merge queue is (Plan 4a Task 2). Each step is written to `mergeBatch` as the batch passes it, so a
/// crash or the owner's stop leaves a record of how far it got and `MergeQueue.recover` knows what is safe to do next.
///
/// `preparing` and `prepared` belong to the plan's "unattributed-changes commit", which Task 1b's S1 ruling retired: the queue
/// never commits the workspace root, so it never writes either step. They stay in the enum so an older or foreign row decodes;
/// recovery treats one defensively (the batch is abandoned and nothing moves `main`).
public enum MergeStep: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case claimed, preparing, prepared, rebased, checked, backedUp, landing, landed, recorded, cleaned, done

    /// Position in the journal; a batch only moves to a higher or equal one.
    public var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// One batch of the merge queue as the journal records it.
public struct MergeBatch: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mergeBatch"

    public var id: String
    public var companyId: String
    /// Per company, in claim order.
    public var number: Int
    /// `main` when the batch was built on it.
    public var base: String? = nil
    public var step: MergeStep
    public var requestIds: [String]
    public var expectedParent: String? = nil
    public var preparedCommit: String? = nil
    /// Request id → the candidate commit that carries it (the batch's rebased chain).
    public var candidates: [String: String] = [:]
    /// The commit `main` is moved to.
    public var landCommit: String? = nil
    /// The requests that land with `landCommit`, in order.
    public var landedIds: [String] = []
    public var error: String? = nil
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date? = nil

    public init(id: String = UUID().uuidString, companyId: String, number: Int, step: MergeStep = .claimed, requestIds: [String],
                startedAt: Date) {
        self.id = id; self.companyId = companyId; self.number = number; self.step = step; self.requestIds = requestIds
        self.startedAt = startedAt; self.updatedAt = startedAt
    }

    private static func list(_ json: String?) -> [String] {
        json.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
    }

    public init(row: Row) throws {
        id = row["id"]; companyId = row["companyId"]; number = row["number"]; base = row["base"]
        let raw: String = row["step"]
        step = MergeStep(rawValue: raw) ?? .claimed
        requestIds = Self.list(row["requestIds"])
        expectedParent = row["expectedParent"]; preparedCommit = row["preparedCommit"]
        let json: String = row["candidates"] ?? "{}"
        candidates = (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
        landCommit = row["landCommit"]; landedIds = Self.list(row["landedIds"]); error = row["error"]
        startedAt = row["startedAt"]; updatedAt = row["updatedAt"]; finishedAt = row["finishedAt"]
    }

    public func encode(to container: inout PersistenceContainer) throws {
        func json<T: Encodable>(_ value: T) -> String { String(decoding: (try? JSONEncoder().encode(value)) ?? Data(), as: UTF8.self) }
        container["id"] = id; container["companyId"] = companyId; container["number"] = number; container["base"] = base
        container["step"] = step.rawValue; container["requestIds"] = json(requestIds)
        container["expectedParent"] = expectedParent; container["preparedCommit"] = preparedCommit
        container["candidates"] = json(candidates); container["landCommit"] = landCommit; container["landedIds"] = json(landedIds)
        container["error"] = error; container["startedAt"] = startedAt; container["updatedAt"] = updatedAt
        container["finishedAt"] = finishedAt
    }
}

/// Tests only: lets a test stop the engine right after the journal wrote a step, as a crash would (nothing after it runs and
/// nothing is cleaned up). Set by `Store.journalProbe`.
final class JournalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var body: (@Sendable (String) -> Bool)?
    /// The body is called with a step's raw value (right after the journal wrote it), or `"moved"` (right after `main` moved,
    /// before `landed` is written); true: crash there.
    func set(_ new: (@Sendable (String) -> Bool)?) { lock.withLock { body = new } }
    func crashes(after label: String) -> Bool { lock.withLock { body }?(label) ?? false }
}

/// Thrown by the queue where `JournalProbe` asked for a simulated crash.
struct SimulatedCrash: Error {}

extension Store {
    // MARK: Reads

    public func mergeBatch(id: String) throws -> MergeBatch? {
        try writer.read { db in try MergeBatch.fetchOne(db, key: id) }
    }

    /// The company's batches that have not reached `done`, oldest first.
    public func openMergeBatches(companyId: String) throws -> [MergeBatch] {
        try writer.read { db in
            try MergeBatch.filter(Column("companyId") == companyId && Column("step") != MergeStep.done.rawValue)
                .order(Column("number")).fetchAll(db)
        }
    }

    public func mergeBatches(companyId: String, limit: Int = 50) throws -> [MergeBatch] {
        try writer.read { db in
            try MergeBatch.filter(Column("companyId") == companyId).order(Column("number").desc).limit(limit).fetchAll(db)
        }
    }

    // MARK: Engine writes

    /// Writes the batch's row in the claim's own transaction (`claimMergeBatch`).
    static func insertMergeBatch(_ db: Database, id: String, companyId: String, requests: [MergeRequest], now: Date) throws {
        let number = (try Int.fetchOne(db, sql: "SELECT MAX(number) FROM mergeBatch WHERE companyId = ?", arguments: [companyId]) ?? 0) + 1
        try MergeBatch(id: id, companyId: companyId, number: number, requestIds: requests.map(\.id), startedAt: now).insert(db)
    }

    /// Moves the batch to `step` (or updates the fields of the step it is at): never backwards, `WorkError.conflict("batch already
    /// at <step>")`. Only the fields given are written. `done` stamps `finishedAt`. This writes the journal and nothing else:
    /// it never touches `main`, `company.mainCommit` or a request.
    func advanceBatch(id: String, to step: MergeStep, base: String? = nil, candidates: [String: String]? = nil, landCommit: String? = nil,
                      landedIds: [String]? = nil, error: String? = nil, now: Date = Store.now()) throws {
        let shownError = try error.map { try redact(Self.flat($0, max: 300)) }
        try writer.write { db in
            guard var batch = try MergeBatch.fetchOne(db, key: id) else { throw WorkError.notFound("no such merge batch") }
            guard step.order >= batch.step.order else { throw WorkError.conflict("batch already at \(batch.step.rawValue)") }
            // A finished batch is not reopened or rewritten (a same-step update of `done` included).
            guard batch.step != .done else { throw WorkError.conflict("batch already at done") }
            batch.step = step
            if let base { batch.base = base }
            if let candidates { batch.candidates = candidates }
            if let landCommit { batch.landCommit = landCommit }
            if let landedIds { batch.landedIds = landedIds }
            if let shownError { batch.error = shownError }
            batch.updatedAt = now
            if step == .done { batch.finishedAt = now }
            try batch.update(db)
        }
    }

    /// Whether a test asked the engine to stop as if it crashed right after `step` was journaled.
    func journalCrash(after step: MergeStep) throws { try journalCrash(label: step.rawValue) }

    func journalCrash(label: String) throws {
        if journalProbe.crashes(after: label) { throw SimulatedCrash() }
    }
}

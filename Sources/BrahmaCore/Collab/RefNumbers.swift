import Foundation
import GRDB

/// C3b fix round 3, controller Ruling 50: the kinds of ref number a company hands out (`F-`, `AR-`, `A-`, `mem:`, item
/// keys, releases, sprints, grants, merge requests and batches), each from its own per-company counter (`refCounter`).
public enum RefCounterKind: String, Sendable {
    case resource, artifact, ask, memory, item, release, sprint, grant, mergeRequest, mergeBatch
    /// Plan C Task C4c: the owner's show requests.
    case showRequest

    /// The table whose rows hold this kind's numbers (`number`, per `companyId`).
    var table: String {
        switch self {
        case .resource: "resource"
        case .artifact: "artifact"
        case .ask: "ask"
        case .memory: "memoryEntry"
        case .item: "workItem"
        case .release: "release"
        case .sprint: "sprint"
        case .grant: "grant"
        case .mergeRequest: "mergeRequest"
        case .mergeBatch: "mergeBatch"
        case .showRequest: "showRequest"
        }
    }
}

extension Store {
    /// What the owner reads for a ref whose number was handed out and whose object is gone (discarded, swept): never another
    /// object under its number. Agents get the generic refusal.
    public static let removedText = "that file was removed"

    /// Ruling 50: the next `count` numbers of `kind` in the company (returns the first), from a counter that only moves
    /// forward: one past the greater of its last value and `floor` (the highest number the kind's rows, vault files or memory
    /// docs hold, so numbers given before the counter existed are never given again). In the caller's write transaction.
    static func nextRefNumber(db: Database, companyId: String, kind: RefCounterKind, floor: Int, count: Int = 1) throws -> Int {
        let first = try peekRefNumber(db: db, companyId: companyId, kind: kind, floor: floor)
        try db.execute(sql: """
            INSERT INTO refCounter (companyId, kind, last) VALUES (?, ?, ?)
            ON CONFLICT(companyId, kind) DO UPDATE SET last = MAX(last, excluded.last)
            """, arguments: [companyId, kind.rawValue, first + max(1, count) - 1])
        return first
    }

    /// The number `nextRefNumber` would hand out now (a preview: nothing is taken). Never at or below a number a row of the
    /// kind holds, whatever the counter says and whatever `floor` the caller passes (fix round 4, N3-2: belt and braces).
    static func peekRefNumber(db: Database, companyId: String, kind: RefCounterKind, floor: Int) throws -> Int {
        let last = try Int.fetchOne(db, sql: "SELECT last FROM refCounter WHERE companyId = ? AND kind = ?",
                                    arguments: [companyId, kind.rawValue]) ?? 0
        return max(last, floor, try highestRow(db: db, companyId: companyId, kind: kind)) + 1
    }

    /// The highest number a row of `kind` holds in the company (0 when none).
    static func highestRow(db: Database, companyId: String, kind: RefCounterKind) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(number), 0) FROM \"\(kind.table)\" WHERE companyId = ?", arguments: [companyId]) ?? 0
    }

    static func nextAskNumber(db: Database, companyId: String) throws -> Int {
        try nextRefNumber(db: db, companyId: companyId, kind: .ask, floor: try Int.fetchOne(db, sql:
            "SELECT COALESCE(MAX(number), 0) FROM ask WHERE companyId = ?", arguments: [companyId]) ?? 0)
    }

    /// The ask number `nextAskNumber` would take now (nothing is taken).
    static func peekAskNumber(db: Database, companyId: String) throws -> Int {
        try peekRefNumber(db: db, companyId: companyId, kind: .ask, floor: try Int.fetchOne(db, sql:
            "SELECT COALESCE(MAX(number), 0) FROM ask WHERE companyId = ?", arguments: [companyId]) ?? 0)
    }

    static func nextMergeRequestNumber(db: Database, companyId: String) throws -> Int {
        try nextRefNumber(db: db, companyId: companyId, kind: .mergeRequest, floor: try Int.fetchOne(db, sql:
            "SELECT MAX(number) FROM mergeRequest WHERE companyId = ?", arguments: [companyId]) ?? 0)
    }

    static func highestRelease(_ db: Database, _ companyId: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(number), 0) FROM release WHERE companyId = ?", arguments: [companyId]) ?? 0
    }

    /// Whether `number` of `kind` was handed out in the company (by the counter).
    static func refNumberIssued(db: Database, companyId: String, kind: RefCounterKind, number: Int) throws -> Bool {
        guard number > 0 else { return false }
        let last = try Int.fetchOne(db, sql: "SELECT last FROM refCounter WHERE companyId = ? AND kind = ?",
                                    arguments: [companyId, kind.rawValue]) ?? 0
        return number <= last
    }

    /// Whether `F-<number>` was handed out and its row is gone (`removedText`).
    func resourceRemoved(companyId: String, number: Int) throws -> Bool {
        try writer.read { db in
            try Store.refNumberIssued(db: db, companyId: companyId, kind: .resource, number: number)
                && (try Store.resource(db: db, companyId: companyId, number: number)) == nil
        }
    }

    // MARK: Share leases (Ruling 51)

    /// A tests-only failure of a lease-item write (`RefHooks.failLeaseKinds`).
    struct ShareLeaseInjectedFailure: Error {}

    /// A share in progress: what it made (copies, snapshots, share refs) is never swept while the lease is live. Released when
    /// the share ends, however it ends; if its process dies, it expires after `ShareLimits.leaseExpiry`.
    func beginShareLease(companyId: String, now: Date) throws -> String {
        let id = UUID().uuidString
        try writer.write { db in
            try db.execute(sql: "INSERT INTO shareLease (id, companyId, expiresAt) VALUES (?, ?, ?)",
                           arguments: [id, companyId, now.addingTimeInterval(ShareLimits.leaseExpiry)])
        }
        return id
    }

    /// Puts `artifact` under the share's lease (right after it is made, or before, for a share ref).
    func leaseShareArtifact(_ lease: String, companyId: String, _ artifact: ShareArtifact) throws {
        let (kind, ref) = Self.leaseKey(artifact)
        if refHooks.failLeaseKinds.contains(kind) { throw ShareLeaseInjectedFailure() }
        try writer.write { db in
            try db.execute(sql: "INSERT INTO shareLeaseItem (leaseId, companyId, kind, ref) VALUES (?, ?, ?, ?)",
                           arguments: [lease, companyId, kind, ref])
        }
    }

    /// Releases the lease (its items go with it).
    func endShareLease(_ lease: String) {
        try? writer.write { db in try db.execute(sql: "DELETE FROM shareLease WHERE id = ?", arguments: [lease]) }
    }

    static func leaseKey(_ artifact: ShareArtifact) -> (kind: String, ref: String) {
        switch artifact {
        case .resource(let n): ("resource", String(n))
        case .snapshot(let id): ("snapshot", id)
        case .shareRef(let id): ("shareRef", id)
        }
    }

    /// Whether a live lease holds `artifact` at `now` (in the caller's transaction).
    static func leased(db: Database, companyId: String, _ artifact: ShareArtifact, now: Date) throws -> Bool {
        let (kind, ref) = leaseKey(artifact)
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM shareLeaseItem i JOIN shareLease l ON l.id = i.leaseId
                          WHERE i.companyId = ? AND i.kind = ? AND i.ref = ? AND l.expiresAt > ?)
            """, arguments: [companyId, kind, ref, now]) ?? true
    }
}

import Foundation
import GRDB

// The rows of migration `vC-refs` (Plan C Task C2a), one property per column. JSON columns are kept as their stored text.

/// A ref a message carries: an attachment, a share or an inline chip, pinned as it was shared (C3b writes them).
public struct MessageRef: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messageRef"

    public var id: String
    public var companyId: String
    public var messageId: String
    public var position: Int
    public var canonical: String
    /// `WorkRefKind.rawValue`.
    public var kind: String
    public var refId: String
    public var branch: String?
    public var rev: String?
    public var rangeStart: Int?
    public var rangeEnd: Int?
    /// JSON object (`WorkRef.params` as pinned).
    public var params: String
    /// ML's `AccessClass.kind` and id.
    public var accessKind: String
    public var accessId: String?
    /// ML's `Sensitivity.rawValue`.
    public var sensitivity: String
    /// JSON array of restrictions.
    public var restrictions: String
    /// JSON array of agent ids, or nil.
    public var readerSet: String?
    public var tainted: Bool
    public var taintReason: String?
    /// `ok`, `redacted` or `purged`.
    public var state: String
    public var inline: Bool
    public var createdAt: Date

    public init(id: String = UUID().uuidString, companyId: String, messageId: String, position: Int, canonical: String, kind: String,
                refId: String, branch: String? = nil, rev: String? = nil, rangeStart: Int? = nil, rangeEnd: Int? = nil,
                params: String = "{}", accessKind: String, accessId: String? = nil, sensitivity: String = "normal",
                restrictions: String = "[]", readerSet: String? = nil, tainted: Bool = false, taintReason: String? = nil,
                state: String = "ok", inline: Bool = false, createdAt: Date) {
        self.id = id; self.companyId = companyId; self.messageId = messageId; self.position = position; self.canonical = canonical
        self.kind = kind; self.refId = refId; self.branch = branch; self.rev = rev; self.rangeStart = rangeStart
        self.rangeEnd = rangeEnd; self.params = params; self.accessKind = accessKind; self.accessId = accessId
        self.sensitivity = sensitivity; self.restrictions = restrictions; self.readerSet = readerSet; self.tainted = tainted
        self.taintReason = taintReason; self.state = state; self.inline = inline; self.createdAt = createdAt
    }
}

/// One read of shared content: every `open_ref`, show render, preview tab, export, view-original and materialized copy.
public struct RefRead: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "refRead"

    public var id: String
    public var companyId: String
    /// `owner`, `agent` or `concierge`.
    public var readerKind: String
    /// The agent id for an agent reader.
    public var readerId: String?
    public var canonical: String
    /// The commit (or blob) read, when there is one.
    public var rev: String?
    public var bytes: Int?
    public var tainted: Bool
    /// `open_ref`, `show`, `tab`, `export`, `viewOriginal` or `materialize`.
    public var via: String
    public var turnId: String?
    public var createdAt: Date
    /// C5 fix round 1: for `via = export`, the file the owner saved (so a purge lists it as a copy outside Brahma).
    public var exportPath: String? = nil

    public init(id: String = UUID().uuidString, companyId: String, readerKind: String, readerId: String?, canonical: String,
                rev: String?, bytes: Int?, tainted: Bool, via: String, turnId: String?, createdAt: Date, exportPath: String? = nil) {
        self.id = id; self.companyId = companyId; self.readerKind = readerKind; self.readerId = readerId; self.canonical = canonical
        self.rev = rev; self.bytes = bytes; self.tainted = tainted; self.via = via; self.turnId = turnId; self.createdAt = createdAt
        self.exportPath = exportPath
    }

    /// The stored reader kind and id of a reader.
    static func reader(_ r: Reader) -> (kind: String, id: String?) {
        switch r {
        case .owner: ("owner", nil)
        case .concierge: ("concierge", nil)
        case .agent(let id): ("agent", id)
        }
    }
}

/// Bytes the engine keeps in the vault for a ref: a worktree diff as it was shared (`worktreeDiff`, keyed by the message ref),
/// or a committed diff (`diffCache`, keyed `<base>..<head>[/<path hash>]`), verified by `sha256` on every read.
public struct RefSnapshot: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "refSnapshot"

    public var id: String
    public var companyId: String
    /// `worktreeDiff` or `diffCache`.
    public var kind: String
    public var cacheKey: String
    /// Relative to the company's vault root (`snapshots/<id>.patch`, `diffcache/<id>.patch`).
    public var vaultPath: String
    public var sha256: String
    public var bytes: Int
    public var tainted: Bool
    public var taintReason: String?
    public var createdAt: Date
    public var purgedAt: Date?

    public init(id: String = UUID().uuidString, companyId: String, kind: String, cacheKey: String, vaultPath: String, sha256: String,
                bytes: Int, tainted: Bool = false, taintReason: String? = nil, createdAt: Date, purgedAt: Date? = nil) {
        self.id = id; self.companyId = companyId; self.kind = kind; self.cacheKey = cacheKey; self.vaultPath = vaultPath
        self.sha256 = sha256; self.bytes = bytes; self.tainted = tainted; self.taintReason = taintReason; self.createdAt = createdAt
        self.purgedAt = purgedAt
    }

    public static let worktreeDiff = "worktreeDiff"
    public static let diffCache = "diffCache"
}

/// A commit made by a session that had read outside content (recorded at the end of its holder's turn). It taints every diff
/// and file ref whose history holds it until the review gate merges it (`clearedBy = "review"`) or the owner vouches for it
/// (`"owner"`). Keyed by `(companyId, sha)`: the same commit in two companies' repositories is two rows.
public struct TaintedCommit: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "taintedCommit"

    public var companyId: String
    public var sha: String
    public var itemId: String?
    public var agentId: String?
    public var turnId: String?
    /// What the session had read (ML's `currentTaint`).
    public var source: String
    public var createdAt: Date
    public var clearedBy: String?
    public var clearedAt: Date?
    /// The commit the engine's rebase replayed it as (`carryTaintThroughRebase`): no longer on the branch, and not an orphan.
    public var carriedTo: String?

    /// A row whose `sha` is `unrecorded-<id>`: the commits of an item could not be listed, so none of them is provably clean.
    public static let unrecordedPrefix = "unrecorded-"

    public init(companyId: String, sha: String, itemId: String?, agentId: String?, turnId: String?, source: String, createdAt: Date,
                clearedBy: String? = nil, clearedAt: Date? = nil, carriedTo: String? = nil) {
        self.companyId = companyId; self.sha = sha; self.itemId = itemId; self.agentId = agentId; self.turnId = turnId
        self.source = source; self.createdAt = createdAt; self.clearedBy = clearedBy; self.clearedAt = clearedAt
        self.carriedTo = carriedTo
    }
}

/// Ruling 22 (P2 R5-1): a restore over a live database that could not be read, for one company. What the restored database
/// can't place reads tainted until the owner vouches (`Store.vouchRestoredCommits`; `brahma vouch restore <company>` or the
/// restore alert's Inbox action): every commit not in `mainCommit`'s history (no `mainCommit`: every commit), and every file
/// or diff whose range from `mainCommit` is not empty (Rulings 24 and 25), whether or not the epoch is `listed`. `listed`
/// only says the restore also recorded the commits off `mainCommit` that every ref and worktree held then as `taintedCommit`
/// rows naming this epoch (attribution to items; never a reason to read anything clean).
public struct RestoreEpoch: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "restoreEpoch"

    public var id: String
    public var companyId: String
    public var mainCommit: String?
    public var listed: Bool
    public var source: String
    public var createdAt: Date
    public var clearedBy: String?
    public var clearedAt: Date?

    /// The `taintOrder` subject of the epoch's clearing.
    public var orderSubject: String { "restore-epoch:\(id)" }
}

/// What one purge deleted (written by C2b's `Store.purge`). The list columns are JSON arrays.
public struct PurgeLog: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "purgeLog"

    public var id: String
    public var companyId: String
    public var canonical: String
    public var vaultPaths: String
    public var gitRefs: String
    public var backupsFlagged: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, companyId: String, canonical: String, vaultPaths: String, gitRefs: String,
                backupsFlagged: String, createdAt: Date) {
        self.id = id; self.companyId = companyId; self.canonical = canonical; self.vaultPaths = vaultPaths; self.gitRefs = gitRefs
        self.backupsFlagged = backupsFlagged; self.createdAt = createdAt
    }
}

extension Store {
    /// The newest reads of `canonical` in the company, newest first (the app's READS toggle and the preview footer).
    public func refReads(companyId: String, canonical: String, limit: Int) throws -> [RefRead] {
        try writer.read { db in
            try RefRead.fetchAll(db, sql: """
                SELECT * FROM refRead WHERE companyId = ? AND canonical = ? ORDER BY createdAt DESC, rowid DESC LIMIT ?
                """, arguments: [companyId, canonical, max(0, limit)])
        }
    }

    /// Writes one read.
    static func recordRefRead(db: Database, companyId: String, reader: Reader, canonical: String, rev: String?, bytes: Int?,
                           tainted: Bool, via: String, turnId: String?, now: Date, exportPath: String? = nil) throws {
        let who = RefRead.reader(reader)
        try RefRead(companyId: companyId, readerKind: who.kind, readerId: who.id, canonical: canonical, rev: rev, bytes: bytes,
                    tainted: tainted, via: via, turnId: turnId, createdAt: now, exportPath: exportPath).insert(db)
    }
}

/// Tests only: seams of the ref code (`Store.refHooks`): the git runner `refGit` uses (a fake that fails), a company read
/// that fails at a turn's taint record, the purge fence's data home for an in-memory store, a step inside a purge, and a
/// redaction that misses (C2b fix round 2).
final class RefHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var runner: (any GitProcessRunning)?
    private var companyReadFails = false

    var gitRunner: (any GitProcessRunning)? { lock.withLock { runner } }
    var failCompanyRead: Bool { lock.withLock { companyReadFails } }
    func setGitRunner(_ r: (any GitProcessRunning)?) { lock.withLock { runner = r } }
    func setFailCompanyRead(_ fails: Bool) { lock.withLock { companyReadFails = fails } }
    private var fence: URL?
    private var afterTurnCheck: (@Sendable () throws -> Void)?
    /// The data home whose purge fence turn starts take when the store has none (an in-memory store).
    var fenceHome: URL? { lock.withLock { fence } }
    /// Runs between the purge's first running-turn check and its fence (a turn starting in that window).
    var afterPurgeTurnCheck: (@Sendable () throws -> Void)? { lock.withLock { afterTurnCheck } }
    func setFenceHome(_ home: URL?) { lock.withLock { fence = home } }
    private var wait: Duration?
    /// How long an item check or an extension trial waits for a purge holding the fence (R4-6), and (round 5) a purge for
    /// the fence; nil: `PurgeFence.defaultWait`.
    var fenceWait: Duration? { lock.withLock { wait } }
    func setFenceWait(_ wait: Duration?) { lock.withLock { self.wait = wait } }
    func setAfterPurgeTurnCheck(_ body: (@Sendable () throws -> Void)?) { lock.withLock { afterTurnCheck = body } }
    private var redaction: (@Sendable (Data) -> Data)?
    /// Makes the redacted copies the gate checks again (a redaction that misses something), in place of `RedactedCopy.make`.
    var redactedCopy: (@Sendable (Data) -> Data)? { lock.withLock { redaction } }
    func setRedactedCopy(_ body: (@Sendable (Data) -> Data)?) { lock.withLock { redaction = body } }
    private var sharePostFails = false
    /// C3b fix round 1: a share's or attachment's post fails inside its write transaction (after every pin and snapshot).
    var failSharePost: Bool { lock.withLock { sharePostFails } }
    func setFailSharePost(_ fails: Bool) { lock.withLock { sharePostFails = fails } }
    private var shareRefFails = false
    /// C3b fix round 2 (Ruling 49): `pinRef` fails right after it wrote a share ref.
    var failAfterShareRef: Bool { lock.withLock { shareRefFails } }
    func setFailAfterShareRef(_ fails: Bool) { lock.withLock { shareRefFails = fails } }
    private var prepared: (@Sendable () throws -> Void)?
    /// C3b fix round 2 (N-1): runs after a share's refs are prepared, before its post (where the channel and inline refs are read).
    var afterSharePrepared: (@Sendable () throws -> Void)? { lock.withLock { prepared } }
    func setAfterSharePrepared(_ body: (@Sendable () throws -> Void)?) { lock.withLock { prepared = body } }
    private var exportOpened: (@Sendable () throws -> Void)?
    /// C5 fix round 1, ruling (3): runs after an export opened its folder, before it writes there (a folder swapped meanwhile).
    var afterExportFolderOpened: (@Sendable () throws -> Void)? { lock.withLock { exportOpened } }
    func setAfterExportFolderOpened(_ body: (@Sendable () throws -> Void)?) { lock.withLock { exportOpened = body } }
    private var leaseFails: Set<String> = []
    /// C3b fix round 4 (N3-1): putting a share artifact of these lease kinds (`resource`, `snapshot`, `shareRef`) under a
    /// share's lease fails (a lease write that hits BUSY or a full disk).
    var failLeaseKinds: Set<String> { lock.withLock { leaseFails } }
    func setFailLeaseKinds(_ kinds: Set<String>) { lock.withLock { leaseFails = kinds } }
}

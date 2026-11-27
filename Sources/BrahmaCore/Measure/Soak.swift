import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What the soak harness records of one company before it kills the engine (Plan X6a Task 7): enough to tell, after the
/// restart, whether anything was lost, left half-done or done twice. Written by `brahma measure <co> --soak-checkpoint <file>`
/// (0600, through `EngineFiles`, into the directory the owner named) and read back by `--soak-verify <file>`.
public struct SoakCheckpoint: Codable, Equatable, Sendable {
    public var companyId: String
    /// Whole seconds (the file carries ISO 8601 without fractions).
    public var takenAt: Date
    /// `main`'s commit.
    public var mainTip: String
    /// Item key → the commit its branch (`refs/heads/item/<key>`) names.
    public var itemHeads: [String: String]
    /// Item key → `workItem.verifiedCommit`, for every item that has one.
    public var verifiedCommits: [String: String]
    /// Item key → the agent id holding its lease.
    public var leases: [String: String]
    /// Release id → how many times its deploy step had started (`deployStartedAt` set: 1; never: 0). There is no execution
    /// counter: exactly-once is the release's status compare-and-swap (inventory §2.14).
    public var releaseExecutions: [String: Int]
    /// The merge batches not at `done`.
    public var openBatches: [String]
    /// The turns `inProgress` (the turns a kill right after this would cut).
    public var runningTurns: [String]
    /// When the engine holding the data home's lock started (`SoakEngine.startedAt`); nil when none was running. Whole seconds.
    public var engineStartedAt: Date?

    public init(companyId: String, takenAt: Date, mainTip: String, itemHeads: [String: String], verifiedCommits: [String: String],
                leases: [String: String], releaseExecutions: [String: Int], openBatches: [String], runningTurns: [String],
                engineStartedAt: Date?) {
        self.companyId = companyId; self.takenAt = takenAt.wholeSeconds; self.mainTip = mainTip; self.itemHeads = itemHeads
        self.verifiedCommits = verifiedCommits; self.leases = leases; self.releaseExecutions = releaseExecutions
        self.openBatches = openBatches; self.runningTurns = runningTurns; self.engineStartedAt = engineStartedAt?.wholeSeconds
    }

    /// The company's state now: one store snapshot (every query the company's own), then `main` and the item branches. Read-only.
    public static func take(store: Store, git: GitWorkspace, companyId: String, now: Date, engineStartedAt: Date? = nil) throws -> SoakCheckpoint {
        struct Rows { var verified: [String: String] = [:]; var leases: [String: String] = [:]; var releases: [String: Int] = [:]
                      var batches: [String] = []; var turns: [String] = [] }
        let rows: Rows = try store.writer.read { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM company WHERE id = ?", arguments: [companyId]) == 1 else {
                throw MeasureError.unknownCompany(companyId)
            }
            var r = Rows()
            for row in try Row.fetchAll(db, sql: "SELECT key, verifiedCommit FROM workItem WHERE companyId = ? AND verifiedCommit IS NOT NULL",
                                        arguments: [companyId]) {
                r.verified[row["key"]] = row["verifiedCommit"]
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT w.key AS key, l.agentId AS agentId FROM workLease l JOIN workItem w ON w.id = l.itemId
                WHERE l.companyId = ? AND w.companyId = ?
                """, arguments: [companyId, companyId]) {
                r.leases[row["key"]] = row["agentId"]
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, deployStartedAt FROM release WHERE companyId = ?", arguments: [companyId]) {
                let started: Date? = row["deployStartedAt"]
                r.releases[row["id"]] = started == nil ? 0 : 1
            }
            r.batches = try String.fetchAll(db, sql: "SELECT id FROM mergeBatch WHERE companyId = ? AND step <> ? ORDER BY number",
                                            arguments: [companyId, MergeStep.done.rawValue])
            r.turns = try String.fetchAll(db, sql: "SELECT id FROM turn WHERE companyId = ? AND outcome = ? ORDER BY startedAt",
                                          arguments: [companyId, TurnOutcome.inProgress.rawValue])
            return r
        }
        guard let tip = try git.head(of: GitWorkspace.mainRef) else { throw MeasureError.noMainBranch(companyId) }
        return SoakCheckpoint(companyId: companyId, takenAt: now, mainTip: tip, itemHeads: try git.itemBranchHeads(),
                              verifiedCommits: rows.verified, leases: rows.leases, releaseExecutions: rows.releases,
                              openBatches: rows.batches, runningTurns: rows.turns, engineStartedAt: engineStartedAt)
    }

    /// The most bytes a checkpoint file is read up to.
    static let readLimit = 16 << 20

    /// Writes the checkpoint to `file`, 0600, atomically (a temporary file renamed over the name), through `EngineFiles` rooted
    /// at `file`'s directory, which must exist: no link is followed, a link planted at the name is replaced, never written
    /// through.
    public func write(to file: URL) throws {
        let dir = file.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MeasureError.noSuchDirectory(dir.path)
        }
        try EngineFiles.replace(try json(), workspace: dir, dir: "", name: file.lastPathComponent, mode: 0o600)
    }

    /// The checkpoint in `file`, read through `EngineFiles` (a regular file, no link followed, at most `readLimit` bytes).
    public static func read(from file: URL) throws -> SoakCheckpoint {
        let dir = file.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MeasureError.noSuchDirectory(dir.path)
        }
        let data: Data
        do {
            guard let read = try EngineFiles.read(workspace: dir, dir: "", name: file.lastPathComponent, limit: readLimit + 1) else {
                throw MeasureError.badCheckpoint("\(file.path) does not exist")
            }
            data = read
        } catch let error as UnsafeEngineFile { throw MeasureError.badCheckpoint("\(error)") }
        guard data.count <= readLimit else { throw MeasureError.badCheckpoint("\(file.path) is larger than \(readLimit) bytes") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(SoakCheckpoint.self, from: data) } catch {
            throw MeasureError.badCheckpoint("\(file.path) does not decode as one (\(error.localizedDescription))")
        }
    }

    /// ISO 8601 dates, sorted keys, pretty-printed.
    public func json() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(self)
    }
}

/// Whether an engine runs on a data home, and since when (rulings R16, R40): there is no engine service on this tree. Liveness
/// is the `flock` an engine (`brahma run` or the app) holds on `<home>/orchestrator.lock` (`OrchestratorLock`); its start is the
/// modification time of `<home>/run/.sentinel`, which every `Orchestrator.start()` writes anew.
public enum SoakEngine {
    /// The running engine's start, or nil when no engine holds the lock (or one holds it but has not written its start yet).
    /// The probe takes a shared lock for an instant when none is held, then drops it: an engine started in that instant is
    /// refused ("already running") and must be started again; the owner's soak script never starts one while it probes.
    public static func startedAt(paths: BrahmaPaths) throws -> Date? {
        let lock = paths.home.appending(path: "orchestrator.lock").path
        let fd = open(lock, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let err = errno
            if err == ENOENT { return nil }
            throw MeasureError.engineStateUnreadable("\(lock): \(String(cString: strerror(err)))")
        }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        let err = errno
        guard err == EWOULDBLOCK else { throw MeasureError.engineStateUnreadable("\(lock): \(String(cString: strerror(err)))") }
        var st = stat()
        guard lstat(paths.sentinel.path, &st) == 0 else { return nil }
        #if canImport(Darwin)
        let mtime = st.st_mtimespec
        #else
        let mtime = st.st_mtim
        #endif
        return Date(timeIntervalSince1970: Double(mtime.tv_sec) + Double(mtime.tv_nsec) / 1_000_000_000)
    }
}

/// One check's outcome. `wait` is not a failure: the engine has not run long enough (or at all) to judge.
public enum SoakResult: String, Codable, Sendable { case pass, fail, wait }

public struct SoakCheck: Codable, Equatable, Sendable {
    public var name: String
    public var result: SoakResult
    public var detail: String
    public init(name: String, result: SoakResult, detail: String) { self.name = name; self.result = result; self.detail = detail }
}

/// The seven checks after a restart, and the verdict: `wait` when any check waits, else `fail` when any fails, else `pass`.
public struct SoakVerdict: Codable, Equatable, Sendable {
    public var companyId: String
    public var checkpointTakenAt: Date
    public var verifiedAt: Date
    public var engineStartedAt: Date?
    public var checks: [SoakCheck]
    public var result: SoakResult
    public var passed: Bool { result == .pass }

    public init(companyId: String, checkpointTakenAt: Date, verifiedAt: Date, engineStartedAt: Date?, checks: [SoakCheck]) {
        self.companyId = companyId; self.checkpointTakenAt = checkpointTakenAt; self.verifiedAt = verifiedAt.wholeSeconds
        self.engineStartedAt = engineStartedAt?.wholeSeconds; self.checks = checks
        result = checks.contains { $0.result == .wait } ? .wait : checks.contains { $0.result == .fail } ? .fail : .pass
    }

    /// `soak verify: <result> (checkpoint <time>; engine started <time>)`, then one `<result> <check>: <detail>` line per check.
    /// Plain text (details name items, agents and releases): a terminal caller sanitizes every line.
    public func lines() -> [String] {
        let engine = engineStartedAt.map { "engine started \(MeasureReport.iso($0))" } ?? "no engine running"
        return ["soak verify: \(result.rawValue) (checkpoint \(MeasureReport.iso(checkpointTakenAt)); \(engine))"]
            + checks.map { "\($0.result.rawValue) \($0.name): \($0.detail)" }
    }

    public func json() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> SoakVerdict {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(SoakVerdict.self, from: data)
    }
}

/// The soak verdict (Plan X6a Task 7): the company's state now against a checkpoint taken before the engine was killed.
/// Read-only: one store snapshot and a few git reads of the company's own workspace.
///
/// 1. `settled`: the engine has run at least `settle` wall seconds since its last start (the owner's script keeps the Mac awake
///    with `caffeinate -i`); no engine running, or not long enough, is `wait`.
/// 2. `noLostCommits`: every commit of the checkpoint (`mainTip`, `itemHeads`, `verifiedCommits`) is still in the repository,
///    and `main` still contains the old tip unless a restore recorded after the checkpoint explains it (`restoreMain`,
///    `restoreEpoch`: the restore marker's records).
/// 3. `leasesRecovered`: no item `inProgress` without a lease; no lease held by a killed (or missing) agent; every lease of the
///    checkpoint is still held by the same live agent, or released with its item no longer `inProgress`.
/// 4. `noStuckMerges`: no merge batch short of `done` for more than `stuckAfter` seconds since the later of its last step and
///    the engine's start.
/// 5. `noDuplicateOutsideActions`: no release's deploy step started again after the checkpoint, and no two releases of the
///    same commit to the same project started deploying (one of them after the checkpoint) unless the later was rolled back.
///    Channel actions are not applicable (X4 absent).
/// 6. `interruptedTurnsRecorded`: every turn running at the checkpoint has ended (the restart records them `interrupted`), no
///    turn started before the engine's start is still `inProgress`, and no agent is `running` without a turn in progress.
/// 7. `companyRunning`: the company is `running`, has started a turn since the engine's start, no engine alert was filed for it
///    since the checkpoint and the engine is not on hold (owner-wide): nothing asked the owner for more than a login.
public enum SoakVerify {
    /// The checks, in the order the verdict lists them.
    public static let checkNames = ["settled", "noLostCommits", "leasesRecovered", "noStuckMerges", "noDuplicateOutsideActions",
                                    "interruptedTurnsRecorded", "companyRunning"]
    /// Seconds the engine must have run since its start before the verdict is judged.
    public static let defaultSettle: TimeInterval = 300
    /// Seconds a merge batch may sit short of `done` (since the later of its last step and the engine's start) before it is stuck.
    public static let stuckAfter: TimeInterval = 600
    /// `--soak-verify`'s exit code for `wait` (0 pass, 1 fail, 2 could not verify).
    public static let waitExitCode: Int32 = 3
    /// The environment variable that lowers the settle time for tests. Honoured only in DEBUG builds.
    public static let settleOverride = "BRAHMA_SOAK_SETTLE_SECONDS"

    /// The settle time: `defaultSettle`, or (DEBUG builds only) a positive whole number of seconds from `settleOverride`.
    public static func settle(environment: [String: String]) -> TimeInterval {
        #if DEBUG
        if let raw = environment[settleOverride], let seconds = Int(raw), seconds > 0 { return TimeInterval(seconds) }
        #endif
        return defaultSettle
    }

    public static func run(_ before: SoakCheckpoint, store: Store, git: GitWorkspace, now: Date, engineStartedAt: Date?,
                           settle: TimeInterval = defaultSettle) throws -> SoakVerdict {
        // Ruling R42(a): only an engine started after the checkpoint is a restart; an older start (the checkpoint's own, reused)
        // judges nothing, and turns are never counted from it.
        let restart = restartedAt(before, engineStartedAt: engineStartedAt)
        let state = try State.read(store: store, before: before, engineStartedAt: restart)
        var checks: [SoakCheck] = []
        checks.append(settled(before, engineStartedAt: engineStartedAt, restart: restart, now: now, settle: settle))
        checks.append(try noLostCommits(before, git: git, restores: state.restores))
        checks.append(leasesRecovered(before, state))
        checks.append(noStuckMerges(before, state, now: now, engineStartedAt: engineStartedAt))
        checks.append(noDuplicateOutsideActions(before, state))
        checks.append(interruptedTurnsRecorded(before, state, engineStartedAt: engineStartedAt))
        checks.append(companyRunning(state))
        return SoakVerdict(companyId: before.companyId, checkpointTakenAt: before.takenAt, verifiedAt: now, engineStartedAt: engineStartedAt,
                           checks: checks)
    }

    // MARK: The records, in one read

    struct Lease { var itemId: String; var key: String; var agentId: String; var agentName: String?; var agentState: String? }
    struct Restore { var line: String; var mainCommit: String? }
    struct Batch { var id: String; var number: Int; var step: String; var updatedAt: Date }
    struct ReleaseRow { var id: String; var number: Int; var status: String; var provider: String; var project: String; var commit: String
                        var deployStartedAt: Date? }

    struct State {
        var companyName = ""
        var companyRunning = false
        /// Item key → (id, status), every item of the company.
        var items: [String: (id: String, status: String)] = [:]
        var leases: [Lease] = []
        /// Agents `running` with no turn in progress: their names.
        var stuckRunning: [String] = []
        /// Turns `inProgress`: id → start.
        var inProgress: [String: Date] = [:]
        /// The checkpoint's running turns: id → outcome now (a turn gone from the table has none).
        var checkpointTurns: [String: String] = [:]
        /// Turns of the company started at or after the engine's start (nil: no engine running).
        var turnsSinceStart: Int?
        var openBatches: [Batch] = []
        /// The checkpoint's open batches as they are now: id → (number, step).
        var checkpointBatches: [String: (number: Int, step: String)] = [:]
        var releases: [ReleaseRow] = []
        /// Restores recorded at or after the checkpoint, each with the `main` it restored to (nil: none recorded).
        var restores: [Restore] = []
        /// Engine alerts filed for the company at or after the checkpoint: `A-<n> <title>`.
        var alerts: [String] = []
        /// The owner-wide engine hold, if any: `<reason> since <time>`.
        var hold: String?

        static func read(store: Store, before: SoakCheckpoint, engineStartedAt: Date?) throws -> State {
            let companyId = before.companyId
            return try store.writer.read { db in
                guard let company = try Row.fetchOne(db, sql: "SELECT name, status FROM company WHERE id = ?", arguments: [companyId]) else {
                    throw MeasureError.unknownCompany(companyId)
                }
                var s = State()
                s.companyName = company["name"]
                let status: String = company["status"]
                s.companyRunning = status == CompanyStatus.running.rawValue
                for row in try Row.fetchAll(db, sql: "SELECT id, key, status FROM workItem WHERE companyId = ?", arguments: [companyId]) {
                    s.items[row["key"]] = (row["id"], row["status"])
                }
                s.leases = try Row.fetchAll(db, sql: """
                    SELECT l.itemId AS itemId, w.key AS key, l.agentId AS agentId, a.name AS name, a.state AS state
                    FROM workLease l JOIN workItem w ON w.id = l.itemId LEFT JOIN agent a ON a.id = l.agentId AND a.companyId = ?
                    WHERE l.companyId = ? AND w.companyId = ?
                    """, arguments: [companyId, companyId, companyId]).map {
                    Lease(itemId: $0["itemId"], key: $0["key"], agentId: $0["agentId"], agentName: $0["name"], agentState: $0["state"])
                }
                s.stuckRunning = try String.fetchAll(db, sql: """
                    SELECT a.name FROM agent a WHERE a.companyId = ? AND a.state = ?
                      AND NOT EXISTS (SELECT 1 FROM turn t WHERE t.agentId = a.id AND t.companyId = ? AND t.outcome = ?)
                    ORDER BY a.name
                    """, arguments: [companyId, AgentState.running.rawValue, companyId, TurnOutcome.inProgress.rawValue])
                for row in try Row.fetchAll(db, sql: "SELECT id, startedAt FROM turn WHERE companyId = ? AND outcome = ?",
                                            arguments: [companyId, TurnOutcome.inProgress.rawValue]) {
                    s.inProgress[row["id"]] = row["startedAt"]
                }
                if let start = engineStartedAt {
                    s.turnsSinceStart = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM turn WHERE companyId = ? AND startedAt >= ?",
                                                         arguments: [companyId, start])
                }
                for chunk in chunks(before.runningTurns) {
                    let marks = chunk.map { _ in "?" }.joined(separator: ", ")
                    for row in try Row.fetchAll(db, sql: "SELECT id, outcome FROM turn WHERE companyId = ? AND id IN (\(marks))",
                                                arguments: StatementArguments([companyId]) + StatementArguments(chunk)) {
                        s.checkpointTurns[row["id"]] = row["outcome"]
                    }
                }
                s.openBatches = try Row.fetchAll(db, sql: """
                    SELECT id, number, step, updatedAt FROM mergeBatch WHERE companyId = ? AND step <> ? ORDER BY number
                    """, arguments: [companyId, MergeStep.done.rawValue]).map {
                    Batch(id: $0["id"], number: $0["number"], step: $0["step"], updatedAt: $0["updatedAt"])
                }
                for chunk in chunks(before.openBatches) {
                    let marks = chunk.map { _ in "?" }.joined(separator: ", ")
                    for row in try Row.fetchAll(db, sql: "SELECT id, number, step FROM mergeBatch WHERE companyId = ? AND id IN (\(marks))",
                                                arguments: StatementArguments([companyId]) + StatementArguments(chunk)) {
                        s.checkpointBatches[row["id"]] = (row["number"], row["step"])
                    }
                }
                s.releases = try Row.fetchAll(db, sql: """
                    SELECT id, number, status, provider, project, "commit" AS sha, deployStartedAt FROM release WHERE companyId = ? ORDER BY number
                    """, arguments: [companyId]).map {
                    ReleaseRow(id: $0["id"], number: $0["number"], status: $0["status"], provider: $0["provider"], project: $0["project"],
                               commit: $0["sha"], deployStartedAt: $0["deployStartedAt"])
                }
                for row in try Row.fetchAll(db, sql: """
                    SELECT e.restoredAt AS at, m.mainCommit AS mainCommit FROM restoreMain m JOIN restoreEvent e ON e.nonce = m.nonce
                    WHERE m.companyId = ? AND e.restoredAt >= ? ORDER BY e.restoredAt
                    """, arguments: [companyId, before.takenAt]) {
                    let at: Date = row["at"], main: String? = row["mainCommit"]
                    s.restores.append(Restore(line: "restore at \(MeasureReport.iso(at))", mainCommit: main))
                }
                for row in try Row.fetchAll(db, sql: """
                    SELECT createdAt AS at, mainCommit FROM restoreEpoch WHERE companyId = ? AND createdAt >= ? ORDER BY createdAt
                    """, arguments: [companyId, before.takenAt]) {
                    let at: Date = row["at"], main: String? = row["mainCommit"]
                    s.restores.append(Restore(line: "restore at \(MeasureReport.iso(at)) over an unreadable database", mainCommit: main))
                }
                for row in try Row.fetchAll(db, sql: """
                    SELECT number, title FROM ask WHERE companyId = ? AND kind = ? AND createdAt >= ? ORDER BY number
                    """, arguments: [companyId, AskKind.engineAlert.rawValue, before.takenAt]) {
                    let number: Int = row["number"], title: String = row["title"]
                    s.alerts.append("A-\(number) \(title)")
                }
                // Owner-wide: one engine hold freezes every company (inventory §2.18).
                if let hold = try Row.fetchOne(db, sql: "SELECT reason, since FROM engineHold WHERE id = ?", arguments: [1]) {
                    let reason: String = hold["reason"], since: Date = hold["since"]
                    s.hold = "\(reason) since \(MeasureReport.iso(since))"
                }
                return s
            }
        }

        /// SQLite's bound-parameter limit is 999 on older builds: ids in chunks of 500.
        static func chunks(_ ids: [String]) -> [[String]] {
            stride(from: 0, to: ids.count, by: 500).map { Array(ids[$0..<min($0 + 500, ids.count)]) }
        }
    }

    // MARK: The checks

    /// The engine's start when it is a restart: later than the checkpoint, and not the start the checkpoint recorded.
    static func restartedAt(_ before: SoakCheckpoint, engineStartedAt: Date?) -> Date? {
        guard let start = engineStartedAt, start > before.takenAt, start.wholeSeconds != before.engineStartedAt else { return nil }
        return start
    }

    static func settled(_ before: SoakCheckpoint, engineStartedAt: Date?, restart: Date?, now: Date, settle: TimeInterval) -> SoakCheck {
        guard let start = restart else {
            let why = engineStartedAt.map { "start \(MeasureReport.iso($0)), checkpoint \(MeasureReport.iso(before.takenAt))" }
                ?? "no engine is running"
            return SoakCheck(name: "settled", result: .wait, detail: "the engine has not restarted since the checkpoint (\(why))")
        }
        let up = now.timeIntervalSince(start)
        let shown = "engine up \(Int(max(0, up).rounded(.down))) s of the \(Int(settle)) s settle"
        return SoakCheck(name: "settled", result: up >= settle ? .pass : .wait, detail: shown)
    }

    static func noLostCommits(_ before: SoakCheckpoint, git: GitWorkspace, restores: [Restore]) throws -> SoakCheck {
        var named: [(what: String, sha: String)] = [("main", before.mainTip)]
        named += before.itemHeads.sorted { $0.key < $1.key }.map { ("\($0.key) branch", $0.value) }
        named += before.verifiedCommits.sorted { $0.key < $1.key }.map { ("\($0.key) verified", $0.value) }
        let missing = Set(try git.missingCommits(Array(Set(named.map(\.sha)))))
        var problems = named.filter { missing.contains($0.sha) }.map { "\($0.what) \($0.sha.prefix(7)) is missing" }
        var notes: [String] = []
        if let tip = try git.head(of: GitWorkspace.mainRef) {
            // Strict: a git error is "could not verify" (exit 2), never a rewind.
            if !missing.contains(before.mainTip), try !git.isAncestorStrict(before.mainTip, of: tip) {
                let rewind = "main was rewound: \(tip.prefix(7)) does not contain the checkpoint's \(before.mainTip.prefix(7))"
                // A restore explains it only if main still contains the commit the restore put it at (when one is recorded).
                var explaining: [String] = [], off: [String] = []
                for restore in restores {
                    guard let restored = restore.mainCommit else { explaining.append("\(restore.line) (main not recorded)"); continue }
                    let gone = try missing.contains(restored) || !git.missingCommits([restored]).isEmpty
                    if gone {
                        off.append("\(restore.line) to \(restored.prefix(7)), which is missing")
                    } else if try git.isAncestorStrict(restored, of: tip) {
                        explaining.append("\(restore.line) (main \(restored.prefix(7)))")
                    } else {
                        off.append("\(restore.line) to \(restored.prefix(7)), which is not on main")
                    }
                }
                if explaining.isEmpty {
                    problems.append(off.isEmpty ? rewind : "\(rewind); not explained by \(off.joined(separator: ", "))")
                } else {
                    notes.append("\(rewind); explained by \(explaining.joined(separator: ", "))")
                }
            }
        } else {
            problems.append("main is gone")
        }
        let total = Set(named.map(\.sha)).count
        if problems.isEmpty {
            let base = "all \(total) commit\(total == 1 ? "" : "s") of the checkpoint present; main contains \(before.mainTip.prefix(7))"
            return SoakCheck(name: "noLostCommits", result: .pass, detail: notes.isEmpty ? base : notes.joined(separator: "; "))
        }
        return SoakCheck(name: "noLostCommits", result: .fail, detail: (problems + notes).joined(separator: "; "))
    }

    static func leasesRecovered(_ before: SoakCheckpoint, _ s: State) -> SoakCheck {
        var problems: [String] = []
        let leased = Set(s.leases.map(\.itemId))
        let orphans = s.items.filter { $0.value.status == WorkItemStatus.inProgress.rawValue && !leased.contains($0.value.id) }.keys.sorted()
        if !orphans.isEmpty { problems.append("in progress with no lease: \(orphans.joined(separator: ", "))") }
        for lease in s.leases.sorted(by: { $0.key < $1.key }) {
            if lease.agentState == nil { problems.append("\(lease.key) is leased to an agent that no longer exists") }
            else if lease.agentState == AgentState.killed.rawValue { problems.append("\(lease.key) is leased to @\(lease.agentName ?? lease.agentId), who was killed") }
        }
        var kept = 0, released = 0
        let now = Dictionary(s.leases.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for (key, agentId) in before.leases.sorted(by: { $0.key < $1.key }) {
            if let lease = now[key] {
                if lease.agentId == agentId { kept += 1 } else { released += 1 }
                continue
            }
            guard let item = s.items[key] else { problems.append("\(key), leased at the checkpoint, no longer exists"); continue }
            // Released: the item moved on; `inProgress` without a lease is the orphan above.
            if item.status != WorkItemStatus.inProgress.rawValue { released += 1 }
        }
        let summary = "\(before.leases.count) lease\(before.leases.count == 1 ? "" : "s") at the checkpoint: \(kept) still held by the same agent, "
            + "\(released) released or passed on; \(s.leases.count) held now"
        return problems.isEmpty ? SoakCheck(name: "leasesRecovered", result: .pass, detail: summary)
            : SoakCheck(name: "leasesRecovered", result: .fail, detail: problems.joined(separator: "; ") + " (\(summary))")
    }

    static func noStuckMerges(_ before: SoakCheckpoint, _ s: State, now: Date, engineStartedAt: Date?) -> SoakCheck {
        var stuck: [String] = []
        for batch in s.openBatches {
            let from = max(batch.updatedAt, engineStartedAt ?? batch.updatedAt)
            let age = now.timeIntervalSince(from)
            if age > stuckAfter { stuck.append("B-\(batch.number) at \(batch.step) for \(Int(age)) s") }
        }
        let earlier = before.openBatches.map { id -> String in
            guard let b = s.checkpointBatches[id] else { return "\(id.prefix(8)) gone" }
            return "B-\(b.number) now \(b.step)"
        }
        var detail = "\(s.openBatches.count) batch\(s.openBatches.count == 1 ? "" : "es") open now"
        if !earlier.isEmpty { detail += "; open at the checkpoint: \(earlier.joined(separator: ", "))" }
        return stuck.isEmpty ? SoakCheck(name: "noStuckMerges", result: .pass, detail: detail)
            : SoakCheck(name: "noStuckMerges", result: .fail,
                        detail: "stuck past \(Int(stuckAfter)) s: \(stuck.joined(separator: ", ")) (\(detail))")
    }

    static func noDuplicateOutsideActions(_ before: SoakCheckpoint, _ s: State) -> SoakCheck {
        var problems: [String] = []
        // The checkpoint's `takenAt` is whole seconds, rounded down: a start one second past it is after the checkpoint.
        let after = before.takenAt.addingTimeInterval(1)
        for r in s.releases where before.releaseExecutions[r.id] == 1 {
            if let started = r.deployStartedAt, started >= after {
                problems.append("R-\(r.number) deployed twice: its deploy step started again at \(MeasureReport.iso(started))")
            }
        }
        let started = s.releases.filter { $0.deployStartedAt != nil && $0.status != ReleaseStatus.rolledBack.rawValue }
        let groups = Dictionary(grouping: started) { "\($0.provider) \($0.project) \($0.commit)" }
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            guard group.contains(where: { ($0.deployStartedAt ?? .distantPast) >= before.takenAt }) else { continue }
            let refs = group.sorted { $0.number < $1.number }.map { "R-\($0.number) (\($0.status))" }
            problems.append("\(refs.joined(separator: " and ")) deployed \(group[0].commit.prefix(7)) to \(group[0].project) more than once")
        }
        let executed = s.releases.filter { $0.deployStartedAt != nil }.count
        let summary = "\(executed) release\(executed == 1 ? "" : "s") deployed or deploying, each once; channel actions not applicable: channels (X4) absent"
        return problems.isEmpty ? SoakCheck(name: "noDuplicateOutsideActions", result: .pass, detail: summary)
            : SoakCheck(name: "noDuplicateOutsideActions", result: .fail, detail: problems.joined(separator: "; "))
    }

    static func interruptedTurnsRecorded(_ before: SoakCheckpoint, _ s: State, engineStartedAt: Date?) -> SoakCheck {
        var problems: [String] = []
        var outcomes: [String: Int] = [:]
        for id in before.runningTurns {
            guard let outcome = s.checkpointTurns[id] else { problems.append("turn \(id.prefix(8)) is gone"); continue }
            if outcome == TurnOutcome.inProgress.rawValue { problems.append("turn \(id.prefix(8)) is still in progress") }
            else { outcomes[outcome, default: 0] += 1 }
        }
        if let start = engineStartedAt {
            let left = s.inProgress.filter { $0.value < start && !before.runningTurns.contains($0.key) }.keys.sorted()
            if !left.isEmpty { problems.append("turns started before the engine's start still in progress: \(left.map { String($0.prefix(8)) }.joined(separator: ", "))") }
        }
        if !s.stuckRunning.isEmpty {
            problems.append("running with no turn in progress: \(s.stuckRunning.map { "@\($0)" }.joined(separator: ", "))")
        }
        let ended = outcomes.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        let summary = "\(before.runningTurns.count) turn\(before.runningTurns.count == 1 ? "" : "s") running at the checkpoint"
            + (ended.isEmpty ? "" : ", ended: \(ended)")
        return problems.isEmpty ? SoakCheck(name: "interruptedTurnsRecorded", result: .pass, detail: summary)
            : SoakCheck(name: "interruptedTurnsRecorded", result: .fail, detail: problems.joined(separator: "; ") + " (\(summary))")
    }

    static func companyRunning(_ s: State) -> SoakCheck {
        var problems: [String] = []
        if !s.companyRunning { problems.append("\(s.companyName) is paused") }
        let turns = s.turnsSinceStart ?? 0
        if s.turnsSinceStart == 0 { problems.append("no turn started since the engine's start") }
        guard s.turnsSinceStart != nil else {
            // No restart since the checkpoint (ruling R42(a)): nothing to count turns from.
            let base = "no restart since the checkpoint to count turns from"
            return problems.isEmpty ? SoakCheck(name: "companyRunning", result: .pass, detail: base)
                : SoakCheck(name: "companyRunning", result: .fail, detail: problems.joined(separator: "; ") + " (\(base))")
        }
        if !s.alerts.isEmpty { problems.append("engine alerts since the checkpoint: \(s.alerts.joined(separator: "; "))") }
        if let hold = s.hold { problems.append("the engine is on hold (\(hold))") }
        let summary = "\(turns) turn\(turns == 1 ? "" : "s") started since the engine's start; no engine alert or hold"
        return problems.isEmpty ? SoakCheck(name: "companyRunning", result: .pass, detail: summary)
            : SoakCheck(name: "companyRunning", result: .fail, detail: problems.joined(separator: "; "))
    }
}

import Foundation
import GRDB

/// One `sandboxCanary` row: the sandbox canary passed for this CLI build, settings shape and macOS version (`v5-owner-guard`).
public struct SandboxCanaryKey: Hashable, Sendable {
    public var fingerprint: String
    public var shape: String
    public var osVersion: String
    /// The CLI's `--version`, for the log and the alert (not part of the key).
    public var cliVersion: String?

    public init(fingerprint: String, shape: String, osVersion: String, cliVersion: String? = nil) {
        self.fingerprint = fingerprint; self.shape = shape; self.osVersion = osVersion; self.cliVersion = cliVersion
    }

    public static func == (a: Self, b: Self) -> Bool { a.fingerprint == b.fingerprint && a.shape == b.shape && a.osVersion == b.osVersion }
    public func hash(into h: inout Hasher) { h.combine(fingerprint); h.combine(shape); h.combine(osVersion) }
    var text: String { "\(fingerprint)|\(shape)|\(osVersion)" }
}

extension Store {
    /// The process of a turn, recorded right after it was spawned (`StreamEvent.spawned`).
    public func setTurnPid(turnId: String, pid: Int32) throws {
        try writer.write { db in _ = try Turn.filter(key: turnId).updateAll(db, Column("pid").set(to: pid)) }
    }

    /// The processes of the turns still in progress, as the database recorded them (informational: no start-time check, so a
    /// crash's leftover row could name a reused pid). The owner-command guard and every stop path use `recordedTurnLeaders`
    /// instead; nothing signals from this set.
    public func runningTurnPids() throws -> Set<Int32> {
        try writer.read { db in try Self.runningTurnPids(db) }
    }

    static func runningTurnPids(_ db: Database) throws -> Set<Int32> {
        Set(try Int32.fetchAll(db, sql: "SELECT pid FROM turn WHERE outcome = ? AND pid IS NOT NULL",
                               arguments: [TurnOutcome.inProgress.rawValue]))
    }


    /// The live leaders of the turns the runner recorded under `<runDir>/turns` (`TurnRecords`), read without changing
    /// anything (a damaged record is skipped, never quarantined): what an owner command run from a shell checks its ancestry
    /// against. The runner records the leader at spawn, the same pid `StreamEvent.spawned` reports and `turn.pid` stores; the
    /// database is not opened, so a read-only command (`brahma restore --dry-run`) touches no file of it. A pid whose start
    /// time no longer matches the record is a reused pid and does not count.
    public static func recordedTurnLeaders(paths: BrahmaPaths) -> Set<Int32> {
        let dir = paths.runDir.appending(path: "turns", directoryHint: .isDirectory)
        var out = Set<Int32>()
        for agentId in TurnRecords.agentIds(in: dir) {
            guard let url = try? TurnRecords.file(agentId: agentId, in: dir) else { continue }
            var st = stat()
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, let data = FileManager.default.contents(atPath: url.path),
                  let records = try? JSONDecoder().decode([TurnRecord].self, from: data) else { continue }
            for r in records where r.leader > 0 {
                if let entry = ProcessTable.entry(r.leader), entry.start == r.leaderStart { out.insert(r.leader) }
            }
        }
        return out
    }

    /// Whether the sandbox canary passed for this key.
    public func sandboxVerified(fingerprint: String, shape: String, osVersion: String) throws -> Bool {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sandboxCanary WHERE cliFingerprint = ? AND settingsShape = ? AND osVersion = ?",
                             arguments: [fingerprint, shape, osVersion]) ?? 0 > 0
        }
    }

    public func sandboxVerified(_ key: SandboxCanaryKey) throws -> Bool {
        try sandboxVerified(fingerprint: key.fingerprint, shape: key.shape, osVersion: key.osVersion)
    }

    /// Records a passing canary (replacing an earlier pass of the same key) and, with `resolveAlert`, answers the open
    /// sandbox-check alert (the gate passes false while another key is still failing).
    public func recordCanary(_ key: SandboxCanaryKey, detail: String, now: Date = Store.now(), resolveAlert: Bool = true) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO sandboxCanary (cliFingerprint, settingsShape, osVersion, cliVersion, passedAt, detail)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [key.fingerprint, key.shape, key.osVersion, key.cliVersion, now, detail])
            if resolveAlert { try resolveEngineAlerts(db, reasons: [EngineAlerts.sandboxCheckReason], now: now) }
        }
    }

    /// Answers the open sandbox-check alert (a waiting key passed outside the engine and no other waited-on key is failing).
    public func resolveSandboxCheckAlert(now: Date = Store.now()) throws {
        try writer.write { db in try resolveEngineAlerts(db, reasons: [EngineAlerts.sandboxCheckReason], now: now) }
    }

    /// Gives back one use of each grant (I2): a turn that consumed them and then did not launch. A grant revoked since stays
    /// revoked; only its counts go back.
    func restoreGrants(ids: [String], now: Date = Store.now()) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            for id in ids {
                guard var g = try Grant.fetchOne(db, key: id), g.useCount > 0 else { continue }
                g.useCount -= 1
                if let uses = g.usesLeft { g.usesLeft = uses + 1 }
                try g.update(db)
            }
        }
    }
}

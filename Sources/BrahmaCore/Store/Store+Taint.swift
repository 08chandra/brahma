import Foundation
import GRDB

/// One commit of an agent's lab and the taint state of the turn that first recorded it (Task 10, read by Task 10b).
public struct LabCommit: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "labCommit"
    public var agentId: String
    public var sha: String
    public var turnId: String?
    public var tainted: Bool
    public var recordedAt: Date
}

extension Store {
    /// The scope key `pendingSessionResetScope` stores: '' for the base session, else the item id (B-M12).
    static func scopeKey(_ itemId: String?) -> String { itemId ?? "" }

    // MARK: Taint

    static let maxTaintSources = 50

    /// Whether what `actorId` writes now carries a tainted origin (I2): an agent whose session is tainted (row or flag file). An
    /// agent row that cannot be read counts as tainted; the owner and the engine never are.
    func writesTainted(db: Database, actorId: String) throws -> Bool {
        guard actorId != "owner", actorId != "system" else { return false }
        guard let agent = try Agent.fetchOne(db, key: actorId) else { return true }
        if agent.sessionTainted { return true }
        guard let home = dataHome, let flag = TaintFlag.url(home: home, agentId: actorId) else { return false }
        return TaintFlag.exists(flag)
    }

    /// The tainted-origin items a turn is about to read (its inbox, its work notices, its item's latest hand-off), as a source
    /// for `markTainted` (`relayed: ...`), or nil.
    public func relayedTaint(inbox: [(InboxItem, Message, Channel)], notices: [PendingNotice], handoff: Handoff?,
                             handles: [String: String]) -> String? {
        func who(_ id: String) -> String { "@" + (handles[id] ?? "unknown") }
        // C3b: a message stamped with its session's taint (`fromTaintedSession`) relays it as the write-time mark does.
        if let m = inbox.first(where: { $0.1.taintedOrigin || $0.1.fromTaintedSession }) { return "relayed: message from \(who(m.1.senderId))" }
        if let n = notices.first(where: { $0.event.taintedOrigin }) { return "relayed: \(n.itemKey) \(n.event.kind.rawValue) by \(who(n.event.actorId))" }
        if let h = handoff, h.taintedOrigin { return "relayed: hand-off by \(who(h.authorId))" }
        return nil
    }

    /// Marks the agent's session tainted, and its in-progress turn (the first source wins on the turn). A newly tainted session
    /// writes one activity event. The source is redacted; when the redactor is not loaded only its kind (`bash`, ...) is kept.
    public func markTainted(agentId: String, source: String, now: Date = Store.now()) throws {
        let shown: String
        if let redacted = try? redact(TaintPolicy.flat(source)) { shown = Store.flat(redacted, max: 120) }
        else { shown = String(source.split(separator: ":", maxSplits: 1).first ?? "outside content") }
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            try db.execute(sql: """
                UPDATE turn SET taintedAt = ?, taintSource = ? WHERE agentId = ? AND outcome = ? AND taintedAt IS NULL
                """, arguments: [now, shown, agentId, TurnOutcome.inProgress.rawValue])
            // The item the agent holds is now worked on by a tainted session (its worktree files, fix round 2). Not from a review
            // or audit turn: it works in a throwaway session, not on the items it holds.
            let kind = try String.fetchOne(db, sql: """
                SELECT kind FROM turn WHERE agentId = ? AND outcome = ? ORDER BY startedAt DESC, rowid DESC LIMIT 1
                """, arguments: [agentId, TurnOutcome.inProgress.rawValue])
            if kind != TurnKind.review.rawValue, kind != TurnKind.audit.rawValue { try Store.markHeldItemsTainted(db: db, agentId: agentId) }
            // S22: every source is kept for the session (a verdict is exempt only when all are the reviewed item's relay).
            var sources = agent.taintSources.split(separator: "\n").map(String.init)
            if !sources.contains(shown), sources.count < Store.maxTaintSources {
                sources.append(shown)
                try db.execute(sql: "UPDATE agent SET taintSources = ? WHERE id = ?", arguments: [sources.joined(separator: "\n"), agentId])
            } else if !sources.contains(shown) {
                // Too many to keep: a marker no verdict exemption accepts.
                try db.execute(sql: "UPDATE agent SET taintSources = taintSources || ? WHERE id = ? AND taintSources NOT LIKE '%(more sources)%'",
                               arguments: ["\n(more sources)", agentId])
            }
            // I2 (10b): the agent's lab is writable on every turn, so a tainted session has worked in it: the sticky lab mark.
            try Store.markLabTainted(db, agentId: agentId, source: shown, now: now)
            guard !agent.sessionTainted else { return }
            try db.execute(sql: "UPDATE agent SET sessionTainted = 1 WHERE id = ?", arguments: [agentId])
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: nil, kind: .error,
                              text: "@\(agent.name) read outside content (\(shown)); its high-risk tools are off until a fresh session",
                              createdAt: now).insert(db)
        }
    }

    /// Marks every item the agent holds a lease on (worktree files written by a tainted session); done items are left alone.
    static func markHeldItemsTainted(db: Database, agentId: String) throws {
        try db.execute(sql: """
            UPDATE workItem SET taintedOrigin = 1 WHERE status <> 'done'
              AND id IN (SELECT itemId FROM \(WorkLease.databaseTableName) WHERE agentId = ?)
            """, arguments: [agentId])
    }

    /// At a holder turn's end (fix round 2): a session that is tainted now marks the items it holds, even when the taint came
    /// from an earlier turn of the same session. Plan C Ruling 20: also every item the turn touched and no longer holds, as the
    /// turn-end taint record takes them: those it held as the turn started (`heldAtStart`) and every item in the turn's claim
    /// log (`turnId`), released since or not. Done items are left alone. `home`: where the hook flag file is read (the
    /// orchestrator's data home), else the store's.
    /// `force` (final wave B1, Ruling 23: the retry of a turn-end mark that failed): marks as if the session were tainted, since
    /// whether it was can no longer be told (a fresh-session reset may have cleared it since).
    public func markHeldItemsIfTainted(agentId: String, turnId: String? = nil, heldAtStart: [String] = [], home: URL? = nil,
                                       force: Bool = false) throws {
        if refHooks.failTaintRecords { throw WorkError.conflict("injected: the held items could not be marked") }
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId) else { return }
            var tainted = agent.sessionTainted || force
            if !tainted, let home = home ?? dataHome, let flag = TaintFlag.url(home: home, agentId: agentId) { tainted = TaintFlag.exists(flag) }
            guard tainted else { return }
            try Store.markHeldItemsTainted(db: db, agentId: agentId)
            var touched = Set(heldAtStart)
            if let turnId {
                touched.formUnion(try String.fetchAll(db, sql: "SELECT itemId FROM leaseClaim WHERE agentId = ? AND turnId = ?",
                                                      arguments: [agentId, turnId]))
            }
            for itemId in touched {
                try db.execute(sql: "UPDATE workItem SET taintedOrigin = 1 WHERE id = ? AND companyId = ? AND status <> 'done'",
                               arguments: [itemId, agent.companyId])
            }
        }
    }

    /// A review or audit turn's throwaway session ended (S19): the agent's own sessions were clean before it, so its flags go
    /// back to clean. The flag file (a hook error) stays: fail closed.
    public func endThrowawaySessionTaint(agentId: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE agent SET sessionTainted = 0, freshSessionRequested = 0, taintSources = '' WHERE id = ?",
                           arguments: [agentId])
        }
    }

    /// The most recent taint source of the agent's turns, if any.
    public func latestTaintSource(agentId: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT taintSource FROM turn WHERE agentId = ? AND taintedAt IS NOT NULL ORDER BY taintedAt DESC, rowid DESC LIMIT 1
                """, arguments: [agentId])
        }
    }

    /// A high-risk call was refused under taint: the turn's end starts a fresh session.
    public func requestFreshSession(agentId: String) throws {
        try writer.write { db in try db.execute(sql: "UPDATE agent SET freshSessionRequested = 1 WHERE id = ?", arguments: [agentId]) }
    }

    /// At a turn's end: when a fresh session was requested, `forceFreshSession(reason: "tainted")` for the turn's scope (its
    /// next turn there carries the reason), every other session of the agent is reset too (the flag is agent-wide, so no
    /// session that may hold the outside content survives it), both flags are cleared and the flag file removed. Returns
    /// whether it reset.
    @discardableResult
    public func clearTaintIfRequested(agentId: String, scope: SessionScope, now: Date = Store.now()) throws -> Bool {
        let cleared = try writer.write { db -> Bool in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.freshSessionRequested else { return false }
            // I2 (10b), S30: the flag is read inside the transaction that marks the lab; the file is removed only after it commits.
            let flagged = dataHome.flatMap { TaintFlag.url(home: $0, agentId: agentId) }.map(TaintFlag.exists) ?? false
            if flagged || agent.sessionTainted {
                try Store.markLabTainted(db, agentId: agentId, source: flagged ? TaintPolicy.hookErrorSource : "tainted session", now: now)
            }
            try Store.forceFreshSession(db: db, agentId: agentId, itemId: scope.itemId, reason: "tainted", now: now)
            try db.execute(sql: "DELETE FROM agentSession WHERE agentId = ?", arguments: [agentId])
            if scope.itemId != nil { try Store.resetSession(db: db, agentId: agentId, scope: .base) }
            try db.execute(sql: "UPDATE agent SET sessionTainted = 0, freshSessionRequested = 0, taintSources = '' WHERE id = ?",
                           arguments: [agentId])
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: nil, kind: .stateChanged,
                              text: "@\(agent.name)'s next turn starts a fresh session (tainted)", createdAt: now).insert(db)
            return true
        }
        if cleared, let home = dataHome { TaintFlag.remove(home: home, agentId: agentId) }
        return cleared
    }

    // MARK: Hook gates

    public func recordHookGate(_ gate: String, fingerprint: String, now: Date = Store.now()) throws {
        try writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO hookGate (gate, cliFingerprint, passedAt) VALUES (?, ?, ?)",
                           arguments: [gate, fingerprint, now])
        }
    }

    public func hookGatePassed(_ gate: String, fingerprint: String) throws -> Bool {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hookGate WHERE gate = ? AND cliFingerprint = ?",
                             arguments: [gate, fingerprint]) ?? 0 > 0
        }
    }

    // MARK: Extensions

    /// The publisher the taint rule sees for `extId` in this company: the one it was installed from; for a `company:`
    /// extension whose lab history is tainted (10b), `third-party:lab-tainted`; for a Brahma built-in that is not installed
    /// under that id, `brahma`; nil when it is not installed (which taints).
    public func extensionPublisher(companyId: String, extId: String) throws -> String? {
        let row = try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT publisher, sourceType FROM companyExtension WHERE companyId = ? AND id = ?",
                             arguments: [companyId, extId])
        }
        guard let row else { return BuiltinExtensions.ids.contains(extId) ? ExtensionPublisher.brahma : nil }
        let publisher: String = row["publisher"] ?? ""
        let sourceType: String = row["sourceType"] ?? ""
        guard !publisher.isEmpty else { return nil }
        return sourceType == ExtensionSourceKind.labTainted ? ExtensionSourceKind.taintedPublisher : publisher
    }

    // MARK: Lab provenance

    /// Records lab commits not seen before with the turn's taint state; returns how many were new.
    @discardableResult
    /// Nothing records clean while the machine-wide mark (S32) or the agent's company mark (N1) stands, nor a commit the
    /// owner's clear snapshot found (`taintedLabCommit`). After a company or machine-wide clear (S33), a commit records clean
    /// only when it is in `observed`: what the engine saw made during this clean turn (the lab's commits now, minus those at
    /// the turn's start). Committer time is never provenance.
    public func recordLabCommits(agentId: String, turnId: String?, shas: [String], tainted: Bool, observed: Set<String>? = nil,
                                 now: Date = Store.now()) throws -> Int {
        guard !shas.isEmpty else { return 0 }
        return try writer.write { db in
            let machine = try Row.fetchOne(db, sql: "SELECT source, clearedAt FROM machineTaint WHERE id = 1")
            let machineSource: String? = machine?["source"]
            let companyRow = try Row.fetchOne(db, sql: """
                SELECT c.source, c.clearedAt FROM companyTaint c JOIN agent a ON a.companyId = c.companyId WHERE a.id = ?
                """, arguments: [agentId])
            let companySource: String? = companyRow?["source"]
            let machineCleared: Date? = machine?["clearedAt"], companyCleared: Date? = companyRow?["clearedAt"]
            let marked = machineSource != nil || companySource != nil
            let observedOnly = machineCleared != nil || companyCleared != nil
            var added = 0
            for sha in shas where sha.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil {
                var tainted = tainted || marked
                if !tainted, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM taintedLabCommit WHERE sha = ?", arguments: [sha]) ?? 0 > 0 {
                    tainted = true
                }
                if !tainted, observedOnly, !(observed?.contains(sha) ?? false) { tainted = true }
                try db.execute(sql: """
                    INSERT OR IGNORE INTO labCommit (agentId, sha, turnId, tainted, recordedAt) VALUES (?, ?, ?, ?, ?)
                    """, arguments: [agentId, sha, turnId, tainted, now])
                added += db.changesCount
            }
            return added
        }
    }

    public func labCommits(agentId: String) throws -> [LabCommit] {
        try writer.read { db in try LabCommit.filter(Column("agentId") == agentId).order(Column.rowID).fetchAll(db) }
    }

    /// Whether a lab commit is tainted for 10b: recorded tainted, or not recorded at all (fail closed).
    public func labCommitTainted(agentId: String, sha: String) throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT tainted FROM labCommit WHERE agentId = ? AND sha = ?", arguments: [agentId, sha]) ?? true
        }
    }

    // MARK: Lab mark (10b, I2)

    /// Commits a clear's snapshot found (S33): never recorded clean in any lab.
    public func recordTaintedLabCommits(_ shas: [String], now: Date = Store.now()) throws {
        guard !shas.isEmpty else { return }
        try writer.write { db in
            for sha in shas where sha.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil {
                try db.execute(sql: "INSERT OR IGNORE INTO taintedLabCommit (sha, recordedAt) VALUES (?, ?)", arguments: [sha, now])
            }
        }
    }

    /// The sticky lab mark: set the first time a session of the agent is tainted (kept, with that first source); cleared only by
    /// the owner (`clearLabTaint`).
    /// Without a sandbox (the role runs Workspace or Full in its company; an engine ceiling only narrows that, so this can only
    /// over-mark), the session's Bash could write any lab of the company: every lab there is marked (fail closed).
    static func markLabTainted(_ db: Database, agentId: String, source: String, now: Date) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO labTaint (agentId, source, markedAt) VALUES (?, ?, ?)",
                       arguments: [agentId, Store.flat(source, max: 200), now])
        guard let agent = try Agent.fetchOne(db, key: agentId), let company = try Company.fetchOne(db, key: agent.companyId) else { return }
        let profile = company.profile(forRole: agent.role)
        guard profile != .sandboxed else { return }
        let shown = Store.flat("@\(agent.name) on the \(profile.rawValue) profile: \(source)", max: 200)
        try db.execute(sql: """
            INSERT OR IGNORE INTO labTaint (agentId, source, markedAt) SELECT id, ?, ? FROM agent WHERE companyId = ? AND id <> ?
            """, arguments: [shown, now, company.id, agentId])
        // S31: the company itself carries the mark, so a lab of an agent hired later is marked too; a Full session upgrades it.
        try db.execute(sql: """
            INSERT INTO companyTaint (companyId, source, profile, markedAt) VALUES (?, ?, ?, ?)
            ON CONFLICT(companyId) DO UPDATE SET
              source = COALESCE(companyTaint.source, excluded.source), markedAt = COALESCE(companyTaint.markedAt, excluded.markedAt),
              profile = CASE WHEN companyTaint.profile IS NULL OR excluded.profile = 'full' THEN excluded.profile ELSE companyTaint.profile END
            """, arguments: [company.id, shown, profile.rawValue, now])
        // S32: a Full session could write any company's labs: the machine-wide mark (kept with its first source).
        if profile == .full {
            try db.execute(sql: """
                INSERT INTO machineTaint (id, source, markedAt) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET source = excluded.source, markedAt = excluded.markedAt WHERE machineTaint.source IS NULL
                """, arguments: [Store.flat("\(company.name): \(shown)", max: 200), now])
        }
    }

    /// The machine-wide mark (S32), or nil when none stands; `clearedAt` is the owner's last machine-wide clear.
    public func machineLabTaint() throws -> (source: String?, markedAt: Date?, clearedAt: Date?)? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT source, markedAt, clearedAt FROM machineTaint WHERE id = 1")
                .map { (source: $0["source"], markedAt: $0["markedAt"], clearedAt: $0["clearedAt"]) }
        }
    }

    /// The owner's machine-wide clear (`brahma lab clear-taint --machine-wide`, owner shell only; no company tool): the mark goes,
    /// the clear time is kept (commits authored before it are never recorded clean), and every company logs it. Per-company
    /// clears never touch it. Returns whether a mark stood.
    @discardableResult
    public func clearMachineLabTaint(now: Date = Store.now(), owner: OwnerPrincipal) throws -> Bool {
        try ProcessRole.refuseInAgentProcess()  // FW-B1 re-review I-1 (with the company clear): the owner principal
        return try writer.write { db in
            let source: String? = try Row.fetchOne(db, sql: "SELECT source FROM machineTaint WHERE id = 1")?["source"]
            try db.execute(sql: """
                INSERT INTO machineTaint (id, source, markedAt, clearedAt) VALUES (1, NULL, NULL, ?)
                ON CONFLICT(id) DO UPDATE SET source = NULL, markedAt = NULL, clearedAt = excluded.clearedAt
                """, arguments: [now])
            guard let source else { return false }
            for company in try Company.fetchAll(db) {
                try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .approval,
                                  text: "The owner cleared the machine-wide lab mark (set by: \(Store.flat(source, max: 120))); lab commits "
                                    + "authored before this stay unrecordable as clean", createdAt: now).insert(db)
            }
            return true
        }
    }

    /// The session's taint at a turn's end (10b, I2): the agent row OR the flag file in `home` (the post-tool hook's mark when
    /// the database write failed); a missing row counts as tainted. When tainted, the lab mark is set in the same transaction
    /// that read the row and the flag. Returns it. Throws when the row or the mark could not be read or written (S30): the
    /// caller then keeps the session's taint and the flag file (no `clearTaintIfRequested`), so the next turn is still tainted.
    public func turnEndTaint(agentId: String, home: URL, now: Date = Store.now()) throws -> Bool {
        try writer.write { db in
            let flagged = TaintFlag.url(home: home, agentId: agentId).map(TaintFlag.exists) ?? true
            let row = try Agent.fetchOne(db, key: agentId)
            let tainted = flagged || (row?.sessionTainted ?? true)
            if tainted {
                let source = row?.taintSources.split(separator: "\n").first.map(String.init)
                    ?? (flagged ? TaintPolicy.hookErrorSource : "tainted session")
                try Store.markLabTainted(db, agentId: agentId, source: source, now: now)
            }
            return tainted
        }
    }

    /// Engine start (10b, I2): a flag file a crash left marks its agent's lab.
    public func markLabsForTaintFlags(home: URL, now: Date = Store.now()) throws {
        let dir = home.appending(path: "run/taint", directoryHint: .isDirectory)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter(TaintFlag.isSafeId)
        guard !names.isEmpty else { return }
        try writer.write { db in
            for id in names where try Agent.fetchOne(db, key: id) != nil {
                try Store.markLabTainted(db, agentId: id, source: TaintPolicy.hookErrorSource, now: now)
            }
        }
    }

    /// The agent's lab mark: since when and the first taint source, or nil when its lab carries none. The company's mark (S31)
    /// counts for every agent of the company, hired before it or after.
    public func labTaint(agentId: String) throws -> (source: String, markedAt: Date)? {
        try writer.read { db in
            if let own = try Row.fetchOne(db, sql: "SELECT source, markedAt FROM labTaint WHERE agentId = ?", arguments: [agentId]) {
                return (source: own["source"], markedAt: own["markedAt"])
            }
            if let company = try Row.fetchOne(db, sql: """
                SELECT c.source, c.markedAt FROM companyTaint c JOIN agent a ON a.companyId = c.companyId
                WHERE a.id = ? AND c.source IS NOT NULL
                """, arguments: [agentId]) {
                return (source: "company: \(company["source"] as String)", markedAt: company["markedAt"])
            }
            // S32: the machine-wide mark counts for every agent of every company.
            guard let machine = try Row.fetchOne(db, sql: "SELECT source, markedAt FROM machineTaint WHERE id = 1 AND source IS NOT NULL")
            else { return nil }
            return (source: "machine-wide: \(machine["source"] as String)", markedAt: machine["markedAt"])
        }
    }

    // MARK: Import mark (Plan L Task 14)

    /// An imported company's mark (owner ruling 2026-11-12: everything imported is outside content): the company lab mark (S31)
    /// with source `import: <host>`. While it stands every work turn of the company is tainted at launch with that source
    /// (`TurnContext.relayedTaint`), and no lab commit there records clean. Only the owner's trust ends it (`brahma company
    /// trust-import`, `trustImport`, which shows the source, the imported commit and the secret scan first); the generic lab
    /// clear refuses while it stands (final-review I3, `clearCompanyLabTaint`).
    /// `profile`: the company's profile when it was imported (fix round 1, I1: never NULL).
    static func markImported(_ db: Database, companyId: String, source: String, profile: String = PermissionProfile.sandboxed.rawValue,
                             now: Date) throws {
        try db.execute(sql: """
            INSERT INTO companyTaint (companyId, source, profile, markedAt) VALUES (?, ?, ?, ?)
            ON CONFLICT(companyId) DO UPDATE SET source = excluded.source, markedAt = excluded.markedAt,
              profile = COALESCE(companyTaint.profile, excluded.profile)
            """, arguments: [companyId, Store.flat(source, max: 200), profile, now])
    }

    /// The owner trusts an imported repo (`brahma company trust-import`, owner shell only; never a company tool): work turns are
    /// no longer tainted at launch. The company mark stays as an ordinary lab mark (labs were worked in by tainted sessions
    /// while the import mark stood; `brahma lab clear-taint` is the separate decision), and every session of the company's
    /// agents that the mark tainted is ended in the same transaction (what it read stays out of every later turn), recorded
    /// as an activity event. Returns the import mark's source, or nil when none stood. The caller holds the engine lock with no
    /// turn in progress (`RepoImport.trust`).
    @discardableResult
    public func trustImport(companyId: String, now: Date = Store.now(), owner: OwnerPrincipal) throws -> String? {
        try ProcessRole.refuseInAgentProcess()  // FW-B1 re-review I-1: the owner principal, never from an agent process
        return try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw WorkError.notFound("no such company") }
            guard let source = try String.fetchOne(db, sql: "SELECT source FROM companyTaint WHERE companyId = ? AND source LIKE 'import: %'",
                                                    arguments: [companyId]) else { return nil }
            try db.execute(sql: "UPDATE companyTaint SET source = ? WHERE companyId = ?",
                           arguments: [Store.flat("labs worked in while the import mark stood (\(source))", max: 200), companyId])
            for agent in try Agent.filter(Column("companyId") == companyId).fetchAll(db) where agent.sessionTainted || agent.freshSessionRequested {
                try Store.markLabTainted(db, agentId: agent.id, source: agent.taintSources.split(separator: "\n").first.map(String.init) ?? source, now: now)
                try Store.forceFreshSession(db: db, agentId: agent.id, itemId: nil, reason: "tainted", now: now)
                try db.execute(sql: "DELETE FROM agentSession WHERE agentId = ?", arguments: [agent.id])
                try db.execute(sql: "UPDATE agent SET sessionTainted = 0, freshSessionRequested = 0, taintSources = '' WHERE id = ?",
                               arguments: [agent.id])
            }
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .approval,
                              text: "The owner trusted the imported repo (\(source)): work turns are no longer tainted at launch and every "
                                + "agent starts a fresh session; labs stay marked until brahma lab clear-taint", createdAt: now).insert(db)
            return source
        }
    }

    /// The import mark's source (`import: <host>`) while it stands, else nil.
    public func importTaint(companyId: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT source FROM companyTaint WHERE companyId = ? AND source LIKE 'import: %'",
                                arguments: [companyId])
        }
    }

    /// The company's own lab mark (S31), or nil.
    public func companyLabTaint(companyId: String) throws -> (source: String, profile: String, markedAt: Date)? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT source, profile, markedAt FROM companyTaint WHERE companyId = ? AND source IS NOT NULL",
                             arguments: [companyId])
                // A NULL profile (an import mark from before fix round 1) reads as unknown, never as a trap (I1).
                .map { (source: $0["source"], profile: ($0["profile"] as String?) ?? "unknown", markedAt: $0["markedAt"]) }
        }
    }

    /// The owner clears the company's lab mark and every lab mark of its agents, recorded as an activity event; the clear time
    /// is kept (S33: from then on only commits the engine saw made in a clean turn record clean in that company). The database
    /// half of `LabProvenance.clearCompanyMark`, which runs it in the owner's critical section. Returns whether anything was
    /// marked. Refused, changing nothing, while the company carries an import mark (final-review I3): that mark ends only
    /// through `trustImport`, which the owner reaches after seeing the source, the imported commit and the secret scan.
    @discardableResult
    public func clearCompanyLabTaint(companyId: String, now: Date = Store.now(), owner: OwnerPrincipal) throws -> Bool {
        try ProcessRole.refuseInAgentProcess()  // FW-B1 re-review I-1: the owner principal, never from an agent process
        return try writer.write { db in
            guard let found = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            try Self.refuseImportMark(db, company: found)
            let company = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM companyTaint WHERE companyId = ? AND source IS NOT NULL",
                                           arguments: [companyId]) ?? 0
            try db.execute(sql: """
                INSERT INTO companyTaint (companyId, source, profile, markedAt, clearedAt) VALUES (?, NULL, NULL, NULL, ?)
                ON CONFLICT(companyId) DO UPDATE SET source = NULL, profile = NULL, markedAt = NULL, clearedAt = excluded.clearedAt
                """, arguments: [companyId, now])
            try db.execute(sql: "DELETE FROM labTaint WHERE agentId IN (SELECT id FROM agent WHERE companyId = ?)", arguments: [companyId])
            let agents = db.changesCount
            guard company + agents > 0 else { return false }
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .approval,
                              text: "The owner cleared the company's lab mark\(company > 0 ? "" : " (none)") and \(agents) agent lab mark(s); "
                                + "extension proposals are checked by their commits again", createdAt: now).insert(db)
            return true
        }
    }

    /// Final-review I3: the generic lab clear never ends an import mark.
    static func importMarkRefusal(_ company: Company) -> String {
        "\(company.name) carries an import mark; use brahma company trust-import \(company.slug)"
    }

    static func refuseImportMark(_ db: Database, company: Company) throws {
        let imported = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM companyTaint WHERE companyId = ? AND source LIKE 'import: %'",
                                        arguments: [company.id]) ?? 0
        if imported > 0 { throw WorkError.invalid(importMarkRefusal(company)) }
    }

    /// The owner clears an agent's lab mark (`brahma lab clear-taint`, owner shell only; never a company tool). Recorded as an
    /// activity event. Returns whether there was a mark.
    @discardableResult
    public func clearLabTaint(companyId: String, agentId: String, now: Date = Store.now(), owner: OwnerPrincipal) throws -> Bool {
        try ProcessRole.refuseInAgentProcess()  // FW-B1 re-review I-1: the owner principal, never from an agent process
        return try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard let row = try Row.fetchOne(db, sql: "SELECT source FROM labTaint WHERE agentId = ?", arguments: [agentId]) else { return false }
            try db.execute(sql: "DELETE FROM labTaint WHERE agentId = ?", arguments: [agentId])
            let source: String = row["source"]
            try ActivityEvent(companyId: companyId, agentId: agentId, turnId: nil, kind: .approval,
                              text: "The owner cleared @\(agent.name)'s lab mark (set by: \(Store.flat(source, max: 120))); its next "
                                + "extension proposals are checked by their commits again", createdAt: now).insert(db)
            return true
        }
    }

    /// Every recorded lab commit of the agent and whether it is tainted (S25: `propose_extension` reads the records before it
    /// looks at the lab, and records nothing itself).
    public func labCommitStates(agentId: String) throws -> [String: Bool] {
        try writer.read { db in
            var out: [String: Bool] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT sha, tainted FROM labCommit WHERE agentId = ?", arguments: [agentId]) {
                out[row["sha"]] = row["tainted"]
            }
            return out
        }
    }

    /// The commit recorded last.
    public func lastLabCommit(agentId: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT sha FROM labCommit WHERE agentId = ? ORDER BY rowid DESC LIMIT 1", arguments: [agentId])
        }
    }
}

/// Lab provenance at a turn's end (fix round 1, I3): every commit object of the lab not recorded yet is recorded with the
/// session's taint state, whatever ref (or none) reaches it, so a commit a tainted session parks on a tag or leaves unreferenced
/// is recorded tainted before a clean turn can branch it. A lab whose `.git` is not a real directory, whose config the engine
/// refuses, or that cannot be listed is not recorded: the session is marked tainted and the owner alerted. An unrecorded lab
/// commit counts as tainted (`labCommitTainted`).
public enum LabProvenance {
    public enum Outcome: Equatable, Sendable {
        case none
        case recorded(Int)
        case refused(String)
    }

    public static let alertReason = "lab-provenance"

    /// Blocking (git).
    /// `startCommits`: the lab's commits when the turn started (`commitSet`), so its own new commits are the ones the engine saw
    /// made (S33); nil: none were seen.
    public static func record(store: Store, workspace: URL, handle: String, companyId: String, agentId: String, turnId: String?,
                              tainted: Bool, now: Date, startCommits: Set<String>? = nil, limit: Int = 100_000,
                              maxOutput: Int = 16 << 20) -> Outcome {
        switch inspect(workspace: workspace, handle: handle) {
        case .missing: return .none
        case .refused(let why): return refuse(store: store, companyId: companyId, agentId: agentId, handle: handle, why: why, now: now)
        case .ok(let lab):
            let git = store.gitWorkspace(root: lab, companyId: companyId)
            do {
                let shas = try git.labCommits(limit: limit, maxOutput: maxOutput)
                let observed = startCommits.map { Set(shas).subtracting($0) }
                return .recorded(try store.recordLabCommits(agentId: agentId, turnId: turnId, shas: shas, tainted: tainted,
                                                            observed: observed, now: now))
            } catch {
                return refuse(store: store, companyId: companyId, agentId: agentId, handle: handle, why: "\(error)", now: now)
            }
        }
    }

    /// What `inspect` found: no lab repository, one the engine refuses to read (why), or a real one (its resolved root).
    enum Inspection: Equatable { case missing, refused(String), ok(URL) }

    /// The lab's `.git` checks (I3-b, F2, S24), with no git run: a real directory reached through no link, no link anywhere
    /// under it, no alternates, grafts, shallow, commondir or replace refs. Blocking. `propose_extension` (10b, S25) runs it
    /// again right before its archive.
    static func inspect(workspace: URL, handle: String) -> Inspection { inspect(workspace: workspace, relative: ".brahma/labs/\(handle)") }

    /// `inspect` for any lab-like repository below the workspace (`relative`, e.g. `.brahma/ext-try/<id>/lab`).
    static func inspect(workspace: URL, relative: String) -> Inspection {
        let root = workspace.resolvedForSandbox.path
        let lab = URL(fileURLWithPath: root).appending(path: relative, directoryHint: .isDirectory)
        let gitDir = lab.appending(path: ".git", directoryHint: .isDirectory)
        // The lab and its `.git` must be real directories down from the workspace (an agent could plant links there).
        if SandboxPath.linkedComponent(gitDir.path, under: root) != nil { return .refused("the lab's .git is reached through a link") }
        switch SandboxPath.kind(gitDir.path) {
        case .missing: return .missing
        case .directory: break
        default: return .refused("the lab's .git is not a directory")
        }
        // Object stores and history the lab borrows or rewrites are refused (I3-b): alternates, grafts, a shallow file, replace refs.
        // F2: a link anywhere under `.git` (it could steer git at another repository's objects or refs) is refused.
        if let link = firstLink(under: gitDir) { return .refused("the lab's .git holds a link (\(link))") }
        for rel in ["objects/info/alternates", "objects/info/http-alternates", "info/grafts", "shallow", "commondir"]
        where SandboxPath.kind(gitDir.appending(path: rel).path) != .missing {
            return .refused("the lab has \(rel)")
        }
        let replace = gitDir.appending(path: "refs/replace").path
        // Read without following a link (EngineFiles); a packed-refs that cannot be read whole is refused.
        let packedData = try? EngineFiles.read(workspace: URL(fileURLWithPath: root), dir: "\(relative)/.git", name: "packed-refs",
                                               limit: 8 << 20)
        if packedData == nil, SandboxPath.kind(gitDir.appending(path: "packed-refs").path) != .missing {
            return .refused("the lab's packed-refs cannot be read")
        }
        let packed = packedData.flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if SandboxPath.kind(replace) != .missing, !((try? FileManager.default.contentsOfDirectory(atPath: replace)) ?? ["?"]).isEmpty
            || packed.contains("refs/replace/") {
            return .refused("the lab has replace refs")
        }
        return .ok(lab)
    }

    /// The lab's commits now (S33: taken when a turn starts, so its end can tell what the engine saw made), or nil when it has
    /// no repository or cannot be read. Blocking (git).
    public static func commitSet(store: Store, workspace: URL, handle: String, companyId: String) -> Set<String>? {
        guard case .ok(let lab) = inspect(workspace: workspace, handle: handle) else { return nil }
        return (try? store.gitWorkspace(root: lab, companyId: companyId).labCommits()).map(Set.init)
    }

    /// Why an owner's clear did not run.
    public struct ClearRefused: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// What `labLikeRepos` walks at most (S34): a workspace with more entries refuses the clear rather than being half-checked.
    public static let workspaceWalkLimit = 200_000

    /// Every lab-like repository of a workspace (S33): `.brahma/labs/*` and `.brahma/ext-try/*/lab` holding a `.git`, whoever
    /// left them (current agents, fired ones, trials, planted ones). Fails closed (M11, S34) with the reason the owner sees:
    /// an entry there whose name Brahma cannot handle safely; `.brahma`, `.brahma/labs` or `.brahma/ext-try` that is not a real
    /// directory; or a repository anywhere else in the workspace (a `.git` directory or file, or a bare repository) outside the
    /// known layout (the main checkout's `.git`, its item worktrees' `.git` pointer files under `.brahma/wt`, the labs and the
    /// trial labs). The workspace is walked with `lstat` (no link is ever followed), at most `walkLimit` entries; a walk cut at
    /// the limit refuses. Blocking.
    static func labLikeRepos(workspace: URL, walkLimit: Int = workspaceWalkLimit) throws -> [String] {
        let ws = workspace.resolvedForSandbox
        func refuse(_ why: String) -> ClearRefused { ClearRefused(message: "\(why); move it aside, then clear the mark") }
        for dir in [".brahma", ".brahma/labs", ".brahma/ext-try"] {
            switch SandboxPath.kind(ws.appending(path: dir).path) {
            case .missing, .directory: continue
            default: throw refuse("\(dir) is not a real directory (a link or a file)")
            }
        }
        var out: [String] = []
        for (dir, suffix) in [(".brahma/labs", ""), (".brahma/ext-try", "/lab")] {
            for name in SandboxPath.entries(ws.appending(path: dir).path) {
                guard !SandboxPath.isUnsafe(name) else {
                    throw refuse("\(dir)/\(Store.flat(name.debugDescription, max: 120)) has a name Brahma cannot handle safely")
                }
                out.append("\(dir)/\(name)\(suffix)")
            }
        }
        let repos = out.filter { SandboxPath.kind(ws.appending(path: "\($0)/.git").path) != .missing }
        // The known `.git` places: walked past, never into.
        let knownGitDirs = Set([".git"] + repos.map { "\($0)/.git" })
        var stack = [""]
        var seen = 0
        while let rel = stack.popLast() {
            let url = rel.isEmpty ? ws : ws.appending(path: rel)
            let names = SandboxPath.entries(url.path)
            // A bare repository: HEAD, objects and refs side by side (the known `.git` dirs are never entered).
            if names.contains("HEAD"), names.contains("objects"), names.contains("refs"), !rel.isEmpty {
                throw refuse("\(Store.flat(rel, max: 200)) is a git repository outside the known layout")
            }
            for name in names {
                seen += 1
                guard seen <= walkLimit else {
                    throw ClearRefused(message: "the workspace has more than \(walkLimit) entries, so it could not be checked whole for "
                                       + "stray repositories; nothing was cleared")
                }
                let child = rel.isEmpty ? name : "\(rel)/\(name)"
                let kind = SandboxPath.kind(ws.appending(path: child).path)
                if name == ".git" {
                    if knownGitDirs.contains(child), kind == .directory { continue }
                    // An item worktree's `.git` is a pointer file to the main repository's own worktree record.
                    let parts = child.split(separator: "/")
                    if kind == .file, parts.count == 4, parts[0] == ".brahma", parts[1] == "wt" { continue }
                    throw refuse("\(Store.flat(child, max: 200)) is a git repository outside the known layout")
                }
                if kind == .directory { stack.append(child) }
            }
        }
        return repos
    }

    /// The owner's clear of a company's lab mark (N1), one critical section under the engine lock: refused while the engine
    /// runs or any tainted session of the company is active; every lab-like repository of its workspace is snapshotted and
    /// its commits marked tainted first; then the mark goes, its clear time kept. Blocking (git).
    @discardableResult
    public static func clearCompanyMark(store: Store, paths: BrahmaPaths, companyId: String, now: Date = Store.now(),
                                        walkLimit: Int = workspaceWalkLimit, owner: OwnerPrincipal) throws -> Bool {
        try ProcessRole.refuseInAgentProcess()
        guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
        // Final-review I3: an import mark ends only through trust-import (refused before anything is snapshotted).
        if try store.importTaint(companyId: companyId) != nil { throw WorkError.invalid(Store.importMarkRefusal(company)) }
        let lock = try engineLock(paths)
        defer { withExtendedLifetime(lock) {} }
        try refuseActiveSessions(store: store, paths: paths, companies: [company])
        try snapshotTainted(store: store, company: company, now: now, walkLimit: walkLimit)
        return try store.clearCompanyLabTaint(companyId: companyId, now: now, owner: owner)
    }

    /// The owner's machine-wide clear (S32, S33), the same critical section over every company.
    @discardableResult
    public static func clearMachineMark(store: Store, paths: BrahmaPaths, now: Date = Store.now(),
                                        walkLimit: Int = workspaceWalkLimit, owner: OwnerPrincipal) throws -> Bool {
        try ProcessRole.refuseInAgentProcess()
        let lock = try engineLock(paths)
        defer { withExtendedLifetime(lock) {} }
        let companies = try store.companies()
        try refuseActiveSessions(store: store, paths: paths, companies: companies)
        // Every workspace is checked whole before any snapshot is written.
        for company in companies { _ = try labLikeRepos(workspace: URL(fileURLWithPath: company.workspacePath, isDirectory: true), walkLimit: walkLimit) }
        for company in companies { try snapshotTainted(store: store, company: company, now: now, walkLimit: walkLimit) }
        return try store.clearMachineLabTaint(now: now, owner: owner)
    }

    static func engineLock(_ paths: BrahmaPaths) throws -> OrchestratorLock {
        do { return try OrchestratorLock.acquire(paths: paths) } catch OrchestratorLockError.alreadyRunning {
            throw ClearRefused(message: "the engine is running (the Brahma app or brahma run): stop it, then clear the mark")
        }
    }

    /// No clear while a session that read outside content is active, a taint flag stands, or a turn is in progress.
    static func refuseActiveSessions(store: Store, paths: BrahmaPaths, companies: [Company]) throws {
        for company in companies {
            for agent in try store.agents(companyId: company.id) where agent.state != .killed {
                let flagged = TaintFlag.url(home: paths.home, agentId: agent.id).map(TaintFlag.exists) ?? true
                if agent.sessionTainted || flagged {
                    throw ClearRefused(message: "@\(agent.name) in \(company.name) has a session that read outside content: clear the "
                                       + "mark once its next turn has started a fresh session")
                }
            }
            let running = try store.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM turn WHERE companyId = ? AND outcome = ?",
                                 arguments: [company.id, TurnOutcome.inProgress.rawValue]) ?? 0
            }
            if running > 0 { throw ClearRefused(message: "a turn in \(company.name) is still recorded as running: let the engine recover it first") }
        }
    }

    /// Every lab-like repository of the company's workspace, its commits recorded tainted (`taintedLabCommit`, and on the
    /// owning agent's records); one that cannot be read refuses the clear.
    static func snapshotTainted(store: Store, company: Company, now: Date, walkLimit: Int = workspaceWalkLimit) throws {
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let agents = try store.agents(companyId: company.id)
        for relative in try labLikeRepos(workspace: workspace, walkLimit: walkLimit) {
            guard case .ok(let root) = inspect(workspace: workspace, relative: relative) else {
                throw ClearRefused(message: "\(relative) in \(company.name) cannot be read safely; move it aside, then clear the mark")
            }
            let shas: [String]
            do { shas = try store.gitWorkspace(root: root, companyId: company.id).labCommits() } catch {
                throw ClearRefused(message: "\(relative) in \(company.name) could not be listed (\(Store.flat("\(error)", max: 200))); "
                                   + "nothing was cleared")
            }
            try store.recordTaintedLabCommits(shas, now: now)
            if relative.hasPrefix(".brahma/labs/"), let owner = agents.first(where: { ".brahma/labs/\($0.name)" == relative }) {
                _ = try store.recordLabCommits(agentId: owner.id, turnId: nil, shas: shas, tainted: true, now: now)
            }
        }
    }

    /// A refused lab, handled as `record` handles one: the session is marked tainted and the owner alerted.
    static func refused(store: Store, companyId: String, agentId: String, handle: String, why: String, now: Date) {
        _ = refuse(store: store, companyId: companyId, agentId: agentId, handle: handle, why: why, now: now)
    }

    /// The first symbolic link under `dir` (relative path), never following one. An unreadable entry counts as a link.
    /// Fails closed (S24): any error while walking (an unreadable directory, say) returns a marker.
    static func firstLink(under dir: URL, limit: Int = 200_000) -> String? {
        final class Failed: @unchecked Sendable { var path: String? }
        let failed = Failed()
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [],
                                                     errorHandler: { url, _ in failed.path = url.path; return false }) else { return "?" }
        var n = 0
        for case let url as URL in e {
            n += 1
            if n > limit { return "too many entries" }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink != false { return String(url.path.dropFirst(dir.path.count)) }
            if failed.path != nil { break }
        }
        if let path = failed.path { return "unreadable: " + String(path.dropFirst(dir.path.count)) }
        return nil
    }

    private static func refuse(store: Store, companyId: String, agentId: String, handle: String, why: String, now: Date) -> Outcome {
        try? store.markTainted(agentId: agentId, source: "lab-git: refused", now: now)
        try? EngineAlerts.raise(store: store, text: "@\(handle)'s lab could not be read for provenance (\(Store.flat(why, max: 200))); "
                                + "its session is treated as tainted.", now: now, reason: alertReason, companyId: companyId)
        return .refused(why)
    }
}

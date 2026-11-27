import Foundation
import GRDB

/// What the database knows about a secret. The value lives only in the `SecretVault`.
public struct SecretMeta: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "secret"

    public var id: String
    public var companyId: String
    public var name: String
    /// A test key may be handed to an agent's environment for the item it works on; any other secret is engine-held.
    public var isTest: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?
}

/// One agent's use of a test key while it works on one item (`use_secret`). The key is put in the environment of that
/// agent's work turns and of that item's checks while the row is open: it ends when the lease goes or the item leaves
/// `inProgress`/`inReview` (`endSecretUses`), and injection also checks the live lease and status, never the row alone.
public struct SecretUse: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord, Identifiable {
    public static let databaseTableName = "secretUse"

    public var id: String
    public var companyId: String
    public var agentId: String
    public var secretName: String
    public var itemId: String?
    public var grantedAt: Date
    public var endedAt: Date? = nil
}

/// What a `request_secret` ask carries in its payload details: never a value.
public struct RequestedSecret: Codable, Equatable, Sendable {
    public var request = "secret"
    public var name: String
    /// The agent's proposal; the owner decides the flag when providing the secret.
    public var test: Bool
}

public enum SecretRequests {
    public static func requested(_ ask: Ask) -> RequestedSecret? {
        guard ask.kind == .request, let details = ask.payload?.details,
              let decoded = try? JSONDecoder().decode(RequestedSecret.self, from: Data(details.utf8)), decoded.request == "secret" else { return nil }
        return decoded
    }

    static func details(_ request: RequestedSecret) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(request)) ?? Data(), as: UTF8.self)
    }
}

extension Store {
    // MARK: Agent requests and uses (Task 4-wire)

    /// `request_secret`: files a `request` ask (risk high, straight to the owner) for a secret the agent needs. Its requester
    /// must be an active agent of the company (`.forbidden("not in your company")`); `AskQuota` applies in the write that
    /// files it. An open request for the same name in the company is returned instead (`deduped`). A name that already is
    /// a secret of the company is not requested again. The reason is redacted like any ask text; no value is ever involved.
    @discardableResult
    public func requestSecret(companyId: String, agentId: String, name: String, reason: String, test: Bool,
                              now: Date = Store.now()) throws -> (ask: Ask, deduped: Bool) {
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard agent.state != .killed else { throw WorkError.forbidden("this agent is not active in the company") }
            guard SecretName.isValid(name) else { throw WorkError.invalid(SecretError.invalidName.message) }
            if test, !SecretName.isInjectable(name) {
                throw WorkError.invalid("\(name) cannot be a test key (\(SecretError.notInjectable.message)); ask for it engine-held")
            }
            if let existing = try SecretMeta.filter(Column("companyId") == companyId && Column("name") == name).fetchOne(db) {
                throw WorkError.conflict(existing.isTest
                    ? "\(name) already exists; take it with use_secret"
                    : "\(name) already exists and is engine-held: connectors use it for you, and agents never receive it")
            }
            let open = try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.request
                                      && [AskStatus.pendingInternal.rawValue, AskStatus.pendingOwner.rawValue].contains(Column("status")))
                .order(Column("number")).fetchAll(db)
            if let same = open.first(where: { SecretRequests.requested($0)?.name == name }) { return (same, true) }
            let ask = try propose(db: db, companyId: companyId, by: .agent(agentId), kind: .request, risk: .high, category: nil,
                                  title: "Secret \(name)", summary: reason,
                                  payload: AskPayload(details: SecretRequests.details(RequestedSecret(name: name, test: test))),
                                  document: nil, itemId: nil, subjectId: nil, supersedes: nil, requestId: nil, decisionClass: .taste,
                                  viaOwner: true, now: now)
            return (ask, false)
        }
    }

    /// The owner provides the secret a `request` ask is for: the value goes to the vault (`setSecret`, with the flag the owner
    /// chose, whatever the request proposed) and the ask is approved through `ownerDecide` with the note "provided". The
    /// value never touches the ask or any other row.
    @discardableResult
    public func provideSecret(askId: String, value: String, isTest: Bool, vault: any SecretVault, now: Date = Store.now()) throws -> Ask {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        guard let ask = try ask(id: askId) else { throw WorkError.notFound("no such ask") }
        guard ask.kind == .request, let request = SecretRequests.requested(ask) else {
            throw WorkError.invalid("\(ask.ref) is not a secret request")
        }
        guard ask.status.isPending else { throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
        // Read once outside the write: a vault that prompts does so here, not while the database write is held.
        _ = try vault.value(companyId: ask.companyId, name: request.name)
        try validateSecret(companyId: ask.companyId, name: request.name, value: value, isTest: isTest)
        // One unit with respect to the pending -> approved transition (4-wire fix round 2, M5): inside ONE write, the ask must
        // still be pending, then the metadata row and the decision, and the vault value is written LAST, only by the provide
        // that won the transition (a second, concurrent provide fails the pending check and never touches the vault). If the
        // vault write fails, the transaction rolls back (row and flag as before, ask still pending). If the commit itself
        // fails after the vault write, the value that was there before is put back (or the new one removed).
        var prior: String?
        var wroteVault = false
        do {
            return try writer.write { db in
                guard let current = try Ask.fetchOne(db, key: askId), current.status.isPending else {
                    throw WorkError.conflict("\(ask.ref) is already \((try Ask.fetchOne(db, key: askId))?.status.rawValue ?? "gone")")
                }
                try upsertSecretMeta(db, companyId: ask.companyId, name: request.name, isTest: isTest, now: now)
                let decided = try ownerDecide(db: db, askId: askId, approve: true, note: "provided", acknowledgeChange: false, currentHash: nil,
                                              grant: nil, providingSecret: true, now: now)
                prior = try vault.value(companyId: ask.companyId, name: request.name)
                try vault.set(companyId: ask.companyId, name: request.name, value: value)
                wroteVault = true
                return decided
            }
        } catch {
            if wroteVault {
                if let prior { try? vault.set(companyId: ask.companyId, name: request.name, value: prior) }
                else { try? vault.delete(companyId: ask.companyId, name: request.name) }
            }
            throw error
        }
    }

    /// A check's log file is agent output: scrubbed in place before anything reads it. A scrub that cannot be done (the
    /// redactor has not loaded, the path is not a regular file, the rewrite failed) removes the file and throws, so no raw
    /// output is ever left behind; the caller records a withheld tail instead.
    public func scrubCheckLog(_ url: URL) throws {
        do { try redactor.scrubFile(url) } catch {
            var st = stat()
            if lstat(url.path, &st) == 0 { unlink(url.path) }
            throw error
        }
    }

    // MARK: Branch continuity between the holder's turns (scan (a))

    /// At the start of a holder's work turn on its leased item: the branch head must be the recorded head. If it is not, the
    /// branch moved outside the holder's turns: the item is flagged (`branchMoved`), the company hears (an `error` activity
    /// line and an engine alert naming the key) and `submit_for_review` is refused until a manager or the owner re-adopts
    /// it. Returns whether continuity held (a never-recorded head counts as held: the claim records one).
    ///
    /// The item is read again inside the write (never the turn context's snapshot, which an engine rebase recorded since
    /// may have overtaken), and an item that is already flagged returns at once: one alert per move, not one per turn.
    func checkBranchContinuity(item: WorkItem, agent: Agent, head: String?, now: Date) throws -> Bool {
        let (held, moved) = try writer.write { db -> (Bool, BranchMoved?) in
            guard let current = try WorkItem.fetchOne(db, key: item.id) else { return (false, nil) }
            if current.branchMoved { return (false, nil) }
            guard let recorded = current.leaseHeadCommit else { return (true, nil) }
            if head == recorded { return (true, nil) }
            let moved = try markBranchMoved(db: db, item: current, agent: agent, holderId: agent.id,
                                            why: "its head is \(head?.prefix(7) ?? "gone"), not the recorded \(recorded.prefix(7))", now: now)
            return (false, moved)
        }
        if let moved { try tellBranchMoved(moved, now: now) }
        return held
    }

    /// Removes an item's worktree unless it is leased again (`GitWorkspace.removeWorktree`), and records the engine's own
    /// auto-commit of leftover work as the item's head — by compare-and-set: only when the recorded head is the commit's
    /// parent and the item is not flagged (4-wire fix round 4, B1). Anything else (the branch moved meanwhile) is left for
    /// the next claim to flag. Every engine path that removes an item worktree goes through here: release, reassignment,
    /// the reap after a stop, kill or expiry, the sweep, and the cleanup after a landing.
    @discardableResult
    public func removeItemWorktree(git: GitWorkspace, companyId: String, key: String) throws -> GitWorkspace.AutoCommit? {
        let made = try git.removeWorktree(key: key, keepIf: { try lease(companyId: companyId, key: key) != nil })
        if let made { try recordEngineAutoCommit(companyId: companyId, key: key, made) }
        return made
    }

    func recordEngineAutoCommit(companyId: String, key: String, _ made: GitWorkspace.AutoCommit) throws {
        do {
            try recordEngineAutoCommitOrThrow(companyId: companyId, key: key, made)
        } catch {
            // The write rolled back, and the auto-commit is already on the branch: fail closed (C2a fix round 4, R4-2) —
            // the commit is recorded tainted and the item marked in a write of their own, and the owner is alerted. The
            // error still reaches the caller (the recorded head was not updated either).
            recordEngineAutoCommitFailClosed(companyId: companyId, key: key, made, error: error)
            throw error
        }
    }

    private func recordEngineAutoCommitOrThrow(companyId: String, key: String, _ made: GitWorkspace.AutoCommit) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE workItem SET leaseHeadCommit = ? WHERE companyId = ? AND key = ? AND leaseHeadCommit = ? AND branchMoved = 0
                """, arguments: [made.commit, companyId, key, made.parent])
            // Plan C2a: the leftover edits are its last holder's work. Recorded tainted when that session is tainted now, when a
            // tainted session held the item (5-lite's sticky mark), or when nobody can say who wrote them (fail closed).
            guard let item = try WorkItem.fetchOne(db, sql: "SELECT * FROM workItem WHERE companyId = ? AND key = ?",
                                                   arguments: [companyId, key]) else { return }
            let writer = try String.fetchOne(db, sql: "SELECT agentId FROM leaseClaim WHERE itemId = ? ORDER BY id DESC LIMIT 1",
                                             arguments: [item.id])
            var source: String?
            if let writer { source = try Self.currentTaint(db: db, agentId: writer, home: dataHome) } else { source = "an unknown session" }
            if source == nil, item.taintedOrigin { source = "outside content" }
            guard let source else { return }
            try db.execute(sql: """
                INSERT OR IGNORE INTO taintedCommit (companyId, sha, itemId, agentId, turnId, source, createdAt)
                VALUES (?, ?, ?, ?, NULL, ?, ?)
                """, arguments: [companyId, made.commit, item.id, writer, Store.flat(source, max: 200), Store.now()])
        }
    }

    /// The reason that keys the owner's alert about an engine auto-commit whose taint record failed (its own, so it never merges
    /// with or is suppressed by a turn's `taint-record:<itemId>` alert).
    static func autoCommitTaintAlertReason(companyId: String, key: String) -> String { "taint-autocommit:\(companyId):\(key)" }

    /// `recordEngineAutoCommit` failed: who wrote the leftover work can't be told, so its commit is recorded tainted — the
    /// sha-keyed row first, written even when the item can't be looked up (it taints by sha alone) — and the item gets 5-lite's
    /// sticky mark in a write of its own; the owner gets an engine alert either way (stderr when even that fails). Never throws.
    private func recordEngineAutoCommitFailClosed(companyId: String, key: String, _ made: GitWorkspace.AutoCommit, error: any Error) {
        let now = Store.now()
        var failures: [String] = []
        do {
            try writer.write { db in
                let itemId = (try? String.fetchOne(db, sql: "SELECT id FROM workItem WHERE companyId = ? AND key = ?",
                                                   arguments: [companyId, key])) ?? nil
                try db.execute(sql: """
                    INSERT OR IGNORE INTO taintedCommit (companyId, sha, itemId, agentId, turnId, source, createdAt)
                    VALUES (?, ?, ?, NULL, NULL, ?, ?)
                    """, arguments: [companyId, made.commit, itemId, Self.taintCheckFailedSource, now])
            }
        } catch let rowError {
            failures.append("the commit could not be recorded (\(rowError))")
        }
        do {
            try writer.write { db in
                try db.execute(sql: "UPDATE workItem SET taintedOrigin = 1 WHERE companyId = ? AND key = ?", arguments: [companyId, key])
            }
        } catch let markError {
            failures.append("the item could not be marked (\(markError))")
        }
        let sha = made.commit.prefix(7)
        let text = "Brahma could not record the taint of its own commit \(sha) of \(key)'s leftover work (\(Store.flat("\(error)", max: 300))). "
            + (failures.isEmpty
                ? "It recorded that commit as tainted instead: \(key) is treated as tainted until it is merged or you vouch for it."
                : "Recording it as tainted failed too: \(failures.joined(separator: "; ")). Treat \(key)'s changes as tainted until it "
                  + "is merged or you vouch for it.")
        do {
            try EngineAlerts.raise(store: self, text: text, now: now, reason: Self.autoCommitTaintAlertReason(companyId: companyId, key: key),
                                   scope: .company(companyId))
        } catch let alertError {
            FileHandle.standardError.write(Data("brahma: \(text) (the alert failed too: \(alertError))\n".utf8))
        }
    }

    /// At claim (4-wire fix round 3, R2): the branch head becomes the recorded head, unless the item already has a recorded
    /// head the branch no longer is — a move while nobody held the lease. That is flagged (with no flagged holder, so only an
    /// executive or the owner can re-adopt it), not adopted. An item already flagged keeps its flag and its flagged holder.
    func recordClaimHead(itemId: String, head: String, now: Date) throws {
        let moved = try writer.write { db -> BranchMoved? in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { return nil }
            // Plan C2a: where a tainted turn that claimed it starts recording. Only a head the engine recorded and the branch still
            // is (an agent may have moved an unheld branch) is trusted, once per lease and claim; else the record starts at the
            // merge base with `main`.
            if !item.branchMoved, item.leaseHeadCommit == head {
                try db.execute(sql: "UPDATE workLease SET claimHead = ? WHERE itemId = ? AND claimHead IS NULL", arguments: [head, itemId])
                try db.execute(sql: """
                    UPDATE leaseClaim SET claimHead = ? WHERE id = (SELECT id FROM leaseClaim WHERE itemId = ? ORDER BY id DESC LIMIT 1)
                      AND claimHead IS NULL
                    """, arguments: [head, itemId])
            }
            if !item.branchMoved, let recorded = item.leaseHeadCommit, recorded != head,
               let claimantId = try Self.leaseHolderId(db: db, itemId: itemId), let claimant = try Agent.fetchOne(db, key: claimantId) {
                return try markBranchMoved(db: db, item: item, agent: claimant, holderId: nil,
                                           why: "it moved while nobody held it: its head is \(head.prefix(7)), not the recorded \(recorded.prefix(7))",
                                           now: now)
            }
            try Self.recordLeaseHead(db: db, itemId: itemId, commit: head)
            return nil
        }
        if let moved { try tellBranchMoved(moved, now: now) }
    }

    /// Marks the branch moved (see `checkBranchContinuity`) and tells the company.
    func flagBranchMoved(item: WorkItem, agent: Agent, why: String, now: Date) throws {
        let moved = try writer.write { db in try markBranchMoved(db: db, item: item, agent: agent, holderId: agent.id, why: why, now: now) }
        try tellBranchMoved(moved, now: now)
    }

    /// A branch move just flagged, for `tellBranchMoved`.
    struct BranchMoved {
        var item: WorkItem
        var agent: Agent
        var flaggedHolder: String?
        var why: String
        var text: String
    }

    /// The flag itself, in the caller's transaction (S4 fix round 1, M9): `branchMoved = 1` (it refuses the submits) and the
    /// company's activity line, which needs no redaction. Nothing here can fail on the alert: the caller commits this first,
    /// then `tellBranchMoved` raises in a transaction of its own, so an alert that throws never rolls the flag back.
    /// `holderId` is who held the lease when the move was found (the flagged holder, `branchMovedHolderId`): the agent whose
    /// turn found it; nil for a move while nobody held the item. A flag already set is never overwritten.
    func markBranchMoved(db: Database, item: WorkItem, agent: Agent, holderId: String?, why: String, now: Date) throws -> BranchMoved {
        let flagged = holderId
        try db.execute(sql: "UPDATE workItem SET branchMoved = 1, branchMovedHolderId = ? WHERE id = ? AND branchMoved = 0",
                       arguments: [flagged, item.id])
        let text = flagged == nil
            ? "item/\(item.key) moved while nobody held it (\(why)); submits are refused until an executive or the owner re-adopts the branch (readopt_branch)"
            : "item/\(item.key) moved outside @\(agent.name)'s turn (\(why)); submits are refused until a manager re-adopts the branch (readopt_branch)"
        try ActivityEvent(companyId: item.companyId, agentId: agent.id, turnId: nil, kind: .error, text: text, createdAt: now).insert(db)
        return BranchMoved(item: item, agent: agent, flaggedHolder: flagged, why: why, text: text)
    }

    /// After the flag is committed: the item's event (notifying the flagged holder's manager) and the engine alert, in a
    /// transaction of their own. A failure here (the secrets not loaded, the company gone) throws to the caller with the flag
    /// already in place.
    func tellBranchMoved(_ moved: BranchMoved, now: Date) throws {
        try writer.write { db in
            if let current = try WorkItem.fetchOne(db, key: moved.item.id) {
                try recordItemEvent(db: db, item: current, actor: "system", kind: .edited,
                                    text: "branch moved outside the holder's turn (\(moved.why))",
                                    alsoNotify: moved.flaggedHolder == nil ? [] : [moved.agent.managerId].compactMap { $0 }, now: now)
            }
            try EngineAlerts.raise(store: self, db: db, text: "\(moved.item.key): \(moved.text)", now: now,
                                   reason: Self.branchMovedAlertReason(moved.item.id), scope: .company(moved.item.companyId))
        }
    }

    static func branchMovedAlertReason(_ itemId: String) -> String { "branch-moved:\(itemId)" }

    /// At the end of a holder's work turn (continuity held at its start): the branch head becomes the recorded head when it
    /// descends from the recorded one (the turn's own commits, or a submit the engine accepted); a rewrite that was not
    /// submitted in the same turn flags the branch instead.
    func recordTurnEndHead(item: WorkItem, agent: Agent, head: String, isDescendant: (String) throws -> Bool, now: Date) throws {
        guard let current = try workItem(id: item.id), try lease(itemId: item.id)?.agentId == agent.id, !current.branchMoved else { return }
        guard let recorded = current.leaseHeadCommit else { try recordLeaseHead(itemId: item.id, commit: head); return }
        if head == recorded { return }
        if try isDescendant(recorded) {
            try recordLeaseHead(itemId: item.id, commit: head)
        } else {
            try flagBranchMoved(item: current, agent: agent, why: "the turn rewrote it to \(head.prefix(7)) without submitting", now: now)
        }
    }

    /// Takes a branch flagged as moved as it is: its current head becomes the recorded head and the flag clears, so the
    /// holder can submit again. Only for a flagged, leased item (`"nothing to re-adopt"` otherwise). Who may (4-wire fix
    /// rounds 2 and 3, S12/R1): the owner; otherwise never the agent that held the item when it was flagged
    /// (`branchMovedHolderId`) nor the current leaseholder, and only an executive of the company or the direct manager of the
    /// FLAGGED holder — a reassignment (which any lead can make) changes neither. The item events record who re-adopted it.
    @discardableResult
    public func readoptBranch(itemId: String, by sender: Sender, head: String?, now: Date = Store.now()) throws -> WorkItem {
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
            let actor = try resolveActor(db, sender, companyId: item.companyId)
            guard try WorkLease.fetchOne(db, key: itemId) != nil, let holderId = try Self.leaseHolderId(db: db, itemId: itemId) else {
                throw WorkError.conflict("\(item.key) is not leased; the next claim records its branch")
            }
            guard item.branchMoved else { throw WorkError.conflict("\(item.key)'s branch is not flagged as moved: nothing to re-adopt") }
            if !actor.privileged {
                guard actor.id != holderId else {
                    throw WorkError.forbidden("you hold \(item.key): its branch is re-adopted by your manager or the owner, not by you")
                }
                guard actor.id != item.branchMovedHolderId else {
                    throw WorkError.forbidden("you held \(item.key) when its branch was flagged: your manager or the owner re-adopts it, not you")
                }
                let flagged = try item.branchMovedHolderId.flatMap { try Agent.fetchOne(db, key: $0) }
                guard actor.kind == .executive || (flagged?.managerId != nil && flagged?.managerId == actor.id) else {
                    throw WorkError.forbidden("only the manager of the agent that held \(item.key) when it was flagged, an executive or the owner can re-adopt its branch")
                }
            }
            guard let head else { throw WorkError.conflict("item/\(item.key) has no head to adopt") }
            try db.execute(sql: "UPDATE workItem SET leaseHeadCommit = ?, branchMoved = 0, branchMovedHolderId = NULL WHERE id = ?", arguments: [head, itemId])
            try resolveEngineAlerts(db, reasons: [Self.branchMovedAlertReason(itemId)], now: now)
            try recordItemEvent(db: db, item: item, actor: actor.id, kind: .edited,
                                text: "branch re-adopted at \(head.prefix(7)) by @\(actor.handle); submits are accepted again",
                                alsoNotify: [holderId], alsoNotifyRole: .holder, now: now)
            try ActivityEvent(companyId: item.companyId, agentId: actor.privileged ? nil : actor.id, turnId: nil, kind: .work,
                              text: "@\(actor.handle) re-adopted item/\(item.key)'s branch at \(head.prefix(7))", createdAt: now).insert(db)
            return try WorkItem.fetchOne(db, key: itemId) ?? item
        }
    }

    /// `use_secret`: opens a use of a TEST key for the item the agent holds. The agent must be an active agent of the company
    /// (`.forbidden("not in your company")`); the secret must exist in that company and be a test key; the agent must hold an
    /// `inProgress` item. One open row per (agent, name, item); `secret.lastUsedAt` moves. Returns the item's key.
    @discardableResult
    public func openSecretUse(companyId: String, agentId: String, name: String, now: Date = Store.now()) throws -> (key: String, use: SecretUse) {
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard agent.state != .killed else { throw WorkError.forbidden("this agent is not active in the company") }
            guard SecretName.isValid(name) else { throw WorkError.invalid(SecretError.invalidName.message) }
            guard let meta = try SecretMeta.filter(Column("companyId") == companyId && Column("name") == name).fetchOne(db) else {
                throw WorkError.notFound("No secret named \(name); ask with request_secret")
            }
            guard meta.isTest else {
                throw WorkError.invalid("\(name) is engine-held: connectors use it for you, and agents never receive it")
            }
            guard let lease = try WorkLease.filter(Column("agentId") == agentId).fetchOne(db),
                  let item = try WorkItem.fetchOne(db, key: lease.itemId), item.companyId == companyId else {
                throw WorkError.conflict("you hold no work item; claim one first, then use_secret while you work on it")
            }
            guard item.status == .inProgress else {
                throw WorkError.conflict("\(item.key) is \(item.status.title.lowercased()), not in progress")
            }
            try db.execute(sql: "UPDATE secret SET lastUsedAt = ? WHERE id = ?", arguments: [now, meta.id])
            if let open = try SecretUse.filter(Column("agentId") == agentId && Column("secretName") == name && Column("itemId") == item.id
                                               && Column("endedAt") == nil).fetchOne(db) {
                return (item.key, open)
            }
            let use = SecretUse(id: UUID().uuidString, companyId: companyId, agentId: agentId, secretName: name, itemId: item.id,
                                grantedAt: now)
            try use.insert(db)
            try ActivityEvent(companyId: companyId, agentId: agentId, turnId: nil, kind: .work,
                              text: "@\(agent.name) takes test key \(name) for \(item.key) from its next turn", createdAt: now).insert(db)
            return (item.key, use)
        }
    }

    /// Ends every open use of the item: the lease went, or the item left `inProgress`/`inReview`.
    static func endSecretUses(db: Database, itemId: String, now: Date) throws {
        try db.execute(sql: "UPDATE secretUse SET endedAt = ? WHERE itemId = ? AND endedAt IS NULL", arguments: [now, itemId])
    }

    /// Ends every open use of the agent (it was killed).
    static func endSecretUses(db: Database, agentId: String, now: Date) throws {
        try db.execute(sql: "UPDATE secretUse SET endedAt = ? WHERE agentId = ? AND endedAt IS NULL", arguments: [now, agentId])
    }

    /// Once per tick: closes any open use whose lease or item status no longer carries it (defence in depth behind the
    /// explicit ends).
    func sweepSecretUses(now: Date) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE secretUse SET endedAt = ? WHERE endedAt IS NULL AND (itemId IS NULL
                    OR NOT EXISTS (SELECT 1 FROM workLease l WHERE l.itemId = secretUse.itemId AND l.agentId = secretUse.agentId)
                    OR NOT EXISTS (SELECT 1 FROM workItem i WHERE i.id = secretUse.itemId AND i.companyId = secretUse.companyId
                                   AND i.status IN ('inProgress', 'inReview')))
                """, arguments: [now])
        }
    }

    /// The names of the test keys the agent's turns on the item (and the item's checks) get: open uses whose secret is still
    /// a test key of the same company, whose lease the agent still holds, and whose item is `inProgress` or `inReview`;
    /// only names `SecretName.isInjectable` accepts. Sorted.
    public func injectableSecretNames(agentId: String, itemId: String) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT u.secretName FROM secretUse u
                JOIN secret s ON s.companyId = u.companyId AND s.name = u.secretName AND s.isTest = 1
                JOIN workLease l ON l.itemId = u.itemId AND l.agentId = u.agentId
                JOIN workItem i ON i.id = u.itemId AND i.companyId = u.companyId AND i.status IN ('inProgress', 'inReview')
                JOIN agent a ON a.id = u.agentId AND a.companyId = u.companyId
                WHERE u.agentId = ? AND u.itemId = ? AND u.endedAt IS NULL
                ORDER BY u.secretName
                """, arguments: [agentId, itemId])
        }.filter { SecretName.isInjectable($0) }
    }

    /// `injectableSecretNames` with their values, from the redactor's loaded set (a value not loaded yet is left out: the
    /// engine admits nothing while the redactor is behind). For `ChildEnvironment.make(secrets:)`.
    public func injectableSecrets(agentId: String, itemId: String) throws -> [String: String] {
        let names = try injectableSecretNames(agentId: agentId, itemId: itemId)
        guard !names.isEmpty, let companyId = try writer.read({ db in try Agent.fetchOne(db, key: agentId)?.companyId }) else { return [:] }
        let cache = redactor.cachedValues()
        var out: [String: String] = [:]
        for name in names { if let loaded = cache["\(companyId):\(name)"] { out[name] = loaded.value } }
        return out
    }

    /// The test keys the item's check runs with: the lease holder's open uses on it.
    func injectableSecrets(forCheckOf itemId: String) throws -> [String: String] {
        guard let holder = try lease(itemId: itemId)?.agentId else { return [:] }
        return try injectableSecrets(agentId: holder, itemId: itemId)
    }

    /// The company's secret values the leak scans look for (test and engine-held alike), from the redactor's loaded set.
    /// They go only into `SecretScan`, whose findings name the secret and never the value.
    func knownSecretValues(companyId: String) -> [(String, String)] {
        redactor.cachedValues().filter { $0.key.hasPrefix("\(companyId):") }.map { ($0.value.name, $0.value.value) }
            .sorted { $0.0 < $1.0 }
    }

    // MARK: The recorded branch head (scan (a))

    /// Records the item branch's head the engine saw (at claim, at the end of a holder's turn, after an engine rebase), while
    /// the item is leased. It never clears `branchMoved` (4-wire fix round 2, N1): a flagged holder that releases and claims
    /// again stays flagged; only `readoptBranch` clears the flag.
    func recordLeaseHead(itemId: String, commit: String) throws {
        try writer.write { db in try Self.recordLeaseHead(db: db, itemId: itemId, commit: commit) }
    }

    static func recordLeaseHead(db: Database, itemId: String, commit: String) throws {
        try db.execute(sql: "UPDATE workItem SET leaseHeadCommit = ? WHERE id = ? AND EXISTS (SELECT 1 FROM workLease WHERE itemId = ?)",
                       arguments: [commit, itemId, itemId])
    }

    // MARK: Redaction helpers for the remaining write paths

    func redact(_ payload: AskPayload?) throws -> AskPayload? {
        guard var p = payload else { return nil }
        p.question = try redact(p.question)
        p.details = try redact(p.details)
        p.recommendation = try redact(p.recommendation)
        p.stakes = try redact(p.stakes)
        p.proposal = try redact(p.proposal)
        p.options = try p.options.map { o in
            var o = o
            o.label = try redact(o.label); o.pros = try redact(o.pros); o.cons = try redact(o.cons)
            o.effort = try redact(o.effort); o.risk = try redact(o.risk)
            return o
        }
        return p
    }

    func redact(_ draft: HandoffDraft) throws -> HandoffDraft {
        var d = draft
        d.goal = try redact(d.goal)
        d.decisions = try d.decisions.map { try redact($0) }
        d.openQuestions = try d.openQuestions.map { try redact($0) }
        d.fileRefs = try d.fileRefs.map { try redact($0) }
        return d
    }

    // MARK: Redaction

    /// The one helper every Store write of agent- or tool-produced text goes through. Throws `secretsNotLoaded` until the
    /// redactor has completed a load in this process (when the database had secrets at open): fail closed, never store
    /// text that might hold an unredacted secret.
    func redact(_ text: String) throws -> String {
        if !redactor.hasLoaded, let load = redactor.takeLoader() { load() }
        guard redactor.hasLoaded else { throw SecretError.secretsNotLoaded }
        return redactor.apply(text)
    }

    /// A loader `redact` runs once, on the first redacting write before the redactor has loaded (instead of throwing at
    /// once). The CLI sets it to a non-interactive load, so read-only commands never touch the vault. It may run inside a
    /// write transaction: it must read the database only through `reloadRedactorIfNeeded` (reentrant reads) and must not
    /// log (`logFailures: false`). Set it only on a file-backed store (a `DatabasePool`): its reentrant reads from inside a
    /// write would deadlock the single connection of `Store.inMemory` (a `DatabaseQueue`) if another thread held the reload lock.
    public var redactorLoader: (@Sendable () -> Void)? {
        get { redactor.lazyLoader }
        set { redactor.lazyLoader = newValue }
    }

    /// `text` with every loaded secret redacted, for the owner's terminal (`brahma canary run`); nil when the secrets cannot be
    /// loaded (the caller withholds the text).
    public func redactedForDisplay(_ text: String) -> String? { try? redact(text) }

    func redact(_ text: String?) throws -> String? {
        guard let text else { return nil }
        return try redact(text)
    }

    func redact(_ spec: CheckSpec?) throws -> CheckSpec? {
        guard var spec else { return nil }
        spec.command = try redact(spec.command)
        spec.paths = try spec.paths.map { try redact($0) }
        return spec
    }

    /// Whether this process must hold everything that would store agent text: the redactor has never completed a load, or
    /// the last reload left a secret unloaded. The engine admits no turn, check, merge or dispatch while it is true, and
    /// `brahma mcp` refuses tool calls (`prepareForToolCall`). With no secrets it is never true.
    public var secretsHeld: Bool { !redactor.hasLoaded || !redactor.failedNames.isEmpty }

    /// Sets the redactor's starting state when the store opens: a database with no secrets is a complete (empty) load; one
    /// with secrets stays unloaded, so writes fail closed until `reloadRedactorIfNeeded` succeeds.
    func initializeRedactor() throws {
        let version = try secretsVersion()
        if version == "0:" { redactor.update([], version: version) }
    }

    /// "<count>:<max(updatedAt)>" over all companies: changes whenever a secret is added, replaced, removed or loaded by the
    /// owner (`ownerLoadSecrets`). A reentrant read: the lazy loader may call it inside a write transaction.
    public func secretsVersion() throws -> String {
        try writer.unsafeReentrantRead { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM secret") ?? 0
            let newest = try Date.fetchOne(db, sql: "SELECT MAX(updatedAt) FROM secret")
            return "\(count):" + (newest.map { String(Int64(($0.timeIntervalSince1970 * 1000).rounded())) } ?? "")
        }
    }

    /// Whether the redactor is behind the database: a secret was added, replaced or removed since the last complete load,
    /// or the last load left some unloaded. The engine holds admission while it is true (the reload runs in the background).
    public func secretsReloadNeeded() throws -> Bool {
        try secretsVersion() != redactor.version || !redactor.hasLoaded
    }

    /// Whether a background reload should run now: one is needed and its backoff (after failed reads) has passed.
    public func redactorReloadDue() throws -> Bool {
        let version = try secretsVersion()
        guard version != redactor.version || !redactor.hasLoaded else { return false }
        return redactor.retryDue(version: version)
    }

    /// Loads every secret's value from the vault into `redactor` when the secrets changed since the last complete load, or
    /// the last load left some unloaded, and the retry backoff allows it (`force` skips the backoff: explicit owner actions).
    /// Returns whether it (re)loaded. Each secret loads on its own: a vault failure for one (a locked Keychain, a read that
    /// would need the owner's permission, a missing item, a value that is not UTF-8) never stops the others. A failed secret
    /// keeps any value loaded for it before and holds the store (`secretsHeld`); failed reads are retried after 5 s, doubling
    /// to 5 min of awake time, and at once when the secrets version changes (only failed or changed secrets are read again).
    /// With `logFailures` (the engine) each failure is logged once as an `error` activity line in its company, by name and
    /// never with a value, and each hold episode writes one owner notice. Throws only when the database cannot be read.
    @discardableResult
    public func reloadRedactorIfNeeded(vault: any SecretVault, logFailures: Bool = true, force: Bool = false) throws -> Bool {
        // One reload at a time per store, held across reading the metadata, reading the vault and installing: the engine's
        // background reload and the owner's load (in the app) can never interleave. The writes (log lines, the notice) happen
        // after the lock is released: the CLI's lazy loader may hold the database's write lock while it waits for this one.
        let writes: (lines: [ActivityEvent], notice: OwnerNotice?)? = try redactor.withReloadLock {
            let version = try secretsVersion()
            guard version != redactor.version || !redactor.hasLoaded else { return nil }
            guard force || redactor.retryDue(version: version) else { return nil }
            let ticket = redactor.beginLoad()
            let metas = try writer.unsafeReentrantRead { db in try SecretMeta.order(Column("createdAt"), Column("name")).fetchAll(db) }
            let previous = redactor.cachedValues()
            var loaded: [String: Redactor.Loaded] = [:]
            var failures: [(meta: SecretMeta, key: String, reason: String, permission: Bool)] = []
            for meta in metas {
                let key = "\(meta.companyId):\(meta.name)"
                if let cached = previous[key], cached.updatedAt == meta.updatedAt { loaded[key] = cached; continue }
                let reason: String
                var permission = false
                do {
                    if let value = try vault.value(companyId: meta.companyId, name: meta.name) {
                        loaded[key] = Redactor.Loaded(name: meta.name, updatedAt: meta.updatedAt, value: value)
                        continue
                    }
                    reason = "the vault has no value for it"
                } catch {
                    reason = "\(error)"
                    permission = (error as? SecretError) == .needsPermission
                }
                failures.append((meta, key, reason, permission))
                // An older value stays redacted until the new one loads (its stale `updatedAt` makes the next read retry).
                if let old = previous[key] { loaded[key] = old }
            }
            let details = failures.map { Redactor.Failure(name: $0.meta.name, reason: Store.flat($0.reason, max: 200),
                                                          needsPermission: $0.permission) }.sorted { $0.name < $1.name }
            // A result read before the installed one never replaces it (defence in depth behind the lock).
            guard try redactor.install(loaded: loaded, failed: failures.map(\.meta.name).sorted(),
                                   version: failures.isEmpty ? version : nil, ticket: ticket, failures: details) else { return nil }
            redactor.recordAttempt(version: version, failed: !failures.isEmpty)
            if failures.isEmpty { _ = redactor.holdEpisode(held: false) }
            let fresh = redactor.unlogged(Set(failures.map { "\($0.key)@\($0.meta.updatedAt.timeIntervalSince1970)" }))
            guard logFailures else { return ([], nil) }
            let now = Store.now()
            let lines = failures.filter { fresh.contains("\($0.key)@\($0.meta.updatedAt.timeIntervalSince1970)") }.map { f in
                ActivityEvent(companyId: f.meta.companyId, agentId: nil, turnId: nil, kind: .error, text: redactor.apply(
                    "secret \(f.meta.name) could not be loaded (\(Store.flat(f.reason, max: 200))); new turns and agent tool calls are held until it loads. Run `brahma secret load` (or press Load secrets in the app), set it again with `brahma secret set`, or remove it with `brahma secret rm`."),
                    createdAt: now)
            }
            // One owner notice per hold episode, so the app shows why agents stopped.
            var notice: OwnerNotice?
            if redactor.holdEpisode(held: !failures.isEmpty) {
                notice = OwnerNotice(companyId: nil, kind: .system, urgency: .normal,
                                     title: details.allSatisfy(\.needsPermission) ? "Secrets need your permission" : "Secrets could not be loaded",
                                     body: Store.holdText(details), createdAt: now)
            }
            return (lines, notice)
        }
        guard let writes else { return false }
        // Engine-authored text naming secrets, never their values: written directly, not through `redact`, which throws while
        // the secrets are not loaded.
        if !writes.lines.isEmpty || writes.notice != nil {
            try writer.write { db in
                for var line in writes.lines { try line.insert(db) }
                if var n = writes.notice { try n.insert(db) }
            }
        }
        return true
    }

    /// An explicit owner action (`brahma secret load`, the app's Load secrets): reads every secret with `vault` (the
    /// interactive one, so macOS may ask the owner), ignoring the backoff. It first touches every secret's `updatedAt`, so
    /// other processes (the engine, `brahma mcp`) see a new secrets version and retry their background reads at once.
    /// Returns how many loaded and which failed, with the reason (never a value).
    public func ownerLoadSecrets(vault: any SecretVault, now: Date = Store.now()) throws -> (loaded: Int, failed: [(name: String, reason: String)]) {
        try writer.write { db in
            let newest = try Date.fetchOne(db, sql: "SELECT MAX(updatedAt) FROM secret")
            // Strictly newer than any stored time, so the version always changes (a clock that went back cannot hide it).
            let stamp = max(now, (newest ?? now).addingTimeInterval(0.001))
            try db.execute(sql: "UPDATE secret SET updatedAt = ?", arguments: [stamp])
        }
        try reloadRedactorIfNeeded(vault: vault, logFailures: false, force: true)
        let metas = try secretsMetas()
        let failed = redactor.lastFailures
        return (metas.count - failed.count, failed.map { ($0.name, $0.reason) })
    }

    /// Why the store is held, for the owner (the hold notice and the app's banner), or nil when it is not. Names and reasons
    /// only, never values. A read that needed permission points to `brahma secret load`; any other failure (a missing item, a
    /// value that is not UTF-8) points to setting the secret again or removing it.
    public func secretsHoldText() -> String? {
        guard secretsHeld else { return nil }
        let failures = redactor.lastFailures
        if failures.isEmpty {
            let n = (try? secretCount()) ?? 0
            return "Brahma can't read \(n) secret(s) yet; agents are paused. Run `brahma secret load` or press Load secrets in the app."
        }
        return Store.holdText(failures)
    }

    static func holdText(_ failures: [Redactor.Failure]) -> String {
        var parts: [String] = []
        let permission = failures.filter(\.needsPermission)
        let other = failures.filter { !$0.needsPermission }
        if !permission.isEmpty {
            parts.append("Brahma can't read \(permission.count) secret(s) without your permission (\(permission.map(\.name).joined(separator: ", "))); agents are paused. Run `brahma secret load` or press Load secrets in the app.")
        }
        if !other.isEmpty {
            // Grouped by reason, in name order.
            var groups: [(reason: String, names: [String])] = []
            for f in other {
                if let i = groups.firstIndex(where: { $0.reason == f.reason }) { groups[i].names.append(f.name) } else { groups.append((f.reason, [f.name])) }
            }
            let list = groups.map { "\($0.names.joined(separator: ", ")) (\($0.reason))" }.joined(separator: "; ")
            parts.append("Brahma can't read \(other.count) secret(s): \(list). Agents are paused until they load; set them again with `brahma secret set` or remove them with `brahma secret rm`.")
        }
        return parts.joined(separator: " ")
    }

    /// How many secrets the database holds (all companies).
    public func secretCount() throws -> Int {
        try writer.read { db in try SecretMeta.fetchCount(db) }
    }

    private func secretsMetas() throws -> [SecretMeta] {
        try writer.read { db in try SecretMeta.fetchAll(db) }
    }

    /// `brahma mcp`'s check before every tool call: a non-interactive background reload (with the same backoff; failures go
    /// to `diagnostics`, never to the database), then the call is refused while the store is held (`secretsHeld`) with
    /// "secrets are not loaded yet; try again shortly". Never lets a tool persist agent text the redactor might miss.
    public func prepareForToolCall(vault: any SecretVault, diagnostics: (String) -> Void = { _ in }) throws {
        do { try reloadRedactorIfNeeded(vault: vault, logFailures: false) } catch { diagnostics("could not reload secrets: \(error)") }
        guard !secretsHeld else {
            let failed = redactor.failedNames
            if !failed.isEmpty { diagnostics("secrets not loaded: \(failed.joined(separator: ", "))") }
            throw ToolError(message: SecretError.secretsNotLoaded.message)
        }
    }

    // MARK: Owner-side API

    public func secrets(companyId: String) throws -> [SecretMeta] {
        try writer.read { db in
            try SecretMeta.filter(Column("companyId") == companyId).order(Column("name")).fetchAll(db)
        }
    }

    /// Stores the value in the vault and its metadata in the database. The value never goes to the database. The
    /// redactor of a running engine picks the new value up on its next tick.
    public func setSecret(companyId: String, name: String, value: String, isTest: Bool, vault: any SecretVault,
                          now: Date = Store.now()) throws {
        try validateSecret(companyId: companyId, name: name, value: value, isTest: isTest)
        // Vault first: a vault that cannot store leaves no metadata row for a value that is not there.
        try vault.set(companyId: companyId, name: name, value: value)
        try writer.write { db in try upsertSecretMeta(db, companyId: companyId, name: name, isTest: isTest, now: now) }
    }

    func validateSecret(companyId: String, name: String, value: String, isTest: Bool) throws {
        guard SecretName.isValid(name) else { throw SecretError.invalidName }
        if isTest {
            // A test key goes into agents' environments: only names `SecretName.isInjectable` accepts.
            guard SecretName.isInjectable(name) else { throw SecretError.notInjectable }
        } else {
            guard !ChildEnvironment.isReserved(name) else { throw SecretError.reservedName }
        }
        guard !value.isEmpty else { throw SecretError.emptyValue }
        guard try company(id: companyId) != nil else { throw SecretError.unknownCompany }
    }

    func upsertSecretMeta(_ db: Database, companyId: String, name: String, isTest: Bool, now: Date) throws {
        if var row = try SecretMeta.filter(Column("companyId") == companyId && Column("name") == name).fetchOne(db) {
            row.isTest = isTest
            row.updatedAt = now
            try row.update(db)
        } else {
            try SecretMeta(id: UUID().uuidString, companyId: companyId, name: name, isTest: isTest, createdAt: now,
                           updatedAt: now, lastUsedAt: nil).insert(db)
        }
    }

    /// Removes the vault value, then the metadata: a vault that cannot delete (a denied prompt) leaves the row, so the owner
    /// can retry instead of orphaning the value. Deleting a value the vault does not have is not an error.
    public func deleteSecret(companyId: String, name: String, vault: any SecretVault) throws {
        let exists = try writer.read { db in
            try SecretMeta.filter(Column("companyId") == companyId && Column("name") == name).fetchCount(db) > 0
        }
        guard exists else { throw SecretError.notFound }
        try vault.delete(companyId: companyId, name: name)
        _ = try writer.write { db in
            try SecretMeta.filter(Column("companyId") == companyId && Column("name") == name).deleteAll(db)
        }
    }
}

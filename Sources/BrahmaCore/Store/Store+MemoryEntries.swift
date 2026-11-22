import Foundation
import GRDB

/// Who a remembered fact is for: the agent itself, its current item, its team, or the whole company.
public enum RememberScope: String, CaseIterable, Codable, Sendable {
    case mine, item, team, company
}

/// What `Store.remember` did: a new entry, a confirmation of an equal one, or a new entry that contradicts the key's previous one.
public enum RememberResult: Equatable, Sendable {
    case created(MemoryEntry)
    case confirmed(MemoryEntry)
    case contradicts(new: MemoryEntry, old: MemoryEntry)
}

/// The owner's view of memory entries (`brahma memory list`, the app's memory browser).
public struct MemoryEntryFilter: Sendable {
    /// Entries written by, or private to, this agent.
    public var agentId: String?
    public var kind: MemoryEntryKind?
    /// Owner-deleted and removed entries too (their tombstones).
    public var includeRemoved: Bool
    /// A case-insensitive substring of the fact.
    public var query: String?
    public var limit: Int

    public init(agentId: String? = nil, kind: MemoryEntryKind? = nil, includeRemoved: Bool = false, query: String? = nil,
                limit: Int = 500) {
        self.agentId = agentId; self.kind = kind; self.includeRemoved = includeRemoved; self.query = query; self.limit = limit
    }
}

extension Store {
    /// The company's stored secrets as `(name, value)`, read from `vault` (`SecretScan.textFindings` matches them). A vault that
    /// cannot be read throws: the caller refuses what it was about to check (fail closed).
    /// Plan C Task C4a (R-3): every stored secret's value, or a refusal when the vault can't give one of them (search never
    /// checks its output against a partial list).
    public func allKnownSecretValues(companyId: String, vault: any SecretVault) throws -> [(name: String, value: String)] {
        try secrets(companyId: companyId).map { meta in
            guard let value = try vault.value(companyId: companyId, name: meta.name) else {
                throw WorkError.invalid("a stored secret's value can't be read")
            }
            return (name: meta.name, value: value)
        }
    }

    public func knownSecretValues(companyId: String, vault: any SecretVault) throws -> [(name: String, value: String)] {
        try secrets(companyId: companyId).compactMap { meta in
            try vault.value(companyId: companyId, name: meta.name).map { (name: meta.name, value: $0) }
        }
    }

    // MARK: remember

    /// Saves a durable fact for `agentId`, in one transaction. Refusals, in this order (each a `WorkError.invalid`):
    /// 1. the fact (trimmed) is not 1–600 characters; 2. the key does not match `MemoryPolicy.keyPattern`; 3. the confidence is
    /// not in 0…1 or `ttlDays` not in 1…90; 4. scope `item` without a current item (the leased one, else the newest owned
    /// `inProgress` one), scope `team` without a team; 5. the fact or key holds a secret (`SecretScan.textFindings` with
    /// `knownValues`); 6. a new entry past `MemoryPolicy.rememberPerActiveHour` in the last 3600 active seconds.
    ///
    /// With a key, the newest live entry of the same scope and key decides: an equal fact hash confirms it, a different one
    /// makes a new entry that contradicts it. Without a key, an equal fact hash in the same scope confirms. Nothing is deleted.
    /// A session that read outside content (`currentTaint`) writes a tainted entry; a tainted entry never lowers the weight of
    /// the untainted entry it contradicts. Every new or changed entry is indexed at once as a `memory` doc.
    public func remember(companyId: String, by agentId: String, fact rawFact: String, key rawKey: String? = nil,
                         type: MemoryEntryType = .fact, scope: RememberScope = .mine,
                         confidence: Double = MemoryPolicy.defaultConfidence, ttlDays: Int? = nil,
                         knownValues: [(name: String, value: String)], now: Date = Store.now(),
                         paths: BrahmaPaths? = nil) throws -> RememberResult {
        let fact = rawFact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...MemoryPolicy.maxFactChars).contains(fact.count) else {
            throw WorkError.invalid("remember needs a fact of 1–600 characters")
        }
        let key = rawKey.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        if let key, key.range(of: MemoryPolicy.keyPattern, options: .regularExpression) == nil {
            throw WorkError.invalid("keys are lowercase letters, digits, '.', '_' or '-' (up to 80)")
        }
        guard confidence.isFinite, (0...1).contains(confidence) else { throw WorkError.invalid("confidence is between 0 and 1") }
        if let ttlDays, !(1...MemoryPolicy.maxTTLDays).contains(ttlDays) { throw WorkError.invalid("ttl_days is 1–90") }
        guard type != .episode else { throw WorkError.invalid("episodes are recorded by the engine; use fact, preference, howto, person or decision") }
        let home = paths?.home ?? dataHome

        return try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId else {
                throw WorkError.forbidden("not in your company")
            }
            let access: AccessClass
            var itemId: String?
            switch scope {
            case .mine: access = .agent(agentId)
            case .company: access = .company
            case .team:
                guard let team = agent.team, !team.isEmpty else { throw WorkError.invalid("you're not on a team; use scope mine or company") }
                access = .team(team)
            case .item:
                guard let current = try Self.currentItemId(db: db, companyId: companyId, agentId: agentId) else {
                    throw WorkError.invalid("you have no current item; use scope mine")
                }
                access = .item(current)
                itemId = current
            }
            let findings = SecretScan.textFindings(fact, knownValues: knownValues)
                + (key.map { SecretScan.textFindings($0, knownValues: knownValues) } ?? [])
            if let first = findings.first {
                throw WorkError.invalid("that looks like a secret (\(first.label)); secrets belong in the Keychain: use request_secret")
            }

            let stored = try redact(fact)
            let hash = MemoryEntry.factHash(stored)
            let activeNow = try Store.activeNow(db: db, companyId: companyId)
            var sql = """
                SELECT * FROM memoryEntry WHERE companyId = ? AND kind = 'semantic' AND accessKind = ? AND accessId IS ?
                  AND removedAt IS NULL AND purgedAt IS NULL AND (expiresActive IS NULL OR expiresActive > ?)
                """
            var arguments: StatementArguments = [companyId, access.kind, access.id, activeNow]
            if let key {
                sql += " AND key = ? ORDER BY number DESC LIMIT 1"
                arguments += [key]
            } else {
                sql += " AND factHash = ? ORDER BY number DESC LIMIT 1"
                arguments += [hash]
            }
            let previous = try MemoryEntry.fetchOne(db, sql: sql, arguments: arguments)

            if var same = previous, same.factHash == hash {
                same.confirmations += 1
                same.confirmedAt = now
                try same.update(db, columns: ["confirmations", "confirmedAt"])
                try indexEntry(db: db, same, now: now)
                return .confirmed(same)
            }

            let created = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM memoryEntry WHERE companyId = ? AND authorId = ? AND kind = 'semantic'
                  AND inheritedFromId IS NULL AND createdActive IS NOT NULL AND createdActive > ?
                """, arguments: [companyId, agentId, activeNow - 3600]) ?? 0
            guard created < MemoryPolicy.rememberPerActiveHour else {
                throw WorkError.invalid("remember is limited to 30 new entries per active hour")
            }

            let taint = try Store.currentTaint(db: db, agentId: agentId, home: home)
            var entry = MemoryEntry(
                id: UUID().uuidString, companyId: companyId, number: try MemoryEntry.nextNumber(db: db, companyId: companyId),
                kind: .semantic, type: type, key: key, fact: stored, factHash: hash, accessKind: access.kind, accessId: access.id,
                confidence: confidence, confirmations: 0, authorId: agentId, itemId: itemId,
                turnId: try Self.runningTurnId(db: db, agentId: agentId),
                provenance: taint.map { Provenance.external("tainted-session:\($0)") }?.raw ?? Provenance.agent(agentId).raw,
                tainted: taint != nil, taintReason: taint.map { "written by a session that read \($0)" },
                contradictsId: previous?.id, contradictedById: nil, inheritedFromId: nil,
                expiresActive: ttlDays.map { activeNow + Double($0) * 86_400 }, createdAt: now, confirmedAt: nil,
                removedAt: nil, purgedAt: nil, createdActive: activeNow)
            try entry.insert(db)
            guard var old = previous else {
                try indexEntry(db: db, entry, now: now)
                return .created(entry)
            }
            old.contradictedById = entry.id
            try old.update(db, columns: ["contradictedById"])
            try indexEntry(db: db, entry, now: now)
            // Its weight reads the contradiction: halved by an untainted entry, unchanged by a tainted one.
            try indexEntry(db: db, old, now: now)
            entry = try MemoryEntry.fetchOne(db, key: entry.id) ?? entry
            return .contradicts(new: entry, old: old)
        }
    }

    /// The agent's current item: the item it leases, else its newest owned item in progress (scope `item`).
    static func currentItemId(db: Database, companyId: String, agentId: String) throws -> String? {
        if let leased = try String.fetchOne(db, sql: """
            SELECT l.itemId FROM workLease l JOIN workItem i ON i.id = l.itemId
            WHERE l.agentId = ? AND i.companyId = ? ORDER BY l.acquiredAt DESC LIMIT 1
            """, arguments: [agentId, companyId]) {
            return leased
        }
        return try String.fetchOne(db, sql: """
            SELECT id FROM workItem WHERE companyId = ? AND ownerId = ? AND status = 'inProgress'
            ORDER BY updatedAt DESC, number DESC LIMIT 1
            """, arguments: [companyId, agentId])
    }

    /// The agent's running turn, if any.
    static func runningTurnId(db: Database, agentId: String) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT id FROM turn WHERE agentId = ? AND outcome = ? ORDER BY startedAt DESC, rowid DESC LIMIT 1
            """, arguments: [agentId, TurnOutcome.inProgress.rawValue])
    }

    /// `MemoryPolicy.entryWeight` of a semantic entry: halved while a live, untainted entry contradicts it.
    static func entryWeight(db: Database, _ entry: MemoryEntry) throws -> Double {
        var contradicted = false
        if let by = entry.contradictedById, let other = try MemoryEntry.fetchOne(db, key: by), other.companyId == entry.companyId,
           other.removedAt == nil, other.purgedAt == nil, !other.tainted {
            contradicted = true
        }
        return MemoryPolicy.entryWeight(confidence: entry.confidence, confirmations: entry.confirmations, contradicted: contradicted)
    }

    /// Indexes a live semantic entry as its `memory` doc (title `Memory mem:<n> · <type> · @<author>`). Removed or purged entries
    /// are never indexed again (a re-ingest would revive the doc), and episodes keep the doc the recorder wrote.
    func indexEntry(db: Database, _ entry: MemoryEntry, now: Date) throws {
        guard entry.kind == .semantic, entry.removedAt == nil, entry.purgedAt == nil, let access = entry.access else { return }
        let handle = try String.fetchOne(db, sql: "SELECT name FROM agent WHERE id = ? AND companyId = ?",
                                         arguments: [entry.authorId, entry.companyId]) ?? entry.authorId
        try ingest(db: db, MemoryIngestDoc(
            companyId: entry.companyId, source: .memory, sourceId: entry.id, ref: entry.ref,
            title: "Memory \(entry.ref) · \(entry.type.rawValue) · @\(handle)", body: entry.fact, access: access,
            provenance: Provenance(raw: entry.provenance) ?? .external(entry.provenance), tainted: entry.tainted,
            taintReason: entry.taintReason, weight: try Self.entryWeight(db: db, entry), authorId: entry.authorId,
            itemId: entry.itemId, createdAt: entry.createdAt, expiresActive: entry.expiresActive), now: now)
    }

    // MARK: Owner browse, delete and inherit

    /// Entries for the owner, newest first.
    public func memoryEntries(companyId: String, filter: MemoryEntryFilter = MemoryEntryFilter()) throws -> [MemoryEntry] {
        try writer.read { db in
            var sql = "SELECT * FROM memoryEntry WHERE companyId = ?"
            var arguments: StatementArguments = [companyId]
            if let agentId = filter.agentId {
                sql += " AND (authorId = ? OR (accessKind = 'agent' AND accessId = ?))"
                arguments += [agentId, agentId]
            }
            if let kind = filter.kind {
                sql += " AND kind = ?"
                arguments += [kind.rawValue]
            }
            if !filter.includeRemoved { sql += " AND removedAt IS NULL AND purgedAt IS NULL" }
            if let query = filter.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
                sql += " AND instr(lower(fact), lower(?)) > 0"
                arguments += [query]
            }
            sql += " ORDER BY number DESC LIMIT ?"
            arguments += [max(filter.limit, 0)]
            return try MemoryEntry.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    /// The owner deletes `mem:<number>`: the fact, its hash and its key are emptied, `purgedAt` and `removedAt` set, and its doc
    /// purged, all in the secure purge's transaction (`purgeMemoryDocs`: `secure_delete`, FTS `optimize`, a WAL checkpoint),
    /// so the fact's text leaves the database file too. The tombstone row stays. An entry it contradicted gets its full weight
    /// back. Returns false when it was already deleted; a number this company does not have is `WorkError.notFound`.
    @discardableResult
    public func ownerDeleteMemory(companyId: String, number: Int, now: Date = Store.now()) throws -> Bool {
        guard let id = try writer.read({ db in
            try String.fetchOne(db, sql: "SELECT id FROM memoryEntry WHERE companyId = ? AND number = ?", arguments: [companyId, number])
        }) else { throw WorkError.notFound("no memory mem:\(number)") }
        return try purgeMemoryDocs(companyId: companyId, source: .memory, sourceIds: [id], now: now) { db -> Bool in
            guard var entry = try MemoryEntry.filter(Column("companyId") == companyId && Column("id") == id).fetchOne(db) else {
                throw WorkError.notFound("no memory mem:\(number)")
            }
            guard entry.purgedAt == nil else { return false }
            entry.fact = ""
            entry.factHash = ""
            entry.key = nil
            entry.purgedAt = now
            entry.removedAt = entry.removedAt ?? now
            try entry.update(db)
            if let oldId = entry.contradictsId, let old = try MemoryEntry.fetchOne(db, key: oldId), old.companyId == companyId {
                try indexEntry(db: db, old, now: now)
            }
            return true
        }
    }

    /// The owner hands `from`'s private semantic entries (agent scope, live, unexpired) to `to`. Copies keep the fact, key, type,
    /// confidence, confirmations, expiry, `tainted`, `taintReason` and `provenance`; `inheritedFromId` is the only new marker.
    /// A contradiction between two copied entries is kept between their copies. Episodes are never copied, and an entry `to`
    /// already inherited is not copied again. Returns the number copied. Both agents must be in the company.
    @discardableResult
    public func inheritMemory(companyId: String, from: String, to: String, now: Date = Store.now()) throws -> Int {
        try writer.write { db in
            for id in [from, to] {
                guard let agent = try Agent.fetchOne(db, key: id), agent.companyId == companyId else {
                    throw WorkError.forbidden("not in your company")
                }
            }
            guard from != to else { throw WorkError.invalid("an agent cannot inherit its own memory") }
            let activeNow = try Store.activeNow(db: db, companyId: companyId)
            let originals = try MemoryEntry.fetchAll(db, sql: """
                SELECT * FROM memoryEntry WHERE companyId = ? AND kind = 'semantic' AND accessKind = 'agent' AND accessId = ?
                  AND removedAt IS NULL AND purgedAt IS NULL AND (expiresActive IS NULL OR expiresActive > ?)
                ORDER BY number
                """, arguments: [companyId, from, activeNow])
            let already = Set(try String.fetchAll(db, sql: """
                SELECT inheritedFromId FROM memoryEntry WHERE companyId = ? AND accessKind = 'agent' AND accessId = ?
                  AND inheritedFromId IS NOT NULL AND removedAt IS NULL AND purgedAt IS NULL
                """, arguments: [companyId, to]))
            var copies: [(original: MemoryEntry, copy: MemoryEntry)] = []
            for original in originals where !already.contains(original.id) {
                var copy = original
                copy.id = UUID().uuidString
                copy.number = try MemoryEntry.nextNumber(db: db, companyId: companyId)
                copy.accessId = to
                copy.inheritedFromId = original.id
                copy.contradictsId = nil
                copy.contradictedById = nil
                copy.turnId = nil
                copy.createdAt = now
                copy.createdActive = activeNow
                try copy.insert(db)
                copies.append((original, copy))
            }
            let copyOf = Dictionary(copies.map { ($0.original.id, $0.copy.id) }, uniquingKeysWith: { a, _ in a })
            for (original, var copy) in copies {
                copy.contradictsId = original.contradictsId.flatMap { copyOf[$0] }
                copy.contradictedById = original.contradictedById.flatMap { copyOf[$0] }
                try copy.update(db, columns: ["contradictsId", "contradictedById"])
            }
            for (_, copy) in copies {
                guard let stored = try MemoryEntry.fetchOne(db, key: copy.id) else { continue }
                try indexEntry(db: db, stored, now: now)
            }
            return copies.count
        }
    }
}

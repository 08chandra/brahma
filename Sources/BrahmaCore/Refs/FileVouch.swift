import Foundation
import GRDB

/// Plan C Task C2b, fix round 5 (controller Ruling 38): a file the secret gate refused for its STRUCTURE (a PDF whose
/// structure couldn't be verified, bytes or a part in a format the engine can't open, archive members it can't decode), and
/// the owner's vouch for exactly those bytes. Pinned to the company, the ref's name (`canonicalHash`, the SHA-256 of its
/// canonical form; the name itself is never kept, only `shown`, as messages show it) and the bytes' SHA-256: any byte
/// changed, another name or another company, and the vouch does not apply. A vouch lets the gate past those structure
/// refusals only: every byte it can read is still scanned (a stored value or a secret pattern refuses as before), and no
/// taint is touched. Owner callers only: `brahma vouch file <company> --sha256 <64 hex> <path>` and the refusal alert's Inbox action
/// (`AppModel.vouchFile`); no agent tool reaches it.
public struct FileVouch: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "fileVouch"

    public var id: String
    public var companyId: String
    public var canonicalHash: String
    public var shown: String
    public var sha256: String
    public var reason: String
    public var refusedAt: Date
    public var vouchedBy: String?
    public var vouchedAt: Date?

    public init(id: String = UUID().uuidString, companyId: String, canonicalHash: String, shown: String, sha256: String, reason: String,
                refusedAt: Date, vouchedBy: String? = nil, vouchedAt: Date? = nil) {
        self.id = id; self.companyId = companyId; self.canonicalHash = canonicalHash; self.shown = shown; self.sha256 = sha256
        self.reason = reason; self.refusedAt = refusedAt; self.vouchedBy = vouchedBy; self.vouchedAt = vouchedAt
    }
}

extension Store {
    /// What keys a refused file's alert: `file-structure:<row id>`.
    static let fileVouchReasonPrefix = "file-structure:"

    /// Whether `ask` is the alert about a file refused for its structure (the Inbox then offers the owner's vouch).
    public static func isFileVouchAlert(_ ask: Ask) -> Bool {
        ask.kind == .engineAlert && (ask.subjectId ?? "").hasPrefix(engineAlertKey(fileVouchReasonPrefix))
    }

    /// The SHA-256 a ref's name is kept by.
    static func canonicalHash(_ canonical: String) -> String { SHA256.hex(Data(canonical.utf8)) }

    /// Whether the owner vouched for exactly these bytes under this name in this company. Fail closed: a database that
    /// can't be read says no.
    func isFileVouched(companyId: String, canonical: String, sha256: String) -> Bool {
        let hash = Self.canonicalHash(canonical)
        return (try? writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT 1 FROM fileVouch WHERE companyId = ? AND canonicalHash = ? AND sha256 = ? AND vouchedAt IS NOT NULL
                """, arguments: [companyId, hash, sha256])
        }) == true
    }

    /// The gate refused these bytes for their structure: the refusal is recorded (once per company, name and bytes) and,
    /// unless the owner already vouched for them, the owner is alerted (once while that alert is open) with the exact
    /// command and the Inbox action. Best effort: the refusal stands whether or not this could be written. `shown` is the
    /// name with every stored value and secret pattern redacted (`SecretGate.shown`); `reason` the refusal without the
    /// command.
    func recordStructureRefusal(companyId: String, canonical: String, shown: String, sha256: String, reason: String, now: Date) {
        do {
            try writer.write { db in
                guard let company = try Company.fetchOne(db, key: companyId) else { return }
                let hash = Self.canonicalHash(canonical)
                var row = try FileVouch.fetchOne(db, sql: "SELECT * FROM fileVouch WHERE companyId = ? AND canonicalHash = ? AND sha256 = ?",
                                                 arguments: [companyId, hash, sha256])
                // Breaker B-2: `refusedAt` is the version's LAST refusal, always after every other version's under the name, so
                // the version refused last is one (the only one `vouchFile` takes).
                let others = try Date.fetchOne(db, sql: """
                    SELECT MAX(refusedAt) FROM fileVouch WHERE companyId = ? AND canonicalHash = ? AND sha256 != ?
                    """, arguments: [companyId, hash, sha256])
                let at = others.map { max(now, $0.addingTimeInterval(0.002)) } ?? now
                if var existing = row {
                    if existing.vouchedAt == nil, existing.refusedAt != at {
                        existing.refusedAt = at
                        try existing.update(db)
                        row = existing
                    }
                } else {
                    let fresh = FileVouch(companyId: companyId, canonicalHash: hash, shown: shown, sha256: sha256, reason: reason, refusedAt: at)
                    try fresh.insert(db)
                    row = fresh
                }
                guard let row, row.vouchedAt == nil else { return }
                let reasonKey = Self.fileVouchReasonPrefix + row.id
                let open = try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.engineAlert
                                          && Column("status") == AskStatus.pendingOwner.rawValue
                                          && Column("subjectId") == Store.engineAlertKey(reasonKey)).fetchCount(db)
                guard open == 0 else { return }
                let how = shown == SecretGate.withheldName
                    ? "use Vouch for this file here"
                    : "run \(SecretGate.vouchCommand(slug: company.slug, shown: shown, sha256: sha256)), or use Vouch for this file here"
                let text = "\(shown) was refused: \(reason). If you trust this exact file (sha256 \(sha256)), \(how). "
                    + "A vouch skips only this check: Brahma still scans what it can read of the file and refuses a stored secret "
                    + "or a secret pattern in it, and any change to the file ends the vouch."
                try EngineAlerts.raise(store: self, db: db, text: text, now: now, reason: reasonKey, companyId: companyId)
            }
        } catch {
            FileHandle.standardError.write(Data("brahma: could not record a file refused for its structure: \(error)\n".utf8))
        }
    }

    /// The owner vouches for the file the gate refused under `canonical` in the company, naming the refused bytes by their
    /// full `sha256` (all 64 hex digits, as the refusal and the alert print them). Ruling 40 (B-4): the file is identified
    /// by its canonical name only (`canonicalHash`); the name as a refusal showed it is accepted only when it shows exactly
    /// one refused file (else the refusal lists them as ambiguous), and never steers the vouch to another file. The hash
    /// must match a recorded version exactly: a prefix never vouches. Breaker B-2 (Ruling 28's class): only the version the
    /// gate refused LAST for that file can be vouched this way, so a command printed for an earlier version, pasted after the
    /// file was rewritten and refused again, vouches nothing; the refusal shows the version refused last and its own
    /// command. Those exact bytes then pass the gate's structure refusals. An owner activity line; the refusal's alert is
    /// closed. Owner callers only (the owner CLI, `brahma vouch file`). Vouching the last version again is a no-op that
    /// returns the vouch.
    @discardableResult
    public func vouchFile(companyId: String, canonical: String, sha256: String, now: Date) throws -> FileVouch {
        let hash = sha256.lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw WorkError.invalid("give the file's full sha256 (all 64 hex digits), as the refusal prints it")
        }
        return try writer.write { db in
            guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            var rows = try FileVouch.fetchAll(db, sql: """
                SELECT * FROM fileVouch WHERE companyId = ? AND canonicalHash = ? ORDER BY refusedAt DESC
                """, arguments: [companyId, Self.canonicalHash(canonical)])
            if rows.isEmpty {
                // The name as a refusal showed it: only when it is one file's.
                let shown = try FileVouch.fetchAll(db, sql: """
                    SELECT * FROM fileVouch WHERE companyId = ? AND shown = ? ORDER BY refusedAt DESC
                    """, arguments: [companyId, canonical])
                let files = Dictionary(grouping: shown, by: \.canonicalHash)
                if files.count > 1 {
                    let listed = files.values.compactMap(\.first).sorted { $0.refusedAt > $1.refusedAt }
                        .map { "one last refused as sha256 \($0.sha256.prefix(12))… (\($0.reason))" }.joined(separator: "; ")
                    throw WorkError.invalid("more than one file Brahma refused is shown as \(shown[0].shown) (\(listed)), so the name doesn't "
                                            + "say which; vouch for the one you mean from its alert in the Inbox, which names it exactly")
                }
                rows = shown
            }
            guard let newest = rows.first else {
                // (The name is not echoed: it is the caller's own text, and may hold anything.)
                throw WorkError.notFound("Brahma has not refused a file by that name for its structure in this company, so there is "
                                         + "nothing to vouch for")
            }
            // The version refused last.
            let last = rows.filter { $0.refusedAt == newest.refusedAt }
            guard Set(last.map(\.sha256)).count == 1 else {
                throw WorkError.invalid("\(newest.shown) was refused as more than one version at once; check the file and try again")
            }
            guard newest.sha256 == hash else {
                let how = newest.vouchedAt == nil
                    ? "if you trust the file as it is now, run \(SecretGate.vouchCommand(slug: company.slug, shown: newest.shown, sha256: newest.sha256))"
                    : "that version is already vouched for"
                let what = rows.contains { $0.sha256 == hash }
                    ? "that sha256 is not the version of \(newest.shown) Brahma refused last: the file changed since that command was printed"
                    : "Brahma never refused \(newest.shown) with that sha256"
                throw WorkError.invalid("\(what), and was last refused as sha256 \(newest.sha256); \(how)")
            }
            var row = newest
            guard row.vouchedAt == nil else { return row }
            return try vouch(db, &row, now: now)
        }
    }

    /// The refusal alert's action: the owner vouches for the file `alertAskId` is about (`vouchFile`). Any other ask is
    /// refused. Owner callers only (the app).
    @discardableResult
    public func vouchFile(alertAskId: String, now: Date) throws -> FileVouch {
        try writer.write { db in
            guard let ask = try Ask.fetchOne(db, key: alertAskId), Self.isFileVouchAlert(ask), let subject = ask.subjectId else {
                throw WorkError.invalid("only the alert about a file refused for its structure can vouch for that file")
            }
            let id = String(subject.dropFirst(Store.engineAlertKey(Self.fileVouchReasonPrefix).count))
            guard var row = try FileVouch.fetchOne(db, key: id), row.companyId == ask.companyId else {
                throw WorkError.notFound("the file this alert is about is no longer recorded")
            }
            guard row.vouchedAt == nil else { return row }
            return try vouch(db, &row, now: now)
        }
    }

    /// Marks `row` vouched by the owner, logs it, and closes its alert.
    private func vouch(_ db: Database, _ row: inout FileVouch, now: Date) throws -> FileVouch {
        row.vouchedBy = "owner"
        row.vouchedAt = now
        try row.update(db)
        try ActivityEvent(companyId: row.companyId, agentId: nil, turnId: nil, kind: .access,
                          text: "Owner vouched for \(row.shown) (sha256 \(row.sha256.prefix(12))…): \(row.reason); Brahma now scans "
                              + "what it can read of exactly these bytes", createdAt: now).insert(db)
        let key = Store.engineAlertKey(Self.fileVouchReasonPrefix + row.id)
        let alerts = try Ask.filter(Column("companyId") == row.companyId && Column("kind") == AskKind.engineAlert
                                    && Column("status") == AskStatus.pendingOwner.rawValue && Column("subjectId") == key).fetchAll(db)
        for var ask in alerts {
            ask.ownerNote = "vouched"
            ask.ownerAnswer = "vouched"
            try settle(db, ask: &ask, status: .answered, decidedBy: "owner", tellRequesterToo: false, now: now)
        }
        return row
    }
}

import Foundation
import GRDB

/// Plan C Task C2b, fix round 5 (controller Ruling 38): a file the secret gate refused for its STRUCTURE (a PDF whose
/// structure couldn't be verified, bytes or a part in a format the engine can't open, archive members it can't decode), and
/// the owner's vouch for exactly those bytes. Pinned to the company, the ref's name (`canonicalHash`, the SHA-256 of its
/// canonical form; the name itself is never kept, only `shown`, as messages show it) and the bytes' SHA-256: any byte
/// changed, another name or another company, and the vouch does not apply. A vouch lets the gate past those structure
/// refusals only: every byte it can read is still scanned (a stored value or a secret pattern refuses as before), and no
/// taint is touched. Owner callers only: `brahma vouch file <company> --id <64 hex> --sha256 <64 hex> [<path>]` (C2b-carry (b):
/// the file's id, `canonicalHash`, and the bytes' full hash bind the vouch; no name decides it) and the refusal alert's Inbox action
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
    /// C2b-carry (c), Ruling 42: for a vouched PDF, the SHA-256 of its flattened copy in the vault (`flattened/<id>.pdf`),
    /// once made (`Store.gatedBytes`).
    public var copySha256: String?

    public init(id: String = UUID().uuidString, companyId: String, canonicalHash: String, shown: String, sha256: String, reason: String,
                refusedAt: Date, vouchedBy: String? = nil, vouchedAt: Date? = nil, copySha256: String? = nil) {
        self.id = id; self.companyId = companyId; self.canonicalHash = canonicalHash; self.shown = shown; self.sha256 = sha256
        self.reason = reason; self.refusedAt = refusedAt; self.vouchedBy = vouchedBy; self.vouchedAt = vouchedAt
        self.copySha256 = copySha256
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
                let how = "run \(SecretGate.vouchCommand(slug: company.slug, id: hash, sha256: sha256, shown: shown)), or use Vouch for "
                    + "this file here"
                let text = "\(shown) was refused: \(reason). If you trust this exact file (sha256 \(sha256)), \(how). "
                    + "A vouch skips only this check. For a PDF, what Brahma then shares is a flattened re-render of its visible "
                    + "pages, checked again like any file (the original is never shared); for other files Brahma still scans what "
                    + "it can read and refuses a stored secret or a secret pattern in it. Any change to the file ends the vouch."
                try EngineAlerts.raise(store: self, db: db, text: text, now: now, reason: reasonKey, companyId: companyId)
            }
        } catch {
            FileHandle.standardError.write(Data("brahma: could not record a file refused for its structure: \(error)\n".utf8))
        }
    }

    /// C2b-carry (b), Ruling 40 as the controller bound it: the owner vouches for the file whose id is `fileId` (its
    /// canonical name's hash, `canonicalHash`, as the refusal and the alert print it) and whose refused bytes are `sha256`
    /// (all 64 hex digits). A vouch binds to those two only: no name lookup ever decides which file is vouched. `name`, when
    /// the owner typed one (the printed command carries the name as shown, for the owner to read), must be that file's
    /// shown or canonical name, and is checked for collisions only.
    /// - Only the version the gate refused LAST for that file vouches (breaker B-2): a command printed before the file
    ///   was rewritten and refused again vouches nothing; the refusal names that file's newest version and its command
    ///   (the same id: never another file's).
    /// - Any name collision refuses as ambiguous, vouching nothing (`collisions`): another refused file shown the same,
    ///   whose canonical name is this one's shown name (or the other way round), or that the typed name names. The refusal
    ///   lists every colliding file (shown name, id, sha256 prefix, refused at), each with its own exact command carrying
    ///   `--ambiguous-ok` (`acknowledgeAmbiguity`); only that form vouches a colliding file, and only its own row.
    /// Those exact bytes under that name then pass the gate's structure refusals (a PDF: through its flattened copy,
    /// Ruling 42). An owner activity line; the refusal's alert is closed. Owner callers only (the owner CLI, `brahma vouch
    /// file`). Vouching the last version again is a no-op that returns the vouch.
    @discardableResult
    public func vouchFile(companyId: String, fileId: String, sha256: String, name: String? = nil, acknowledgeAmbiguity: Bool = false,
                          now: Date) throws -> FileVouch {
        let hash = sha256.lowercased(), id = fileId.lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw WorkError.invalid("give the file's full sha256 (all 64 hex digits), as the refusal prints it")
        }
        guard id.count == 64, id.allSatisfy(\.isHexDigit) else {
            throw WorkError.invalid("give the file's id (all 64 hex digits), as the refusal prints it")
        }
        let zone = ownerTimeZone()
        return try writer.write { db in
            guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            let rows = try FileVouch.fetchAll(db, sql: """
                SELECT * FROM fileVouch WHERE companyId = ? AND canonicalHash = ? ORDER BY refusedAt DESC
                """, arguments: [companyId, id])
            guard let newest = rows.first else {
                throw WorkError.notFound("Brahma has not refused a file with that id for its structure in this company, so there is "
                                         + "nothing to vouch for")
            }
            // (A typed name is not echoed: it is the caller's own text, and may hold anything.)
            if let name, name != newest.shown, Self.canonicalHash(name) != id {
                throw WorkError.invalid("the name given is not the name of the file with that id; nothing was vouched")
            }
            // The version refused last.
            let last = rows.filter { $0.refusedAt == newest.refusedAt }
            guard Set(last.map(\.sha256)).count == 1 else {
                throw WorkError.invalid("\(newest.shown) was refused as more than one version at once; check the file and try again")
            }
            guard newest.sha256 == hash else {
                let how = newest.vouchedAt == nil
                    ? "if you trust the file as it is now, run \(SecretGate.vouchCommand(slug: company.slug, id: newest.canonicalHash, sha256: newest.sha256, shown: newest.shown))"
                    : "that version is already vouched for"
                let what = rows.contains { $0.sha256 == hash }
                    ? "that sha256 is not the version of \(newest.shown) Brahma refused last: the file changed since that command was printed"
                    : "Brahma never refused \(newest.shown) with that sha256"
                throw WorkError.invalid("\(what), and was last refused as sha256 \(newest.sha256); \(how)")
            }
            let colliding = try Self.collisions(db, target: newest, typed: name)
            if !colliding.isEmpty && !acknowledgeAmbiguity {
                throw Self.ambiguous([newest] + colliding, slug: company.slug, zone: zone, inbox: false)
            }
            var row = newest
            guard row.vouchedAt == nil else { return row }
            return try vouch(db, &row, now: now)
        }
    }

    /// C2b-carry (b): every other refused file (another `canonicalHash`) in `target`'s company that the owner could take
    /// for it: shown the same; whose canonical name is `target`'s shown name, or whose shown name is `target`'s canonical
    /// name; or, when the owner typed a name, shown as that name or named by it. The newest row of each file, newest first.
    static func collisions(_ db: Database, target: FileVouch, typed: String?) throws -> [FileVouch] {
        let others = try FileVouch.fetchAll(db, sql: """
            SELECT * FROM fileVouch WHERE companyId = ? AND canonicalHash != ? ORDER BY refusedAt DESC
            """, arguments: [target.companyId, target.canonicalHash])
        let shownHash = canonicalHash(target.shown), typedHash = typed.map(canonicalHash)
        var seen = Set<String>()
        return others.filter { other in
            let collides = other.shown == target.shown || other.canonicalHash == shownHash || canonicalHash(other.shown) == target.canonicalHash
                || (typed.map { other.shown == $0 } ?? false) || other.canonicalHash == typedHash
            return collides && seen.insert(other.canonicalHash).inserted
        }
    }

    /// The ambiguity refusal: every file listed (shown name, id, sha256 prefix, refused at), each with its own exact
    /// command carrying `--ambiguous-ok` (the Inbox: the alert's confirmation instead).
    static func ambiguous(_ files: [FileVouch], slug: String, zone: TimeZone, inbox: Bool) -> WorkError {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let listed = files.enumerated().map { k, f in
            "(\(k + 1)) \(f.shown) — id \(f.canonicalHash), sha256 \(f.sha256.prefix(12))…, refused \(format.string(from: f.refusedAt))"
                + (f.vouchedAt == nil ? "" : ", already vouched")
                + (inbox ? "" : ": \(SecretGate.vouchCommand(slug: slug, id: f.canonicalHash, sha256: f.sha256, shown: f.shown, acknowledged: true))")
        }.joined(separator: "; ")
        let how = inbox
            ? "check which file you mean, then confirm in the Inbox, where the files are shown side by side"
            : "check which file you mean, then run that file's own command"
        return WorkError.invalid("\(files.count) files Brahma refused could be taken for one another by their names, so nothing was "
                                 + "vouched; \(how): \(listed)")
    }

    /// C2b-carry (b): the file the alert `alertAskId` is about, and every other refused file it could be taken for
    /// (`collisions`); the Inbox shows them side by side and asks for the owner's explicit confirmation before it vouches a
    /// colliding file. Nil for any other ask.
    public func fileVouchChoice(alertAskId: String) throws -> (file: FileVouch, colliding: [FileVouch])? {
        try writer.read { db in
            guard let ask = try Ask.fetchOne(db, key: alertAskId), Self.isFileVouchAlert(ask), let subject = ask.subjectId else { return nil }
            let id = String(subject.dropFirst(Store.engineAlertKey(Self.fileVouchReasonPrefix).count))
            guard let row = try FileVouch.fetchOne(db, key: id), row.companyId == ask.companyId else { return nil }
            return (row, try Self.collisions(db, target: row, typed: nil))
        }
    }

    /// The refusal alert's action: the owner vouches for the file `alertAskId` is about (its exact row: that id and those
    /// bytes). A file that collides with another refused file (`collisions`) vouches only with `acknowledgeAmbiguity`, the
    /// owner's confirmation after the Inbox showed the files side by side. Any other ask is refused. Owner callers only
    /// (the app).
    @discardableResult
    public func vouchFile(alertAskId: String, acknowledgeAmbiguity: Bool = false, now: Date) throws -> FileVouch {
        let zone = ownerTimeZone()
        return try writer.write { db in
            guard let ask = try Ask.fetchOne(db, key: alertAskId), Self.isFileVouchAlert(ask), let subject = ask.subjectId else {
                throw WorkError.invalid("only the alert about a file refused for its structure can vouch for that file")
            }
            let id = String(subject.dropFirst(Store.engineAlertKey(Self.fileVouchReasonPrefix).count))
            guard var row = try FileVouch.fetchOne(db, key: id), row.companyId == ask.companyId,
                  let company = try Company.fetchOne(db, key: row.companyId) else {
                throw WorkError.notFound("the file this alert is about is no longer recorded")
            }
            guard row.vouchedAt == nil else { return row }
            let colliding = try Self.collisions(db, target: row, typed: nil)
            if !colliding.isEmpty && !acknowledgeAmbiguity {
                throw Self.ambiguous([row] + colliding, slug: company.slug, zone: zone, inbox: true)
            }
            return try vouch(db, &row, now: now)
        }
    }

    /// What a vouch does, as the CLI and the Inbox say it (Ruling 42: a PDF is shared only as a flattened re-render of
    /// its visible pages).
    public static func vouchedLine(_ row: FileVouch) -> String {
        "If it is a PDF, Brahma shares only a flattened re-render of its visible pages, checked again like any file (the "
            + "original is never shared); other files pass the structure check, and every byte Brahma can read in them is still "
            + "scanned for stored secrets and secret patterns. Any change to the file ends the vouch."
    }

    /// Marks `row` vouched by the owner, logs it, and closes its alert.
    private func vouch(_ db: Database, _ row: inout FileVouch, now: Date) throws -> FileVouch {
        row.vouchedBy = "owner"
        row.vouchedAt = now
        try row.update(db)
        try ActivityEvent(companyId: row.companyId, agentId: nil, turnId: nil, kind: .access,
                          text: "Owner vouched for \(row.shown) (sha256 \(row.sha256.prefix(12))…): \(row.reason); a PDF is shared only "
                              + "as a flattened re-render of its visible pages, other files pass with what Brahma can read of exactly "
                              + "these bytes scanned", createdAt: now).insert(db)
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

import Foundation
import GRDB

/// Controller Ruling 48 (C3b fix round 2): inside a turn, the archive and PDF helpers never run in the agent's process tree.
/// `brahma mcp` runs inside the turn's sandbox, where Seatbelt can't apply a second sandbox (`sandbox_apply: Operation not
/// permitted`), and the turn's sandbox is not loosened for it. Instead, when the secret gate (or the text an `open_ref` shows)
/// needs a helper, the tool queues a `gateRequest` that names only the ref (its `WorkRef`, never bytes or a path the tool
/// chose) and the purpose, under the turn's id. The engine (its tick, outside every turn sandbox) answers it only while that
/// turn holds its live credential (`Store.turnCredentialIsLive`, what every call of the turn's MCP server needs), and only
/// for a ref the agent may read in full: it resolves the ref itself, reads the bytes itself, runs the sandboxed deny-default
/// helpers and writes back only the verdict and the gated bytes (or the rendered text). The tool then works with the engine's
/// bytes, never its own. No answer within `QueuedRefGate.timeout` refuses (fail closed) and withdraws the request. Final wave
/// B1 item 11: the concierge's server queues requests the same way under its run (`QueuedRefGate(conciergeRequestId:)`); the
/// engine answers them only while that `conciergeRun` is live, resolving the ref as `.concierge`.
public enum GatePurpose: String, Codable, Sendable {
    /// The share's step 4 (`gatedBytes` strict, the shown read).
    case check
    /// A committed file's pin (`pinRef`: the check of its bytes, unpinned name).
    case checkCommitted
    /// A worktree or `.brahma` file's pin (the bytes that become the blob).
    case pin
    /// A private lab or notes file's snapshot (`gatedBytes` strict, the file's own name).
    case snapshot
    /// `open_ref {copy: true}` (the bytes copied).
    case copy
    /// `open_ref`: the text it shows (gated, then extracted).
    case render

    /// Whether the gate refuses a secret pattern in bytes that can't be redacted (`gatedBytes`), rather than passing it to the
    /// caller as `.pattern` (`SecretGate.check`, which `openRef` and `pinRef` handle themselves).
    var strict: Bool { self == .check || self == .snapshot }
}

/// What the engine answered: the bytes to use (the engine's own read, gated: a vouched PDF's flattened copy), their extension
/// and the gate's verdict; for `.render`, the text to show (as UTF-8) with extension `""`.
public struct EngineGateResult: Equatable, Sendable {
    public var data: Data
    public var ext: String
    public var verdict: ScanVerdict
}

/// What asks the engine to gate a ref (`QueuedRefGate` in `brahma mcp`).
public protocol RefGateBroker: Sendable {
    /// `expected`: the size and SHA-256 of the bytes the caller will act on (Ruling 52): the engine gates exactly those, or
    /// refuses.
    func gate(companyId: String, agentId: String, ref: WorkRef, purpose: GatePurpose,
              expected: (size: Int, sha256: String)) throws -> EngineGateResult
}

/// The archive reader of a turn's MCP server: it never runs a helper. Every helper call throws `NeedsEngineGate`, which the
/// gate points (`Store.gateRef`) turn into a request to the engine through `broker`.
public struct EngineGateArchives: ArchiveReader {
    public let broker: any RefGateBroker

    public init(broker: any RefGateBroker) { self.broker = broker }

    public func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
        throw NeedsEngineGate()
    }

    public func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart] { throw NeedsEngineGate() }

    public func flattenPDF(of data: Data, maxBytes: Int, timeout: Duration) throws -> Data { throw NeedsEngineGate() }
}

/// A gate in the tool's process reached a helper: the engine must gate this ref.
struct NeedsEngineGate: Error {}

/// `brahma mcp`'s broker: a `gateRequest` row under the turn's id, then the engine's answer read back (polled), then the row
/// deleted. The engine not answering within `timeout` refuses and withdraws the request.
public struct QueuedRefGate: RefGateBroker {
    public static let defaultTimeout: Duration = .seconds(120)
    static let unanswered = "that ref couldn't be checked for secrets just now (the engine didn't answer); try again"

    let store: Store
    let turnId: String
    let timeout: Duration

    public init(store: Store, turnId: String, timeout: Duration = QueuedRefGate.defaultTimeout) {
        self.store = store; self.turnId = turnId; self.timeout = timeout
    }

    /// Final wave B1 item 11: the concierge's broker. Its requests are written under the concierge's run (`requestId` in the
    /// `turnId` column, `ConciergeCaps.agentId` as the agent); the engine answers them only while that run is live.
    public init(store: Store, conciergeRequestId: String, timeout: Duration = QueuedRefGate.defaultTimeout) {
        self.store = store; self.turnId = conciergeRequestId; self.timeout = timeout
    }

    public func gate(companyId: String, agentId: String, ref: WorkRef, purpose: GatePurpose,
                     expected: (size: Int, sha256: String)) throws -> EngineGateResult {
        let id = try enqueue(companyId: companyId, agentId: agentId, ref: ref, purpose: purpose, expected: expected)
        defer { try? store.writer.write { db in try db.execute(sql: "DELETE FROM gateRequest WHERE id = ?", arguments: [id]) } }
        // Awake time: a Mac asleep while the engine works is not the engine failing to answer.
        let deadline = AwakeTime.deadline(after: timeout)
        while true {
            let row = try store.writer.read { db in try Row.fetchOne(db, sql: "SELECT * FROM gateRequest WHERE id = ?", arguments: [id]) }
            guard let row else { throw WorkError.invalid(Self.unanswered) }
            switch row["status"] as String {
            case "done":
                guard let data: Data = row["result"], let verdict = Store.decodeVerdict(row["verdict"]) else {
                    throw WorkError.notFound(Store.refUnavailable)
                }
                return EngineGateResult(data: data, ext: row["resultExt"] ?? "", verdict: verdict)
            case "refused":
                throw WorkError.invalid(row["message"] ?? Store.refUnavailable)
            case "unavailable":
                throw WorkError.notFound(Store.refUnavailable)
            case "pending", "working":
                if AwakeTime.clock.now >= deadline {
                    // Withdrawn before the engine starts it (a request it already took is answered into a row that is deleted).
                    try? store.writer.write { db in
                        try db.execute(sql: "UPDATE gateRequest SET status = 'withdrawn' WHERE id = ? AND status = 'pending'", arguments: [id])
                    }
                    throw WorkError.invalid(Self.unanswered)
                }
                usleep(20_000)
            default:
                throw WorkError.invalid(Self.unanswered)
            }
        }
    }

    /// Writes the request: the ref as JSON, the purpose, the agent, the turn, and the size and SHA-256 of the caller's bytes
    /// (never the bytes). Returns its id.
    func enqueue(companyId: String, agentId: String, ref: WorkRef, purpose: GatePurpose, expected: (size: Int, sha256: String)) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = String(decoding: try encoder.encode(ref), as: UTF8.self)
        let id = UUID().uuidString
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO gateRequest (id, companyId, agentId, turnId, purpose, ref, status, createdAt, expectedSize, expectedSha256)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)
                """, arguments: [id, companyId, agentId, turnId, purpose.rawValue, json, Store.now(), expected.size, expected.sha256])
        }
        return id
    }
}

extension Store {
    /// The gate at one read point, for `ref`'s `data` (the caller's read) named `canonical`. With a turn's
    /// `EngineGateArchives`, bytes that need a helper (an archive, a PDF, or anything whose scan reaches one) are gated by the
    /// engine instead, and its bytes are returned in place of `data`. Otherwise `gatedBytes` (when `strict`, or for a PDF
    /// with `paths`) or `SecretGate.check`.
    func gateRef(_ data: Data, ext: String, canonical: String, companyId: String, ref: WorkRef, reader: Reader, purpose: GatePurpose,
                 archives: any ArchiveReader, knownValues: [(name: String, value: String)],
                 paths: BrahmaPaths?) throws -> (data: Data, ext: String, verdict: ScanVerdict) {
        func local(_ archives: any ArchiveReader) throws -> (data: Data, ext: String, verdict: ScanVerdict) {
            if let paths, purpose.strict || SecretGate.isFlattenTarget(data, ext: ext) {
                let g = try gatedBytes(data, ext: ext, canonical: canonical, companyId: companyId, archives: archives,
                                       knownValues: knownValues, paths: paths)
                return (g.data, g.ext, g.verdict)
            }
            let v = try SecretGate.check(data, ext: ext, canonical: canonical, archives: archives, knownValues: knownValues, store: self,
                                         companyId: companyId)
            return (data, ext, v)
        }
        guard let engine = archives as? EngineGateArchives else { return try local(archives) }
        // A turn's agent, or (final wave B1 item 11) the concierge, whose requests the engine answers under its live run.
        let agentId: String
        switch reader {
        case .agent(let id): agentId = id
        case .concierge: agentId = ConciergeCaps.agentId
        default: throw WorkError.notFound(Self.refUnavailable)
        }
        let expected = (size: data.count, sha256: SHA256.hex(data))
        if Self.needsHelper(data, ext: ext) {
            let r = try engine.broker.gate(companyId: companyId, agentId: agentId, ref: ref, purpose: purpose, expected: expected)
            return (r.data, r.ext, r.verdict)
        }
        do { return try local(engine) } catch is NeedsEngineGate {
            let r = try engine.broker.gate(companyId: companyId, agentId: agentId, ref: ref, purpose: purpose, expected: expected)
            return (r.data, r.ext, r.verdict)
        }
    }

    /// Bytes whose gate needs a helper for sure: an archive (Office files included) or a PDF.
    static func needsHelper(_ data: Data, ext: String) -> Bool {
        ArchiveMemberScan.isArchive(data, ext: ext) || EmbeddedContent.isPDF(data, ext: ext)
    }

    /// The text `open_ref` shows for gated bytes of extension `ext`: text as it is, a binary as its metadata, anything else
    /// through `TextExtract` (an archive reader's refusal shown as its message).
    static func renderBody(_ data: Data, ext: String, archives: any ArchiveReader) throws -> String {
        let kind = ArtifactKind.from(ext: ext)
        let binary = data.prefix(OpenRefLimits.binarySniffBytes).contains(0)
        let textish = kind == nil || kind?.isText == true || ArtifactKind.isText(ext: ext)
        if !binary, textish { return String(decoding: data, as: UTF8.self) }
        if binary, textish { return TextExtract.metadata(kind: kind, bytes: data.count) }
        do { return try TextExtract.extract(kind: kind, ext: ext, data: data, archives: archives) } catch let e as ArchiveReadError {
            return e.message
        }
    }

    // MARK: Engine side

    /// The engine's side of Ruling 48 (its tick): answers every pending `gateRequest`, oldest first, at most `limit`. A request
    /// is answered only while its turn holds its live credential for that company and agent, and only for a ref that agent
    /// can read in full; the engine reads the bytes itself (`readContent`, as the tool's read point would), gates them with
    /// `archives(companyId)` (the sandboxed unzip reader and PDF helper) and the stored values `knownValues(companyId)`, and
    /// writes back only the verdict and the gated bytes (`.render`: the text to show). A refusal of the gate is written as
    /// its text; anything else as `unavailable` (the agent sees only the generic text), its detail in the owner's feed.
    /// Requests nobody collected within an hour are deleted. Returns how many were answered.
    @discardableResult
    public func serveGateRequests(archives: (String) -> any ArchiveReader, knownValues: (String) throws -> [(name: String, value: String)],
                                  paths: BrahmaPaths, now: Date, limit: Int = 20) throws -> Int {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM gateRequest WHERE createdAt < ?", arguments: [now.addingTimeInterval(-3600)])
        }
        let pending = try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM gateRequest WHERE status = 'pending' ORDER BY createdAt, rowid LIMIT ?", arguments: [limit])
        }
        var answered = 0
        for row in pending {
            let id: String = row["id"], companyId: String = row["companyId"], agentId: String = row["agentId"], turnId: String = row["turnId"]
            // Taken: a request withdrawn after this point is still answered, into a row its tool deletes.
            let taken = try writer.write { db -> Bool in
                try db.execute(sql: "UPDATE gateRequest SET status = 'working' WHERE id = ? AND status = 'pending'", arguments: [id])
                return db.changesCount > 0
            }
            guard taken else { continue }
            let outcome: (status: String, message: String?, result: Data?, ext: String?, verdict: String?)
            do {
                // Final wave B1 item 11: a concierge request (its agent is `ConciergeCaps.agentId`, its `turnId` the request's id)
                // is answered only while that request's `conciergeRun` is live in this company, like a turn's live credential.
                let live = agentId == ConciergeCaps.agentId
                    ? try conciergeRunIsLive(companyId: companyId, requestId: turnId)
                    : try turnCredentialIsLive(turnId: turnId, companyId: companyId, agentId: agentId)
                guard live else {
                    throw WorkError.invalid("this turn has ended; its tools no longer work")
                }
                guard let purpose = GatePurpose(rawValue: row["purpose"]),
                      let ref = try? JSONDecoder().decode(WorkRef.self, from: Data((row["ref"] as String).utf8)) else {
                    throw WorkError.notFound(Self.refUnavailable)
                }
                // Ruling 52: the request names the bytes its caller will use; none named is refused.
                guard let size: Int = row["expectedSize"], let sha: String = row["expectedSha256"] else {
                    throw WorkError.notFound(Self.refUnavailable)
                }
                let r = try engineGate(companyId: companyId, agentId: agentId, ref: ref, purpose: purpose, archives: archives(companyId),
                                       knownValues: try knownValues(companyId), paths: paths, expected: (size, sha))
                outcome = ("done", nil, r.data, r.ext, Self.encodeVerdict(r.verdict))
            } catch let e as WorkError {
                outcome = ("refused", e.message, nil, nil, nil)
            } catch {
                refTrace(companyId: companyId, "a gate request couldn't be answered (\(Store.flat("\(error)", max: 200)))", now: now)
                outcome = ("unavailable", nil, nil, nil, nil)
            }
            try writer.write { db in
                try db.execute(sql: """
                    UPDATE gateRequest SET status = ?, message = ?, result = ?, resultExt = ?, verdict = ?, finishedAt = ? WHERE id = ?
                    """, arguments: [outcome.status, outcome.message, outcome.result, outcome.ext, outcome.verdict, now, id])
            }
            answered += 1
        }
        return answered
    }

    /// One request: the ref resolved for the agent (anything but `.full` is the generic text), its bytes read as the tool's
    /// read point reads them, then gated (and for `.render`, extracted).
    func engineGate(companyId: String, agentId: String, ref: WorkRef, purpose: GatePurpose, archives: any ArchiveReader,
                    knownValues: [(name: String, value: String)], paths: BrahmaPaths,
                    expected: (size: Int, sha256: String)) throws -> EngineGateResult {
        // The concierge reads as `.concierge` (the owner's access minus secret values), every other requester as its agent.
        let reader: Reader = agentId == ConciergeCaps.agentId ? .concierge : .agent(agentId)
        let r = try resolveDetailed(ref, reader: reader, companyId: companyId, messageRefId: nil)
        guard r.resolved.visibility == .full, let subject = r.subject, let company = r.company, r.resolved.state != .purged else {
            throw WorkError.notFound(Self.refUnavailable)
        }
        let content: Content
        do {
            // Ruling 52: always the whole content (within the global caps), never a shown prefix or a metadata stand-in.
            content = try readContent(r, subject: subject, company: company, paths: paths, whole: true, knownValues: knownValues)
        } catch let e as WorkError {
            throw e
        } catch {
            throw WorkError.notFound(Self.refUnavailable)
        }
        let canonical: String
        switch purpose {
        case .snapshot: canonical = ref.id.split(separator: "/").last.map(String.init) ?? ref.id
        case .checkCommitted: canonical = Self.unpinned(ref).canonical
        default: canonical = ref.canonical
        }
        let data = content.data, ext = content.ext
        // Ruling 52: exactly the bytes the caller will act on, or nothing: a verdict is never given for other bytes.
        guard data.count == expected.size, SHA256.hex(data) == expected.sha256 else {
            throw WorkError.invalid("\(SecretGate.shown(ref.canonical, knownValues: knownValues)) changed while it was being checked for "
                                    + "secrets, or couldn't be read whole; open or share it again")
        }
        let gated: (data: Data, ext: String, verdict: ScanVerdict)
        if purpose.strict || SecretGate.isFlattenTarget(data, ext: ext) {
            let g = try gatedBytes(data, ext: ext, canonical: canonical, companyId: companyId, archives: archives, knownValues: knownValues,
                                   paths: paths)
            gated = (g.data, g.ext, g.verdict)
        } else {
            gated = (data, ext, try SecretGate.check(data, ext: ext, canonical: canonical, archives: archives, knownValues: knownValues,
                                                    store: self, companyId: companyId))
        }
        guard purpose == .render else { return EngineGateResult(data: gated.data, ext: gated.ext, verdict: gated.verdict) }
        let body: String
        if case .text(let text) = content.body, !gated.verdict.isClean || gated.data == data {
            body = text
        } else {
            body = try Self.renderBody(gated.data, ext: gated.ext, archives: archives)
        }
        return EngineGateResult(data: Data(body.utf8), ext: "", verdict: gated.verdict)
    }

    static func encodeVerdict(_ v: ScanVerdict) -> String {
        switch v {
        case .clean: "clean"
        case .pattern(let label, let line): "pattern\n\(line)\n\(label)"
        case .knownValue: "knownValue"
        }
    }

    /// Nil for anything but `clean` and a pattern (a stored value is never answered as a verdict: the gate refuses it).
    static func decodeVerdict(_ s: String?) -> ScanVerdict? {
        guard let s else { return nil }
        if s == "clean" { return .clean }
        let parts = s.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "pattern", let line = Int(parts[1]) else { return nil }
        return .pattern(label: parts[2], line: line)
    }
}

extension ScanVerdict {
    var isClean: Bool { self == .clean }
}

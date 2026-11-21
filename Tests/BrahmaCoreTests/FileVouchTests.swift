import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// A PDF reader whose helper found a structural anomaly but read everything it could (`UnverifiedPDF`): the parts it read.
struct UnverifiedPDFReader: ArchiveReader {
    var parts: [PDFPart]

    func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
        throw ArchiveReadError.unavailable
    }

    func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart] { throw UnverifiedPDF(parts: parts) }
}

/// C2b fix round 5 (controller Ruling 38, R5-3): the owner's path for a file the gate refuses for its STRUCTURE (a PDF whose
/// structure couldn't be verified, a format or archive method the engine can't scan). The owner vouches for that exact file
/// (`brahma vouch file <company> <path>`, owner-gated like `brahma vouch restore`, or the refusal alert's Inbox action);
/// the vouch is pinned to the bytes' SHA-256, the company and the ref's canonical name. A vouched file passes the structure
/// refusals only: every byte the gate can read is still scanned (a stored value or a secret pattern in it refuses as
/// before), taint is untouched, and any change to the bytes ends the vouch. The refusal names the exact command.
@Suite(.scratch) struct FileVouchTests {
    static let known = SecretGateTests.known
    static let value = SecretGateTests.value

    /// The suffix every structure refusal ends with: the exact command for `canonical` in `company`.
    static func command(_ company: Company, _ canonical: String) -> String {
        " — the owner can vouch for this exact file: brahma vouch file \(company.slug) \(canonical)"
    }

    /// `error` without the vouch command for `canonical` in `company` when it ends with exactly that command (the tests of
    /// the refusals themselves compare the rest).
    static func withoutCommand(_ error: WorkError, _ company: Company, _ canonical: String) -> WorkError {
        let suffix = command(company, canonical)
        guard case .invalid(let message) = error, message.hasSuffix(suffix) else { return error }
        return .invalid(String(message.dropLast(suffix.count)))
    }

    func check(_ cf: CollabFixture, _ data: Data, ext: String = "pdf", canonical: String = "doc.pdf", companyId: String? = nil,
               archives: any ArchiveReader) throws -> ScanVerdict {
        try SecretGate.check(data, ext: ext, canonical: canonical, archives: archives, knownValues: Self.known, store: cf.store,
                             companyId: companyId ?? cf.c.id)
    }

    func outcome(_ body: () throws -> ScanVerdict) -> String {
        do { return "\(try body())" } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    func vouchRows(_ cf: CollabFixture, _ companyId: String) throws -> [Row] {
        try cf.store.writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM fileVouch WHERE companyId = ?", arguments: [companyId]) }
    }

    /// A PDF with one structural anomaly (object 5 rewritten by an update) and, when given, object 6 holding `hidden` under
    /// FlateDecode (seen only decoded).
    static func anomalous(hidden: String? = nil) -> Data {
        typealias B = RevisionBuild
        let base = B.build(B.base(B.stream(4, PDFBuild.zlib(PDFBuild.text("hello")))))
        var objects = [B.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>")]
        var entries: [(Int, Int, ([Int]) -> Int)] = [(5, 0, { $0[0] })]
        if let hidden {
            objects.append(B.stream(6, PDFBuild.zlib(Data(hidden.utf8))))
            entries.append((6, 0, { $0[1] }))
        }
        return B.update(base, objects: objects, entries: entries, size: 7).data
    }

    /// The refusal names the exact command; the gate records the refused bytes and alerts the owner (once while open); the
    /// owner's vouch (pinned to the bytes) lets the same bytes past the structure check with the real helper, and every
    /// part it read is still scanned: a stored value or a secret pattern seen only decoded still refuses. A changed byte
    /// is refused again; company B's same bytes are not vouched; the vouch touches no taint.
    @Test func vouchedFileSkipsOnlyTheStructureRefusal() throws {
        guard EmbeddedContentTests.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try EmbeddedContentTests.reader(cf)
        let file = Self.anomalous()
        let refused = outcome { try check(cf, file, archives: reader) }
        #expect(refused == "this PDF's structure couldn't be verified" + Self.command(cf.c, "doc.pdf"), "\(refused)")
        let rows = try vouchRows(cf, cf.c.id)
        #expect(rows.count == 1 && (rows.first?["sha256"] as String?) == SHA256.hex(file) && (rows.first?["vouchedAt"] as Date?) == nil)
        let cId = cf.c.id
        let alerts = { try cf.store.writer.read { db in
            try Ask.fetchAll(db, sql: "SELECT * FROM ask WHERE companyId = ? AND kind = 'engineAlert' AND status = 'pendingOwner'", arguments: [cId])
        } }
        #expect(try alerts().filter { Store.isFileVouchAlert($0) }.count == 1)
        // A second refusal of the same bytes raises no second alert.
        _ = outcome { try check(cf, file, archives: reader) }
        #expect(try alerts().filter { Store.isFileVouchAlert($0) }.count == 1)
        let taintBefore = try dumpTaint(cf)

        let vouch = try cf.store.vouchFile(companyId: cId, canonical: "doc.pdf", now: cf.now)
        #expect(vouch.sha256 == SHA256.hex(file))
        #expect(outcome { try check(cf, file, archives: reader) } == "clean")
        #expect(try alerts().filter { Store.isFileVouchAlert($0) }.isEmpty, "the refusal alert is still open after the vouch")
        let lines = try cf.store.events(afterId: 0, companyId: cId).map(\.text)
        #expect(lines.contains { $0.contains("Owner vouched for doc.pdf") }, "\(lines)")
        #expect(try dumpTaint(cf) == taintBefore, "the vouch changed taint")

        // Any byte changed: no longer vouched.
        let changed = file + Data("% one more byte\n".utf8)
        #expect(outcome { try check(cf, changed, archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
        // Another canonical name, or the same name and bytes in company B: not vouched.
        #expect(outcome { try check(cf, file, canonical: "other.pdf", archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
        let other = outcome { try check(cf, file, companyId: cf.fx.d.id, archives: reader) }
        #expect(other == "this PDF's structure couldn't be verified" + Self.command(cf.fx.d, "doc.pdf"), "\(other)")

        // What the gate can read is still scanned: a stored value, and a secret pattern, seen only decoded.
        for (name, hidden) in [("value.pdf", "key \(Self.value)"), ("pattern.pdf", "key \(SecretGateTests.aws)")] {
            let pdf = Self.anomalous(hidden: hidden)
            #expect(!String(decoding: pdf, as: UTF8.self).contains(hidden))
            #expect(outcome { try check(cf, pdf, canonical: name, archives: reader) }.hasPrefix("this PDF's structure couldn't be verified"))
            _ = try cf.store.vouchFile(companyId: cId, canonical: name, now: cf.now)
            let after = outcome { try check(cf, pdf, canonical: name, archives: reader) }
            #expect(after.contains("contains a stored secret") || after.contains("looks like it contains a secret"), "\(name): \(after)")
        }
    }

    /// The same rule without the helper: the parts an unverified read returns are scanned once the file is vouched (and
    /// refused before); bytes compressed in a format the engine can't open (gzip) pass once vouched, their own bytes still
    /// scanned; an archive with a member it can't decode (encrypted) passes once vouched, the members it can read scanned.
    @Test func vouchCoversFormatsAndArchives() throws {
        let cf = try CollabFixture()
        let cId = cf.c.id
        let clean = UnverifiedPDFReader(parts: [PDFPart(kind: .decodedStream, data: Data("hello".utf8))])
        let pdf = Data("%PDF-1.7 a file the helper flagged".utf8)
        #expect(outcome { try check(cf, pdf, archives: clean) } == "this PDF's structure couldn't be verified" + Self.command(cf.c, "doc.pdf"))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "doc.pdf", now: cf.now)
        #expect(outcome { try check(cf, pdf, archives: clean) } == "clean")
        // (Other bytes: verdicts are cached by the bytes, and a real reader reads the same bytes the same way.)
        let held = Data("%PDF-1.7 another flagged file".utf8)
        let holding = UnverifiedPDFReader(parts: [PDFPart(kind: .decodedStream, data: Data("key \(Self.value)".utf8))])
        #expect(outcome { try check(cf, held, canonical: "held.pdf", archives: holding) }.hasPrefix("this PDF's structure couldn't be verified"))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "held.pdf", now: cf.now)
        #expect(outcome { try check(cf, held, canonical: "held.pdf", archives: holding) }.contains("contains a stored secret"))

        let gz = Data([0x1F, 0x8B, 0x08, 0x00]) + Data("compressed bytes".utf8)
        let gzRefusal = "logs.gz is compressed as gzip, which can't be scanned for secrets; share the files inside instead"
        #expect(outcome { try check(cf, gz, ext: "gz", canonical: "logs.gz", archives: UnavailableArchiveReader()) }
                == gzRefusal + Self.command(cf.c, "logs.gz"))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "logs.gz", now: cf.now)
        #expect(outcome { try check(cf, gz, ext: "gz", canonical: "logs.gz", archives: UnavailableArchiveReader()) } == "clean")
        let gzKey = Data([0x1F, 0x8B, 0x08, 0x00]) + Data(" key \(SecretGateTests.aws) ".utf8)
        #expect(outcome { try check(cf, gzKey, ext: "gz", canonical: "key.gz", archives: UnavailableArchiveReader()) }.hasPrefix("key.gz is compressed as gzip"))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "key.gz", now: cf.now)
        #expect(outcome { try check(cf, gzKey, ext: "gz", canonical: "key.gz", archives: UnavailableArchiveReader()) }.hasPrefix("pattern"))

        // The stored member's bytes are a stand-in of the same length; the reader hands back what it would inflate.
        let zip = try SecretGateTests.zip {
            $0.add("secret.bin", "cipher text", flags: 1)
            $0.add("readme.txt", "key " + String(repeating: "x", count: Self.value.count))
        }
        let members = StubArchiveReader(members: [("readme.txt", Data("key \(Self.value)".utf8))])
        let method = "this archive uses compression or encryption that can't be scanned for secrets"
        #expect(outcome { try check(cf, zip, ext: "zip", canonical: "bundle.zip", archives: members) } == method + Self.command(cf.c, "bundle.zip"))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "bundle.zip", now: cf.now)
        #expect(outcome { try check(cf, zip, ext: "zip", canonical: "bundle.zip", archives: members) }.contains("contains a stored secret"))
        let cleanZip = try SecretGateTests.zip {
            $0.add("secret.bin", "cipher text", flags: 1)
            $0.add("readme.txt", "hello")
        }
        let cleanMembers = StubArchiveReader(members: [("readme.txt", Data("hello".utf8))])
        #expect(outcome { try check(cf, cleanZip, ext: "zip", canonical: "clean.zip", archives: cleanMembers) }.hasPrefix(method))
        _ = try cf.store.vouchFile(companyId: cId, canonical: "clean.zip", now: cf.now)
        #expect(outcome { try check(cf, cleanZip, ext: "zip", canonical: "clean.zip", archives: cleanMembers) } == "clean")

        // One name refused as two versions: the vouch says which (by sha256), or refuses to guess.
        let v1 = Data("%PDF-1.7 version one".utf8), v2 = Data("%PDF-1.7 version two".utf8)
        for v in [v1, v2] { _ = outcome { try check(cf, v, canonical: "multi.pdf", archives: clean) } }
        #expect(throws: WorkError.self) { try cf.store.vouchFile(companyId: cId, canonical: "multi.pdf", now: cf.now) }
        #expect(throws: WorkError.self) { try cf.store.vouchFile(companyId: cId, canonical: "multi.pdf", sha256: "abc", now: cf.now) }
        let picked = try cf.store.vouchFile(companyId: cId, canonical: "multi.pdf", sha256: String(SHA256.hex(v2).prefix(12)), now: cf.now)
        #expect(picked.sha256 == SHA256.hex(v2))
        #expect(outcome { try check(cf, v2, canonical: "multi.pdf", archives: clean) } == "clean")
        #expect(outcome { try check(cf, v1, canonical: "multi.pdf", archives: clean) }.hasPrefix("this PDF's structure couldn't be verified"))

        // Nothing refused under that name: nothing to vouch for. A refusal that isn't about structure records nothing.
        #expect(throws: WorkError.self) { try cf.store.vouchFile(companyId: cId, canonical: "never.pdf", now: cf.now) }
        let unread = Data("%PDF-1.7 a file no helper read".utf8)
        #expect(outcome { try check(cf, unread, canonical: "no-helper.pdf", archives: UnavailableArchiveReader()) } == "PDFs can't be scanned on this machine")
        #expect(throws: WorkError.self) { try cf.store.vouchFile(companyId: cId, canonical: "no-helper.pdf", now: cf.now) }
        // A name that holds a stored value is never echoed: not in the refusal, the alert, or the record.
        let named = "src/\(Self.value).pdf"
        let message = outcome { try check(cf, pdf, canonical: named, archives: clean) }
        #expect(message.hasPrefix("this PDF's structure couldn't be verified"))
        let dump = try dumpDatabase(cf.store)
        for piece in SecretGateTests.pieces(Self.value) {
            #expect(!message.contains(piece))
            #expect(!dump.contains(piece), "the database holds a piece of the value")
        }
    }

    func dumpTaint(_ cf: CollabFixture) throws -> String {
        try cf.store.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM taintedCommit") + (try Row.fetchAll(db, sql: "SELECT id, tainted FROM resource"))
            return rows.map(\.description).joined(separator: "\n")
        }
    }

    /// `brahma vouch file <company> <path>` is the owner's: refused without the owner key and from an agent's shell
    /// (`BRAHMA_AGENT_ID`), changing nothing; as the owner it vouches for the refused bytes (an owner activity line, the
    /// alert closed) and the gate then passes them. No agent tool reaches it.
    @Test func cliVouchFileOwnerOnly() throws {
        func home(initOwner: Bool) throws -> (home: OwnerTestHome, company: Company, pdf: Data) {
            let home = try OwnerTestHome(initOwner: initOwner)
            let paths = ownerPaths(home.url)
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            defer { try? store.close() }
            let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            let pdf = Data("%PDF-1.7 flagged".utf8)
            #expect(throws: WorkError.self) {
                try SecretGate.check(pdf, ext: "pdf", canonical: "docs/spec.pdf", archives: UnverifiedPDFReader(parts: []), knownValues: [],
                                     store: store, companyId: company.id)
            }
            return (home, company, pdf)
        }
        func vouched(_ h: (home: OwnerTestHome, company: Company, pdf: Data)) throws -> (vouched: Bool, passes: Bool, lines: [String]) {
            let paths = ownerPaths(h.home.url)
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            defer { try? store.close() }
            let at = try store.writer.read { db in
                try Date.fetchOne(db, sql: "SELECT vouchedAt FROM fileVouch WHERE companyId = ?", arguments: [h.company.id])
            }
            let passes = (try? SecretGate.check(h.pdf, ext: "pdf", canonical: "docs/spec.pdf", archives: UnverifiedPDFReader(parts: []),
                                                knownValues: [], store: store, companyId: h.company.id)) == .clean
            return (at != nil, passes, try store.events(afterId: 0, companyId: h.company.id).map(\.text))
        }
        let noKey = try home(initOwner: false)
        let refusedNoKey = try runBrahma(["vouch", "file", "acme", "docs/spec.pdf"], home: noKey.home.url)
        #expect(refusedNoKey.status != 0 && refusedNoKey.stderr.contains("owner key missing"), "\(refusedNoKey.stderr)")
        #expect(try vouched(noKey).vouched == false)

        let h = try home(initOwner: true)
        let agent = try runBrahma(["vouch", "file", "acme", "docs/spec.pdf"], home: h.home.url, extra: ["BRAHMA_AGENT_ID": "agent-1"])
        #expect(agent.status != 0 && agent.stderr.contains("owner commands can't run inside an agent turn"), "\(agent.stderr)")
        let afterAgent = try vouched(h)
        #expect(!afterAgent.vouched && !afterAgent.passes)
        #expect(try runBrahma(["vouch", "file", "nosuch", "docs/spec.pdf"], home: h.home.url).status != 0)
        let unknown = try runBrahma(["vouch", "file", "acme", "docs/other.pdf"], home: h.home.url)
        #expect(unknown.status != 0, "\(unknown.stdout)")

        let owner = try runBrahma(["vouch", "file", "acme", "docs/spec.pdf"], home: h.home.url)
        #expect(owner.status == 0, "\(owner.stderr)")
        #expect(owner.stdout.contains("docs/spec.pdf") && owner.stdout.contains(String(SHA256.hex(h.pdf).prefix(12))), "\(owner.stdout)")
        let after = try vouched(h)
        #expect(after.vouched && after.passes)
        #expect(after.lines.contains { $0.contains("Owner vouched for docs/spec.pdf") }, "\(after.lines)")
    }

    /// No agent tool reaches the file vouch: no company tool is named for it, and no tool source calls it or writes it.
    @Test func noAgentToolReachesTheFileVouch() throws {
        #expect(!CompanyToolNames.all.contains { $0.contains("vouch") })
        var reaches: [String] = []
        for (path, text) in try EngineGitGuardTests.sources(under: "Sources/BrahmaCore/MCP") {
            let code = EngineGitGuardTests.code(text)
            if code.range(of: #"\bvouchFile\b|fileVouch"#, options: .regularExpression) != nil { reaches.append(path) }
        }
        #expect(reaches.isEmpty, "a tool path reaches the file vouch: \(reaches)")
    }
}

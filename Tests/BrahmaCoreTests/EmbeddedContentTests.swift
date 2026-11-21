import Testing
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(Compression)
import Compression
#endif
@testable import BrahmaCore

/// Builds real PDFs for the gate's tests: objects numbered from 1 with a classic cross-reference table whose offsets are
/// right, so every reader opens them without a repair.
enum PDFBuild {
    /// A PDF of `objects` (object i + 1 is `objects[i]`). `prefix` comes before the header (and counts in the offsets);
    /// `junk` is written as is just before object `junk.before` (its bytes belong to no object).
    static func build(_ objects: [Data], version: String = "1.7", trailer: String = "", prefix: Data = Data(),
                      junk: (before: Int, data: Data)? = nil) -> Data {
        var out = prefix + Data("%PDF-\(version)\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            if let junk, junk.before == i + 1 { out += junk.data }
            offsets.append(out.count)
            out += Data("\(i + 1) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += pad10(o) + " 00000 n \n" }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R\(trailer) >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Data(table.utf8)
    }

    static func pad10(_ n: Int) -> String { String(repeating: "0", count: max(0, 10 - String(n).count)) + String(n) }

    /// Catalog (1), pages (2), one page (3) drawing `content` (4) in Helvetica (5), then `extra` (6, 7, …).
    static func page(_ content: Data, extra: [Data] = []) -> [Data] {
        [Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
         Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
         Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>".utf8),
         content,
         Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)] + extra
    }

    /// A stream object: `dict`, the `stream` keyword followed by `eol`, `data`, `endstream`.
    static func stream(_ dict: String, _ data: Data, eol: String = "\n") -> Data {
        Data("\(dict)\nstream\(eol)".utf8) + data + Data("\nendstream".utf8)
    }

    static func text(_ s: String) -> Data { Data("BT /F1 12 Tf 72 700 Td (\(s)) Tj ET".utf8) }

    /// `data` with every `old` replaced by `new`, byte for byte (the PDFs hold binary data a String round trip would mangle).
    static func replacing(_ data: Data, _ old: String, _ new: String) -> Data {
        let o = Data(old.utf8), n = Data(new.utf8)
        var out = Data(), rest = data[...]
        while let r = rest.range(of: o) {
            out += rest[rest.startIndex..<r.lowerBound] + n
            rest = rest[r.upperBound...]
        }
        return out + rest
    }

    static func zlib(_ data: Data) -> Data { (try? SecretGateTests.zlib(data)) ?? Data() }

    /// A one-page PDF whose content is `text` under FlateDecode.
    static func flate(_ s: String) -> Data {
        let z = zlib(text(s))
        return build(page(stream("<< /Length \(z.count) /Filter /FlateDecode >>", z)))
    }

    /// A PDF 1.5 file whose objects live in a compressed object stream (6) with a cross-reference stream (7), as pdfTeX and
    /// most current writers make them. `hidden`, when given, is one more object (8) in the object stream that nothing uses.
    static func objectStreams(hidden: String? = nil) -> Data {
        let content = zlib(text("hello"))
        var inner: [(Int, String)] = [
            (1, "<< /Type /Catalog /Pages 2 0 R >>"), (2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            (3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>"),
            (5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ]
        if let hidden { inner.append((8, hidden)) }
        var header = "", body = ""
        for (n, o) in inner { header += "\(n) \(body.utf8.count) "; body += o + "\n" }
        let packed = zlib(Data((header + body).utf8))
        var out = Data("%PDF-1.5\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int: Int] = [:]
        offsets[4] = out.count
        out += Data("4 0 obj\n".utf8) + stream("<< /Length \(content.count) /Filter /FlateDecode >>", content) + Data("\nendobj\n".utf8)
        offsets[6] = out.count
        out += Data("6 0 obj\n".utf8)
            + stream("<< /Type /ObjStm /N \(inner.count) /First \(header.utf8.count) /Length \(packed.count) /Filter /FlateDecode >>", packed)
            + Data("\nendobj\n".utf8)
        let xref = out.count
        var rows = Data()
        func be(_ v: Int, _ n: Int) { for k in (0..<n).reversed() { rows.append(UInt8((v >> (8 * k)) & 0xFF)) } }
        let size = 9
        for n in 0..<size {
            if n == 7 { rows.append(1); be(xref, 4); be(0, 2) }
            else if let o = offsets[n] { rows.append(1); be(o, 4); be(0, 2) }
            else if let index = inner.firstIndex(where: { $0.0 == n }) { rows.append(2); be(6, 4); be(index, 2) }
            else { rows.append(0); be(0, 4); be(0, 2) }
        }
        let packedRows = zlib(rows)
        out += Data("7 0 obj\n".utf8)
            + stream("<< /Type /XRef /Size \(size) /W [1 4 2] /Root 1 0 R /Length \(packedRows.count) /Filter /FlateDecode >>", packedRows)
            + Data("\nendobj\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return out
    }

    /// The offset the last `startxref` of `pdf` names.
    static func lastStartxref(_ pdf: Data) -> Int {
        String(decoding: pdf.suffix(64), as: UTF8.self).components(separatedBy: "startxref\n").last?
            .split(separator: "\n").first.flatMap { Int($0) } ?? 0
    }

    /// `base` plus an incremental update holding `objects` (number, body), whose cross-reference section also maps each
    /// `aliases` number to the offset of the object `aliases[n]` (two numbers, one object).
    static func update(_ base: Data, objects: [(Int, Data)], aliases: [Int: Int] = [:]) -> Data {
        var out = base
        var offsets: [Int: Int] = [:]
        for (n, body) in objects {
            offsets[n] = out.count
            out += Data("\(n) 0 obj\n".utf8) + body + Data("\nendobj\n".utf8)
        }
        for (n, target) in aliases { offsets[n] = offsets[target] }
        let xref = out.count
        var table = "xref\n0 1\n0000000000 65535 f \n"
        for n in offsets.keys.sorted() { table += "\(n) 1\n\(pad10(offsets[n] ?? 0)) 00000 n \n" }
        let size = max(objects.map(\.0).max() ?? 0, aliases.keys.max() ?? 0) + 1
        table += "trailer\n<< /Size \(size) /Root 1 0 R /Prev \(lastStartxref(base)) >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Data(table.utf8)
    }

    /// zlib (RFC 1950) bytes of `count` zero bytes, compressed in 1 MiB steps: a decompression bomb, never held whole.
    static func zeroBomb(_ count: Int) -> Data {
        #if canImport(Compression)
        let step = 1 << 20
        let zeros = [UInt8](repeating: 0, count: step)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: step)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: UnsafePointer(dst), src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return Data() }
        defer { compression_stream_destroy(&stream) }
        var out = Data([0x78, 0x9C])
        var left = count
        zeros.withUnsafeBufferPointer { src in
            while true {
                let n = min(left, step)
                left -= n
                let flags = left == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                stream.src_ptr = src.baseAddress!
                stream.src_size = n
                var status = COMPRESSION_STATUS_OK
                repeat {
                    stream.dst_ptr = dst
                    stream.dst_size = step
                    status = compression_stream_process(&stream, flags)
                    out.append(dst, count: step - stream.dst_size)
                } while status == COMPRESSION_STATUS_OK && (stream.src_size > 0 || (flags != 0 && stream.dst_size == 0))
                if left == 0 || status != COMPRESSION_STATUS_OK { break }
            }
        }
        let a: UInt32 = 1, b = UInt32(count % 65521)
        let adler = b << 16 | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return out
        #else
        return Data()
        #endif
    }

    /// A one-page PDF whose content stream inflates to 768 MiB of zeros (about 0.8 MB on disk).
    static let memoryBomb: Data = {
        let z = zeroBomb(768 << 20)
        return build(page(stream("<< /Length \(z.count) /Filter /FlateDecode >>", z)))
    }()

    /// `pdf` saved by PDFKit with an owner password and `user` as the user password (empty: anyone opens it).
    static func encrypted(_ pdf: Data, user: String) -> Data? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(data: pdf), let url = try? tempDir().appending(path: "enc.pdf") else { return nil }
        guard doc.write(to: url, withOptions: [.ownerPasswordOption: "owner-pw", .userPasswordOption: user]) else { return nil }
        return try? Data(contentsOf: url)
        #else
        return nil
        #endif
    }
}

/// A sandboxed runner stand-in for the PDF reader (round 4: the helper runs as a program, never a shell command): writes
/// `parts` as the helper's standard output and reports `outcome` (whose exit code is the helper's own).
struct ScriptedRunner: SandboxedRunner {
    /// What the reader asked for.
    final class Record: @unchecked Sendable {
        let lock = NSLock()
        var arguments: [String] = []
        var stdoutCap = 0
        var commands = 0
    }

    var parts: Data?
    var outcome: CheckOutcome
    var record: Record? = nil

    func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
             policy: SandboxPolicy) async -> CheckOutcome {
        record?.lock.withLock { record?.commands += 1 }
        return GroupRun.fail("a shell command was run", outputURL: outputURL)
    }

    func runProgramBlocking(arguments: [String], cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                            stdoutURL: URL, stdoutCap: Int, policy: SandboxPolicy) -> CheckOutcome {
        record?.lock.withLock { record?.arguments = arguments; record?.stdoutCap = stdoutCap }
        if let parts { try? parts.write(to: stdoutURL) }
        return outcome
    }

    func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        throw SandboxError.unavailable
    }
}

/// SplitMix64: the fuzz tests' inputs are the same on every run.
struct SeededBytes {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func bytes(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8(truncatingIfNeeded: next()) }) }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
}

/// C2b fix round 2 (controller ruling 33, R2-1, R2-4, R2-5 and the open R1-9 repro cases): no PDF is parsed in the engine.
/// The sandboxed `brahma-pdf` helper (PDFKit and CoreGraphics, under Seatbelt like the unzip reader) hands back every
/// stream decoded, every string, name and page text; the engine scans that under the one shared budget and recurses into
/// every decoded stream. A PNG's text chunks are walked strictly in the engine; every in-engine decoder refuses bad input
/// and never traps.
@Suite(.scratch) struct EmbeddedContentTests {
    static let value = SecretGateTests.value
    static let known = SecretGateTests.known
    static let aws = SecretGateTests.aws

    static func refusal(_ canonical: String) -> WorkError { SecretGateTests.refusal(canonical, line: nil) }

    static let encrypted = WorkError.invalid("this PDF is encrypted, so it can't be scanned for secrets")
    static let undecodable = WorkError.invalid("this PDF has a stream that can't be decoded for scanning")
    /// Round 4 (R4-6, ruling 35): every structural anomaly the helper finds is this one refusal (round 5, ruling 38: the
    /// gate ends it with the owner's vouch command, which `check` verifies and takes off).
    static let unaccounted = WorkError.invalid("this PDF's structure couldn't be verified")
    static let unreadable = WorkError.invalid("this PDF can't be read, so it can't be scanned for secrets")
    static let unavailable = WorkError.invalid("PDFs can't be scanned on this machine")
    static let badPNG = WorkError.invalid("this PNG has a chunk that can't be checked for secrets")

    /// The helper SwiftPM built next to the test bundle.
    static var helper: URL {
        Bundle.module.bundleURL.deletingLastPathComponent().appending(path: SandboxedPDFReader.helperName).resolvedForSandbox
    }

    static var helperReady: Bool { Toolchain.seatbeltAvailable && FileManager.default.isExecutableFile(atPath: helper.path) }

    /// The real reader: Seatbelt, a data home under the owner's home (as the engine's is), unzip and the PDF helper.
    static func reader(_ cf: CollabFixture, helper: URL? = EmbeddedContentTests.helper) throws -> SandboxedUnzipReader {
        let home = try Scratch.homeDir().resolvedForSandbox
        let sbPaths = BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
        let sbVault = Vault(paths: sbPaths, companyId: cf.c.id, content: ContentVault(paths: sbPaths))
        return SandboxedUnzipReader(runner: SeatbeltRunner(baseline: {
            SandboxBaseline.current(paths: sbPaths, otherWorkspaces: [], backupTargets: [])
        }, proxies: EgressProxyPool()), scratch: { try sbVault.makeTempDir() }, pdfHelper: helper)
    }

    /// The gate's verdict; a structure refusal without the owner's vouch command when it names exactly the command for
    /// `canonical` in the fixture's company (round 5, ruling 38: `FileVouchTests` checks the command itself).
    func check(_ cf: CollabFixture, _ data: Data, ext: String = "pdf", canonical: String = "doc.pdf",
               archives: any ArchiveReader, known: [(name: String, value: String)] = EmbeddedContentTests.known) throws -> ScanVerdict {
        do {
            return try SecretGate.check(data, ext: ext, canonical: canonical, archives: archives, knownValues: known, store: cf.store,
                                        companyId: cf.c.id)
        } catch let e as WorkError { throw FileVouchTests.withoutCommand(e, cf.c, canonical) }
    }

    /// The helper is built with the package (SwiftPM builds every executable product for `swift test`).
    @Test func helperIsBuilt() {
        #if os(macOS)
        #expect(FileManager.default.isExecutableFile(atPath: Self.helper.path), "\(Self.helper.path)")
        #endif
    }

    /// Where the engine finds the helper: beside its own binary (the CLI, `swift build`'s products), or in the app bundle's
    /// `Contents/Helpers` next to `Contents/MacOS`.
    @Test func helperLocated() {
        let cli = URL(fileURLWithPath: "/p/.build/debug/brahma")
        #expect(SandboxedPDFReader.locate(executable: cli, isExecutable: { $0 == "/p/.build/debug/brahma-pdf" })?.path == "/p/.build/debug/brahma-pdf")
        let app = URL(fileURLWithPath: "/A/Brahma.app/Contents/MacOS/Brahma")
        #expect(SandboxedPDFReader.locate(executable: app, isExecutable: { $0 == "/A/Brahma.app/Contents/Helpers/brahma-pdf" })?.path
            == "/A/Brahma.app/Contents/Helpers/brahma-pdf")
        #expect(SandboxedPDFReader.locate(executable: cli, isExecutable: { _ in false }) == nil)
    }

    /// The re-review's repro cases (B, C, D, G, E, F, H, I) and the plain ones: every one read clean through the old
    /// in-engine parser while PDFKit showed the value. Each is now refused.
    @Test(arguments: ["A-flate", "B-space-before-eol", "C-comment-before-stream", "D-obj-in-dictionary", "G-dictionary-over-4k",
                      "E-escaped-filter-name", "F-decoy-predictor", "H-octal-escape", "I-header-at-1100", "split-TJ-hex-over-flate",
                      "hex-info-string", "png-up-predictor", "orphan-object", "generation-1-object", "object-stream-orphan"])
    func pdfReproCasesCaught(_ name: String) throws {
        guard Self.helperReady else { return }
        let cf = try CollabFixture()
        let content = PDFBuild.text("key \(Self.value)")
        let z = PDFBuild.zlib(content)
        let plain = PDFBuild.zlib(PDFBuild.text("hello"))
        var ext = "pdf", canonical = "\(name).pdf"
        let pdf: Data
        switch name {
        case "A-flate": pdf = PDFBuild.flate("key \(Self.value)")
        case "B-space-before-eol":
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(z.count) /Filter /FlateDecode >>", z, eol: " \n")))
        case "C-comment-before-stream":
            pdf = PDFBuild.build(PDFBuild.page(Data("<< /Length \(z.count) /Filter /FlateDecode >> %c\nstream\n".utf8) + z + Data("\nendstream".utf8)))
        case "D-obj-in-dictionary":
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Filter /FlateDecode /Z (obj) /Length \(z.count) >>", z)))
        case "G-dictionary-over-4k":
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Filter /FlateDecode /Z (\(String(repeating: "x", count: 5000))) /Length \(z.count) >>", z)))
        case "E-escaped-filter-name":
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(z.count) /Fil#74er /FlateDecode >>", z)))
        case "F-decoy-predictor":
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Z (/Predictor 2 /Colors 1 /Columns 4) /Length \(z.count) /Filter /FlateDecode >>", z)))
        case "H-octal-escape":
            let octal = Data("BT /F1 12 Tf 72 700 Td (key \\163k_test_51abcdefgh) Tj ET".utf8)
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(octal.count) >>", octal)))
        case "I-header-at-1100":
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(z.count) /Filter /FlateDecode >>", z)),
                                 prefix: Data((String(repeating: "x", count: 1100) + "\n").utf8))
            ext = "txt"; canonical = "notes.txt"
        case "split-TJ-hex-over-flate":
            let split = PDFBuild.zlib(Data("BT /F1 12 Tf 72 700 Td [(sk_test_) -20 (51abcdefgh)] TJ ET".utf8))
            let hex = Data(split.map { String(format: "%02X", $0) }.joined().utf8) + Data(">".utf8)
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(hex.count) /Filter [/ASCIIHexDecode /FlateDecode] >>", hex)))
        case "hex-info-string":
            // A hex string of a secret PATTERN (the raw scan knows the hex forms of stored values, not of patterns): the
            // helper's decoded strings catch it.
            let awsHex = Data(Self.aws.utf8).map { String(format: "%02x", $0) }.joined()
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(plain.count) /Filter /FlateDecode >>", plain),
                                               extra: [Data("<< /Title <\(awsHex)> >>".utf8)]), trailer: " /Info 6 0 R")
            #expect(!String(decoding: pdf, as: UTF8.self).contains(Self.aws))
            #expect(throws: WorkError.self) { try check(cf, pdf, canonical: canonical, archives: try Self.reader(cf)) }
            return
        case "png-up-predictor":
            let rows = Array("key sk_test_".utf8), rows2 = Array("51abcdefgh  ".utf8)
            var predicted: [UInt8] = [2] + rows + [2]
            for (i, c) in rows2.enumerated() { predicted.append(c &- rows[i]) }
            let up = PDFBuild.zlib(Data(predicted))
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(up.count) /Filter /FlateDecode /DecodeParms << /Predictor 12 /Columns 12 >> >>", up)))
        case "orphan-object":
            // An object nothing uses: no viewer shows it, any PDF tool decodes it.
            pdf = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(plain.count) /Filter /FlateDecode >>", plain),
                                               extra: [PDFBuild.stream("<< /Length \(z.count) /Filter /FlateDecode >>", z)]))
        case "generation-1-object":
            let built = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(plain.count) /Filter /FlateDecode >>", plain),
                                                     extra: [PDFBuild.stream("<< /Length \(z.count) /Filter /FlateDecode >>", z)]))
            pdf = PDFBuild.replacing(PDFBuild.replacing(built, "6 0 obj", "6 1 obj"), "00000 n \ntrailer", "00001 n \ntrailer")
        case "object-stream-orphan":
            pdf = PDFBuild.objectStreams(hidden: "<< /Note (\\163k_test_51abcdefgh) >>")
        default:
            Issue.record("unknown case \(name)"); return
        }
        #expect(!String(decoding: pdf, as: UTF8.self).contains(Self.value), "\(name): the raw bytes must not hold the value")
        // Through the reader the gate refuses it. Round 4: a file whose header is not at byte 0 is one CoreGraphics rebuilds
        // by scanning (its cross-reference unused), so no stream body can be placed by its offset: refused as unaccounted.
        let expected = name == "I-header-at-1100" ? Self.unaccounted : Self.refusal(canonical)
        #expect(throws: expected, "\(name)") { try check(cf, pdf, ext: ext, canonical: canonical, archives: try Self.reader(cf)) }
        // Without the helper it is refused too, never passed.
        #expect(throws: WorkError.self, "\(name) without a helper") { try check(cf, pdf, ext: ext, canonical: canonical, archives: UnavailableArchiveReader()) }
    }

    /// K' and encryption: an encrypted PDF (whatever its `/Encrypt` key is spelled as) is refused.
    @Test func encryptedPDFRefused() throws {
        guard Self.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try Self.reader(cf)
        let source = PDFBuild.flate("key \(Self.value)")
        for user in ["", "user-pw"] {
            let locked = try #require(PDFBuild.encrypted(source, user: user))
            #expect(throws: Self.encrypted, "user password '\(user)'") { try check(cf, locked, canonical: "locked.pdf", archives: reader) }
            if user.isEmpty {
                // K': the key's name escaped (`/Encr#79pt`), so no text search finds it.
                let escaped = PDFBuild.replacing(locked, "/Encrypt", "/Encr#79pt")
                #expect(escaped.range(of: Data("/Encrypt".utf8)) == nil)
                #expect(throws: WorkError.self) { try check(cf, escaped, canonical: "escaped.pdf", archives: reader) }
            }
        }
    }

    /// Fail closed: a stray stream, an earlier revision's stream, an unknown filter, a stream that does not decode, a file
    /// that says PDF but is not one, no helper — each is refused. Clean PDFs (classic and object-stream) pass.
    @Test func pdfFailsClosed() throws {
        guard Self.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try Self.reader(cf)
        let z = PDFBuild.zlib(PDFBuild.text("key \(Self.value)"))
        let plain = PDFBuild.zlib(PDFBuild.text("hello"))
        // A `stream` keyword that belongs to no object: no reader ties it to anything.
        let stray = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(plain.count) /Filter /FlateDecode >>", plain)),
                                   junk: (before: 5, data: Data("stream\n".utf8) + z + Data("\nendstream\n".utf8)))
        #expect(throws: Self.unaccounted) { try check(cf, stray, canonical: "stray.pdf", archives: reader) }
        // An earlier revision's stream, replaced by an incremental update: still in the file. Round 3: every revision is
        // read, so the value in it is caught.
        let original = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(z.count) /Filter /FlateDecode >>", z)))
        let previous = String(decoding: original.suffix(40), as: UTF8.self).components(separatedBy: "startxref\n").last?
            .split(separator: "\n").first.flatMap { Int($0) } ?? 0
        var updated = original
        let at = updated.count
        updated += Data("4 0 obj\n".utf8) + PDFBuild.stream("<< /Length \(plain.count) /Filter /FlateDecode >>", plain) + Data("\nendobj\n".utf8)
        let xref = updated.count
        updated += Data("xref\n4 1\n\(PDFBuild.pad10(at)) 00000 n \ntrailer\n<< /Size 6 /Root 1 0 R /Prev \(previous) >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        // Round 4 (R4-6): an object rewritten across revisions is an anomaly in itself.
        #expect(throws: Self.unaccounted) { try check(cf, updated, canonical: "revised.pdf", archives: reader) }
        // A filter nobody knows, and a Flate stream that is not zlib.
        let unknown = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length 6 /Filter /MadeUpDecode >>", Data("opaque".utf8))))
        #expect(throws: Self.undecodable) { try check(cf, unknown, canonical: "odd.pdf", archives: reader) }
        let broken = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length 24 /Filter /FlateDecode >>", Data("not a zlib stream at all".utf8))))
        #expect(throws: Self.undecodable) { try check(cf, broken, canonical: "broken.pdf", archives: reader) }
        // Text that carries a PDF header but is no PDF: it can't be read as one, so it is refused, not passed.
        let notes = Data("These notes mention %PDF-1.7 and nothing else.\n".utf8)
        #expect(throws: Self.unreadable) { try check(cf, notes, ext: "md", canonical: "notes.md", archives: reader) }
        // No helper: refused.
        #expect(throws: Self.unavailable) { try check(cf, PDFBuild.flate("hello"), canonical: "a.pdf", archives: UnavailableArchiveReader()) }
        #expect(throws: Self.unavailable) {
            try check(cf, PDFBuild.flate("hello again"), canonical: "b.pdf", archives: try Self.reader(cf, helper: nil))
        }
        // Clean PDFs pass: a classic one, and one whose objects live in an object stream (PDF 1.5).
        #expect(try check(cf, PDFBuild.flate("hello there"), canonical: "clean.pdf", archives: reader) == .clean)
        #expect(try check(cf, PDFBuild.objectStreams(), canonical: "modern.pdf", archives: reader) == .clean)
        // A stored value in an unused object of an object stream is caught.
        #expect(throws: Self.refusal("hidden.pdf")) {
            try check(cf, PDFBuild.objectStreams(hidden: "<< /Note (key \(Self.value)) >>"), canonical: "hidden.pdf", archives: reader)
        }
        // A scanned budget: a PDF that decodes to more than the budget left is refused.
        let big = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(plain.count) /Filter /FlateDecode >>", plain),
                                               extra: [{ let d = PDFBuild.zlib(Data(repeating: 0x20, count: 50_000))
                                                         return PDFBuild.stream("<< /Length \(d.count) /Filter /FlateDecode >>", d) }()]))
        #expect(throws: ArchiveMemberScan.overBudget) {
            try EmbeddedContent.scan(big, ext: "pdf", archives: reader, expanded: [], budget: ArchiveScanBudget(bytes: 10_000), level: 0,
                                     chunk: ContentScan.chunkBytes)
        }
    }

    /// Ruling 33 (3): every decoded stream is checked again: a zip (its members scanned), a gzip (refused), a PNG (its text
    /// chunks) and a PDF (through the helper again), all on the one budget.
    @Test func decodedStreamsRecursed() throws {
        guard Self.helperReady, FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else { return }
        let cf = try CollabFixture()
        let reader = try Self.reader(cf)
        func embedded(_ file: Data, subtype: String = "") -> Data {
            let z = PDFBuild.zlib(file)
            let plain = PDFBuild.zlib(PDFBuild.text("hello"))
            return PDFBuild.build([
                Data("<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles << /Names [(f) 7 0 R] >> >> >>".utf8),
                Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
                Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>".utf8),
                PDFBuild.stream("<< /Length \(plain.count) /Filter /FlateDecode >>", plain),
                Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
                PDFBuild.stream("<< /Type /EmbeddedFile\(subtype) /Length \(z.count) /Filter /FlateDecode >>", z),
                Data("<< /Type /Filespec /F (f) /EF << /F 6 0 R >> >>".utf8),
            ])
        }
        // A real deflated zip whose member holds the value.
        let dir = try tempDir()
        try Data(("v=\(Self.value)\n" + String(repeating: "pad ", count: 50)).utf8).write(to: dir.appending(path: "s.txt"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        p.arguments = ["-q", "-X", "-9", "out.zip", "s.txt"]
        try p.run(); p.waitUntilExit()
        let zip = try Data(contentsOf: dir.appending(path: "out.zip"))
        #expect(throws: Self.refusal("zip-inside.pdf")) { try check(cf, embedded(zip), canonical: "zip-inside.pdf", archives: reader) }
        // gzip data inside: can't be scanned, refused.
        let gz = Data([0x1F, 0x8B, 0x08, 0x00]) + Data(repeating: 0x41, count: 64)
        #expect(throws: WorkError.invalid("this PDF holds gzip data, which can't be scanned for secrets")) {
            try check(cf, embedded(gz), canonical: "gz-inside.pdf", archives: reader)
        }
        // A PNG whose zTXt chunk holds the value.
        let png = SecretGateTests.png([("zTXt", Data("Comment".utf8) + Data([0, 0]) + PDFBuild.zlib(Data("key \(Self.value)".utf8)))])
        #expect(throws: Self.refusal("png-inside.pdf")) { try check(cf, embedded(png), canonical: "png-inside.pdf", archives: reader) }
        // A PDF inside the PDF.
        #expect(throws: Self.refusal("pdf-inside.pdf")) {
            try check(cf, embedded(PDFBuild.flate("key \(Self.value)")), canonical: "pdf-inside.pdf", archives: reader)
        }
        // And a clean attachment passes.
        #expect(try check(cf, embedded(Data("just a note\n".utf8)), canonical: "note-inside.pdf", archives: reader) == .clean)
    }

    /// R2-1: the helper killed, timed out or crashed, or output that does not hold together: refused. Round 4: the exit
    /// status is the helper's own (no status file), and output past the cap is the runner's kill.
    @Test func helperFailuresRefused() throws {
        let cf = try CollabFixture()
        let pdf = PDFBuild.flate("hello")
        func scripted(_ runner: ScriptedRunner) -> SandboxedPDFReader {
            SandboxedPDFReader(runner: runner, helper: URL(fileURLWithPath: "/usr/bin/true"), scratch: { try cf.vault.makeTempDir() })
        }
        func exit(_ code: Int32?) -> CheckOutcome { CheckOutcome(exitCode: code, timedOut: false, tail: "") }
        let good = Self.framed([(0x44, Data("BT (hello) Tj ET".utf8)), (0x54, Data("hello".utf8))])
        #expect(try scripted(ScriptedRunner(parts: good, outcome: exit(0))).parts(of: pdf, maxBytes: 1_000_000).count == 2)
        let cases: [(String, ScriptedRunner)] = [
            ("killed", ScriptedRunner(parts: Data(), outcome: exit(137))),
            ("crashed", ScriptedRunner(parts: Data("BRAHMA-PDF/1\n".utf8), outcome: exit(139))),
            ("sandbox-exec failed", ScriptedRunner(parts: good, outcome: exit(65))),
            ("no output", ScriptedRunner(parts: nil, outcome: exit(0))),
            ("garbage", ScriptedRunner(parts: Data("garbage".utf8), outcome: exit(0))),
            ("truncated", ScriptedRunner(parts: good.prefix(good.count - 3), outcome: exit(0))),
            ("no end record", ScriptedRunner(parts: good.prefix(good.count - 13), outcome: exit(0))),
            ("wrong count", ScriptedRunner(parts: Self.framed([(0x44, Data("x".utf8))], count: 5), outcome: exit(0))),
            ("unknown kind", ScriptedRunner(parts: Self.framed([(0x51, Data("x".utf8))]), outcome: exit(0))),
            ("trailing bytes", ScriptedRunner(parts: good + Data("x".utf8), outcome: exit(0))),
        ]
        for (name, runner) in cases {
            #expect(throws: SandboxedPDFReader.unreadable, "\(name)") { try scripted(runner).parts(of: pdf, maxBytes: 1_000_000) }
        }
        // Round 3: a run that timed out, could not start, or was stopped for its memory says so (and is not cached).
        #expect(throws: SandboxedPDFReader.tooLong) {
            try scripted(ScriptedRunner(parts: good, outcome: CheckOutcome(exitCode: nil, timedOut: true, tail: ""))).parts(of: pdf, maxBytes: 1_000_000)
        }
        #expect(throws: SandboxedPDFReader.couldNotRun) {
            try scripted(ScriptedRunner(parts: nil, outcome: CheckOutcome(exitCode: nil, timedOut: false, tail: "could not run"))).parts(of: pdf, maxBytes: 1_000_000)
        }
        #expect(throws: SandboxedPDFReader.tooMuchMemory) {
            try scripted(ScriptedRunner(parts: nil, outcome: CheckOutcome(exitCode: nil, timedOut: false, tail: GroupRun.memoryExceeded))).parts(of: pdf, maxBytes: 1_000_000)
        }
        #expect(throws: SandboxedPDFReader.tooMuchMemory) { try scripted(ScriptedRunner(parts: Data(), outcome: exit(9))).parts(of: pdf, maxBytes: 1000) }
        // Round 4: output past the cap is the runner's kill: over the budget.
        #expect(throws: ArchiveMemberScan.overBudget) {
            try scripted(ScriptedRunner(parts: nil, outcome: CheckOutcome(exitCode: nil, timedOut: false, tail: GroupRun.outputExceeded))).parts(of: pdf, maxBytes: 1000)
        }
        // The helper's own answers.
        #expect(throws: SandboxedPDFReader.encrypted) { try scripted(ScriptedRunner(parts: Data(), outcome: exit(3))).parts(of: pdf, maxBytes: 1000) }
        #expect(throws: SandboxedPDFReader.undecodable) { try scripted(ScriptedRunner(parts: Data(), outcome: exit(4))).parts(of: pdf, maxBytes: 1000) }
        #expect(throws: SandboxedPDFReader.unaccounted) { try scripted(ScriptedRunner(parts: Data(), outcome: exit(5))).parts(of: pdf, maxBytes: 1000) }
        #expect(throws: ArchiveMemberScan.overBudget) { try scripted(ScriptedRunner(parts: Data(), outcome: exit(6))).parts(of: pdf, maxBytes: 1000) }
        // More output than allowed is over the budget whatever the helper says.
        #expect(throws: ArchiveMemberScan.overBudget) {
            try scripted(ScriptedRunner(parts: good, outcome: exit(0))).parts(of: pdf, maxBytes: good.count - 1)
        }
        // Through the gate, a failed helper is a refusal.
        let failing = SandboxedUnzipReader(runner: ScriptedRunner(parts: Data(), outcome: exit(137)), scratch: { try cf.vault.makeTempDir() },
                                           pdfHelper: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(throws: Self.unreadable) { try check(cf, pdf, canonical: "x.pdf", archives: failing) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: cf.paths.tmpDir.path).isEmpty)
        // (The real sandbox's time limit and output cap: `helperRunsAloneInItsOwnSession`.)
    }

    /// R2-4: the helper output's parser on garbage, truncations and mutations: it refuses, it never traps.
    @Test func helperOutputParserNeverTraps() {
        var rng = SeededBytes(state: 0xC2B2)
        var valid = Data("BRAHMA-PDF/1\n".utf8)
        for i in 0..<4 { let p = rng.bytes(i * 7); valid += Data([0x44, 0, 0, 0, UInt8(p.count)]) + p }
        valid += Data([0x45, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 4])
        #expect(((try? SandboxedPDFReader.parse(valid, maxBytes: 10_000)) ?? []).count == 4)
        var inputs: [Data] = (0...valid.count).map { valid.prefix($0) }
        for _ in 0..<2000 {
            var m = valid
            m[rng.below(m.count)] = UInt8(truncatingIfNeeded: rng.next())
            inputs.append(m)
        }
        for _ in 0..<500 { inputs.append(Data("BRAHMA-PDF/1\n".utf8) + rng.bytes(rng.below(64))) }
        inputs.append(Data("BRAHMA-PDF/1\n".utf8) + Data([0x44, 0xFF, 0xFF, 0xFF, 0xFF]))
        for input in inputs { _ = try? SandboxedPDFReader.parse(input, maxBytes: 10_000) }
    }

    /// N-2: the re-review's crafted TIFF-predictor stream (a short last row) trapped the old in-engine decoder. Decoding is
    /// the helper's now: the gate answers, the engine does not crash.
    @Test func shortPredictorRowDoesNotCrash() throws {
        let cf = try CollabFixture()
        let z = PDFBuild.zlib(Data("abcd".utf8))
        let crafted = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(z.count) /Filter /FlateDecode /DecodeParms << /Predictor 2 /Colors 3 /Columns 1 >> >>", z)))
        // No helper: refused (and no crash).
        #expect(throws: Self.unavailable) { try check(cf, crafted, canonical: "tiff.pdf", archives: UnavailableArchiveReader()) }
        guard Self.helperReady else { return }
        #expect(try check(cf, crafted, canonical: "tiff.pdf", archives: try Self.reader(cf)) == .clean)
    }

    // MARK: PNG (R2-5)

    static func chunk(_ type: String, _ data: Data, crc: UInt32? = nil) -> Data {
        let typed = Data(type.utf8) + data
        let c = crc ?? ZipBuilder.crc32(typed)
        func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        return Data(be32(UInt32(data.count))) + typed + Data(be32(c))
    }

    static let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    static let ihdr = chunk("IHDR", Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 0]))
    static let iend = chunk("IEND", Data())

    static func itxt(flag: UInt8, method: UInt8 = 0, _ payload: Data) -> Data {
        var d = Data("Comment".utf8)
        d.append(contentsOf: [0, flag, method] as [UInt8])
        d.append(Data("en".utf8)); d.append(contentsOf: [0, 0] as [UInt8])
        return chunk("iTXt", d + payload)
    }

    @Test func pngWalkIsStrict() throws {
        let cf = try CollabFixture()
        let none = UnavailableArchiveReader()
        let secret = PDFBuild.zlib(Data("key \(Self.value)".utf8))
        func png(_ chunks: [Data], tail: Data = Data()) -> Data { Self.signature + Self.ihdr + chunks.reduce(Data(), +) + Self.iend + tail }
        // iTXt: flag 1 is compressed (caught); any flag but 0 or 1 is refused (Pillow decompresses flag 2).
        #expect(throws: Self.refusal("one.png")) { try check(cf, png([Self.itxt(flag: 1, secret)]), ext: "png", canonical: "one.png", archives: none) }
        #expect(throws: Self.badPNG) { try check(cf, png([Self.itxt(flag: 2, secret)]), ext: "png", canonical: "two.png", archives: none) }
        #expect(throws: Self.badPNG) { try check(cf, png([Self.itxt(flag: 1, method: 1, secret)]), ext: "png", canonical: "m.png", archives: none) }
        // iCCP is decoded too.
        #expect(throws: Self.refusal("icc.png")) {
            try check(cf, png([Self.chunk("iCCP", Data("icc".utf8) + Data([0, 0]) + secret)]), ext: "png", canonical: "icc.png", archives: none)
        }
        // Anything after IEND is refused (some metadata readers read past it).
        let after = Self.chunk("zTXt", Data("Comment".utf8) + Data([0, 0]) + secret)
        #expect(throws: Self.badPNG) { try check(cf, png([], tail: after), ext: "png", canonical: "after.png", archives: none) }
        #expect(throws: Self.badPNG) { try check(cf, png([], tail: Data("x".utf8)), ext: "png", canonical: "after2.png", archives: none) }
        // A chunk the engine doesn't know (a compressed EXIF, a private chunk) is refused, never skipped.
        #expect(throws: Self.badPNG) { try check(cf, png([Self.chunk("zxIf", secret)]), ext: "png", canonical: "zx.png", archives: none) }
        #expect(throws: Self.badPNG) { try check(cf, png([Self.chunk("prIv", Data("x".utf8))]), ext: "png", canonical: "pv.png", archives: none) }
        // A wrong CRC, a length past the end, no IEND, IHDR not first, a type that is not four letters: refused.
        #expect(throws: Self.badPNG) {
            try check(cf, png([Self.chunk("tEXt", Data("a\0b".utf8), crc: 1)]), ext: "png", canonical: "crc.png", archives: none)
        }
        #expect(throws: Self.badPNG) {
            try check(cf, Self.signature + Self.ihdr + Data([0, 0, 0x10, 0]) + Data("tEXt".utf8) + Data(repeating: 0x41, count: 20),
                      ext: "png", canonical: "long.png", archives: none)
        }
        #expect(throws: Self.badPNG) { try check(cf, Self.signature + Self.ihdr, ext: "png", canonical: "noend.png", archives: none) }
        #expect(throws: Self.badPNG) { try check(cf, Self.signature + Self.iend, ext: "png", canonical: "noihdr.png", archives: none) }
        #expect(throws: Self.badPNG) { try check(cf, png([Self.chunk("t3Xt", Data("a".utf8))]), ext: "png", canonical: "type.png", archives: none) }
        // A zTXt that does not inflate is refused.
        #expect(throws: WorkError.invalid("this PNG has a compressed chunk that can't be decoded for scanning")) {
            try check(cf, png([Self.chunk("zTXt", Data("Comment".utf8) + Data([0, 0]) + Data("not zlib".utf8))]), ext: "png",
                      canonical: "bad.png", archives: none)
        }
        // Known chunks pass: pHYs, a clean tEXt, an uncompressed iTXt, a clean zTXt, an IDAT.
        let fine = png([Self.chunk("pHYs", Data([0, 0, 0x0B, 0x13, 0, 0, 0x0B, 0x13, 1])), Self.chunk("tEXt", Data("Software\0brahma".utf8)),
                        Self.itxt(flag: 0, Data("plain words".utf8)),
                        Self.chunk("zTXt", Data("Comment".utf8) + Data([0, 0]) + PDFBuild.zlib(Data("made with care".utf8))),
                        Self.chunk("IDAT", PDFBuild.zlib(Data([0, 0])))])
        #expect(try check(cf, fine, ext: "png", canonical: "fine.png", archives: none) == .clean)
    }

    /// R2-4: every decoder still in the engine (the PNG walk, inflate, the zip local-header test, the zip inventory) on
    /// garbage, truncations and mutations: each refuses or answers, none traps.
    @Test func inEngineDecodersNeverTrap() throws {
        var rng = SeededBytes(state: 0xF022)
        let zlibbed = PDFBuild.zlib(Data("some text to inflate, some text to inflate".utf8))
        let png = Self.signature + Self.ihdr + Self.chunk("zTXt", Data("k".utf8) + Data([0, 0]) + zlibbed) + Self.itxt(flag: 1, zlibbed) + Self.iend
        let zip = try SecretGateTests.zip { $0.add("a.txt", "alpha"); $0.add("b/c.txt", "beta", flags: 8) }
        let samples = [png, zlibbed, zip]
        var inputs: [Data] = []
        for s in samples {
            inputs += (0...s.count).map { s.prefix($0) }
            for _ in 0..<1500 {
                var m = s
                m[rng.below(m.count)] = UInt8(truncatingIfNeeded: rng.next())
                inputs.append(m)
            }
        }
        for _ in 0..<1500 {
            inputs.append(rng.bytes(rng.below(200)))
            inputs.append(Self.signature + rng.bytes(rng.below(120)))
            inputs.append(Data([0x50, 0x4B, 0x03, 0x04]) + rng.bytes(rng.below(80)))
            inputs.append(Data([0x78, 0x9C]) + rng.bytes(rng.below(80)))
        }
        for input in inputs {
            _ = try? EmbeddedContent.pngTexts(input, budget: ArchiveScanBudget())
            _ = try? EmbeddedContent.inflateZlib(input, cap: 100_000, failure: EmbeddedContent.badInflate)
            _ = ArchiveMemberScan.isArchive(input, ext: "bin")
            _ = try? ZipInventory.entries(of: input)
            _ = ArchiveMemberScan.unscannableFormat(input)
        }
        // Slices whose indices do not start at 0 too.
        for input in inputs.prefix(400) where input.count > 3 {
            let slice = input[input.startIndex.advanced(by: 2)...]
            _ = try? EmbeddedContent.pngTexts(slice, budget: ArchiveScanBudget())
            _ = ArchiveMemberScan.isArchive(slice, ext: "bin")
        }
    }

    // MARK: Fix round 3

    /// R3-1 (C-1): every revision of the file is read. The reviewer's `rev_dup`: revision 1 draws an AWS key, an update
    /// replaces that content and maps a second object number to the new object (so a count by cross-reference entries
    /// would come out even): refused. `rev_noalias`, the same update without the alias: the key in revision 1 is caught. Two bodies of one
    /// object in a single revision leave one that no revision reaches: refused.
    @Test func everyRevisionRead() throws {
        guard Self.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try Self.reader(cf)
        let secret = PDFBuild.zlib(PDFBuild.text("key \(Self.aws)"))
        let clean = PDFBuild.zlib(PDFBuild.text("hello"))
        let revision1 = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Filter /FlateDecode /Length \(secret.count) >>", secret)))
        let newContent = PDFBuild.stream("<< /Filter /FlateDecode /Length \(clean.count) >>", clean)
        let aliased = PDFBuild.update(revision1, objects: [(4, newContent)], aliases: [6: 4])
        let plain = PDFBuild.update(revision1, objects: [(4, newContent)])
        #expect(!String(decoding: aliased, as: UTF8.self).contains(Self.aws))
        // Two numbers naming one object: refused (the alias is what let one stream stand in for the hidden one).
        #expect(throws: Self.unaccounted) { try check(cf, aliased, canonical: "rev_dup.pdf", archives: reader) }
        // Round 4 (R4-6): object 4 rewritten by the update is an anomaly: refused whatever it holds.
        #expect(throws: Self.unaccounted) { try check(cf, plain, canonical: "rev_noalias.pdf", archives: reader) }
        // A stored value in revision 1 of a three-revision file.
        let stored = PDFBuild.flate("key \(Self.value)")
        let three = PDFBuild.update(PDFBuild.update(stored, objects: [(4, newContent)]), objects: [(5, Data("<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>".utf8))])
        #expect(throws: Self.unaccounted) { try check(cf, three, canonical: "three.pdf", archives: reader) }
        // Two bodies of object 4 in one revision; the cross-reference names the second.
        let twice = PDFBuild.build(PDFBuild.page(newContent),
                                   junk: (before: 4, data: Data("4 0 obj\n".utf8) + PDFBuild.stream("<< /Filter /FlateDecode /Length \(secret.count) >>", secret) + Data("\nendobj\n".utf8)))
        #expect(throws: Self.unaccounted) { try check(cf, twice, canonical: "twice.pdf", archives: reader) }
        // A clean multi-revision file passes.
        // Round 4 (R4-6): an update that only adds objects (no object rewritten) passes.
        #expect(try check(cf, PDFBuild.update(PDFBuild.flate("one"), objects: [(6, Data("<< /Producer (edited) >>".utf8))]),
                          canonical: "edited.pdf", archives: reader) == .clean)
    }

    /// R3-2 (C-2): strings drawn by content streams outside the page text (an annotation's appearance, every appearance
    /// state, a Form XObject nothing draws, a marked-content property) are read with their escapes decoded.
    @Test func contentStreamsOutsidePageTextScanned() throws {
        guard Self.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try Self.reader(cf)
        let octal = "(key \\163\\153\\137test\\137\\065\\061abcdefgh) Tj"
        func form(_ ops: String, font: Int = 6) -> Data {
            let body = Data("BT /F1 14 Tf 2 6 Td \(ops) ET".utf8)
            return PDFBuild.stream("<< /Type /XObject /Subtype /Form /BBox [0 0 280 30] /Resources << /Font << /F1 \(font) 0 R >> >> /Length \(body.count) >>", body)
        }
        func annotated(_ ap: String, extra: [Data] = []) -> Data {
            PDFBuild.build([Data("<< /Type /Catalog /Pages 2 0 R >>".utf8), Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
                            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 100] /Annots [4 0 R] >>".utf8),
                            Data("<< /Type /Annot /Subtype /Stamp /Rect [10 40 290 70] /F 4 /AP \(ap) >>".utf8),
                            form(octal), Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)] + extra)
        }
        let annot = annotated("<< /N 5 0 R >>")
        #expect(!String(decoding: annot, as: UTF8.self).contains(Self.value))
        #expect(throws: Self.refusal("annot.pdf")) { try check(cf, annot, canonical: "annot.pdf", archives: reader) }
        // An appearance state (`/D << /Down … >>`) other than the normal one.
        let states = annotated("<< /N 7 0 R /D << /Down 5 0 R >> >>", extra: [form("(hello) Tj")])
        #expect(throws: Self.refusal("states.pdf")) { try check(cf, states, canonical: "states.pdf", archives: reader) }
        // A Form XObject nothing draws.
        let page = PDFBuild.zlib(PDFBuild.text("hello"))
        let unused = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(page.count) /Filter /FlateDecode >>", page)) + [form(octal, font: 5)])
        #expect(throws: Self.refusal("unused.pdf")) { try check(cf, unused, canonical: "unused.pdf", archives: reader) }
        // A marked-content property (`/ActualText`) in the page's own content.
        let marked = Data("/Span << /ActualText (\\163k_test_51abcdefgh) >> BDC BT /F1 12 Tf 72 700 Td (x) Tj ET EMC".utf8)
        let actual = PDFBuild.build(PDFBuild.page(PDFBuild.stream("<< /Length \(marked.count) >>", marked)))
        #expect(throws: Self.refusal("actual.pdf")) { try check(cf, actual, canonical: "actual.pdf", archives: reader) }
        // A clean annotation passes.
        let fine = PDFBuild.build([Data("<< /Type /Catalog /Pages 2 0 R >>".utf8), Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
                                   Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 100] /Annots [4 0 R] >>".utf8),
                                   Data("<< /Type /Annot /Subtype /Stamp /Rect [10 40 290 70] /F 4 /AP << /N 5 0 R >> >>".utf8),
                                   form("(\\150ello) Tj"), Data("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8)])
        #expect(try check(cf, fine, canonical: "fine-annot.pdf", archives: reader) == .clean)
    }

    /// R3-3 (I-1): a PDF that inflates past the memory limit is stopped and refused well inside the time limit, by the
    /// engine's watchdog (the run's process group's footprint) and, on its own, by the helper's self-check.
    @Test(.timeLimit(.minutes(5))) func memoryBombStopped() throws {
        guard Self.helperReady else { return }
        let cf = try CollabFixture()
        let bomb = PDFBuild.memoryBomb
        #expect(bomb.count < 2_000_000)
        let home = try Scratch.homeDir().resolvedForSandbox
        let sbPaths = BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
        let sbVault = Vault(paths: sbPaths, companyId: cf.c.id, content: ContentVault(paths: sbPaths))
        func reader(engine: Int, helper: Int) -> SandboxedPDFReader {
            SandboxedPDFReader(runner: SeatbeltRunner(baseline: { SandboxBaseline.current(paths: sbPaths, otherWorkspaces: [], backupTargets: []) },
                                                      proxies: EgressProxyPool()),
                               helper: Self.helper, scratch: { try sbVault.makeTempDir() }, memoryLimit: engine, helperMemoryLimit: helper)
        }
        var started = AwakeTime.uptime()
        #expect(throws: SandboxedPDFReader.tooMuchMemory, "the engine's watchdog") {
            try reader(engine: 256 << 20, helper: 64 << 30).parts(of: bomb, maxBytes: ArchiveLimits.maxBytes)
        }
        #expect(AwakeTime.uptime() - started < 30)
        started = AwakeTime.uptime()
        #expect(throws: SandboxedPDFReader.tooMuchMemory, "the helper's self-check") {
            try reader(engine: 64 << 30, helper: 256 << 20).parts(of: bomb, maxBytes: ArchiveLimits.maxBytes)
        }
        #expect(AwakeTime.uptime() - started < 30)
        // Through the gate, with the standard 1 GiB limit.
        #expect(throws: WorkError.invalid("this PDF needs too much memory to scan for secrets")) {
            try check(cf, bomb, canonical: "bomb.pdf", archives: try Self.reader(cf))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: sbPaths.tmpDir.path).isEmpty)
    }

    /// R3-6 (m-B): `stream` followed straight by its data (no end of line) is still a stream keyword: one the reader
    /// drops is data no walk reaches, refused.
    @Test func streamWithoutEndOfLineRefused() throws {
        guard Self.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try Self.reader(cf)
        let z = PDFBuild.zlib(PDFBuild.text("key \(Self.aws)"))
        let noEOL = PDFBuild.build(PDFBuild.page(Data("<< /Filter /FlateDecode /Length \(z.count) >>\nstream".utf8) + z + Data("\nendstream".utf8)))
        #expect(throws: WorkError.self) { try check(cf, noEOL, canonical: "noeol.pdf", archives: reader) }
        let space = PDFBuild.build(PDFBuild.page(Data("<< /Filter /FlateDecode /Length \(z.count) >>\nstream ".utf8) + z + Data("\nendstream".utf8)))
        #expect(throws: WorkError.self) { try check(cf, space, canonical: "space.pdf", archives: reader) }
    }

    /// R3-7 (m-C): the helper runs under a deny-default profile: it may run only the pipeline's programs, read only the
    /// system, its own binary and the one input, write only its two outputs, and reach no network or mach service but the
    /// run's own marker. Probes run AS the helper show each denial; real PDFs on this Mac still read.
    @Test func helperProfileIsDenyDefault() throws {
        let cf = try CollabFixture()
        let held = URL(fileURLWithPath: "/private/tmp/held"), out = URL(fileURLWithPath: "/private/tmp/out")
        let policy = SandboxedPDFReader.policy(helper: URL(fileURLWithPath: "/opt/h/brahma-pdf"), held: held, out: out, memoryLimit: 1 << 30)
        let profile = SeatbeltProfile.render(policy: policy, baseline: SandboxBaseline.current(paths: cf.paths, otherWorkspaces: [], backupTargets: []),
                                             proxyPort: nil, marker: "dev.brahma.run.test")
        #expect(profile.contains("(deny default)") && !profile.contains("(allow default)"))
        #expect(!profile.contains("network-outbound") && !profile.contains("network-bind"))
        #expect(profile.contains("(allow mach-lookup (global-name \"dev.brahma.run.test\"))"))
        #expect(profile.components(separatedBy: "mach-lookup").count == 2)
        #expect(profile.contains("(literal \"/opt/h/brahma-pdf\")") && !profile.contains("/private/tmp/out/parts"))
        #expect(!profile.contains("(allow file-write* (subpath"))
        #expect(policy.memoryLimit == 1 << 30)
        guard Toolchain.seatbeltAvailable else { return }
        let home = try Scratch.homeDir().resolvedForSandbox
        let sbPaths = BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
        let sbVault = Vault(paths: sbPaths, companyId: cf.c.id, content: ContentVault(paths: sbPaths))
        let outside = home.appending(path: "outside.txt")
        try Data("not for the helper\n".utf8).write(to: outside)
        // Round 4: the helper runs as itself, so the probes are a compiled stand-in (`HelperProbe`) that prints a valid,
        // empty helper output only when the action it tries was denied.
        if let probe = HelperProbe.binary() {
            let probeReader = SandboxedPDFReader(runner: SeatbeltRunner(baseline: {
                SandboxBaseline.current(paths: sbPaths, otherWorkspaces: [], backupTargets: [])
            }, proxies: EgressProxyPool()), helper: probe, scratch: { try sbVault.makeTempDir() })
            let probes: [(String, String)] = [
                ("read a file outside", "read \(outside.path)"),
                ("read /etc", "read /private/etc/hosts"),
                ("run another program", "exec /bin/cat"),
                ("write outside its outputs", "write \(home.appending(path: "written.txt").path)"),
                ("open a network connection", "connect 22"),
            ]
            for (name, orders) in probes {
                #expect(throws: Never.self, "\(name) was not denied") { _ = try probeReader.parts(of: Data((orders + "\n").utf8), maxBytes: 10_000) }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "written.txt").path))
        // Real PDFs on this Mac still read under it: each clean, or (breaker B-1) refused for its structure, which the helper
        // can only say once it has read the whole file under the profile (`ENERGY STAR.pdf`: CoreGraphics can't parse its
        // structure elements, whose `/Pg` references overflow, so its view holds in-use objects the reader never resolved).
        guard Self.helperReady else { return }
        let reader = try Self.reader(cf)
        let places = ["/System/Library/ProductDocuments/ProductGuides", "/System/Library/Audio/MIDI Devices/Generic/Images",
                      "/System/Library/CoreServices/OSDUIHelper.app/Contents/Resources", "/System/Library/CoreServices/ScriptMonitor.app/Contents/Resources",
                      "/System/Library/CoreServices/SystemUIServer.app/Contents/Resources", "/System/Library/QuickLook/iWork.qlgenerator/Contents/Resources"]
        var read = 0, clean = 0
        for place in places {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: place)) ?? []).sorted() where name.hasSuffix(".pdf") && read < 30 {
                guard let data = FileManager.default.contents(atPath: place + "/" + name) else { continue }
                let outcome: String
                do { outcome = "\(try check(cf, data, canonical: name, archives: reader))" } catch let e as WorkError { outcome = e.message }
                let structure = outcome == Self.unaccounted.message || outcome.hasPrefix(Self.unaccounted.message + " — the owner can vouch")
                #expect(outcome == "clean" || structure, "\(name): \(outcome)")
                if outcome == "clean" { clean += 1 }
                read += 1
            }
        }
        #expect(read == 0 || clean * 10 >= read * 9, "\(clean) of \(read) real PDFs read clean")
    }

    // MARK: Fix round 4

    /// R4-1 (ruling 34, items 1 and 2): the reviewer's `v.py` files. Revision A draws an AWS key from object 4 and ends at
    /// `startxref` with no `%%EOF`.
    /// - `v1_shift`: an update maps object 6 to the new object 4's offset minus one (the newline before its header): an
    ///   in-use entry that is not exactly an object's header, refused.
    /// - `v1_control`, without the alias: revision A is cut at its `startxref` and walked; the key is caught.
    /// - `v2_gen`: a generation-1 stream with an indirect `/Length` that a later revision changes; revision A again caught,
    ///   at generation 1 and 0 alike.
    /// - Revision A's body with no cross-reference entry naming it at all (no revision of its own), next to the same
    ///   generation-1 trick: a stream body no entry names, refused.
    /// - An in-use entry at offset 0 (as some Apple PDFs have), or naming another generation than the header: refused.
    /// Controls: a revision ending at `startxref` alone, updated cleanly, passes.
    @Test func everyStreamPlacedAtItsExactOffset() throws {
        guard Self.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try Self.reader(cf)
        typealias B = RevisionBuild
        let secret = PDFBuild.zlib(PDFBuild.text("key \(Self.aws)")), clean = PDFBuild.zlib(PDFBuild.text("hello"))
        let a = B.build(B.base(B.stream(4, secret)), eof: false)
        func noKey(_ d: Data) -> Bool { !String(decoding: d, as: UTF8.self).contains(Self.aws) }
        let v1 = B.update(a, objects: [B.stream(4, clean)], entries: [(4, 0, { $0[0] }), (6, 0, { $0[0] - 1 })], size: 7).data
        #expect(noKey(v1))
        #expect(throws: Self.unaccounted) { try check(cf, v1, canonical: "v1_shift.pdf", archives: reader) }
        let control = B.update(a, objects: [B.stream(4, clean)], entries: [(4, 0, { $0[0] })], size: 6).data
        // Round 4 (R4-6): object 4 rewritten by the update: refused as unverifiable (before R4-6 its key was caught).
        #expect(throws: Self.unaccounted) { try check(cf, control, canonical: "v1_control.pdf", archives: reader) }
        for gen in [1, 0] {
            let nine = B.obj(9, Data("<< /Length 7 0 R >>\nstream\nABCDEFGH\nendstream".utf8), gen: gen)
            let b = B.update(a, objects: [B.stream(4, clean), nine, B.obj(7, "4")],
                             entries: [(4, 0, { $0[0] }), (9, gen, { $0[1] }), (7, 0, { $0[2] })], size: 10)
            let v2 = B.update(b, objects: [B.obj(7, "8")], entries: [(7, 0, { $0[0] })], size: 10).data
            #expect(noKey(v2))
            #expect(throws: Self.unaccounted) { try check(cf, v2, canonical: "v2_gen\(gen).pdf", archives: reader) }
        }
        // Revision A's body named by no entry anywhere: its stream is placed nowhere.
        let hidden = B.build(B.base(B.stream(4, clean)), unlisted: [B.stream(4, secret)], eof: true)
        let nine = B.obj(9, Data("<< /Length 7 0 R >>\nstream\nABCDEFGH\nendstream".utf8), gen: 1)
        let hb = B.update(hidden, objects: [nine, B.obj(7, "4")], entries: [(9, 1, { $0[0] }), (7, 0, { $0[1] })], size: 10)
        let unnamed = B.update(hb, objects: [B.obj(7, "8")], entries: [(7, 0, { $0[0] })], size: 10).data
        #expect(noKey(unnamed))
        #expect(throws: Self.unaccounted) { try check(cf, unnamed, canonical: "unnamed.pdf", archives: reader) }
        // An in-use entry at offset 0, and one naming generation 1 for a generation-0 header.
        let base = B.build(B.base(B.stream(4, clean)))
        let zero = B.update(base, objects: [], entries: [(6, 0, { _ in 0 })], size: 7).data
        #expect(throws: Self.unaccounted) { try check(cf, zero, canonical: "zero.pdf", archives: reader) }
        let wrongGeneration = B.update(base, objects: [B.stream(4, clean)], entries: [(4, 1, { $0[0] })], size: 6).data
        #expect(throws: Self.unaccounted) { try check(cf, wrongGeneration, canonical: "generation.pdf", archives: reader) }
        // Control: revision A clean and ending at `startxref` alone, then an update that adds an object.
        let fine = B.update(B.build(B.base(B.stream(4, clean)), eof: false),
                            objects: [B.obj(6, "<< /Producer (hello again) >>")], entries: [(6, 0, { $0[0] })], size: 7).data
        #expect(try check(cf, fine, canonical: "fine.pdf", archives: reader) == .clean)
    }

    /// R4-6 (ruling 35): any anomaly the exact-offset accounting finds is one refusal, "this PDF's structure couldn't be
    /// verified" (round 5: then the owner's vouch command), with nothing modelled: more than 8 revisions; an object
    /// rewritten across revisions (clean or not); an object header no cross-reference entry names. Controls: 8 revisions
    /// that only add objects pass.
    @Test func structureAnomaliesRefused() throws {
        guard Self.helperReady else { return }
        let cf = try CollabFixture()
        let reader = try Self.reader(cf)
        typealias B = RevisionBuild
        let clean = PDFBuild.zlib(PDFBuild.text("hello"))
        func additive(_ revisions: Int) -> Data {
            var file = B.build(B.base(B.stream(4, clean)))
            for k in 1..<revisions {
                file = B.update(file, objects: [B.obj(5 + k, "<< /Note (revision \(k)) >>")], entries: [(5 + k, 0, { $0[0] })], size: 6 + k)
            }
            return file.data
        }
        #expect(try check(cf, additive(8), canonical: "eight.pdf", archives: reader) == .clean)
        #expect(throws: Self.unaccounted) { try check(cf, additive(9), canonical: "nine.pdf", archives: reader) }
        let base = B.build(B.base(B.stream(4, clean)))
        let rewritten = B.update(base, objects: [B.obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Courier >>")],
                                 entries: [(5, 0, { $0[0] })], size: 6).data
        #expect(throws: Self.unaccounted) { try check(cf, rewritten, canonical: "rewritten.pdf", archives: reader) }
        let unknown = B.build(B.base(B.stream(4, clean)), unlisted: [B.obj(9, "<< /Note (nobody names me) >>")]).data
        #expect(throws: Self.unaccounted) { try check(cf, unknown, canonical: "unknown.pdf", archives: reader) }
        #expect(SandboxedPDFReader.unaccounted.message == "this PDF's structure couldn't be verified")
    }

    /// R4-4 (R3-7 and R3-3's escape): the helper runs as itself (no shell, no `head`), as the leader of its own session,
    /// under a profile that lets it run nothing else and fork nothing; its output is the engine's pipe, cut at the cap (the
    /// run killed); its exit status is its own. Stand-ins run as the helper under the real Seatbelt (`HelperProbe`).
    @Test func helperRunsAloneInItsOwnSession() throws {
        let cf = try CollabFixture()
        let held = URL(fileURLWithPath: "/private/tmp/held"), out = URL(fileURLWithPath: "/private/tmp/out")
        let policy = SandboxedPDFReader.policy(helper: URL(fileURLWithPath: "/opt/h/brahma-pdf"), held: held, out: out, memoryLimit: 1 << 30)
        let profile = SeatbeltProfile.render(policy: policy, baseline: SandboxBaseline.current(paths: cf.paths, otherWorkspaces: [], backupTargets: []),
                                             proxyPort: nil, marker: "dev.brahma.run.test")
        #expect(profile.contains("(allow process-exec (literal \"/opt/h/brahma-pdf\"))"))
        #expect(!profile.contains("process-fork") && !profile.contains("/bin/sh") && !profile.contains("/usr/bin/head")
                && !profile.contains("/private/var/select"))
        #expect(!profile.contains("(allow file-write*"))
        // The reader hands the runner the helper's own argv and the cap; nothing is a shell command.
        let recorder = ScriptedRunner.Record()
        let good = Self.framed([(0x44, Data("BT (hello) Tj ET".utf8))])
        let scripted = SandboxedPDFReader(runner: ScriptedRunner(parts: good, outcome: CheckOutcome(exitCode: 0, timedOut: false, tail: ""), record: recorder),
                                          helper: URL(fileURLWithPath: "/opt/h/brahma-pdf"), scratch: { try cf.vault.makeTempDir() })
        #expect(try scripted.parts(of: PDFBuild.flate("hello"), maxBytes: 5000).count == 1)
        let argv = recorder.arguments
        #expect(argv.count == 4 && argv.first == "/opt/h/brahma-pdf" && argv.last == String(SandboxedPDFReader.memoryLimit))
        #expect(argv.count == 4 && argv[1].hasSuffix("/held/input.pdf") && argv[2] == "5000")
        #expect(recorder.stdoutCap == 5000 && recorder.commands == 0)

        guard Toolchain.seatbeltAvailable, let probe = HelperProbe.binary() else { return }
        let home = try Scratch.homeDir().resolvedForSandbox
        let sbPaths = BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
        let sbVault = Vault(paths: sbPaths, companyId: cf.c.id, content: ContentVault(paths: sbPaths))
        let probeReader = SandboxedPDFReader(runner: SeatbeltRunner(baseline: {
            SandboxBaseline.current(paths: sbPaths, otherWorkspaces: [], backupTargets: [])
        }, proxies: EgressProxyPool()), helper: probe, scratch: { try sbVault.makeTempDir() })
        func run(_ orders: String, maxBytes: Int = 10_000, timeout: Duration = .seconds(30)) throws -> [PDFPart] {
            try probeReader.parts(of: Data((orders + "\n").utf8), maxBytes: maxBytes, timeout: timeout)
        }
        // The probe is not vacuous: what the profile allows (a system file) is seen as allowed.
        #expect(throws: SandboxedPDFReader.unreadable) { try run("read /System/Library/CoreServices/SystemVersion.plist") }
        #expect(try run("").isEmpty)
        // Denied: fork, exec in place, spawn, leaving its session or group.
        for orders in ["fork", "exec /bin/sh", "exec /usr/bin/head", "exec /bin/cat", "spawn /bin/sh", "spawn /usr/bin/head", "setsid"] {
            #expect(throws: Never.self, "\(orders) was not denied") { _ = try run(orders) }
        }
        // Output past the cap: the engine kills the run and refuses (over the budget), well inside the time limit.
        var started = AwakeTime.uptime()
        #expect(throws: ArchiveMemberScan.overBudget) { try run("flood", maxBytes: 100_000) }
        #expect(AwakeTime.uptime() - started < 20)
        // A helper that never finishes is killed at the time limit.
        started = AwakeTime.uptime()
        #expect(throws: SandboxedPDFReader.tooLong) { try run("spin", timeout: .seconds(2)) }
        #expect(AwakeTime.uptime() - started < 25)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sbPaths.tmpDir.path).isEmpty)
    }

    /// R4-6 (a), ruling 35: the sandboxed unzip runs as the PDF helper does: `/usr/bin/unzip -p` itself (no shell, no
    /// `head`), the leader of its own session, under the same deny-default profile (nothing else runs, nothing forks, no
    /// network, no file written, only the held copy read), a memory watchdog on its own pid, and its output read by the engine
    /// up to the byte cap. All members come out of one run, in archive order, split by the sizes the central directory
    /// declares and each checked against its CRC-32. A stand-in run under the reader's own policy shows each denial.
    @Test func unzipRunsAloneInItsOwnSession() throws {
        let cf = try CollabFixture()
        let held = URL(fileURLWithPath: "/private/tmp/held"), out = URL(fileURLWithPath: "/private/tmp/out")
        let unzip = URL(fileURLWithPath: SandboxedUnzipReader.unzip)
        let policy = SandboxedUnzipReader.policy(unzip: unzip, held: held, out: out)
        let profile = SeatbeltProfile.render(policy: policy, baseline: SandboxBaseline.current(paths: cf.paths, otherWorkspaces: [], backupTargets: []),
                                             proxyPort: nil, marker: "dev.brahma.run.test")
        #expect(profile.contains("(deny default)") && !profile.contains("(allow default)"))
        #expect(profile.contains("(allow process-exec (literal \"/usr/bin/unzip\"))"))
        #expect(!profile.contains("process-fork") && !profile.contains("/bin/sh") && !profile.contains("/usr/bin/head"))
        #expect(!profile.contains("(allow file-write*") && !profile.contains("network-outbound"))
        #expect(policy.memoryLimit == SandboxedUnzipReader.memoryLimit)
        // One run: the argv, the cap, nothing through a shell; members split by size and checked by CRC.
        let zip = try SecretGateTests.zip { z in z.add("a.txt", "alpha"); z.add("b/[c].txt", "bravo charlie") }
        func scripted(_ parts: Data?, _ outcome: CheckOutcome, _ record: ScriptedRunner.Record? = nil) -> SandboxedUnzipReader {
            SandboxedUnzipReader(runner: ScriptedRunner(parts: parts, outcome: outcome, record: record), scratch: { try cf.vault.makeTempDir() })
        }
        let ok = CheckOutcome(exitCode: 0, timedOut: false, tail: "")
        let recorder = ScriptedRunner.Record()
        let members = try scripted(Data("alphabravo charlie".utf8), ok, recorder).members(of: zip, wanted: { _ in true }, limits: .standard)
        #expect(members.map(\.name) == ["a.txt", "b/[c].txt"] && members.map { String(decoding: $0.data, as: UTF8.self) } == ["alpha", "bravo charlie"])
        let argv = recorder.arguments
        #expect(argv.count == 5 && argv[0] == "/usr/bin/unzip" && argv[1] == "-p" && argv[2].hasSuffix("/held/archive.zip"))
        #expect(argv.count == 5 && argv[3] == "a.txt" && argv[4] == "b/[[]c].txt")
        #expect(recorder.stdoutCap == ArchiveLimits.standard.bytes && recorder.commands == 0)
        // The members out of order (same total, the split lands elsewhere: CRC), short, long, a failed unzip: unreadable;
        // past the cap: expands; out of time, no run.
        for (name, parts, outcome) in [("out of order", "bravo charlie" + "alpha", ok), ("one byte changed", "alphAbravo charlie", ok), ("short", "alphabravo", ok), ("long", "alphabravo charlie!", ok),
                                       ("failed", "alphabravo charlie", CheckOutcome(exitCode: 1, timedOut: false, tail: ""))] {
            #expect(throws: ArchiveReadError.unreadable, "\(name)") {
                try scripted(Data(parts.utf8), outcome).members(of: zip, wanted: { _ in true }, limits: .standard)
            }
        }
        #expect(throws: ArchiveReadError.expands) {
            try scripted(nil, CheckOutcome(exitCode: nil, timedOut: false, tail: GroupRun.outputExceeded)).members(of: zip, wanted: { _ in true }, limits: .standard)
        }
        #expect(throws: SandboxedUnzipReader.tooLong) {
            try scripted(nil, CheckOutcome(exitCode: nil, timedOut: true, tail: "")).members(of: zip, wanted: { _ in true }, limits: .standard)
        }
        #expect(throws: SandboxedUnzipReader.couldNotRun) {
            try scripted(nil, CheckOutcome(exitCode: nil, timedOut: false, tail: "")).members(of: zip, wanted: { _ in true }, limits: .standard)
        }

        guard Toolchain.seatbeltAvailable else { return }
        // Real zips and Office files still read through the real reader.
        let reader = try Self.reader(cf)
        let real = try reader.members(of: zip, wanted: { _ in true }, limits: .standard)
        #expect(real.map(\.name) == ["a.txt", "b/[c].txt"] && real.map { String(decoding: $0.data, as: UTF8.self) } == ["alpha", "bravo charlie"])
        let docx = try SecretGateTests.zip { z in
            z.add("[Content_Types].xml", "<Types/>")
            z.add("word/document.xml", "<w:document><w:body><w:p><w:r><w:t>Hello docx</w:t></w:r></w:p></w:body></w:document>")
        }
        #expect(try TextExtract.extract(kind: nil, ext: "docx", data: docx, archives: reader).contains("Hello docx"))
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") {
            let dir = try tempDir()
            for i in 0..<5 { try Data(String(repeating: "line \(i) of a deflated member\n", count: 40).utf8).write(to: dir.appending(path: "m\(i).txt")) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            p.currentDirectoryURL = dir
            p.arguments = ["-q", "-X", "-9", "out.zip"] + (0..<5).map { "m\($0).txt" }
            try p.run(); p.waitUntilExit()
            let deflated = try reader.members(of: try Data(contentsOf: dir.appending(path: "out.zip")), wanted: { _ in true }, limits: .standard)
            #expect(deflated.count == 5 && deflated.allSatisfy { $0.data.count == 40 * "line 0 of a deflated member\n".utf8.count })
        }
        // The reader's own policy with a stand-in in unzip's place: each of these is denied (the stand-in exits 0).
        guard let probe = HelperProbe.binary() else { return }
        let home = try Scratch.homeDir().resolvedForSandbox
        let sbPaths = BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
        let sbVault = Vault(paths: sbPaths, companyId: cf.c.id, content: ContentVault(paths: sbPaths))
        let runner = SeatbeltRunner(baseline: { SandboxBaseline.current(paths: sbPaths, otherWorkspaces: [], backupTargets: []) }, proxies: EgressProxyPool())
        let outside = home.appending(path: "outside.txt")
        try Data("not for unzip\n".utf8).write(to: outside)
        func run(_ orders: String) throws -> CheckOutcome {
            let dir = try sbVault.makeTempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let heldDir = dir.appending(path: "held", directoryHint: .isDirectory), outDir = dir.appending(path: "out", directoryHint: .isDirectory)
            for d in [heldDir, outDir] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: false) }
            let ordersFile = heldDir.appending(path: "archive.zip")
            try Data((orders + "\n").utf8).write(to: ordersFile)
            let p = SandboxedUnzipReader.policy(unzip: probe, held: heldDir.resolvedForSandbox, out: outDir.resolvedForSandbox)
            return runner.runProgramBlocking(arguments: [probe.path, ordersFile.resolvedForSandbox.path], cwd: outDir.resolvedForSandbox,
                                             environment: [:], timeout: .seconds(30), outputURL: dir.appending(path: "log"),
                                             stdoutURL: outDir.resolvedForSandbox.appending(path: "members"), stdoutCap: 10_000, policy: p)
        }
        #expect(try run("read /System/Library/CoreServices/SystemVersion.plist").exitCode == 1, "the stand-in sees what is allowed")
        for orders in ["fork", "exec /bin/sh", "exec /usr/bin/unzip", "spawn /bin/sh", "setsid", "connect 22", "read \(outside.path)",
                       "read /private/etc/hosts", "write \(home.appending(path: "unzip-wrote.txt").path)"] {
            #expect(try run(orders).exitCode == 0, "\(orders) was not denied")
        }
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: "unzip-wrote.txt").path))
    }

    /// R4-4 (R3-3): the memory watchdog follows the run's own process, not only its process group: a child that moved itself
    /// into another group (its parent's) and then grows is still stopped.
    @Test(.timeLimit(.minutes(2))) func memoryWatchdogFollowsTheLeader() throws {
        guard let probe = HelperProbe.binary() else { return }
        let dir = try tempDir()
        let orders = dir.appending(path: "orders")
        try Data("joinparent\nhog 700\n".utf8).write(to: orders)
        let started = AwakeTime.uptime()
        let outcome = GroupRun.run(executable: probe.path, arguments: [probe.path, orders.path], workingDirectory: dir, timeout: 30,
                                   outputURL: dir.appending(path: "log"), environment: [:], termGrace: 1,
                                   clock: { AwakeTime.uptime() }, cancel: GroupRun.CancelFlag(), memoryLimit: 128 << 20)
        #expect(outcome.tail.hasSuffix(GroupRun.memoryExceeded), "\(outcome)")
        #expect(AwakeTime.uptime() - started < 20)
    }

    static func framed(_ records: [(UInt8, Data)], count: Int? = nil) -> Data {
        var out = Data("BRAHMA-PDF/1\n".utf8)
        for (kind, payload) in records {
            let n = UInt32(payload.count)
            out += Data([kind, UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]) + payload
        }
        let c = UInt64(count ?? records.count)
        out += Data([0x45, 0, 0, 0, 8] + (0..<8).reversed().map { UInt8((c >> (8 * UInt64($0))) & 0xFF) })
        return out
    }
}

/// The reviewer's `v.py` (re-review 3) in Swift: PDFs built object by object, with incremental updates whose classic
/// cross-reference sections name any (number, generation, offset), and revisions that may end at `startxref` with no
/// `%%EOF`.
enum RevisionBuild {
    static func obj(_ n: Int, _ body: Data, gen: Int = 0) -> Data { Data("\(n) \(gen) obj\n".utf8) + body + Data("\nendobj\n".utf8) }
    static func obj(_ n: Int, _ body: String, gen: Int = 0) -> Data { obj(n, Data(body.utf8), gen: gen) }

    static func stream(_ n: Int, _ data: Data, gen: Int = 0) -> Data {
        obj(n, Data("<< /Filter /FlateDecode /Length \(data.count) >>\nstream\n".utf8) + data + Data("\nendstream".utf8), gen: gen)
    }

    /// Catalog (1), pages (2), a page (3) drawing `content` (object 4, given whole) in Helvetica (5).
    static func base(_ content: Data) -> [Data] {
        [obj(1, "<< /Type /Catalog /Pages 2 0 R >>"), obj(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
         obj(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"),
         content, obj(5, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")]
    }

    /// A first revision: the header, `parts` (object i + 1 is `parts[i]`), then `unlisted` (bodies no entry names), a classic
    /// table, the trailer, `startxref`, and `%%EOF` when `eof`.
    static func build(_ parts: [Data], unlisted: [Data] = [], eof: Bool = true) -> (data: Data, xref: Int) {
        var out = Data("%PDF-1.7\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for u in unlisted { out += u }
        for p in parts { offsets.append(out.count); out += p }
        let xref = out.count
        var table = "xref\n0 \(parts.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += PDFBuild.pad10(o) + " 00000 n \n" }
        table += "trailer\n<< /Size \(parts.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n" + (eof ? "%%EOF\n" : "")
        return (out + Data(table.utf8), xref)
    }

    /// `previous` plus an update holding `objects`; its table names each entry (number, generation, offset), the offset a
    /// function of the new objects' offsets.
    static func update(_ previous: (data: Data, xref: Int), objects: [Data], entries: [(Int, Int, ([Int]) -> Int)], size: Int,
                       eof: Bool = true) -> (data: Data, xref: Int) {
        var out = previous.data
        var offsets: [Int] = []
        for o in objects { offsets.append(out.count); out += o }
        let xref = out.count
        var table = "xref\n0 1\n0000000000 65535 f \n"
        for (n, g, offset) in entries {
            table += "\(n) 1\n\(PDFBuild.pad10(offset(offsets))) \(String(repeating: "0", count: 5 - String(g).count))\(g) n \n"
        }
        table += "trailer\n<< /Size \(size) /Root 1 0 R /Prev \(previous.xref) >>\nstartxref\n\(xref)\n" + (eof ? "%%EOF\n" : "")
        return (out + Data(table.utf8), xref)
    }
}

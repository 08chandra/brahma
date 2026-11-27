import Testing
import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// Plan C Task C5 (named apart from the handbook's `ExportTests`): the owner's Save As (`Store.exportRef`): owner-chosen
/// folders only, the secret gate again, the download mark, sanitized names, and the activity and read records.
@Suite(.scratch) struct RefExportTests {
    static let known: [(name: String, value: String)] = [("DEPLOY_TOKEN", "tok-zebra-quokka-991")]

    @Test(arguments: [("notes\u{202E}txt.exe", "exe", "notestxt.exe"), ("photo.png", "html", "photo.png.html"), ("a/b:c", "txt", "a-b-c.txt")])
    func exportSanitizesName(_ d: String, _ e: String, _ out: String) { #expect(ExportName.sanitize(d, realExt: e) == out) }

    @Test func exportNameEdges() {
        #expect(ExportName.sanitize("a\\b", realExt: "md") == "a-b.md")
        #expect(ExportName.sanitize("..", realExt: "md") == "file.md")
        #expect(ExportName.sanitize("REPORT.PDF", realExt: "pdf") == "REPORT.PDF")
        #expect(ExportName.sanitize("x", realExt: "p\u{202E}d/f") == "x.pdf")
        #expect(ExportName.sanitize("x.md", realExt: "") == "x.md")
        #expect(ExportName.sanitize(String(repeating: "n", count: 300), realExt: "txt").count == 124)
    }

    func refusal(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    func export(_ cf: CollabFixture, _ ref: WorkRef, to url: URL, known: [(name: String, value: String)] = []) throws -> URL {
        try cf.store.exportRef(companyId: cf.c.id, ref: ref, to: url, knownValues: known, paths: cf.paths, now: cf.now)
    }

    func activity(_ cf: CollabFixture, _ kind: ActivityKind) throws -> [String] {
        let cId = cf.c.id
        return try cf.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM activityEvent WHERE companyId = ? AND kind = ? ORDER BY rowid",
                                arguments: [cId, kind.rawValue])
        }
    }

    @Test func exportSetsQuarantineAndSanitizesName() throws {
        let cf = try CollabFixture()
        try cf.addResource(21, name: "notes.md", ext: "md", bytes: Data("# Notes\n".utf8), provenance: .external("doc-type"),
                           tainted: true, taintReason: "outside")
        let out = try tempDir()
        let written = try export(cf, WorkRef(kind: .resource, id: "21"), to: out.appending(path: "my\u{202E}notes.txt"))
        #expect(written.lastPathComponent == "mynotes.txt.md")
        #expect(try Data(contentsOf: written) == Data("# Notes\n".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["mynotes.txt.md"], "no temporary file is left")
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: 256)
        let n = getxattr(written.path, "com.apple.quarantine", &buffer, buffer.count, 0, XATTR_NOFOLLOW)
        #expect(n > 0)
        let mark = String(decoding: buffer.prefix(max(0, n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #expect(mark.hasPrefix("0081;") && mark.hasSuffix(";Brahma;"), "\(mark)")
        #expect(Quarantine.isQuarantined(written))
        #endif
        #expect(try activity(cf, .export) == ["ownerExport F-21"])
        let reads = try cf.reads("F-21")
        #expect(reads.count == 1 && reads[0].via == "export" && reads[0].readerKind == "owner" && reads[0].tainted && reads[0].bytes == 8)
        // Saving again replaces the file (the owner confirmed it in the save panel).
        _ = try export(cf, WorkRef(kind: .resource, id: "21"), to: written)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["mynotes.txt.md"])
    }

    @Test func exportRefusesBrahmaPlaces() throws {
        let cf = try CollabFixture()
        try cf.addResource(21, name: "notes.md", ext: "md", bytes: Data("# Notes\n".utf8))
        let ref = WorkRef(kind: .resource, id: "21")
        let refusal = "Brahma doesn't save exports inside its own data folder or a company workspace; choose another folder"
        let elsewhere = try tempDir().appending(path: "x/.brahma", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cf.paths.home, withIntermediateDirectories: true)
        for dir in [cf.workspace, cf.workspace.appending(path: "src"), cf.workspace.appending(path: ".brahma"), cf.paths.home, elsewhere,
                    URL(fileURLWithPath: cf.fx.d.workspacePath)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #expect(self.refusal { try export(cf, ref, to: dir.appending(path: "out.md")) } == refusal, "\(dir.path)")
        }
        // A link to the workspace is the workspace.
        let link = try tempDir().appending(path: "ws-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cf.workspace)
        #expect(self.refusal { try export(cf, ref, to: link.appending(path: "out.md")) } == refusal)
        // A folder that doesn't exist; a folder already at the name.
        let out = try tempDir()
        #expect(self.refusal { try export(cf, ref, to: out.appending(path: "nope/out.md")) } == "the folder to save in doesn't exist")
        try FileManager.default.createDirectory(at: out.appending(path: "taken.md"), withIntermediateDirectories: true)
        #expect(self.refusal { try export(cf, ref, to: out.appending(path: "taken.md")) }?.hasPrefix("a folder named taken.md") == true)
        #expect(try activity(cf, .export).isEmpty)
        // Live records and other companies' refs have nothing to export.
        #expect(self.refusal { try export(cf, WorkRef(kind: .agent, id: "eng-1"), to: out.appending(path: "a.txt")) }?
            .hasSuffix("is a live record with no file to export") == true)
        #expect(self.refusal { try export(cf, WorkRef(kind: .resource, id: "999"), to: out.appending(path: "a.txt")) } == Store.refUnavailable)
    }

    @Test func exportRescansSecrets() throws {
        let cf = try CollabFixture()
        let out = try tempDir()
        // A value stored after the file was added: the export is refused and nothing is written.
        try cf.addResource(21, name: "env.txt", ext: "txt", bytes: Data("TOKEN=tok-zebra-quokka-991\n".utf8))
        let refused = refusal { try export(cf, WorkRef(kind: .resource, id: "21"), to: out.appending(path: "env.txt"), known: Self.known) }
        #expect(refused?.contains("contains a stored secret") == true, "\(refused ?? "")")
        #expect(refused?.contains("tok-zebra") == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        // A secret pattern in text: the redacted copy is what's written.
        try cf.addResource(22, name: "aws.txt", ext: "txt", bytes: Data("key AKIAIOSFODNN7EXAMPLE end\n".utf8))
        let written = try export(cf, WorkRef(kind: .resource, id: "22"), to: out.appending(path: "aws.txt"), known: Self.known)
        let text = String(decoding: try Data(contentsOf: written), as: UTF8.self)
        #expect(!text.contains("AKIAIOSFODNN7EXAMPLE") && text.contains("[redacted"), "\(text)")
        // A PDF with no helper to check it: refused (fail closed).
        try cf.addResource(23, name: "deck.pdf", ext: "pdf", bytes: try Data(contentsOf: try resourceFixture("sample.pdf")))
        #expect(refusal { try export(cf, WorkRef(kind: .resource, id: "23"), to: out.appending(path: "deck.pdf")) } != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path) == ["aws.txt"])
    }

    @Test func diffExportsAsPatch() throws {
        let cf = try CollabFixture()
        let out = try tempDir()
        let written = try export(cf, WorkRef(kind: .diff, id: "ENG-1"), to: out.appending(path: "ENG-1 changes"))
        #expect(written.lastPathComponent == "ENG-1 changes.patch")
        let patch = String(decoding: try Data(contentsOf: written), as: UTF8.self)
        #expect(patch.contains("diff --git a/src/a.ts b/src/a.ts") && patch.contains("+TWO"), "\(patch)")
        #expect(try activity(cf, .export) == ["ownerExport \(WorkRef(kind: .diff, id: "ENG-1").canonical)"])
        #expect(try cf.reads(WorkRef(kind: .diff, id: "ENG-1").canonical).first?.via == "export")
    }

    @Test func artifactFolderExportsAsZip() throws {
        let cf = try CollabFixture()
        let dir = cf.workspace.appending(path: "site", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir.appending(path: "css"), withIntermediateDirectories: true)
        try Data("<link href=css/a.css>".utf8).write(to: dir.appending(path: "index.html"))
        try Data("p{}".utf8).write(to: dir.appending(path: "css/a.css"))
        let artifact = try cf.store.publishArtifact(companyId: cf.c.id, by: .owner, sourcePath: "site", title: "Site", itemKey: nil,
                                                    baseDirectory: cf.workspace)
        let out = try tempDir()
        #if canImport(Darwin)
        let written = try export(cf, WorkRef(kind: .artifact, id: String(artifact.number)), to: out.appending(path: "site"))
        #expect(written.lastPathComponent == "site.zip")
        let zip = try Data(contentsOf: written)
        #expect(zip.prefix(2) == Data("PK".utf8))
        let listed = String(decoding: zip, as: UTF8.self)
        #expect(listed.contains("index.html") && listed.contains("css/a.css"))
        #else
        #expect(refusal { try export(cf, WorkRef(kind: .artifact, id: String(artifact.number)), to: out.appending(path: "site")) }
            == "folder export needs macOS")
        #endif
    }

    // MARK: Fix round 1

    /// Ruling (1): a purge lists every copy the owner exported, by path, as copies outside Brahma to delete.
    @Test func purgeListsExportedCopies() throws {
        let cf = try CollabFixture()
        try cf.addResource(21, name: "notes.md", ext: "md", bytes: Data("# Notes\n".utf8))
        let ref = WorkRef(kind: .resource, id: "21")
        let first = try export(cf, ref, to: try tempDir().appending(path: "notes.md"))
        let second = try export(cf, ref, to: try tempDir().appending(path: "copy.md"))
        #expect(try cf.reads("F-21").compactMap(\.exportPath).sorted() == [first.path, second.path].sorted())
        let report = try cf.store.purge(companyId: cf.c.id, ref: ref, contentVault: ContentVault(paths: cf.paths), paths: cf.paths, now: cf.now, owner: try OwnerPrincipal.mint())
        #expect(report.exportedCopies.sorted() == [first.path, second.path].sorted())
        let notices = try cf.store.undeliveredNotices().filter { $0.title == Store.exportedCopiesTitle }
        #expect(notices.count == 2, "\(notices.map(\.body))")
        #expect(notices.map(\.body).sorted() == [first.path, second.path].map { "you exported F-21 to \($0) · Brahma can't delete it; delete it if you no longer need it" }.sorted())
    }

    /// Ruling (3): the folder is opened once (no link anywhere on the way) and written through that descriptor; a folder moved
    /// or replaced before the write fails closed, and a link planted at the name is replaced, never followed.
    @Test func exportSurvivesFolderAndNameSwaps() throws {
        let cf = try CollabFixture()
        try cf.addResource(21, name: "notes.md", ext: "md", bytes: Data("# Notes\n".utf8))
        let ref = WorkRef(kind: .resource, id: "21")
        let fm = FileManager.default
        // A link planted at the target name: replaced by the file; what it pointed at is untouched.
        let out = try tempDir()
        let victim = try tempDir().appending(path: "victim.md")
        try Data("keep".utf8).write(to: victim)
        try fm.createSymbolicLink(at: out.appending(path: "notes.md"), withDestinationURL: victim)
        let written = try export(cf, ref, to: out.appending(path: "notes.md"))
        #expect(try Data(contentsOf: victim) == Data("keep".utf8))
        #expect(try fm.attributesOfItem(atPath: written.path)[.type] as? FileAttributeType == .typeRegular)
        // A link anywhere on the way to the folder: refused when it is opened (the real path is walked without following).
        // The folder swapped for a link after it was opened: nothing is saved, in either place.
        let base = try tempDir()
        let chosen = base.appending(path: "chosen", directoryHint: .isDirectory)
        let moved = base.appending(path: "moved", directoryHint: .isDirectory)
        let elsewhere = try tempDir()
        try fm.createDirectory(at: chosen, withIntermediateDirectories: true)
        let (chosenPath, movedPath, elsewherePath) = (chosen.path, moved.path, elsewhere.path)
        cf.store.refHooks.setAfterExportFolderOpened {
            try FileManager.default.moveItem(atPath: chosenPath, toPath: movedPath)
            try FileManager.default.createSymbolicLink(atPath: chosenPath, withDestinationPath: elsewherePath)
        }
        let refused = refusal { try export(cf, ref, to: chosen.appending(path: "notes.md")) }
        cf.store.refHooks.setAfterExportFolderOpened(nil)
        #expect(refused == "the folder to save in was moved or replaced while saving; nothing was saved")
        #expect(try fm.contentsOfDirectory(atPath: elsewherePath).isEmpty)
        #expect(try fm.contentsOfDirectory(atPath: movedPath).isEmpty)
        #expect(try activity(cf, .export).count == 1, "only the first export is recorded")
    }

    /// Review I2 (both purge entry points): ML's own `purgeResource` (what the app and the CLI call) lists the exports too.
    @Test func resourcePurgeListsExportedCopies() throws {
        let cf = try CollabFixture()
        try cf.addResource(21, name: "notes.md", ext: "md", bytes: Data("# Notes\n".utf8))
        let written = try export(cf, WorkRef(kind: .resource, id: "21"), to: try tempDir().appending(path: "notes.md"))
        let report = try cf.store.purgeResource(companyId: cf.c.id, number: 21, backups: [], contentVault: ContentVault(paths: cf.paths),
                                                paths: cf.paths, now: cf.now)
        #expect(report.exports == [written.path])
        #expect(try cf.store.undeliveredNotices().filter { $0.title == Store.exportedCopiesTitle }.map(\.body)
            == ["you exported F-21 to \(written.path) · Brahma can't delete it; delete it if you no longer need it"])
        // An old tombstone's report (no `exports` key) still reads.
        let old = try JSONDecoder().decode(PurgeReport.self, from: Data(#"{"backups":["b"],"transcripts":[]}"#.utf8))
        #expect(old == PurgeReport(backups: ["b"], transcripts: []))
    }

    /// Review M1: an export whose record can't be written leaves no file (it would be a copy no purge could list).
    @Test func exportWithoutRecordLeavesNoFile() throws {
        let cf = try CollabFixture()
        try cf.addResource(21, name: "notes.md", ext: "md", bytes: Data("# Notes\n".utf8))
        try cf.store.writer.write { db in try db.execute(sql: "DROP TABLE refRead") }
        let out = try tempDir()
        #expect(refusal { try export(cf, WorkRef(kind: .resource, id: "21"), to: out.appending(path: "notes.md")) } != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).isEmpty)
        #expect(try activity(cf, .export).isEmpty)
    }

    /// Review I4 (Ruling 42): a PDF the owner vouched for exports its flattened copy, never the original.
    @Test func vouchedPDFExportsFlattenedCopy() throws {
        let cf = try CollabFixture()
        let pdf = Data("%PDF-1.7 vouched for export".utf8)
        try cf.addResource(23, name: "deck.pdf", ext: "pdf", bytes: pdf)
        let ref = WorkRef(kind: .resource, id: "23")
        let out = try tempDir()
        func save() throws -> URL {
            try cf.store.exportRef(companyId: cf.c.id, ref: ref, to: out.appending(path: "deck"), knownValues: [], paths: cf.paths,
                                   archives: FlattenOnlyReader(), now: cf.now)
        }
        #expect(refusal { try save() } != nil, "its structure can't be verified: refused until vouched")
        _ = try cf.store.vouchFile(companyId: cf.c.id, canonical: ref.canonical, sha256: SHA256.hex(pdf), now: cf.now)
        let written = try save()
        let bytes = try Data(contentsOf: written)
        #expect(written.lastPathComponent == "deck.pdf")
        #expect(bytes.starts(with: FlattenOnlyReader.copyMark) && bytes != pdf && !bytes.contains(pdf))
        #expect(try cf.reads("F-23").first?.via == "export")
    }

    /// Fix round 1 (controller): never into config other tools execute, inside a workspace or not, whatever the case, and
    /// not through a link to such a folder.
    @Test func exportRefusesToolConfigPlaces() throws {
        let cf = try CollabFixture()
        try cf.addResource(21, name: "notes.md", ext: "md", bytes: Data("# Notes\n".utf8))
        let ref = WorkRef(kind: .resource, id: "21")
        let fm = FileManager.default
        let base = try tempDir()
        var targets: [URL] = []
        for dir in [".claude", ".Git", ".github/Workflows", "x/.CLAUDE/commands"] {
            let url = base.appending(path: dir, directoryHint: .isDirectory)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            targets.append(url.appending(path: "out.md"))
        }
        let link = base.appending(path: "innocent")
        try fm.createSymbolicLink(at: link, withDestinationURL: base.appending(path: ".claude"))
        targets.append(link.appending(path: "out.md"))
        let plain = base.appending(path: "plain", directoryHint: .isDirectory)
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        targets += [plain.appending(path: "CLAUDE.md"), plain.appending(path: "claude"), plain.appending(path: ".MCP.json")]
        for url in targets {
            #expect(refusal { try export(cf, ref, to: url) } == Store.toolConfigRefusal, "\(url.path)")
        }
        #expect(try fm.contentsOfDirectory(atPath: plain.path).isEmpty)
        #expect(try activity(cf, .export).isEmpty)
        // `.github` alone is fine.
        let github = base.appending(path: ".github", directoryHint: .isDirectory)
        _ = try export(cf, ref, to: github.appending(path: "notes.md"))
    }

    // MARK: Fix round 2

    /// Re-review N1: exports of a pinned file and a pinned diff (canonical with `@<rev>`) are listed by their purge.
    @Test func purgeOfPinsListsTheirExports() throws {
        let cf = try CollabFixture()
        let out = try tempDir()
        var written: [WorkRef: URL] = [:]
        for (raw, id) in [("ENG-1:src/a.ts", "mr-f"), ("ENG-1:diff", "mr-d")] {
            let pinned = try cf.store.pinRef(try cf.fx.ref(raw), for: .owner, companyId: cf.c.id, messageRefId: id, knownValues: [],
                                             paths: cf.paths)
            #expect(pinned.rev != nil && pinned.canonical.contains("@"), "\(pinned.canonical)")
            // A message carries it as purge finds it (its canonical form without the pin).
            var carried = pinned
            carried.rev = nil
            try PurgeTests.record(cf, carried, id: id, at: cf.now)
            written[pinned] = try export(cf, pinned, to: out.appending(path: id))
        }
        for (pinned, url) in written {
            let report = try cf.store.purge(companyId: cf.c.id, ref: pinned, contentVault: ContentVault(paths: cf.paths), paths: cf.paths,
                                            now: cf.now, owner: try OwnerPrincipal.mint())
            #expect(report.exportedCopies == [url.path], "\(pinned.canonical)")
        }
    }

    /// Re-review N2: config names are matched with a Unicode case fold (long s, fullwidth, other cases), not `lowercased()`.
    @Test func toolConfigNamesFoldCase() throws {
        let cf = try CollabFixture()
        try cf.addResource(21, name: "notes.md", ext: "md", bytes: Data("# Notes\n".utf8))
        let ref = WorkRef(kind: .resource, id: "21")
        let base = try tempDir()
        var targets = [".mcp.j\u{17F}on", "\u{FF23}LAUDE.md", "CLAUDE.M\u{FF24}", "\u{FF0E}mcp.json"].map { base.appending(path: $0) }
        for dir in [".\u{FF23}laude", ".gi\u{FF54}", ".github/\u{FF37}ork\u{FB02}ows"] {
            let url = base.appending(path: dir, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            targets.append(url.appending(path: "out.md"))
        }
        for url in targets {
            #expect(refusal { try export(cf, ref, to: url) } == Store.toolConfigRefusal, "\(url.path)")
        }
    }
}

/// A PDF reader that verifies nothing but its own flattened copies (as `FlaggedPDFReader` in the app's tests).
struct FlattenOnlyReader: ArchiveReader {
    static let copyMark = Data("%PDF-1.3 flattened for export ".utf8)

    func members(of data: Data, wanted: @Sendable (String) -> Bool, limits: ArchiveLimits) throws -> [(name: String, data: Data)] {
        throw ArchiveReadError.refused("no archives here")
    }

    func pdfParts(of data: Data, maxBytes: Int, timeout: Duration) throws -> [PDFPart] {
        if data.starts(with: Self.copyMark) { return [PDFPart(kind: .pageText, data: Data("hello".utf8))] }
        throw UnverifiedPDF(parts: [])
    }

    func flattenPDF(of data: Data, maxBytes: Int, timeout: Duration) throws -> Data { Self.copyMark + Data(SHA256.hex(data).utf8) }
}

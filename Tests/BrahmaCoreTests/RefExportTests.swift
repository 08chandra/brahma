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
}

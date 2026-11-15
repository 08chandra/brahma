import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

@Suite(.scratch) struct ResourceIntakeTests {
    private let fm = FileManager.default
    private let executables = "executables can't be added as resources"

    private func write(_ text: String, _ url: URL) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func write(bytes: [UInt8], _ url: URL) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    /// A sparse file of `size` bytes that starts with `header`.
    private func sparse(_ url: URL, size: UInt64, header: Data) throws -> URL {
        try header.write(to: url)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: size)
        try h.close()
        return url
    }

    private func inspect(_ urls: URL..., known: [(name: String, value: String)] = []) throws -> DropPlan {
        try ResourceIntake.inspect(urls: urls, knownValues: known)
    }

    private func reasons(_ plan: DropPlan) -> [String] { plan.refusals.map(\.reason) }

    @Test func symlinkRefused() throws {
        let dir = try tempDir(), outside = try tempDir()
        _ = try write("ssh-ed25519 AAAA secret", outside.appending(path: "id_ed25519.txt"))
        let link = dir.appending(path: "ssh")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let fileLink = dir.appending(path: "notes.md")
        try fm.createSymbolicLink(at: fileLink, withDestinationURL: outside.appending(path: "id_ed25519.txt"))

        let plan = try inspect(link, fileLink)
        #expect(plan.items.isEmpty)
        #expect(plan.refusals.map(\.name) == ["ssh", "notes.md"])
        #expect(reasons(plan) == ["symlinks can't be added", "symlinks can't be added"])

        // Inside a folder: the link (to a file or a directory) is skipped and listed, never followed.
        let folder = dir.appending(path: "proj")
        _ = try write("# hi", folder.appending(path: "a.md"))
        try fm.createSymbolicLink(at: folder.appending(path: "keys"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: folder.appending(path: "b.txt"), withDestinationURL: outside.appending(path: "id_ed25519.txt"))
        let inner = try inspect(folder)
        #expect(inner.items.map(\.relativePath) == ["proj/a.md"])
        #expect(Set(inner.skipped) == ["proj/keys", "proj/b.txt"])
        #expect(inner.refusals.isEmpty)
        #expect(inner.folderName == "proj")
    }

    @Test func gitDirExcluded() throws {
        let dir = try tempDir()
        let folder = dir.appending(path: "repo")
        _ = try write("[core]", folder.appending(path: ".git/config"))
        _ = try write("ref: refs/heads/main", folder.appending(path: ".git/HEAD"))
        _ = try write("junk", folder.appending(path: ".DS_Store"))
        _ = try write("junk", folder.appending(path: "src/.DS_Store"))
        _ = try write("let x = 1", folder.appending(path: "src/main.swift"))
        _ = try write("# readme", folder.appending(path: "README.md"))
        let plan = try inspect(folder)
        #expect(plan.items.map(\.relativePath).sorted() == ["repo/README.md", "repo/src/main.swift"])
        #expect(plan.skipped == ["repo/.git"])
        #expect(plan.refusals.isEmpty)
        #expect(plan.items.allSatisfy { $0.root.standardizedFileURL.path == dir.standardizedFileURL.path })

        // Depth: a directory more than 12 levels below the folder is skipped and listed.
        let deep = dir.appending(path: "deep")
        var path = deep
        for i in 1...13 { path = path.appending(path: "d\(i)") }
        _ = try write("deep", path.appending(path: "x.txt"))
        _ = try write("shallow", deep.appending(path: "d1/y.txt"))
        let d = try inspect(deep)
        #expect(d.items.map(\.relativePath) == ["deep/d1/y.txt"])
        #expect(d.skipped == ["deep/d1/d2/d3/d4/d5/d6/d7/d8/d9/d10/d11/d12/d13"])
    }

    @Test func folderCaps() throws {
        let dir = try tempDir()
        let many = dir.appending(path: "many")
        try fm.createDirectory(at: many, withIntermediateDirectories: true)
        for i in 0...500 { try Data("n".utf8).write(to: many.appending(path: "f\(i).txt")) }
        let plan = try inspect(many)
        #expect(plan.items.isEmpty)
        #expect(plan.refusals.map(\.name) == ["many"])
        #expect(reasons(plan) == ["folders are limited to 500 files and 200 MB"])
        #expect(plan.folderName == nil)

        // Exactly 500 files is fine.
        try fm.removeItem(at: many.appending(path: "f500.txt"))
        let full = try inspect(many)
        #expect(full.items.count == 500)
        #expect(full.folderName == "many")

        // Over 200 MB in total (sparse files, each under the per-file cap).
        let big = dir.appending(path: "big")
        try fm.createDirectory(at: big, withIntermediateDirectories: true)
        for i in 0..<5 { _ = try sparse(big.appending(path: "p\(i).pdf"), size: 45 * 1_048_576, header: Data("%PDF-1.4\n".utf8)) }
        let heavy = try inspect(big)
        #expect(heavy.items.isEmpty)
        #expect(reasons(heavy) == ["folders are limited to 500 files and 200 MB"])
    }

    @Test func perFileCaps() throws {
        let dir = try tempDir()
        let pdf = try sparse(dir.appending(path: "huge.pdf"), size: 51 * 1_048_576, header: Data("%PDF-1.4\n".utf8))
        let refused = try inspect(pdf)
        #expect(refused.items.isEmpty)
        #expect(reasons(refused) == ["huge.pdf is over the 50 MB limit"])

        var ftyp = Data([0, 0, 0, 24]); ftyp.append(Data("ftypisom".utf8)); ftyp.append(Data([0, 0, 2, 0])); ftyp.append(Data("isomiso2".utf8))
        let video = try sparse(dir.appending(path: "talk.mp4"), size: 400 * 1_048_576, header: ftyp)
        let ok = try inspect(video)
        #expect(ok.refusals.isEmpty)
        #expect(ok.items.count == 1)
        #expect(ok.items.first?.fileKind == "video")
        #expect(ok.items.map(\.bytes) == [400 * 1_048_576])
        #expect(ok.totalBytes == 400 * 1_048_576)

        let tooLong = try sparse(dir.appending(path: "long.mov"), size: 501 * 1_048_576, header: ftyp)
        #expect(reasons(try inspect(tooLong)) == ["long.mov is over the 500 MB limit"])
    }

    @Test func executablesRefused() throws {
        let dir = try tempDir()
        let macho = try write(bytes: [0xCF, 0xFA, 0xED, 0xFE, 7, 0, 0, 1], dir.appending(path: "notes.txt"))
        let fat = try write(bytes: [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2], dir.appending(path: "lib.md"))
        let elf = try write(bytes: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1], dir.appending(path: "run.log"))
        let pe = try write("MZ this is a windows program", dir.appending(path: "data.csv"))
        let exe = try write("hello", dir.appending(path: "setup.exe"))
        let command = try write("echo hi", dir.appending(path: "go.command"))
        let app = dir.appending(path: "Thing.app")
        _ = try write("<plist/>", app.appending(path: "Contents/Info.plist"))
        let plan = try inspect(macho, fat, elf, pe, exe, command, app)
        #expect(plan.items.isEmpty)
        #expect(plan.refusals.map(\.name) == ["notes.txt", "lib.md", "run.log", "data.csv", "setup.exe", "go.command", "Thing.app"])
        #expect(reasons(plan) == Array(repeating: executables, count: 7))

        // Inside a folder: the executable and the bundle are refused, the rest is kept.
        let folder = dir.appending(path: "kit")
        _ = try write(bytes: [0xFE, 0xED, 0xFA, 0xCF, 0, 0], folder.appending(path: "tool.json"))
        _ = try write("<plist/>", folder.appending(path: "Plug.bundle/Contents/Info.plist"))
        _ = try write("fine", folder.appending(path: "ok.txt"))
        let inner = try inspect(folder)
        #expect(inner.items.map(\.relativePath) == ["kit/ok.txt"])
        #expect(Set(inner.refusals.map(\.name)) == ["kit/tool.json", "kit/Plug.bundle"])
        #expect(Set(reasons(inner)) == [executables])
    }

    @Test func unknownExtensionAndPlaylistRefused() throws {
        let dir = try tempDir()
        let xyz = try write("?", dir.appending(path: "a.xyz"))
        let m3u8 = try write("#EXTM3U", dir.appending(path: "live.m3u8"))
        let mpd = try write("<MPD/>", dir.appending(path: "dash.MPD"))
        let bare = try write("all:", dir.appending(path: "Makefile"))
        let plan = try inspect(xyz, m3u8, mpd, bare)
        #expect(plan.items.isEmpty)
        #expect(reasons(plan) == [
            ".xyz files aren't supported as resources (allowed: documents, images, video, tables, 3D, text and code, .zip)",
            "streaming playlists can't be added; add the video file",
            "streaming playlists can't be added; add the video file",
            "files without an extension aren't supported as resources (allowed: documents, images, video, tables, 3D, text and code, .zip)",
        ])
    }

    @Test func magicMismatchRefused() throws {
        let dir = try tempDir()
        let fakePDF = try write("<!doctype html><script>alert(1)</script>", dir.appending(path: "invoice.pdf"))
        let nulPy = try write("print('hi')\u{0}\n", dir.appending(path: "x.py"))
        let fakePNG = try write("GIF89a....", dir.appending(path: "pic.png"))
        let fakeZip = try write("not a zip", dir.appending(path: "a.zip"))
        let plan = try inspect(fakePDF, nulPy, fakePNG, fakeZip)
        #expect(plan.items.isEmpty)
        #expect(reasons(plan) == [
            "the file's content doesn't match .pdf", "the file's content doesn't match .py",
            "the file's content doesn't match .png", "the file's content doesn't match .zip",
        ])
        // The real thing passes.
        let real = dir.appending(path: "real.pdf")
        try fm.copyItem(at: try resourceFixture("sample.pdf"), to: real)
        #expect(try inspect(real).items.map(\.fileKind) == ["pdf"])
    }

    @Test func zipBombRefused() throws {
        let dir = try tempDir()
        let bomb = try ZipFixture.write([.init(name: "big.bin", claimedUncompressed: 1_000_000_000)], to: dir.appending(path: "bomb.zip"))
        let many = try ZipFixture.write((0...10_000).map { .init(name: "f\($0)") }, to: dir.appending(path: "many.zip"))
        let plan = try inspect(bomb, many)
        #expect(plan.items.isEmpty)
        #expect(reasons(plan) == ["this archive expands too much", "this archive expands too much"])

        let fine = try ZipFixture.write([.init(name: "a.txt", data: Data(repeating: 65, count: 64))], to: dir.appending(path: "ok.zip"))
        let ok = try inspect(fine)
        #expect(ok.items.map(\.fileKind) == ["archive"])
        #expect(ok.items.first?.isText == false)
    }

    @Test func zipUnsafeEntryRefused() throws {
        let dir = try tempDir()
        let dots = try ZipFixture.write([.init(name: "../../.ssh/authorized_keys")], to: dir.appending(path: "dots.zip"))
        let link = try ZipFixture.write([.init(name: "home", symlink: true)], to: dir.appending(path: "link.zip"))
        let abs = try ZipFixture.write([.init(name: "/etc/hosts")], to: dir.appending(path: "abs.zip"))
        let plan = try inspect(dots, link, abs)
        #expect(plan.items.isEmpty)
        #expect(reasons(plan) == Array(repeating: "this archive contains unsafe paths", count: 3))
    }

    @Test func otherArchivesRefused() throws {
        let dir = try tempDir()
        let urls = try ["a.tar", "b.tar.gz", "c.tgz", "d.bz2", "e.xz", "f.7z", "g.rar"].map { try write("x", dir.appending(path: $0)) }
        let plan = try ResourceIntake.inspect(urls: urls, knownValues: [])
        #expect(plan.items.isEmpty)
        #expect(reasons(plan) == Array(repeating: "only .zip archives can be added", count: 7))
    }

    @Test func docTypeDropDefaultsTainted() throws {
        let dir = try tempDir()
        let pdf = dir.appending(path: "report.pdf"), docx = dir.appending(path: "Plan.DOCX")
        try fm.copyItem(at: try resourceFixture("sample.pdf"), to: pdf)
        try fm.copyItem(at: try resourceFixture("sample.docx"), to: docx)
        let zip = try ZipFixture.write([.init(name: "a.txt")], to: dir.appending(path: "bundle.zip"))
        let plan = try inspect(pdf, docx, zip)
        #expect(plan.refusals.isEmpty)
        #expect(plan.items.map(\.provenance) == [.external("doc-type"), .external("doc-type"), .external("doc-type")])
        #expect(plan.items.allSatisfy { $0.tainted })
        #expect(plan.items.map(\.taintReason) == ["PDF from outside (document type)", "DOCX from outside (document type)",
                                                  "ZIP from outside (document type)"])
        #expect(plan.items.map(\.ext) == ["pdf", "docx", "zip"])

        // The rule itself.
        #expect(DropTrust.defaultProvenance(ext: "svg", bytes: 10, quarantined: false).reason == "SVG from outside (document type)")
        let owner = DropTrust.defaultProvenance(ext: "swift", bytes: 10, quarantined: false)
        #expect(owner.provenance == .owner && !owner.tainted && owner.reason == nil)
    }

    @Test func quarantinedDropDefaultsTainted() throws {
        #if canImport(Darwin)
        let dir = try tempDir()
        let md = try write("# from the web", dir.appending(path: "notes.md"))
        let plain = try write("# mine", dir.appending(path: "mine.md"))
        let value = "0081;5f000000;Safari;"
        let rc = value.withCString { setxattr(md.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        #expect(rc == 0)
        #expect(Quarantine.isQuarantined(md))
        #expect(!Quarantine.isQuarantined(plain))
        let plan = try inspect(md, plain)
        #expect(plan.items.map(\.quarantined) == [true, false])
        #expect(plan.items.map(\.provenance) == [.external("quarantine"), .owner])
        #expect(plan.items.map(\.tainted) == [true, false])
        #expect(plan.items.map(\.taintReason) == ["downloaded file (macOS quarantine)", nil])
        #else
        #expect(!Quarantine.isQuarantined(URL(fileURLWithPath: "/")))
        #endif
    }

    @Test func smallTextTrustedLargeTextTainted() throws {
        let dir = try tempDir()
        let small = try write("# notes\n", dir.appending(path: "small.md"))
        let line = String(repeating: "a", count: 99) + "\n"
        let bigText = String(repeating: line, count: 700)                   // 70 000 bytes
        let bigTxt = try write(bigText, dir.appending(path: "big.txt"))
        let bigCsv = try write(bigText, dir.appending(path: "big.csv"))
        let bigSwift = try write(bigText, dir.appending(path: "big.swift"))
        let edge = try write(String(repeating: "b", count: 65_536), dir.appending(path: "edge.md"))
        let plan = try inspect(small, bigTxt, bigCsv, bigSwift, edge)
        #expect(plan.refusals.isEmpty)
        #expect(plan.items.map(\.tainted) == [false, true, true, false, false])
        #expect(plan.items.map(\.taintReason) == [nil, "large text file", "large text file", nil, nil])
        #expect(plan.items.map(\.provenance) == [.owner, .external("doc-type"), .external("doc-type"), .owner, .owner])
        #expect(plan.items.map(\.isText) == [true, true, true, true, true])
        #expect(plan.totalBytes == 8 + 70_000 * 3 + 65_536)
    }

    @Test func namesSanitized() throws {
        #expect(ResourceIntake.maxName == 120)
        #expect(ResourceIntake.sanitizeName("invoice\u{202E}fdp.exe") == "invoicefdp.exe")
        #expect(ResourceIntake.sanitizeName("a\u{200B}b\u{200D}c\u{FEFF}.md") == "abc.md")
        #expect(ResourceIntake.sanitizeName("bad\u{0}\u{7}\u{1B}[31mname.txt") == "bad[31mname.txt")
        #expect(ResourceIntake.sanitizeName("  many \t spaces\n here .md ") == "many spaces here .md")
        #expect(ResourceIntake.sanitizeName("Cafe\u{301}.md") == "Caf\u{E9}.md")
        #expect(ResourceIntake.sanitizeName("") == "file")
        #expect(ResourceIntake.sanitizeName("\u{202E}\u{200B} ") == "file")
        let long = ResourceIntake.sanitizeName(String(repeating: "x", count: 300) + ".pdf")
        #expect(long.count == 120)
        #expect(long.hasSuffix(".pdf"))
        #expect(ResourceIntake.sanitizeName(String(repeating: "y", count: 130)).count == 120)

        // On a real drop: the display name is sanitized, the relative path is the name on disk.
        let dir = try tempDir()
        let raw = "report\u{202E}dm.txt.md"
        let url = try write("# hi", dir.appending(path: raw))
        let plan = try inspect(url)
        #expect(plan.items.map(\.displayName) == ["reportdm.txt.md"])
        #expect(plan.items.map(\.relativePath) == [raw])
        #expect(plan.items.map(\.ext) == ["md"])
    }

    @Test func identityRecordedFromFd() throws {
        let dir = try tempDir()
        let url = try write("let x = 1\n", dir.appending(path: "a.swift"))
        let plan = try inspect(url)
        let item = try #require(plan.items.first)
        var st = stat(), dst = stat()
        #expect(lstat(url.path, &st) == 0)
        #expect(stat(dir.path, &dst) == 0)
        #expect(item.identity == FileIdentity(st))
        #expect(item.identity.size == 10)
        #expect(item.rootIdentity == FileIdentity(dst))
        #expect(item.relativePath == "a.swift")
        #expect(item.root.standardizedFileURL.path == dir.standardizedFileURL.path)
        #expect(item.fileKind == "code")
        #expect(item.bytes == 10)

        // A secret inside: the finding rides on the item and the plan says what kind.
        let env = try write("API=AKIAABCDEFGHIJKLMNOP\nDB=correct-horse-battery\n", dir.appending(path: ".env"))
        let p = try inspect(env, known: [(name: "DB_PASS", value: "correct-horse-battery")])
        #expect(p.items.first?.findings == [ScanFinding(label: "aws-key", line: 1, isKnownValue: false),
                                            ScanFinding(label: "stored secret DB_PASS", line: 2, isKnownValue: true)])
        #expect(p.hasKnownValueFinding && p.hasPatternFinding)
        #expect(p.items.first?.ext == "env")
        #expect(!plan.hasKnownValueFinding && !plan.hasPatternFinding)
    }

    @Test(arguments: ["javascript:alert(1)", "ftp://x", "https://user:pw@h.com/a"])
    func linkValidation(_ s: String) throws {
        if s.hasPrefix("https") {
            #expect(try ResourceIntake.link(s) == "https://h.com/a")
        } else {
            #expect(throws: ResourceError.invalid("only http and https links can be added")) { try ResourceIntake.link(s) }
        }
    }

    @Test func linkRules() throws {
        #expect(try ResourceIntake.link("  HTTP://Example.com/a?b=1#c ") == "http://Example.com/a?b=1#c")
        let bad = ["", "https://", "https:///path", "file:///etc/passwd", "data:text/html,hi", "https://a.com/\u{202E}gpj.exe",
                   "https://a.com/\u{7}", "https://a.com/x\u{200B}", "https://a.com/" + String(repeating: "a", count: 2048), "not a url"]
        for s in bad {
            #expect(throws: ResourceError.invalid("only http and https links can be added")) { try ResourceIntake.link(s) }
        }
        #expect(try ResourceIntake.link("https://a.com/" + String(repeating: "a", count: 2000)).count <= ResourcePolicy.maxURL)
    }
}

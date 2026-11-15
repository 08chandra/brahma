import Testing
import Foundation
@testable import BrahmaCore

/// Hand-built zip archives for the archive checks: stored entries whose central-directory records can claim any
/// uncompressed size or carry a symlink mode, so a "bomb" is a few hundred bytes on disk and nothing is ever inflated.
enum ZipFixture {
    struct Entry {
        var name: String
        var data: Data = Data("x".utf8)
        var claimedUncompressed: UInt32? = nil
        var symlink: Bool = false
    }

    static func make(_ entries: [Entry]) -> Data {
        var out = Data(), central = Data()
        func u16(_ v: Int, into d: inout Data) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        func u32(_ v: UInt32, into d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        for e in entries {
            let name = Data(e.name.utf8)
            let offset = UInt32(out.count)
            u32(0x0403_4b50, into: &out); u16(20, into: &out); u16(0, into: &out); u16(0, into: &out)
            u16(0, into: &out); u16(0, into: &out); u32(0, into: &out)
            u32(UInt32(e.data.count), into: &out); u32(UInt32(e.data.count), into: &out)
            u16(name.count, into: &out); u16(0, into: &out)
            out.append(name); out.append(e.data)

            u32(0x0201_4b50, into: &central); u16(3 << 8 | 20, into: &central); u16(20, into: &central)
            u16(0, into: &central); u16(0, into: &central); u16(0, into: &central); u16(0, into: &central)
            u32(0, into: &central); u32(UInt32(e.data.count), into: &central)
            u32(e.claimedUncompressed ?? UInt32(e.data.count), into: &central)
            u16(name.count, into: &central); u16(0, into: &central); u16(0, into: &central)
            u16(0, into: &central); u16(0, into: &central)
            u32(UInt32(e.symlink ? 0o120777 : 0o100644) << 16, into: &central)
            u32(offset, into: &central); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4b50, into: &out); u16(0, into: &out); u16(0, into: &out)
        u16(entries.count, into: &out); u16(entries.count, into: &out)
        u32(UInt32(central.count), into: &out); u32(cdOffset, into: &out); u16(0, into: &out)
        return out
    }

    static func write(_ entries: [Entry], to url: URL) throws -> URL {
        try make(entries).write(to: url)
        return url
    }
}

func resourceFixture(_ name: String) throws -> URL {
    let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
    return try #require(Bundle.module.url(forResource: parts[0], withExtension: parts[1], subdirectory: "Fixtures/resources"))
}

@Suite(.scratch) struct FileKindsTests {
    @Test func extensionTable() {
        let rows: [(ArtifactKind, [String])] = [
            (.html, ["html", "htm"]),
            (.markdown, ["md", "markdown"]),
            (.pdf, ["pdf"]),
            (.image, ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "svg"]),
            (.video, ["mp4", "m4v", "mov"]),
            (.table, ["csv", "tsv"]),
            (.spreadsheet, ["xlsx", "numbers", "xls"]),
            (.document, ["docx", "pptx", "key", "pages", "doc", "ppt", "msg", "rtf"]),
            (.model3d, ["gltf", "usda", "obj", "dae", "glb", "usdc", "usdz", "stl", "usd"]),
            (.cad, ["step", "stp", "iges", "igs"]),
            (.text, ["txt", "json", "yaml", "yml", "log", "eml"]),
            (.code, ["swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cc",
                     "cpp", "hpp", "m", "mm", "cs", "php", "sh", "zsh", "bash", "sql", "toml", "ini", "xml", "css", "scss",
                     "env", "cfg", "conf"]),
        ]
        var seen = 0
        for (kind, exts) in rows {
            for ext in exts {
                #expect(ArtifactKind.from(fileName: "a.\(ext)") == kind, "\(ext)")
                #expect(ArtifactKind.from(fileName: "Some File.\(ext.uppercased())") == kind, "\(ext) uppercased")
                seen += 1
            }
        }
        #expect(Set(rows.map(\.0)) == Set(ArtifactKind.allCases))
        #expect(seen == 83)
        // A dotfile is its own extension: `.env` is code.
        #expect(ArtifactKind.from(fileName: ".env") == .code)
        for none in ["a.zip", "a.m3u8", "a.mpd", "a.m3u", "a.pls", "Makefile", "a.", "a.exe", "a.tar"] {
            #expect(ArtifactKind.from(fileName: none) == nil, "\(none)")
        }
        #expect(ArtifactKind.playlistExtensions == ["m3u8", "m3u", "mpd", "pls"])

        // isText: the kind-level answer, and the per-extension one (svg, and the text 3D formats).
        let textKinds: Set<ArtifactKind> = [.html, .markdown, .table, .text, .code]
        for kind in ArtifactKind.allCases { #expect(kind.isText == textKinds.contains(kind), "\(kind)") }
        for ext in ["svg", "gltf", "usda", "obj", "dae", "md", "swift", "csv"] { #expect(ArtifactKind.isText(ext: ext), "\(ext)") }
        for ext in ["png", "glb", "usdc", "usdz", "stl", "usd", "step", "pdf", "zip", "mp4"] { #expect(!ArtifactKind.isText(ext: ext), "\(ext)") }

        #expect(ArtifactPolicy.maxFileBytes == 52_428_800)
        #expect(ArtifactPolicy.maxVideoBytes == 524_288_000)
        #expect(ArtifactPolicy.maxFolderBytes == 209_715_200)
        #expect(ArtifactPolicy.maxFiles == 500)
        #expect(ArtifactPolicy.titleMax == 120)
        #expect(ArtifactPolicy.companyQuotaBytes == 2_147_483_648)
        #expect(ArtifactPolicy.publishesPerHour == 20)
    }

    @Test func snifferMatches() throws {
        func head(_ url: URL) throws -> Data { try Data(contentsOf: url).prefix(64) }
        for (name, kind, ext) in [("sample.pdf", ArtifactKind.pdf, "pdf"), ("sample.png", .image, "png"),
                                  ("sample.docx", .document, "docx"), ("sample.xls", .spreadsheet, "xls"),
                                  ("sample.mp4", .video, "mp4"), ("sample.swift", .code, "swift")] {
            #expect(ArtifactSniffer.matches(kind: kind, ext: ext, head: try head(resourceFixture(name))), "\(name)")
        }
        let html = Data("<!doctype html><html><body>hi</body></html>".utf8)
        #expect(!ArtifactSniffer.matches(kind: .pdf, ext: "pdf", head: html))
        #expect(ArtifactSniffer.matches(kind: .html, ext: "html", head: html))
        #expect(!ArtifactSniffer.matches(kind: .code, ext: "py", head: Data("print(1)\0\n".utf8)))
        // The text rule allows a multi-byte character cut off at byte 64, and nothing else invalid.
        var cut = Data(repeating: UInt8(ascii: "a"), count: 63); cut.append(0xC3)
        #expect(ArtifactSniffer.matches(kind: .text, ext: "txt", head: cut))
        #expect(!ArtifactSniffer.matches(kind: .text, ext: "txt", head: Data([0x61, 0xC3])), "a short file ending mid-character")
        #expect(!ArtifactSniffer.matches(kind: .text, ext: "txt", head: Data([0x61, 0xFF, 0x62])))
        // svg: text and `<svg` or `<?xml` first; mov: ftyp or the classic atoms at 4.
        #expect(ArtifactSniffer.matches(kind: .image, ext: "svg", head: Data("  <svg xmlns='x'/>".utf8)))
        #expect(ArtifactSniffer.matches(kind: .image, ext: "svg", head: Data("<?xml version='1.0'?><svg/>".utf8)))
        #expect(!ArtifactSniffer.matches(kind: .image, ext: "svg", head: Data("<html><svg/></html>".utf8)))
        var mov = Data([0, 0, 0, 8]); mov.append(Data("moov".utf8))
        #expect(ArtifactSniffer.matches(kind: .video, ext: "mov", head: mov))
        #expect(!ArtifactSniffer.matches(kind: .video, ext: "mp4", head: mov))
        // Extension-only formats match anything; heic needs its brand.
        #expect(ArtifactSniffer.matches(kind: .model3d, ext: "stl", head: Data([0, 1, 2])))
        var heic = Data([0, 0, 0, 24]); heic.append(Data("ftypheic".utf8))
        #expect(ArtifactSniffer.matches(kind: .image, ext: "heic", head: heic))
        var avif = Data([0, 0, 0, 24]); avif.append(Data("ftypavif".utf8))
        #expect(!ArtifactSniffer.matches(kind: .image, ext: "heic", head: avif))
        #expect(ArtifactSniffer.matches(kind: .document, ext: "rtf", head: Data(#"{\rtf1\ansi"#.utf8)))
    }

    @Test func archiveRatioRefusesBomb() throws {
        let dir = try tempDir()
        let bomb = try ZipFixture.write([.init(name: "big.bin", claimedUncompressed: 1_000_000_000)], to: dir.appending(path: "bomb.zip"))
        let stats = try ArchiveRatio.stats(url: bomb)
        #expect(stats.entries == 1)
        #expect(stats.uncompressedBytes == 1_000_000_000)
        #expect(stats.ratio > 100)
        #expect(throws: ArchiveError.expandsTooMuch) { try ArchiveRatio.check(url: bomb) }

        let fine = try ZipFixture.write([.init(name: "a.txt", data: Data(repeating: 65, count: 100))], to: dir.appending(path: "ok.zip"))
        let ratio = try ArchiveRatio.check(url: fine)
        #expect(ratio > 0 && ratio <= 1)

        // More than 10 000 entries: refused, and only the first 10 000 records are read.
        let many = try ZipFixture.write((0...10_000).map { .init(name: "f\($0)") }, to: dir.appending(path: "many.zip"))
        #expect(try ArchiveRatio.stats(url: many).entries == 10_001)
        #expect(throws: ArchiveError.expandsTooMuch) { try ArchiveRatio.check(url: many) }

        // Not a zip at all.
        let junk = dir.appending(path: "junk.zip")
        try Data("PK\u{3}\u{4} but nothing else".utf8).write(to: junk)
        #expect(throws: ArchiveError.unreadable) { try ArchiveRatio.stats(url: junk) }
    }

    @Test func archiveStatsFlagSymlinkAndUnsafeNames() throws {
        let dir = try tempDir()
        let link = try ZipFixture.write([.init(name: "ok.txt"), .init(name: "ssh", symlink: true)], to: dir.appending(path: "l.zip"))
        let s = try ArchiveRatio.stats(url: link)
        #expect(s.hasSymlink && !s.hasUnsafeName)
        #expect(throws: ArchiveError.unsafePaths) { try ArchiveRatio.check(url: link) }

        for name in ["../evil", "a/../../b", "/etc/passwd", "\\windows\\x", "a\\..\\b", "nul\u{0}byte"] {
            let z = try ZipFixture.write([.init(name: name)], to: dir.appending(path: "u.zip"))
            let st = try ArchiveRatio.stats(url: z)
            #expect(st.hasUnsafeName && !st.hasSymlink, "\(name)")
        }
        let safe = try ZipFixture.write([.init(name: "dir/a..b.txt"), .init(name: "..hidden")], to: dir.appending(path: "s.zip"))
        let st = try ArchiveRatio.stats(url: safe)
        #expect(!st.hasUnsafeName && !st.hasSymlink)
        #expect(st.entries == 2)
    }
}

import Testing
import Foundation
@testable import BrahmaCore

/// Hand-built zip archives for the archive checks: stored entries whose central-directory records can claim any
/// uncompressed size or carry a symlink mode, so a "bomb" is a few hundred bytes on disk and nothing is ever inflated.
enum ZipFixture {
    /// How an entry's data descriptor (bit 3) is written after its data.
    enum Descriptor { case signed, unsigned, signed64, unsigned64, missing, badCRC }

    struct Entry {
        var name: String
        var data: Data = Data("x".utf8)
        var claimedUncompressed: UInt32? = nil
        var symlink: Bool = false
        /// The name written in the local header, when it should differ from the central record's.
        var localName: String? = nil
        /// The uncompressed size written in the local header, when it should differ from the central record's.
        var localUncompressed: UInt32? = nil
        /// Bit 3 set in both headers, zero local sizes and CRC, and a data descriptor after the data.
        var dataDescriptor: Bool = false
        var descriptor: Descriptor = .signed
        /// No local header of its own: the central record points at entry `n`'s (overlapping data).
        var sharesLocalWith: Int? = nil
        var method: Int = 0
        var localMethod: Int? = nil
        var crc: UInt32 = 0
        var localCRC: UInt32? = nil
        /// Extra fields of the central record and of the local header.
        var extra: Data = Data()
        var localExtra: Data = Data()
        /// Bytes written right before this entry's local header (not listed anywhere).
        var gapBefore: Data = Data()
        /// The central record's "disk number start".
        var diskStart: Int = 0
        /// Local sizes as 0xFFFFFFFF with a ZIP64 field carrying both (Python's force_zip64).
        var zip64Local: Bool = false
        /// The central uncompressed size as 0xFFFFFFFF with a ZIP64 field carrying it (Info-ZIP's -fz).
        var zip64Central: Bool = false
    }

    static func u16(_ v: Int, into d: inout Data) { var x = UInt16(truncatingIfNeeded: v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
    static func u32(_ v: UInt32, into d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    static func u64(_ v: UInt64, into d: inout Data) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 8)) }

    /// An Info-ZIP Unicode Path extra field (0x7075) naming `path`.
    static func unicodePathField(_ path: String, version: UInt8 = 1) -> Data {
        var d = Data()
        let name = Data(path.utf8)
        u16(0x7075, into: &d); u16(5 + name.count, into: &d); d.append(version); u32(0, into: &d); d.append(name)
        return d
    }

    static func zip64Field(_ values: [UInt64]) -> Data {
        var d = Data()
        u16(0x0001, into: &d); u16(values.count * 8, into: &d)
        for v in values { u64(v, into: &d) }
        return d
    }

    /// The local headers with their data (offsets counted from `base`), and each entry's central record.
    static func parts(_ entries: [Entry], base: Int = 0) -> (locals: Data, records: [Data]) {
        var out = Data()
        var offsets: [UInt32] = [], records: [Data] = []
        for e in entries {
            let name = Data(e.name.utf8)
            let uncompressed = e.claimedUncompressed ?? UInt32(e.data.count)
            let flags = e.dataDescriptor ? 0x0008 : 0
            let offset: UInt32
            if let shared = e.sharesLocalWith {
                offset = offsets[shared]
            } else {
                out.append(e.gapBefore)
                offset = UInt32(base + out.count)
                let localName = Data((e.localName ?? e.name).utf8)
                let localU = e.localUncompressed ?? uncompressed
                let localExtra = (e.zip64Local ? zip64Field([UInt64(localU), UInt64(e.data.count)]) : Data()) + e.localExtra
                u32(0x0403_4b50, into: &out); u16(20, into: &out); u16(flags, into: &out); u16(e.localMethod ?? e.method, into: &out)
                u16(0, into: &out); u16(0, into: &out); u32(e.dataDescriptor ? 0 : (e.localCRC ?? e.crc), into: &out)
                u32(e.dataDescriptor ? 0 : (e.zip64Local ? 0xFFFF_FFFF : UInt32(e.data.count)), into: &out)
                u32(e.dataDescriptor ? 0 : (e.zip64Local ? 0xFFFF_FFFF : localU), into: &out)
                u16(localName.count, into: &out); u16(localExtra.count, into: &out)
                out.append(localName); out.append(localExtra); out.append(e.data)
                if e.dataDescriptor {
                    let c = UInt64(e.data.count), u = UInt64(uncompressed)
                    switch e.descriptor {
                    case .signed: u32(0x0807_4b50, into: &out); u32(e.crc, into: &out); u32(UInt32(c), into: &out); u32(UInt32(u), into: &out)
                    case .unsigned: u32(e.crc, into: &out); u32(UInt32(c), into: &out); u32(UInt32(u), into: &out)
                    case .signed64: u32(0x0807_4b50, into: &out); u32(e.crc, into: &out); u64(c, into: &out); u64(u, into: &out)
                    case .unsigned64: u32(e.crc, into: &out); u64(c, into: &out); u64(u, into: &out)
                    case .badCRC: u32(0x0807_4b50, into: &out); u32(e.crc ^ 1, into: &out); u32(UInt32(c), into: &out); u32(UInt32(u), into: &out)
                    case .missing: break
                    }
                }
            }
            offsets.append(offset)

            let centralExtra = (e.zip64Central ? zip64Field([UInt64(uncompressed)]) : Data()) + e.extra
            var r = Data()
            u32(0x0201_4b50, into: &r); u16(3 << 8 | 20, into: &r); u16(20, into: &r)
            u16(flags, into: &r); u16(e.method, into: &r); u16(0, into: &r); u16(0, into: &r)
            u32(e.crc, into: &r); u32(UInt32(e.data.count), into: &r)
            u32(e.zip64Central ? 0xFFFF_FFFF : uncompressed, into: &r)
            u16(name.count, into: &r); u16(centralExtra.count, into: &r); u16(0, into: &r)
            u16(e.diskStart, into: &r); u16(0, into: &r)
            u32(UInt32(e.symlink ? 0o120777 : 0o100644) << 16, into: &r)
            u32(offset, into: &r); r.append(name); r.append(centralExtra)
            records.append(r)
        }
        return (out, records)
    }

    /// An end record: `disk` for both disk numbers, `count` entries, the central directory's size and offset.
    static func eocd(count: Int, cdSize: UInt32, cdOffset: UInt32, disk: Int = 0, comment: Data = Data()) -> Data {
        var d = Data()
        u32(0x0605_4b50, into: &d); u16(disk, into: &d); u16(disk, into: &d)
        u16(count, into: &d); u16(count, into: &d)
        u32(cdSize, into: &d); u32(cdOffset, into: &d); u16(comment.count, into: &d); d.append(comment)
        return d
    }

    /// A ZIP64 end record (with `extensible` data after its fixed fields) and its locator, for a central directory of
    /// `count` records at `cdOffset`; the record starts at `recordOffset`.
    static func zip64Tail(count: Int, cdSize: Int, cdOffset: Int, at recordOffset: Int, extensible: Data = Data()) -> Data {
        var d = Data()
        u32(0x0606_4b50, into: &d); u64(UInt64(44 + extensible.count), into: &d); u16(45, into: &d); u16(45, into: &d)
        u32(0, into: &d); u32(0, into: &d)
        u64(UInt64(count), into: &d); u64(UInt64(count), into: &d); u64(UInt64(cdSize), into: &d); u64(UInt64(cdOffset), into: &d)
        d.append(extensible)
        u32(0x0706_4b50, into: &d); u32(0, into: &d); u64(UInt64(recordOffset), into: &d); u32(1, into: &d)
        return d
    }

    /// `declaredEntries` overrides the end record's count; `trailing` is appended after the end record (outside its
    /// comment); `zip64` writes a ZIP64 end record and locator and puts the markers in the end record; `prefix` is
    /// prepended with every offset adjusted for it (a self-extractor's stub).
    static func make(_ entries: [Entry], declaredEntries: Int? = nil, trailing: Data = Data(), comment: Data = Data(),
                     disk: Int = 0, zip64: Bool = false, zip64Extensible: Data = Data(), prefix: Data = Data()) -> Data {
        let (locals, records) = parts(entries, base: prefix.count)
        var out = prefix + locals
        let central = records.reduce(Data(), +)
        let cdOffset = out.count
        out.append(central)
        let count = declaredEntries ?? entries.count
        if zip64 {
            out.append(zip64Tail(count: count, cdSize: central.count, cdOffset: cdOffset, at: out.count, extensible: zip64Extensible))
            out.append(eocd(count: 0xFFFF, cdSize: 0xFFFF_FFFF, cdOffset: 0xFFFF_FFFF, disk: disk, comment: comment))
        } else {
            out.append(eocd(count: count, cdSize: UInt32(central.count), cdOffset: UInt32(cdOffset), disk: disk, comment: comment))
        }
        out.append(trailing)
        return out
    }

    static func write(_ entries: [Entry], to url: URL, declaredEntries: Int? = nil, trailing: Data = Data(),
                      comment: Data = Data(), disk: Int = 0, zip64: Bool = false) throws -> URL {
        try make(entries, declaredEntries: declaredEntries, trailing: trailing, comment: comment, disk: disk, zip64: zip64)
            .write(to: url)
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

    /// The central directory, the end record and the local headers must agree; a zip whose records disagree is refused.
    @Test func archiveRecordsMustAgree() throws {
        let dir = try tempDir()
        func zip(_ name: String, _ entries: [ZipFixture.Entry], declared: Int? = nil, trailing: Data = Data()) throws -> URL {
            try ZipFixture.write(entries, to: dir.appending(path: name), declaredEntries: declared, trailing: trailing)
        }
        // The end record declares one entry; the central directory hides a second, unsafe one.
        let hidden = try zip("hidden.zip", [.init(name: "ok.txt"), .init(name: "../evil")], declared: 1)
        #expect(throws: ArchiveError.unreadable) { try ArchiveRatio.stats(url: hidden) }
        // Declares more than it holds.
        let short = try zip("short.zip", [.init(name: "ok.txt")], declared: 2)
        #expect(throws: ArchiveError.unreadable) { try ArchiveRatio.stats(url: short) }
        // The central record names a different file than its local header (what an extractor would write).
        let renamed = try zip("renamed.zip", [.init(name: "ok.txt", localName: "../../.zshrc")])
        #expect(throws: ArchiveError.unsafePaths) { try ArchiveRatio.check(url: renamed) }
        // The sizes disagree: a small central claim over a large local one.
        let sizes = try zip("sizes.zip", [.init(name: "a.bin", localUncompressed: 1_000_000_000)])
        #expect(throws: ArchiveError.unreadable) { try ArchiveRatio.stats(url: sizes) }
        // Two central records over one local header (overlapping entries).
        let overlap = try zip("overlap.zip", [.init(name: "a.txt"), .init(name: "a.txt", sharesLocalWith: 0)])
        #expect(throws: ArchiveError.unreadable) { try ArchiveRatio.stats(url: overlap) }
        // Bytes after the end record that its comment length does not cover: no end record ends the file.
        let tail = try zip("tail.zip", [.init(name: "a.txt")], trailing: Data("junk".utf8))
        #expect(throws: ArchiveError.unreadable) { try ArchiveRatio.stats(url: tail) }
        // Data-descriptor entries (bit 3 in both headers, zero local sizes) are consistent.
        let descriptor = try zip("dd.zip", [.init(name: "a.txt", dataDescriptor: true), .init(name: "b.txt", dataDescriptor: true)])
        #expect(try ArchiveRatio.stats(url: descriptor).entries == 2)
        // The real fixture (written by a zip library, deflated) passes.
        let docx = try ArchiveRatio.stats(url: try resourceFixture("sample.docx"))
        #expect(docx.entries == 2 && ArchiveRatio.refusal(docx) == nil)
        #expect(ArtifactKind.isZipContainer(ext: "DOCX"))
        #expect(Set(ArtifactKind.extensionTable.keys.filter { ArtifactKind.isZipContainer(ext: $0) }) ==
                ["xlsx", "numbers", "docx", "pptx", "key", "pages", "usdz"])
    }

    /// Round 2: no reader of the archive may see a different end record, central directory or file name than this one.
    @Test func archiveParserDifferentialsClosed() throws {
        let dir = try tempDir()
        var n = 0
        func file(_ data: Data) throws -> URL {
            n += 1
            let url = dir.appending(path: "z\(n).zip")
            try data.write(to: url)
            return url
        }
        func unreadable(_ data: Data, _ why: String) throws {
            let url = try file(data)
            #expect(throws: ArchiveError.unreadable, "\(why)") { try ArchiveRatio.stats(url: url) }
        }
        let ok: [ZipFixture.Entry] = [.init(name: "ok.txt")]
        // A normal zip still lists, with a comment too, and as ZIP64.
        #expect(try ArchiveRatio.stats(url: try file(ZipFixture.make(ok))).entries == 1)
        #expect(try ArchiveRatio.stats(url: try file(ZipFixture.make(ok, comment: Data("hello".utf8)))).entries == 1)
        #expect(try ArchiveRatio.stats(url: try file(ZipFixture.make(ok + [.init(name: "b.txt")], zip64: true))).entries == 2)

        // 1. End record: two of them; one hidden in the comment; comment not reaching the end.
        let (locals, records) = ZipFixture.parts(ok)
        var twice = locals + records[0]
        twice += ZipFixture.eocd(count: 1, cdSize: UInt32(records[0].count), cdOffset: UInt32(locals.count))
        twice += ZipFixture.eocd(count: 1, cdSize: UInt32(records[0].count), cdOffset: UInt32(locals.count))
        try unreadable(twice, "two end records")
        let inner = ZipFixture.eocd(count: 1, cdSize: UInt32(records[0].count), cdOffset: UInt32(locals.count))
        try unreadable(ZipFixture.make(ok, comment: inner), "an end record inside the comment")
        try unreadable(ZipFixture.make(ok, trailing: Data([0, 0])), "the comment does not reach the end of the file")

        // 2. ZIP64 and disks. An unused locator (no markers) pointing at a ZIP64 record whose central directory hides
        //    `../evil`: Python's zipfile would follow it.
        let all: [ZipFixture.Entry] = [.init(name: "ok.txt"), .init(name: "../evil")]
        let (allLocals, allRecords) = ZipFixture.parts(all)
        var hidden = allLocals
        let hiddenCD = allRecords.reduce(Data(), +)
        let hiddenAt = hidden.count
        hidden += hiddenCD
        let z64At = hidden.count
        let z64 = ZipFixture.zip64Tail(count: 2, cdSize: hiddenCD.count, cdOffset: hiddenAt, at: z64At)
        hidden += z64.prefix(56)                                           // the ZIP64 end record
        let visibleAt = hidden.count
        hidden += allRecords[0]                                            // the visible directory: ok.txt only
        hidden += z64.suffix(20)                                           // the locator, right before the end record
        hidden += ZipFixture.eocd(count: 1, cdSize: UInt32(allRecords[0].count), cdOffset: UInt32(visibleAt))
        try unreadable(hidden, "a ZIP64 locator the end record does not call for")
        // Markers without a locator.
        var markersOnly = locals + records[0]
        markersOnly += ZipFixture.eocd(count: 0xFFFF, cdSize: 0xFFFF_FFFF, cdOffset: 0xFFFF_FFFF)
        try unreadable(markersOnly, "ZIP64 markers without a locator")
        try unreadable(ZipFixture.make(ok, disk: 1), "a multi-disk end record")
        var multi = ZipFixture.make(ok, zip64: true)
        let locatorAt = multi.count - 22 - 20
        multi[locatorAt + 16] = 2                                          // total disks 2
        try unreadable(multi, "a multi-disk ZIP64 locator")
        // Bytes between the central directory and the end record.
        var gap = locals + records[0] + Data([0, 0, 0, 0])
        gap += ZipFixture.eocd(count: 1, cdSize: UInt32(records[0].count), cdOffset: UInt32(locals.count))
        try unreadable(gap, "a gap after the central directory")

        // 3. Names, methods and CRCs.
        let upath = try file(ZipFixture.make([.init(name: "safe.txt", extra: ZipFixture.unicodePathField("../../.zshrc"))]))
        #expect(throws: ArchiveError.unsafePaths) { try ArchiveRatio.stats(url: upath) }
        let localUpath = try file(ZipFixture.make([.init(name: "safe.txt", localExtra: ZipFixture.unicodePathField("/etc/x"))]))
        #expect(throws: ArchiveError.unsafePaths) { try ArchiveRatio.check(url: localUpath) }
        let fineUpath = try file(ZipFixture.make([.init(name: "caf\u{E9}.txt", extra: ZipFixture.unicodePathField("caf\u{E9}.txt"))]))
        #expect(try ArchiveRatio.check(url: fineUpath) > 0)
        try unreadable(ZipFixture.make([.init(name: "a.txt"), .init(name: "a.txt")]), "duplicate names")
        try unreadable(ZipFixture.make([.init(name: "dir/a.txt"), .init(name: "dir//./a.txt")]), "duplicate after normalising")
        try unreadable(ZipFixture.make([.init(name: "dir/a.txt"), .init(name: "dir\\a.txt")]), "duplicate with a backslash")
        try unreadable(ZipFixture.make([.init(name: "a.txt"), .init(name: "b.txt", extra: ZipFixture.unicodePathField("a.txt"))]),
                       "a Unicode Path that duplicates another entry")
        try unreadable(ZipFixture.make([.init(name: "a.txt", method: 8, localMethod: 0)]), "method differs")
        try unreadable(ZipFixture.make([.init(name: "a.txt", crc: 0x1234_5678, localCRC: 0x8765_4321)]), "CRC differs")
        // With a data descriptor, the local CRC may be zero.
        #expect(try ArchiveRatio.stats(url: try file(ZipFixture.make([.init(name: "a.txt", dataDescriptor: true, crc: 0x1234_5678)]))).entries == 1)
    }

    /// Round 3: the archive's layout is canonical, so a streaming reader, Python and this parser see the same entries.
    @Test func archiveLayoutIsCanonical() throws {
        let dir = try tempDir()
        var n = 0
        func file(_ data: Data) throws -> URL {
            n += 1
            let url = dir.appending(path: "c\(n).zip")
            try data.write(to: url)
            return url
        }
        func lists(_ data: Data, _ why: String) throws -> Int {
            let url = try file(data)
            do { return try ArchiveRatio.stats(url: url).entries } catch { Issue.record("\(why): \(error)"); return -1 }
        }
        func unreadable(_ data: Data, _ why: String) throws {
            let url = try file(data)
            #expect(throws: ArchiveError.unreadable, "\(why)") { try ArchiveRatio.stats(url: url) }
        }
        let ok: [ZipFixture.Entry] = [.init(name: "ok.txt")]
        #expect(try lists(ZipFixture.make(ok), "a normal zip") == 1)

        // 1. ZIP64: no extensible data in the end record; 0 or 1 disks in total.
        try unreadable(ZipFixture.make(ok, zip64: true, zip64Extensible: Data(repeating: 0, count: 16)),
                       "a ZIP64 end record with extensible data")
        var zeroDisks = ZipFixture.make(ok, zip64: true)
        zeroDisks[zeroDisks.count - 22 - 20 + 16] = 0
        #expect(try lists(zeroDisks, "a ZIP64 locator saying 0 disks") == 1)
        #expect(try lists(ZipFixture.make([.init(name: "big.txt", zip64Local: true), .init(name: "c.txt")]),
                          "ZIP64 local sizes (Python force_zip64)") == 2)
        #expect(try lists(ZipFixture.make([.init(name: "dir/a.txt", zip64Local: true, zip64Central: true)], zip64: true),
                          "ZIP64 central and local fields with a ZIP64 end record (Info-ZIP -fz)") == 1)

        // 2. Extra blocks and Unicode Paths fail closed.
        try unreadable(ZipFixture.make([.init(name: "safe.txt", extra: ZipFixture.unicodePathField("safe.txt")
                                                + ZipFixture.unicodePathField("../../.zshrc"))]), "two Unicode Path fields")
        try unreadable(ZipFixture.make([.init(name: "safe.txt", localExtra: ZipFixture.unicodePathField("safe.txt")
                                                + ZipFixture.unicodePathField("other.txt"))]), "two local Unicode Path fields")
        try unreadable(ZipFixture.make([.init(name: "a.txt", extra: Data([0x75, 0x70, 0x09, 0x00, 0x01]))]), "a truncated field")
        try unreadable(ZipFixture.make([.init(name: "a.txt", extra: Data([0x00, 0x00]))]), "a truncated field header")
        try unreadable(ZipFixture.make([.init(name: "a.txt", localExtra: Data([0x0A, 0x00, 0x04]))]), "a truncated local field")
        try unreadable(ZipFixture.make([.init(name: "a.txt", extra: ZipFixture.zip64Field([1]) + ZipFixture.zip64Field([1]))]),
                       "two ZIP64 fields")
        try unreadable(ZipFixture.make([.init(name: "a.txt", extra: ZipFixture.unicodePathField("b.txt"))]),
                       "a Unicode Path naming another file")
        try unreadable(ZipFixture.make([.init(name: "a.txt", extra: ZipFixture.unicodePathField("a.txt", version: 2))]),
                       "a Unicode Path of an unknown version")
        #expect(try lists(ZipFixture.make([.init(name: "Caf\u{E9}.txt", extra: ZipFixture.unicodePathField("cafe\u{301}.txt"),
                                                  localExtra: ZipFixture.unicodePathField("caf\u{E9}.txt"))]),
                          "Unicode Paths naming the same file") == 1)

        // 3. Local entries tile the file from 0 to the central directory.
        let hiddenHeader = ZipFixture.parts([.init(name: "../hidden")]).locals
        try unreadable(ZipFixture.make([.init(name: "a.txt"), .init(name: "b.txt", gapBefore: hiddenHeader)]),
                       "a gap holding a local header the central directory doesn't list")
        try unreadable(ZipFixture.make([.init(name: "a.txt"), .init(name: "b.txt", gapBefore: Data([0, 0, 0, 0]))]), "a gap")
        try unreadable(ZipFixture.make(ok, prefix: Data("#!/bin/sh\nexit 0\n".utf8)), "a prepended stub, offsets adjusted")
        for form in [ZipFixture.Descriptor.signed, .unsigned, .signed64, .unsigned64] {
            let entries: [ZipFixture.Entry] = [
                .init(name: "s1.txt", data: Data("hello there".utf8), dataDescriptor: true, descriptor: form, method: 8, crc: 0x4579_5D56),
                .init(name: "dir/"),
                .init(name: "s2.txt", dataDescriptor: true, descriptor: form, crc: 0x856A_5AA8),
            ]
            #expect(try lists(ZipFixture.make(entries), "data descriptors, \(form)") == 3)
        }
        try unreadable(ZipFixture.make([.init(name: "a.txt", dataDescriptor: true, descriptor: .missing, crc: 7), .init(name: "b.txt")]),
                       "bit 3 without a descriptor")
        try unreadable(ZipFixture.make([.init(name: "a.txt", dataDescriptor: true, descriptor: .badCRC, crc: 7)]),
                       "a descriptor whose CRC is not the central record's")
        try unreadable(ZipFixture.make([.init(name: "d.txt", diskStart: 1)]), "an entry on another disk")

        // 4. Names that land on one file: case and Unicode normalisation.
        try unreadable(ZipFixture.make([.init(name: "A.txt"), .init(name: "a.txt")]), "a case-only duplicate")
        try unreadable(ZipFixture.make([.init(name: "caf\u{E9}.txt"), .init(name: "cafe\u{301}.txt")]), "an NFC/NFD duplicate")
        try unreadable(ZipFixture.make([.init(name: "Dir/X.TXT"), .init(name: "dir//x.txt")]), "case plus normalisation")
    }
}

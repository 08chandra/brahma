import Testing
import Foundation
@testable import BrahmaCore

@Suite(.scratch) struct ContentScanTests {
    /// Literal (name, value) pairs: the scan never reads a vault.
    private let known: [(name: String, value: String)] = [(name: "DB_PASS", value: "correct-horse-battery-staple")]

    private func file(_ data: Data, _ name: String = "f.txt") throws -> URL {
        let url = try tempDir().appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func patternFoundWithLine() throws {
        #expect(ContentScan.chunkBytes == 1 << 20)
        #expect(ContentScan.minOverlap == 4096)
        let text = "line one\nline two\nkey = AKIAABCDEFGHIJKLMNOP\nline four\n"
        let url = try file(Data(text.utf8))
        #expect(try ContentScan.scan(url: url, isText: true, knownValues: []) == [ScanFinding(label: "aws-key", line: 3, isKnownValue: false)])

        // Lines are carried across chunks: a key on line 1 500 of a file read 16 bytes at a time, and again past the
        // first overlap window.
        var lines = (1...2000).map { "row \($0) of plain text" }
        lines[1499] = "token ghp_" + String(repeating: "a", count: 36)
        let long = try file(Data(lines.joined(separator: "\n").utf8))
        for chunk in [16, 1000, 1 << 20] {
            #expect(try ContentScan.scan(url: long, isText: true, knownValues: [], chunk: chunk) ==
                    [ScanFinding(label: "github-token", line: 1500, isKnownValue: false)], "chunk \(chunk)")
        }
        // The same key in a binary file is not a pattern finding: binaries are checked for known values only.
        var bin = Data([0, 1, 2, 3]); bin.append(Data(text.utf8))
        #expect(try ContentScan.scan(url: try file(bin, "b.bin"), isText: false, knownValues: []) == [])
    }

    @Test func knownValueFoundAcrossChunkBoundary() throws {
        let value = known[0].value
        // The value starts 10 bytes before the first 16-byte boundary and spans the next two.
        let text = "abcdef\nxyz" + value + "\nafter\n"
        let url = try file(Data(text.utf8))
        let found = try ContentScan.scan(url: url, isText: true, knownValues: known, chunk: 16)
        #expect(found == [ScanFinding(label: "stored secret DB_PASS", line: 2, isKnownValue: true)])

        // Past the first overlap window too: 10 000 bytes of filler, then the value straddling a chunk edge.
        let filler = String(repeating: "x", count: 9_990) + "\n"
        let far = try file(Data((filler + "....." + value + "\n").utf8))
        #expect(try ContentScan.scan(url: far, isText: true, knownValues: known, chunk: 16) ==
                [ScanFinding(label: "stored secret DB_PASS", line: 2, isKnownValue: true)])
        // The overlap grows to the longest needle, so a value longer than 4096 bytes is still found whole.
        let huge = String(repeating: "Q", count: 5000) + "9"
        let hugeFile = try file(Data(("a\n" + huge + "\n").utf8))
        #expect(try ContentScan.scan(url: hugeFile, isText: true, knownValues: [(name: "BIG", value: huge)], chunk: 1024) ==
                [ScanFinding(label: "stored secret BIG", line: 2, isKnownValue: true)])
        // Short values (under Redactor.minLength) are not looked for.
        #expect(try ContentScan.scan(url: url, isText: true, knownValues: [(name: "PIN", value: "abc")]) == [])
    }

    @Test func knownValueInBinary() throws {
        var bin = Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])
        bin.append(Data(repeating: 0, count: 3000))
        bin.append(Data(known[0].value.utf8))
        bin.append(Data(repeating: 0xFF, count: 3000))
        let url = try file(bin, "x.png")
        for chunk in [16, 1 << 20] {
            let found = try ContentScan.scan(url: url, isText: false, knownValues: known, chunk: chunk)
            #expect(found == [ScanFinding(label: "stored secret DB_PASS", line: 0, isKnownValue: true)], "chunk \(chunk)")
        }
        // Its percent-encoded form too (the Redactor's forms).
        let spaced = "pass word with spaces!"
        var enc = Data([0, 0]); enc.append(Data(try #require(spaced.addingPercentEncoding(withAllowedCharacters: .alphanumerics)).utf8))
        #expect(try ContentScan.scan(url: try file(enc, "e.bin"), isText: false, knownValues: [(name: "P", value: spaced)]).count == 1)
        // Through the descriptor entry point, whatever the descriptor's offset.
        let fd = open(url.path, O_RDONLY)
        defer { close(fd) }
        _ = lseek(fd, 5000, SEEK_SET)
        #expect(try ContentScan.scan(fd: fd, isText: false, knownValues: known).count == 1)
    }

    @Test func valueNeverInFinding() throws {
        let text = "a=\(known[0].value)\nb=AKIAABCDEFGHIJKLMNOP\nc=\(known[0].value)\n"
        let url = try file(Data(text.utf8))
        let found = try ContentScan.scan(url: url, isText: true, knownValues: known, chunk: 8)
        #expect(found == [ScanFinding(label: "stored secret DB_PASS", line: 1, isKnownValue: true),
                          ScanFinding(label: "aws-key", line: 2, isKnownValue: false),
                          ScanFinding(label: "stored secret DB_PASS", line: 3, isKnownValue: true)])
        for f in found {
            #expect(!f.label.contains(known[0].value))
            #expect(!f.label.contains("AKIA"))
            #expect(!"\(f)".contains(known[0].value))
        }
    }

    @Test func redactReplacesSpans() throws {
        let text = "key=AKIAABCDEFGHIJKLMNOP\npass=\(known[0].value) and again \(known[0].value)\nplain\n"
        let found = SecretScan.textFindings(text, knownValues: known)
        let out = ContentScan.redact(text: text, findings: found, knownValues: known)
        #expect(out == "key=[redacted aws-key]\npass=[redacted stored secret DB_PASS] and again [redacted stored secret DB_PASS]\nplain\n")
        #expect(SecretScan.textFindings(out, knownValues: known).isEmpty)
        // Overlapping matches become one span.
        let overlapping = "AKIAABCDEFGHIJKLMNOP"
        let o = ContentScan.redact(text: "x \(overlapping) y", findings: [], knownValues: [(name: "K", value: "AKIAABCDEFGH")])
        #expect(!o.contains("AKIA"))
        #expect(!o.contains("IJKLMNOP"))
        #expect(o.hasPrefix("x [redacted ") && o.hasSuffix("] y"))
        // Nothing to redact: unchanged.
        #expect(ContentScan.redact(text: "hello", findings: [], knownValues: known) == "hello")
    }
}

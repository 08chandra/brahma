import Testing
import Foundation
@testable import BrahmaCore

/// The static scans of Plan X1 (spec §8.1.1, §8.1.6): Swift sources under a root, with comments and string literals blanked.
/// `EngineGitGuardTests.code` blanks `//` comments only; these lints also need string literals gone (a doc string may spell
/// `RuntimeId(` or `try?`), so this is a small single-pass scanner. Lengths are kept, so offsets still line up.
enum SourceLint {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every `.swift` file under `root`, as (path relative to `root`, text), sorted.
    static func swiftFiles(under root: URL) throws -> [(path: String, text: String)] {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            out.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// The code of a file with every `//` and `/* */` comment and the inside of every string literal (`"…"`, `"""…"""`,
    /// `#"…"#`) replaced by spaces; the quotes stay, newlines stay.
    static func code(_ text: String) -> String {
        let c = Array(text.unicodeScalars)
        var out = c
        var i = 0
        func blank(_ j: Int) { if out[j] != "\n" { out[j] = " " } }
        while i < c.count {
            let ch = c[i]
            if ch == "/", i + 1 < c.count, c[i + 1] == "/" {
                while i < c.count, c[i] != "\n" { blank(i); i += 1 }
            } else if ch == "/", i + 1 < c.count, c[i + 1] == "*" {
                var depth = 0
                while i < c.count {
                    if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" { depth += 1; blank(i); blank(i + 1); i += 2; continue }
                    if c[i] == "*", i + 1 < c.count, c[i + 1] == "/" {
                        depth -= 1; blank(i); blank(i + 1); i += 2
                        if depth == 0 { break }
                        continue
                    }
                    blank(i); i += 1
                }
            } else if ch == "#" || ch == "\"" {
                // A string: `#...#"` raw prefix, then `"` or `"""`.
                var hashes = 0
                var j = i
                while j < c.count, c[j] == "#" { hashes += 1; j += 1 }
                guard j < c.count, c[j] == "\"" else { i += 1; continue }
                let multiline = j + 2 < c.count && c[j + 1] == "\"" && c[j + 2] == "\""
                let quotes = multiline ? 3 : 1
                var k = j + quotes
                // Blank until the matching closing quotes (and raw hashes); escapes skip the next scalar.
                while k < c.count {
                    if c[k] == "\\", hashes == 0, k + 1 < c.count, c[k + 1] == "(" {
                        // An interpolation: blank through its matching parenthesis (nested quotes are blanked with it).
                        blank(k); k += 1
                        var depth = 0
                        while k < c.count {
                            if c[k] == "(" { depth += 1 }
                            if c[k] == ")" { depth -= 1 }
                            blank(k); k += 1
                            if depth == 0 { break }
                        }
                        continue
                    }
                    if c[k] == "\\", hashes == 0 { blank(k); if k + 1 < c.count { blank(k + 1) }; k += 2; continue }
                    if c[k] == "\\", hashes > 0, (k + hashes) < c.count, Array(c[(k + 1)...(k + hashes)]).allSatisfy({ $0 == "#" }) {
                        for m in k...(k + hashes) { blank(m) }
                        k += hashes + 1
                        if k < c.count { blank(k); k += 1 }
                        continue
                    }
                    if c[k] == "\"", k + quotes <= c.count, Array(c[k..<(k + quotes)]).allSatisfy({ $0 == "\"" }),
                       k + quotes + hashes <= c.count, Array(c[(k + quotes)..<(k + quotes + hashes)]).allSatisfy({ $0 == "#" }) {
                        k += quotes + hashes
                        break
                    }
                    if !multiline, c[k] == "\n" { break }
                    blank(k); k += 1
                }
                i = k
            } else {
                i += 1
            }
        }
        var s = String.UnicodeScalarView()
        s.append(contentsOf: out)
        return String(s)
    }

    /// `(path, line, matched text)` for every match of `pattern` in the blanked code of every file under `root` not excluded.
    static func hits(under root: URL, excluding: (String) -> Bool = { _ in false }, pattern: String) throws -> [(path: String, line: Int, text: String)] {
        let regex = try NSRegularExpression(pattern: pattern)
        var out: [(String, Int, String)] = []
        for (path, text) in try swiftFiles(under: root) where !excluding(path) {
            let code = Self.code(text)
            let ns = code as NSString
            for m in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                let line = ns.substring(to: m.range.location).components(separatedBy: "\n").count
                out.append((path, line, ns.substring(with: m.range)))
            }
        }
        return out
    }

    /// A temp copy of `root` (for a positive control: plant an offender, scan the copy).
    static func copy(of root: URL) throws -> URL {
        let dir = try tempDir().appending(path: root.lastPathComponent, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: root, to: dir)
        return dir
    }

    static func plant(_ text: String, at relative: String, under root: URL) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}

/// Spec §8.1.1, §8.1.6: a `RuntimeId` is constructed only in the runtime catalog's own directory (`Sources/BrahmaCore/Runtime/`;
/// decoding through `Codable` is the only other way in), and no source compares a `rawValue` with a string literal (`==` or `!=`,
/// either side): a runtime is named through `RuntimeCatalog`, never by its spelling.
@Suite(.scratch) struct RuntimeIdLintTests {
    static let sources = SourceLint.packageRoot.appending(path: "Sources", directoryHint: .isDirectory)
    static let runtimeDir = "BrahmaCore/Runtime/"
    /// `RuntimeId(`, `RuntimeId.init`, and the implicit-member form `.init(rawValue: "…")` of any type (fix round 1: `let id:
    /// RuntimeId = .init(rawValue:)` and `runtime(.init(rawValue:))` name no type).
    static let construction = #"\bRuntimeId\s*(\(|\.\s*init\b)|\.init\s*\(\s*rawValue:\s*""#
    /// `rawValue == "…"`, `rawValue != "…"` and the reversed `"…" == x.rawValue` / `"…" != x.rawValue`.
    static let rawValueLiteral = #"\brawValue\s*[!=]=\s*"|"\s*[!=]=\s*[A-Za-z_][A-Za-z0-9_.]*\.rawValue\b"#
    static func excluded(_ path: String) -> Bool { path.hasPrefix(runtimeDir) }

    static func offenders(under root: URL) throws -> [String] {
        try (SourceLint.hits(under: root, excluding: excluded, pattern: construction)
             + SourceLint.hits(under: root, excluding: excluded, pattern: rawValueLiteral))
            .map { "\($0.path):\($0.line): \($0.text)" }.sorted()
    }

    @Test func runtimeIdsOnlyInCatalog() throws {
        #expect(FileManager.default.fileExists(atPath: Self.sources.appending(path: Self.runtimeDir).path), "no Runtime directory")
        let offenders = try Self.offenders(under: Self.sources)
        #expect(offenders.isEmpty, "RuntimeId constructed or compared by spelling outside Sources/BrahmaCore/Runtime:\n\(offenders.joined(separator: "\n"))")
    }

    /// Positive control: a planted file in a temp copy of the scan root is reported, by every form; one under `Runtime/` is not;
    /// the spelling in a comment or a string is not.
    @Test func plantedOffenderIsReported() throws {
        let copy = try SourceLint.copy(of: Self.sources)
        #expect(try Self.offenders(under: copy).isEmpty, "the copy must start clean")
        try SourceLint.plant("""
            import Foundation
            // RuntimeId("in a comment") is fine; so is "RuntimeId(" in a string and "rawValue == \\"x\\"".
            let doc = \"\"\"
                RuntimeId(rawValue: "multiline") and rawValue == "s"
                \"\"\"
            let raw = #"RuntimeId(rawValue: "raw")"#
            enum Offender {
                static let a = RuntimeId(rawValue: "other")
                static let b = RuntimeId .init(rawValue: "other")
                static func c(_ id: RuntimeId) -> Bool { id.rawValue == "claude" }
                static func d(_ id: RuntimeId) -> Bool { "claude" == id.rawValue }
                static let e: RuntimeId = .init(rawValue: "other")
                static func f() -> Bool { RuntimeCatalog.runtime(.init(rawValue: "other")) != nil }
                static func g(_ id: RuntimeId) -> Bool { id.rawValue != "claude" }
                static func h(_ id: RuntimeId) -> Bool { "claude" != id.rawValue }
            }
            """, at: "BrahmaCore/Somewhere/Offender.swift", under: copy)
        try SourceLint.plant("let inCatalog = RuntimeId(rawValue: \"claude\")\n", at: "BrahmaCore/Runtime/Planted.swift", under: copy)
        let offenders = try Self.offenders(under: copy)
        #expect(offenders.count == 8, "\(offenders)")
        #expect(offenders.allSatisfy { $0.hasPrefix("BrahmaCore/Somewhere/Offender.swift:") }, "\(offenders)")
        #expect(offenders.contains { $0.hasSuffix(":8: RuntimeId(") })
        #expect(offenders.contains { $0.hasSuffix(":9: RuntimeId .init") })
        #expect(offenders.contains { $0.hasSuffix(":10: rawValue == \"") })
        #expect(offenders.contains { $0.hasSuffix(":11: \" == id.rawValue") })
        #expect(offenders.contains { $0.hasSuffix(":12: .init(rawValue: \"") })
        #expect(offenders.contains { $0.hasSuffix(":13: .init(rawValue: \"") })
        #expect(offenders.contains { $0.hasSuffix(":14: rawValue != \"") })
        #expect(offenders.contains { $0.hasSuffix(":15: \" != id.rawValue") })
    }

    /// The blanker: comments and string insides go, quotes and newlines stay, lengths are kept.
    @Test func blankingKeepsShapeAndQuotes() {
        let text = "let a = \"x // y\" // c\n/* b\n l */ let r = #\"q\"# + \"\"\"\nm\n\"\"\"\n"
        let code = SourceLint.code(text)
        #expect(code.count == text.count)
        #expect(code.components(separatedBy: "\n").count == text.components(separatedBy: "\n").count)
        #expect(code.hasPrefix("let a = \"      \"     \n"))
        #expect(code.contains("let r = #\" \"# + \"\"\"\n \n\"\"\""))
        #expect(!code.contains("b") && !code.contains("c") && !code.contains("x // y"))
        // An interpolation with a nested string does not end the literal early.
        let nested = SourceLint.code("let s = \"a \\(f(\"b\")) c\" + d\n")
        #expect(nested == "let s = \"             \" + d\n", "\(nested)")
    }
}

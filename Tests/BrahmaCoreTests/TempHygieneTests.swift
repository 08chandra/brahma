import Testing
import Foundation
@testable import BrahmaCore

/// The suite leaves nothing behind: every test's scratch directories live under one per-process root and go when the test
/// ends (`TestScratch.swift`, whose `ScratchHygieneTests` checks that at run time in each target); and every executable a test
/// runs comes from the shared, content-keyed fake-tool directory, never a fresh file per test (macOS assesses each new
/// executable). The source scans here keep both true for every test file.
@Suite(.scratch) struct TempHygieneTests {
    static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Every `@Suite` carries `.scratch`, and every `@Test` is covered: by `.scratch` on itself, by the `@Suite(.scratch)` of the
    /// type it is declared in (or an extension of one), or, at file scope, by its own `.scratch`. A test in a plain helper
    /// type (no `@Suite`) would run without a scope, and its directories would only go at process exit.
    @Test func everyTestRunsInAScratchScope() throws {
        let suite = try NSRegularExpression(pattern: #"^\s*(@\w+(\([^)]*\))?\s+)*@Suite\b"#)
        let test = try NSRegularExpression(pattern: #"^\s*(@\w+(\([^)]*\))?\s+)*@Test\b"#)
        let decl = try NSRegularExpression(
            pattern: #"^(\s*)(@\w+(\([^)]*\))?\s+)*((private|fileprivate|internal|public)\s+)?(final\s+)?(struct|class|enum|actor|extension)\s+(\w+)"#)
        func match(_ re: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
            re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        }
        func group(_ m: NSTextCheckingResult, _ n: Int, in line: String) -> String { Range(m.range(at: n), in: line).map { String(line[$0]) } ?? "" }
        let sources = try Self.sources()
        // The suites that carry the trait: the `@Suite(.scratch...)` line and the type name on it or within the next 4 lines.
        var scratchSuites: Set<String> = []
        var missing: [String] = []
        for (file, text) in sources {
            let lines = text.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() where match(suite, line) != nil {
                guard line.contains(".scratch") else { missing.append("\(file):\(i + 1) @Suite without .scratch"); continue }
                for j in i..<min(i + 5, lines.count) {
                    if let m = match(decl, lines[j]) { scratchSuites.insert(group(m, 8, in: lines[j])); break }
                }
            }
        }
        for (file, text) in sources {
            let lines = text.components(separatedBy: "\n")
            var decls: [(indent: Int, name: String, line: Int)] = []                 // every type/extension declaration so far
            for (i, line) in lines.enumerated() {
                if let m = match(decl, line) { decls.append((m.range(at: 1).length, group(m, 8, in: line), i)) }
                guard match(test, line) != nil, !line.contains(".scratch") else { continue }
                let indent = line.prefix { $0 == " " || $0 == "\t" }.count
                guard let enclosing = decls.last(where: { $0.indent < indent }) else {
                    missing.append("\(file):\(i + 1) @Test at file scope without .scratch"); continue
                }
                let header = lines[max(0, enclosing.line - 4)...enclosing.line].joined(separator: "\n")
                let covered = scratchSuites.contains(enclosing.name) && (header.contains("@Suite(.scratch") || header.contains("extension "))
                if !covered { missing.append("\(file):\(i + 1) @Test in \(enclosing.name), which is not a @Suite(.scratch)") }
            }
        }
        #expect(missing == [], "add .scratch: \(missing)")
    }

    /// No test writes an executable of its own: the exec bit is set only by `FakeTools` (TestScratch.swift). The few lines that
    /// set a mode as the thing under test (a hook's mode, a directory, a mode change under review) say so: `exec-bit fixture`.
    @Test func executablesComeFromTheSharedToolDirectory() throws {
        let execBit = try NSRegularExpression(pattern: #"(posixPermissions:\s*|chmod\([^)]*,\s*)0o[1357][0-7][0-7]"#)
        var offenders: [String] = []
        for (file, text) in try Self.sources() where file != "TestScratch.swift" {
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where execBit.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil && !line.contains("exec-bit fixture") {
                offenders.append("\(file):\(i + 1)")
            }
        }
        #expect(offenders == [], "use FakeTools.script/bin/install, or mark a mode under test `// exec-bit fixture: ...`: \(offenders)")
    }

    /// No test reaches for the raw temp or home APIs: every scratch path comes from `tempDir()` / `Scratch`, so it is scoped,
    /// swept and guarded. A read-only use says why on its line: `raw-temp-api: ...`.
    @Test func noRawTempOrHomeAPIOutsideScratch() throws {
        let raw = ["temporaryDirectory", "NSTemporaryDirectory", "mkdtemp", "homeDirectoryForCurrentUser", "NSHomeDirectory",
                   "Scratch.temporaryBase", "Scratch.homeBase", "Scratch.homeRoot"]      // the bases are fileprivate to TestScratch anyway
        var offenders: [String] = []
        for (file, text) in try Self.sources() where file != "TestScratch.swift" && file != "TempHygieneTests.swift" {
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where raw.contains(where: { line.contains($0) }) && !line.contains("raw-temp-api:") {
                offenders.append("\(file):\(i + 1)")
            }
        }
        #expect(offenders == [], "use tempDir(), or mark a read-only use `// raw-temp-api: ...`: \(offenders)")
    }

    /// Work that escapes the test's task (a detached task or thread) does not see the scratch scope: `tempDir()` there would
    /// be an orphan. Each such site says what it does on its line: `scope-escape: ...`.
    @Test func scopeEscapesAreDeclared() throws {
        let escapes = ["Task.detached", "Thread.detachNewThread", "DispatchQueue.global"]
        var offenders: [String] = []
        for (file, text) in try Self.sources() where file != "TestScratch.swift" && file != "TempHygieneTests.swift" {
            for (i, line) in text.components(separatedBy: "\n").enumerated()
            where escapes.contains(where: { line.contains($0) }) && !line.contains("scope-escape:") {
                offenders.append("\(file):\(i + 1)")
            }
        }
        #expect(offenders == [], "mark `// scope-escape: ...` (and make no scratch dirs there): \(offenders)")
    }

    /// The three targets' copies of the scratch support are the same file.
    @Test func scratchSupportTwinsAreIdentical() throws {
        let core = try Data(contentsOf: Self.tests.appending(path: "BrahmaCoreTests/TestScratch.swift"))
        let app = try Data(contentsOf: Self.tests.appending(path: "BrahmaAppModelTests/TestScratch.swift"))
        let mapKit = try Data(contentsOf: Self.tests.appending(path: "BrahmaMapKitTests/TestScratch.swift"))
        #expect(core == app && core == mapKit)
    }

    private static func sources() throws -> [(String, String)] {
        var out: [(String, String)] = []
        for case let url as URL in try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        where url.pathExtension == "swift" {
            out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }
}

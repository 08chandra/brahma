import Testing
import Foundation
@testable import BrahmaSafety

/// The kernel stays engine-agnostic (spec §6.8.1, §6.8.2): no file under `Sources/BrahmaSafety` imports GRDB or names the
/// engine's types, so the helper (S8) can link it without a database or an orchestrator. Static scans of the sources, comments
/// blanked the way `EngineGitGuardTests.code` does.
@Suite(.scratch) struct KernelBoundaryTests {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// No file under `Sources/BrahmaSafety` contains `import GRDB`, `Store`, `Orchestrator`, `Company(` or `Agent(` in code.
    @Test func kernelImportsNoEngine() throws {
        let forbidden: [(name: String, pattern: String)] = [
            ("import GRDB", #"^\s*import\s+GRDB\b"#),
            ("Store", #"\bStore\b"#),
            ("Orchestrator", #"\bOrchestrator\b"#),
            ("Company(", #"\bCompany\("#),
            ("Agent(", #"\bAgent\("#),
        ]
        let sources = try Self.sources(under: "Sources/BrahmaSafety")
        #expect(sources.count >= 20, "the kernel's files are found (\(sources.count))")
        var offenders: [String] = []
        for (path, text) in sources {
            let code = Self.code(text)
            let ns = code as NSString
            for (name, pattern) in forbidden {
                let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
                for match in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                    offenders.append("\(path):\(Self.line(of: match.range.location, in: ns)): \(name)")
                }
            }
        }
        #expect(offenders.isEmpty, Comment(rawValue: "engine references in the kernel:\n" + offenders.joined(separator: "\n")))

        // The scan is live: a synthetic file with each reference is caught, comments are not.
        let synthetic = Self.code("import GRDB\nlet s = Store()\n// Orchestrator in a comment\nlet c = Company(x)\nlet a = Agent(y)\nlet ua = UserAgent(z)\n")
        var hits: [String] = []
        for (name, pattern) in forbidden {
            let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            if regex.firstMatch(in: synthetic, range: NSRange(location: 0, length: (synthetic as NSString).length)) != nil { hits.append(name) }
        }
        #expect(hits == ["import GRDB", "Store", "Company(", "Agent("])
    }

    /// `Package.swift`'s `brahma-helper` target lists `BrahmaSafety` as its only dependency. Written now, enabled in S8, when
    /// the target exists.
    @Test(.disabled("enabled in S8: the brahma-helper target does not exist yet"))
    func helperDependsOnlyOnKernel() throws {
        let manifest = try String(contentsOf: Self.packageRoot.appending(path: "Package.swift"), encoding: .utf8)
        let target = try NSRegularExpression(
            pattern: #"\.executableTarget\(\s*name:\s*"brahma-helper"\s*,\s*dependencies:\s*\[([^\]]*)\]"#)
        let ns = manifest as NSString
        let match = try #require(target.firstMatch(in: manifest, range: NSRange(location: 0, length: ns.length)), "a brahma-helper target")
        let dependencies = ns.substring(with: match.range(at: 1)).split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        #expect(dependencies == ["\"BrahmaSafety\""], "brahma-helper depends on the kernel alone: \(dependencies)")
    }

    // MARK: Helpers

    /// The Swift sources under `dir` (repo-relative path, text), sorted by path.
    static func sources(under dir: String) throws -> [(path: String, text: String)] {
        let base = packageRoot.appending(path: dir)
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(packageRoot.standardizedFileURL.path.count + 1))
            out.append((relative, try String(contentsOf: url, encoding: .utf8)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// The code of a file with comments blanked out (lengths kept, so offsets still line up).
    static func code(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[..<r.lowerBound]) + String(repeating: " ", count: line.distance(from: r.lowerBound, to: line.endIndex))
        }.joined(separator: "\n")
    }

    static func line(of offset: Int, in ns: NSString) -> Int {
        var n = 1
        for i in 0..<offset where ns.character(at: i) == 10 { n += 1 }
        return n
    }
}

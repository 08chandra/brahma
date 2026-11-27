import Testing
import Foundation
@testable import BrahmaCore

/// Plan X1 Ruling 2: the runtime seam and the gateway never fail open. Under `Sources/BrahmaCore/Runtime` (must exist) and
/// `Sources/BrahmaCore/Gateway` (tolerated absent until the gateway lands) no `try?`, no `?? true`, no `?? false` and no empty
/// `catch {}`; comments and string literals blanked (`SourceLint.code`).
///
/// Ruling 30: the Claude compiler and parser moved under `Runtime/Claude/` by Task 3's pure move keep today's fail-open sites
/// (fixing them during a byte-identical move would risk behaviour drift). `legacyBaseline` records exactly those files and
/// their counts at the move; it may only shrink (a file over its count fails, a file under it fails until the baseline is
/// lowered to match). Every other file under the scopes, and every new file, has a baseline of zero.
@Suite(.scratch) struct GatewayFailOpenLintTests {
    static let core = SourceLint.packageRoot.appending(path: "Sources/BrahmaCore", directoryHint: .isDirectory)
    static let scopes = ["Runtime", "Gateway"]
    static let patterns: [(name: String, regex: String)] = [
        ("try?", #"\btry\?"#),
        ("?? true", #"\?\?\s*true\b"#),
        ("?? false", #"\?\?\s*false\b"#),
        ("empty catch", #"\bcatch\s*\{\s*\}"#),
    ]

    /// The legacy files Task 3 moved under `Runtime/` (scope-relative path → fail-open sites at the move). Shrink-only.
    static let legacyBaseline: [String: Int] = [
        "Runtime/Claude/ClaudeSettings.swift": 3,
        "Runtime/Claude/StreamParser.swift": 5,
    ]

    /// `(scope/path:line: what)` for every fail-open form under the scopes that exist below `core`.
    static func offenders(core: URL) throws -> [String] {
        var out: [String] = []
        for scope in scopes {
            let root = core.appending(path: scope, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for (name, regex) in patterns {
                for hit in try SourceLint.hits(under: root, pattern: regex) { out.append("\(scope)/\(hit.path):\(hit.line): \(name)") }
            }
        }
        return out.sorted()
    }

    /// The file part of an offender line (`scope/path`).
    static func file(of offender: String) -> String {
        String(offender.prefix { $0 != ":" })
    }

    /// Every offender of a file holding more sites than its baseline (zero for any file not in `legacyBaseline`).
    static func violations(core: URL) throws -> [String] {
        let offenders = try offenders(core: core)
        let counts = Dictionary(grouping: offenders, by: file(of:)).mapValues(\.count)
        return offenders.filter { counts[file(of: $0), default: 0] > legacyBaseline[file(of: $0), default: 0] }
    }

    @Test func noFailOpenInRuntimeOrGateway() throws {
        #expect(FileManager.default.fileExists(atPath: Self.core.appending(path: "Runtime").path), "Sources/BrahmaCore/Runtime must exist")
        let violations = try Self.violations(core: Self.core)
        #expect(violations.isEmpty, "fail-open forms in the runtime or gateway beyond the legacy baseline:\n\(violations.joined(separator: "\n"))")
    }

    /// The baseline only shrinks: a legacy file with fewer sites than recorded must have its count lowered (so a site removed
    /// cannot quietly come back), and a baseline entry for a file that no longer exists is removed.
    @Test func legacyBaselineIsTight() throws {
        let counts = Dictionary(grouping: try Self.offenders(core: Self.core), by: Self.file(of:)).mapValues(\.count)
        for (file, recorded) in Self.legacyBaseline.sorted(by: { $0.key < $1.key }) {
            #expect(FileManager.default.fileExists(atPath: Self.core.appending(path: file).path), "\(file) is gone: drop it from the baseline")
            #expect(counts[file, default: 0] == recorded,
                    "\(file): \(counts[file, default: 0]) fail-open site(s), baseline \(recorded): lower the baseline (it only shrinks)")
        }
        // Only files moved under `Runtime/Claude/` by Task 3 are legacy; nothing under the gateway ever is.
        #expect(Self.legacyBaseline.keys.allSatisfy { $0.hasPrefix("Runtime/Claude/") })
    }

    /// Positive control: each form planted in a temp copy is reported (and only from the scoped directories; comments and strings
    /// do not count).
    @Test func plantedFailOpenIsReported() throws {
        let copy = try SourceLint.copy(of: Self.core)
        #expect(try Self.violations(core: copy).isEmpty, "the copy must start clean")
        try SourceLint.plant("""
            import Foundation
            // try? and ?? true in a comment; "?? false" and "catch {}" in a string.
            func a(_ s: String?) -> Int? { try? Int(s ?? "", radix: 10) }
            func b(_ f: Bool?) -> Bool { f ?? true }
            func c(_ f: Bool?) -> Bool { f ??
                false }
            func d() { do { try e() } catch {
            } }
            func e() throws {}
            """, at: "Runtime/Planted.swift", under: copy)
        try SourceLint.plant("func g(_ f: Bool?) -> Bool { f ?? false }\n", at: "Gateway/Planted.swift", under: copy)
        try SourceLint.plant("func h(_ f: Bool?) -> Bool { f ?? false }\n", at: "Sandbox/Planted.swift", under: copy)
        // One more site in a legacy file puts all of that file's sites over its baseline.
        let legacy = copy.appending(path: "Runtime/Claude/StreamParser.swift")
        try Data((try String(contentsOf: legacy, encoding: .utf8) + "func i(_ f: Bool?) -> Bool { f ?? true }\n").utf8).write(to: legacy)
        let offenders = try Self.violations(core: copy)
        let legacyHits = offenders.filter { $0.hasPrefix("Runtime/Claude/StreamParser.swift:") }
        #expect(legacyHits.count == (Self.legacyBaseline["Runtime/Claude/StreamParser.swift"] ?? 0) + 1, "\(legacyHits)")
        #expect(offenders.filter { !$0.hasPrefix("Runtime/Claude/StreamParser.swift:") }
                    == ["Gateway/Planted.swift:1: ?? false", "Runtime/Planted.swift:3: try?", "Runtime/Planted.swift:4: ?? true",
                        "Runtime/Planted.swift:5: ?? false", "Runtime/Planted.swift:7: empty catch"], "\(offenders)")
    }
}

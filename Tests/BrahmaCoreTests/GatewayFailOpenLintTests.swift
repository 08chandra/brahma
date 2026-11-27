import Testing
import Foundation
@testable import BrahmaCore

/// Plan X1 Ruling 2: the runtime seam and the gateway never fail open. Under `Sources/BrahmaCore/Runtime` (must exist) and
/// `Sources/BrahmaCore/Gateway` (tolerated absent until the gateway lands) no `try?`, no `?? true`, no `?? false` and no empty
/// `catch {}`; comments and string literals blanked (`SourceLint.code`).
@Suite(.scratch) struct GatewayFailOpenLintTests {
    static let core = SourceLint.packageRoot.appending(path: "Sources/BrahmaCore", directoryHint: .isDirectory)
    static let scopes = ["Runtime", "Gateway"]
    static let patterns: [(name: String, regex: String)] = [
        ("try?", #"\btry\?"#),
        ("?? true", #"\?\?\s*true\b"#),
        ("?? false", #"\?\?\s*false\b"#),
        ("empty catch", #"\bcatch\s*\{\s*\}"#),
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

    @Test func noFailOpenInRuntimeOrGateway() throws {
        #expect(FileManager.default.fileExists(atPath: Self.core.appending(path: "Runtime").path), "Sources/BrahmaCore/Runtime must exist")
        let offenders = try Self.offenders(core: Self.core)
        #expect(offenders.isEmpty, "fail-open forms in the runtime or gateway:\n\(offenders.joined(separator: "\n"))")
    }

    /// Positive control: each form planted in a temp copy is reported (and only from the scoped directories; comments and strings
    /// do not count).
    @Test func plantedFailOpenIsReported() throws {
        let copy = try SourceLint.copy(of: Self.core)
        #expect(try Self.offenders(core: copy).isEmpty, "the copy must start clean")
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
        let offenders = try Self.offenders(core: copy)
        #expect(offenders == ["Gateway/Planted.swift:1: ?? false", "Runtime/Planted.swift:3: try?", "Runtime/Planted.swift:4: ?? true",
                              "Runtime/Planted.swift:5: ?? false", "Runtime/Planted.swift:7: empty catch"], "\(offenders)")
    }
}

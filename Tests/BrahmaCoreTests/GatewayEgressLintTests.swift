import Testing
import Foundation
@testable import BrahmaCore

/// Plan X1 Ruling 22: the gateway-only egress constructor `EgressProxy(gatewayHost:)` lets one pinned host through, vendor
/// roots included, so it may be called from exactly one place in the product: `Sources/BrahmaCore/Gateway/Upstream.swift`
/// (its definition lives in `Sandbox/EgressProxy.swift`). Agent sandboxes only ever get `EgressProxy(allow:)`, which refuses
/// Anthropic's hosts. Comments and string literals do not count (`SourceLint.code`).
@Suite(.scratch) struct GatewayEgressLintTests {
    static let sources = SourceLint.packageRoot.appending(path: "Sources", directoryHint: .isDirectory)
    static let allowed: Set<String> = ["BrahmaCore/Gateway/Upstream.swift", "BrahmaCore/Sandbox/EgressProxy.swift"]
    static let pattern = #"\bgatewayHost\s*:"#

    static func offenders(under root: URL) throws -> [String] {
        try SourceLint.hits(under: root, excluding: { allowed.contains($0) }, pattern: pattern).map { "\($0.path):\($0.line)" }.sorted()
    }

    @Test func gatewayEgressConstructorOnlyInUpstream() throws {
        #expect(try Self.offenders(under: Self.sources).isEmpty, "EgressProxy(gatewayHost:) outside Gateway/Upstream.swift")
        // The one call site exists (so the lint cannot pass by the constructor going unused under another name).
        let upstream = try String(contentsOf: Self.sources.appending(path: "BrahmaCore/Gateway/Upstream.swift"), encoding: .utf8)
        #expect(SourceLint.code(upstream).range(of: #"EgressProxy\s*\(\s*gatewayHost\s*:"#, options: .regularExpression) != nil)
    }

    /// Positive control: a planted call anywhere else (the sandbox runner, a new gateway file) is reported; mentions in comments
    /// and strings are not.
    @Test func plantedGatewayEgressCallIsReported() throws {
        let copy = try SourceLint.copy(of: Self.sources.appending(path: "BrahmaCore", directoryHint: .isDirectory))
        let root = copy.deletingLastPathComponent()
        try SourceLint.plant("""
            // EgressProxy(gatewayHost: "api.anthropic.com") in a comment
            let note = "EgressProxy(gatewayHost: x)"
            func leak() throws -> EgressProxy { try EgressProxy(gatewayHost: "api.anthropic.com") }
            """, at: "BrahmaCore/Sandbox/Planted.swift", under: root)
        try SourceLint.plant("func again() throws { _ = try EgressProxy(\n    gatewayHost : \"h.example.com\") }\n",
                             at: "BrahmaCore/Gateway/Other.swift", under: root)
        #expect(try Self.offenders(under: root) == ["BrahmaCore/Gateway/Other.swift:2", "BrahmaCore/Sandbox/Planted.swift:3"])
    }
}

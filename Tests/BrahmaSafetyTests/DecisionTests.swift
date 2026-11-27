import Testing
import Foundation
@testable import BrahmaSafety

/// Plan S Task S4 (spec §6.7): `Decision` has a mandatory deny path and no `Bool`/`Optional` coercion; `bestEffort` swallows
/// and logs the error of a cleanup step.
@Suite(.scratch) struct DecisionTests {
    /// The only way to read a decision is an exhaustive `switch`: no `Bool` property, no `ExpressibleByBooleanLiteral`, no
    /// failable unwrap. The block below must not compile if it were enabled (kept as the compile-time statement of the rule).
    @Test func denyHasNoBoolCoercion() {
        let allowed: Decision<String> = .allow("/bin/sh", because: "pinned at engine start")
        let denied: Decision<String> = .deny("not on the allowlist")
        #if false
        let _: Bool = denied
        let _: Bool = allowed.isAllowed
        if denied {}
        let _: Decision<String> = true
        guard let _ = allowed else { return }
        #endif
        func read(_ d: Decision<String>) -> String {
            switch d {
            case .allow(let value, let because): return "allow \(value): \(because)"
            case .deny(let why): return "deny: \(why)"
            }
        }
        #expect(read(allowed) == "allow /bin/sh: pinned at engine start")
        #expect(read(denied) == "deny: not on the allowlist")
        // Equatable when the payload is: a deny never equals an allow.
        #expect(allowed != denied)
        #expect(denied == .deny("not on the allowlist"))
    }

    /// S4 fix round 1 (M5): the rule above, held by a source scan (the `#if false` block alone proves nothing once someone adds
    /// a conversion): in code, `Decision.swift` names no `Bool` at all (no `Bool` member, property or return) and no
    /// `ExpressibleByBooleanLiteral`, and no other kernel file extends `Decision`.
    @Test func decisionSourceDeclaresNoBool() throws {
        let sources = try KernelBoundaryTests.sources(under: "Sources/BrahmaSafety")
        let decision = try #require(sources.first { $0.path == "Sources/BrahmaSafety/Policy/Decision.swift" })
        let code = KernelBoundaryTests.code(decision.text)
        #expect(code.contains("enum Decision"), "the scan reads the real file")
        for banned in [#"\bBool\b"#, #"\bExpressibleByBooleanLiteral\b"#] {
            #expect(code.range(of: banned, options: .regularExpression) == nil, "Decision.swift: \(banned)")
        }
        let extensions = sources.filter { $0.path != decision.path }
            .filter { KernelBoundaryTests.code($0.text).range(of: #"\bextension\s+Decision\b"#, options: .regularExpression) != nil }
        #expect(extensions.isEmpty, "Decision is extended outside its file: \(extensions.map(\.path))")
    }

    /// `bestEffort` runs its body; a thrown error is swallowed (and logged to stderr), never rethrown.
    @Test func bestEffortSwallowsAndRuns() {
        struct Boom: Error {}
        var ran = 0
        bestEffort("a cleanup that works") { ran += 1 }
        bestEffort("a cleanup that fails") { ran += 1; throw Boom() }
        #expect(ran == 2)
    }
}

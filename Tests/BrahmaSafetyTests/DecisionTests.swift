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

    /// `bestEffort` runs its body; a thrown error is swallowed (and logged to stderr), never rethrown.
    @Test func bestEffortSwallowsAndRuns() {
        struct Boom: Error {}
        var ran = 0
        bestEffort("a cleanup that works") { ran += 1 }
        bestEffort("a cleanup that fails") { ran += 1; throw Boom() }
        #expect(ran == 2)
    }
}

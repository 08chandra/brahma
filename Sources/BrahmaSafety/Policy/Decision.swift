import Foundation

/// A safety decision with a mandatory deny path (spec §6.7). It is read only by an exhaustive `switch`: there is no `Bool`
/// property, no `ExpressibleByBooleanLiteral` and no failable unwrap, so a caller cannot fold "could not decide" into
/// "allowed". Both cases say why (Ruling P2: the reason is a `String` until a `Reason` type is wanted).
public enum Decision<Allowed: Sendable>: Sendable {
    case allow(Allowed, because: String)
    case deny(String)
}

extension Decision: Equatable where Allowed: Equatable {}

/// Runs a cleanup step whose failure changes no decision: the error is logged to stderr
/// (`brahma: best-effort <what> failed: <error>`) and swallowed. Only for cleanup (removing a temp directory, a leftover
/// after the outcome is already settled); a step on a decision path throws or reports its problem instead (spec §6.7).
public func bestEffort(_ what: StaticString, _ body: () throws -> Void) {
    do {
        try body()
    } catch {
        FileHandle.standardError.write(Data("brahma: best-effort \(what) failed: \(error)\n".utf8))
    }
}

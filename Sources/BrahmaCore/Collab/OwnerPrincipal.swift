import Foundation

/// Which kind of process this is, set once at its entry point (controller Ruling C6-3): the owner's surfaces (the app, the owner
/// CLI) or an agent's (`brahma mcp`, anything a turn runs). Sticky towards `.agent`: once a process is an agent's, nothing turns it
/// back.
public enum ProcessRole: Equatable, Sendable {
    case unknown, owner, agent

    /// Controller Ruling C6-4, the interim guard until the final wave threads `OwnerPrincipal` through every owner API: the
    /// generic refusal (`WorkError.forbidden`) in an agent process, before any lookup; silent in an owner's. Called first thing by
    /// the public entry points of the owner decisions (`ownerDecide`, `ownerAnswer`, `ownerRescind`, `acknowledge`), the vouches
    /// (`vouchFile`, `vouchResource`, `vouchItem` takes the token), `purgeResource`, `setResourceScope`, `approveAccess`,
    /// `provideSecret`, `declineFileRequest` and `answerFileRequest`. The `db:` overloads the engine's own presets use are not guarded.
    public static func refuseInAgentProcess() throws {
        guard OwnerPrincipal.processRole != .agent else { throw WorkError.forbidden(OwnerPrincipal.refusal) }
    }
}

public enum OwnerPrincipalError: Error, Equatable, CustomStringConvertible {
    /// Minting was refused: the process is an agent's, or the owner-shell guard said why.
    case refused(String)
    public var description: String { if case .refused(let why) = self { return why }; return "" }
}

/// Plan C Task C6 fix rounds 2–3, controller Rulings C6-2(b) and C6-3: the owner principal every owner-only Store API takes.
/// It has no public initializer: the only way to hold one is `mint`, which the app's `AppModel` entry and the CLI's
/// `requireOwnerShell`/`OwnerKey` path call. `mint` throws (and logs) in an agent process — `brahma mcp` and every agent-turn
/// entry point set that role before they open any Store — and for a process the owner-shell guard refuses (BRAHMA_AGENT_ID set, or
/// inside a running turn's process tree). So no `CompanyTools` handler, and no code a turn runs, can act as the owner however a
/// future tool were wired: the parameter can't be forged, only minted.
public struct OwnerPrincipal: Sendable, Equatable {
    private init() {}

    /// What a caller without a principal is told (generic: the same text as a missing ref).
    public static var refusal: String { Store.refUnavailable }

    private static let roleLock = NSLock()
    nonisolated(unsafe) private static var role: ProcessRole = .unknown

    /// Tests only: a role scoped to the current task (`$roleOverride.withValue(.agent) { … }`), so a test of agent mode never
    /// touches the process-wide role the other tests run under.
    @TaskLocal static var roleOverride: ProcessRole?

    /// This process's role (the task-local override first).
    public static var processRole: ProcessRole { roleOverride ?? roleLock.withLock { role } }

    /// An agent's process (`brahma mcp`, a turn's entry point): from here on `mint` throws. Sticky.
    public static func enterAgentProcess() { roleLock.withLock { role = .agent } }

    /// An owner surface (the app, the owner CLI). Ignored once the process is an agent's.
    public static func enterOwnerProcess() { roleLock.withLock { if role != .agent { role = .owner } } }

    /// What a server or turn entry point asserts before it opens a Store: refuses unless the role is `.agent` (an unknown role is a
    /// wiring mistake, fail closed).
    public static func requireAgentProcess() throws {
        guard processRole == .agent else { throw OwnerPrincipalError.refused("this entry point runs only as an agent process") }
    }

    /// The owner principal of this process. Throws (and logs) in an agent process — always: no argument lifts that (round 3,
    /// I-1) — and for a process the owner-shell guard refuses (BRAHMA_AGENT_ID set, or a running turn among the ancestors).
    public static func mint() throws -> OwnerPrincipal {
        try mint(role: nil, environment: ProcessInfo.processInfo.environment, ancestors: ProcessAncestry.chain(of: getpid()), runningTurnPids: [])
    }

    /// The owner CLI's form: the running turns' leaders (`Store.recordedTurnLeaders(paths:)`) count as ancestors to refuse.
    public static func mint(runningTurnPids: Set<Int32>) throws -> OwnerPrincipal {
        try mint(role: nil, environment: ProcessInfo.processInfo.environment, ancestors: ProcessAncestry.chain(of: getpid()), runningTurnPids: runningTurnPids)
    }

    /// The seam the tests use (`@testable`): `role` can only make the check stricter (simulate an agent role); the process's own
    /// agent role refuses first, whatever is passed.
    static func mint(role: ProcessRole?, environment: [String: String], ancestors: [Int32], runningTurnPids: Set<Int32>) throws -> OwnerPrincipal {
        if processRole == .agent || role == .agent {
            log("owner principal refused: this is an agent process")
            throw OwnerPrincipalError.refused("an agent process can't act as the owner")
        }
        if let why = OwnerShellGuard.refusal(environment: environment, ancestors: ancestors, runningTurnPids: runningTurnPids) {
            log("owner principal refused: \(why)")
            throw OwnerPrincipalError.refused(why)
        }
        return OwnerPrincipal()
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data("brahma: \(line)\n".utf8))
    }
}

extension Store {
    /// The owner's principal, or the generic refusal (`WorkError.forbidden`) when the caller has none: what every owner surface
    /// checks before an owner-only call.
    public func requireOwner(_ owner: OwnerPrincipal?) throws -> OwnerPrincipal {
        guard let owner else { throw WorkError.forbidden(OwnerPrincipal.refusal) }
        return owner
    }
}

import Foundation

/// What a set of subjects may have a helper read (spec §6.4.4, architect's call). A path is in reach when it lies at or
/// under an `allowed` entry and under no `denied` entry that lies inside that same allowed entry: a deny takes away part of
/// the allowance it sits in, and an allowance inside a denied area (an agent's own lab inside `.brahma`) is its own.
/// - an agent: its company workspace, minus the `.git` internals (`SandboxScope.gitInternals`), minus the engine-only
///   children of `.brahma` (`SandboxScope.engineOnlyDotBrahma`), minus other agents' labs and notes; plus its own lab, home
///   and notes (`agent(workspace:denied:own:)`, built by the engine from its layout);
/// - the owner: the company workspace (`owner(workspace:)`);
/// - an engine, external or unknown subject: the purpose's places only. `SandboxPolicyFactory.decide` applies this itself:
///   it needs no reach for such a set, and checks the given one whenever an agent or the owner is a member;
/// - a set: the intersection of its members' reaches (`intersection`), least privilege winning (spec §6.2.4).
/// The call directory and the helper's own directory are always in reach (the factory adds them).
public struct Reach: Hashable, Sendable {
    public let allowed: [String]
    public let denied: [String]
    /// The reaches of the set's other members: a path must be in every one of them too.
    let alsoWithin: [Reach]

    public init(allowed: [String], denied: [String]) {
        self.init(allowed: allowed, denied: denied, alsoWithin: [])
    }

    init(allowed: [String], denied: [String], alsoWithin: [Reach]) {
        self.allowed = allowed; self.denied = denied; self.alsoWithin = alsoWithin
    }

    /// The owner's reach: the company workspace.
    public static func owner(workspace: Place) -> Reach { Reach(allowed: [workspace.resolvedPath], denied: []) }

    /// An agent's reach: the company workspace minus `denied` (git internals, engine-only `.brahma` children, other agents'
    /// labs and notes), plus `own` (its lab, home and notes).
    public static func agent(workspace: Place, denied: [String], own: [String]) -> Reach {
        Reach(allowed: [workspace.resolvedPath] + own, denied: denied)
    }

    /// The paths in both reaches.
    public func intersection(_ other: Reach) -> Reach {
        Reach(allowed: allowed, denied: denied, alsoWithin: alsoWithin + [other])
    }

    /// Whether `path` is in this reach: `.allow(path)`, or `.deny(why)`.
    public func admits(_ path: String) -> Decision<String> {
        let inOwn = allowed.contains { a in
            SandboxPath.isInside(path, a)
                && !denied.contains { d in SandboxPath.isInside(path, d) && SandboxPath.isInside(d, a) && SandboxPath.key(d) != SandboxPath.key(a) }
        }
        guard inOwn else { return .deny("\(path) is outside the subjects' reach") }
        for other in alsoWithin {
            if case .deny(let why) = other.admits(path) { return .deny(why) }
        }
        return .allow(path, because: "inside the subjects' reach")
    }
}

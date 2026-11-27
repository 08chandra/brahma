import Foundation
import Testing
@testable import BrahmaCore

extension Tag {
    /// Spawns real processes (git, a loopback HTTP server): the process tier of Plan P, which this tree does not have yet.
    @Tag static var process: Self
}

/// The test gate (Ruling 3): `GitHubRules` applied in X4's §8.4.5 order — kill switch, first use, taint, irreversible, the
/// type rules, then the grant — so later X4 can lift the rules unchanged. Production has only `NoChannelGate`.
struct RulesGate: PRActionGate {
    var killSwitch = false
    /// The action names (`push-branch`, ...) the owner granted.
    var granted: Set<String> = []

    func decide(_ r: PRActionRequest) async -> PRActionDecision {
        if killSwitch { return .refuse(rule: "kill switch") }
        if let why = GitHubRules.firstPushAsks(r) { return .ask(reason: why) }
        if let why = GitHubRules.taintedAsks(r) { return .ask(reason: why) }
        if let why = GitHubRules.mergePRAlwaysAsks(r.type) { return .ask(reason: why) }
        if r.type == .pushBranch {
            if let why = GitHubRules.publicRepoPushAsks(visibility: r.repoVisibility) { return .ask(reason: why) }
            if let payload = r.payload, let why = GitHubRules.workflowsPathAsks(payload: payload) { return .ask(reason: why) }
        }
        guard granted.contains(r.type.name) else { return .refuse(rule: "no grant for \(r.type.name)") }
        return .auto
    }
}

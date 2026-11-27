import Foundation

/// The company owner's Full opt-out for one action (spec §6.3.1): it carries the reason, and it is a distinct type that only
/// `SandboxPolicyFactory` creates, so the unsandboxed runner (`UnsandboxedRunning`) takes only a `FullOptOut` and cannot be
/// reached from a `Bool`.
public struct FullOptOut: Sendable, Equatable {
    public let reason: String

    init(reason: String) { self.reason = reason }
}

/// What the factory decided for one action.
public enum PolicyDecision: Sendable, Equatable {
    case sandboxed(ValidatedPolicy)
    /// The company owner's Full opt-out (`FullOptOut`).
    case fullOptOut(FullOptOut)
    /// Nothing runs; why, for the caller's existing refusal path (Ruling P2's shape: a `String`, the spec's `Refusal` being
    /// undefined).
    case refused(String)
}

/// The only source of Seatbelt policies (spec §6.3, Plan S Task S7). Every site that runs something under the sandbox names
/// its purpose, its subject principals (`PrincipalSet`, resolved once) and its verified places, and gets a decision:
/// - the places must be the purpose's own case (`PurposePlaces`); any other is refused;
/// - each purpose's writable, readable, network and toolchain are the values its site used before Plan S, moved in;
/// - Full opt-out only when the purpose runs agent-written commands, every subject is Full-eligible (`allFull`) and the
///   company's own profile is Full;
/// - network grants only from `principals.commonGrantDomains` (B3: the intersection of the members' grants; none with an
///   unknown, external or engine member), and only for a preview server, the one purpose whose site took grants;
/// - a helper call never runs Full, never gets grants or the toolchain, and is refused unless every place it names is
///   inside the subjects' reach (spec §6.4.4);
/// - the policy is validated (`SandboxPolicyCheck.validate`) against `baseline`; any throw is a refusal. The only way to
///   obtain a `ValidatedPolicy` is this.
public enum SandboxPolicyFactory {
    public static func decide(_ purpose: Purpose, principals: PrincipalSet, places: PurposePlaces, network: NetworkScope,
                              baseline: SandboxBaseline, reach: Reach? = nil) -> PolicyDecision {
        let policy: SandboxPolicy
        switch (purpose, places) {
        case (.check, .check(let checkout, let workspace)):
            policy = SandboxPolicy(writable: [checkout.url], readable: [workspace.url], network: .outbound(allow: network.allowedDomains),
                                   toolchain: true)
        case (.previewServer(let port), .previewServer(let run)):
            policy = SandboxPolicy(writable: [run.url], readable: [run.url],
                                   network: .loopbackListen(allow: withGrants(network.allowedDomains, principals.commonGrantDomains),
                                                            ports: port.ports),
                                   toolchain: true)
        case (.previewOneShot, .previewOneShot(let run)):
            policy = SandboxPolicy(writable: [run.url], readable: [run.url], network: .outbound(allow: network.allowedDomains), toolchain: false)
        case (.appleBuild, .appleBuild(let run)):
            policy = SandboxPolicy(writable: [run.url], readable: [run.url], network: .outbound(allow: network.allowedDomains), toolchain: true)
        case (.guiApp, .guiApp(let run, let appData)):
            policy = SandboxPolicy(writable: [appData.url], readable: [run.url], network: .outbound(allow: network.allowedDomains),
                                   toolchain: true)
        case (.releaseTool, .releaseTool(let writable, let readable)):
            policy = SandboxPolicy(writable: writable.map(\.url), readable: readable.map(\.url),
                                   network: .outbound(allow: network.allowedDomains), toolchain: true)
        case (.releaseSmoke, .releaseSmoke(let dir)):
            policy = SandboxPolicy(writable: [dir.url], readable: [dir.url], network: .outbound(allow: network.allowedDomains), toolchain: true)
        case (.providerProbe, .providerProbe(let writable, let readable)):
            policy = SandboxPolicy(writable: writable.map(\.url), readable: readable.map(\.url),
                                   network: .outbound(allow: network.allowedDomains), toolchain: true)
        case (.extensionUnzip, .extensionUnzip(let unzipped, let held)):
            policy = SandboxPolicy(writable: [unzipped.url], readable: [held.url], network: .none, toolchain: false)
        case (.extensionValidate, .extensionValidate(let scratch, let readable)),
             (.doctorExtensions, .doctorExtensions(let scratch, let readable)):
            policy = SandboxPolicy(writable: [scratch.url], readable: readable.map(\.url), network: .none, toolchain: false)
        case (.canary, .canary(let writable, let readable)):
            policy = SandboxPolicy(writable: writable.map(\.url), readable: readable.map(\.url), network: .none, toolchain: false)
        case (.helper(let op), .helper(let placesOp, let targets, let call, let helperDir)) where op == placesOp:
            if case .deny(let why) = inReach(targets, principals: principals, reach: reach) { return .refused(why) }
            policy = SandboxPolicy(writable: [call.url], readable: targets.map(\.url) + [helperDir.url],
                                   network: op == .httpsProbe ? .outbound(allow: network.allowedDomains) : .none, toolchain: false)
        case (.pdfReader(let memoryLimit), .pdfReader(let helper, let held, let out)):
            var p = SandboxPolicy(writable: [out.url], readable: [held.url], network: .none, toolchain: false)
            p.confined = SandboxConfinement(executables: [helper.url], readableFiles: [helper.url],
                                            listableDirectories: [helper.url.deletingLastPathComponent()], writableFiles: [])
            p.memoryLimit = memoryLimit
            policy = p
        default:
            return .refused("the places given (\(places.name)) are not the places of a \(purpose.name)")
        }
        if purpose.runsAgentCommands, principals.allFull, principals.ownerProfile == .full {
            return .fullOptOut(FullOptOut(reason: "the company and every subject of this \(purpose.name) run Full"))
        }
        return validated(policy, baseline: baseline)
    }

    // removed in S12
    /// The one policy not decided by purpose until Plan S Task S12 moves text extraction into the helper
    /// (`.helper(.extractText)`): `SandboxedUnzipReader`'s, unchanged from before Plan S (writable `[unzipped]`, readable
    /// `[held]`, no network, no toolchain, `program` the only thing it runs, `memoryLimit`). The safety lint allows its one
    /// caller (`Refs/TextExtract.swift`) and no other.
    package static func legacyExtract(unzipped: Place, held: Place, program: Place, memoryLimit: Int,
                                      baseline: SandboxBaseline) -> PolicyDecision {
        var policy = SandboxPolicy(writable: [unzipped.url], readable: [held.url], network: .none, toolchain: false)
        policy.confined = SandboxConfinement(executables: [program.url], readableFiles: [], listableDirectories: [], writableFiles: [])
        policy.memoryLimit = memoryLimit
        return validated(policy, baseline: baseline)
    }

    private static func validated(_ policy: SandboxPolicy, baseline: SandboxBaseline) -> PolicyDecision {
        do { return .sandboxed(try SandboxPolicyCheck.validate(policy, baseline: baseline)) } catch { return .refused("\(error)") }
    }

    /// The company's domains plus the set's common grants (already the intersection, already none for an unknown, external
    /// or engine member), normalized, sorted and unique as `CompanyNetwork.scope` gives them; the company's list as it is
    /// when there is no grant.
    private static func withGrants(_ domains: [String], _ grants: [String]) -> [String] {
        guard !grants.isEmpty else { return domains }
        return Array(Set((domains + grants).map(SandboxDomains.normalize))).sorted()
    }

    /// Every target of a helper call inside the subjects' reach (spec §6.4.4). A set with no agent and no owner member
    /// (engine, external, unknown only) reaches the purpose's places only, which its targets are; any agent or owner member
    /// needs the reach the engine built for the set, and every target must be in it.
    private static func inReach(_ targets: [Place], principals: PrincipalSet, reach: Reach?) -> Decision<Void> {
        let needsReach = principals.members.contains { member in
            switch member {
            case .agent, .owner: return true
            case .engine, .external, .unknown: return false
            }
        }
        guard needsReach else { return .allow((), because: "the purpose's places only") }
        guard let reach else { return .deny("no reach was given for the helper call's subjects") }
        for target in targets {
            if case .deny(let why) = reach.admits(target.resolvedPath) { return .deny(why) }
        }
        return .allow((), because: "every place is inside the subjects' reach")
    }
}

import Testing
import Foundation
@testable import BrahmaSafety

/// Plan S Task S7 (spec §6.3, §7.2): `SandboxPolicyFactory.decide` is the only source of Seatbelt policies. For every purpose
/// the decided policy is exactly the one its site built before Plan S (`<purpose>MatchesLegacy`, against a literal
/// `SandboxPolicy` holding the old site's values); Full is for agent-written commands only; the places must be the purpose's
/// own; grants come only from the set's common grants; a helper call never names a place outside its subjects' reach.
@Suite(.scratch) struct SandboxPolicyFactoryTests {
    /// A real temp tree, resolved (`$TMPDIR` sits behind `/var`), with the places every site names.
    struct Tree {
        let root: URL
        let workspace: URL, checkout: URL, run: URL, appData: URL, tools: URL, home: URL, upload: URL, held: URL, unzipped: URL
        let scratch: URL, claudeDir: URL, call: URL, helperDir: URL, helper: URL, ownLab: URL, otherLab: URL, gitDir: URL, out: URL

        init() throws {
            let base = try tempDir().resolvedForSandbox
            root = base
            func dir(_ path: String) throws -> URL {
                let url = base.appending(path: path, directoryHint: .notDirectory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return URL(fileURLWithPath: url.path, isDirectory: false)
            }
            workspace = try dir("ws"); checkout = try dir("home/run/checkouts/r1"); run = try dir("home/run/exports/p1")
            appData = try dir("ws/.brahma/preview/apps/mac"); tools = try dir("home/releases/tools/vercel")
            home = try dir("home/releases/R-1/home"); upload = try dir("home/releases/R-1/upload")
            held = try dir("staging/.zip"); unzipped = try dir("staging/.unzip"); scratch = try dir("scratch")
            claudeDir = try dir("bin/claude-dir"); call = try dir("helper-calls/c1"); helperDir = try dir("bin/helper")
            ownLab = try dir("ws/.brahma/labs/a"); otherLab = try dir("ws/.brahma/labs/b"); gitDir = try dir("ws/.git")
            out = try dir("pdf/out")
            helper = helperDir.appending(path: "brahma-helper")
            try Data("#!/bin/sh\n".utf8).write(to: helper)
        }

        func place(_ url: URL, _ kind: PlaceKind = .directory) throws -> Place { try Place.verify(url, kind: kind, under: root) }
    }

    static let baseline = SandboxBaseline(userHome: URL(fileURLWithPath: "/nonexistent-brahma-owner-home"), protected: [],
                                          darwinUserTemp: nil, darwinUserCache: nil)

    static func agent(_ id: String = "a", profile: PermissionProfile = .workspace, grants: [String] = []) -> Principal {
        .agent(AgentPrincipal(agentId: id, companyId: "c1", role: "engineer", profile: profile, grantDomains: grants))
    }

    static func set(_ members: [Principal], owner: PermissionProfile = .workspace) -> PrincipalSet {
        PrincipalSet(companyId: "c1", members: members, ownerProfile: owner)
    }

    static let sandboxedSet = set([agent()])
    static let engineSet = PrincipalSet(companyId: "", members: [.engine], ownerProfile: .sandboxed)
    static let domains = ["*.stripe.com", "registry.npmjs.org"]

    /// The legacy literal, validated the way the runner validated it before Plan S.
    static func legacy(_ writable: [URL], _ readable: [URL], _ network: SandboxNetwork, toolchain: Bool,
                       _ shape: (inout SandboxPolicy) -> Void = { _ in }) throws -> ValidatedPolicy {
        var p = SandboxPolicy(writable: writable, readable: readable, network: network, toolchain: toolchain)
        shape(&p)
        return try SandboxPolicyCheck.validate(p, baseline: baseline)
    }

    static func sandboxed(_ d: PolicyDecision, sourceLocation: SourceLocation = #_sourceLocation) -> ValidatedPolicy? {
        guard case .sandboxed(let v) = d else { Issue.record("not sandboxed: \(d)", sourceLocation: sourceLocation); return nil }
        return v
    }

    static func decide(_ purpose: Purpose, _ places: PurposePlaces, principals: PrincipalSet = sandboxedSet,
                       network: NetworkScope = .fixed(domains), reach: Reach? = nil) -> PolicyDecision {
        SandboxPolicyFactory.decide(purpose, principals: principals, places: places, network: network, baseline: baseline, reach: reach)
    }

    // MARK: One per purpose: the decided policy is the old site's

    /// `Sandbox/SandboxedCheckRunner.swift`: writable `[checkout]`, readable `[workspace]`, `.outbound(companyDomains)`, toolchain.
    @Test func checkMatchesLegacy() throws {
        let t = try Tree()
        for kind in [CheckKind.submit, .merge, .mergeQueue] {
            let v = Self.sandboxed(Self.decide(.check(kind), .check(checkout: try t.place(t.checkout), workspace: try t.place(t.workspace))))
            #expect(v == (try Self.legacy([t.checkout], [t.workspace], .outbound(allow: Self.domains), toolchain: true)))
        }
    }

    /// `Preview/PreviewModel.swift` (`PreviewPolicy.server`): writable/readable `[run]`, `.loopbackListen(domains, [port])`, toolchain.
    @Test func previewServerMatchesLegacy() throws {
        let t = try Tree()
        let v = Self.sandboxed(Self.decide(.previewServer(port: LoopbackPort(41_000)), .previewServer(run: try t.place(t.run))))
        #expect(v == (try Self.legacy([t.run], [t.run], .loopbackListen(allow: Self.domains, ports: [41_000]), toolchain: true)))
        // A number that is no port gives no port, as `UInt16(exactly:)` did.
        let none = Self.sandboxed(Self.decide(.previewServer(port: LoopbackPort(70_000)), .previewServer(run: try t.place(t.run))))
        #expect(none == (try Self.legacy([t.run], [t.run], .loopbackListen(allow: Self.domains, ports: []), toolchain: true)))
    }

    /// `Preview/PreviewKinds.swift` (`oneShot`): writable/readable `[run]`, `.outbound(domains)`, no toolchain.
    @Test func previewOneShotMatchesLegacy() throws {
        let t = try Tree()
        let v = Self.sandboxed(Self.decide(.previewOneShot, .previewOneShot(run: try t.place(t.run))))
        #expect(v == (try Self.legacy([t.run], [t.run], .outbound(allow: Self.domains), toolchain: false)))
    }

    /// `Preview/PreviewKinds.swift` (`appleBuild`): as `oneShot`, with the toolchain.
    @Test func appleBuildMatchesLegacy() throws {
        let t = try Tree()
        let v = Self.sandboxed(Self.decide(.appleBuild, .appleBuild(run: try t.place(t.run))))
        #expect(v == (try Self.legacy([t.run], [t.run], .outbound(allow: Self.domains), toolchain: true)))
    }

    /// `Preview/PreviewKinds.swift` (`guiApp`): writable `[appData]` named logically, readable `[run]`, `.outbound`, toolchain.
    /// A link at the app-data place (left by the app's previous run) fails the policy check instead of widening the grant.
    @Test func guiAppMatchesLegacy() throws {
        let t = try Tree()
        let ws = try t.place(t.workspace)
        let logical = t.workspace.appending(path: ".brahma/preview/apps/mac", directoryHint: .notDirectory)
        let v = Self.sandboxed(Self.decide(.guiApp(surface: "mac"), .guiApp(run: try t.place(t.run), appData: try Place.logical(logical, under: ws))))
        #expect(v == (try Self.legacy([logical], [t.run], .outbound(allow: Self.domains), toolchain: true)))
        try FileManager.default.removeItem(at: t.appData)
        try FileManager.default.createSymbolicLink(at: t.appData, withDestinationURL: t.scratch)
        guard case .refused = Self.decide(.guiApp(surface: "mac"), .guiApp(run: try t.place(t.run), appData: try Place.logical(logical, under: ws))) else {
            Issue.record("a linked app-data place was not refused"); return
        }
    }

    /// `Release/ReleaseExecutor.swift`, both shapes: the tool install (writable/readable `[tools]`) and a token step
    /// (writable `[home, cwd]`, readable `[cwd, tools]`), each `.outbound(provider list)` with the toolchain.
    @Test func releaseToolMatchesLegacy() throws {
        let t = try Tree()
        let install = Self.sandboxed(Self.decide(.releaseTool, .releaseTool(writable: [try t.place(t.tools)], readable: [try t.place(t.tools)]),
                                                 principals: Self.engineSet, network: .fixed(["registry.npmjs.org"])))
        #expect(install == (try Self.legacy([t.tools], [t.tools], .outbound(allow: ["registry.npmjs.org"]), toolchain: true)))
        let token = Self.sandboxed(Self.decide(.releaseTool, .releaseTool(writable: [try t.place(t.home), try t.place(t.upload)],
                                                                          readable: [try t.place(t.upload), try t.place(t.tools)]),
                                               principals: Self.engineSet, network: .fixed(["api.vercel.com", "vercel.com"])))
        #expect(token == (try Self.legacy([t.home, t.upload], [t.upload, t.tools], .outbound(allow: ["api.vercel.com", "vercel.com"]),
                                          toolchain: true)))
    }

    /// `Store/Store+Release.swift` (`smokePolicy`, also the release build): writable/readable `[export]`, `.outbound`, toolchain.
    @Test func releaseSmokeMatchesLegacy() throws {
        let t = try Tree()
        let v = Self.sandboxed(Self.decide(.releaseSmoke, .releaseSmoke(dir: try t.place(t.run))))
        #expect(v == (try Self.legacy([t.run], [t.run], .outbound(allow: Self.domains), toolchain: true)))
    }

    /// `Hosting/ProviderProbe.swift`, both shapes (the executor's install and token step, as the probe runs them).
    @Test func providerProbeMatchesLegacy() throws {
        let t = try Tree()
        let install = Self.sandboxed(Self.decide(.providerProbe, .providerProbe(writable: [try t.place(t.tools)], readable: [try t.place(t.tools)]),
                                                 principals: Self.engineSet, network: .fixed(["registry.npmjs.org"])))
        #expect(install == (try Self.legacy([t.tools], [t.tools], .outbound(allow: ["registry.npmjs.org"]), toolchain: true)))
        let token = Self.sandboxed(Self.decide(.providerProbe, .providerProbe(writable: [try t.place(t.home), try t.place(t.upload)],
                                                                              readable: [try t.place(t.upload), try t.place(t.tools)]),
                                               principals: Self.engineSet, network: .fixed(["api.vercel.com"])))
        #expect(token == (try Self.legacy([t.home, t.upload], [t.upload, t.tools], .outbound(allow: ["api.vercel.com"]), toolchain: true)))
    }

    /// `Extensions/ExtensionImporter.swift`: writable `[unzipped]`, readable `[held]`, no network, no toolchain.
    @Test func extensionUnzipMatchesLegacy() throws {
        let t = try Tree()
        let v = Self.sandboxed(Self.decide(.extensionUnzip, .extensionUnzip(unzipped: try t.place(t.unzipped), held: try t.place(t.held)),
                                           principals: Self.set([.external(source: "zip")]), network: .none))
        #expect(v == (try Self.legacy([t.unzipped], [t.held], .none, toolchain: false)))
    }

    /// `Extensions/ExtensionValidator.swift`: writable `[scratch]`, readable the claude binary's directory, nothing else.
    @Test func extensionValidateMatchesLegacy() throws {
        let t = try Tree()
        let v = Self.sandboxed(Self.decide(.extensionValidate, .extensionValidate(scratch: try t.place(t.scratch), readable: [try t.place(t.claudeDir)]),
                                           principals: Self.set([.external(source: "acme/tool")]), network: .none))
        #expect(v == (try Self.legacy([t.scratch], [t.claudeDir], .none, toolchain: false)))
    }

    /// `Engine/Doctor+Extensions.swift`: as `extensionValidate`, for the doctor's fixture plugin.
    @Test func doctorExtensionsMatchesLegacy() throws {
        let t = try Tree()
        let v = Self.sandboxed(Self.decide(.doctorExtensions, .doctorExtensions(scratch: try t.place(t.scratch), readable: [try t.place(t.claudeDir)]),
                                           principals: Self.engineSet, network: .none))
        #expect(v == (try Self.legacy([t.scratch], [t.claudeDir], .none, toolchain: false)))
    }

    /// `Safety/SandboxCanary.swift`, both runs: the backend probe (writable `[cwd]`, nothing readable) and the local layer
    /// (writable the scratch then the turn's writable places, readable the turn's readable places), no network, no toolchain.
    @Test func canaryMatchesLegacy() throws {
        let t = try Tree()
        let backend = Self.sandboxed(Self.decide(.canary(.backend), .canary(writable: [try t.place(t.scratch)], readable: []),
                                                 principals: Self.engineSet, network: .none))
        #expect(backend == (try Self.legacy([t.scratch], [], .none, toolchain: false)))
        let local = Self.sandboxed(Self.decide(.canary(.localLayer), .canary(writable: [try t.place(t.scratch), try t.place(t.ownLab)],
                                                                             readable: [try t.place(t.workspace)]),
                                               principals: Self.engineSet, network: .none))
        #expect(local == (try Self.legacy([t.scratch, t.ownLab], [t.workspace], .none, toolchain: false)))
    }

    /// `.helper(op)` (spec §6.4.4; no site before Plan S): writable the call dir, readable the targets and the helper's own
    /// directory, no network (an https probe: its one base host), never the toolchain.
    @Test func helperMatchesLegacy() throws {
        let t = try Tree()
        let ws = try t.place(t.workspace)
        let places = PurposePlaces.helper(op: .worktreeDiff, targets: [try t.place(t.ownLab), try t.place(t.gitDir)], call: try t.place(t.call),
                                          helperDir: try t.place(t.helperDir))
        let v = Self.sandboxed(Self.decide(.helper(.worktreeDiff), places, network: .none, reach: .owner(workspace: ws)))
        #expect(v == (try Self.legacy([t.call], [t.ownLab, t.gitDir, t.helperDir], .none, toolchain: false)))
        let probe = Self.sandboxed(Self.decide(.helper(.httpsProbe), .helper(op: .httpsProbe, targets: [], call: try t.place(t.call),
                                                                             helperDir: try t.place(t.helperDir)),
                                               network: .fixed(["site.example"]), reach: .owner(workspace: ws)))
        #expect(probe == (try Self.legacy([t.call], [t.helperDir], .outbound(allow: ["site.example"]), toolchain: false)))
    }

    /// `Refs/SandboxedPDFReader.swift` (spec §14.1's added site): the deny-default profile running only the helper, reading
    /// only the held copy, writing nothing of its own, with the memory limit.
    @Test func pdfReaderMatchesLegacy() throws {
        let t = try Tree()
        let v = Self.sandboxed(Self.decide(.pdfReader(memoryLimit: 1 << 30), .pdfReader(helper: try t.place(t.helper, .file), held: try t.place(t.held),
                                                                                        out: try t.place(t.out)),
                                           principals: Self.engineSet, network: .none))
        #expect(v == (try Self.legacy([t.out], [t.held], .none, toolchain: false) { p in
            p.confined = SandboxConfinement(executables: [t.helper], readableFiles: [t.helper], listableDirectories: [t.helperDir], writableFiles: [])
            p.memoryLimit = 1 << 30
        }))
    }

    /// `Refs/TextExtract.swift` until S12: `legacyExtract`, unchanged from today.
    @Test func legacyExtractMatchesLegacy() throws {
        let t = try Tree()
        let v = Self.sandboxed(SandboxPolicyFactory.legacyExtract(unzipped: try t.place(t.out), held: try t.place(t.held),
                                                                  program: try t.place(t.helper, .file), memoryLimit: 1 << 30,
                                                                  baseline: Self.baseline))
        #expect(v == (try Self.legacy([t.out], [t.held], .none, toolchain: false) { p in
            p.confined = SandboxConfinement(executables: [t.helper], readableFiles: [], listableDirectories: [], writableFiles: [])
            p.memoryLimit = 1 << 30
        }))
    }

    // MARK: The rules

    static let everyPurpose: [Purpose] = [
        .check(.submit), .previewServer(port: LoopbackPort(41_000)), .previewOneShot, .appleBuild, .guiApp(surface: "mac"), .releaseTool,
        .releaseSmoke, .providerProbe, .extensionUnzip, .extensionValidate, .doctorExtensions, .canary(.backend), .helper(.worktreeDiff),
        .pdfReader(memoryLimit: 1 << 30),
    ]

    /// Each purpose with its own places, for the rule tests.
    static func places(_ purpose: Purpose, _ t: Tree) throws -> PurposePlaces {
        switch purpose {
        case .check: return .check(checkout: try t.place(t.checkout), workspace: try t.place(t.workspace))
        case .previewServer: return .previewServer(run: try t.place(t.run))
        case .previewOneShot: return .previewOneShot(run: try t.place(t.run))
        case .appleBuild: return .appleBuild(run: try t.place(t.run))
        case .guiApp: return .guiApp(run: try t.place(t.run), appData: try t.place(t.appData))
        case .releaseTool: return .releaseTool(writable: [try t.place(t.tools)], readable: [try t.place(t.tools)])
        case .releaseSmoke: return .releaseSmoke(dir: try t.place(t.run))
        case .providerProbe: return .providerProbe(writable: [try t.place(t.tools)], readable: [try t.place(t.tools)])
        case .extensionUnzip: return .extensionUnzip(unzipped: try t.place(t.unzipped), held: try t.place(t.held))
        case .extensionValidate: return .extensionValidate(scratch: try t.place(t.scratch), readable: [try t.place(t.claudeDir)])
        case .doctorExtensions: return .doctorExtensions(scratch: try t.place(t.scratch), readable: [try t.place(t.claudeDir)])
        case .canary: return .canary(writable: [try t.place(t.scratch)], readable: [])
        case .helper(let op): return .helper(op: op, targets: [try t.place(t.ownLab)], call: try t.place(t.call), helperDir: try t.place(t.helperDir))
        case .pdfReader: return .pdfReader(helper: try t.place(t.helper, .file), held: try t.place(t.held), out: try t.place(t.out))
        }
    }

    /// Full opt-out only for purposes that run agent-written commands, with every subject Full-eligible and the company's
    /// own profile Full (spec §6.3.2); a helper call never runs Full.
    @Test func fullOnlyForCodeRunningPurposes() throws {
        let t = try Tree()
        let allFull = Self.set([Self.agent(profile: .full), .owner(companyId: "c1")], owner: .full)
        #expect(allFull.allFull)
        let ws = try t.place(t.workspace)
        guard case .sandboxed = Self.decide(.helper(.worktreeDiff), try Self.places(.helper(.worktreeDiff), t), principals: allFull,
                                            reach: .owner(workspace: ws)) else {
            Issue.record("a helper call ran Full"); return
        }
        guard case .fullOptOut(let optOut) = Self.decide(.check(.submit), try Self.places(.check(.submit), t), principals: allFull) else {
            Issue.record("a Full company's check was not Full"); return
        }
        #expect(!optOut.reason.isEmpty)
        let codeRunning: Set<String> = ["check", "previewServer", "previewOneShot", "appleBuild", "guiApp", "releaseTool", "releaseSmoke"]
        for purpose in Self.everyPurpose {
            let places = try Self.places(purpose, t)
            let decided = Self.decide(purpose, places, principals: allFull, reach: .owner(workspace: ws))
            switch decided {
            case .fullOptOut: #expect(codeRunning.contains(places.name), "\(purpose) ran Full")
            case .sandboxed: #expect(!codeRunning.contains(places.name), "\(purpose) did not run Full in a Full company")
            case .refused(let why): Issue.record("\(purpose) refused: \(why)")
            }
            // The company's own profile not Full, or a member not Full-eligible: never Full.
            for spoiler in [Self.set([Self.agent(profile: .full)], owner: .workspace), Self.set([Self.agent(profile: .full), Self.agent("b")], owner: .full),
                            Self.set([Self.agent(profile: .full), .unknown(reason: "no setter")], owner: .full),
                            Self.set([.owner(companyId: "c1"), .engine], owner: .full), Self.set([.external(source: "x")], owner: .full)] {
                if case .fullOptOut = Self.decide(purpose, places, principals: spoiler, reach: .owner(workspace: ws)) {
                    Issue.record("\(purpose) ran Full for \(spoiler.members)")
                }
            }
        }
    }

    /// The places must be the purpose's own case (spec §6.3.1): anything else is refused, so a caller cannot slip extra
    /// places in.
    @Test func mismatchedPlacesRefused() throws {
        let t = try Tree()
        guard case .refused = Self.decide(.check(.submit), .previewServer(run: try t.place(t.run))) else {
            Issue.record("a check took a preview server's places"); return
        }
        for purpose in Self.everyPurpose {
            for other in Self.everyPurpose where other != purpose {
                let places = try Self.places(other, t)
                if places.name == (try Self.places(purpose, t)).name { continue }
                guard case .refused = Self.decide(purpose, places, reach: .owner(workspace: try t.place(t.workspace))) else {
                    Issue.record("\(purpose) took \(places.name)'s places"); continue
                }
            }
        }
        // A helper's places for another op.
        guard case .refused = Self.decide(.helper(.worktreeDiff), try Self.places(.helper(.stageCopy), t),
                                          reach: .owner(workspace: try t.place(t.workspace))) else {
            Issue.record("a helper call took another op's places"); return
        }
    }

    /// B3 through the factory: a preview server reaches the set's common grants; a set with an unknown (or external, or
    /// engine) member gets none (S6-8); no other purpose takes grants.
    @Test func unknownGetsNoGrants() throws {
        let t = try Tree()
        let place = PurposePlaces.previewServer(run: try t.place(t.run))
        func domains(_ d: PolicyDecision) -> [String] {
            guard case .sandboxed(let v) = d, case .loopbackListen(let allow, _) = v.network else { return ["<not a server>"] }
            return allow
        }
        let granted = Self.set([Self.agent("a", grants: ["grant.example", "both.example"]), Self.agent("b", grants: ["both.example"])])
        #expect(domains(Self.decide(.previewServer(port: LoopbackPort(41_000)), place, principals: granted))
                == (Self.domains + ["both.example"]).sorted())
        for spoiler: Principal in [.unknown(reason: "no setter"), .external(source: "x"), .engine] {
            let spoiled = Self.set([Self.agent("a", grants: ["grant.example"]), spoiler])
            #expect(domains(Self.decide(.previewServer(port: LoopbackPort(41_000)), place, principals: spoiled)) == Self.domains,
                    "\(spoiler) took no grant away")
        }
        // Grants are a preview server's only: a check of the same set reaches the company's domains alone.
        guard case .sandboxed(let check) = Self.decide(.check(.submit), try Self.places(.check(.submit), t), principals: granted) else {
            Issue.record("check refused"); return
        }
        #expect(check.network == .outbound(allow: Self.domains))
    }

    /// A helper call is refused when a place it names is outside its subjects' reach (spec §6.4.4): another agent's lab,
    /// the repository's `.git` internals, a place outside the workspace; an agent or owner subject with no reach given is
    /// refused too; an engine-only set reaches its purpose's places.
    @Test func placesOutsideReachRefused() throws {
        let t = try Tree()
        let ws = try t.place(t.workspace)
        let agentReach = Reach.agent(workspace: ws, denied: [t.gitDir.path, t.workspace.appending(path: ".brahma/labs").path], own: [t.ownLab.path])
        func call(_ target: URL, _ principals: PrincipalSet, _ reach: Reach?) throws -> PolicyDecision {
            Self.decide(.helper(.worktreeDiff), .helper(op: .worktreeDiff, targets: [try t.place(target)], call: try t.place(t.call),
                                                        helperDir: try t.place(t.helperDir)),
                        principals: principals, network: .none, reach: reach)
        }
        let a = Self.set([Self.agent("a")])
        for outside in [t.otherLab, t.gitDir, t.scratch, t.root] {
            guard case .refused = try call(outside, a, agentReach) else { Issue.record("\(outside.path) was in the agent's reach"); continue }
        }
        guard case .sandboxed = try call(t.ownLab, a, agentReach) else { Issue.record("its own lab was out of reach"); return }
        guard case .sandboxed = try call(t.appData.deletingLastPathComponent(), Self.set([.owner(companyId: "c1")]), .owner(workspace: ws)) else {
            Issue.record("the owner's workspace was out of reach"); return
        }
        guard case .refused = try call(t.scratch, Self.set([.owner(companyId: "c1")]), .owner(workspace: ws)) else {
            Issue.record("outside the workspace was in the owner's reach"); return
        }
        // The intersection: the agent's own lab is outside another agent's reach.
        let bReach = Reach.agent(workspace: ws, denied: [t.workspace.appending(path: ".brahma/labs").path], own: [t.otherLab.path])
        guard case .refused = try call(t.ownLab, Self.set([Self.agent("a"), Self.agent("b")]), agentReach.intersection(bReach)) else {
            Issue.record("a lab was in both agents' reach"); return
        }
        guard case .refused = try call(t.ownLab, a, nil) else { Issue.record("an agent subject with no reach was not refused"); return }
        guard case .sandboxed = try call(t.scratch, Self.engineSet, nil) else { Issue.record("an engine call's own place was refused"); return }
    }
}

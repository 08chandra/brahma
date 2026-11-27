import Testing
import Foundation
@testable import BrahmaSafety

/// Plan S Task S7, spec §10.1 (property tests, deterministic seed, `FuzzConfig.cases` each):
/// - **Policy render ≡ validate.** For random policies built from real temp trees with random links, the profile
///   `SeatbeltRunner.prepare` renders holds exactly the strings `SandboxPolicyCheck.validate` accepted, and a link swapped in
///   between the check and the render (the runner's test hook) cannot change the profile text (spec §6.3.3).
/// - **Reach.** For random principal sets and places, `SandboxPolicyFactory.decide` never returns a policy whose places
///   exceed the subjects' reach (plus the call and helper directories), never Full with an unknown, external or engine
///   member, and decides the same for any member order.
@Suite(.scratch) struct PolicyRenderPropertyTests {
    static let baseline = SandboxBaseline(userHome: URL(fileURLWithPath: "/nonexistent-brahma-owner-home"), protected: [],
                                          darwinUserTemp: nil, darwinUserCache: nil)

    final class Hook: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (() -> Void)?
        func set(_ a: @escaping () -> Void) { lock.withLock { action = a } }
        func fire() { let a = lock.withLock { () -> (() -> Void)? in let a = action; action = nil; return a }; a?() }
    }

    /// Every `"…"` string of a profile.
    static func quoted(_ profile: String) -> [String] {
        var out: [String] = [], current = "", inside = false, escaped = false
        for ch in profile {
            if inside {
                if escaped { current.append(ch); escaped = false } else if ch == "\\" { escaped = true }
                else if ch == "\"" { out.append(current); current = ""; inside = false } else { current.append(ch) }
            } else if ch == "\"" { inside = true }
        }
        return out
    }

    @Test func renderUsesValidatedStringsOnly() throws {
        var rng = FuzzConfig.generator()
        let top = try tempDir().resolvedForSandbox
        let fm = FileManager.default
        let hook = Hook()
        let runner = SeatbeltRunner(baseline: { Self.baseline }, proxies: EgressProxyPool(), termGrace: 1, afterValidate: { hook.fire() })
        for n in 0..<FuzzConfig.cases {
            let dir = top.appending(path: "c\(n)", directoryHint: .notDirectory)
            let outside = dir.appending(path: "outside", directoryHint: .notDirectory)
            try fm.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("secret".utf8).write(to: outside.appending(path: "s"))
            // Real directories, some nested, and links among them (never policy entries themselves).
            var real: [URL] = []
            for i in 0..<Int.random(in: 3...6, using: &rng) {
                let parent = real.isEmpty || Bool.random(using: &rng) ? dir : real.randomElement(using: &rng)!
                let d = parent.appending(path: "d\(i)", directoryHint: .notDirectory)
                try fm.createDirectory(at: d, withIntermediateDirectories: true)
                real.append(URL(fileURLWithPath: d.path, isDirectory: false))
            }
            for i in 0..<Int.random(in: 0...3, using: &rng) {
                let at = (real.randomElement(using: &rng) ?? dir).appending(path: "l\(i)")
                try fm.createSymbolicLink(at: at, withDestinationURL: Bool.random(using: &rng) ? outside : real.randomElement(using: &rng)!)
            }
            // Distinct, non-nested entries: the first writable keeps TMPDIR; the rest may be swapped.
            var pool = real.shuffled(using: &rng).filter { d in !real.contains { $0 != d && (SandboxPath.isInside(d.path, $0.path)) } }
            if pool.count < 2 { pool = [real[0]] + (real.count > 1 ? [real.last!] : []) }
            let writable = [pool[0]] + (pool.count > 2 && Bool.random(using: &rng) ? [pool[2]] : [])
            let readable = Array(pool.dropFirst().filter { !writable.contains($0) }.prefix(Int.random(in: 1...3, using: &rng)))
            guard !readable.isEmpty else { continue }
            let policy = SandboxPolicy(writable: writable, readable: readable, network: .none, toolchain: false)
            let v: ValidatedPolicy
            do { v = try SandboxPolicyCheck.validate(policy, baseline: Self.baseline) } catch {
                Issue.record("seed \(FuzzConfig.seed) case \(n): a real tree was refused: \(error)"); continue
            }
            let expected = SeatbeltProfile.render(v, baseline: Self.baseline, proxyPort: nil)
            // Between the runner's check and its render: a readable (or a later writable) entry becomes a link out.
            let victim = (readable + writable.dropFirst()).randomElement(using: &rng)!
            hook.set {
                try? fm.removeItem(at: victim)
                try? fm.createSymbolicLink(at: victim, withDestinationURL: outside)
            }
            let prepared = try runner.prepare(command: "true", environment: [:], policy: v, proxyPort: nil, marker: nil)
            SeatbeltRunner.removeTemp(v)
            let profile = prepared.arguments[2]
            #expect(SandboxPath.kind(victim.path) == .link, "seed \(FuzzConfig.seed) case \(n): the hook did not swap")
            #expect(profile == expected, "seed \(FuzzConfig.seed) case \(n): the swap changed the profile")
            let mine = Self.quoted(profile).filter { $0.hasPrefix(dir.path) }
            #expect(Set(mine) == Set(v.writable + v.readable), "seed \(FuzzConfig.seed) case \(n): \(mine) vs \(v.writable + v.readable)")
            #expect(!profile.contains(outside.path), "seed \(FuzzConfig.seed) case \(n): the link's target reached the profile")
            try? fm.removeItem(at: dir)
        }
    }

    @Test func reachIsNeverExceeded() throws {
        var rng = FuzzConfig.generator()
        let root = try tempDir().resolvedForSandbox
        func dir(_ p: String) throws -> URL {
            let u = root.appending(path: p, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return URL(fileURLWithPath: u.path, isDirectory: false)
        }
        let ws = try dir("ws")
        let tree = [ws, try dir("ws/src"), try dir("ws/.git/objects"), try dir("ws/.brahma/labs/a"), try dir("ws/.brahma/labs/b"),
                    try dir("ws/.brahma/notes/a"), try dir("ws/.brahma/notes/b"), try dir("ws/.brahma/trash"), try dir("outside"),
                    try dir("ws/.brahma/wt/K-1")]
        let call = try dir("calls/c"), helperDir = try dir("bin/helper")
        func place(_ u: URL) throws -> Place { try Place.verify(u, kind: .directory, under: root) }
        let wsPlace = try place(ws)
        func reach(of member: Principal) -> Reach? {
            switch member {
            case .owner: return .owner(workspace: wsPlace)
            case .agent(let a):
                return .agent(workspace: wsPlace, denied: [ws.path + "/.git", ws.path + "/.brahma/labs", ws.path + "/.brahma/notes", ws.path + "/.brahma/trash"],
                              own: [ws.path + "/.brahma/labs/\(a.agentId)", ws.path + "/.brahma/notes/\(a.agentId)"])
            case .engine, .external, .unknown: return nil
            }
        }
        func agent(_ id: String, _ profile: PermissionProfile) -> Principal {
            .agent(AgentPrincipal(agentId: id, companyId: "c1", role: "engineer", profile: profile, grantDomains: ["g.example"]))
        }
        let pool: [Principal] = [agent("a", .full), agent("a", .workspace), agent("b", .full), .owner(companyId: "c1"), .engine,
                                 .external(source: "zip"), .unknown(reason: "no holder")]
        let purposes: [Purpose] = HelperOp.allCases.map { .helper($0) } + [.check(.submit), .previewServer(port: LoopbackPort(4000)), .previewOneShot,
                                                                         .releaseSmoke, .canary(.localLayer)]
        for n in 0..<FuzzConfig.cases {
            let members = (0..<Int.random(in: 1...4, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
            let set = PrincipalSet(companyId: "c1", members: members, ownerProfile: Bool.random(using: &rng) ? .full : .workspace)
            let reaches = set.members.compactMap(reach(of:))
            let given = reaches.dropFirst().reduce(reaches.first) { acc, r in acc?.intersection(r) }
            let purpose = purposes.randomElement(using: &rng)!
            let picks = (0..<Int.random(in: 1...3, using: &rng)).map { _ in tree.randomElement(using: &rng)! }
            let places: PurposePlaces
            switch purpose {
            case .helper(let op): places = .helper(op: op, targets: try picks.map(place), call: try place(call), helperDir: try place(helperDir))
            case .check: places = .check(checkout: try place(picks[0]), workspace: wsPlace)
            case .previewServer: places = .previewServer(run: try place(picks[0]))
            case .previewOneShot: places = .previewOneShot(run: try place(picks[0]))
            case .releaseSmoke: places = .releaseSmoke(dir: try place(picks[0]))
            default: places = .canary(writable: [try place(call)], readable: try picks.map(place))
            }
            let decided = SandboxPolicyFactory.decide(purpose, principals: set, places: places, network: .fixed(["x.example"]),
                                                      baseline: Self.baseline, reach: given)
            let spoiled = set.members.contains { m in
                switch m { case .engine, .external, .unknown: return true; case .agent, .owner: return false }
            }
            if case .fullOptOut = decided {
                #expect(!spoiled, "seed \(FuzzConfig.seed) case \(n): Full with \(set.members)")
                if case .helper = purpose { Issue.record("seed \(FuzzConfig.seed) case \(n): a helper call ran Full") }
            }
            if case .helper = purpose, case .sandboxed(let v) = decided {
                #expect(!v.toolchain, "seed \(FuzzConfig.seed) case \(n): a helper call got the toolchain")
                for path in v.readable + v.writable where path != call.path && path != helperDir.path {
                    if let given {
                        guard case .allow = given.admits(path) else {
                            Issue.record("seed \(FuzzConfig.seed) case \(n): \(path) is outside the reach of \(set.members)"); continue
                        }
                    } else {
                        #expect(!reaches.isEmpty || picks.map(\.path).contains(path), "seed \(FuzzConfig.seed) case \(n): \(path) is no place of the call")
                        #expect(reaches.isEmpty, "seed \(FuzzConfig.seed) case \(n): an agent or owner subject without a reach ran")
                    }
                }
                if case .loopbackListen(let allow, _) = v.network { #expect(!allow.contains("g.example"), "a helper call got a grant") }
                if case .outbound(let allow) = v.network { #expect(!allow.contains("g.example"), "a helper call got a grant") }
            }
            // Member order never matters.
            let shuffled = PrincipalSet(companyId: "c1", members: members.shuffled(using: &rng), ownerProfile: set.ownerProfile)
            #expect(SandboxPolicyFactory.decide(purpose, principals: shuffled, places: places, network: .fixed(["x.example"]),
                                                baseline: Self.baseline, reach: given) == decided,
                    "seed \(FuzzConfig.seed) case \(n): the order of \(members) changed the decision")
        }
    }
}

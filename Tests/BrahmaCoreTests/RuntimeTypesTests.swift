import Testing
import Foundation
@testable import BrahmaCore

// Plan X1 Task 2: the runtime seam's value types. `ModelClass.of(family:)`, the catalog's Claude class map, and the one identity
// the seam must keep: a subscription `TurnShape.key` is today's canary shape string for every golden of Task 1, and a gateway
// key is that string plus `+gateway`.
@Suite(.scratch) struct RuntimeTypesTests {
    /// `opus`→deep, `sonnet`→standard, `haiku`→fast; anything else is no class. Callers pass `ModelAllowlist.family(model)`.
    @Test func modelClassOfFamily() {
        #expect(ModelClass.of(family: "opus") == .deep)
        #expect(ModelClass.of(family: ModelAllowlist.family("claude-opus-5-5")) == .deep)
        #expect(ModelClass.of(family: "sonnet") == .standard)
        #expect(ModelClass.of(family: ModelAllowlist.family("claude-sonnet-5-5")) == .standard)
        #expect(ModelClass.of(family: "haiku") == .fast)
        #expect(ModelClass.of(family: ModelAllowlist.family("gpt-5")) == nil)
        #expect(ModelClass.of(family: "") == nil)
        #expect(ModelClass.allCases.count == 3)
    }

    /// Every golden of Task 1: the subscription key is the recorded `shape`, the gateway key is that string + `+gateway`, and the
    /// shape's fields are the request's own.
    @Test func subscriptionShapeKeyUnchanged() throws {
        let world = try GoldenWorld()
        let names = ParityShapes.allNames.sorted()
        #expect(names.count >= 40, "\(names.count) shapes")
        var checked = 0
        for name in names {
            let request = try goldenRequest(name: name, world: world)
            let golden = try #require(try JSONSerialization.jsonObject(with: Data(try Goldens.read(name).utf8)) as? [String: Any])
            let recorded = try #require(golden["shape"] as? String, "\(name) has no shape")
            let subscription = try TurnShape.of(request, auth: .subscription)
            let gateway = try TurnShape.of(request, auth: .gateway)
            #expect(subscription.key == recorded, "\(name): subscription key changed")
            #expect(gateway.key == recorded + "+gateway", "\(name): gateway key")
            #expect(subscription.auth == .subscription && gateway.auth == .gateway)
            #expect(subscription.profile == request.profile, "\(name)")
            #expect(subscription.kind == request.kind, "\(name)")
            #expect(subscription.mode == request.mode?.mode, "\(name)")
            #expect(subscription.launch == CanaryShape.launch(request.mode), "\(name)")
            #expect(subscription.settingsShape == TurnProfileCompiler.profile(for: request).settings.shape(), "\(name)")
            // The two routes differ in auth only.
            var asSubscription = gateway
            asSubscription.auth = .subscription
            #expect(asSubscription == subscription, "\(name)")
            checked += 1
        }
        #expect(checked == names.count)
    }

    /// The key as code: a launch-less shape is the settings shape; a fan-out shape hashes `settingsShape|launch`.
    @Test func shapeKeyFormula() throws {
        let plain = TurnShape(profile: .sandboxed, kind: .work, mode: .quick, launch: nil, settingsShape: "0123456789abcdef", auth: .subscription)
        #expect(plain.key == "0123456789abcdef")
        let task = TurnShape(profile: .sandboxed, kind: .work, mode: .standard, launch: "task", settingsShape: "0123456789abcdef", auth: .subscription)
        #expect(task.key == StableHash.fnv1a64("0123456789abcdef|task"))
        var gateway = task
        gateway.auth = .gateway
        #expect(gateway.key == task.key + "+gateway")
        // Codable round trip keeps the key.
        let data = try JSONEncoder().encode(gateway)
        #expect(try JSONDecoder().decode(TurnShape.self, from: data).key == gateway.key)
    }

    /// Claude: deep=opus, standard=sonnet, fast=haiku. Another runtime (decoded, the only way in besides the catalog) maps nothing.
    @Test func catalogMapsClaudeClasses() throws {
        #expect(RuntimeCatalog.defaultModel(.deep, on: RuntimeCatalog.claude) == "opus")
        #expect(RuntimeCatalog.defaultModel(.standard, on: RuntimeCatalog.claude) == "sonnet")
        #expect(RuntimeCatalog.defaultModel(.fast, on: RuntimeCatalog.claude) == "haiku")
        let other = try JSONDecoder().decode(RuntimeId.self, from: Data("\"other-runtime\"".utf8))
        #expect(other != RuntimeCatalog.claude)
        for c in ModelClass.allCases { #expect(RuntimeCatalog.defaultModel(c, on: other) == nil) }
        #expect(RuntimeCatalog.runtime(other) == nil)
        // Whatever the catalog lists (nothing until Task 3) answers to its own id.
        for runtime in RuntimeCatalog.all { #expect(RuntimeCatalog.runtime(runtime.id)?.id == runtime.id) }
        let roundTrip = try JSONDecoder().decode(RuntimeId.self, from: JSONEncoder().encode(RuntimeCatalog.claude))
        #expect(roundTrip == RuntimeCatalog.claude)
    }

    /// The small types: a probe round-trips through Codable, a canary shape is equal on its key alone, a compile error compares.
    @Test func valueTypesBehave() throws {
        let probe = RuntimeProbe(runtime: RuntimeCatalog.claude, cliVersion: "2.1.322", passedGates: [ProbeGateId(rawValue: "F7-agents")],
                                 authRoutes: [.subscription, .gateway], notes: ["n"])
        let decoded = try JSONDecoder().decode(RuntimeProbe.self, from: JSONEncoder().encode(probe))
        #expect(decoded == probe)
        #expect(AuthRoute(rawValue: "gateway") == .gateway)

        let a = CanaryTurnShape(shapeKey: "k") { _ in throw RuntimeCompileError.unavailable("a") }
        let b = CanaryTurnShape(shapeKey: "k") { _ in throw RuntimeCompileError.unavailable("b") }
        let c = CanaryTurnShape(shapeKey: "other") { _ in throw RuntimeCompileError.unavailable("c") }
        #expect(a == b)
        #expect(a != c)
        #expect(RuntimeCompileError.unavailable("x") == .unavailable("x"))
        #expect(RuntimeCompileError.unavailable("x") != .unavailable("y"))

        let spec = LaunchSpec(executable: "/usr/local/bin/claude", arguments: ["-p"], environment: ["A": "1"],
                              files: [LaunchFile(path: "/tmp/x", contents: Data("x".utf8))],
                              sandbox: .claudeSettings(path: "/tmp/s.json"), workingDirectory: "/tmp", stdin: "prompt")
        #expect(spec == spec)
        #expect(spec.sandbox != .unsandboxed(.full))
        #expect(TaintSignalMode(rawValue: "syncHook") == .syncHook)
        #expect(UsageSignalMode.allCases.count == 3)
    }
}

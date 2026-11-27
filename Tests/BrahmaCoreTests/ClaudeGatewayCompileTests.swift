import Testing
import Foundation
@testable import BrahmaCore

// Plan X1 Task 12: a `claude` turn compiled for the model gateway (`ClaudeGatewayCompile`, through `ClaudeRuntime.compile`). The
// gateway golden `work-sandboxed-gateway-routed` is recorded and compared by `ClaudeParityGoldenTests` with every subscription
// golden; these tests pin what it must show and what no gateway turn may ever carry (Review Focus 1).

/// The subscription golden of the cell the gateway golden compiles (`ParityShapes.ambientAuthCell`).
private let subscriptionCellName = ParityShapes.ambientAuthCell.name

private func compile(_ r: TurnRequest, world: GoldenWorld, base: [String: String]? = nil) throws -> LaunchSpec {
    try ClaudeRuntime(baseEnvironment: base ?? world.baseEnvironment).compile(r, RuntimeProbe(runtime: RuntimeCatalog.claude))
}

private func value(after flag: String, in argv: [String]) -> String? {
    argv.firstIndex(of: flag).flatMap { argv.indices.contains($0 + 1) ? argv[$0 + 1] : nil }
}

private func goldenArgv(_ name: String) throws -> [String] {
    let golden = try #require(try JSONSerialization.jsonObject(with: Data(try Goldens.read(name).utf8)) as? [String: Any])
    return try #require(golden["argv"] as? [String], "\(name) has no argv")
}

@Suite(.scratch) struct ClaudeGatewayCompileTests {
    /// A routed decision class runs as `brahma-<class>`: the argv is the recorded gateway golden's, with `--model` and
    /// `--fallback-model` both the alias; the settings name the routed aliases; the shape is the `+gateway` key.
    @Test func routedClassUsesAlias() throws {
        let world = try GoldenWorld()
        let golden = try capture(name: ParityShapes.workSandboxedGatewayRouted, world: world)
        #expect(world.normalize(golden.argv.joined(separator: "\n"))
                == (try goldenArgv(ParityShapes.workSandboxedGatewayRouted)).joined(separator: "\n"))
        #expect(value(after: "--model", in: golden.argv) == "brahma-standard")
        #expect(value(after: "--fallback-model", in: golden.argv) == "brahma-standard")
        let settings = try #require(golden.settings as? [String: Any])
        #expect(settings["availableModels"] as? [String] == ["haiku", "sonnet", "opus", "brahma-deep", "brahma-standard"])
        #expect(golden.env["ANTHROPIC_DEFAULT_OPUS_MODEL"] == "brahma-deep")
        #expect(golden.env["ANTHROPIC_DEFAULT_SONNET_MODEL"] == "brahma-standard")
        #expect(golden.env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] == nil, "fast is not routed")
        let plain = try capture(name: subscriptionCellName, world: world)
        #expect(golden.shape == plain.shape + "+gateway")
        // Only the model flags differ from the subscription argv.
        var expected = plain.argv
        for flag in ["--model", "--fallback-model"] { expected[try #require(expected.firstIndex(of: flag)) + 1] = "brahma-standard" }
        #expect(golden.argv == expected)
    }

    /// No routed class for the decision: the argv is the subscription golden's, byte for byte (Anthropic pass-through), the
    /// settings and every file are the subscription turn's, and the environment differs only by the gateway's variables.
    @Test func unroutedAnthropicKeepsArgv() throws {
        let world = try GoldenWorld()
        let plainRequest = try world.request(ParityShapes.ambientAuthCell)
        let plain = try compile(plainRequest, world: world)
        for routed in [Set<ModelClass>(), [.deep], [.deep, .fast]] {
            let spec = try compile(try world.gatewayRequest(routed: routed), world: world)
            #expect(world.normalize(spec.arguments.joined(separator: "\n"))
                    == (try goldenArgv(subscriptionCellName)).joined(separator: "\n"), "routed \(routed)")
            #expect(spec.arguments == plain.arguments)
            if routed.isEmpty {
                // The settings are the subscription turn's but for the config dir's deny entries (Ruling 63).
                let dir = try #require(try world.gatewayRequest().gateway?.configDir)
                func stripped(_ spec: LaunchSpec) throws -> ClaudeSettings {
                    var s = try JSONDecoder().decode(ClaudeSettings.self, from: try #require(spec.files.first?.contents))
                    s.sandbox?.filesystem?.denyWrite?.removeAll { $0 == dir }
                    s.sandbox?.filesystem?.denyRead?.removeAll { $0 == dir }
                    s.permissions?.deny?.removeAll { $0.contains(dir) }
                    return s
                }
                #expect(try stripped(spec) == (try stripped(plain)))
                #expect(spec.files.map(\.path) == plain.files.map(\.path))
            }
            let gatewayNames = ChildEnvironment.gatewayVariables.union(ChildEnvironment.gatewayOverrides)
                .union([ClaudeGatewayCompile.denyProxyMarker])
            let changed = Set(spec.environment.keys).union(plain.environment.keys).filter { spec.environment[$0] != plain.environment[$0] }
            #expect(changed.isSubset(of: gatewayNames), "\(changed.subtracting(gatewayNames).sorted())")
            #expect(spec.environment["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:4100/t/")
        }
    }

    /// For every decision class that is routed, `--fallback-model` is the same alias as `--model`: a fallback never changes the
    /// model (spec §8.2.5).
    @Test func fallbackModelIsSameAlias() throws {
        let world = try GoldenWorld()
        for (model, c) in [("opus", ModelClass.deep), ("sonnet", .standard), ("haiku", .fast), ("claude-opus-5-5", .deep)] {
            var r = try world.gatewayRequest(routed: Set(ModelClass.allCases))
            r.mode?.model = model
            let spec = try compile(r, world: world)
            #expect(value(after: "--model", in: spec.arguments) == "brahma-\(c.rawValue)", "\(model)")
            #expect(value(after: "--fallback-model", in: spec.arguments) == "brahma-\(c.rawValue)", "\(model)")
            #expect(spec.arguments.filter { $0.hasPrefix("brahma-") }.count == 2, "\(model): \(spec.arguments)")
        }
    }

    /// The turn token is in the child environment as `ANTHROPIC_API_KEY` and nowhere else: not in the argv, the settings file,
    /// the MCP config, any other variable or the golden. A launch that would carry it elsewhere is refused.
    @Test func tokenNeverInArgvOrSettings() throws {
        let world = try GoldenWorld()
        let r = try world.gatewayRequest()
        let token = try #require(r.gateway?.token.value)
        let spec = try compile(r, world: world)
        #expect(spec.environment["ANTHROPIC_API_KEY"] == token)
        #expect(spec.environment.filter { $0.value.contains(token) }.keys.sorted() == ["ANTHROPIC_API_KEY"])
        #expect(!spec.arguments.contains { $0.contains(token) })
        for file in spec.files { #expect(!String(decoding: file.contents, as: UTF8.self).contains(token), "\(file.path)") }
        let settingsPath = try #require(value(after: "--settings", in: spec.arguments))
        #expect(spec.files.contains { $0.path == settingsPath })
        let mcp = try String(contentsOfFile: try #require(value(after: "--mcp-config", in: spec.arguments)), encoding: .utf8)
        #expect(!mcp.contains(token))
        #expect(!(try Goldens.read(ParityShapes.workSandboxedGatewayRouted)).contains(token))
        // Fail closed: the token in a file, in the argv or in another variable is refused.
        let g = try #require(r.gateway)
        var inFile = spec
        inFile.files.append(LaunchFile(path: "/x/notes", contents: Data("k=\(token)".utf8)))
        #expect(throws: RuntimeCompileError.self) { try ClaudeGatewayCompile.apply(&inFile, g, decisionModel: "sonnet") }
        var inArgv = spec
        inArgv.arguments.append(token)
        #expect(throws: RuntimeCompileError.self) { try ClaudeGatewayCompile.apply(&inArgv, g, decisionModel: "sonnet") }
        var inEnv = spec
        inEnv.environment["BRAHMA_X"] = token
        #expect(throws: RuntimeCompileError.self) { try ClaudeGatewayCompile.apply(&inEnv, g, decisionModel: "sonnet") }
    }

    /// Every proxy variable names the turn's deny-all proxy and `NO_PROXY` only the loopback names, over whatever the owner
    /// set (lower-case names included); with the traffic switch, the base URL and the agent's config dir. The proxy refuses
    /// a direct call to a vendor host and records it, before any lookup.
    @Test func gatewayTurnHasDenyProxy() async throws {
        let world = try GoldenWorld()
        let pool = EgressProxyPool()
        let proxy = try await pool.proxy(for: [])
        var r = try world.gatewayRequest()
        r.gateway?.denyProxy = "http://127.0.0.1:\(proxy.port)"
        var owner = world.baseEnvironment
        for name in ClaudeGatewayCompile.proxyNames { owner[name] = "http://owner-proxy.example.com:3128" }
        for name in ClaudeGatewayCompile.noProxyNames { owner[name] = "*" }
        owner["CLAUDE_CONFIG_DIR"] = world.userHome.appending(path: "cc").path
        let spec = try compile(r, world: world, base: owner)
        for name in ClaudeGatewayCompile.proxyNames { #expect(spec.environment[name] == "http://127.0.0.1:\(proxy.port)", "\(name)") }
        for name in ClaudeGatewayCompile.noProxyNames { #expect(spec.environment[name] == "127.0.0.1,localhost", "\(name)") }
        #expect(spec.environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        #expect(spec.environment["CLAUDE_CONFIG_DIR"] == world.gatewayLaunch().configDir)
        #expect(spec.environment["CLAUDE_CODE_OAUTH_TOKEN"] == nil && spec.environment["ANTHROPIC_AUTH_TOKEN"] == nil)
        #expect(spec.environment[ClaudeGatewayCompile.denyProxyMarker] == "http://127.0.0.1:\(proxy.port)")
        let reply = try connectThrough(proxy.port, "CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com:443\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 403"), "\(reply)")
        #expect(proxy.deniedHosts.contains("api.anthropic.com"))
        #expect(proxy.allowedHosts.isEmpty)
        await pool.stopAll()
    }

    /// Agent Bash keeps its own network path and never sees the gateway: run through the agent's real shell prefix with the
    /// compiled environment, a command gets no proxy variable holding the deny proxy, no `NO_PROXY` of the gateway's, no
    /// marker and no `ANTHROPIC_*` (the token included). A proxy value the sandbox set for the command is left alone.
    @Test func shellPrefixRestoresProxyForBash() throws {
        let world = try GoldenWorld()
        let spec = try compile(try world.gatewayRequest(), world: world)
        let prefix = try #require(spec.environment["CLAUDE_CODE_SHELL_PREFIX"])
        _ = try ShellPrefix.write(layout: world.layout, paths: world.paths, shell: "/bin/zsh", keepNames: [])
        #expect(prefix == world.layout.shellPrefix.path)
        try FileManager.default.createDirectory(at: world.paths.runDir, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: world.paths.sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: world.paths.sentinel.path)
        defer { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: world.paths.sentinel.path) }

        let bash = try runPrefix(prefix, "env", environment: spec.environment)
        #expect(bash.status == 0, "\(bash.err)")
        let env = Dictionary(bash.out.split(separator: "\n").compactMap { line -> (String, String)? in
            let parts = line.split(separator: "=", maxSplits: 1)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { $1 })
        let deny = try #require(spec.environment["HTTPS_PROXY"])
        #expect(!env.values.contains(deny), "\(env.filter { $0.value == deny }.keys.sorted())")
        for name in ClaudeGatewayCompile.proxyNames + ClaudeGatewayCompile.noProxyNames { #expect(env[name] == nil, "\(name)") }
        #expect(env[ClaudeGatewayCompile.denyProxyMarker] == nil)
        #expect(!env.keys.contains { $0.hasPrefix("ANTHROPIC_") }, "\(env.keys.sorted())")
        #expect(!bash.out.contains(world.gatewayLaunch().token.value))

        // The sandbox's own proxy for the command survives; so does a NO_PROXY that is not the gateway's.
        var sandboxed = spec.environment
        sandboxed["HTTPS_PROXY"] = "http://localhost:51515"
        sandboxed["no_proxy"] = "localhost,127.0.0.1,::1"
        let kept = try runPrefix(prefix, "echo \"$HTTPS_PROXY|$no_proxy|${HTTP_PROXY:-unset}\"", environment: sandboxed)
        #expect(kept.out == "http://localhost:51515|localhost,127.0.0.1,::1|unset\n", "\(kept.out) \(kept.err)")

        // A subscription turn's environment is untouched by the drop (no marker): the owner's proxy passes as before.
        var subscription = world.baseEnvironment
        subscription["HTTPS_PROXY"] = deny
        let plain = try runPrefix(prefix, "echo \"$HTTPS_PROXY\"", environment: subscription)
        #expect(plain.out == deny + "\n")
    }

    /// The gateway config dir is the agent's own, in the engine's run area (Ruling 63), the same for every gateway turn of the
    /// agent (so `--resume` keeps working), another agent's differs, it is never the owner's config dir, and it lies outside
    /// every place the turn can reach.
    @Test func configDirIsPerAgentAndStable() throws {
        let world = try GoldenWorld()
        let dir = try GatewayConfigDir.directory(paths: world.paths, agentId: world.eng.id).path
        #expect(dir == world.gatewayLaunch().configDir)
        #expect(dir == world.paths.runDir.appending(path: "gateway-config/\(world.eng.id)").path)
        #expect(dir != (try GatewayConfigDir.directory(paths: world.paths, agentId: "other-agent")).path)
        #expect(throws: GatewayConfigDir.Refusal.self) { try GatewayConfigDir.directory(paths: world.paths, agentId: "../x") }
        // Two turns, two tokens, one config dir; set on every gateway turn whatever the owner's environment holds.
        var owner = world.baseEnvironment
        owner["CLAUDE_CONFIG_DIR"] = world.userHome.appending(path: "owner-cc").path
        var second = try world.gatewayRequest()
        second.gateway?.token = GatewayToken.mint()
        let a = try compile(try world.gatewayRequest(), world: world, base: owner)
        let b = try compile(second, world: world, base: owner)
        #expect(a.environment["CLAUDE_CONFIG_DIR"] == dir && b.environment["CLAUDE_CONFIG_DIR"] == dir)
        #expect(a.environment["ANTHROPIC_API_KEY"] != b.environment["ANTHROPIC_API_KEY"])
        // The owner's own config dir (or a place in it), a relative path or one with `..` is refused.
        for bad in [owner["CLAUDE_CONFIG_DIR"]!, owner["CLAUDE_CONFIG_DIR"]! + "/agents/x", world.userHome.appending(path: ".claude").path,
                    "relative/cc", dir + "/../../x", dir + "/", "/x/it's"] {
            var r = try world.gatewayRequest()
            r.gateway?.configDir = bad
            #expect(throws: RuntimeCompileError.self, "\(bad)") { try compile(r, world: world, base: owner) }
        }
    }

    /// Ruling 63 (X1-39): the config dir lies outside every place the sandboxed turn can write or read, and the compiled
    /// settings deny Bash writes and reads to it and the Read/Edit/Write tools on it. A dir in the agent's home, its worktree,
    /// its Claude temp dir or the workspace (where the agent could plant settings or hooks) never compiles.
    @Test func configDirOutsideTheSandboxAndDenied() throws {
        let world = try GoldenWorld()
        let r = try world.gatewayRequest()
        let dir = try #require(r.gateway?.configDir)
        let scope = try #require(r.sandbox)
        for place in ClaudeRuntime.reachablePlaces(r) + scope.writable.map(\.path) + [scope.cwd.path] {
            #expect(!dir.hasPrefix(place + "/") && dir != place, "\(dir) is in \(place)")
        }
        let spec = try compile(r, world: world)
        let settingsPath = try #require(value(after: "--settings", in: spec.arguments))
        let file = try #require(spec.files.first { $0.path == settingsPath })
        let settings = try JSONDecoder().decode(ClaudeSettings.self, from: file.contents)
        let fs = try #require(settings.sandbox?.filesystem)
        #expect(fs.denyWrite?.contains(dir) == true && fs.denyRead?.contains(dir) == true)
        #expect(!(fs.allowWrite ?? []).contains { dir == $0 || dir.hasPrefix($0 + "/") }, "\(fs.allowWrite ?? [])")
        #expect(!(fs.allowRead ?? []).contains { dir == $0 || dir.hasPrefix($0 + "/") }, "\(fs.allowRead ?? [])")
        let deny = settings.permissions?.deny ?? []
        for tool in ["Read", "Edit", "Write"] {
            #expect(deny.contains("\(tool)(/\(dir))") && deny.contains("\(tool)(/\(dir)/**)"), "\(tool)")
        }
        // The data home stays a protected root as well (denyRead/denyWrite and the Read/Edit rules), as the owner's ~/.claude.
        #expect(fs.denyWrite?.contains(world.paths.home.path) == true && deny.contains("Edit(/\(world.paths.home.path)/**)"))
        // A subscription turn's settings are untouched (its golden is byte-identical).
        let plain = try compile(try world.request(ParityShapes.ambientAuthCell), world: world)
        #expect(!plain.files.contains { String(decoding: $0.contents, as: UTF8.self).contains("gateway-config") })
        // Agent-reachable places are refused.
        let refused = [world.layout.agentHome.appending(path: ".claude-gateway").path, world.ws.appending(path: "cc").path,
                       try #require(scope.claudeTmp).appending(path: "cc").path, scope.cwd.path]
        for bad in refused {
            var g = r
            g.gateway?.configDir = bad
            #expect(throws: RuntimeCompileError.self, "\(bad)") { try compile(g, world: world) }
        }
    }

    /// An `anthropic/<model>` route still runs as its alias, and the gateway serves the alias by its route: only the body's
    /// `model` field changes upstream.
    @Test func anthropicRouteRewritesModel() async throws {
        let world = try GoldenWorld()
        var r = try world.gatewayRequest(routed: [.deep])
        r.mode?.model = "opus"
        let spec = try compile(r, world: world)
        let sent = try #require(value(after: "--model", in: spec.arguments))
        #expect(sent == "brahma-deep")
        let rig = try ModelGatewayRig([ModelGatewayTests.ok])
        let token = rig.grant(aliases: [sent: .init(provider: "anthropic", model: "claude-opus-5-5")], passThrough: [])
        let response = try await rig.exchange(ModelGatewayTests.body(sent), token: token)
        #expect(response.status == 200, "\(response.text)")
        let upstream = try #require(rig.upstream.requests.first)
        #expect(String(decoding: upstream.body, as: UTF8.self) == ModelGatewayTests.body("claude-opus-5-5"))
    }

    /// Fail closed: a malformed launch never compiles — no base URL without a well-formed token, a gateway or deny proxy off
    /// loopback, the same port for both, an alias that is not `brahma-<class>`.
    @Test func malformedGatewayLaunchRefused() throws {
        let world = try GoldenWorld()
        let edits: [(String, (inout GatewayLaunch) -> Void)] = [
            ("token", { $0.token = GatewayToken(value: String(repeating: "A", count: 64)) }),
            ("short token", { $0.token = GatewayToken(value: "abc") }),
            ("remote base", { $0.baseURL = "https://api.anthropic.com/" }),
            ("no prefix", { $0.baseURL = "http://127.0.0.1:4100/" }),
            ("localhost base", { $0.baseURL = "http://localhost:4100/t/" }),
            ("port 0", { $0.baseURL = "http://127.0.0.1:0/t/" }),
            ("port 70000", { $0.baseURL = "http://127.0.0.1:70000/t/" }),
            ("remote proxy", { $0.denyProxy = "http://proxy.example.com:3128" }),
            ("same port", { $0.denyProxy = "http://127.0.0.1:4100" }),
            ("alias", { $0.aliases[.deep] = "claude-opus-5-5" }),
        ]
        for (label, edit) in edits {
            var r = try world.gatewayRequest()
            var g = try #require(r.gateway)
            edit(&g)
            r.gateway = g
            #expect(throws: RuntimeCompileError.self, "\(label)") { try compile(r, world: world) }
        }
        // `apply` on a launch whose environment was not compiled for the gateway refuses too.
        var plain = try compile(try world.request(ParityShapes.ambientAuthCell), world: world)
        #expect(throws: RuntimeCompileError.self) { try ClaudeGatewayCompile.apply(&plain, world.gatewayLaunch(), decisionModel: "sonnet") }
    }

    /// The aliases join the allowlist the audit and the validator read (Ruling 62), but an agent can never pin one: a pinned
    /// alias would reach Anthropic as is.
    @Test func aliasesAllowedButNeverPinned() {
        for c in ModelClass.allCases {
            let alias = GatewayLaunch.alias(c)
            #expect(ModelAllowlist.allows(alias) && ModelAllowlist.isGatewayAlias(alias))
            var i = ModeInputs()
            i.agentModel = alias
            #expect(ModePolicy.select(i).refusal != nil, "\(alias) pinned")
            let usage = TurnResult(isError: false, subtype: "success", text: "", costUSD: 0, apiErrorStatus: nil, sessionId: "s",
                                   modelsUsed: [alias])
            #expect(TurnAudit.findings(result: usage, initModel: alias, main: "sonnet", fallback: "sonnet", expectations: nil).isClean)
        }
        let other = TurnResult(isError: false, subtype: "success", text: "", costUSD: 0, apiErrorStatus: nil, sessionId: "s",
                               modelsUsed: ["brahma-x"])
        #expect(!TurnAudit.findings(result: other, initModel: nil, main: "sonnet", fallback: "sonnet", expectations: nil).isClean)
        #expect(!ModelAllowlist.allows("brahma-x"))
        // `claude`'s stderr note for an alias it does not know is never an infrastructure failure (Ruling 20).
        #expect(EngineHealth.classify(text: "[claude-code:unrecognized_model] brahma-standard", apiErrorStatus: nil) == .none)
    }
}

/// One CONNECT to the proxy on loopback; its reply head.
private func connectThrough(_ port: UInt16, _ request: String) throws -> String {
    let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
    guard fd >= 0 else { throw POSIXError(.EMFILE) }
    defer { close(fd) }
    var tv = timeval(tv_sec: 20, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard ok == 0 else { throw POSIXError(.ECONNREFUSED) }
    _ = request.withCString { write(fd, $0, strlen($0)) }
    var got = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !String(decoding: got, as: UTF8.self).contains("\r\n\r\n") {
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        got += buffer[0..<n]
    }
    return String(decoding: got, as: UTF8.self)
}

/// The prefix run the way Claude Code runs `CLAUDE_CODE_SHELL_PREFIX`: `/bin/sh <prefix> <command>`.
private func runPrefix(_ prefix: String, _ command: String, environment: [String: String]) throws -> (status: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [prefix, command]
    p.environment = environment
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
}

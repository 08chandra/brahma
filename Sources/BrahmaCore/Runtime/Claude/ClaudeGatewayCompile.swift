import Foundation

// Plan X1 Task 12: a `claude` turn compiled for the model gateway (spec §8.2, Review Focus 1). `ClaudeRuntime.compile` calls
// this when `TurnRequest.gateway` is set; a subscription turn (gateway nil) never reaches it, so every subscription golden is
// unchanged.
//
// No subscription path, by construction:
// - `ANTHROPIC_BASE_URL` is the loopback gateway and `ANTHROPIC_API_KEY` the turn's token, so `claude` authenticates with the
//   token (`apiKeySource: ANTHROPIC_API_KEY`, X1-0 h1b) and never with the owner's login. The compile refuses to emit the base
//   URL without a well-formed token (Rulings 20, 32): a base URL alone makes `claude` forward the owner's OAuth bearer (X1-0 h2).
// - The four proxy variables name the turn's claude proxy (`claudeProxy`: an `EgressProxy` allowing only the turn's web
//   domains, deny-all when there are none; Ruling 64(2)) and the two `NO_PROXY` names only the loopback names. `DomainMatcher`
//   refuses every vendor root (anthropic.com, claude.ai, claude.com) whatever the list says, so a direct call from `claude`
//   to a vendor host is refused and logged by that proxy, while WebFetch keeps the turn's web domains.
// - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (zero CONNECTs with it, X1-0).
// - `CLAUDE_CONFIG_DIR` is the agent's own isolated gateway config dir, ALWAYS (Ruling 62): the owner's hooks, plugins and
//   login never load in a gateway turn.
// The agent's Bash gets none of it, on every profile: the shell prefix (the sandboxed one, or on Workspace and Full the minimal
// gateway prefix, Ruling 64(1)) puts the owner's proxy values back where the claude proxy's are (keyed on `claudeProxyMarker`)
// and unsets every `ANTHROPIC_*` (the token included). WebSearch, a server tool the gateway refuses (X1-34), is not offered.
//
// Nothing here fails open (`GatewayFailOpenLintTests`): no `try?`, no `?? true` / `?? false`, no empty `catch`.

public enum ClaudeGatewayCompile {
    /// `NO_PROXY` on a gateway turn: the loopback names only (the gateway is on 127.0.0.1).
    public static let noProxy = "127.0.0.1,localhost"
    /// The four proxy variables `claude` (Node) reads; all name the claude proxy. With the two `noProxyNames` they are the six
    /// proxy names a gateway turn always fills (Ruling 33).
    public static let proxyNames = ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"]
    public static let noProxyNames = ["NO_PROXY", "no_proxy"]
    /// The engine variable that tells the shell prefix which proxy value is the turn's claude proxy, so agent Bash never
    /// inherits it (not a secret: the proxy only lets the turn's web domains through).
    public static let claudeProxyMarker = "BRAHMA_CLAUDE_PROXY"
    /// `BRAHMA_BASE_<name>`: the owner's value of one of the six proxy names, which the shell prefix puts back for agent Bash.
    public static let baseProxyPrefix = "BRAHMA_BASE_"
    /// The server tool the gateway's policy refuses (X1-34): never offered on a gateway turn.
    public static let refusedTools = ["WebSearch"]

    /// Which `ANTHROPIC_DEFAULT_*_MODEL` names a class: `opus`, `sonnet` and `haiku` are what `claude` resolves its own
    /// aliases (and a forced sub-agent's `sonnet`) through.
    public static let defaultModelVariable: [ModelClass: String] = [
        .deep: "ANTHROPIC_DEFAULT_OPUS_MODEL", .standard: "ANTHROPIC_DEFAULT_SONNET_MODEL", .fast: "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    ]

    /// The `gateway:` part of the child environment (`ChildEnvironment.make(gateway:)`): the base URL, the token, the traffic
    /// switch, the default-model variable of each routed class, the claude proxy in the four proxy names, the loopback names
    /// in the two `NO_PROXY` names, and the config dir. Refused (fail closed) when `g` is malformed: a token that is not
    /// `TurnTokenFormat`, a base URL that is not `http://127.0.0.1:<port>/t/`, a claude proxy that is not
    /// `http://127.0.0.1:<port>` or is the gateway's own port, an alias
    /// that is not `brahma-<class>`, or a config dir that is not a plain absolute path, is (or lies in) the owner's own config
    /// dir in `owner` (the launcher's environment), or is (or lies in, or holds) one of `reachable`, the places the turn's
    /// sandbox or tools can reach (Ruling 63: the dir is `GatewayConfigDir`'s, in the engine's run area).
    public static func environment(_ g: GatewayLaunch, owner: [String: String] = [:],
                                   reachable: [String] = []) throws(RuntimeCompileError) -> [String: String] {
        guard TurnTokenFormat.isWellFormed(g.token.value) else {
            throw .invalid("the gateway turn has no well-formed turn token; it was not started (no base URL without a token)")
        }
        guard let gatewayPort = loopbackPort(g.baseURL, path: GatewayRoutes.prefix) else {
            throw .invalid("the gateway base URL must be http://127.0.0.1:<port>\(GatewayRoutes.prefix)")
        }
        guard let proxyPort = loopbackPort(g.claudeProxy, path: ""), proxyPort != gatewayPort else {
            throw .invalid("the gateway turn's claude proxy must be http://127.0.0.1:<port>, not the gateway's port")
        }
        for (c, alias) in g.aliases where alias != GatewayLaunch.alias(c) {
            throw .invalid("the \(c.rawValue) alias must be \(GatewayLaunch.alias(c))")
        }
        try checkConfigDir(g.configDir, owner: owner, reachable: reachable)
        var env = ["ANTHROPIC_BASE_URL": g.baseURL, "ANTHROPIC_API_KEY": g.token.value,
                   "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CONFIG_DIR": g.configDir]
        for (c, alias) in g.aliases { if let name = defaultModelVariable[c] { env[name] = alias } }
        for name in proxyNames { env[name] = g.claudeProxy }
        for name in noProxyNames { env[name] = noProxy }
        return env
    }

    /// The engine variables (`extra`, `BRAHMA_*`) a gateway turn adds for the shell prefix: the claude-proxy marker, and
    /// `BRAHMA_BASE_<name>` for each of the six proxy names the owner's environment (`base`) passes to a turn, so agent Bash
    /// gets the owner's value back (or none, when the owner set none).
    public static func extra(_ g: GatewayLaunch, base: [String: String] = [:]) -> [String: String] {
        var extra = [claudeProxyMarker: g.claudeProxy]
        let passed = ChildEnvironment.make(base: base, purpose: .claude)
        for name in proxyNames + noProxyNames { if let value = passed[name] { extra[baseProxyPrefix + name] = value } }
        return extra
    }

    /// The web domains the turn's claude proxy allows (`EgressProxyPool.proxy(for:)`, Ruling 64(2)): the sandboxed turn's
    /// WebFetch domains (`scope.network.webDomains`, exactly the subscription turn's), or on Workspace and Full the company's
    /// (`CompanyNetwork.scope`: registries, docs and the owner's web domains). Never a vendor root (`DomainMatcher` refuses
    /// them anyway). Empty means deny-all.
    public static func claudeProxyDomains(_ r: TurnRequest) -> [String] {
        let domains = r.profile == .sandboxed
            ? (r.sandbox?.network.webDomains ?? [])
            : CompanyNetwork.scope(company: r.company, grantDomains: [], grantWebDomains: []).webDomains
        return domains.filter { !SandboxDomains.isForbidden($0) }
    }

    /// A gateway turn's own shell prefix on Workspace and Full (`ShellPrefix.writeGateway`): the path must name one.
    public static func isGatewayShellPrefix(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return path.hasPrefix("/") && !path.contains(where: \.isWhitespace) && !SandboxPath.isUnsafe(path)
            && name.hasPrefix(ShellPrefix.gatewayPrefixName) && name.hasSuffix(".sh")
    }

    /// The turn's settings for the gateway: `availableModels` gains the routed aliases (Ruling 62), so `--model brahma-<class>`
    /// is a model the turn may name; and the config dir is named in the deny lists (Ruling 63) — the sandbox's `denyWrite` and
    /// `denyRead` for Bash, and `Read`/`Edit`/`Write` deny rules for the tools, as the owner's `~/.claude` is. It already lies
    /// in the data home, a protected root of every sandboxed turn; this says it again for the one dir a turn's CLI writes.
    /// Only strings join existing non-empty arrays: the settings shape is unchanged.
    public static func settings(_ s: inout ClaudeSettings, _ g: GatewayLaunch) {
        if var models = s.availableModels {
            for c in ModelClass.allCases { if let alias = g.aliases[c], !models.contains(alias) { models.append(alias) } }
            s.availableModels = models
        }
        let forms = Array(Set([g.configDir, SandboxPath.resolve(g.configDir)])).sorted()
        func adding(_ list: [String]?, _ more: [String]) -> [String] { (list ?? []) + more.filter { !(list ?? []).contains($0) } }
        if var sandbox = s.sandbox, var fs = sandbox.filesystem {
            fs.denyWrite = adding(fs.denyWrite, forms)
            fs.denyRead = adding(fs.denyRead, forms)
            sandbox.filesystem = fs
            s.sandbox = sandbox
        }
        let rules = forms.flatMap { p in ["Read", "Edit", "Write"].flatMap { ClaudeSettingsCompiler.rules($0, p) } }
        var permissions = s.permissions ?? ClaudeSettings.Permissions()
        permissions.deny = adding(permissions.deny, rules)
        s.permissions = permissions
    }

    /// Finishes a launch compiled with `environment(g)` in its child environment: checks that the environment carries the
    /// gateway values (and no owner login), then, when the decision model's class is routed, `--model brahma-<class>` and
    /// `--fallback-model brahma-<class>` (the fallback never changes the model, spec §8.2.5); otherwise the argv is
    /// unchanged (Anthropic pass-through). Refuses (fail closed) a launch whose environment lost a gateway value, carries a
    /// Claude login variable, or holds the token anywhere but `ANTHROPIC_API_KEY`.
    public static func apply(_ spec: inout LaunchSpec, _ g: GatewayLaunch, decisionModel: String) throws(RuntimeCompileError) {
        let expected = try environment(g)
        for (name, value) in expected.merging([claudeProxyMarker: g.claudeProxy], uniquingKeysWith: { $1 })
        where spec.environment[name] != value {
            throw .invalid("the gateway turn's environment lacks \(name); it was not started")
        }
        // Agent Bash must never inherit the claude proxy or the token: every gateway turn runs its Bash through a prefix.
        guard let prefix = spec.environment["CLAUDE_CODE_SHELL_PREFIX"], !prefix.isEmpty else {
            throw .invalid("the gateway turn has no shell prefix for agent Bash; it was not started")
        }
        for name in ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"] where spec.environment[name] != nil {
            throw .invalid("the gateway turn's environment carries \(name); it was not started")
        }
        let token = g.token.value
        let leaks = spec.environment.filter { $0.key != "ANTHROPIC_API_KEY" && $0.value.contains(token) }.keys.sorted()
            + spec.arguments.filter { $0.contains(token) }.map { _ in "argv" }
            + spec.files.filter { String(decoding: $0.contents, as: UTF8.self).contains(token) }.map(\.path)
        if let leak = leaks.first {
            throw .invalid("the gateway turn's token would reach \(leak); it was not started")
        }
        removeRefusedTools(&spec.arguments)
        guard let c = ModelClass.of(family: ModelAllowlist.family(decisionModel)), let alias = g.aliases[c] else { return }
        for flag in ["--model", "--fallback-model"] {
            guard let i = spec.arguments.firstIndex(of: flag), spec.arguments.indices.contains(i + 1) else {
                throw .invalid("the gateway turn's argv has no \(flag)")
            }
            spec.arguments[i + 1] = alias
        }
    }

    /// `refusedTools` leave `--tools` (when the turn names its tools) and join `--disallowed-tools` (every turn names those).
    static func removeRefusedTools(_ argv: inout [String]) {
        if let i = argv.firstIndex(of: "--tools"), argv.indices.contains(i + 1) {
            argv[i + 1] = argv[i + 1].split(separator: ",").map(String.init).filter { !refusedTools.contains($0) }.joined(separator: ",")
        }
        if let i = argv.firstIndex(of: "--disallowed-tools"), argv.indices.contains(i + 1) {
            var tools = argv[i + 1].split(separator: ",").map(String.init)
            for tool in refusedTools where !tools.contains(tool) { tools.append(tool) }
            argv[i + 1] = tools.joined(separator: ",")
        } else {
            argv += ["--disallowed-tools", refusedTools.joined(separator: ",")]
        }
    }

    /// The port of `http://127.0.0.1:<port><path>` (1-65535, no leading zero), or nil for anything else.
    static func loopbackPort(_ url: String, path: String) -> Int? {
        let head = "http://127.0.0.1:"
        guard url.hasPrefix(head), url.hasSuffix(path), url.count > head.count + path.count else { return nil }
        let digits = url.dropFirst(head.count).dropLast(path.count)
        guard digits.count <= 5, digits.first != "0", digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(digits), (1...65535).contains(port) else { return nil }
        return port
    }

    /// A plain absolute path (no `.`/`..` component, no quote, backslash or control character), never the owner's config dir
    /// (`CLAUDE_CONFIG_DIR`, else `$HOME/.claude`) or a place inside it, and never a place a turn reaches (`reachable`: equal,
    /// inside or above one, in either the given or the resolved form).
    static func checkConfigDir(_ dir: String, owner: [String: String], reachable: [String]) throws(RuntimeCompileError) {
        let components = dir.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard dir.hasPrefix("/"), dir.count > 1, !SandboxPath.isUnsafe(dir), !dir.hasSuffix("/"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw .invalid("the gateway config dir must be a plain absolute path")
        }
        var owned: [String] = []
        if let d = owner["CLAUDE_CONFIG_DIR"], !d.isEmpty { owned.append(d) }
        if let home = owner["HOME"], !home.isEmpty { owned.append(home.hasSuffix("/") ? home + ".claude" : home + "/.claude") }
        for o in owned {
            let root = o.hasSuffix("/") ? String(o.dropLast()) : o
            if dir == root || dir.hasPrefix(root + "/") {
                throw .invalid("the gateway config dir may never be the owner's Claude config dir")
            }
        }
        let forms = Set([dir, SandboxPath.resolve(dir)])
        for place in reachable where !place.isEmpty {
            for p in Set([place, SandboxPath.resolve(place)]) {
                let root = p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
                for d in forms where d == root || d.hasPrefix(root + "/") || root.hasPrefix(d + "/") {
                    throw .invalid("the gateway config dir must lie outside every place the turn can reach (\(root))")
                }
            }
        }
    }
}

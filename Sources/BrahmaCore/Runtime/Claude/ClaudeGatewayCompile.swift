import Foundation

// Plan X1 Task 12: a `claude` turn compiled for the model gateway (spec §8.2, Review Focus 1). `ClaudeRuntime.compile` calls
// this when `TurnRequest.gateway` is set; a subscription turn (gateway nil) never reaches it, so every subscription golden is
// unchanged.
//
// No subscription path, by construction:
// - `ANTHROPIC_BASE_URL` is the loopback gateway and `ANTHROPIC_API_KEY` the turn's token, so `claude` authenticates with the
//   token (`apiKeySource: ANTHROPIC_API_KEY`, X1-0 h1b) and never with the owner's login. The compile refuses to emit the base
//   URL without a well-formed token (Rulings 20, 32): a base URL alone makes `claude` forward the owner's OAuth bearer (X1-0 h2).
// - Every proxy variable names a deny-all egress proxy and `NO_PROXY` only the loopback names, so a direct call from `claude`
//   to any vendor host is refused and logged by that proxy.
// - `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (zero CONNECTs with it, X1-0).
// - `CLAUDE_CONFIG_DIR` is the agent's own isolated gateway config dir, ALWAYS (Ruling 62): the owner's hooks, plugins and
//   login never load in a gateway turn.
// The agent's Bash gets none of it: the shell prefix scrubs `ANTHROPIC_*` (the token included) and drops the deny proxy
// (`ShellPrefix`, keyed on `denyProxyMarker`).
//
// Nothing here fails open (`GatewayFailOpenLintTests`): no `try?`, no `?? true` / `?? false`, no empty `catch`.

public enum ClaudeGatewayCompile {
    /// `NO_PROXY` on a gateway turn: the loopback names only (the gateway is on 127.0.0.1).
    public static let noProxy = "127.0.0.1,localhost"
    /// The four proxy variables `claude` (Node) reads; all name the deny proxy.
    public static let proxyNames = ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"]
    public static let noProxyNames = ["NO_PROXY", "no_proxy"]
    /// The engine variable that tells the shell prefix which proxy value is the turn's deny proxy, so agent Bash never
    /// inherits it (it is not a secret: the proxy refuses everything).
    public static let denyProxyMarker = "BRAHMA_DENY_PROXY"
    /// The gateway config dir's name inside the agent home (`configDir(layout:)`).
    public static let configDirName = ".claude-gateway"

    /// Which `ANTHROPIC_DEFAULT_*_MODEL` names a class: `opus`, `sonnet` and `haiku` are what `claude` resolves its own
    /// aliases (and a forced sub-agent's `sonnet`) through.
    public static let defaultModelVariable: [ModelClass: String] = [
        .deep: "ANTHROPIC_DEFAULT_OPUS_MODEL", .standard: "ANTHROPIC_DEFAULT_SONNET_MODEL", .fast: "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    ]

    /// The agent's isolated, persistent gateway config dir: `<agent home>/.claude-gateway` (Ruling 62). The same for every
    /// gateway turn of the agent, so `--resume` keeps working; an empty scratch dir the launcher creates, never a copy of the
    /// owner's.
    public static func configDir(layout: SandboxLayout) -> URL {
        layout.agentHome.appending(path: configDirName, directoryHint: .isDirectory)
    }

    /// The `gateway:` part of the child environment (`ChildEnvironment.make(gateway:)`): the base URL, the token, the traffic
    /// switch, the default-model variable of each routed class, the deny proxy in all six proxy names and the config dir.
    /// Refused (fail closed) when `g` is malformed: a token that is not `TurnTokenFormat`, a base URL that is not
    /// `http://127.0.0.1:<port>/t/`, a deny proxy that is not `http://127.0.0.1:<port>` or is the gateway's own port, an alias
    /// that is not `brahma-<class>`, or a config dir that is not a plain absolute path or is (or lies in) the owner's own config
    /// dir in `owner` (the launcher's environment).
    public static func environment(_ g: GatewayLaunch, owner: [String: String] = [:]) throws(RuntimeCompileError) -> [String: String] {
        guard TurnTokenFormat.isWellFormed(g.token.value) else {
            throw .invalid("the gateway turn has no well-formed turn token; it was not started (no base URL without a token)")
        }
        guard let gatewayPort = loopbackPort(g.baseURL, path: GatewayRoutes.prefix) else {
            throw .invalid("the gateway base URL must be http://127.0.0.1:<port>\(GatewayRoutes.prefix)")
        }
        guard let denyPort = loopbackPort(g.denyProxy, path: ""), denyPort != gatewayPort else {
            throw .invalid("the gateway turn's deny proxy must be http://127.0.0.1:<port>, not the gateway's port")
        }
        for (c, alias) in g.aliases where alias != GatewayLaunch.alias(c) {
            throw .invalid("the \(c.rawValue) alias must be \(GatewayLaunch.alias(c))")
        }
        try checkConfigDir(g.configDir, owner: owner)
        var env = ["ANTHROPIC_BASE_URL": g.baseURL, "ANTHROPIC_API_KEY": g.token.value,
                   "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CONFIG_DIR": g.configDir]
        for (c, alias) in g.aliases { if let name = defaultModelVariable[c] { env[name] = alias } }
        for name in proxyNames { env[name] = g.denyProxy }
        for name in noProxyNames { env[name] = noProxy }
        return env
    }

    /// The engine variables (`extra`, `BRAHMA_*`) a gateway turn adds: the deny-proxy marker the shell prefix reads.
    public static func extra(_ g: GatewayLaunch) -> [String: String] { [denyProxyMarker: g.denyProxy] }

    /// A mode turn's `availableModels` gains the routed aliases (Ruling 62), so `--model brahma-<class>` is a model the turn
    /// may name. Strings in an existing non-empty array: the settings shape is unchanged. A turn with no `availableModels`
    /// (the concierge) is left as it is.
    public static func settings(_ s: inout ClaudeSettings, _ g: GatewayLaunch) {
        guard var models = s.availableModels else { return }
        for c in ModelClass.allCases { if let alias = g.aliases[c], !models.contains(alias) { models.append(alias) } }
        s.availableModels = models
    }

    /// Finishes a launch compiled with `environment(g)` in its child environment: checks that the environment carries the
    /// gateway values (and no owner login), then, when the decision model's class is routed, `--model brahma-<class>` and
    /// `--fallback-model brahma-<class>` (the fallback never changes the model, spec §8.2.5); otherwise the argv is
    /// unchanged (Anthropic pass-through). Refuses (fail closed) a launch whose environment lost a gateway value, carries a
    /// Claude login variable, or holds the token anywhere but `ANTHROPIC_API_KEY`.
    public static func apply(_ spec: inout LaunchSpec, _ g: GatewayLaunch, decisionModel: String) throws(RuntimeCompileError) {
        let expected = try environment(g)
        for (name, value) in expected where spec.environment[name] != value {
            throw .invalid("the gateway turn's environment lacks \(name); it was not started")
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
        guard let c = ModelClass.of(family: ModelAllowlist.family(decisionModel)), let alias = g.aliases[c] else { return }
        for flag in ["--model", "--fallback-model"] {
            guard let i = spec.arguments.firstIndex(of: flag), spec.arguments.indices.contains(i + 1) else {
                throw .invalid("the gateway turn's argv has no \(flag)")
            }
            spec.arguments[i + 1] = alias
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

    /// A plain absolute path (no `.`/`..` component, no quote, backslash or control character), and never the owner's config
    /// dir (`CLAUDE_CONFIG_DIR`, else `$HOME/.claude`) or a place inside it.
    static func checkConfigDir(_ dir: String, owner: [String: String]) throws(RuntimeCompileError) {
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
    }
}

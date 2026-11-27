import Foundation

/// What a `claude` turn needs to run through the model gateway (Plan X1 Task 12): set on `TurnRequest.gateway` by the launcher
/// (Task 14); `ClaudeGatewayCompile` turns it into the launch's environment and argv. Nil on a request means a subscription turn.
///
/// Beyond the brief's three fields it carries the two values the compile cannot make itself, because compiling starts nothing
/// and creates nothing (Ruling 62): the port of the turn's claude proxy (`EgressProxyPool.proxy(for:
/// ClaudeGatewayCompile.claudeProxyDomains(request))`, started by the launcher, Ruling 64(2)) and the agent's isolated, persistent gateway config dir (`GatewayConfigDir.prepare`, in the engine's run area
/// and checked before every gateway turn, Ruling 63).
public struct GatewayLaunch: Sendable, Equatable {
    /// `http://127.0.0.1:<port>/t/`: the gateway's base URL (`GatewayRoutes.prefix`).
    public var baseURL: String
    /// The turn's own token: the child's `ANTHROPIC_API_KEY`, never in argv or any file.
    public var token: GatewayToken
    /// Class → `brahma-<class>` for the routed classes only; an unrouted class is served by Anthropic pass-through.
    public var aliases: [ModelClass: String]
    /// `http://127.0.0.1:<port>`: the egress proxy every proxy variable of the turn's `claude` names (Review Focus 1, Ruling
    /// 64(2)): it allows only the turn's web domains (so WebFetch works) and refuses every vendor host; deny-all with none.
    public var claudeProxy: String
    /// The agent's isolated gateway `CLAUDE_CONFIG_DIR`: absolute, in the engine's run area (`GatewayConfigDir`), the same for
    /// every gateway turn of the agent (so `--resume` works), never the owner's config dir or a copy of it, and never a place
    /// the turn can reach (Rulings 18, 20, 62, 63).
    public var configDir: String

    public init(baseURL: String, token: GatewayToken, aliases: [ModelClass: String], claudeProxy: String, configDir: String) {
        self.baseURL = baseURL; self.token = token; self.aliases = aliases; self.claudeProxy = claudeProxy; self.configDir = configDir
    }

    /// `brahma-<class>`: the model name `claude` sends for a routed class; the gateway's grant maps it to the route's target.
    public static func alias(_ c: ModelClass) -> String { "brahma-\(c.rawValue)" }

    /// The aliases for `classes`, each `alias(_:)`.
    public static func aliases(for classes: some Sequence<ModelClass>) -> [ModelClass: String] {
        Dictionary(uniqueKeysWithValues: Set(classes).map { ($0, alias($0)) })
    }
}

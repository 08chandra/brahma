import Foundation

/// What a gateway request may ask the provider to do (Plan X1 Ruling X1-34, Ruling 45). It runs in `ModelGateway` before
/// routing, so every adapter — `anthropic` now, `openai-compatible` (Task 10) and X1b's later — goes through it, and nothing
/// is sent upstream for a refused request. Everything is an allowlist, so a new provider feature is refused until reviewed:
///
/// - **No provider-side network.** A turn's own network goes through its sandbox's egress proxy; a provider that fetches,
///   searches or runs code on the turn's behalf would bypass it (and give a tainted session an exfiltration path). So
///   `mcp_servers` is refused, every tool whose `type` is present and not `custom` (a server tool: web fetch / search, code
///   execution, computer use, tool search, any versioned `*_20xx…` type) is refused unless the turn's grant lists that exact
///   type in `serverTools` (empty in X1; `TurnTokenRegistry.markTainted` clears it), and a content block whose `source` is a
///   URL (an image or document the provider would download) is refused.
/// - **Only what the price book meters.** Top-level body keys outside `bodyKeys` are refused (a new key may carry a pricing
///   modifier the meter does not model, Ruling 39), and so is every `anthropic-beta` value outside `betas`.
///
/// Refusals are 403 `permission_error` (`claude` does not retry a 403, X1-0 (g)), except Ruling 39's priced-modifier
/// refusals, which keep 400.
public enum GatewayPolicy {
    /// The Messages fields the canonical request models, plus the keys X1-0 recorded `claude` sending.
    public static let bodyKeys: Set<String> = CanonicalRequest.modelled.union(["context_management", "output_config", "thinking", "safeguards"])

    /// Keys that change the price, allowed only at their standard value (Ruling 39).
    static let standardOnly: [String: (value: String, reason: String)] = [
        "speed": ("standard", "fast mode is not priced"),
        "inference_geo": ("global", "inference_geo is not priced"),
        "service_tier": ("standard_only", "service_tier is not priced"),
    ]

    /// The `anthropic-beta` values allowed: the nine X1-0 recorded `claude` 2.1.325 sending. None enables a provider-side
    /// network tool on its own (`advanced-tool-use` adds tool search and programmatic tool calls, which need a server tool in
    /// `tools`, refused above) and none changes the price per token.
    public static let betas: Set<String> = [
        "claude-code-20250219", "interleaved-thinking-2025-05-14", "context-management-2025-06-27", "per-turn-control-2026-07-01",
        "mid-conversation-tool-changes-2026-07-01", "thinking-token-count-2026-05-13", "advanced-tool-use-2025-11-20",
        "effort-2025-11-24", "thinking-display-updates-2026-08-18",
    ]

    /// The provider-side tools with network or code reach, by the names the providers use: Anthropic's server tool types,
    /// OpenAI's built-in tools and Gemini's grounding tools. Every adapter refuses to send any of them (Task 10 maps none).
    public static let providerNetworkTools: Set<String> = [
        "web_search", "web_fetch", "code_execution", "computer", "bash", "text_editor", "tool_search_tool_regex",
        "tool_search_tool_bm25", "mcp_toolset", "file_search", "web_search_preview", "code_interpreter", "image_generation",
        "google_search", "google_search_retrieval", "url_context", "grounding",
    ]

    /// The tool `type` of a client tool, defined and run by the caller.
    static let clientToolType = "custom"

    static func forbidden(_ reason: String) -> GatewayError {
        .refused(status: 403, type: "permission_error", message: "Brahma: " + reason)
    }

    /// Refuses (throws) a request the policy does not allow. `body` is the strictly parsed tree (`CanonicalRequest.tree`: no
    /// key repeated at any depth), the same tree the adapter serializes upstream, so what is checked is what is sent.
    static func check(body: StrictJSON, headers: [GatewayHeader], grant: TurnGrant) throws(GatewayError) {
        guard case .object(let members) = body else { throw .policy("the request body is not a JSON object") }
        let top = Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.value) })
        if top["mcp_servers"] != nil { throw forbidden("mcp_servers would let the provider reach the network; it is not allowed") }
        if top["fallbacks"] != nil { throw .policy("fallbacks is not priced") }
        for (key, standard) in standardOnly.sorted(by: { $0.key < $1.key }) {
            if let value = top[key], value.stringValue != standard.value { throw .policy(standard.reason) }
        }
        for key in top.keys.sorted() where !bodyKeys.contains(key) && standardOnly[key] == nil {
            throw forbidden("the request field \(shown(key)) is not allowed")
        }
        if let tools = top["tools"] {
            guard case .array(let list) = tools else { throw .policy("tools must be a list") }
            for tool in list {
                guard case .object = tool else { throw .policy("tools must be a list of objects") }
                guard let type = tool["type"] else { continue }
                guard case .string(let name) = type else { throw .policy("a tool type must be a string") }
                if name == clientToolType || grant.serverTools.contains(name) { continue }
                throw forbidden("server tool \(shown(name)) would let the provider reach the network; it is not allowed")
            }
        }
        for key in ["system", "messages"] where top[key].map(hasURLSource) == true {
            throw forbidden("a URL source would let the provider fetch the network; send the content instead")
        }
        let betas = headers.filter { $0.name == "anthropic-beta" }
        guard betas.count <= 1 else { throw forbidden("send at most one anthropic-beta header") }
        if let beta = betas.first {
            for value in beta.value.split(separator: ",", omittingEmptySubsequences: false) {
                let name = value.trimmingCharacters(in: .whitespaces)
                guard Self.betas.contains(name) else { throw forbidden("the beta \(shown(name)) is not allowed") }
            }
        }
    }

    /// Whether any object under `value` is a content `source` of type `url`.
    static func hasURLSource(_ value: StrictJSON) -> Bool {
        switch value {
        case .array(let items):
            return items.contains(where: hasURLSource)
        case .object(let fields):
            if let source = value["source"], case .object = source, source["type"]?.stringValue == "url" { return true }
            // A tool call's `input` is the model's arguments to a client tool, not content the provider fetches.
            let isToolUse = value["type"]?.stringValue == "tool_use"
            return fields.contains { !(isToolUse && $0.key == "input") && hasURLSource($0.value) }
        default:
            return false
        }
    }

    /// A key, type or beta as a refusal may show it: short and plain, else a fixed phrase.
    static func shown(_ s: String) -> String {
        let plain = !s.isEmpty && s.utf8.count <= 64 && s.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._-".unicodeScalars.contains($0)
        }
        return plain ? s : "(unprintable)"
    }
}

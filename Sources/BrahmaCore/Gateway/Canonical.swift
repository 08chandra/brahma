import Foundation

/// One request to the gateway, decoded (Plan X1 Task 8): the Anthropic Messages request `claude` sends, which is also the
/// gateway's canonical format — the `anthropic` adapter forwards the raw body, other adapters (Task 10) translate from this.
/// Top-level keys this type does not model (`thinking`, `context_management`, `output_config`, `speed`, …) are kept in `extra`.
/// Inside content, blocks other than text / image / tool_use / tool_result are kept whole as `.other`; keys a typed block does
/// not model (`cache_control`, `citations`) are dropped — only the `anthropic` adapter needs them, and it forwards the raw body.
public struct CanonicalRequest: Codable, Sendable, Equatable {
    public var model: String
    public var system: CanonicalContent?
    public var messages: [CanonicalMessage]
    public var tools: [CanonicalTool]?
    public var toolChoice: JSONValue?
    /// Required by `/v1/messages`, absent on `count_tokens`.
    public var maxTokens: Int?
    public var stream: Bool?
    public var temperature: Double?
    public var topP: Double?
    public var stopSequences: [String]?
    public var metadata: [String: JSONValue]?
    /// Every other top-level key, as sent.
    public var extra: [String: JSONValue]

    public init(model: String, system: CanonicalContent? = nil, messages: [CanonicalMessage], tools: [CanonicalTool]? = nil,
                toolChoice: JSONValue? = nil, maxTokens: Int? = nil, stream: Bool? = nil, temperature: Double? = nil,
                topP: Double? = nil, stopSequences: [String]? = nil, metadata: [String: JSONValue]? = nil,
                extra: [String: JSONValue] = [:]) {
        self.model = model; self.system = system; self.messages = messages; self.tools = tools; self.toolChoice = toolChoice
        self.maxTokens = maxTokens; self.stream = stream; self.temperature = temperature; self.topP = topP
        self.stopSequences = stopSequences; self.metadata = metadata; self.extra = extra
    }

    /// Parses a request body strictly (`StrictJSON`: a key repeated at any depth is refused — the gateway and the provider
    /// must read the same values) into the tree the gateway checks and forwards. Refusals are 400 (Ruling 19).
    public static func tree(_ body: Data) throws(GatewayError) -> StrictJSON {
        let tree: StrictJSON
        do {
            tree = try StrictJSON.parse(body)
        } catch {
            switch error {
            case .duplicateKey(let path): throw .policy("duplicate key \(path)")
            case .tooDeep: throw .policy("the request body nests more than \(StrictJSON.maxDepth) levels deep")
            case .malformed: throw .policy("the request body is not valid JSON")
            }
        }
        guard case .object = tree else { throw .policy("the request body is not a JSON object") }
        return tree
    }

    /// Decodes a body: `tree(_:)`, then `decode(tree:)`.
    public static func decode(_ body: Data) throws(GatewayError) -> CanonicalRequest {
        try decode(tree: try tree(body))
    }

    /// The canonical request a checked tree holds (decoded from the tree's own serialization, so it reads exactly what the
    /// provider would be sent).
    public static func decode(tree: StrictJSON) throws(GatewayError) -> CanonicalRequest {
        do {
            return try JSONDecoder().decode(CanonicalRequest.self, from: tree.serialized())
        } catch {
            throw .policy("the request body is not a Messages request")
        }
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static let modelled: Set<String> = ["model", "system", "messages", "tools", "tool_choice", "max_tokens", "stream", "temperature",
                                        "top_p", "stop_sequences", "metadata"]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        model = try c.decode(String.self, forKey: Key("model"))
        system = try c.decodeIfPresent(CanonicalContent.self, forKey: Key("system"))
        messages = try c.decode([CanonicalMessage].self, forKey: Key("messages"))
        tools = try c.decodeIfPresent([CanonicalTool].self, forKey: Key("tools"))
        toolChoice = try c.decodeIfPresent(JSONValue.self, forKey: Key("tool_choice"))
        maxTokens = try c.decodeIfPresent(Int.self, forKey: Key("max_tokens"))
        stream = try c.decodeIfPresent(Bool.self, forKey: Key("stream"))
        temperature = try c.decodeIfPresent(Double.self, forKey: Key("temperature"))
        topP = try c.decodeIfPresent(Double.self, forKey: Key("top_p"))
        stopSequences = try c.decodeIfPresent([String].self, forKey: Key("stop_sequences"))
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: Key("metadata"))
        var extra: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.modelled.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
        self.extra = extra
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        for (key, value) in extra where !Self.modelled.contains(key) { try c.encode(value, forKey: Key(key)) }
        try c.encode(model, forKey: Key("model"))
        try c.encodeIfPresent(system, forKey: Key("system"))
        try c.encode(messages, forKey: Key("messages"))
        try c.encodeIfPresent(tools, forKey: Key("tools"))
        try c.encodeIfPresent(toolChoice, forKey: Key("tool_choice"))
        try c.encodeIfPresent(maxTokens, forKey: Key("max_tokens"))
        try c.encodeIfPresent(stream, forKey: Key("stream"))
        try c.encodeIfPresent(temperature, forKey: Key("temperature"))
        try c.encodeIfPresent(topP, forKey: Key("top_p"))
        try c.encodeIfPresent(stopSequences, forKey: Key("stop_sequences"))
        try c.encodeIfPresent(metadata, forKey: Key("metadata"))
    }
}

/// `user`, `assistant`, or `system` (X1-0: `claude` sends `role: "system"` entries inside `messages`).
public struct CanonicalMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: CanonicalContent

    public init(role: String, content: CanonicalContent) { self.role = role; self.content = content }
}

/// Message, system or tool-result content: a string, or a list of blocks.
public enum CanonicalContent: Codable, Sendable, Equatable {
    case text(String)
    case blocks([CanonicalBlock])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        do {
            self = .text(try c.decode(String.self))
        } catch DecodingError.typeMismatch {
            self = .blocks(try c.decode([CanonicalBlock].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .blocks(let b): try c.encode(b)
        }
    }
}

/// One content block. Text, image, tool_use and tool_result are typed; every other block (thinking, redacted_thinking,
/// documents, server-tool blocks…) is `.other`, kept as sent.
public enum CanonicalBlock: Codable, Sendable, Equatable {
    case text(String)
    /// `source` as sent (`base64` with `media_type`/`data`, or `url`).
    case image(source: JSONValue)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: CanonicalContent?, isError: Bool?)
    case other(JSONValue)

    private enum CodingKeys: String, CodingKey {
        case type, text, source, id, name, input, content
        case toolUseId = "tool_use_id", isError = "is_error"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "image": self = .image(source: try c.decode(JSONValue.self, forKey: .source))
        case "tool_use":
            self = .toolUse(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                            input: try c.decode(JSONValue.self, forKey: .input))
        case "tool_result":
            self = .toolResult(toolUseId: try c.decode(String.self, forKey: .toolUseId),
                               content: try c.decodeIfPresent(CanonicalContent.self, forKey: .content),
                               isError: try c.decodeIfPresent(Bool.self, forKey: .isError))
        default:
            self = .other(try JSONValue(from: decoder))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case .other(let raw) = self { try raw.encode(to: encoder); return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type); try c.encode(s, forKey: .text)
        case .image(let source):
            try c.encode("image", forKey: .type); try c.encode(source, forKey: .source)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type); try c.encode(id, forKey: .id); try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode("tool_result", forKey: .type); try c.encode(toolUseId, forKey: .toolUseId)
            try c.encodeIfPresent(content, forKey: .content); try c.encodeIfPresent(isError, forKey: .isError)
        case .other:
            break
        }
    }
}

/// A tool definition: a client tool (`name`, `description`, `input_schema`) or a server tool (`type` set, no schema).
public struct CanonicalTool: Codable, Sendable, Equatable {
    public var type: String?
    public var name: String
    public var description: String?
    public var inputSchema: JSONValue?

    private enum CodingKeys: String, CodingKey { case type, name, description, inputSchema = "input_schema" }

    public init(type: String? = nil, name: String, description: String? = nil, inputSchema: JSONValue? = nil) {
        self.type = type; self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

/// One Messages SSE event, in the order `claude` requires (inventory (d)): `message_start (content_block_start
/// content_block_delta* content_block_stop)* message_delta message_stop`, with `ping` anywhere and `error` ending a stream.
/// The `anthropic` adapter relays the provider's events unchanged; adapters that translate (Task 10) emit these.
public enum CanonicalStreamEvent: Sendable, Equatable {
    case messageStart(id: String, model: String, usage: GatewayUsage)
    case contentBlockStart(index: Int, block: JSONValue)
    case contentBlockDelta(index: Int, delta: JSONValue)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?, usage: GatewayUsage?)
    case messageStop
    case ping
    case error(type: String, message: String)

    /// `event: <name>\ndata: <json>\n\n`.
    public func sse() -> Data {
        let (name, payload): (String, JSONValue) = switch self {
        case .messageStart(let id, let model, let usage):
            ("message_start", .object(["type": .string("message_start"), "message": .object([
                "id": .string(id), "type": .string("message"), "role": .string("assistant"), "model": .string(model),
                "content": .array([]), "stop_reason": .null, "stop_sequence": .null, "usage": Self.json(usage),
            ])]))
        case .contentBlockStart(let index, let block):
            ("content_block_start", .object(["type": .string("content_block_start"), "index": .number(Double(index)), "content_block": block]))
        case .contentBlockDelta(let index, let delta):
            ("content_block_delta", .object(["type": .string("content_block_delta"), "index": .number(Double(index)), "delta": delta]))
        case .contentBlockStop(let index):
            ("content_block_stop", .object(["type": .string("content_block_stop"), "index": .number(Double(index))]))
        case .messageDelta(let stopReason, let usage):
            ("message_delta", .object([
                "type": .string("message_delta"),
                "delta": .object(["stop_reason": stopReason.map(JSONValue.string) ?? .null, "stop_sequence": .null]),
                "usage": usage.map(Self.json) ?? .object([:]),
            ]))
        case .messageStop:
            ("message_stop", .object(["type": .string("message_stop")]))
        case .ping:
            ("ping", .object(["type": .string("ping")]))
        case .error(let type, let message):
            ("error", .object(["type": .string("error"), "error": .object(["type": .string(type), "message": .string(message)])]))
        }
        return Data("event: \(name)\ndata: ".utf8) + Self.encode(payload) + Data("\n\n".utf8)
    }

    static func json(_ u: GatewayUsage) -> JSONValue {
        .object(["input_tokens": .number(Double(u.inputTokens)), "output_tokens": .number(Double(u.outputTokens)),
                 "cache_read_input_tokens": .number(Double(u.cacheReadTokens)),
                 "cache_creation_input_tokens": .number(Double(u.cacheWriteTokens))])
    }

    /// Compact, sorted keys; integral numbers written without a fraction. Encoding a `JSONValue` built here cannot fail.
    static func encode(_ value: JSONValue) -> Data {
        switch value {
        case .null: return Data("null".utf8)
        case .bool(let b): return Data((b ? "true" : "false").utf8)
        case .number(let n):
            if n.isFinite, n == n.rounded(), abs(n) < 1e15 { return Data(String(Int64(n)).utf8) }
            return Data((n.isFinite ? "\(n)" : "null").utf8)
        case .string(let s): return Data(("\"" + GatewayRefusal.jsonEscaped(s) + "\"").utf8)
        case .array(let items):
            return Data("[".utf8) + items.map(encode).joined(separator: Data(",".utf8)) + Data("]".utf8)
        case .object(let members):
            let parts = members.sorted { $0.key < $1.key }.map { Data(("\"" + GatewayRefusal.jsonEscaped($0.key) + "\":").utf8) + encode($0.value) }
            return Data("{".utf8) + parts.joined(separator: Data(",".utf8)) + Data("}".utf8)
        }
    }
}

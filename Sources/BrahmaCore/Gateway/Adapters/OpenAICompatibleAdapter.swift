import Foundation

/// The `openai-compatible` adapter (Plan X1 Task 10): translates the Messages request `claude` sends into a Chat Completions
/// request, and the provider's answer (whole, or streamed through `OpenAICompatibleStream`) back into a Messages response.
///
/// **Requests** are translated from the policy-checked `StrictJSON` tree (Ruling X1-35 / 46, Ruling 57), never from the bytes
/// received nor from `JSONValue` (whose `Double` numbers would round large integers in tool inputs). `GatewayPolicy` has
/// already run (no provider-side network); on top of it this adapter sends only function tools — a tool with any `type` but
/// `custom` is refused, whatever the grant says, so no provider-side tool (`web_search`, `file_search`, `code_interpreter`,
/// grounding…) is ever emitted. The mapping:
/// - `system` → a leading `system` message; a `role: "system"` entry inside `messages` (inventory (d)) → a `system` message
///   in place. Text blocks are joined with newlines.
/// - user text → `content` (a string; a list of parts when the message carries an image); a base64 image → an `image_url`
///   part holding a data URL (PNG, JPEG, GIF, WebP only).
/// - `tool_use` → the assistant's `tool_calls[{id, type: "function", function: {name, arguments: <the input as JSON text>}}]`;
///   `tool_result` → a `role: "tool"` message with `tool_call_id`, its text prefixed `Error: ` when `is_error`, placed before
///   the rest of its user message (an image in a tool result goes into that user message).
/// - `tools` → `{type: "function", function: {name, description, parameters: <input_schema>}}`; `tool_choice`
///   `auto | any | none | tool` → `auto | required | none | {type: "function", function: {name}}`, sent only with tools.
/// - `max_tokens`, `temperature`, `top_p` as sent; `stop_sequences` → `stop`; `stream: true` adds
///   `stream_options: {include_usage: true}` (the usage the meter needs).
/// - Dropped, never invented: thinking blocks, `cache_control`, citations, `metadata`, and every other top-level key
///   (`thinking`, `context_management`, `output_config`, `safeguards`, `speed`, `inference_geo`, `service_tier`).
/// - Anything else (a document, a server-tool block, a tool reference, a URL image) is refused with a reason: it has no
///   Chat Completions form, and dropping it would change what the model is asked.
///
/// The provider key goes only in `Authorization: Bearer <key>`; the upstream headers are exactly that and `content-type`,
/// and the URL is the provider's `baseURL` (on its pinned host) + `/chat/completions`.
///
/// **`count_tokens`** is answered by the gateway itself (`countTokensLocally`): `ceil(canonicalBytes / 4)`, the bytes of the
/// policy-checked tree. Nothing is sent upstream (`upstream` refuses the endpoint as a backstop), so it costs nothing and
/// the meter neither reserves nor charges it.
///
/// **Responses**: content → a text block; `tool_calls` → `tool_use` blocks (arguments parsed strictly; arguments that are not
/// a JSON object become `{}`, so the turn sees a tool error on its next request, never a crash); `finish_reason` → `stop_reason`;
/// `usage` → `GatewayUsage` (`OpenAICompatibleStream.usage`). Errors are relayed redacted, like the `anthropic` adapter's.
/// **Billing of errors** (Ruling 55): a 4xx bills nothing; a 5xx is charged the estimate (an aggregator may bill partial work).
public struct OpenAICompatibleAdapter: ProviderAdapter {
    public let id = AdapterId.openAICompatible
    public let version = "1"

    /// `count_tokens` on this adapter: one token per this many canonical bytes, rounded up (pinned).
    public static let countBytesPerToken = 4
    /// The path appended to the provider's `baseURL`.
    public static let chatPath = "/chat/completions"
    /// The largest non-streamed response read (the same bound as a stream).
    static let maxResponseBytes = OpenAICompatibleStream.maxStreamBytes
    /// The image types sent as data URLs.
    static let imageMediaTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    public init() {}

    /// `ceil(canonicalBytes / 4)`.
    public static func countEstimate(canonicalBytes: Int) -> Int {
        let bytes = max(canonicalBytes, 0)
        return bytes / countBytesPerToken + (bytes % countBytesPerToken == 0 ? 0 : 1)
    }

    public func countTokensLocally(_ body: StrictJSON) -> Int? {
        Self.countEstimate(canonicalBytes: body.serialized().count)
    }

    /// Ruling 55: a 4xx bills nothing; a 5xx (an aggregator may have billed partial work) is charged the estimate.
    public func billsNothing(status: Int) -> Bool { (400...499).contains(status) }

    // MARK: Requests

    public func upstream(_ r: CanonicalRequest, body: StrictJSON, model: String, endpoint: GatewayEndpoint, headers: [GatewayHeader],
                         provider: Provider, key: String) throws(GatewayError) -> UpstreamRequest {
        guard endpoint == .messages else {
            throw .unavailable("count_tokens for provider \(provider.id) is answered by the gateway, never sent upstream")
        }
        let url = try Self.url(provider)
        guard !key.isEmpty, key.utf8.count <= 4096, key.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            throw .unavailable("the key for provider \(provider.id) is not a valid header value")
        }
        return UpstreamRequest(url: url, method: "POST", headers: ["authorization": "Bearer " + key, "content-type": "application/json"],
                               body: try Self.chatRequest(body, model: model).serialized())
    }

    /// `baseURL` + `/chat/completions`: `https`, on the provider's one host (port 443), no user, query or fragment, a plain path.
    static func url(_ provider: Provider) throws(GatewayError) -> URL {
        let invalid = GatewayError.unavailable("provider \(provider.id) has no valid https base URL on its host")
        let base = provider.baseURL
        guard provider.host == provider.host.lowercased(), !provider.host.hasPrefix("*."), DomainMatcher.isValidPattern(provider.host),
              DomainMatcher.isHostName(provider.host), base.scheme == "https", base.host?.lowercased() == provider.host,
              base.user == nil, base.password == nil, base.port == nil || base.port == 443, base.query == nil, base.fragment == nil,
              let parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw invalid }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard path.isEmpty || path.hasPrefix("/"),
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              path.utf8.allSatisfy({ isPathByte($0) }) else { throw invalid }
        var out = URLComponents()
        out.scheme = "https"
        out.host = provider.host
        out.percentEncodedPath = path + chatPath
        guard let url = out.url, url.host == provider.host else { throw invalid }
        return url
    }

    private static func isPathByte(_ b: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) || "/._-".utf8.contains(b)
    }

    /// The Chat Completions body for a checked Messages tree, routed to `model`.
    static func chatRequest(_ tree: StrictJSON, model: String) throws(GatewayError) -> StrictJSON {
        var messages: [StrictJSON] = []
        if let system = tree["system"] {
            let text = try systemText(system)
            if !text.isEmpty { messages.append(message("system", .string(text))) }
        }
        guard case .array(let list) = tree["messages"] else { throw .policy("messages must be a list") }
        for entry in list {
            guard case .object = entry, let role = entry["role"]?.stringValue, let content = entry["content"] else {
                throw .policy("each message needs a role and content")
            }
            switch role {
            case "system":
                messages.append(message("system", .string(try systemText(content))))
            case "user":
                messages += try userMessages(content)
            case "assistant":
                messages.append(try assistantMessage(content))
            default:
                throw .policy("the message role \(GatewayPolicy.shown(role)) cannot be sent to an openai-compatible provider")
            }
        }
        var out: [StrictJSON.Member] = [.init("model", .string(model)), .init("messages", .array(messages))]
        if let tools = tree["tools"] {
            guard case .array(let list) = tools else { throw .policy("tools must be a list") }
            if !list.isEmpty {
                out.append(.init("tools", .array(try list.map(function))))
                if let choice = tree["tool_choice"] { out.append(.init("tool_choice", try toolChoice(choice))) }
            }
        }
        for (from, to) in [("max_tokens", "max_tokens"), ("temperature", "temperature"), ("top_p", "top_p"), ("stop_sequences", "stop")] {
            if let value = tree[from], value != .null { out.append(.init(to, value)) }
        }
        if tree["stream"] == .bool(true) {
            out.append(.init("stream", .bool(true)))
            out.append(.init("stream_options", .object([.init("include_usage", .bool(true))])))
        }
        return .object(out)
    }

    private static func message(_ role: String, _ content: StrictJSON) -> StrictJSON {
        .object([.init("role", .string(role)), .init("content", content)])
    }

    private static func unsupported(_ what: String) -> GatewayError {
        .policy("\(what) cannot be sent to an openai-compatible provider")
    }

    /// The blocks of a content value (a string is one text block).
    private static func blocks(_ content: StrictJSON) throws(GatewayError) -> [StrictJSON] {
        switch content {
        case .string(let s): return [.object([.init("type", .string("text")), .init("text", .string(s))])]
        case .array(let items): return items
        default: throw .policy("message content must be a string or a list of blocks")
        }
    }

    private static func type(of block: StrictJSON) throws(GatewayError) -> String {
        guard case .object = block, let type = block["type"]?.stringValue else { throw .policy("each content block needs a type") }
        return type
    }

    private static func text(of block: StrictJSON) throws(GatewayError) -> String {
        guard let text = block["text"]?.stringValue else { throw .policy("a text block needs its text") }
        return text
    }

    /// Thinking is the provider's own; it is never sent to another.
    private static let droppedBlocks: Set<String> = ["thinking", "redacted_thinking"]

    /// System content as one text: its text blocks, joined.
    static func systemText(_ content: StrictJSON) throws(GatewayError) -> String {
        if case .string(let s) = content { return s }
        var texts: [String] = []
        for block in try blocks(content) {
            let type = try type(of: block)
            if droppedBlocks.contains(type) { continue }
            guard type == "text" else { throw unsupported("a \(GatewayPolicy.shown(type)) block in a system message") }
            texts.append(try text(of: block))
        }
        return texts.joined(separator: "\n")
    }

    /// One user message: its tool results first (`role: "tool"`, answering the assistant's calls), then its text and images.
    static func userMessages(_ content: StrictJSON) throws(GatewayError) -> [StrictJSON] {
        if case .string = content { return [message("user", content)] }
        var tools: [StrictJSON] = []
        var parts: [StrictJSON] = []
        for block in try blocks(content) {
            let type = try type(of: block)
            switch type {
            case "text": parts.append(textPart(try text(of: block)))
            case "image": parts.append(try imagePart(block))
            case "tool_result":
                let (message, images) = try toolMessage(block)
                tools.append(message)
                parts += images
            case _ where droppedBlocks.contains(type): continue
            default: throw unsupported("a \(GatewayPolicy.shown(type)) block")
            }
        }
        guard !parts.isEmpty else { return tools }
        let onlyText = parts.allSatisfy { $0["type"] == .string("text") }
        let content: StrictJSON = onlyText ? .string(parts.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")) : .array(parts)
        return tools + [message("user", content)]
    }

    private static func textPart(_ text: String) -> StrictJSON {
        .object([.init("type", .string("text")), .init("text", .string(text))])
    }

    /// A base64 image as an `image_url` part with a data URL; any other source is refused.
    static func imagePart(_ block: StrictJSON) throws(GatewayError) -> StrictJSON {
        guard let source = block["source"], source["type"]?.stringValue == "base64",
              let media = source["media_type"]?.stringValue, imageMediaTypes.contains(media),
              let data = source["data"]?.stringValue, !data.isEmpty, data.utf8.allSatisfy(isBase64Byte) else {
            throw unsupported("an image that is not inline base64 PNG, JPEG, GIF or WebP")
        }
        return .object([.init("type", .string("image_url")),
                        .init("image_url", .object([.init("url", .string("data:\(media);base64,\(data)"))]))])
    }

    private static func isBase64Byte(_ b: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) || b == UInt8(ascii: "+") || b == UInt8(ascii: "/") || b == UInt8(ascii: "=")
    }

    /// A `tool_result` as a `role: "tool"` message (its text, `Error: `-prefixed when `is_error`), and its images as parts.
    static func toolMessage(_ block: StrictJSON) throws(GatewayError) -> (message: StrictJSON, images: [StrictJSON]) {
        guard let id = block["tool_use_id"]?.stringValue else { throw .policy("a tool_result needs its tool_use_id") }
        var texts: [String] = []
        var images: [StrictJSON] = []
        if let content = block["content"], content != .null {
            for item in try blocks(content) {
                let type = try type(of: item)
                switch type {
                case "text": texts.append(try text(of: item))
                case "image": images.append(try imagePart(item))
                default: throw unsupported("a \(GatewayPolicy.shown(type)) block in a tool result")
                }
            }
        }
        var text = texts.joined(separator: "\n")
        if block["is_error"] == .bool(true) { text = "Error: " + text }
        let message: StrictJSON = .object([.init("role", .string("tool")), .init("tool_call_id", .string(id)), .init("content", .string(text))])
        return (message, images)
    }

    /// An assistant message: its text as `content` (null when it only calls tools), its `tool_use` blocks as `tool_calls`
    /// whose `arguments` are the input's exact serialization.
    static func assistantMessage(_ content: StrictJSON) throws(GatewayError) -> StrictJSON {
        if case .string = content { return message("assistant", content) }
        var texts: [String] = []
        var calls: [StrictJSON] = []
        for block in try blocks(content) {
            let type = try type(of: block)
            switch type {
            case "text": texts.append(try text(of: block))
            case "tool_use":
                guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue, let input = block["input"],
                      case .object = input else { throw .policy("a tool_use needs an id, a name and an object input") }
                let arguments = String(decoding: input.serialized(), as: UTF8.self)
                calls.append(.object([
                    .init("id", .string(id)), .init("type", .string("function")),
                    .init("function", .object([.init("name", .string(name)), .init("arguments", .string(arguments))])),
                ]))
            case _ where droppedBlocks.contains(type): continue
            default: throw unsupported("a \(GatewayPolicy.shown(type)) block")
            }
        }
        let text: StrictJSON = texts.isEmpty ? (calls.isEmpty ? .string("") : .null) : .string(texts.joined(separator: "\n"))
        var members: [StrictJSON.Member] = [.init("role", .string("assistant")), .init("content", text)]
        if !calls.isEmpty { members.append(.init("tool_calls", .array(calls))) }
        return .object(members)
    }

    /// A client tool as a function; any other tool type is refused (no provider-side tool is ever emitted).
    static func function(_ tool: StrictJSON) throws(GatewayError) -> StrictJSON {
        guard case .object = tool else { throw .policy("tools must be a list of objects") }
        if let type = tool["type"], type != .string(GatewayPolicy.clientToolType) {
            let name = type.stringValue.map(GatewayPolicy.shown) ?? "(unprintable)"
            throw GatewayPolicy.forbidden("server tool \(name) cannot be sent to an openai-compatible provider; only function tools are")
        }
        guard let name = tool["name"]?.stringValue, let schema = tool["input_schema"], case .object = schema else {
            throw .policy("a tool needs a name and an input_schema object")
        }
        var function: [StrictJSON.Member] = [.init("name", .string(name))]
        if let description = tool["description"], description != .null {
            guard case .string = description else { throw .policy("a tool description must be a string") }
            function.append(.init("description", description))
        }
        function.append(.init("parameters", schema))
        return .object([.init("type", .string("function")), .init("function", .object(function))])
    }

    /// `tool_choice`: `auto` → `auto`, `any` → `required`, `none` → `none`, `tool` → that function.
    static func toolChoice(_ choice: StrictJSON) throws(GatewayError) -> StrictJSON {
        switch choice["type"]?.stringValue {
        case "auto": return .string("auto")
        case "any": return .string("required")
        case "none": return .string("none")
        case "tool":
            guard let name = choice["name"]?.stringValue else { throw .policy("tool_choice tool needs a name") }
            return .object([.init("type", .string("function")), .init("function", .object([.init("name", .string(name))]))])
        default:
            throw .policy("this tool_choice cannot be sent to an openai-compatible provider")
        }
    }

    // MARK: Responses

    public func translate(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>, streamed: Bool,
                          into reply: GatewayReply, redact: @Sendable (String) -> String) async throws(GatewayError) -> UsageOutcome {
        guard (200...299).contains(status) else {
            throw await AnthropicAdapter.upstreamError(status: status, body: body, redact: redact)
        }
        let isEventStream = headers["content-type"]?.lowercased().hasPrefix("text/event-stream") == true
        if streamed {
            guard isEventStream else { throw .upstream(status: 502, message: "Brahma: the provider did not stream its reply") }
            return try await relay(body, into: reply, redact: redact)
        }
        guard !isEventStream else { throw .upstream(status: 502, message: "Brahma: the provider streamed a reply asked for whole") }
        let whole = try await AnthropicAdapter.collect(body, limit: Self.maxResponseBytes)
        let translated = Result { () throws(GatewayError) -> (Data, UsageOutcome) in try Self.message(whole, redact: redact) }
        // A cancelled task's body may be cut short: never relayed as a 200, but a whole message's usage still counts (Ruling 52(a)).
        guard !Task.isCancelled, !reply.isCut else {
            if case .success(let done) = translated { return done.1 }
            return .none
        }
        guard !whole.isEmpty else { throw .upstream(status: 502, message: "Brahma: the provider sent an empty response") }
        let (message, outcome) = try translated.get()
        await reply.send(status: status, json: message)
        return outcome
    }

    /// A whole Chat Completions response as a Messages message, and its usage (final when present and valid). A 200 that
    /// holds an `error` object is relayed as an error, redacted.
    static func message(_ data: Data, redact: (String) -> String) throws(GatewayError) -> (Data, UsageOutcome) {
        let tree: StrictJSON
        do {
            tree = try StrictJSON.parse(data)
        } catch {
            throw .upstream(status: 502, message: "Brahma: the provider sent a response that is not JSON")
        }
        guard case .object = tree else { throw .upstream(status: 502, message: "Brahma: the provider sent a response that is not an object") }
        if let failure = tree["error"], failure != .null {
            let detail = String(redact(OpenAICompatibleStream.errorDetail(failure)).prefix(1000))
            throw .upstream(status: 502, message: "Brahma: the provider answered with an error" + (detail.isEmpty ? "" : ": " + detail))
        }
        let malformed = GatewayError.upstream(status: 502, message: "Brahma: the provider sent a malformed response")
        guard case .array(let choices) = tree["choices"], let choice = choices.first, case .object = choice,
              let message = choice["message"], case .object = message else { throw malformed }
        var content: [StrictJSON] = []
        switch message["content"] {
        case .none, .some(.null): break
        case .some(.string(let text)):
            if !text.isEmpty { content.append(.object([.init("type", .string("text")), .init("text", .string(text))])) }
        default: throw malformed
        }
        switch message["tool_calls"] {
        case .none, .some(.null): break
        case .some(.array(let calls)):
            for call in calls {
                guard case .object = call, let function = call["function"], case .object = function else { throw malformed }
                let arguments = function["arguments"]?.stringValue ?? ""
                content.append(.object([
                    .init("type", .string("tool_use")),
                    .init("id", .string(OpenAICompatibleStream.toolUseId(call["id"]?.stringValue ?? ""))),
                    .init("name", .string(function["name"]?.stringValue ?? "")),
                    .init("input", OpenAICompatibleStream.toolInput(arguments)),
                ]))
            }
        default: throw malformed
        }
        let hasToolCalls = content.contains { $0["type"] == .string("tool_use") }
        let stop = OpenAICompatibleStream.stopReason(choice["finish_reason"]?.stringValue, hasToolCalls: hasToolCalls)
        let usage = tree["usage"].flatMap(OpenAICompatibleStream.usage)
        let shown = usage ?? OpenAICompatibleStream.zeroUsage
        let out: StrictJSON = .object([
            .init("id", .string(OpenAICompatibleStream.plainId(tree["id"], fallback: "msg_brahma"))),
            .init("type", .string("message")), .init("role", .string("assistant")),
            .init("model", .string(OpenAICompatibleStream.plainId(tree["model"], fallback: "unknown"))),
            .init("content", .array(content)), .init("stop_reason", .string(stop)), .init("stop_sequence", .null),
            .init("usage", .object([
                .init("input_tokens", .number(String(shown.inputTokens))), .init("output_tokens", .number(String(shown.outputTokens))),
                .init("cache_read_input_tokens", .number(String(shown.cacheReadTokens))),
                .init("cache_creation_input_tokens", .number(String(shown.cacheWriteTokens))),
            ])),
        ])
        return (out.serialized(), UsageOutcome(usage: usage, complete: usage != nil))
    }

    /// Streams the provider's chunks through `OpenAICompatibleStream` to the client. Stops (returning what it read, not
    /// final) when the reply is cut or the task cancelled; stops reading the provider once the stream has ended (normally
    /// or with an `error` event, a bound included).
    private func relay(_ body: AsyncThrowingStream<Data, Error>, into reply: GatewayReply,
                       redact: @Sendable (String) -> String) async throws(GatewayError) -> UsageOutcome {
        var stream = OpenAICompatibleStream()
        var started = false
        var received = false
        var iterator = body.makeAsyncIterator()

        func write(_ events: [CanonicalStreamEvent]) async -> Bool {
            guard !events.isEmpty else { return true }
            if !started {
                guard await reply.startEvents() else { return false }
                started = true
            }
            return await reply.event(events.reduce(into: Data()) { $0.append($1.sse()) })
        }

        while !stream.isEnded {
            let chunk: Data?
            do {
                chunk = try await iterator.next()
            } catch {
                guard started else { throw .upstream(status: 502, message: "Brahma: the provider stream failed") }
                if !Task.isCancelled, !reply.isCut, await write(stream.fail()) { await reply.endEvents() }
                return stream.outcome
            }
            if Task.isCancelled || reply.isCut { return stream.outcome }
            guard let chunk else {
                guard received else { throw .upstream(status: 502, message: "Brahma: the provider sent an empty stream") }
                guard await write(stream.end(redact: redact)) else { return stream.outcome }
                break
            }
            if !chunk.isEmpty { received = true }
            guard await write(stream.feed(chunk, redact: redact)) else { return stream.outcome }
        }
        if started { await reply.endEvents() }
        return stream.outcome
    }
}

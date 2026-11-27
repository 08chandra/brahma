import Foundation

/// A Chat Completions SSE stream turned into Messages stream events (Plan X1 Task 10): a state machine the
/// `openai-compatible` adapter feeds with the provider's bytes as they arrive.
///
/// It emits `message_start` once (at the first chunk), then one content block per text run — streamed as it arrives — and one
/// per tool call. Tool calls are accumulated by their `index` (their arguments arrive in pieces, possibly interleaved with
/// other calls) and emitted whole when the finish reason arrives: `content_block_start` (`tool_use`, empty input), one
/// `input_json_delta` holding the arguments as validated JSON, `content_block_stop`. Arguments that are not a JSON object
/// (cut, malformed, repeated keys) become `{}`: the turn runs the tool with no input and `claude` answers its own validation
/// error as a `tool_result` on the next request — never a crash. Then `message_delta` (stop reason and usage) and
/// `message_stop`: the order `claude` requires (inventory (d)).
///
/// The provider is untrusted, so every input is bounded (Review Focus 3) and a violated bound ends the reply with an `error`
/// event (`overloaded_error`, "Brahma: provider stream exceeded <bound>"): one SSE line at most `maxLineBytes`, the tool
/// calls' ids, names and arguments together at most `maxToolArgumentBytes`, at most `maxToolCalls` calls, the whole stream
/// at most `maxStreamBytes`. Text is never held: each delta is emitted as it is read. A line that is not JSON, a provider
/// error chunk, `[DONE]` or the end of the stream before a finish reason also end the reply with an `error` event.
///
/// Usage (Ruling X1-37): `prompt_tokens` less `prompt_tokens_details.cached_tokens` is input, the cached tokens are cache
/// reads, `completion_tokens` is output. It is final (`outcome.complete`) only when a usage chunk arrived with or after the
/// finish reason and the stream then ended normally (`[DONE]`, or its end with nothing wrong). A usage with a count that is
/// not a whole number from 0 to `GatewayUsage.maxTokens` (−5, 10¹²), or cached tokens above the prompt, is no usage at all:
/// the meter charges the estimate, never a negative or absurd amount.
public struct OpenAICompatibleStream {
    /// The longest SSE line read (a 50 MB event is refused at 1 MiB, never buffered).
    public static let maxLineBytes = 1 << 20
    /// The most bytes of tool-call ids, names and arguments held for one reply.
    public static let maxToolArgumentBytes = 4 << 20
    /// The most bytes one streamed reply may send.
    public static let maxStreamBytes = 64 << 20
    /// The most tool calls one reply may make.
    public static let maxToolCalls = 128

    /// One tool call being accumulated.
    private struct ToolCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    /// The current line, not yet ended (at most `maxLineBytes`).
    private var line: [UInt8] = []
    private var started = false
    private var openText: Int?
    private var nextIndex = 0
    private var calls: [Int: ToolCall] = [:]
    private var callOrder: [Int] = []
    private var finishReason: String?
    private var usage: GatewayUsage?
    private var usageInvalid = false
    private var usageAfterFinish = false
    private var endedNormally = false

    /// Bytes read so far.
    public private(set) var streamBytes = 0
    /// Bytes of tool-call ids, names and arguments held.
    public private(set) var toolBytes = 0
    /// The most bytes this stream ever held at once (the open line and the tool calls): what `hostileStreamsAreBounded`
    /// checks instead of the process's memory.
    public private(set) var peakBufferedBytes = 0
    /// The stream is over (normally, or with an `error` event): the adapter stops reading.
    public private(set) var isEnded = false

    public init() {}

    /// What the reply's usage came to (`UsageOutcome`): final only after the terminal usage report and a normal end.
    public var outcome: UsageOutcome {
        let seen = usageInvalid ? nil : usage
        return UsageOutcome(usage: seen, complete: endedNormally && usageAfterFinish)
    }

    // MARK: Input

    /// Reads one chunk of the provider's body; returns the events it completes. `redact` is applied to every provider text
    /// relayed in an `error` event.
    public mutating func feed(_ chunk: Data, redact: (String) -> String) -> [CanonicalStreamEvent] {
        guard !isEnded else { return [] }
        streamBytes += chunk.count
        guard streamBytes <= Self.maxStreamBytes else { return exceeded("64 MiB") }
        var events: [CanonicalStreamEvent] = []
        var start = chunk.startIndex
        while start < chunk.endIndex, !isEnded {
            guard let newline = chunk[start...].firstIndex(of: 0x0A) else {
                let rest = chunk[start...]
                guard line.count + rest.count <= Self.maxLineBytes else { return events + exceeded("1 MiB per line") }
                line.append(contentsOf: rest)
                notePeak()
                break
            }
            let segment = chunk[start..<newline]
            guard line.count + segment.count <= Self.maxLineBytes else { return events + exceeded("1 MiB per line") }
            if line.isEmpty {
                events += read(line: segment, redact: redact)
            } else {
                line.append(contentsOf: segment)
                notePeak()
                let whole = Data(line)
                line.removeAll(keepingCapacity: true)
                events += read(line: whole, redact: redact)
            }
            start = chunk.index(after: newline)
        }
        return events
    }

    /// The provider's body ended: a last line without a newline is read, then the reply ends — normally when the finish
    /// reason arrived, else with an `error` event.
    public mutating func end(redact: (String) -> String) -> [CanonicalStreamEvent] {
        guard !isEnded else { return [] }
        var events: [CanonicalStreamEvent] = []
        if !line.isEmpty {
            let last = Data(line)
            line.removeAll()
            events += read(line: last, redact: redact)
        }
        return events + done()
    }

    /// The provider's body failed midway: the reply ends with an `error` event.
    public mutating func fail() -> [CanonicalStreamEvent] {
        guard !isEnded else { return [] }
        return error(type: "api_error", message: "Brahma: the provider stream failed")
    }

    // MARK: Lines and chunks

    private mutating func notePeak() {
        peakBufferedBytes = max(peakBufferedBytes, line.count + toolBytes)
    }

    /// One SSE line: `data:` lines are chunks; comments, other fields and blank lines are skipped.
    private mutating func read(line raw: Data, redact: (String) -> String) -> [CanonicalStreamEvent] {
        var bytes = raw
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        let prefix = Array("data:".utf8)
        guard bytes.starts(with: prefix) else { return [] }
        var payload = bytes.dropFirst(prefix.count)
        if payload.first == 0x20 { payload = payload.dropFirst() }
        if payload.elementsEqual("[DONE]".utf8) { return done() }
        let json: StrictJSON
        do {
            json = try StrictJSON.parse(Data(payload))
        } catch {
            return malformed()
        }
        return read(chunk: json, redact: redact)
    }

    private mutating func read(chunk: StrictJSON, redact: (String) -> String) -> [CanonicalStreamEvent] {
        guard case .object = chunk else { return malformed() }
        if let failure = chunk["error"], failure != .null {
            let detail = String(redact(Self.errorDetail(failure)).prefix(1000))
            return error(type: "api_error", message: "Brahma: the provider stream failed" + (detail.isEmpty ? "" : ": " + detail))
        }
        var events: [CanonicalStreamEvent] = []
        if !started {
            started = true
            events.append(.messageStart(id: Self.plainId(chunk["id"], fallback: "msg_brahma"), model: Self.plainId(chunk["model"], fallback: "unknown"),
                                        usage: Self.zeroUsage))
        }
        events += read(choices: chunk["choices"])
        guard !isEnded else { return events }
        // Read after the choices: a usage in the chunk that carries the finish reason is the terminal report.
        if let reported = chunk["usage"], reported != .null {
            switch Self.usage(reported) {
            case .some(let u): usage = u
            case .none: usageInvalid = true
            }
            if finishReason != nil { usageAfterFinish = true }
        }
        return events
    }

    private mutating func read(choices: StrictJSON?) -> [CanonicalStreamEvent] {
        var events: [CanonicalStreamEvent] = []
        guard let choices, choices != .null else { return events }
        guard case .array(let list) = choices else { return malformed() }
        for choice in list {
            guard case .object = choice else { return events + malformed() }
            // `n` is never sent, so only the first choice is read.
            if let index = choice["index"], Self.integer(index) != 0 { continue }
            guard finishReason == nil else { continue }
            if let delta = choice["delta"], delta != .null {
                guard case .object = delta else { return events + malformed() }
                switch delta["content"] {
                case .none, .some(.null): break
                case .some(.string(let text)):
                    if !text.isEmpty { events += self.text(text) }
                default: return events + malformed()
                }
                switch delta["tool_calls"] {
                case .none, .some(.null): break
                case .some(.array(let deltas)):
                    for d in deltas {
                        events += toolCall(d)
                        if isEnded { return events }
                    }
                default: return events + malformed()
                }
            }
            switch choice["finish_reason"] {
            case .none, .some(.null): break
            case .some(.string(let reason)): events += finish(reason)
            default: return events + malformed()
            }
            if isEnded { return events }
        }
        return events
    }

    private mutating func text(_ text: String) -> [CanonicalStreamEvent] {
        var events: [CanonicalStreamEvent] = []
        let index: Int
        if let open = openText {
            index = open
        } else {
            index = nextIndex
            nextIndex += 1
            openText = index
            events.append(.contentBlockStart(index: index, block: .object(["type": .string("text"), "text": .string("")])))
        }
        events.append(.contentBlockDelta(index: index, delta: .object(["type": .string("text_delta"), "text": .string(text)])))
        return events
    }

    private mutating func closeText() -> [CanonicalStreamEvent] {
        guard let open = openText else { return [] }
        openText = nil
        return [.contentBlockStop(index: open)]
    }

    /// One tool-call delta: `index` names the call; `id` and `function.name` are kept from their first appearance,
    /// `function.arguments` pieces are appended.
    private mutating func toolCall(_ d: StrictJSON) -> [CanonicalStreamEvent] {
        guard case .object = d else { return malformed() }
        let index: Int
        switch d["index"] {
        case .none: index = 0
        case .some(let value):
            guard let n = Self.integer(value), n >= 0 else { return malformed() }
            index = n
        }
        var id = "", name = "", arguments = ""
        switch d["id"] {
        case .none, .some(.null): break
        case .some(.string(let s)): id = s
        default: return malformed()
        }
        if let function = d["function"], function != .null {
            guard case .object = function else { return malformed() }
            switch function["name"] {
            case .none, .some(.null): break
            case .some(.string(let s)): name = s
            default: return malformed()
            }
            switch function["arguments"] {
            case .none, .some(.null): break
            case .some(.string(let s)): arguments = s
            default: return malformed()
            }
        }
        let events = closeText()
        if calls[index] == nil {
            guard calls.count < Self.maxToolCalls else { return events + exceeded("\(Self.maxToolCalls) tool calls") }
            calls[index] = ToolCall()
            callOrder.append(index)
        }
        var call = calls[index] ?? ToolCall()
        var added = arguments.utf8.count
        if call.id.isEmpty, !id.isEmpty { call.id = id; added += id.utf8.count }
        if call.name.isEmpty, !name.isEmpty { call.name = name; added += name.utf8.count }
        guard toolBytes + added <= Self.maxToolArgumentBytes else { return events + exceeded("4 MiB of tool-call arguments") }
        toolBytes += added
        call.arguments += arguments
        calls[index] = call
        notePeak()
        return events
    }

    /// The finish reason: the open text block closes, every tool call is emitted whole, in the order the calls began.
    private mutating func finish(_ reason: String) -> [CanonicalStreamEvent] {
        var events = closeText()
        for index in callOrder {
            guard let call = calls[index] else { continue }
            let block = nextIndex
            nextIndex += 1
            let input = String(decoding: Self.toolInput(call.arguments).serialized(), as: UTF8.self)
            events.append(.contentBlockStart(index: block, block: .object([
                "type": .string("tool_use"), "id": .string(Self.toolUseId(call.id)), "name": .string(call.name), "input": .object([:]),
            ])))
            events.append(.contentBlockDelta(index: block, delta: .object(["type": .string("input_json_delta"), "partial_json": .string(input)])))
            events.append(.contentBlockStop(index: block))
        }
        finishReason = Self.stopReason(reason, hasToolCalls: !callOrder.isEmpty)
        calls.removeAll()
        toolBytes = 0
        return events
    }

    /// `[DONE]` or the end of the body: the reply ends normally after a finish reason, else with an `error` event.
    private mutating func done() -> [CanonicalStreamEvent] {
        guard !isEnded else { return [] }
        guard let finishReason else {
            return error(type: "api_error", message: "Brahma: the provider stream ended before its finish reason")
        }
        isEnded = true
        endedNormally = true
        let shown = usageInvalid ? nil : usage
        return [.messageDelta(stopReason: finishReason, usage: shown ?? Self.zeroUsage), .messageStop]
    }

    private mutating func malformed() -> [CanonicalStreamEvent] {
        error(type: "api_error", message: "Brahma: the provider stream is malformed")
    }

    private mutating func exceeded(_ bound: String) -> [CanonicalStreamEvent] {
        error(type: "overloaded_error", message: "Brahma: provider stream exceeded \(bound)")
    }

    /// Ends the reply with an `error` event and drops everything held.
    private mutating func error(type: String, message: String) -> [CanonicalStreamEvent] {
        isEnded = true
        line = []
        calls = [:]
        callOrder = []
        toolBytes = 0
        return [.error(type: type, message: message)]
    }

    // MARK: Shared with the adapter's whole-message path

    static let zeroUsage = GatewayUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)

    /// `finish_reason` as a Messages `stop_reason`: `stop` → `end_turn` (`tool_use` when the reply made tool calls),
    /// `length` → `max_tokens`, `tool_calls` → `tool_use`, `content_filter` and anything else → `end_turn`.
    static func stopReason(_ reason: String?, hasToolCalls: Bool) -> String {
        switch reason {
        case "length": "max_tokens"
        case "tool_calls", "function_call": "tool_use"
        case "stop": hasToolCalls ? "tool_use" : "end_turn"
        default: "end_turn"
        }
    }

    /// A tool call's arguments as the `tool_use` input: the JSON object they hold (parsed strictly, numbers exact), or `{}`
    /// when they hold anything else.
    static func toolInput(_ arguments: String) -> StrictJSON {
        guard !arguments.allSatisfy(\.isWhitespace) else { return .object([]) }
        do {
            let parsed = try StrictJSON.parse(Data(arguments.utf8))
            if case .object = parsed { return parsed }
            return .object([])
        } catch {
            return .object([])
        }
    }

    /// A provider tool-call id as a `tool_use` id (`^[A-Za-z0-9_-]{1,64}$`), else a new one.
    static func toolUseId(_ id: String) -> String {
        let valid = (1...64).contains(id.utf8.count) && id.utf8.allSatisfy(isIdByte)
        return valid ? id : "toolu_brahma_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24)
    }

    /// A provider message id or model name as relayed: letters, digits, `_ - . :`, at most 128; else `fallback`.
    static func plainId(_ value: StrictJSON?, fallback: String) -> String {
        guard let s = value?.stringValue, (1...128).contains(s.utf8.count),
              s.utf8.allSatisfy({ isIdByte($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: ":") }) else { return fallback }
        return s
    }

    private static func isIdByte(_ b: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) || b == UInt8(ascii: "_") || b == UInt8(ascii: "-")
    }

    /// A Chat Completions `usage` object as `GatewayUsage`, or nil when any count is missing, not a whole number, below zero,
    /// above `GatewayUsage.maxTokens`, or the cached tokens exceed the prompt.
    static func usage(_ value: StrictJSON) -> GatewayUsage? {
        guard case .object = value, let prompt = count(value["prompt_tokens"]), let completion = count(value["completion_tokens"]) else {
            return nil
        }
        var cached = 0
        switch value["prompt_tokens_details"] {
        case .none, .some(.null): break
        case .some(let details):
            guard case .object = details else { return nil }
            switch details["cached_tokens"] {
            case .none, .some(.null): break
            case .some(let n):
                guard let c = count(n) else { return nil }
                cached = c
            }
        }
        guard cached <= prompt else { return nil }
        return GatewayUsage(inputTokens: prompt - cached, outputTokens: completion, cacheReadTokens: cached, cacheWriteTokens: 0)
    }

    /// A token count: a JSON integer from 0 to `GatewayUsage.maxTokens`.
    private static func count(_ value: StrictJSON?) -> Int? {
        guard let value, let n = integer(value), (0...GatewayUsage.maxTokens).contains(n) else { return nil }
        return n
    }

    /// A JSON number written as an integer (`-?[0-9]+`) that fits an `Int`.
    static func integer(_ value: StrictJSON) -> Int? {
        guard case .number(let digits) = value else { return nil }
        return Int(digits)
    }

    /// An OpenAI error object as one line: `type: message`, or the message alone.
    static func errorDetail(_ error: StrictJSON) -> String {
        if let text = error.stringValue { return text }
        let message = error["message"]?.stringValue ?? ""
        let type = error["type"]?.stringValue
        return (type.map { $0 + ": " } ?? "") + message
    }
}

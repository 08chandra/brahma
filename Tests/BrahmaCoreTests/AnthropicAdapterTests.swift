import Testing
import Foundation
@testable import BrahmaCore

/// Plan X1 Task 8: the canonical request and the `anthropic` adapter — the key swap, the body pass-through (only `model` for an
/// alias and `metadata.user_id` ever change), the upstream header allowlist (Ruling 43), the usage tap and redacted errors.
@Suite(.scratch, .serialized) struct AnthropicAdapterTests {
    static let provider = AnthropicFixture.provider()

    static func upstream(_ body: String, model: String? = nil, endpoint: GatewayEndpoint = .messages,
                         headers: [GatewayHeader] = []) throws -> UpstreamRequest {
        let tree = try CanonicalRequest.tree(Data(body.utf8))
        let canonical = try CanonicalRequest.decode(tree: tree)
        return try AnthropicAdapter().upstream(canonical, body: tree, model: model ?? canonical.model, endpoint: endpoint,
                                               headers: headers, provider: provider, key: AnthropicFixture.key)
    }

    // MARK: The canonical request

    /// The request `claude` sends (X1-0): `role: "system"` inside `messages`, thinking, tool_use / tool_result / image blocks,
    /// and top-level keys the canonical type does not model, kept in `extra`.
    @Test func decodesWhatClaudeSends() throws {
        let r = try CanonicalRequest.decode(try AnthropicFixture.data("request-claude", "json"))
        #expect(r.model == "claude-opus-5-5")
        #expect(r.maxTokens == 128000 && r.stream == true && r.temperature == 1)
        #expect(r.messages.map(\.role) == ["user", "system", "assistant", "user"])
        #expect(r.messages[1].content == .text("Mode: work."))
        guard case .blocks(let assistant) = r.messages[2].content, case .blocks(let results) = r.messages[3].content else {
            Issue.record("block content expected"); return
        }
        #expect(assistant.count == 2)
        if case .other(let thinking) = assistant[0] { #expect(thinking.objectValue?["type"] == .string("thinking")) } else {
            Issue.record("a thinking block is kept as it is")
        }
        #expect(assistant[1] == .toolUse(id: "toolu_1", name: "Read", input: .object(["file_path": .string("hello.txt")])))
        #expect(results[0] == .toolResult(toolUseId: "toolu_1", content: .text("hi"), isError: false))
        if case .image = results[1] {} else { Issue.record("an image block") }
        #expect(r.tools?.map(\.name) == ["Read"])
        #expect(r.toolChoice == .object(["type": .string("auto")]))
        #expect(r.stopSequences == ["\n\nHuman:"])
        #expect(r.system == .blocks([.text("You are Claude Code.")]))
        #expect(Set(r.extra.keys) == ["thinking", "context_management", "output_config"])
        #expect(r.metadata?["user_id"] != nil)
    }

    /// A key that appears twice could route on one value and reach the provider with the other: refused before routing.
    @Test func repeatedOrMalformedTopLevelRefused() {
        for body in [#"{"model":"brahma-standard","model":"claude-fable-5-1","max_tokens":1,"messages":[]}"#,
                     #"{"model":"brahma-standard","model":"claude-fable-5-1","max_tokens":1,"messages":[]}"#,
                     #"{"model":"a","max_tokens":1,"messages":[],"metadata":{"user_id":"x","user_id":"y"}}"#,
                     #"{"model":"a","max_tokens":1,"messages":[]} {}"#, #"["model"]"#, #"{"model":7,"messages":[]}"#, ""] {
            #expect(throws: GatewayError.self, "\(body)") { try CanonicalRequest.decode(Data(body.utf8)) }
        }
    }

    @Test func streamEventsEncodeAsSSE() {
        let usage = GatewayUsage(inputTokens: 3, outputTokens: 4, cacheReadTokens: 5, cacheWriteTokens: 6)
        let start = String(decoding: CanonicalStreamEvent.messageStart(id: "msg_1", model: "m", usage: usage).sse(), as: UTF8.self)
        #expect(start.hasPrefix("event: message_start\ndata: {") && start.hasSuffix("}\n\n"))
        let json = try? JSONSerialization.jsonObject(with: Data(start.split(separator: "\n")[1].dropFirst(6).utf8)) as? [String: Any]
        let u = (json?["message"] as? [String: Any])?["usage"] as? [String: Int]
        #expect(u == ["input_tokens": 3, "output_tokens": 4, "cache_read_input_tokens": 5, "cache_creation_input_tokens": 6])
        #expect(String(decoding: CanonicalStreamEvent.messageStop.sse(), as: UTF8.self) == "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
        let delta = String(decoding: CanonicalStreamEvent.messageDelta(stopReason: "tool_use", usage: nil).sse(), as: UTF8.self)
        #expect(delta.hasPrefix("event: message_delta\n") && delta.contains(#""stop_reason":"tool_use""#))
        let error = String(decoding: CanonicalStreamEvent.error(type: "overloaded_error", message: "Brahma: x").sse(), as: UTF8.self)
        #expect(error.hasPrefix("event: error\n") && error.contains(#""type":"overloaded_error""#))
    }

    // MARK: Upstream requests

    /// Ruling X1-35 / 46: the provider gets the serialization of the policy-checked tree, never the bytes received — equal in
    /// meaning, keys in the order received, numbers with exactly the digits received (2^63+1 and a long decimal survive),
    /// strings re-escaped, no whitespace. `metadata.user_id` (a device id) is the one field removed; an alias changes only
    /// `model`.
    @Test func forwardsThePolicyCheckedTree() throws {
        let plain = #"{ "model" : "claude-opus-5-5","max_tokens":128000, "temperature":0.70,"x_future":{"b":1,"a":[1e2, -0.0, 9223372036854775809, 0.1234567890123456789012345678901]},"messages":[{"role":"user","content":"hé \"q\" \\ \n\/"}],"metadata":{"other":"kept"} }"#
        let sent = try Self.upstream(plain)
        let text = String(decoding: sent.body, as: UTF8.self)
        #expect(text == #"{"model":"claude-opus-5-5","max_tokens":128000,"temperature":0.70,"x_future":{"b":1,"a":[1e2,-0.0,9223372036854775809,0.1234567890123456789012345678901]},"messages":[{"role":"user","content":"hé \"q\" \\ \n/"}],"metadata":{"other":"kept"}}"#)
        #expect(try StrictJSON.parse(sent.body) == StrictJSON.parse(Data(plain.utf8)), "equal in meaning")
        #expect(text.contains("9223372036854775809") && text.contains("0.1234567890123456789012345678901"))
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.method == "POST")

        let withUser = #"{"model":"claude-opus-5-5","metadata":{"user_id":"{\"device_id\":\"00ff\"}", "other":"kept"},"max_tokens":1,"messages":[]}"#
        #expect(String(decoding: try Self.upstream(withUser).body, as: UTF8.self)
                    == #"{"model":"claude-opus-5-5","metadata":{"other":"kept"},"max_tokens":1,"messages":[]}"#)
        let userLast = #"{"model":"claude-opus-5-5","metadata":{"other":"kept" , "user_id":"u"},"max_tokens":1,"messages":[]}"#
        #expect(String(decoding: try Self.upstream(userLast).body, as: UTF8.self)
                    == #"{"model":"claude-opus-5-5","metadata":{"other":"kept"},"max_tokens":1,"messages":[]}"#)
        let userOnly = #"{"model":"claude-opus-5-5","metadata":{ "user_id":"u" },"max_tokens":1,"messages":[]}"#
        #expect(String(decoding: try Self.upstream(userOnly).body, as: UTF8.self)
                    == #"{"model":"claude-opus-5-5","metadata":{},"max_tokens":1,"messages":[]}"#)

        // An alias: only `model` is replaced (here together with `metadata.user_id`, on the same path).
        let alias = #"{"messages":[{"role":"user","content":"hi"}], "model":"brahma-standard" ,"temperature":0.70,"metadata":{"user_id":"u"},"max_tokens":32000}"#
        #expect(String(decoding: try Self.upstream(alias, model: "claude-sonnet-5-5").body, as: UTF8.self)
                    == #"{"messages":[{"role":"user","content":"hi"}],"model":"claude-sonnet-5-5","temperature":0.70,"metadata":{},"max_tokens":32000}"#)

        // The fixture of a real request: only the metadata member goes.
        let fixture = try AnthropicFixture.text("request-claude", "json").trimmingCharacters(in: .newlines)
        let stripped = String(decoding: try Self.upstream(fixture).body, as: UTF8.self)
        let userMember = try #require(fixture.range(of: #""user_id":"{\"device_id\":\"00ff\",\"account_uuid\":\"\",\"session_id\":\"5e55\"}""#))
        #expect(stripped == fixture.replacingCharacters(in: userMember, with: ""))

        // count_tokens goes to its own endpoint.
        #expect(try Self.upstream(plain, endpoint: .countTokens).url.absoluteString == "https://api.anthropic.com/v1/messages/count_tokens")
    }

    /// Ruling 43: only the allowlisted headers go upstream, each a short printable value; the key is the adapter's alone.
    @Test func forwardsOnlyAllowlistedHeaders() throws {
        let body = #"{"model":"claude-opus-5-5","max_tokens":1,"messages":[]}"#
        func h(_ name: String, _ value: String) -> GatewayHeader { GatewayHeader(name: name, value: value) }
        let hostile = [
            h("cookie", "session=1"), h("x-forwarded-for", "10.0.0.1"), h("x-forwarded-host", "evil"), h("host", "evil"),
            h("anthropic-beta", "a\r\nx: y"), h("x-api-key", "client-supplied"), h("authorization", "Bearer client"),
            h("connection", "keep-alive"), h("content-length", "99"), h("accept-encoding", "gzip, br"), h("transfer-encoding", "chunked"),
            h("anthropic-version", "2023-06-01"), h("content-type", "application/json"), h("accept", "application/json"),
            h("x-app", "cli"), h("user-agent", "claude-cli/2.1.325 (external, sdk-cli)"), h("x-stainless-os", "MacOS"),
            h("x-stainless-retry-count", "0"), h("x-claude-code-session-id", "5e55"),
            h("x-stainless-arch", "arm64\t"), h("x-stainless-lang", "js\u{7f}"), h("x-stainless-runtime", "nodé"),
            h("x-stainless-timeout", String(repeating: "9", count: 513)),
            h("anthropic-dangerous-direct-browser-access", "true"),
        ]
        let sent = try Self.upstream(body, headers: hostile)
        #expect(sent.headers == [
            "x-api-key": AnthropicFixture.key, "anthropic-version": "2023-06-01", "content-type": "application/json",
            "accept": "application/json", "x-app": "cli", "user-agent": "claude-cli/2.1.325 (external, sdk-cli)",
            "x-stainless-os": "MacOS", "x-stainless-retry-count": "0", "x-claude-code-session-id": "5e55",
        ])
        // A valid anthropic-beta is forwarded; one outside `^[a-z0-9,._-]{1,512}$` is not.
        let betas = "prompt-caching-2024-07-31,context-management-2025-06-27"
        #expect(try Self.upstream(body, headers: [h("anthropic-beta", betas)]).headers["anthropic-beta"] == betas)
        #expect(try Self.upstream(body, headers: [h("anthropic-beta", "a, b")]).headers["anthropic-beta"] == nil)
        // With no client headers the adapter still sends the key, a JSON content type and an API version.
        #expect(try Self.upstream(body).headers == ["x-api-key": AnthropicFixture.key, "content-type": "application/json",
                                                     "anthropic-version": AnthropicAdapter.defaultVersion])
    }

    @Test func providerHostMustBeOneHostName() throws {
        let tree = try CanonicalRequest.tree(Data(#"{"model":"claude-opus-5-5","max_tokens":1,"messages":[]}"#.utf8))
        let canonical = try CanonicalRequest.decode(tree: tree)
        for host in ["", "*.anthropic.com", "127.0.0.1", "api.anthropic.com/evil", "api.anthropic.com:8443", "user@api.anthropic.com"] {
            #expect(throws: GatewayError.self, "\(host)") {
                try AnthropicAdapter().upstream(canonical, body: tree, model: "claude-opus-5-5", endpoint: .messages, headers: [],
                                                provider: AnthropicFixture.provider(host: host), key: AnthropicFixture.key)
            }
        }
    }

    // MARK: StrictJSON (Ruling X1-35)

    /// A key repeated in any object at any depth is refused, compared after unescaping, with its path.
    @Test func strictJSONRefusesDuplicateKeysAtAnyDepth() {
        let cases: [(String, String)] = [
            (#"{"type":"a","type":"b"}"#, "type"),
            (#"{"a":{"b":{"c":{"d":{"type":1,"type":2}}}}}"#, "a.b.c.d.type"),
            (#"{"tools":[{"name":"x"},{"name":"y","type":"custom","type":"web_fetch_20250910"}]}"#, "tools[1].type"),
            (#"{"messages":[{"content":[{"type":"text","text":"","type":"image"}]}]}"#, "messages[0].content[0].type"),
            (#"{"m":[{"source":{"type":"base64","type":"url"}}]}"#, "m[0].source.type"),
            (#"{"type":"text","type":"web_fetch"}"#, "type"),
            (#"{"type":1,"type":2}"#, "type"),
        ]
        for (body, path) in cases {
            #expect(throws: StrictJSON.Failure.duplicateKey(path: path), "\(body)") { try StrictJSON.parse(Data(body.utf8)) }
        }
        // The same key in different objects is fine.
        #expect(throws: Never.self) { try StrictJSON.parse(Data(#"{"type":"a","b":{"type":"c"},"c":[{"type":1},{"type":2}]}"#.utf8)) }
    }

    @Test func strictJSONIsStrict() throws {
        for bad in ["", " ", "{", #"{"a":1,}"#, "[1,]", "01", "1.", ".5", "+1", "NaN", "1e", "-", #""\ud800""#, #""\udc00x""#,
                    "\"a\tb\"", "\"a\u{01}b\"", #""\x""#, "tru", "{} {}", #"{'a':1}"#, #"{"a" 1}"#] {
            #expect(throws: StrictJSON.Failure.self, "\(bad)") { try StrictJSON.parse(Data(bad.utf8)) }
        }
        let deep = String(repeating: "[", count: StrictJSON.maxDepth + 2) + String(repeating: "]", count: StrictJSON.maxDepth + 2)
        #expect(throws: StrictJSON.Failure.tooDeep) { try StrictJSON.parse(Data(deep.utf8)) }
        // Escapes decode (a surrogate pair included) and re-encode as valid, meaning-equal JSON.
        let tree = try StrictJSON.parse(Data(#"{"s":"😀 \u0007 \t é","n":[0,-1.5e-3,1E+9]}"#.utf8))
        #expect(tree["s"] == .string("😀 \u{07} \t é"))
        #expect(String(decoding: tree.serialized(), as: UTF8.self) == #"{"s":"😀 \u0007 \t é","n":[0,-1.5e-3,1E+9]}"#)
        #expect(try StrictJSON.parse(tree.serialized()) == tree)
        // Foundation reads the serialization as the same document.
        let foundation = try JSONSerialization.jsonObject(with: tree.serialized()) as? [String: Any]
        #expect(foundation?["s"] as? String == "😀 \u{07} \t é")
    }

    /// Ruling X1-36 / 47: parsing is linear — counted, not timed. Doubling a 10k-element array nested 60 deep, or a 50k-key
    /// object, doubles the parser's steps, and no path is rendered for a body that parses.
    @Test func strictJSONWorkIsLinearAndRendersNoPathOnSuccess() throws {
        func work(_ body: String) throws -> StrictJSON.Work {
            var w = StrictJSON.Work()
            _ = try StrictJSON.parse(Data(body.utf8), work: &w)
            return w
        }
        func deepWide(_ n: Int) -> String {
            String(repeating: "[", count: 60) + Array(repeating: "0", count: n).joined(separator: ",") + String(repeating: "]", count: 60)
        }
        func wide(_ n: Int) -> String { "{" + (0..<n).map { "\"k\($0)\":[\($0)]" }.joined(separator: ",") + "}" }
        for (small, large) in [(try work(deepWide(10_000)), try work(deepWide(20_000))), (try work(wide(50_000)), try work(wide(100_000)))] {
            #expect(small.pathRenders == 0 && large.pathRenders == 0, "no path is rendered on success")
            let ratio = Double(large.steps) / Double(small.steps)
            #expect((1.9...2.1).contains(ratio), "steps \(small.steps) -> \(large.steps)")
        }
    }

    /// A duplicate deep inside still names its path, truncated to the last 256 characters behind an ellipsis; one render.
    @Test func strictJSONDeepDuplicatePathIsTruncated() {
        let keys = (0..<40).map { "level\($0)_long" }
        let body = keys.map { "{\"\($0)\":" }.joined() + #"{"type":1,"type":2}"# + String(repeating: "}", count: keys.count)
        var work = StrictJSON.Work()
        do {
            _ = try StrictJSON.parse(Data(body.utf8), work: &work)
            Issue.record("the duplicate must be refused")
        } catch {
            guard case .duplicateKey(let path) = error else { Issue.record("\(error)"); return }
            let full = (keys + ["type"]).joined(separator: ".")
            #expect(path.count == StrictJSON.maxPathLength && path.hasPrefix("…") && full.hasSuffix(path.dropFirst()), "\(path)")
            #expect(work.pathRenders == 1)
        }
    }

    /// At most 64 nested containers; the 65th is refused with a reason.
    @Test func strictJSONDepthIsCappedAt64() throws {
        func nested(_ n: Int) -> Data { Data((String(repeating: "[", count: n) + String(repeating: "]", count: n)).utf8) }
        #expect(StrictJSON.maxDepth == 64)
        #expect(throws: Never.self) { try StrictJSON.parse(nested(64)) }
        #expect(throws: StrictJSON.Failure.tooDeep) { try StrictJSON.parse(nested(65)) }
        let body = #"{"model":"claude-opus-5-5","max_tokens":1,"messages":[],"metadata":{"x":"# + String(repeating: "[", count: 63)
            + String(repeating: "]", count: 63) + "}}"
        do {
            _ = try CanonicalRequest.tree(Data(body.utf8))
            Issue.record("depth 65 must be refused")
        } catch {
            #expect(error.status == 400 && error.message == "Brahma: the request body nests more than 64 levels deep", "\(error)")
        }
    }

    /// Ruling 49 m2: at most `maxSteps` values and keys (a 32 MiB `[0,0,…]` would be 16M nodes); a realistic large request —
    /// the fixture plus a 30 MiB base64 image — is far below it.
    @Test func strictJSONCapsTotalValues() throws {
        let tooMany = "[" + Array(repeating: "0", count: StrictJSON.maxSteps).joined(separator: ",") + "]"
        #expect(throws: StrictJSON.Failure.tooManyValues) { try StrictJSON.parse(Data(tooMany.utf8)) }
        do {
            _ = try CanonicalRequest.tree(Data(tooMany.utf8))
            Issue.record("refused")
        } catch {
            #expect(error.status == 400 && error.message == "Brahma: the request body holds more than \(StrictJSON.maxSteps) values")
        }
        let fixture = try AnthropicFixture.text("request-claude", "json").trimmingCharacters(in: .newlines)
        let image = #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":""# + String(repeating: "A", count: 30 << 20) + #""}}"#
        let large = fixture.replacingOccurrences(of: #"{"type":"text","text":"Read hello.txt","cache_control":{"type":"ephemeral"}}"#,
                                                 with: image)
        #expect(large.utf8.count > 30 << 20)
        var work = StrictJSON.Work()
        _ = try StrictJSON.parse(Data(large.utf8), work: &work)
        #expect(work.steps < 1000)
    }

    /// Ruling 49 m1: a leading U+FEFF in a string or key is kept, raw or escaped.
    @Test func strictJSONKeepsALeadingByteOrderMark() throws {
        let tree = try StrictJSON.parse(Data("{\"\u{FEFF}k\":\"\u{FEFF}x\",\"e\":\"\\ufeffy\"}".utf8))
        #expect(tree.members?.first?.key == "\u{FEFF}k")
        #expect(tree["\u{FEFF}k"] == .string("\u{FEFF}x"))
        #expect(tree["e"] == .string("\u{FEFF}y"))
        #expect(try StrictJSON.parse(tree.serialized()) == tree)
    }

    /// Ruling 49 m6: a non-streamed response whose task is cancelled mid-body is never relayed (no truncated 200).
    @Test func cancelledNonStreamedResponseIsNotRelayed() async throws {
        let rig = try ReplyRig()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(Data(#"{"type":"message","content":[{"type":"text","text":"par"#.utf8))
        let reply = rig.reply
        let task = Task {
            try await AnthropicAdapter().translate(status: 200, headers: ["content-type": "application/json"], body: stream,
                                                   streamed: false, into: reply, redact: { $0 })
        }
        task.cancel()
        #expect(try await task.value == .none)
        rig.finish()
        await #expect(throws: TestPeerError.eof) { try await rig.peer.readHead() }
    }

    // MARK: Responses

    /// The stream reaches the client unchanged (events split across upstream chunks are re-joined into whole events) while the
    /// tap reads `message_start.usage` and the final `message_delta.usage`.
    @Test func readsStreamingFinalUsage() async throws {
        let fixture = try AnthropicFixture.data("stream-tools", "sse")
        let rig = try ReplyRig()
        guard case .respond(let status, let headers, let chunks, _) = FakeUpstream.sse(fixture, chunk: 5) else { return }
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        chunks.forEach { continuation.yield($0) }
        continuation.finish()
        let outcome = try await AnthropicAdapter().translate(status: status, headers: headers, body: stream, streamed: true, into: rig.reply,
                                                             redact: { $0 })
        // The terminal message_delta usage then message_stop, and a normal end: final (Ruling X1-37).
        #expect(outcome == UsageOutcome(usage: GatewayUsage(inputTokens: 25, outputTokens: 87, cacheReadTokens: 2000, cacheWriteTokens: 100),
                                        complete: true))
        rig.finish()
        let response = try await rig.peer.readResponse()
        #expect(response.status == 200 && response.head.headers["content-type"] == "text/event-stream")
        #expect(Data(response.body) == fixture)
    }

    @Test func readsNonStreamedUsage() async throws {
        let fixture = try AnthropicFixture.data("message", "json")
        let rig = try ReplyRig()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.yield(fixture.prefix(40)); continuation.yield(fixture.dropFirst(40))
        continuation.finish()
        let outcome = try await AnthropicAdapter().translate(status: 200, headers: ["content-type": "application/json"], body: stream,
                                                             streamed: false, into: rig.reply, redact: { $0 })
        #expect(outcome == UsageOutcome(usage: GatewayUsage(inputTokens: 12, outputTokens: 34, cacheReadTokens: 5, cacheWriteTokens: 6),
                                        complete: true))
        rig.finish()
        let response = try await rig.peer.readResponse()
        #expect(response.status == 200 && Data(response.body) == fixture)
    }

    /// Ruling X1-37: a stream's usage is final only after the terminal `message_delta` usage, then `message_stop`, then a
    /// normal end; the usage of `message_start` alone, or a stream without `message_stop`, is not.
    @Test func streamUsageIsFinalOnlyAfterItsTerminalReport() {
        var tap = AnthropicUsageTap()
        tap.read(event: #"{"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":1}}}"#)
        #expect(tap.outcome(endedNormally: true).complete == false, "message_start alone")
        tap.read(event: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":87}}"#)
        #expect(tap.outcome(endedNormally: true).complete == false, "no message_stop")
        tap.read(event: #"{"type":"message_stop"}"#)
        #expect(tap.outcome(endedNormally: false).complete == false, "ended early")
        #expect(tap.outcome(endedNormally: true) == UsageOutcome(usage: GatewayUsage(inputTokens: 25, outputTokens: 87, cacheReadTokens: 0,
                                                                                    cacheWriteTokens: 0), complete: true))
        var stopOnly = AnthropicUsageTap()
        stopOnly.read(event: #"{"type":"message_start","message":{"usage":{"input_tokens":25,"output_tokens":1}}}"#)
        stopOnly.read(event: #"{"type":"message_stop"}"#)
        #expect(stopOnly.outcome(endedNormally: true).complete == false, "message_stop without the terminal usage")
        #expect(UsageOutcome(usage: nil, complete: true).complete == false, "no usage is never final")
    }

    /// Usage the provider reports out of range is clamped, never negative or absurd; a body with no usage yields none.
    @Test func usageIsClampedAndOptional() {
        var tap = AnthropicUsageTap()
        tap.read(event: #"{"type":"message_start","message":{"usage":{"input_tokens":-5,"output_tokens":1e300,"cache_read_input_tokens":"7"}}}"#)
        #expect(tap.usage == GatewayUsage(inputTokens: 0, outputTokens: GatewayUsage.maxTokens, cacheReadTokens: 0, cacheWriteTokens: 0))
        #expect(AnthropicUsageTap().usage == nil)
        #expect(AnthropicUsageTap.usage(ofMessage: Data(#"{"input_tokens":12}"#.utf8)) == nil)
    }

    /// An upstream 401 whose body carries the key: the client gets an error with `[redacted]` in its place, the turn ends (400,
    /// not a retried 401), and no log line holds the key.
    @Test func upstreamErrorRedactsKey() async throws {
        let body = try AnthropicFixture.text("error-401", "json").replacingOccurrences(of: "{{KEY}}", with: AnthropicFixture.key)
        let rig = try ModelGatewayRig([FakeUpstream.json(401, body)])
        let response = try await rig.exchange(#"{"model":"claude-opus-5-5","max_tokens":1,"messages":[]}"#, token: rig.grant())
        #expect(response.status == 400)
        #expect(response.errorType == "invalid_request_error")
        #expect(!response.text.contains(AnthropicFixture.key))
        #expect(response.text.contains("[redacted]"), "\(response.text)")
        #expect(response.text.contains("401"))
        #expect(rig.upstream.requests.count == 1)
        #expect(rig.upstream.requests.first?.headers["x-api-key"] == AnthropicFixture.key)
        #expect(!rig.logLines.isEmpty)
        #expect(rig.logLines.allSatisfy { !$0.contains(AnthropicFixture.key) }, "\(rig.logLines)")
        #expect(rig.logLines.contains { $0.contains("[redacted]") })
    }
}

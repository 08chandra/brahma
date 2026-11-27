import Testing
import Foundation
@testable import BrahmaCore

/// Fixtures under `Fixtures/openai/`, and the provider they speak for.
enum OpenAIFixture {
    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/openai"))
        return try Data(contentsOf: url)
    }

    static func text(_ name: String, _ ext: String) throws -> String { String(decoding: try data(name, ext), as: UTF8.self) }

    /// A one-line JSON fixture without its final newline.
    static func json(_ name: String) throws -> String { try text(name, "json").trimmingCharacters(in: .newlines) }

    /// A provider key in the real format, assembled at runtime (lane rule: no key-format literal in fixtures).
    static let key = ["sk", "proj", "FIXTURE0only0not0a0key0", "AA"].joined(separator: "-")
    static let keyName = "BRAHMA_KEY_OPENAI"
    static let redact: @Sendable (String) -> String = { $0.replacingOccurrences(of: key, with: "[redacted]") }

    static func provider(baseURL: String = "https://api.openai.com/v1", host: String = "api.openai.com") -> Provider {
        Provider(id: "openai", adapter: AdapterId.openAICompatible.rawValue, baseURL: URL(string: baseURL)!, host: host, keySecret: keyName,
                 builtin: true, createdAt: Date(timeIntervalSince1970: 0))
    }

    static let price = PriceRow(provider: "openai", model: "gpt-5.5", inPerMTok: 1.25, outPerMTok: 10, cacheReadPerMTok: 0.125, setBy: "owner")
    static let routes: [String: TurnGrant.RoutedTarget] = ["brahma-standard": .init(provider: "openai", model: "gpt-5.5")]
}

/// Plan X1 Task 10: the `openai-compatible` adapter — Messages → Chat Completions from the policy-checked tree (Ruling 57),
/// whole responses back, the two upstream headers, local `count_tokens`, and error billing (Ruling 55). The streamed path is
/// `OpenAICompatibleStreamTests`.
@Suite(.scratch, .serialized) struct OpenAICompatibleAdapterTests {
    static func upstream(_ body: String, model: String = "gpt-5.5", endpoint: GatewayEndpoint = .messages,
                         provider: Provider = OpenAIFixture.provider(), key: String = OpenAIFixture.key) throws -> UpstreamRequest {
        let tree = try CanonicalRequest.tree(Data(body.utf8))
        let canonical = try CanonicalRequest.decode(tree: tree)
        return try OpenAICompatibleAdapter().upstream(canonical, body: tree, model: model, endpoint: endpoint, headers: [],
                                                      provider: provider, key: key)
    }

    static func sentText(_ body: String) throws -> String { String(decoding: try upstream(body).body, as: UTF8.self) }

    /// The adapter's refusal of `body`, or nil when it translates.
    static func refusal(_ body: String) -> GatewayError? {
        do {
            _ = try upstream(body)
            return nil
        } catch let error as GatewayError {
            return error
        } catch {
            return .unavailable("\(error)")
        }
    }

    /// One response through `translate` into a real reply: its outcome or error, and what the client read.
    static func respond(_ body: Data, status: Int = 200, contentType: String = "application/json", streamed: Bool = false) async throws
        -> (outcome: UsageOutcome?, error: GatewayError?, response: TestResponse?) {
        let rig = try ReplyRig()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        var offset = 0
        while offset < body.count {
            continuation.yield(body.subdata(in: offset..<min(body.count, offset + 7)))
            offset += 7
        }
        continuation.finish()
        var outcome: UsageOutcome?
        var failure: GatewayError?
        do {
            outcome = try await OpenAICompatibleAdapter().translate(status: status, headers: ["content-type": contentType], body: stream,
                                                                     streamed: streamed, into: rig.reply, redact: OpenAIFixture.redact)
        } catch {
            failure = error
        }
        rig.finish()
        let response = failure == nil ? try await rig.peer.readResponse() : nil
        return (outcome, failure, response)
    }

    // MARK: Requests

    /// Five request goldens: each Messages request (it passes the policy) becomes exactly its Chat Completions body —
    /// system text first, `role: "system"` entries in place, tool calls with exact arguments (2^63+1 and a long decimal
    /// survive), tool results as `role: "tool"`, images as data URLs.
    @Test(arguments: ["text", "system", "tools", "tool-roundtrip", "image"])
    func requestGoldens(_ name: String) throws {
        let request = try OpenAIFixture.json("request-\(name)")
        let tree = try CanonicalRequest.tree(Data(request.utf8))
        try GatewayPolicy.check(body: tree, headers: [], grant: GatewayHarness.grant())
        #expect(try Self.sentText(request) == OpenAIFixture.json("chat-\(name)"))
    }

    /// Thinking blocks, `cache_control`, citations, `metadata` and every unmodelled top-level key are dropped, never sent.
    @Test func droppedFieldsNeverSent() throws {
        let system = try Self.sentText(try OpenAIFixture.json("request-system"))
        let tools = try Self.sentText(try OpenAIFixture.json("request-tools"))
        for word in ["thinking", "signature", "easy", "cache_control", "ephemeral", "citations", "cited_text", "metadata", "user_id",
                     "device_id", "context_management", "clear_thinking", "output_config", "effort", "safeguards", "adaptive"] {
            #expect(!system.contains(word), "\(word) in \(system)")
        }
        #expect(!tools.contains("cache_control") && !tools.contains("defer_loading"), "\(tools)")
        let standard = #"{"model":"brahma-standard","max_tokens":5,"messages":[{"role":"user","content":"hi"}],"speed":"standard","inference_geo":"global","service_tier":"standard_only","stream":false}"#
        #expect(try Self.sentText(standard) == #"{"model":"gpt-5.5","messages":[{"role":"user","content":"hi"}],"max_tokens":5}"#)
    }

    /// Ruling 57: the upstream headers are exactly `Authorization: Bearer <key>` and `content-type`; the URL is the provider's
    /// base URL on its pinned host + `/chat/completions`. A base URL that leaves the host, or a key that is not a header value,
    /// is unavailable (the message never holds the key); `count_tokens` is never sent upstream.
    @Test func upstreamHeadersAndURL() throws {
        let body = #"{"model":"brahma-standard","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}"#
        let sent = try Self.upstream(body)
        #expect(sent.headers == ["authorization": "Bearer " + OpenAIFixture.key, "content-type": "application/json"])
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/chat/completions" && sent.method == "POST")
        let router = OpenAIFixture.provider(baseURL: "https://openrouter.ai/api/v1/", host: "openrouter.ai")
        #expect(try Self.upstream(body, provider: router).url.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(try Self.upstream(body, provider: OpenAIFixture.provider(baseURL: "https://api.openai.com:443")).url.absoluteString
                    == "https://api.openai.com/chat/completions")
        for base in ["http://api.openai.com/v1", "https://evil.example/v1", "https://user@api.openai.com/v1", "https://api.openai.com:8443/v1",
                     "https://api.openai.com/v1?x=1", "https://api.openai.com/v1#f", "https://api.openai.com/v1/../x",
                     "https://api.openai.com/v1/%2e%2e/x", "https://api.openai.com/v1//x", "https://api.openai.com.evil.example/v1"] {
            #expect(throws: GatewayError.unavailable("provider openai has no valid https base URL on its host"), "\(base)") {
                try Self.upstream(body, provider: OpenAIFixture.provider(baseURL: base))
            }
        }
        #expect(throws: GatewayError.self) { try Self.upstream(body, provider: OpenAIFixture.provider(host: "*.openai.com")) }
        // Host names are case-insensitive: the request still goes to the pinned (lower-case) host.
        #expect(try Self.upstream(body, provider: OpenAIFixture.provider(baseURL: "https://API.openai.com/v1")).url.host == "api.openai.com")
        for key in [OpenAIFixture.key + "\r\nx-evil: 1", "", OpenAIFixture.key + " "] {
            do {
                _ = try Self.upstream(body, key: key)
                Issue.record("a key that is not a header value must be refused")
            } catch let error as GatewayError {
                #expect(error.status == 400 && !error.message.contains(OpenAIFixture.key), "\(error)")
            } catch {
                Issue.record("\(error)")
            }
        }
        #expect(throws: GatewayError.self) { try Self.upstream(body, endpoint: .countTokens) }
    }

    /// Ruling 57 / X1-34: only client tools become functions. A provider-side tool type — even one a grant allowed — is
    /// refused (403), so no `web_search`, `file_search`, `code_interpreter` or grounding tool is ever emitted.
    @Test func serverToolsNeverEmitted() async throws {
        for type in GatewayPolicy.providerNetworkTools.sorted() + ["web_search_20250305", "function", "mcp"] {
            let body = #"{"model":"m","max_tokens":5,"messages":[],"tools":[{"type":"\#(type)","name":"\#(type)"}]}"#
            let error = Self.refusal(body)
            #expect(error?.status == 403 && error?.type == "permission_error", "\(type): \(String(describing: error))")
        }
        // A client tool *named* like a provider tool is the caller's own function: sent as one.
        let named = #"{"model":"m","max_tokens":5,"messages":[],"tools":[{"name":"web_search","input_schema":{"type":"object"}}]}"#
        #expect(try Self.sentText(named).contains(#"{"type":"function","function":{"name":"web_search","parameters":{"type":"object"}}}"#))

        // Through the gateway, with a grant that allows web_search: still refused before anything goes upstream.
        let rig = try ModelGatewayRig([FakeUpstream.json(200, "{}")], providers: [OpenAIFixture.provider()], capped: ["openai"],
                                      adapters: [OpenAICompatibleAdapter()], prices: [OpenAIFixture.price])
        try rig.vault.set(companyId: rig.companyId, name: OpenAIFixture.keyName, value: OpenAIFixture.key)
        let token = rig.grant(aliases: OpenAIFixture.routes, serverTools: ["web_search"])
        let body = #"{"model":"brahma-standard","max_tokens":5,"messages":[{"role":"user","content":"hi"}],"tools":[{"type":"web_search","name":"web_search"}]}"#
        let response = try await rig.exchange(body, token: token)
        #expect(response.status == 403 && response.text.contains("only function tools"), "\(response.text)")
        #expect(rig.upstream.requests.isEmpty)
        #expect(try rig.charges().isEmpty, "a request refused before sending is released")
    }

    /// Content with no Chat Completions form is refused with a reason (400), never silently dropped.
    @Test func untranslatableContentRefused() {
        let cases = [
            #"[{"type":"document","source":{"type":"text","media_type":"text/plain","data":"x"}}]"#,
            #"[{"type":"image","source":{"type":"url","url":"https://x"}}]"#,
            #"[{"type":"image","source":{"type":"base64","media_type":"image/svg+xml","data":"PHN2Zz4="}}]"#,
            #"[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"a\"b"}}]"#,
            #"[{"type":"tool_result","tool_use_id":"t","content":[{"type":"tool_reference","tool_name":"x"}]}]"#,
            #"[{"type":"server_tool_use","id":"s","name":"web_search","input":{}}]"#,
        ]
        for content in cases {
            let body = #"{"model":"m","max_tokens":5,"messages":[{"role":"user","content":\#(content)}]}"#
            let error = Self.refusal(body)
            #expect(error?.status == 400 && error?.message.contains("cannot be sent to an openai-compatible provider") == true,
                    "\(content): \(String(describing: error))")
        }
        let toolChange = #"{"model":"m","max_tokens":5,"messages":[{"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_reference","name":"x"}}]}]}"#
        #expect(Self.refusal(toolChange)?.status == 400)
        #expect(Self.refusal(#"{"model":"m","max_tokens":5,"messages":[{"role":"developer","content":"x"}]}"#)?.status == 400)
        #expect(Self.refusal(#"{"model":"m","max_tokens":5,"messages":[],"tools":[{"name":"x","input_schema":{"type":"object"}}],"tool_choice":{"type":"later"}}"#)?.status == 400)
    }

    // MARK: Responses

    /// Four whole-response goldens: text (cached prompt tokens are cache reads), tool calls (exact arguments; empty
    /// arguments are `{}`), a length stop and a content filter; each usage is final.
    @Test func responseGoldens() async throws {
        let cases: [(String, GatewayUsage)] = [
            ("text", GatewayUsage(inputTokens: 20, outputTokens: 5, cacheReadTokens: 100, cacheWriteTokens: 0)),
            ("tool-call", GatewayUsage(inputTokens: 300, outputTokens: 40, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ("length", GatewayUsage(inputTokens: 10, outputTokens: 3, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ("content-filter", GatewayUsage(inputTokens: 10, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)),
        ]
        for (name, usage) in cases {
            let (outcome, error, response) = try await Self.respond(try OpenAIFixture.data("response-\(name)", "json"))
            #expect(error == nil, "\(name): \(String(describing: error))")
            #expect(outcome == UsageOutcome(usage: usage, complete: true), "\(name)")
            let expected = try OpenAIFixture.json("message-\(name)")
            #expect(response?.status == 200 && response?.text == expected, "\(name): \(response?.text ?? "")")
        }
    }

    /// The error golden: an OpenAI error body echoing the key. As a 401 it is relayed as a 400 (the turn ends at once); inside
    /// a 200 it is a 502; either way redacted.
    @Test func errorResponseGolden() async throws {
        let body = Data(try OpenAIFixture.json("response-error").replacingOccurrences(of: "{{KEY}}", with: OpenAIFixture.key).utf8)
        let (_, unauthorized, _) = try await Self.respond(body, status: 401)
        #expect(unauthorized == .upstream(status: 400, message: "Brahma: the provider answered HTTP 401: invalid_request_error: Incorrect API key provided: [redacted]."))
        let (_, inside, _) = try await Self.respond(body, status: 200)
        #expect(inside == .upstream(status: 502, message: "Brahma: the provider answered with an error: invalid_request_error: Incorrect API key provided: [redacted]."))
        let (_, limited, _) = try await Self.respond(body, status: 429)
        #expect(limited?.status == 429)
        for broken in ["", "not json", #"{"choices":[]}"#, #"{"choices":[{"message":{"content":7}}]}"#, #"{"a":1,"a":2}"#] {
            let (_, error, _) = try await Self.respond(Data(broken.utf8))
            #expect(error?.status == 502, "\(broken): \(String(describing: error))")
        }
        // Asked to stream, answered whole (or the reverse): refused, never relayed in the wrong shape.
        #expect(try await Self.respond(try OpenAIFixture.data("response-text", "json"), streamed: true).error?.status == 502)
        #expect(try await Self.respond(try OpenAIFixture.data("stream-text", "sse"), contentType: "text/event-stream").error?.status == 502)
    }

    /// Arguments that are not a JSON object (cut, an array, a repeated key, prose) become a `tool_use` with `{}`: the reply
    /// is still relayed (the turn sees its tool fail on the next request), whole or streamed.
    @Test func unparsableToolArgumentsSurvive() async throws {
        for arguments in [#"{\"a\":"#, "[1,2]", #"{\"a\":1,\"a\":2}"#, "not json", #"\"x\""#] {
            let whole = #"{"id":"c","model":"m","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_1","type":"function","function":{"name":"Read","arguments":"\#(arguments)"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#
            let (outcome, error, response) = try await Self.respond(Data(whole.utf8))
            #expect(error == nil && outcome?.complete == true, "\(arguments)")
            #expect(response?.text.contains(#"{"type":"tool_use","id":"call_1","name":"Read","input":{}}"#) == true, "\(response?.text ?? "")")
            #expect(response?.text.contains(#""stop_reason":"tool_use""#) == true)

            let sse = OpenAICompatibleStreamTests.sse([
                #"{"id":"c","model":"m","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"Read","arguments":"\#(arguments)"}}]}}]}"#,
                #"{"id":"c","model":"m","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}"#,
            ])
            let streamed = try await Self.respond(sse, contentType: "text/event-stream", streamed: true)
            #expect(streamed.error == nil && streamed.outcome?.complete == true, "\(arguments)")
            let text = streamed.response?.text ?? ""
            #expect(text.contains(#""partial_json":"{}""#) && text.hasSuffix("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"), "\(text)")
        }
    }

    // MARK: Through the gateway

    /// Ruling 55: a 4xx bills nothing (settled at zero), a 5xx is charged the estimate.
    @Test func errorBillingFollowsRuling55() async throws {
        let adapter = OpenAICompatibleAdapter()
        #expect([400, 401, 404, 413, 429, 499].allSatisfy(adapter.billsNothing(status:)))
        #expect(![500, 502, 503, 529, 599].contains(where: adapter.billsNothing(status:)))
        let body = #"{"model":"brahma-standard","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}"#
        let price = try #require(PriceBook.price(for: OpenAIFixture.price))
        let estimate = GatewayMeter.estimate(price, maxTokens: 16, body: Data(body.utf8))
        for (status, state, usd) in [(429, "settled", 0.0), (503, "estimated", estimate)] {
            let rig = try ModelGatewayRig([FakeUpstream.json(status, #"{"error":{"message":"no","type":"x"}}"#)], providers: [OpenAIFixture.provider()],
                                          capped: ["openai"], adapters: [OpenAICompatibleAdapter()], prices: [OpenAIFixture.price])
            try rig.vault.set(companyId: rig.companyId, name: OpenAIFixture.keyName, value: OpenAIFixture.key)
            #expect(try await rig.exchange(body, token: rig.grant(aliases: OpenAIFixture.routes)).status == status)
            let row = try #require(try rig.charges().first)
            #expect(row.state == state && abs(row.usd - usd) < 1e-12, "\(status): \(row)")
        }
    }

    /// `count_tokens` is answered by the gateway: `ceil(canonicalBytes / 4)` of the checked tree. Nothing goes upstream, the
    /// key is never needed, and the meter writes nothing (it costs nothing) — so an unpriced, uncapped model still counts.
    @Test func countTokensAnsweredLocally() async throws {
        #expect(OpenAICompatibleAdapter.countBytesPerToken == 4)
        #expect([0, 1, 4, 5, 8, 9].map { OpenAICompatibleAdapter.countEstimate(canonicalBytes: $0) } == [0, 1, 1, 2, 2, 3])
        let rig = try ModelGatewayRig([FakeUpstream.json(200, #"{"input_tokens":999}"#)], providers: [OpenAIFixture.provider()], storeKey: false,
                                      caps: nil, adapters: [AnthropicAdapter(), OpenAICompatibleAdapter()])
        let body = #"{ "model" : "brahma-standard", "messages" : [ {"role":"user","content":"count these words"} ] }"#
        let canonical = try CanonicalRequest.tree(Data(body.utf8)).serialized().count
        let response = try await rig.exchange(body, token: rig.grant(aliases: OpenAIFixture.routes), target: "/t/v1/messages/count_tokens?beta=true")
        #expect(response.status == 200 && response.text == #"{"input_tokens":\#((canonical + 3) / 4)}"#, "\(response.text)")
        #expect(rig.upstream.requests.isEmpty)
        #expect(try rig.charges().isEmpty)
        #expect(rig.logLines.contains { $0.contains("count_tokens answered locally") }, "\(rig.logLines)")
    }

    /// A streamed turn end to end: the client gets the translated events, the provider gets the translated body with the
    /// Bearer key, and the charge is settled at the final usage; a stream without its usage is charged the estimate.
    @Test func streamedTurnIsTranslatedAndSettled() async throws {
        let rig = try ModelGatewayRig([FakeUpstream.sse(try OpenAIFixture.data("stream-text", "sse")),
                                       FakeUpstream.sse(try OpenAIFixture.data("stream-no-usage", "sse"))],
                                      providers: [OpenAIFixture.provider()], capped: ["openai"], adapters: [OpenAICompatibleAdapter()],
                                      prices: [OpenAIFixture.price])
        try rig.vault.set(companyId: rig.companyId, name: OpenAIFixture.keyName, value: OpenAIFixture.key)
        let token = rig.grant(aliases: OpenAIFixture.routes)
        let body = #"{"model":"brahma-standard","max_tokens":64,"stream":true,"metadata":{"user_id":"u"},"messages":[{"role":"user","content":"hi"}]}"#
        let response = try await rig.exchange(body, token: token)
        #expect(response.status == 200 && response.head.headers["content-type"] == "text/event-stream")
        let expected = try OpenAIFixture.text("stream-text.expected", "sse")
        #expect(response.text == expected)
        let sent = try #require(rig.upstream.requests.first)
        #expect(sent.url.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(sent.headers == ["authorization": "Bearer " + OpenAIFixture.key, "content-type": "application/json"])
        #expect(String(decoding: sent.body, as: UTF8.self)
                    == #"{"model":"gpt-5.5","messages":[{"role":"user","content":"hi"}],"max_tokens":64,"stream":true,"stream_options":{"include_usage":true}}"#)
        let price = try #require(PriceBook.price(for: OpenAIFixture.price))
        let usage = GatewayUsage(inputTokens: 30, outputTokens: 3, cacheReadTokens: 20, cacheWriteTokens: 0)
        let settled = try #require(try rig.charges().first)
        #expect(settled.state == "settled" && abs(settled.usd - price.cost(usage)) < 1e-12, "\(settled)")
        #expect(settled.inputTokens == 30 && settled.outputTokens == 3 && settled.cacheReadTokens == 20)

        #expect(try await rig.exchange(body, token: token).status == 200)
        let estimated = try rig.charges()[1]
        #expect(estimated.state == "estimated" && abs(estimated.usd - GatewayMeter.estimate(price, maxTokens: 64, body: Data(body.utf8))) < 1e-12,
                "\(estimated)")
    }

    /// An upstream 401 echoing the key: the client gets a 400 with `[redacted]`, and no log line holds the key.
    @Test func upstreamErrorRedactsKey() async throws {
        let body = try OpenAIFixture.json("response-error").replacingOccurrences(of: "{{KEY}}", with: OpenAIFixture.key)
        let rig = try ModelGatewayRig([FakeUpstream.json(401, body)], providers: [OpenAIFixture.provider()], capped: ["openai"],
                                      adapters: [OpenAICompatibleAdapter()], prices: [OpenAIFixture.price])
        try rig.vault.set(companyId: rig.companyId, name: OpenAIFixture.keyName, value: OpenAIFixture.key)
        let response = try await rig.exchange(#"{"model":"brahma-standard","max_tokens":1,"messages":[]}"#, token: rig.grant(aliases: OpenAIFixture.routes))
        #expect(response.status == 400 && response.errorType == "invalid_request_error")
        #expect(!response.text.contains(OpenAIFixture.key) && response.text.contains("[redacted]"), "\(response.text)")
        #expect(rig.upstream.requests.first?.headers["authorization"] == "Bearer " + OpenAIFixture.key)
        #expect(!rig.logLines.isEmpty && rig.logLines.allSatisfy { !$0.contains(OpenAIFixture.key) }, "\(rig.logLines)")
    }

    /// Ruling 48 / 57: a provider with no key stored is unavailable as a 400 (the turn ends at once), never sent.
    @Test func missingKeyIsUnavailable() async throws {
        let rig = try ModelGatewayRig([FakeUpstream.json(200, "{}")], providers: [OpenAIFixture.provider()], capped: ["openai"],
                                      adapters: [OpenAICompatibleAdapter()], prices: [OpenAIFixture.price])
        let response = try await rig.exchange(#"{"model":"brahma-standard","max_tokens":1,"messages":[]}"#, token: rig.grant(aliases: OpenAIFixture.routes))
        #expect(response.status == 400 && response.text.contains("Brahma: unavailable: no provider key"), "\(response.text)")
        #expect(rig.upstream.requests.isEmpty)
    }

    /// The gateway serves `openai-compatible` providers by default.
    @Test func registeredByDefault() throws {
        let gateway = ModelGateway(registry: TurnTokenRegistry(clock: ManualAwakeClock()), providers: { _ in nil },
                                   upstream: FakeUpstream([FakeUpstream.json(200, "{}")]), vault: MemoryVault(),
                                   meter: GatewayMeter(store: try Store.inMemory(), prices: { PriceBook(owner: []) }, clock: { Date() }))
        #expect(gateway.adapterIds == [.anthropic, .openAICompatible])
    }
}

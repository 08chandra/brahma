import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan X1 Task 8: `ModelGateway` behind the real server — routing by the turn's grant, the policy refusals (Ruling 19's 400),
/// the key read from the vault per request, cancellation, and an upstream that fails is always an error, never an empty 200.
@Suite(.scratch, .serialized) struct ModelGatewayTests {
    static let ok = FakeUpstream.json(200, #"{"type":"message","usage":{"input_tokens":1,"output_tokens":2}}"#)

    static func body(_ model: String, tools: Bool = false, extra: String = "") -> String {
        let toolList = tools ? #","tools":[{"name":"Read","input_schema":{"type":"object"}}]"# : ""
        return #"{"model":"\#(model)","max_tokens":16,"messages":[{"role":"user","content":"hi"}]\#(toolList)\#(extra)}"#
    }

    @Test func unroutedModelRefused() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        for model in ["claude-fable-5-1", "brahma-deep", "claude-opus-5-5-20990101", "Claude-Opus-5-5"] {
            let response = try await rig.exchange(Self.body(model), token: token)
            #expect(response.status == GatewayRefusal.status && response.errorType == GatewayRefusal.type)
            #expect(response.text.contains("Brahma: model \(model) is not routed for this turn"), "\(response.text)")
        }
        // A model name that is not a plain id is not echoed.
        let odd = try await rig.exchange(Self.body("x\\\"y"), token: token)
        #expect(odd.status == 400 && odd.text.contains("Brahma: the requested model is not routed for this turn"), "\(odd.text)")
        #expect(rig.upstream.requests.isEmpty)
        #expect(rig.providerLookups == 0)
    }

    /// A pass-through model goes to the grant's provider exactly as sent; an alias goes to its routed target with only `model`
    /// replaced; a model only resembling a granted id is refused.
    @Test func passThroughOnlyForGrantedFamilies() async throws {
        let sse = try AnthropicFixture.data("stream-tools", "sse")
        let rig = try ModelGatewayRig([FakeUpstream.sse(sse), Self.ok])
        let token = rig.grant()
        let streamed = Self.body("claude-opus-5-5", extra: #","stream":true"#)
        let response = try await rig.exchange(streamed, token: token)
        #expect(response.status == 200 && Data(response.body) == sse)
        let first = try #require(rig.upstream.requests.first)
        #expect(first.body == Data(streamed.utf8))
        #expect(first.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(first.headers["x-api-key"] == AnthropicFixture.key)
        #expect(rig.logLines.contains { $0.contains("anthropic/claude-opus-5-5") && $0.contains("in=25 out=87 cacheRead=2000 cacheWrite=100") },
                "\(rig.logLines)")

        let aliased = try await rig.exchange(Self.body("brahma-standard"), token: token)
        #expect(aliased.status == 200)
        #expect(rig.upstream.requests.count == 2)
        #expect(String(decoding: rig.upstream.requests[1].body, as: UTF8.self) == Self.body("claude-sonnet-5-5"))

        // The routed model itself is not a pass-through family here: refused.
        #expect(try await rig.exchange(Self.body("claude-sonnet-5-5"), token: token).status == 400)
        #expect(rig.upstream.requests.count == 2)
    }

    @Test func toolsRefusedForTextOnlyModel() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant(textOnly: ["claude-sonnet-5-5"])
        let refused = try await rig.exchange(Self.body("brahma-standard", tools: true), token: token)
        #expect(refused.status == 400 && refused.text.contains("does not take tools"), "\(refused.text)")
        #expect(rig.upstream.requests.isEmpty)
        // An empty tool list carries no tools; the same model without tools is served.
        #expect(try await rig.exchange(Self.body("brahma-standard", extra: #","tools":[]"#), token: token).status == 200)
        #expect(try await rig.exchange(Self.body("brahma-standard"), token: token).status == 200)
        // Other models still take tools.
        #expect(try await rig.exchange(Self.body("claude-opus-5-5", tools: true), token: token).status == 200)
        #expect(rig.upstream.requests.count == 3)
    }

    /// Ruling 39: a pricing modifier the price book does not model is refused, never metered at the standard rate.
    @Test func unpricedModifiersRefused() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        let fast = try await rig.exchange(Self.body("claude-opus-5-5", extra: #","speed":"fast""#), token: token)
        #expect(fast.status == 400 && fast.text.contains("Brahma: fast mode is not priced"), "\(fast.text)")
        for extra in [#","inference_geo":"us""#, #","service_tier":"auto""#, #","fallbacks":"default""#, #","speed":7"#] {
            let r = try await rig.exchange(Self.body("claude-opus-5-5", extra: extra), token: token)
            #expect(r.status == 400 && r.text.contains("is not priced"), "\(extra): \(r.text)")
        }
        #expect(rig.upstream.requests.isEmpty)
        // The standard values are priced.
        for extra in [#","speed":"standard""#, #","inference_geo":"global""#, #","service_tier":"standard_only""#] {
            #expect(try await rig.exchange(Self.body("claude-opus-5-5", extra: extra), token: token).status == 200, "\(extra)")
        }
    }

    // MARK: Ruling X1-34: no provider-side network; only metered fields and betas

    /// The betas X1-0 recorded `claude` 2.1.325 sending, in its order.
    static let recordedBetas = "claude-code-20250219,interleaved-thinking-2025-05-14,context-management-2025-06-27,per-turn-control-2026-07-01,"
        + "mid-conversation-tool-changes-2026-07-01,thinking-token-count-2026-05-13,advanced-tool-use-2025-11-20,effort-2025-11-24,"
        + "thinking-display-updates-2026-08-18"

    static func expectForbidden(_ r: TestResponse, _ reason: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(r.status == 403 && r.errorType == "permission_error", "\(r.status) \(r.text)", sourceLocation: sourceLocation)
        #expect(r.text.contains("Brahma: ") && r.text.contains(reason), "\(r.text)", sourceLocation: sourceLocation)
    }

    /// The request `claude` really sends — client tools, thinking, context management, effort, an inline image, metadata,
    /// and the nine recorded betas — passes.
    @Test func claudesOwnRequestPasses() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let body = try AnthropicFixture.text("request-claude", "json").trimmingCharacters(in: .newlines)
        let r = try await rig.exchange(body, token: rig.grant(), extra: ["anthropic-beta: \(Self.recordedBetas)"])
        #expect(r.status == 200, "\(r.text)")
        #expect(rig.upstream.requests.first?.headers["anthropic-beta"] == Self.recordedBetas)
        #expect(GatewayPolicy.betas.count == 9)
    }

    @Test func mcpServersRefused() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let r = try await rig.exchange(Self.body("claude-opus-5-5", extra: #","mcp_servers":[{"type":"url","url":"https://x.example/mcp","name":"x"}]"#),
                                       token: rig.grant())
        Self.expectForbidden(r, "mcp_servers would let the provider reach the network")
        #expect(rig.upstream.requests.isEmpty)
    }

    /// A tool whose `type` is a server tool is refused, whatever its version; a client tool (no type, or `custom`) passes.
    @Test func serverToolTypesRefused() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        for type in ["web_fetch_20250910", "web_fetch_20260209", "web_search_20250305", "web_search_20260209", "code_execution_20260521",
                     "computer_toolset_20260801", "bash_20250124", "text_editor_20250728", "tool_search_tool_regex_20251119",
                     "mcp_toolset", "memory_20250818", "web_search_2099_01_01"] {
            let tools = #","tools":[{"name":"Read","input_schema":{"type":"object"}},{"type":"\#(type)","name":"x"}]"#
            Self.expectForbidden(try await rig.exchange(Self.body("claude-opus-5-5", extra: tools), token: token),
                                 "server tool \(type) would let the provider reach the network")
        }
        #expect(rig.upstream.requests.isEmpty)
        let custom = #","tools":[{"type":"custom","name":"Read","input_schema":{"type":"object"}},{"name":"Grep","input_schema":{"type":"object"}}]"#
        #expect(try await rig.exchange(Self.body("claude-opus-5-5", extra: custom), token: token).status == 200)
        #expect(rig.upstream.requests.count == 1)
    }

    /// Content sources are an allowlist (base64, text, content): a URL the provider would fetch, a Files-API `file` it would
    /// read from the provider organization, or an unknown type are refused wherever a source appears — a message image or
    /// document, a system block, a document nested in a tool result. Inline sources pass, and so does a tool call whose
    /// arguments merely mention a source.
    @Test func contentSourcesAllowlisted() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        for source in [#"{"type":"url","url":"https://x.example/a.png?d=secret"}"#, #"{"type":"file","file_id":"file_011CNha8iCJcU1wXNR6q4V8w"}"#,
                       #"{"type":"s3","bucket":"b"}"#, #"{"url":"https://x.example"}"#] {
            let image = #"{"type":"image","source":\#(source)}"#
            let document = #"{"type":"document","source":\#(source)}"#
            let nested = #"[{"type":"tool_result","tool_use_id":"t","content":[\#(document)]}]"#
            let content = #"{"type":"document","source":{"type":"content","content":[\#(image)]}}"#
            for blocks in ["[\(image)]", "[\(document)]", nested, "[\(content)]"] {
                let body = #"{"model":"claude-opus-5-5","max_tokens":16,"messages":[{"role":"user","content":\#(blocks)}]}"#
                Self.expectForbidden(try await rig.exchange(body, token: token), "is not allowed; send the content inline")
            }
            let system = #"{"model":"claude-opus-5-5","max_tokens":16,"system":[\#(document)],"messages":[]}"#
            Self.expectForbidden(try await rig.exchange(system, token: token), "content source")
        }
        #expect(rig.upstream.requests.isEmpty)
        let inline = #"{"model":"claude-opus-5-5","max_tokens":16,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBO"}},{"type":"document","source":{"type":"text","media_type":"text/plain","data":"hi"}},{"type":"document","source":{"type":"content","content":[{"type":"text","text":"hi"}]}}]},{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Fetch","input":{"source":{"type":"url","url":"https://x.example"}}}]}]}"#
        let ok = try await rig.exchange(inline, token: token)
        #expect(ok.status == 200, "\(ok.text)")
    }

    /// Ruling 49 m3: a server-tool type or an inline tool definition anywhere in `system` or `messages` is refused, not only
    /// in `tools`; the history blocks of a server tool already used (`server_tool_use`, `web_search_tool_result`) are not tools.
    @Test func serverToolsRefusedAnywhere() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        let blocks = [
            #"{"type":"web_fetch_20260209","name":"web_fetch"}"#, #"{"type":"code_execution_20260521","name":"code_execution"}"#,
            #"{"type":"mcp_toolset","mcp_server_name":"x"}"#, #"{"type":"tool_definition","tool":{"name":"x"}}"#,
            #"{"name":"Grep","input_schema":{"type":"object"}}"#,
        ]
        for block in blocks {
            let inMessages = #"{"model":"claude-opus-5-5","max_tokens":16,"messages":[{"role":"user","content":[{"type":"text","text":"hi"},\#(block)]}]}"#
            Self.expectForbidden(try await rig.exchange(inMessages, token: token), "not allowed")
            let inSystem = #"{"model":"claude-opus-5-5","max_tokens":16,"system":[\#(block)],"messages":[]}"#
            Self.expectForbidden(try await rig.exchange(inSystem, token: token), "not allowed")
        }
        #expect(rig.upstream.requests.isEmpty)
        let history = #"{"model":"claude-opus-5-5","max_tokens":16,"messages":[{"role":"assistant","content":[{"type":"server_tool_use","id":"s","name":"web_search","input":{"query":"q"}},{"type":"web_search_tool_result","tool_use_id":"s","content":[]}]}]}"#
        #expect(try await rig.exchange(history, token: token).status == 200)
    }

    /// Ruling X1-34 (2): an unknown top-level key or beta is refused before anything goes upstream (it may carry a pricing
    /// modifier the meter does not model); one anthropic-beta header at most.
    @Test func unknownBodyKeysAndBetasRefused() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        for extra in [#","container":"c1""#, #","context_1m":true"#, #","top_k":5"#, #","x_future":{}"#] {
            Self.expectForbidden(try await rig.exchange(Self.body("claude-opus-5-5", extra: extra), token: token), "is not allowed")
        }
        for beta in ["fast-mode-2026-02-01", "web-fetch-2025-09-10", "mcp-client-2025-11-20", "context-1m-2025-08-07",
                     "claude-code-20250219,code-execution-2025-08-25", "claude-code-20250219,", "claude-code-20250219\tx"] {
            let r = try await rig.exchange(Self.body("claude-opus-5-5"), token: token, extra: ["anthropic-beta: \(beta)"])
            Self.expectForbidden(r, "is not allowed")
        }
        let twice = try await rig.exchange(Self.body("claude-opus-5-5"), token: token,
                                           extra: ["anthropic-beta: claude-code-20250219", "anthropic-beta: effort-2025-11-24"])
        Self.expectForbidden(twice, "at most one anthropic-beta header")
        #expect(rig.upstream.requests.isEmpty)
        // The known-safe keys and a recorded beta (spaces after commas allowed) pass.
        let safe = #","thinking":{"type":"adaptive"},"output_config":{"effort":"high"},"context_management":{"edits":[]},"safeguards":{},"top_p":1,"stop_sequences":[],"tool_choice":{"type":"auto"}"#
        let ok = try await rig.exchange(Self.body("claude-opus-5-5", extra: safe), token: token,
                                        extra: ["anthropic-beta: claude-code-20250219, effort-2025-11-24"])
        #expect(ok.status == 200, "\(ok.text)")
    }

    /// A server tool the grant names is sent; once the turn is tainted it is refused like any other.
    @Test func markTaintedClearsGrantedServerTools() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant(serverTools: ["web_search_20260209"])
        let search = Self.body("claude-opus-5-5", extra: #","tools":[{"type":"web_search_20260209","name":"web_search"}]"#)
        #expect(try await rig.exchange(search, token: token).status == 200)
        let fetch = Self.body("claude-opus-5-5", extra: #","tools":[{"type":"web_fetch_20260209","name":"web_fetch"}]"#)
        Self.expectForbidden(try await rig.exchange(fetch, token: token), "server tool web_fetch_20260209")
        rig.registry.markTainted(token)
        #expect(rig.registry.admit(token.value)?.serverTools == [])
        Self.expectForbidden(try await rig.exchange(search, token: token), "server tool web_search_20260209")
        #expect(rig.upstream.requests.count == 1)
    }

    /// Ruling X1-35: a repeated key at any depth — where the policy and the provider could read different values — is refused
    /// with its path, and nothing goes upstream.
    @Test func duplicateKeysAtAnyDepthRefused() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        let cases: [(String, String)] = [
            (#"{"model":"claude-opus-5-5","max_tokens":16,"messages":[],"type":"a","type":"b"}"#, "type"),
            (#"{"model":"claude-opus-5-5","max_tokens":16,"messages":[],"tools":[{"name":"Read","input_schema":{"type":"object"},"type":"custom","type":"web_fetch_20250910"}]}"#, "tools[0].type"),
            (#"{"model":"claude-opus-5-5","max_tokens":16,"messages":[{"role":"user","content":[{"type":"text","text":"hi","type":"document"}]}]}"#, "messages[0].content[0].type"),
            (#"{"model":"claude-opus-5-5","max_tokens":16,"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBO","type":"url"}}]}]}"#, "messages[0].content[0].source.type"),
            (#"{"model":"claude-opus-5-5","max_tokens":16,"messages":[],"output_config":{"a":{"b":{"c":{"effort":"low","effort":"max"}}}}}"#, "output_config.a.b.c.effort"),
            (#"{"model":"claude-opus-5-5","max_tokens":16,"messages":[],"tools":[{"name":"Read","input_schema":{},"type":"custom","type":"web_search_20260209"}]}"#, "tools[0].type"),
            (#"{"model":"brahma-standard","max_tokens":16,"messages":[],"model":"claude-fable-5-1"}"#, "model"),
        ]
        for (body, path) in cases {
            let r = try await rig.exchange(body, token: token)
            #expect(r.status == 400 && r.errorType == "invalid_request_error", "\(path): \(r.text)")
            #expect(r.text.contains("Brahma: duplicate key \(path)"), "\(r.text)")
        }
        #expect(rig.upstream.requests.isEmpty)
    }

    /// The provider gets the checked tree re-serialized: a request with a 2^63+1 integer and a long decimal arrives equal in
    /// meaning, keys in order, numbers exact.
    @Test func upstreamGetsTheCheckedTree() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let body = #"{ "model": "claude-opus-5-5", "max_tokens": 16, "messages": [ {"role": "user", "content": "hé"} ], "metadata": {"n": 9223372036854775809, "d": 3.14159265358979323846264338327950288, "user_id": "x"} }"#
        #expect(try await rig.exchange(body, token: rig.grant()).status == 200)
        let sent = try #require(rig.upstream.requests.first)
        #expect(String(decoding: sent.body, as: UTF8.self)
                    == #"{"model":"claude-opus-5-5","max_tokens":16,"messages":[{"role":"user","content":"hé"}],"metadata":{"n":9223372036854775809,"d":3.14159265358979323846264338327950288}}"#)
    }

    @Test func malformedOrRepeatedKeysRefusedBeforeRouting() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        let twice = #"{"model":"brahma-standard","max_tokens":1,"messages":[],"model":"claude-fable-5-1"}"#
        let r = try await rig.exchange(twice, token: token)
        #expect(r.status == 400 && r.errorType == "invalid_request_error")
        #expect(try await rig.exchange("not json", token: token).status == 400)
        #expect(rig.upstream.requests.isEmpty)
    }

    /// No key in the vault: Ruling 48's 400 "Brahma: unavailable: …" naming the secret (never its value) — a 400 ends the
    /// turn at once where `claude` would retry a 503 for minutes — and nothing is sent upstream.
    @Test func missingKeyIsUnavailable() async throws {
        let rig = try ModelGatewayRig([Self.ok], storeKey: false)
        let response = try await rig.exchange(Self.body("claude-opus-5-5"), token: rig.grant())
        #expect(response.status == 400 && response.errorType == "invalid_request_error")
        #expect(response.text.contains("Brahma: unavailable: no provider key: set \(Provider.anthropicKeyName)"), "\(response.text)")
        #expect(rig.upstream.requests.isEmpty)
        // A provider without a key secret, a missing provider, a LAN provider and an unknown adapter are unavailable too.
        for provider in [AnthropicFixture.provider(keySecret: nil), AnthropicFixture.provider(lan: true),
                         AnthropicFixture.provider(adapter: "openai-compatible"), AnthropicFixture.provider(keySecret: "OPENAI_API_KEY")] {
            let rig = try ModelGatewayRig([Self.ok], providers: [provider])
            let r = try await rig.exchange(Self.body("claude-opus-5-5"), token: rig.grant())
            #expect(r.status == 400 && r.text.contains("Brahma: unavailable: "), "\(provider): \(r.text)")
            #expect(rig.upstream.requests.isEmpty)
        }
        let none = try ModelGatewayRig([Self.ok], providers: [])
        #expect(try await none.exchange(Self.body("claude-opus-5-5"), token: none.grant()).text.contains("Brahma: unavailable: provider anthropic is not configured"))
    }

    /// A transport failure, an upstream that answers with a redirect, or a broken body are errors the client sees — never an
    /// empty 200 — and a redirect is never followed.
    @Test func upstreamUnavailableIsAnError() async throws {
        for script in [FakeUpstream.Reply.fail(.unavailable("the gateway upstream is not available on this platform yet")),
                       .fail(.upstream(status: 502, message: "Brahma: the provider could not be reached")),
                       .respond(status: 302, headers: ["location": "https://evil.example/"], chunks: [], hold: false),
                       .respond(status: 200, headers: ["content-type": "application/json"], chunks: [], hold: false)] {
            let rig = try ModelGatewayRig([script])
            let response = try await rig.exchange(Self.body("claude-opus-5-5"), token: rig.grant())
            // Ruling 48: unavailable is a 400 (the turn ends at once); a failed or misbehaving provider is a 502.
            if case .fail(.unavailable) = script {
                #expect(response.status == 400 && response.text.contains("Brahma: unavailable: "), "\(response.text)")
            } else {
                #expect(response.status == 502, "\(script): \(response.status) \(response.text)")
            }
            #expect(response.errorType != nil, "\(response.text)")
            #expect(rig.upstream.requests.count == 1)
        }
    }

    /// Ruling X1-33 follow-up: a request cut before its key is read never reads the key and never connects upstream.
    @Test func cutBeforeTheKeyNeverConnects() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let registry = rig.registry
        rig.onProviderLookup { registry.revokeAll(reason: "test stop") }
        let (peer, served) = rig.connect()
        await peer.write(rawRequest(token: rig.grant().value, body: Self.body("claude-opus-5-5")))
        #expect(await peer.seesEOF())
        await served.value
        #expect(rig.providerLookups == 1)
        #expect(rig.upstream.requests.isEmpty)
    }

    /// A reply cut mid-stream (revocation) stops reading upstream: the upstream stream is cancelled, not left running.
    @Test func cutReplyStopsTheUpstreamStream() async throws {
        let firstEvent = Data("event: ping\ndata: {\"type\": \"ping\"}\n\n".utf8)
        let rig = try ModelGatewayRig([.respond(status: 200, headers: ["content-type": "text/event-stream"], chunks: [firstEvent], hold: true)])
        let (peer, served) = rig.connect()
        await peer.write(rawRequest(token: rig.grant().value, body: Self.body("claude-opus-5-5", extra: #","stream":true"#)))
        let head = try await peer.readHead()
        #expect(head.status == 200)
        #expect(try await peer.readChunk() == Array(firstEvent))
        rig.registry.revokeAll(reason: "owner stop")
        #expect(await peer.seesEOF())
        await served.value
        #expect(await eventually { rig.upstream.cancelledStreams == 1 })
    }

    /// The live transport, without the network: only `https://<one host name>` (port 443) is sent, through a proxy pinned to
    /// exactly that host; the session keeps no cookies or cache.
    @Test func egressTransportPinsOneHost() async throws {
        let transport = EgressUpstreamTransport()
        defer { transport.stop() }
        for url in ["http://api.anthropic.com/v1/messages", "https://127.0.0.1/v1/messages", "https://api.anthropic.com:8443/v1/messages",
                    "https://user:pw@api.anthropic.com/v1/messages", "https://localhost/v1/messages"] {
            let request = UpstreamRequest(url: URL(string: url)!, method: "POST", headers: [:], body: Data())
            await #expect(throws: GatewayError.self, "\(url)") { try await transport.send(request) }
        }
        #if canImport(Darwin)
        let proxy = try transport.proxy(for: "api.anthropic.com")
        #expect(proxy.allow == ["api.anthropic.com"])
        #expect(try transport.proxy(for: "api.anthropic.com") === proxy)
        let session = EgressUpstreamTransport.configuration(proxyPort: proxy.port)
        #expect(session.httpCookieStorage == nil && session.urlCache == nil && session.httpShouldSetCookies == false)
        #expect(session.connectionProxyDictionary?[kCFNetworkProxiesHTTPSPort as String] as? Int == Int(proxy.port))
        #expect(session.connectionProxyDictionary?[kCFNetworkProxiesHTTPSProxy as String] as? String == "127.0.0.1")
        #endif
    }

    // MARK: Task 9: metering through the gateway

    /// The reservation is in the database before the request reaches the transport, and is settled with the usage after.
    @Test func reservesBeforeSendingAndSettlesAfter() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let store = rig.store
        let atSend = GatewayMeterTests.Locked<[String]>([])
        rig.upstream.onSend { atSend.with { $0 = ((try? ModelGatewayRig.charges(store)) ?? []).map(\.state) } }
        #expect(try await rig.exchange(Self.body("claude-opus-5-5"), token: rig.grant()).status == 200)
        #expect(atSend.with { $0 } == ["reserved"])
        let row = try #require(try rig.charges().first)
        #expect(row.state == "settled" && !row.estimated && row.inputTokens == 1 && row.outputTokens == 2)
        #expect(row.provider == "anthropic" && row.model == "claude-opus-5-5")
        #expect(abs(row.usd - (1 * 4 + 2 * 20) / 1e6) < 1e-12)
        // An alias is charged as its routed target.
        #expect(try await rig.exchange(Self.body("brahma-standard"), token: rig.grant()).status == 200)
        #expect(try rig.charges().last?.model == "claude-sonnet-5-5")
    }

    /// Ruling 23: a request refused before it leaves the gateway is never charged — by policy, routing, a missing
    /// `max_tokens`, a missing key (after the reservation: released), or a transport that refused before sending.
    @Test func refusedRequestsAreNeverCharged() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        #expect(try await rig.exchange(Self.body("claude-fable-5-1"), token: token).status == 400)
        #expect(try await rig.exchange(Self.body("claude-opus-5-5", extra: #","mcp_servers":[]"#), token: token).status == 403)
        let noMax = try await rig.exchange(#"{"model":"claude-opus-5-5","messages":[]}"#, token: token)
        #expect(noMax.status == 400 && noMax.text.contains("Brahma: max_tokens is required"), "\(noMax.text)")
        #expect(try rig.charges().isEmpty)
        let keyless = try ModelGatewayRig([Self.ok], storeKey: false)
        #expect(try await keyless.exchange(Self.body("claude-opus-5-5"), token: keyless.grant()).status == 400)
        #expect(try keyless.charges().isEmpty)
        let refusing = try ModelGatewayRig([.fail(.unavailable("the request was cancelled"))])
        #expect(try await refusing.exchange(Self.body("claude-opus-5-5"), token: refusing.grant()).status == 400)
        let refusedCharges = try refusing.charges()
        #expect(refusing.upstream.requests.count == 1 && refusedCharges.isEmpty)
    }

    /// Once the transport has the request: a failure that may have reached the provider is charged the estimate; an error
    /// answer (which the provider does not bill) and `count_tokens` (free) are settled at zero.
    @Test func sentRequestsAreSettled() async throws {
        let body = Self.body("claude-opus-5-5")
        let estimate = GatewayMeter.estimate(PriceBook.pinned["anthropic/claude-opus-5-5"]!, maxTokens: 16, body: Data(body.utf8))
        for (script, state, usd) in [(FakeUpstream.Reply.fail(.upstream(status: 502, message: "Brahma: the provider could not be reached")), "estimated", estimate),
                                     (.respond(status: 302, headers: [:], chunks: [], hold: false), "estimated", estimate),
                                     (FakeUpstream.json(529, #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#), "settled", 0),
                                     (FakeUpstream.json(400, #"{"type":"error","error":{"type":"invalid_request_error","message":"no"}}"#), "settled", 0)] {
            let rig = try ModelGatewayRig([script])
            #expect(try await rig.exchange(body, token: rig.grant()).status >= 400)
            let row = try #require(try rig.charges().first, "\(script)")
            #expect(row.state == state && abs(row.usd - usd) < 1e-12, "\(script): \(row)")
        }
        let count = try ModelGatewayRig([FakeUpstream.json(200, #"{"input_tokens":12}"#)])
        let counted = try await count.exchange(#"{"model":"claude-opus-5-5","messages":[{"role":"user","content":"hi"}]}"#, token: count.grant(),
                                               target: "/t/v1/messages/count_tokens?beta=true")
        #expect(counted.status == 200)
        let row = try #require(try count.charges().first)
        #expect(row.state == "settled" && row.usd == 0)
    }

    /// Ruling 55: the adapter decides whether its provider bills an error answer. An adapter that (like Task 10's
    /// openai-compatible one) bills nothing on 4xx but may bill a 5xx: a 400 is settled at zero, a 503 charged the estimate.
    /// Anthropic bills no error: its 503 is zero.
    @Test func adapterDecidesWhetherAnErrorIsBilled() async throws {
        let body = Self.body("claude-opus-5-5")
        let estimate = GatewayMeter.estimate(PriceBook.pinned["anthropic/claude-opus-5-5"]!, maxTokens: 16, body: Data(body.utf8))
        let answers = [(400, "invalid_request_error"), (503, "api_error")]
        for (status, type) in answers {
            let reply = FakeUpstream.json(status, #"{"type":"error","error":{"type":"\#(type)","message":"no"}}"#)
            let adapters: [(any ProviderAdapter, Bool)] = [(BillsServerErrors(), status >= 500), (AnthropicAdapter(), false)]
            for (adapter, billed) in adapters {
                let rig = try ModelGatewayRig([reply], adapters: [adapter])
                #expect(try await rig.exchange(body, token: rig.grant()).status == status)
                let row = try #require(try rig.charges().first)
                if billed {
                    #expect(row.state == "estimated" && abs(row.usd - estimate) < 1e-12, "\(adapter.version) \(status): \(row)")
                } else {
                    #expect(row.state == "settled" && row.usd == 0, "\(adapter.version) \(status): \(row)")
                }
            }
        }
        #expect(AnthropicAdapter().billsNothing(status: 400) && AnthropicAdapter().billsNothing(status: 529))
    }

    /// The anthropic adapter, except that it reports 5xx answers as possibly billed (the openai-compatible rule, Ruling 55).
    struct BillsServerErrors: ProviderAdapter {
        let base = AnthropicAdapter()
        var id: AdapterId { base.id }
        let version = "bills-5xx"
        func upstream(_ r: CanonicalRequest, body: StrictJSON, model: String, endpoint: GatewayEndpoint, headers: [GatewayHeader],
                      provider: Provider, key: String) throws(GatewayError) -> UpstreamRequest {
            try base.upstream(r, body: body, model: model, endpoint: endpoint, headers: headers, provider: provider, key: key)
        }
        func translate(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>, streamed: Bool,
                       into reply: GatewayReply, redact: @Sendable (String) -> String) async throws(GatewayError) -> UsageOutcome {
            try await base.translate(status: status, headers: headers, body: body, streamed: streamed, into: reply, redact: redact)
        }
        func billsNothing(status: Int) -> Bool { status < 500 }
        func countTokensLocally(_ body: StrictJSON) -> Int? { nil }
    }

    /// Ruling 52(f): at most `GatewayLimits.maxUpstreamRequests` requests upstream at once; past it a 429 rate_limit_error
    /// (transient: `claude` backs off and retries), never charged. A slot frees when its request ends.
    @Test func gatewayBusyPastTheUpstreamLimit() async throws {
        #expect(GatewayLimits.maxUpstreamRequests == 32)
        let feeds = [UpstreamFeed(), UpstreamFeed()]
        let rig = try ModelGatewayRig(feeds.map { .feed(status: 200, headers: ["content-type": "text/event-stream"], $0) } + [Self.ok], maxUpstream: 2)
        let token = rig.grant()
        let streamed = Self.body("claude-opus-5-5", extra: #","stream":true"#)
        var open: [(TestPeer, Task<Void, Never>)] = []
        for _ in feeds {
            let (peer, served) = rig.connect()
            await peer.write(rawRequest(token: token.value, body: streamed))
            open.append((peer, served))
        }
        #expect(await eventually { rig.upstream.requests.count == 2 })
        let busy = try await rig.exchange(Self.body("claude-opus-5-5"), token: token)
        #expect(busy.status == 429 && busy.errorType == "rate_limit_error" && busy.text.contains("Brahma: gateway busy"), "\(busy.text)")
        let held = try rig.charges()
        #expect(rig.upstream.requests.count == 2 && held.count == 2)
        // Which connection got which feed is a race: finish both normally, then the slots are free again.
        for feed in feeds {
            feed.send("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n")
            feed.send("event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n")
            feed.send("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
            feed.finish()
        }
        // Each client reads its whole stream before closing (closing early would end the stream early: charged the estimate).
        for (peer, served) in open {
            #expect(try await peer.readResponse().status == 200)
            peer.close()
            await served.value
        }
        #expect(try rig.charges().map(\.state) == ["settled", "settled"])
        #expect(try await rig.exchange(Self.body("claude-opus-5-5"), token: token).status == 200)
    }

    /// Ruling 52(c): mid-conversation tool changes by reference and a tool search result's references pass the policy.
    @Test func toolReferencesPass() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let body = #"{"model":"claude-opus-5-5","max_tokens":16,"tools":[{"name":"get_forecast","input_schema":{"type":"object"},"defer_loading":true}],"messages":[{"role":"user","content":"hi"},{"role":"system","content":[{"type":"tool_addition","tool":{"type":"tool_reference","name":"get_forecast"}},{"type":"tool_removal","tool":{"type":"tool_reference","name":"get_weather"}}]},{"role":"assistant","content":[{"type":"tool_use","id":"t","name":"Search","input":{"q":"weather"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":[{"type":"tool_reference","tool_name":"get_forecast"}]}]}]}"#
        let r = try await rig.exchange(body, token: rig.grant(), extra: ["anthropic-beta: mid-conversation-tool-changes-2026-07-01"])
        #expect(r.status == 200, "\(r.text)")
    }

    /// Ruling 52(d): a content `source` that is neither an object nor a string is refused with 403.
    @Test func sourceOfAnotherShapeRefused() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        for source in ["[]", "7", "true", "null", #"[{"type":"url","url":"https://x.example"}]"#] {
            let body = #"{"model":"claude-opus-5-5","max_tokens":16,"messages":[{"role":"user","content":[{"type":"image","source":\#(source)}]}]}"#
            Self.expectForbidden(try await rig.exchange(body, token: token), "a content source must be an object")
        }
        #expect(rig.upstream.requests.isEmpty)
    }

    /// Ruling 52(b): the parse cap is 500 000 values and keys.
    @Test func strictJSONStepCap() {
        #expect(StrictJSON.maxSteps == 500_000)
    }

    @Test func startsAndStopsOnLoopback() throws {
        let rig = try ModelGatewayRig([Self.ok])
        // A reservation a dead gateway left open: `start` charges it at its estimate before it serves.
        _ = try rig.meter.reserve(try #require(rig.registry.admit(rig.grant().value)), model: "claude-opus-5-5", maxTokens: 10,
                                  body: Data("{}".utf8))
        let port = try rig.gateway.start()
        #expect(try rig.charges().map(\.state) == ["estimated"])
        #expect(port > 0)
        #expect(try rig.gateway.start() == port)
        rig.gateway.stop()
        rig.gateway.stop()
    }
}

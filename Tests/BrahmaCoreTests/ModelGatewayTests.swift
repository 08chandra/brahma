import Testing
import Foundation
@testable import BrahmaCore

/// Plan X1 Task 8: `ModelGateway` behind the real server — routing by the turn's grant, the policy refusals (Ruling 19's 400),
/// the key read from the vault per request, cancellation, and an upstream that fails is always an error, never an empty 200.
@Suite(.scratch) struct ModelGatewayTests {
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

    @Test func malformedOrRepeatedKeysRefusedBeforeRouting() async throws {
        let rig = try ModelGatewayRig([Self.ok])
        let token = rig.grant()
        let twice = #"{"model":"brahma-standard","max_tokens":1,"messages":[],"model":"claude-fable-5-1"}"#
        let r = try await rig.exchange(twice, token: token)
        #expect(r.status == 400 && r.errorType == "invalid_request_error")
        #expect(try await rig.exchange("not json", token: token).status == 400)
        #expect(rig.upstream.requests.isEmpty)
    }

    /// No key in the vault: a 503 naming the secret (never its value), and nothing is sent upstream.
    @Test func missingKeyIsUnavailable() async throws {
        let rig = try ModelGatewayRig([Self.ok], storeKey: false)
        let response = try await rig.exchange(Self.body("claude-opus-5-5"), token: rig.grant())
        #expect(response.status == 503)
        #expect(response.text.contains(Provider.anthropicKeyName), "\(response.text)")
        #expect(rig.upstream.requests.isEmpty)
        // A provider without a key secret, a missing provider, a LAN provider and an unknown adapter are unavailable too.
        for provider in [AnthropicFixture.provider(keySecret: nil), AnthropicFixture.provider(lan: true),
                         AnthropicFixture.provider(adapter: "openai-compatible"), AnthropicFixture.provider(keySecret: "OPENAI_API_KEY")] {
            let rig = try ModelGatewayRig([Self.ok], providers: [provider])
            let r = try await rig.exchange(Self.body("claude-opus-5-5"), token: rig.grant())
            #expect(r.status == 503, "\(provider): \(r.text)")
            #expect(rig.upstream.requests.isEmpty)
        }
        let none = try ModelGatewayRig([Self.ok], providers: [])
        #expect(try await none.exchange(Self.body("claude-opus-5-5"), token: none.grant()).status == 503)
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
            #expect(response.status >= 500, "\(script): \(response.status) \(response.text)")
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
        #expect(await peer.seesEOF(within: 10))
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
        #expect(await peer.seesEOF(within: 10))
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

    @Test func startsAndStopsOnLoopback() throws {
        let rig = try ModelGatewayRig([Self.ok])
        let port = try rig.gateway.start()
        #expect(port > 0)
        #expect(try rig.gateway.start() == port)
        rig.gateway.stop()
        rig.gateway.stop()
    }
}

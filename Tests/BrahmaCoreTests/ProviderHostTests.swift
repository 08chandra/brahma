import Testing
import Foundation
@testable import BrahmaCore

/// Plan X1 Task 11: a provider record's base URL pins exactly one https host (`ProviderHost.validate`): https, a host name
/// (never an IP literal or `localhost`), no user info, no query or fragment, port 443 or none; LAN providers wait for X1b.
/// The gateway never follows a redirect away from the pinned host.
@Suite(.scratch, .serialized) struct ProviderHostTests {
    static func validate(_ url: String, adapter: AdapterId = .openAICompatible, lan: Bool = false) -> Result<String, ProviderHost.Refusal> {
        guard let parsed = URL(string: url) else { return .failure(ProviderHost.Refusal("unparsable test URL \(url)")) }
        return ProviderHost.validate(baseURL: parsed, adapter: adapter, lan: lan)
    }

    static func refusal(_ url: String, adapter: AdapterId = .openAICompatible, lan: Bool = false) -> String? {
        switch validate(url, adapter: adapter, lan: lan) {
        case .success: nil
        case .failure(let refusal): refusal.reason
        }
    }

    @Test func httpsHostRequired() {
        #expect(Self.validate("https://api.example.com/v1") == .success("api.example.com"))
        #expect(Self.validate("https://openrouter.ai/api/v1") == .success("openrouter.ai"))
        #expect(Self.validate("https://api.anthropic.com", adapter: .anthropic) == .success("api.anthropic.com"))
        #expect(Self.validate("https://api.example.com:443/v1") == .success("api.example.com"))
        #expect(Self.validate("https://API.Example.com/v1") == .success("api.example.com"), "the pinned host is lower-cased")
        for url in ["http://api.example.com/v1", "ftp://api.example.com", "wss://api.example.com", "HTTPS://api.example.com"] {
            #expect(Self.refusal(url) == "a provider's base URL must be https", "\(url)")
        }
        #expect(Self.refusal("https://api.example.com:8443/v1") == "a provider's base URL must use port 443 (or none)")
        #expect(Self.refusal("https://api.example.com:80/v1") == "a provider's base URL must use port 443 (or none)")
        for url in ["https://api.example.com/v1?key=x", "https://api.example.com/v1?", "https://api.example.com/v1#frag"] {
            #expect(Self.refusal(url) == "a provider's base URL must not hold a query or a fragment", "\(url)")
        }
        let notAName = "a provider's base URL must name its host, never an IP address or localhost"
        for url in ["https://localhost/v1", "https://api.localhost/v1", "https://intranet/v1", "https://api.example.com./v1",
                    "https://-bad.example.com", "https://api_x.example.com"] {
            #expect(Self.refusal(url) == notAName, "\(url)")
        }
        // Every X1 adapter reaches a remote provider; any other adapter is refused until it has its own rules.
        #expect(Self.refusal("https://api.example.com/v1", adapter: AdapterId(rawValue: "local"))
                == "no adapter local: X1 has anthropic and openai-compatible")
        #expect(ProviderHost.remoteAdapters == [.anthropic, .openAICompatible])
        // The built-in providers all pass.
        for (url, host) in [("https://api.anthropic.com", "api.anthropic.com"), ("https://api.openai.com/v1", "api.openai.com"),
                            ("https://openrouter.ai/api/v1", "openrouter.ai"), ("https://api.groq.com/openai/v1", "api.groq.com")] {
            #expect(Self.validate(url) == .success(host), "\(url)")
        }
    }

    @Test func ipLiteralRefused() {
        let notAName = "a provider's base URL must name its host, never an IP address or localhost"
        for url in ["https://127.0.0.1/v1", "https://1.2.3.4", "https://10.0.0.1:443/v1", "https://[::1]/v1", "https://[2001:db8::1]/v1",
                    "https://[::ffff:127.0.0.1]/v1", "https://127.1/v1", "https://0x7f.1/v1", "https://2130706433/v1",
                    "https://169.254.169.254/latest"] {
            #expect(Self.refusal(url) == notAName, "\(url)")
        }
    }

    @Test func userInfoRefused() {
        for url in ["https://user@api.example.com/v1", "https://user:pw@api.example.com/v1", "https://:pw@api.example.com/v1",
                    "https://api.example.com@evil.example.com/v1"] {
            #expect(Self.refusal(url) == "a provider's base URL must not hold a user name or password", "\(url)")
        }
    }

    /// LAN providers arrive with local servers in X1b: refused whatever the URL.
    @Test func lanRefusedInX1() {
        #expect(Self.refusal("https://api.example.com/v1", lan: true) == "LAN providers arrive with local servers in X1b")
        #expect(Self.refusal("http://192.168.1.10:8080/v1", lan: true) == "LAN providers arrive with local servers in X1b")
        #expect(ProviderHost.lanRefusal == "LAN providers arrive with local servers in X1b")
    }

    /// One key-name rule (Ruling 60): `ProviderHost.isProviderKeyName` is `Provider.isKeyName`, `ANTHROPIC_API_KEY` or
    /// `^BRAHMA_KEY_[A-Z0-9_]{1,40}$`.
    @Test func providerKeyNames() {
        let forty = "BRAHMA_KEY_" + String(repeating: "A", count: 40)
        for name in ["ANTHROPIC_API_KEY", "BRAHMA_KEY_OPENROUTER", "BRAHMA_KEY_OPEN_ROUTER2", "BRAHMA_KEY_X", forty] {
            #expect(ProviderHost.isProviderKeyName(name) && Provider.isKeyName(name), "\(name)")
        }
        for name in ["OPENROUTER_API_KEY", "BRAHMA_KEY_", "BRAHMA_KEY_lower", "BRAHMA_KEY_A-B", forty + "A", "ANTHROPIC_AUTH_TOKEN",
                     "BRAHMA_KEYS", "BRAHMA_DEV", "anthropic_api_key", " BRAHMA_KEY_X", "BRAHMA_KEY_X\n", "BRAHMA_KEY_Ä"] {
            #expect(!ProviderHost.isProviderKeyName(name) && !Provider.isKeyName(name), "\(name)")
        }
    }

    /// A provider that answers with a redirect is refused: the transport never follows it (Task 8), the gateway answers an
    /// upstream error (502), and no second request is ever made.
    @Test func redirectingBaseURLRefused() async throws {
        for status in [301, 302, 307, 308] {
            let redirect = FakeUpstream.Reply.respond(status: status, headers: ["location": "https://evil.example.com/v1/messages"],
                                                      chunks: [], hold: false)
            let rig = try ModelGatewayRig([redirect, ModelGatewayTests.ok])
            let response = try await rig.exchange(ModelGatewayTests.body("claude-opus-5-5"), token: rig.grant())
            #expect(response.status == 502 && response.errorType == "api_error", "\(status): \(response.status) \(response.text)")
            #expect(response.text.contains("redirects are refused"), "\(response.text)")
            #expect(rig.upstream.requests.count == 1, "\(status): no second request")
            #expect(rig.upstream.requests.allSatisfy { $0.url.host == "api.anthropic.com" })
        }
    }
}

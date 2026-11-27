import Testing
import Foundation
@testable import BrahmaCore

// Plan X1 Task 4 (spec §8.2.2): a turn never inherits Claude auth from the engine's environment; the gateway's variables reach a
// child only through `make(gateway:)` (Ruling 32), and its turn token must be well formed.

/// A value in Anthropic's key format, assembled at runtime so no source line holds such a literal (Ruling 8).
private let ownerKey = ["sk", "ant", "real"].joined(separator: "-")
/// A well-formed turn token: 64 lowercase hex characters.
private let turnToken = String(repeating: "0123456789abcdef", count: 4)

@Suite(.scratch) struct ChildEnvironmentTests {
    /// The owner's shell carries both auth variables and a base URL: no purpose passes any of them on.
    @Test func ambientAuthNeverPassed() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/h", "ANTHROPIC_API_KEY": ownerKey, "CLAUDE_CODE_OAUTH_TOKEN": "owner-oauth",
                    "ANTHROPIC_BASE_URL": "https://x"]
        for purpose in [ChildEnvironment.Purpose.claude, .general, .check] {
            let env = ChildEnvironment.make(base: base, extra: ["BRAHMA_AGENT_ID": "a1"], purpose: purpose)
            for name in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL"] {
                #expect(env[name] == nil, "\(purpose): \(name) passed")
            }
            #expect(!env.keys.contains { $0.hasPrefix("ANTHROPIC_") }, "\(purpose): \(env.keys.sorted())")
            #expect(env["PATH"] == "/usr/bin:/bin"); #expect(env["HOME"] == "/h")
        }
    }

    /// The gateway's names are dropped from `extra` and `engineClaudeVars` (and from `base`); through `gateway:` they pass.
    @Test func gatewayVarsOnlyFromGatewayParameter() {
        var gateway = Dictionary(uniqueKeysWithValues: ChildEnvironment.gatewayVariables.map { ($0, "v-\($0)") })
        gateway["ANTHROPIC_API_KEY"] = turnToken
        gateway["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:4100/t/"
        #expect(ChildEnvironment.gatewayVariables == ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_DEFAULT_OPUS_MODEL",
                                                      "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
                                                      "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
        let smuggled = ChildEnvironment.make(base: gateway.merging(["PATH": "/bin"]) { $1 }, extra: gateway,
                                             engineClaudeVars: gateway, purpose: .claude)
        for name in ChildEnvironment.gatewayVariables { #expect(smuggled[name] == nil, "\(name) passed without gateway:") }
        #expect(smuggled["PATH"] == "/bin")

        let env = ChildEnvironment.make(base: ["PATH": "/bin"], purpose: .claude, gateway: gateway)
        for name in ChildEnvironment.gatewayVariables { #expect(env[name] == gateway[name], "\(name) missing") }
        #expect(env["PATH"] == "/bin")
    }

    /// A token that is not a turn token (here, a value in a real key format) is dropped, and with it the base URL and the model
    /// names, so the child can never send the owner's login to the gateway; the deny proxy and the isolated config dir still
    /// apply (Ruling 32).
    @Test func malformedTurnTokenDropped() {
        let env = ChildEnvironment.make(base: ["PATH": "/bin"], purpose: .claude, gateway: ["ANTHROPIC_API_KEY": ownerKey])
        #expect(env["ANTHROPIC_API_KEY"] == nil)

        let gateway = ["ANTHROPIC_API_KEY": ownerKey, "ANTHROPIC_BASE_URL": "http://127.0.0.1:4100/t/",
                       "ANTHROPIC_DEFAULT_OPUS_MODEL": "brahma-deep", "ANTHROPIC_DEFAULT_SONNET_MODEL": "brahma-standard",
                       "ANTHROPIC_DEFAULT_HAIKU_MODEL": "brahma-fast", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                       "HTTPS_PROXY": "http://127.0.0.1:4200", "NO_PROXY": "127.0.0.1,localhost", "CLAUDE_CONFIG_DIR": "/agent/cc"]
        let base = ["PATH": "/bin", "HTTPS_PROXY": "http://owner:3128", "CLAUDE_CONFIG_DIR": "/owner/.claude"]
        let tokens: [String?] = [nil, ownerKey, String(turnToken.dropLast()), turnToken.uppercased(), String(turnToken.dropLast()) + "g",
                                 turnToken + "0", ""]
        for token in tokens {
            var g = gateway
            g["ANTHROPIC_API_KEY"] = token
            let env = ChildEnvironment.make(base: base, purpose: .claude, gateway: g)
            for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                         "ANTHROPIC_DEFAULT_HAIKU_MODEL"] {
                #expect(env[name] == nil, "token \(token ?? "nil"): \(name) passed")
            }
            #expect(env["HTTPS_PROXY"] == "http://127.0.0.1:4200"); #expect(env["NO_PROXY"] == "127.0.0.1,localhost")
            #expect(env["CLAUDE_CONFIG_DIR"] == "/agent/cc"); #expect(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        }
    }

    /// Ruling 32, spelled out: a base URL with the deny proxy and the agent's config dir, the token absent or malformed. Neither
    /// the base URL nor a model alias reaches the child; every proxy name and the config dir take the gateway's value over the
    /// owner's.
    @Test func baseURLWithoutAWellFormedTokenKeepsOnlyTheDenyProxyAndConfigDir() {
        let proxies = ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"]
        var base = ["PATH": "/bin", "NO_PROXY": "*.corp", "no_proxy": "*.corp", "CLAUDE_CONFIG_DIR": "/owner/.claude"]
        var gateway = ["ANTHROPIC_BASE_URL": "http://127.0.0.1:4100/t/", "ANTHROPIC_DEFAULT_OPUS_MODEL": "brahma-deep",
                       "ANTHROPIC_DEFAULT_SONNET_MODEL": "brahma-standard", "ANTHROPIC_DEFAULT_HAIKU_MODEL": "brahma-fast",
                       "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost", "CLAUDE_CONFIG_DIR": "/agent/cc"]
        for name in proxies { base[name] = "http://owner:3128"; gateway[name] = "http://127.0.0.1:4200" }
        for token in [nil, ownerKey] as [String?] {
            var g = gateway
            g["ANTHROPIC_API_KEY"] = token
            let env = ChildEnvironment.make(base: base, purpose: .claude, gateway: g)
            #expect(env["ANTHROPIC_BASE_URL"] == nil, "token \(token ?? "absent")")
            #expect(env["ANTHROPIC_API_KEY"] == nil, "token \(token ?? "absent")")
            #expect(!env.keys.contains { $0.hasPrefix("ANTHROPIC_DEFAULT_") }, "token \(token ?? "absent"): \(env.keys.sorted())")
            for name in proxies { #expect(env[name] == "http://127.0.0.1:4200", "\(name) not the deny proxy") }
            #expect(env["NO_PROXY"] == "127.0.0.1,localhost"); #expect(env["no_proxy"] == "127.0.0.1,localhost")
            #expect(env["CLAUDE_CONFIG_DIR"] == "/agent/cc"); #expect(env["PATH"] == "/bin")
        }
    }

    /// The deny proxy and the per-agent config dir override the owner's values; any other name in `gateway:` is dropped.
    @Test func gatewayOverridesBaseAndAdmitsNothingElse() {
        let base = ["PATH": "/bin", "HTTPS_PROXY": "http://owner:3128", "HTTP_PROXY": "http://owner:3128", "https_proxy": "http://owner:3128",
                    "http_proxy": "http://owner:3128", "NO_PROXY": "*.corp", "no_proxy": "*.corp", "CLAUDE_CONFIG_DIR": "/owner/.claude"]
        let overrides = ["HTTPS_PROXY": "http://127.0.0.1:4200", "HTTP_PROXY": "http://127.0.0.1:4200", "https_proxy": "http://127.0.0.1:4200",
                         "http_proxy": "http://127.0.0.1:4200", "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
                         "CLAUDE_CONFIG_DIR": "/agent/cc"]
        var gateway = overrides
        gateway["ANTHROPIC_API_KEY"] = turnToken
        gateway["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:4100/t/"
        for stray in ["PATH", "HOME", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_SUBAGENT_MODEL", "BRAHMA_AGENT_ID",
                      "NODE_OPTIONS", "SSL_CERT_FILE"] {
            gateway[stray] = "stray"
        }
        let env = ChildEnvironment.make(base: base, purpose: .claude, gateway: gateway)
        for (name, value) in overrides { #expect(env[name] == value, "\(name) not overridden") }
        #expect(env["ANTHROPIC_API_KEY"] == turnToken); #expect(env["PATH"] == "/bin")
        for stray in ["HOME", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_SUBAGENT_MODEL", "BRAHMA_AGENT_ID",
                      "NODE_OPTIONS", "SSL_CERT_FILE"] {
            #expect(env[stray] == nil, "\(stray) admitted from gateway:")
        }
        // A test key can never take a gateway name after the fact.
        let secrets = ChildEnvironment.make(base: base, purpose: .claude, secrets: ["ANTHROPIC_API_KEY": "x"], gateway: gateway)
        #expect(secrets["ANTHROPIC_API_KEY"] == turnToken)
        // Only a turn takes the gateway: a check or a general child never does.
        for purpose in [ChildEnvironment.Purpose.general, .check] {
            let other = ChildEnvironment.make(base: base, purpose: purpose, gateway: gateway)
            #expect(other["ANTHROPIC_API_KEY"] == nil); #expect(other["HTTPS_PROXY"] == "http://owner:3128")
            #expect(other["CLAUDE_CONFIG_DIR"] == "/owner/.claude")
        }
    }

    /// Ruling 33 (Plan X1 Task 12): a partial gateway fill never leaves one of the owner's override names behind (Node reads
    /// the lower-case proxy names first), and a well-formed token without a base URL is dropped with the other token-bound
    /// names (it would go to the default endpoint).
    @Test func partialGatewayKeepsNoOwnerOverride() {
        var base = ["PATH": "/bin", "CLAUDE_CONFIG_DIR": "/owner/.claude"]
        for name in ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"] { base[name] = "http://owner:3128" }
        base["NO_PROXY"] = "*"; base["no_proxy"] = "*"
        let partial = ["ANTHROPIC_API_KEY": turnToken, "ANTHROPIC_BASE_URL": "http://127.0.0.1:4100/t/", "HTTPS_PROXY": "http://127.0.0.1:4200"]
        let env = ChildEnvironment.make(base: base, purpose: .claude, gateway: partial)
        #expect(env["HTTPS_PROXY"] == "http://127.0.0.1:4200")
        for name in ChildEnvironment.gatewayOverrides where name != "HTTPS_PROXY" { #expect(env[name] == nil, "\(name) kept the owner's value") }
        #expect(env["ANTHROPIC_API_KEY"] == turnToken); #expect(env["PATH"] == "/bin")
        // No gateway at all: the owner's values pass as before (a subscription turn is unchanged).
        let plain = ChildEnvironment.make(base: base, purpose: .claude)
        for name in ChildEnvironment.gatewayOverrides { #expect(plain[name] == base[name], "\(name)") }
    }

    @Test func wellFormedTokenWithoutBaseURLDropped() {
        let gateway = ["ANTHROPIC_API_KEY": turnToken, "ANTHROPIC_DEFAULT_OPUS_MODEL": "brahma-deep", "HTTPS_PROXY": "http://127.0.0.1:4200",
                       "CLAUDE_CONFIG_DIR": "/agent/cc", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]
        for g in [gateway, gateway.merging(["ANTHROPIC_BASE_URL": ""]) { $1 }] {
            let env = ChildEnvironment.make(base: ["PATH": "/bin"], purpose: .claude, gateway: g)
            #expect(env["ANTHROPIC_API_KEY"] == nil); #expect(env["ANTHROPIC_DEFAULT_OPUS_MODEL"] == nil)
            #expect(env["ANTHROPIC_BASE_URL"] == nil)
            #expect(env["HTTPS_PROXY"] == "http://127.0.0.1:4200"); #expect(env["CLAUDE_CONFIG_DIR"] == "/agent/cc")
            #expect(env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
        }
    }

    @Test func turnTokenFormat() {
        #expect(TurnTokenFormat.isWellFormed(turnToken))
        #expect(TurnTokenFormat.isWellFormed(String(repeating: "f", count: 64)))
        for bad in ["", String(turnToken.dropLast()), turnToken + "a", turnToken.uppercased(), String(turnToken.dropLast()) + "g",
                    String(turnToken.dropLast()) + " ", ownerKey, String(repeating: "٣", count: 64)] {
            #expect(!TurnTokenFormat.isWellFormed(bad), "\(bad)")
        }
    }

    /// Every auth and gateway name stays reserved: no secret may take one.
    @Test func gatewayNamesStayReserved() {
        for name in ChildEnvironment.gatewayVariables.union(["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CONFIG_DIR"]) {
            #expect(ChildEnvironment.isReserved(name), "\(name)")
            #expect(!SecretName.isInjectable(name), "\(name)")
        }
    }

    /// Plan X1 Task 11: provider keys may be stored engine-held, but the injection path can never hand one to a child. A
    /// secrets map holding them (a row written by other means) is dropped and reported for every purpose, with or without a
    /// gateway; a gateway turn keeps its turn token, never the provider key.
    @Test func providerKeysNeverInjected() {
        let providerKey = ["sk", "ant", "provider"].joined(separator: "-")
        let names = ["ANTHROPIC_API_KEY", "BRAHMA_KEY_OPENROUTER", "BRAHMA_KEY_" + String(repeating: "A", count: 40)]
        let secrets = Dictionary(uniqueKeysWithValues: names.map { ($0, providerKey) }).merging(["STRIPE_TEST_KEY": "test-v"]) { $1 }
        for name in names {
            #expect(Provider.isKeyName(name), "\(name)")
            #expect(!SecretName.isInjectable(name), "\(name)")
        }
        #expect(ChildEnvironment.droppedSecretNames(secrets) == names.sorted())
        let gateway = ["ANTHROPIC_BASE_URL": "http://127.0.0.1:4100/t/", "ANTHROPIC_API_KEY": turnToken]
        for purpose in [ChildEnvironment.Purpose.claude, .general, .check] {
            for g in [[:], gateway] {
                let env = ChildEnvironment.make(base: ["PATH": "/bin", "HOME": "/h"], extra: ["BRAHMA_AGENT_ID": "a1"], purpose: purpose,
                                                secrets: secrets, gateway: g)
                #expect(!env.values.contains(providerKey), "\(purpose) gateway=\(!g.isEmpty): \(env.keys.sorted())")
                for name in names where name != "ANTHROPIC_API_KEY" { #expect(env[name] == nil, "\(purpose): \(name)") }
                #expect(env["ANTHROPIC_API_KEY"] == (purpose == .claude && !g.isEmpty ? turnToken : nil), "\(purpose)")
                #expect(env["STRIPE_TEST_KEY"] == "test-v")
            }
        }
    }

    /// Ruling 61 m4: the engine's `BRAHMA_*` pass-through from `extra` never carries a provider key name, whatever the caller
    /// put there; the engine's own variables still pass.
    @Test func extraNeverPassesAProviderKeyName() {
        let providerKey = ["sk", "ant", "provider"].joined(separator: "-")
        let extra = ["BRAHMA_AGENT_ID": "a1", "BRAHMA_KEY_OPENROUTER": providerKey, "BRAHMA_KEY_" + String(repeating: "B", count: 40): providerKey,
                     "BRAHMA_KEYS": "plain"]
        for purpose in [ChildEnvironment.Purpose.claude, .general, .check] {
            let env = ChildEnvironment.make(base: ["PATH": "/bin"], extra: extra, purpose: purpose)
            #expect(!env.keys.contains { Provider.isKeyName($0) }, "\(purpose): \(env.keys.sorted())")
            #expect(!env.values.contains(providerKey))
            #expect(env["BRAHMA_AGENT_ID"] == "a1" && env["BRAHMA_KEYS"] == "plain", "\(purpose)")
        }
    }
}

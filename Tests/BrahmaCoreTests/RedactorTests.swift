import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite(.scratch) struct RedactorTests {
    private func redactor(_ values: [(name: String, value: String)], version: String = "v1") -> Redactor {
        let r = Redactor()
        r.update(values, version: version)
        return r
    }

    @Test func redactsRawValue() {
        let r = redactor([("STRIPE_KEY", "sk_test_abcdef123456")])
        #expect(r.apply("token=sk_test_abcdef123456; done") == "token=[redacted STRIPE_KEY]; done")
        #expect(r.apply("nothing here") == "nothing here")
    }

    @Test func redactsPercentAndJSONEscaped() throws {
        let value = #"p"a/ss word:9"#
        let r = redactor([("DB_PASS", value)])
        // Percent-encoded (a URL query), JSON-escaped with and without escaped slashes (a log line).
        let percent = try #require(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
        #expect(r.apply("?pw=\(percent)&x=1") == "?pw=[redacted DB_PASS]&x=1")
        let escapedSlash = try jsonInner(value, escapeSlashes: true), plain = try jsonInner(value, escapeSlashes: false)
        #expect(escapedSlash.contains(#"\""#))
        #expect(r.apply(#"{"pw":"\#(escapedSlash)"}"#) == #"{"pw":"[redacted DB_PASS]"}"#)
        #expect(r.apply(#"{"pw":"\#(plain)"}"#) == #"{"pw":"[redacted DB_PASS]"}"#)
        #expect(!r.apply("\(value) \(percent) \(escapedSlash) \(plain)").contains("word"))
        // applyJSON redacts string leaves at any depth and leaves other leaves alone.
        let tree: JSONValue = .object(["a": .array([.string("x \(value) y"), .number(3)]), "b": .object(["c": .string(percent), "d": .bool(true)]),
                                       "n": .null])
        let out = r.applyJSON(tree)
        #expect(out == .object(["a": .array([.string("x [redacted DB_PASS] y"), .number(3)]),
                                "b": .object(["c": .string("[redacted DB_PASS]"), "d": .bool(true)]), "n": .null]))
    }

    /// m1 (13a fix round 1): a secret used as an object key is redacted too, at any depth.
    @Test func applyJSONRedactsObjectKeys() {
        let r = redactor([("STRIPE_KEY", "sk_test_abcdef123456")])
        let tree: JSONValue = .object([
            "sk_test_abcdef123456": .string("v"),
            "outer": .array([.object(["id=sk_test_abcdef123456": .number(1), "plain": .bool(false)])]),
        ])
        let out = r.applyJSON(tree)
        #expect(out == .object([
            "[redacted STRIPE_KEY]": .string("v"),
            "outer": .array([.object(["id=[redacted STRIPE_KEY]": .number(1), "plain": .bool(false)])]),
        ]))
        // Two keys that redact to the same text both survive (nothing is silently dropped), and neither holds the value.
        let both = r.applyJSON(.object(["sk_test_abcdef123456": .string("a"), "[redacted STRIPE_KEY]": .string("b")]))
        guard case .object(let keys) = both else { Issue.record("not an object"); return }
        #expect(keys.count == 2)
        #expect(keys.keys.allSatisfy { !$0.contains("sk_test_abcdef123456") })
        #expect(keys.values.contains(.string("a")) && keys.values.contains(.string("b")))
    }

    private func jsonInner(_ s: String, escapeSlashes: Bool) throws -> String {
        let e = JSONEncoder()
        if !escapeSlashes { e.outputFormatting = [.withoutEscapingSlashes] }
        let data = try e.encode(s)
        let text = String(decoding: data, as: UTF8.self)
        return String(text.dropFirst().dropLast())
    }

    @Test func shortValuesNotRedacted() {
        #expect(Redactor.minLength == 8)
        let r = redactor([("SHORT", "1234567"), ("EXACT", "12345678")])
        #expect(r.apply("a 1234567 b") == "a 1234567 b")
        #expect(r.apply("a 12345678 b") == "a [redacted EXACT] b")
        // Multi-byte characters count as characters, not bytes: 4 characters is short.
        #expect(redactor([("U", "éééé")]).apply("éééé") == "éééé")
    }

    @Test func longestFirstWhenValuesOverlap() {
        let r = redactor([("SHORTER", "abcdefgh"), ("LONGER", "abcdefghijkl")])
        #expect(r.apply("v=abcdefghijkl") == "v=[redacted LONGER]")
        #expect(r.apply("v=abcdefgh") == "v=[redacted SHORTER]")
    }

    @Test func versionAndUpdateReplaceTheSet() {
        let r = Redactor()
        #expect(r.apply("anything-goes-through") == "anything-goes-through")
        r.update([("A", "secret-value-1")], version: "1:x")
        #expect(r.version == "1:x"); #expect(r.apply("secret-value-1") == "[redacted A]")
        r.update([("B", "secret-value-2")], version: "1:y")
        #expect(r.version == "1:y"); #expect(r.apply("secret-value-1 secret-value-2") == "secret-value-1 [redacted B]")
    }

    @Test func scrubFileRewritesInPlace() throws {
        let dir = try tempDir()
        let file = dir.appending(path: "check.log")
        try Data("line1\nleak: sk_test_abcdef123456\nline3\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let r = redactor([("STRIPE_KEY", "sk_test_abcdef123456")])
        try r.scrubFile(file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "line1\nleak: [redacted STRIPE_KEY]\nline3\n")
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        // A clean file is left byte-for-byte alone; a missing file is an error the caller sees.
        let clean = dir.appending(path: "clean.log")
        try Data([0x61, 0xFF, 0x62]).write(to: clean)
        try r.scrubFile(clean)
        #expect(try Data(contentsOf: clean) == Data([0x61, 0xFF, 0x62]))
        #expect(throws: (any Error).self) { try r.scrubFile(dir.appending(path: "missing.log")) }
    }

    @Test func redactorReloadsOnSecretChange() async throws {
        let dir = try tempDir()
        let path = dir.appending(path: "brahma.sqlite").path
        let engine = try Store(path: path), other = try Store(path: path)
        let company = try engine.createCompany(name: "Acme", goal: "g", workspacesRoot: dir.appending(path: "ws"))
        let vault = MemoryVault()
        let paths = BrahmaPaths(home: dir.appending(path: "home"), workspaces: dir.appending(path: "ws"))
        let orchestrator = Orchestrator(store: engine, runner: FakeTurnRunner(), paths: paths, mcpExecutable: "/usr/local/bin/brahma",
                                        vault: vault)
        try await orchestrator.start()
        // Added through a different Store handle (the owner's CLI or app).
        try other.setSecret(companyId: company.id, name: "API_TOKEN", value: "tok-0123456789", isTest: false, vault: vault)
        #expect(engine.redactor.apply("x tok-0123456789 y") == "x tok-0123456789 y")
        // The tick reloads in the background (a Blocking body), never on the actor.
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(300))
        #expect(engine.redactor.apply("x tok-0123456789 y") == "x [redacted API_TOKEN] y")
        #expect(engine.redactor.version == (try engine.secretsVersion()))
        // Removing it is picked up on the next tick too.
        try other.deleteSecret(companyId: company.id, name: "API_TOKEN", vault: vault)
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(300))
        #expect(engine.redactor.apply("x tok-0123456789 y") == "x tok-0123456789 y")
    }

    @Test func reloadIsANoOpWhenNothingChanged() throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let vault = CountingVault()
        try store.setSecret(companyId: company.id, name: "API_TOKEN", value: "tok-0123456789", isTest: false, vault: vault)
        #expect(try store.reloadRedactorIfNeeded(vault: vault))
        let reads = vault.reads
        #expect(try store.reloadRedactorIfNeeded(vault: vault) == false)
        #expect(vault.reads == reads)
    }

    @Test func mcpServerReloadsBeforeEveryToolCall() throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let ceo = try store.hire(companyId: company.id, name: "ceo", role: "ceo", model: "m")
        let calls = HitCounter()
        let server = MCPServer(tools: CompanyTools(store: store, companyId: company.id, agentId: ceo.id), beforeCall: { calls.bump() })
        _ = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        #expect(calls.value == 0)
        _ = server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_channels","arguments":{}}}"#)
        _ = server.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_agents","arguments":{}}}"#)
        #expect(calls.value == 2)
    }
}

final class HitCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

final class CountingVault: SecretVault, @unchecked Sendable {
    private let inner = MemoryVault(); private let counter = HitCounter()
    var reads: Int { counter.value }
    func set(companyId: String, name: String, value: String) throws { try inner.set(companyId: companyId, name: name, value: value) }
    func value(companyId: String, name: String) throws -> String? { counter.bump(); return try inner.value(companyId: companyId, name: name) }
    func delete(companyId: String, name: String) throws { try inner.delete(companyId: companyId, name: name) }
}

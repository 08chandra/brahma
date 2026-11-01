import Testing
import Foundation
import GRDB
@testable import BrahmaCore

let patternSamples: [PatternSample] = [
    PatternSample(label: "aws-key", sample: "AKIA" + "ABCDEFGHIJKLMNOP"),
    PatternSample(label: "private-key", sample: "-----BEGIN RSA PRIVATE KEY-----"),
    PatternSample(label: "github-token", sample: "ghp_" + String(repeating: "a", count: 36)),
    PatternSample(label: "github-pat", sample: "github_pat_" + String(repeating: "A1_", count: 20)),
    PatternSample(label: "slack-token", sample: "xoxb-" + "1234567890-abcdef"),
    PatternSample(label: "openai-style", sample: "sk-" + "proj_abcdefghij0123456789"),
    PatternSample(label: "stripe-live", sample: "sk_live_" + "abcdefghij0123456789"),
    PatternSample(label: "google-api", sample: "AIza" + String(repeating: "x", count: 35)),
]

/// A vault whose reads can be made to fail per name (or entirely), and that counts its reads.
final class ScriptedVault: SecretVault, @unchecked Sendable {
    private let lock = NSLock()
    private let inner: any SecretVault
    private var _failing: Set<String> = []
    private var _unavailable = false
    private var _needPermission = false
    private var _reads: [String] = []
    private var _threads: [String] = []
    private var _failDelete = false
    init(inner: any SecretVault = MemoryVault()) { self.inner = inner }
    var failDelete: Bool { get { lock.withLock { _failDelete } } set { lock.withLock { _failDelete = newValue } } }
    /// The name of the thread each read ran on.
    var threads: [String] { lock.withLock { _threads } }
    var failing: Set<String> { get { lock.withLock { _failing } } set { lock.withLock { _failing = newValue } } }
    var unavailable: Bool { get { lock.withLock { _unavailable } } set { lock.withLock { _unavailable = newValue } } }
    /// Reads fail as a Keychain read that would have needed the owner's permission (non-interactive).
    var needPermission: Bool { get { lock.withLock { _needPermission } } set { lock.withLock { _needPermission = newValue } } }
    var reads: [String] { lock.withLock { _reads } }
    func set(companyId: String, name: String, value: String) throws { try inner.set(companyId: companyId, name: name, value: value) }
    func value(companyId: String, name: String) throws -> String? {
        let thread = Thread.current.name ?? ""
        lock.withLock { _reads.append(name); _threads.append(thread) }
        if needPermission { throw SecretError.needsPermission }
        if unavailable || failing.contains(name) { throw SecretError.vaultFailed("scripted failure") }
        return try inner.value(companyId: companyId, name: name)
    }
    func delete(companyId: String, name: String) throws {
        if failDelete { throw SecretError.vaultFailed("scripted delete failure") }
        try inner.delete(companyId: companyId, name: name)
    }
}

/// An awake-time clock the tests move by hand (the redactor's retry backoff runs on it).
final class ManualUptime: @unchecked Sendable {
    private let lock = NSLock(); private var t: TimeInterval = 1000
    var now: TimeInterval { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    func install(on store: Store) { store.redactor.setRetryClock { [self] in now } }
}

struct PatternSample: Sendable, CustomTestStringConvertible {
    let label: String, sample: String
    var testDescription: String { label }
}

private let aws = "AKIA" + "ABCDEFGHIJKLMNOP"   // split so this file does not itself trip a scanner

@Suite(.scratch) struct SecretTests {
    private struct W {
        let store: Store, company: Company, other: Company, vault = MemoryVault()
        let ceo: Agent, eng: Agent
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        init() throws {
            store = try Store.inMemory()
            company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            other = try store.createCompany(name: "Other", goal: "g", workspacesRoot: try tempDir())
            ceo = try store.hire(companyId: company.id, name: "ceo", role: "ceo", model: "sonnet")
            eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        }
        func set(_ name: String = "STRIPE_KEY", _ value: String = "sk_test_abcdef123456", test: Bool = false) throws {
            try store.setSecret(companyId: company.id, name: name, value: value, isTest: test, vault: vault, now: now)
        }
    }

    /// Every column of every table, as text: where a leaked value would have to be to leak.
    private func dump(_ store: Store) throws -> String {
        try store.writer.read { db in
            var out = ""
            for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") {
                for row in try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"") {
                    out += "\(table): " + row.databaseValues.map { "\($0)" }.joined(separator: " | ") + "\n"
                }
            }
            return out
        }
    }

    // MARK: names, vaults, metadata

    @Test(arguments: ["AB", "STRIPE_KEY", "A1_B2", String(repeating: "A", count: 64)])
    func validNames(_ name: String) { #expect(SecretName.isValid(name)) }

    @Test(arguments: ["", "A", "lower", "1ABC", "_ABC", "AB-C", "AB C", "AB\n", String(repeating: "A", count: 65), "ÄB"])
    func invalidNames(_ name: String) { #expect(!SecretName.isValid(name)) }

    @Test func memoryVaultRoundTripsPerCompany() throws {
        let v = MemoryVault()
        try v.set(companyId: "c1", name: "A_KEY", value: "one")
        try v.set(companyId: "c2", name: "A_KEY", value: "two")
        #expect(try v.value(companyId: "c1", name: "A_KEY") == "one"); #expect(try v.value(companyId: "c2", name: "A_KEY") == "two")
        try v.set(companyId: "c1", name: "A_KEY", value: "three")
        #expect(try v.value(companyId: "c1", name: "A_KEY") == "three")
        try v.delete(companyId: "c1", name: "A_KEY")
        #expect(try v.value(companyId: "c1", name: "A_KEY") == nil); #expect(try v.value(companyId: "c2", name: "A_KEY") == "two")
        try v.delete(companyId: "c1", name: "A_KEY")   // deleting a missing secret is fine
    }

    @Test func unavailableVaultFailsClosed() {
        let v = UnavailableVault()
        #expect(throws: (any Error).self) { try v.set(companyId: "c", name: "A_KEY", value: "x") }
        #expect(throws: (any Error).self) { _ = try v.value(companyId: "c", name: "A_KEY") }
        #expect(throws: (any Error).self) { try v.delete(companyId: "c", name: "A_KEY") }
    }

    @Test func setStoresMetadataNotValue() throws {
        let w = try W()
        let value = "sk_test_abcdef123456"
        try w.set("STRIPE_KEY", value, test: true)
        let metas = try w.store.secrets(companyId: w.company.id)
        #expect(metas.map(\.name) == ["STRIPE_KEY"]); #expect(metas[0].isTest); #expect(metas[0].companyId == w.company.id)
        #expect(metas[0].lastUsedAt == nil)
        #expect(try w.vault.value(companyId: w.company.id, name: "STRIPE_KEY") == value)
        #expect(!(try dump(w.store)).contains(value))
        #expect(try w.store.secrets(companyId: w.other.id).isEmpty)
        // Replacing keeps the row (and its creation time), moves updatedAt, and may flip the test flag.
        let later = w.now.addingTimeInterval(60)
        try w.store.setSecret(companyId: w.company.id, name: "STRIPE_KEY", value: "sk_test_second_value", isTest: false, vault: w.vault, now: later)
        let again = try w.store.secrets(companyId: w.company.id)
        #expect(again.count == 1); #expect(again[0].id == metas[0].id); #expect(again[0].createdAt == metas[0].createdAt)
        #expect(again[0].updatedAt > metas[0].updatedAt); #expect(!again[0].isTest)
        #expect(try w.vault.value(companyId: w.company.id, name: "STRIPE_KEY") == "sk_test_second_value")
    }

    @Test func setSecretValidatesAndFailsWithoutLeavingARow() throws {
        let w = try W()
        #expect(throws: SecretError.invalidName) { try w.set("lower") }
        #expect(throws: SecretError.emptyValue) { try w.set("OK_NAME", "") }
        #expect(throws: SecretError.unknownCompany) {
            try w.store.setSecret(companyId: "nope", name: "OK_NAME", value: "valuevalue", isTest: false, vault: w.vault)
        }
        #expect(try w.store.secrets(companyId: w.company.id).isEmpty)
        // A vault that cannot store leaves no metadata row behind either.
        #expect(throws: (any Error).self) {
            try w.store.setSecret(companyId: w.company.id, name: "OK_NAME", value: "valuevalue", isTest: false, vault: UnavailableVault())
        }
        #expect(try w.store.secrets(companyId: w.company.id).isEmpty)
    }

    @Test func deleteSecretRemovesRowAndValue() throws {
        let w = try W()
        try w.set()
        try w.store.deleteSecret(companyId: w.company.id, name: "STRIPE_KEY", vault: w.vault)
        #expect(try w.store.secrets(companyId: w.company.id).isEmpty)
        #expect(try w.vault.value(companyId: w.company.id, name: "STRIPE_KEY") == nil)
        #expect(throws: SecretError.notFound) { try w.store.deleteSecret(companyId: w.company.id, name: "STRIPE_KEY", vault: w.vault) }
        // Another company's secret of the same name is untouched.
        try w.set()
        try w.store.setSecret(companyId: w.other.id, name: "STRIPE_KEY", value: "other-company-value", isTest: false, vault: w.vault)
        try w.store.deleteSecret(companyId: w.company.id, name: "STRIPE_KEY", vault: w.vault)
        #expect(try w.vault.value(companyId: w.other.id, name: "STRIPE_KEY") == "other-company-value")
    }

    @Test func secretsVersionTracksCountAndNewestUpdate() throws {
        let w = try W()
        #expect(try w.store.secretsVersion() == "0:")
        try w.set("A_KEY", "value-number-1")
        let v1 = try w.store.secretsVersion()
        #expect(v1.hasPrefix("1:")); #expect(v1.count > 2)
        try w.set("B_KEY", "value-number-2")
        let v2 = try w.store.secretsVersion()
        #expect(v2.hasPrefix("2:")); #expect(v2 != v1)
        try w.store.setSecret(companyId: w.company.id, name: "A_KEY", value: "value-number-3", isTest: false, vault: w.vault,
                              now: w.now.addingTimeInterval(120))
        #expect(try w.store.secretsVersion() != v2)
        try w.store.setSecret(companyId: w.other.id, name: "C_KEY", value: "value-number-4", isTest: false, vault: w.vault)
        #expect(try w.store.secretsVersion().hasPrefix("3:"))   // all companies
    }

    @Test func reloadLoadsValuesFromTheVault() throws {
        let w = try W()
        try w.set("STRIPE_KEY", "sk_test_abcdef123456")
        try w.store.setSecret(companyId: w.other.id, name: "OTHER_KEY", value: "other-company-value", isTest: false, vault: w.vault)
        #expect(try w.store.reloadRedactorIfNeeded(vault: w.vault))
        #expect(w.store.redactor.apply("a sk_test_abcdef123456 b other-company-value") == "a [redacted STRIPE_KEY] b [redacted OTHER_KEY]")
        #expect(!w.store.secretsHeld)
        // A value already loaded is not read again while its secret is unchanged: it stays redacted even if the vault
        // loses it. A secret whose value is missing when it is loaded is a per-secret failure (fail closed): the rest still
        // redact and the store is held until it loads.
        try w.vault.delete(companyId: w.other.id, name: "OTHER_KEY")
        try w.set("NEW_KEY", "brand-new-value-xx")
        try w.set("LOST_KEY", "lost-value-123456")
        try w.vault.delete(companyId: w.company.id, name: "LOST_KEY")
        #expect(try w.store.reloadRedactorIfNeeded(vault: w.vault))
        #expect(w.store.redactor.apply("brand-new-value-xx sk_test_abcdef123456 other-company-value lost-value-123456")
                == "[redacted NEW_KEY] [redacted STRIPE_KEY] [redacted OTHER_KEY] lost-value-123456")
        #expect(w.store.secretsHeld)
        #expect(w.store.redactor.failedNames == ["LOST_KEY"])
        let line = try #require(try w.store.events(afterId: 0, companyId: w.company.id).last { $0.kind == .error })
        #expect(line.text.contains("LOST_KEY")); #expect(line.text.contains("the vault has no value for it"))
    }

    @Test func reloadWithUnavailableVaultKeepsTheOldSet() throws {
        let w = try W()
        let clock = ManualUptime(); clock.install(on: w.store)
        try w.set()
        _ = try w.store.reloadRedactorIfNeeded(vault: w.vault)
        try w.set("NEW_KEY", "brand-new-value-xx")
        // Nothing can be read: no throw, the values already loaded still redact, the store is held and the next call retries.
        #expect(try w.store.reloadRedactorIfNeeded(vault: UnavailableVault()))
        #expect(w.store.redactor.apply("sk_test_abcdef123456") == "[redacted STRIPE_KEY]")
        #expect(w.store.secretsHeld)
        #expect(w.store.redactor.version != (try w.store.secretsVersion()))
        // Retried after the backoff (5 s of awake time), not before.
        #expect(try w.store.reloadRedactorIfNeeded(vault: w.vault) == false)
        clock.advance(5)
        #expect(try w.store.reloadRedactorIfNeeded(vault: w.vault))
        #expect(!w.store.secretsHeld)
        #expect(w.store.redactor.version == (try w.store.secretsVersion()))
        #expect(w.store.redactor.apply("brand-new-value-xx") == "[redacted NEW_KEY]")
    }

    // MARK: F2: per-secret load, fail closed

    @Test func oneFailingSecretStillRedactsOthers() throws {
        let w = try W()
        let clock = ManualUptime(); clock.install(on: w.store)
        let vault = ScriptedVault(inner: w.vault)
        try w.store.setSecret(companyId: w.company.id, name: "GOOD_KEY", value: "good-value-12345", isTest: false, vault: vault)
        try w.store.setSecret(companyId: w.company.id, name: "BAD_KEY", value: "bad-value-123456", isTest: false, vault: vault)
        vault.failing = ["BAD_KEY"]
        #expect(try w.store.reloadRedactorIfNeeded(vault: vault))   // a vault failure never aborts the load
        #expect(w.store.redactor.apply("good-value-12345 bad-value-123456") == "[redacted GOOD_KEY] bad-value-123456")
        #expect(w.store.secretsHeld); #expect(w.store.redactor.failedNames == ["BAD_KEY"])
        // Logged by name for the secret's company, never with the value.
        let errors = { try w.store.events(afterId: 0, companyId: w.company.id).filter { $0.kind == .error } }
        #expect(try errors().count == 1)
        #expect(try errors()[0].text.contains("BAD_KEY")); #expect(!(try errors()[0].text.contains("bad-value-123456")))
        #expect(try w.store.events(afterId: 0, companyId: w.other.id).filter { $0.kind == .error }.isEmpty)
        // Retried once the backoff has passed (only the failed one is read again), and the same failure is not logged twice.
        let readsBefore = vault.reads.count
        clock.advance(5)
        #expect(try w.store.reloadRedactorIfNeeded(vault: vault))
        #expect(vault.reads.dropFirst(readsBefore) == ["BAD_KEY"])
        #expect(try errors().count == 1)
        // The vault recovers: fully loaded, no longer held, both redact.
        vault.failing = []
        clock.advance(10)
        #expect(try w.store.reloadRedactorIfNeeded(vault: vault))
        #expect(!w.store.secretsHeld); #expect(w.store.redactor.failedNames.isEmpty)
        #expect(w.store.redactor.version == (try w.store.secretsVersion()))
        #expect(w.store.redactor.apply("good-value-12345 bad-value-123456") == "[redacted GOOD_KEY] [redacted BAD_KEY]")
        #expect(try w.store.reloadRedactorIfNeeded(vault: vault) == false)
    }

    @Test func nonUTF8Refused() throws {
        // At input: `brahma secret set` refuses bytes that are not UTF-8 (they would be stored mangled and never redacted).
        func read(_ bytes: [UInt8]) throws -> String {
            let pipe = Pipe()
            pipe.fileHandleForWriting.write(Data(bytes))
            try pipe.fileHandleForWriting.close()
            return try SecretInput.read(from: pipe.fileHandleForReading)
        }
        #expect(throws: SecretError.notUTF8) { _ = try read([0x61, 0xFF, 0xFE, 0x62, 0x0A]) }
        #expect(try read(Array("ok-ünï-value\n".utf8)) == "ok-ünï-value")
        #expect(throws: SecretError.notUTF8) { _ = try SecretValue.decode(Data([0x61, 0xC3, 0x28, 0x62])) }
        #expect(try SecretValue.decode(Data("plain-value".utf8)) == "plain-value")
        // At load: a stored value that is not UTF-8 is a per-secret failure (logged, held, retried), never skipped.
        let w = try W()
        let home = try tempDir()
        let vault = FileVault(home: home)
        try w.store.setSecret(companyId: w.company.id, name: "GOOD_KEY", value: "good-value-12345", isTest: false, vault: vault)
        try w.store.setSecret(companyId: w.company.id, name: "RAW_KEY", value: "placeholder-1234", isTest: false, vault: vault)
        try vault.setRaw(companyId: w.company.id, name: "RAW_KEY", bytes: Data([0x72, 0x61, 0x77, 0xFF, 0xFE, 0x31, 0x32, 0x33, 0x34]))
        #expect(throws: SecretError.notUTF8) { _ = try vault.value(companyId: w.company.id, name: "RAW_KEY") }
        _ = try w.store.reloadRedactorIfNeeded(vault: vault)
        #expect(w.store.secretsHeld); #expect(w.store.redactor.failedNames == ["RAW_KEY"])
        #expect(w.store.redactor.apply("good-value-12345") == "[redacted GOOD_KEY]")
        let errors = try w.store.events(afterId: 0, companyId: w.company.id).filter { $0.kind == .error }
        #expect(errors.count == 1); #expect(errors[0].text.contains("RAW_KEY")); #expect(errors[0].text.contains("UTF-8"))
    }

    /// A data home whose database already holds a secret, opened by a fresh Store (a new engine or MCP process).
    private struct FreshProcess {
        let dir: URL, path: String
        let company: Company, ceo: Agent
        let inner = MemoryVault()
        init() throws {
            dir = try tempDir()
            path = dir.appending(path: "brahma.sqlite").path
            let owner = try Store(path: path)
            company = try owner.createCompany(name: "Acme", goal: "g", workspacesRoot: dir.appending(path: "ws"))
            ceo = try owner.hire(companyId: company.id, name: "ceo", role: "ceo", model: "sonnet")
            _ = try MessageRouter(store: owner).sendDM(companyId: company.id, from: .owner, to: "ceo", text: "please start")
            try owner.setSecret(companyId: company.id, name: "API_KEY", value: "api-key-value-123", isTest: false, vault: inner)
        }
    }

    @Test func failClosedUntilFirstLoad() async throws {
        let f = try FreshProcess()
        let vault = ScriptedVault(inner: f.inner)
        vault.unavailable = true
        let store = try Store(path: f.path)
        let clock = ManualUptime(); clock.install(on: store)
        // Before any load in this process: held, and every redacting write throws instead of storing unredacted text.
        #expect(store.secretsHeld); #expect(!store.redactor.hasLoaded)
        #expect(throws: SecretError.secretsNotLoaded) {
            _ = try MessageRouter(store: store).post(companyId: f.company.id, channel: "general", from: .owner, text: "api-key-value-123")
        }
        #expect(throws: SecretError.secretsNotLoaded) {
            try store.appendEvent(ActivityEvent(companyId: f.company.id, agentId: nil, turnId: nil, kind: .usage, text: "x", createdAt: .now))
        }

        // (a) The engine admits no turn while the vault throws.
        let w = try World(store: store, vault: vault)
        try await w.orchestrator.start()
        try await w.cycle(); try await w.cycle()
        #expect(w.fake.requests.isEmpty, "no turn may start before the secrets are loaded")
        #expect(try w.agent(f.ceo).state == .ready)
        let errors = try store.events(afterId: 0, companyId: f.company.id).filter { $0.kind == .error }
        #expect(errors.filter { $0.text.contains("API_KEY") }.count == 1, "one activity line, not one per tick: \(errors.map(\.text))")
        #expect(!errors.contains { $0.text.contains("api-key-value-123") })

        // (b) `brahma mcp` refuses tool calls with a clear error, and nothing is written.
        let server = MCPServer(tools: CompanyTools(store: store, companyId: f.company.id, agentId: f.ceo.id),
                               beforeCall: { try store.prepareForToolCall(vault: vault) })
        let refused = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"post_message","arguments":{"channel":"general","text":"api-key-value-123"}}}"#) ?? ""
        #expect(refused.contains("secrets are not loaded yet; try again shortly")); #expect(refused.contains(#""isError":true"#))
        let general = try #require(try store.channel(companyId: f.company.id, name: "general"))
        #expect(try store.messages(channelId: general.id, limit: 5).isEmpty)

        // Every engine read ran in the engine's Blocking threads, never on the actor.
        #expect(!vault.threads.isEmpty); #expect(vault.threads.allSatisfy { $0 == "brahma-blocking" }, "\(vault.threads)")
        // One owner notice for the hold episode, written although redaction is not loaded.
        let notices = try store.undeliveredNotices().filter { $0.kind == .system && $0.title.lowercased().contains("secret") }
        #expect(notices.count == 1, "\(notices.map(\.title))")
        // The vault comes back: once the backoff passes a tick loads in the background, the next tick admits the turn; MCP writes
        // work and are redacted.
        vault.unavailable = false
        try await w.cycle()
        #expect(store.secretsHeld, "not retried before the backoff")
        clock.advance(5)
        try await w.cycle()
        #expect(!store.secretsHeld); #expect(store.redactor.hasLoaded)
        try await w.cycle()
        #expect(w.fake.requests.count == 1)
        #expect(vault.threads.allSatisfy { $0 == "brahma-blocking" }, "\(vault.threads)")
        let ok = server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"post_message","arguments":{"channel":"general","text":"key api-key-value-123"}}}"#) ?? ""
        #expect(ok.contains(#""isError":false"#), "\(ok)")
        #expect(try store.messages(channelId: general.id, limit: 5).map(\.text) == ["key [redacted API_KEY]"])
    }

    @Test func mcpRefusesWhileAnySecretFailsAfterTheFirstLoad() throws {
        let w = try W()
        let vault = ScriptedVault(inner: w.vault)
        try w.store.setSecret(companyId: w.company.id, name: "BAD_KEY", value: "bad-value-123456", isTest: false, vault: vault)
        vault.failing = ["BAD_KEY"]
        let clock = ManualUptime(); clock.install(on: w.store)
        #expect(throws: (any Error).self) { try w.store.prepareForToolCall(vault: vault) }
        vault.failing = []
        // MCP reads back off like the engine: still refused until the retry is due.
        #expect(throws: (any Error).self) { try w.store.prepareForToolCall(vault: vault) }
        clock.advance(5)
        try w.store.prepareForToolCall(vault: vault)
        #expect(w.store.redactor.apply("bad-value-123456") == "[redacted BAD_KEY]")
    }

    @Test func noSecretsNoHold() async throws {
        let w = try World(vault: UnavailableVault())
        let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        #expect(!w.store.secretsHeld); #expect(w.store.redactor.hasLoaded)
        // A fresh process on a database with no secrets is not held either.
        let dir = try tempDir(); let path = dir.appending(path: "brahma.sqlite").path
        let first = try Store(path: path)
        _ = try first.createCompany(name: "Acme", goal: "g", workspacesRoot: dir)
        let fresh = try Store(path: path)
        #expect(!fresh.secretsHeld)
        try fresh.prepareForToolCall(vault: UnavailableVault())
        try w.dm(c, ceo)
        try await w.orchestrator.start()
        try await w.cycle()
        #expect(w.fake.requests.count == 1)
        let tools = CompanyTools(store: w.store, companyId: c.id, agentId: ceo.id)
        let server = MCPServer(tools: tools, beforeCall: { try w.store.prepareForToolCall(vault: UnavailableVault()) })
        let ok = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_channels","arguments":{}}}"#) ?? ""
        #expect(ok.contains(#""isError":false"#), "\(ok)")
    }

    // MARK: round 2: backoff, notices, lazy loading, owner load

    @Test func backgroundReadsBackOffAndResetOnVersionChange() throws {
        let w = try W()
        let clock = ManualUptime(); clock.install(on: w.store)
        let vault = ScriptedVault(inner: w.vault)
        try w.store.setSecret(companyId: w.company.id, name: "BAD_KEY", value: "bad-value-123456", isTest: false, vault: vault)
        vault.failing = ["BAD_KEY"]
        func attempt() throws -> Bool { let n = vault.reads.count; _ = try w.store.reloadRedactorIfNeeded(vault: vault); return vault.reads.count > n }
        #expect(try attempt())                       // first attempt at once
        var delays: [Int] = []
        for _ in 0..<9 {
            var waited = 0
            while !(try attempt()) { clock.advance(1); waited += 1; if waited > 400 { break } }
            delays.append(waited)
        }
        #expect(delays == [5, 10, 20, 40, 80, 160, 300, 300, 300], "\(delays)")
        #expect(try w.store.redactorReloadDue() == false)
        // A secrets change (another process set one) retries at once and restarts the backoff.
        try w.store.setSecret(companyId: w.company.id, name: "OTHER_KEY", value: "other-value-1234", isTest: false, vault: vault)
        #expect(try w.store.redactorReloadDue())
        #expect(try attempt())
        #expect(try attempt() == false); clock.advance(5); #expect(try attempt())
        // An explicit owner load ignores the backoff.
        vault.failing = []
        let report = try w.store.ownerLoadSecrets(vault: vault)
        #expect(report.failed.isEmpty); #expect(!w.store.secretsHeld)
    }

    @Test func holdEpisodeWritesOneOwnerNotice() throws {
        let w = try W()
        let clock = ManualUptime(); clock.install(on: w.store)
        let vault = ScriptedVault(inner: w.vault)
        try w.store.setSecret(companyId: w.company.id, name: "A_KEY", value: "a-value-1234567", isTest: false, vault: vault)
        try w.store.setSecret(companyId: w.company.id, name: "B_KEY", value: "b-value-1234567", isTest: false, vault: vault)
        vault.needPermission = true
        let notices = { try w.store.undeliveredNotices().filter { $0.kind == .system } }
        _ = try w.store.reloadRedactorIfNeeded(vault: vault)
        for _ in 0..<3 { clock.advance(400); _ = try w.store.reloadRedactorIfNeeded(vault: vault) }
        #expect(try notices().count == 1)
        let n = try #require(try notices().first)
        #expect(n.companyId == nil)
        #expect("\(n.title) \(n.body)".contains("Brahma can't read 2 secret(s) without your permission (A_KEY, B_KEY); agents are paused. Run `brahma secret load` or press Load secrets in the app."),
                "\(n.title) | \(n.body)")
        // MCP and the CLI never write notices.
        try? w.store.prepareForToolCall(vault: vault)
        #expect(try notices().count == 1)
        // The episode ends when everything loads; a new failure starts a new one.
        vault.needPermission = false
        clock.advance(400); _ = try w.store.reloadRedactorIfNeeded(vault: vault)
        #expect(!w.store.secretsHeld)
        try w.store.setSecret(companyId: w.company.id, name: "C_KEY", value: "c-value-1234567", isTest: false, vault: w.vault)
        vault.failing = ["C_KEY"]
        _ = try w.store.reloadRedactorIfNeeded(vault: vault)
        #expect(try notices().count == 2)
        // A failure `brahma secret load` cannot fix says what it is, by name and reason (never a value).
        let second = try #require(try notices().last)
        #expect("\(second.title) \(second.body)".contains("Brahma can't read 1 secret(s): C_KEY (the secrets vault failed: scripted failure)"),
                "\(second.body)")
        #expect(!second.body.contains("c-value-1234567"))
    }

    @Test func holdTextSaysWhyByReason() throws {
        let w = try W()
        let clock = ManualUptime(); clock.install(on: w.store)
        let vault = ScriptedVault(inner: w.vault)
        #expect(w.store.secretsHoldText() == nil)
        for (n, v) in [("A_KEY", "a-value-1234567"), ("B_KEY", "b-value-1234567"), ("C_KEY", "c-value-1234567")] {
            try w.store.setSecret(companyId: w.company.id, name: n, value: v, isTest: false, vault: vault)
        }
        // Before any load attempt in this process.
        let fresh = try Store(path: try { () throws -> String in
            let d = try tempDir(); let p = d.appending(path: "b.sqlite").path
            let o = try Store(path: p); let c = try o.createCompany(name: "X", goal: "g", workspacesRoot: d)
            try o.setSecret(companyId: c.id, name: "X_KEY", value: "x-value-1234567", isTest: false, vault: MemoryVault())
            return p }())
        #expect(fresh.secretsHoldText()?.contains("can't read 1 secret(s)") == true, "\(fresh.secretsHoldText() ?? "nil")")
        // Missing value and a value that is not UTF-8: names and reasons, and the fix is not `secret load`.
        try w.vault.delete(companyId: w.company.id, name: "B_KEY")
        vault.failing = ["C_KEY"]
        _ = try w.store.reloadRedactorIfNeeded(vault: vault)
        let text = try #require(w.store.secretsHoldText())
        #expect(text.contains("Brahma can't read 2 secret(s): B_KEY (the vault has no value for it); C_KEY (the secrets vault failed: scripted failure)."), "\(text)")
        #expect(!text.contains("without your permission")); #expect(text.contains("brahma secret set"))
        #expect(!text.contains("value-1234567"))
        // Permission failures say so and point to `brahma secret load`.
        try w.vault.set(companyId: w.company.id, name: "B_KEY", value: "b-value-1234567")
        vault.failing = []; vault.needPermission = true
        clock.advance(400); _ = try w.store.reloadRedactorIfNeeded(vault: vault)
        let perm = try #require(w.store.secretsHoldText())
        #expect(perm.contains("Brahma can't read 2 secret(s) without your permission (B_KEY, C_KEY)"), "\(perm)")
        #expect(perm.contains("brahma secret load"))
    }

    // MARK: round 3: one reload at a time; a stale load never wins

    /// A vault whose read of `gated` signals `reached`, waits for `release`, then fails (a background read that would have
    /// needed permission).
    final class GatedVault: SecretVault, @unchecked Sendable {
        let inner: any SecretVault, gated: String
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        init(inner: any SecretVault, gated: String) { self.inner = inner; self.gated = gated }
        func set(companyId: String, name: String, value: String) throws { try inner.set(companyId: companyId, name: name, value: value) }
        func value(companyId: String, name: String) throws -> String? {
            if name == gated { reached.signal(); release.wait(); throw SecretError.needsPermission }
            return try inner.value(companyId: companyId, name: name)
        }
        func delete(companyId: String, name: String) throws { try inner.delete(companyId: companyId, name: name) }
    }

    @Test func concurrentReloadsNeverLeaveAStaleFailedLoad() throws {
        let dir = try tempDir(); let path = dir.appending(path: "brahma.sqlite").path
        let owner = try Store(path: path)
        let company = try owner.createCompany(name: "Acme", goal: "g", workspacesRoot: dir)
        let vault = MemoryVault()
        for (n, v) in [("A_KEY", "a-value-1234567"), ("B_KEY", "b-value-1234567"), ("C_KEY", "c-value-1234567")] {
            try owner.setSecret(companyId: company.id, name: n, value: v, isTest: false, vault: vault)
        }
        // One process (the app): its engine's background reload and the owner's Load secrets share this store.
        let store = try Store(path: path)
        let background = GatedVault(inner: vault, gated: "B_KEY")
        let bgDone = DispatchSemaphore(value: 0), ownerDone = DispatchSemaphore(value: 0)
        Thread { _ = try? store.reloadRedactorIfNeeded(vault: background, logFailures: false); bgDone.signal() }.start()
        #expect(background.reached.wait(timeout: .now() + 10) == .success)   // the background read of B is in flight
        Thread { _ = try? store.ownerLoadSecrets(vault: vault); ownerDone.signal() }.start()
        // Give the owner's load every chance to finish first (it must not be able to: one reload at a time).
        let ownerFinishedFirst = ownerDone.wait(timeout: .now() + 0.5) == .success
        background.release.signal()                                          // B fails in the background
        #expect(bgDone.wait(timeout: .now() + 10) == .success)
        if !ownerFinishedFirst { #expect(ownerDone.wait(timeout: .now() + 10) == .success) }
        #expect(!ownerFinishedFirst, "the owner's load ran while the background reload was in flight")
        // The owner's complete load is the one that stands: nothing held, everything redacted.
        #expect(!store.secretsHeld, "failed: \(store.redactor.failedNames)")
        #expect(store.redactor.version == (try store.secretsVersion()))
        #expect(store.redactor.apply("a-value-1234567 b-value-1234567 c-value-1234567")
                == "[redacted A_KEY] [redacted B_KEY] [redacted C_KEY]")
    }

    @Test func installRejectsALoadStartedBeforeTheInstalledOne() {
        let r = Redactor()
        let older = r.beginLoad(), newer = r.beginLoad()
        r.install(loaded: ["c:A_KEY": .init(name: "A_KEY", updatedAt: .now, value: "a-value-1234567")], failed: [], version: "1:2",
                  ticket: newer)
        #expect(r.hasLoaded); #expect(r.version == "1:2")
        // The older, failed result arrives late: ignored.
        #expect(r.install(loaded: [:], failed: ["A_KEY"], version: nil, ticket: older) == false)
        #expect(r.failedNames.isEmpty); #expect(r.version == "1:2")
        #expect(r.apply("a-value-1234567") == "[redacted A_KEY]")
    }

    @Test func engineRunDoesNotInstallTheCLILazyLoader() throws {
        // `brahma run` is the engine: it reloads in its own Blocking bodies, never through the CLI's on-the-actor loader.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let run = try String(contentsOf: sources.appending(path: "Sources/brahma/RunCommand.swift"), encoding: .utf8)
        #expect(run.contains("openStore(lazySecrets: false)"))
        #expect(!run.contains("try openStore()"))
        let support = try String(contentsOf: sources.appending(path: "Sources/brahma/CLISupport.swift"), encoding: .utf8)
        #expect(support.contains("func openStore(lazySecrets: Bool = true)"))
    }

    @Test func lazyLoaderRunsOnceOnTheFirstRedactingWrite() throws {
        let f = try FreshProcess()
        let store = try Store(path: f.path)
        let loads = HitCounter()
        let vault = ScriptedVault(inner: f.inner)
        store.redactorLoader = { loads.bump(); _ = try? store.reloadRedactorIfNeeded(vault: vault, logFailures: false) }
        // Read-only work never touches the vault.
        _ = try store.secrets(companyId: f.company.id); _ = try store.companies(); _ = try store.events(afterId: 0)
        #expect(loads.value == 0); #expect(vault.reads.isEmpty)
        // The first redacting write loads (from inside its write transaction) and is redacted.
        _ = try MessageRouter(store: store).post(companyId: f.company.id, channel: "general", from: .owner, text: "key api-key-value-123")
        #expect(loads.value == 1); #expect(vault.reads == ["API_KEY"])
        let general = try #require(try store.channel(companyId: f.company.id, name: "general"))
        #expect(try store.messages(channelId: general.id, limit: 5).map(\.text) == ["key [redacted API_KEY]"])
        _ = try MessageRouter(store: store).post(companyId: f.company.id, channel: "general", from: .owner, text: "again")
        #expect(loads.value == 1)
        // A loader that cannot load: the write still fails closed, and the loader is tried only once.
        let other = try Store(path: f.path)
        let failing = ScriptedVault(inner: f.inner); failing.unavailable = true
        let tries = HitCounter()
        other.redactorLoader = { tries.bump(); _ = try? other.reloadRedactorIfNeeded(vault: failing, logFailures: false) }
        for _ in 0..<2 {
            #expect(throws: SecretError.secretsNotLoaded) {
                _ = try MessageRouter(store: other).post(companyId: f.company.id, channel: "general", from: .owner, text: "x")
            }
        }
        #expect(tries.value == 1)
    }

    @Test func ownerLoadSignalsOtherProcessesToRetryAtOnce() throws {
        let f = try FreshProcess()
        let engine = try Store(path: f.path)
        let clock = ManualUptime(); clock.install(on: engine)
        let denied = ScriptedVault(inner: f.inner); denied.unavailable = true
        _ = try engine.reloadRedactorIfNeeded(vault: denied)
        #expect(engine.secretsHeld); #expect(try engine.redactorReloadDue() == false)
        // The owner loads interactively in another process (the CLI's `brahma secret load`, or the app's button).
        let owner = try Store(path: f.path)
        let report = try owner.ownerLoadSecrets(vault: f.inner)
        #expect(report.loaded == 1); #expect(report.failed.isEmpty); #expect(!owner.secretsHeld)
        // The engine's backoff is reset by the secrets version change and its next background read succeeds.
        #expect(try engine.redactorReloadDue())
        denied.unavailable = false
        _ = try engine.reloadRedactorIfNeeded(vault: denied)
        #expect(!engine.secretsHeld)
        // A failed owner load reports the names and reasons.
        let broken = try Store(path: f.path)
        let failing = ScriptedVault(inner: f.inner); failing.unavailable = true
        let bad = try broken.ownerLoadSecrets(vault: failing)
        #expect(bad.failed.map(\.name) == ["API_KEY"]); #expect(bad.failed[0].reason.contains("scripted failure"))
    }

    @Test func deleteSecretRemovesTheVaultValueFirst() throws {
        let w = try W()
        let vault = ScriptedVault(inner: w.vault)
        try w.store.setSecret(companyId: w.company.id, name: "A_KEY", value: "a-value-1234567", isTest: false, vault: vault)
        vault.failDelete = true
        #expect(throws: (any Error).self) { try w.store.deleteSecret(companyId: w.company.id, name: "A_KEY", vault: vault) }
        // The row stays, so the owner can retry; the value was not orphaned.
        #expect(try w.store.secrets(companyId: w.company.id).map(\.name) == ["A_KEY"])
        vault.failDelete = false
        try w.store.deleteSecret(companyId: w.company.id, name: "A_KEY", vault: vault)
        #expect(try w.store.secrets(companyId: w.company.id).isEmpty)
        #expect(try vault.value(companyId: w.company.id, name: "A_KEY") == nil)
        #expect(throws: SecretError.notFound) { try w.store.deleteSecret(companyId: w.company.id, name: "A_KEY", vault: vault) }
    }

    @Test func requestModeReasonIsRedactedRawFirst() throws {
        let w = try W()
        let s = "multi-line\nsecret-9876"
        try w.set("ML_KEY", s)
        _ = try w.store.reloadRedactorIfNeeded(vault: w.vault)
        let item = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Hard \(s)", ownerId: w.eng.id, status: .ready), now: w.now)
        #expect(try w.store.workItem(id: item.id)?.title == "Hard [redacted ML_KEY]", "title redacted before it is flattened")
        _ = try w.store.requestMode(companyId: w.company.id, by: w.eng.id, itemKey: item.key, mode: "deep", reason: "need \(s) now", now: w.now)
        let everything = try dump(w.store)
        #expect(!everything.contains("multi-line secret-9876")); #expect(!everything.contains("secret-9876"))
    }

    @Test func checkSpecAndTouchPathsAreRedactedBeforeValidation() throws {
        let w = try W()
        let s = "sk_test_pathsecret1"
        try w.set("PATH_KEY", s)
        _ = try w.store.reloadRedactorIfNeeded(vault: w.vault)
        let draft = WorkItemDraft(type: .task, title: "T", checkSpec: CheckSpec(command: "make", paths: ["src/\(s)/x.swift"]),
                                  ownerId: w.eng.id, status: .ready, touchPaths: ["docs/\(s).md"])
        // Either refused (a redacted path is not a valid path) or stored redacted: never stored raw.
        let created = try? w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: draft, now: w.now)
        let plain = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "U", ownerId: w.eng.id, status: .ready), now: w.now)
        _ = try? w.store.updateWorkItem(id: plain.id, by: .owner, patch: WorkItemPatch(touchPaths: ["lib/\(s).swift"]), now: w.now)
        _ = try? w.store.updateWorkItem(id: plain.id, by: .owner, patch: WorkItemPatch(
            checkSpec: .some(CheckSpec(command: "make", paths: ["a/\(s)"]))), now: w.now)
        #expect(!(try dump(w.store)).contains(s))
        _ = created
    }

    // MARK: redaction at every store write path

    @Test func redactsEverywhere() throws {
        let w = try W()
        let s = "sk_test_abcdef123456"
        try w.set("STRIPE_KEY", s)
        _ = try w.store.reloadRedactorIfNeeded(vault: w.vault)
        let router = MessageRouter(store: w.store)

        // Messages and the activity line derived from them (channel, DM, owner and agent senders).
        _ = try router.post(companyId: w.company.id, channel: "general", from: .agent(w.eng.id), text: "key is \(s)")
        _ = try router.sendDM(companyId: w.company.id, from: .owner, to: "eng-1", text: "use \(s) please")
        let general = try #require(try w.store.channel(companyId: w.company.id, name: "general"))
        #expect(try w.store.messages(channelId: general.id, limit: 10).map(\.text) == ["key is [redacted STRIPE_KEY]"])
        #expect(try w.store.searchMessages(companyId: w.company.id, query: s).isEmpty)

        // Activity events, raw and engine alerts and holds.
        try w.store.appendEvent(ActivityEvent(companyId: w.company.id, agentId: nil, turnId: nil, kind: .error, text: "boom \(s)", createdAt: w.now))
        try EngineAlerts.raise(store: w.store, text: "alert \(s)", now: w.now)
        try w.store.setHold(reason: .cli, detail: "probe said \(s)", now: w.now)

        // Turn summary (success and failure) and the activity line that echoes it.
        let t1 = try #require(try w.store.beginTurn(agentId: w.eng.id, now: w.now)).1
        try w.store.endTurn(agentId: w.eng.id, turn: t1, end: .succeeded(
            TurnResult(isError: false, subtype: "success", text: "done with \(s)", costUSD: nil, apiErrorStatus: nil, sessionId: "s"),
            usageHold: nil), deliveredItemIds: [], now: w.now)
        _ = try w.store.writer.write { db in try Agent.filter(key: w.eng.id).updateAll(db, Column("state").set(to: AgentState.ready.rawValue)) }
        let t2 = try #require(try w.store.beginTurn(agentId: w.eng.id, now: w.now)).1
        try w.store.endTurn(agentId: w.eng.id, turn: t2, end: .failed("crashed: \(s)"), deliveredItemIds: [], now: w.now)
        let t3 = try w.store.startTurn(agentId: w.ceo.id, now: w.now)
        try w.store.finishTurn(id: t3.id, outcome: .failed, summary: "direct \(s)", costUSD: nil, now: w.now)

        // set_blocked reason.
        let tools = CompanyTools(store: w.store, companyId: w.company.id, agentId: w.ceo.id)
        _ = try tools.call(name: "set_blocked", arguments: ["on": .string("owner"), "reason": .string("need \(s)")])

        // Work items: create, edit every free-text field, status/blocked reason, check, comment, notes.
        let item = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Use \(s)", description: "desc \(s)", acceptanceCriteria: "ac \(s)",
            checkSpec: CheckSpec(command: "curl -u \(s) x"), ownerId: w.eng.id, status: .ready), now: w.now)
        // Checked before the edit below overwrites these fields.
        let fresh = try #require(try w.store.workItem(id: item.id))
        #expect(fresh.title == "Use [redacted STRIPE_KEY]"); #expect(fresh.description == "desc [redacted STRIPE_KEY]")
        #expect(fresh.acceptanceCriteria == "ac [redacted STRIPE_KEY]")
        #expect(fresh.checkSpec?.command == "curl -u [redacted STRIPE_KEY] x")
        _ = try w.store.updateWorkItem(id: item.id, by: .owner, patch: WorkItemPatch(
            title: "Retitle \(s)", description: "d2 \(s)", acceptanceCriteria: "a2 \(s)",
            checkSpec: .some(CheckSpec(command: "echo \(s)")), notes: .some("notes \(s)")), now: w.now)
        _ = try w.store.commentWorkItem(id: item.id, by: .agent(w.eng.id), text: "I pasted \(s) @ceo", now: w.now)
        _ = try w.store.updateWorkItem(id: item.id, by: .agent(w.eng.id), patch: WorkItemPatch(status: .blocked, blockedReason: "stuck on \(s)"), now: w.now)

        // Owner notices.
        try w.store.notifyOwner(companyId: w.company.id, title: "Title \(s)", body: "Body \(s)", now: w.now)
        try w.store.writer.write { db in
            try w.store.notifyOwner(db: db, companyId: w.company.id, kind: .digest, urgency: .urgent, title: "T \(s)", body: "B \(s)", now: w.now)
        }

        let everything = try dump(w.store)
        #expect(!everything.contains(s), "the secret value reached the database")
        #expect(everything.contains("[redacted STRIPE_KEY]"))
        // Spot checks that the redaction kept the surrounding text.
        #expect(try w.store.itemEvents(itemId: item.id).contains { $0.kind == .commented && $0.text == "I pasted [redacted STRIPE_KEY] @ceo" })
        #expect(try w.store.lastTurn(agentId: w.eng.id)?.summary == "crashed: [redacted STRIPE_KEY]")
        #expect(try w.store.undeliveredNotices().contains { $0.title == "Title [redacted STRIPE_KEY]" })
    }

    @Test func shortSecretValuesAreNotRedactedAnywhere() throws {
        let w = try W()
        try w.set("TINY_KEY", "abc1234")   // 7 characters
        _ = try w.store.reloadRedactorIfNeeded(vault: w.vault)
        _ = try MessageRouter(store: w.store).post(companyId: w.company.id, channel: "general", from: .owner, text: "abc1234")
        let general = try #require(try w.store.channel(companyId: w.company.id, name: "general"))
        #expect(try w.store.messages(channelId: general.id, limit: 1).map(\.text) == ["abc1234"])
    }

    // MARK: leak patterns

    @Test(arguments: patternSamples)
    func patternsFound(_ s: PatternSample) {
        let label = s.label, sample = s.sample
        let diff = "+++ b/app.env\n@@ -0,0 +1 @@\n+token = \(sample)\n"
        let found = SecretScan.findings(diff: diff, knownValues: [])
        #expect(found.count == 1); #expect(found.first?.contains(label) == true, "\(found)")
        #expect(found.allSatisfy { !$0.contains(sample) }, "a finding must never contain the matched text")
    }

    @Test func patternTableIsTheSpecifiedEight() {
        #expect(SecretScan.patterns.map(\.label) == ["aws-key", "private-key", "github-token", "github-pat", "slack-token",
                                                      "openai-style", "stripe-live", "google-api"])
        #expect(SecretScan.patterns.map(\.ere) == [
            "AKIA[0-9A-Z]{16}", "-----BEGIN [A-Z ]*PRIVATE KEY-----", "gh[pousr]_[A-Za-z0-9]{36,}", "github_pat_[A-Za-z0-9_]{60,}",
            "xox[abprs]-[A-Za-z0-9-]{10,}", "sk-[A-Za-z0-9_-]{20,}", "sk_live_[A-Za-z0-9]{20,}", "AIza[0-9A-Za-z_-]{35}",
        ])
    }

    @Test func onlyAddedLinesAreScanned() {
        let diff = """
        diff --git a/a b/a
        --- a/a
        +++ b/a
        @@ -1,3 +1,3 @@
         context \(aws)
        -removed \(aws)
        +clean line
        """
        #expect(SecretScan.findings(diff: diff, knownValues: [("STRIPE_KEY", "sk_test_abcdef123456")]).isEmpty)
        // The `+++` file header is not an added line; a path that looks like a key is reported as a file name (4-wire fix 1, M3).
        #expect(SecretScan.findings(diff: "--- a/x\n+++ b/\(aws)\n", knownValues: []) == ["aws-key in a file name"])
        #expect(SecretScan.findings(diff: "--- a/x\n+++ b/plain.txt\n", knownValues: []).isEmpty)
        #expect(SecretScan.findings(diff: "+\(aws)\n", knownValues: []).count == 1)
        #expect(SecretScan.findings(diff: "", knownValues: []).isEmpty)
    }

    @Test func knownValueFoundByNameNeverByValue() {
        let value = "correct-horse-battery"
        let diff = "+++ b/config.yml\n+password: \(value)\n+other: fine\n"
        let found = SecretScan.findings(diff: diff, knownValues: [("DB_PASS", value)])
        #expect(found.count == 1); #expect(found[0].contains("DB_PASS")); #expect(!found[0].contains(value))
        // Short values are not scanned for (they would match everywhere), and absent values do not match.
        #expect(SecretScan.findings(diff: "+abc1234\n", knownValues: [("TINY", "abc1234")]).isEmpty)
        #expect(SecretScan.findings(diff: diff, knownValues: [("OTHER", "not-in-the-diff")]).isEmpty)
        // The percent-encoded form is found too.
        let enc = SecretScan.findings(diff: "+url=?pw=p%40ss%2Fword99\n", knownValues: [("DB_PASS", "p@ss/word99")])
        #expect(enc.count == 1 && enc[0].contains("DB_PASS"))
    }

    // MARK: child environment

    @Test func childEnvironmentInjectsSecretsAfterTheDrop() {
        let base = ["PATH": "/bin", "HOME": "/h", "STRIPE_KEY": "inherited", "AWS_SECRET_ACCESS_KEY": "inherited"]
        // Nothing is injected by default, and the drop step still removes inherited secrets.
        let plain = ChildEnvironment.make(base: base, extra: [:], purpose: .general)
        #expect(plain["STRIPE_KEY"] == nil); #expect(plain["AWS_SECRET_ACCESS_KEY"] == nil)
        // An injected secret survives the drop (its name contains KEY) and replaces an inherited one.
        let env = ChildEnvironment.make(base: base, extra: ["BRAHMA_AGENT_ID": "a1"], purpose: .claude,
                                        secrets: ["STRIPE_KEY": "sk_test_abcdef123456", "TEST_TOKEN": "tok"])
        #expect(env["STRIPE_KEY"] == "sk_test_abcdef123456"); #expect(env["TEST_TOKEN"] == "tok")
        #expect(env["AWS_SECRET_ACCESS_KEY"] == nil); #expect(env["PATH"] == "/bin"); #expect(env["BRAHMA_AGENT_ID"] == "a1")
        // A secret can never overwrite the engine's own variables or the basics.
        let hostile = ChildEnvironment.make(base: base, extra: ["BRAHMA_AGENT_ID": "a1"], purpose: .general,
                                            secrets: ["BRAHMA_AGENT_ID": "evil", "BRAHMA_DEV": "1", "PATH": "/evil", "HOME": "/evil"])
        #expect(hostile["BRAHMA_AGENT_ID"] == "a1"); #expect(hostile["BRAHMA_DEV"] == nil)
        #expect(hostile["PATH"] == "/bin"); #expect(hostile["HOME"] == "/h")
    }

    static let refusedInjectable = [
        "GIT_SSH_COMMAND", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "NODE_OPTIONS", "PYTHONPATH", "PATH", "BASH_FUNC_X",
        "CLAUDE_CODE_SHELL_PREFIX", "MY_LIB_PATH", "TEST_NAME",
        // Allowlisted by KEY/TOKEN/SECRET, then caught by a denied family.
        "GIT_TOKEN", "SSH_KEY", "DYLD_KEY", "LD_KEY", "BASH_FUNC_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "BRAHMA_SECRET",
        "ANTHROPIC_API_KEY", "NODE_AUTH_TOKEN", "NPM_TOKEN", "PYTHON_KEY", "PERL5_KEY", "RUBY_TOKEN", "JAVA_KEY", "XDG_SECRET",
        "MY_KEY_OPTIONS", "SECRET_LIB", "TOKEN_PATH", "SSL_KEYLOG_FILE", "SSLKEYLOGFILE", "LC_KEY",
        // Exact names and the base allowlist (none contains KEY/TOKEN/SECRET, so the allowlist already refuses them).
        "HOME", "SHELL", "ENV", "BASH_ENV", "ZDOTDIR", "PROMPT_COMMAND", "IFS", "TMPDIR", "LANG", "TERM", "USER", "LOGNAME",
    ]

    @Test(arguments: SecretTests.refusedInjectable)
    func refusedInjectableNames(_ name: String) throws {
        #expect(!SecretName.isInjectable(name), "\(name)")
        let w = try W()
        if SecretName.isValid(name) {
            #expect(throws: SecretError.notInjectable) {
                try w.store.setSecret(companyId: w.company.id, name: name, value: "some-value-123", isTest: true, vault: w.vault)
            }
        }
        #expect(try w.store.secrets(companyId: w.company.id).isEmpty)
        #expect(try w.vault.value(companyId: w.company.id, name: name) == nil, "refused before the vault is touched")
        // A row written by other means cannot bypass it: the child environment drops the name and reports it.
        let env = ChildEnvironment.make(base: ["PATH": "/bin", "HOME": "/h"], extra: [:], purpose: .claude, secrets: [name: "evil"])
        #expect(env[name] != "evil")
        #expect(ChildEnvironment.droppedSecretNames([name: "evil", "STRIPE_TEST_KEY": "v"]) == [name])
    }

    @Test(arguments: ["STRIPE_TEST_KEY", "GITHUB_TOKEN_TEST", "AWS_SECRET_ACCESS_KEY", "API_KEY", "MY_TOKEN", "TEST_SECRET",
                      "OPENAI_API_KEY", "AWS_SESSION_TOKEN"])
    func acceptedInjectableNames(_ name: String) throws {
        #expect(SecretName.isInjectable(name), "\(name)")
        let w = try W()
        try w.store.setSecret(companyId: w.company.id, name: name, value: "some-value-123", isTest: true, vault: w.vault)
        #expect(ChildEnvironment.make(base: [:], extra: [:], purpose: .general, secrets: [name: "v"])[name] == "v")
        #expect(ChildEnvironment.droppedSecretNames([name: "v"]).isEmpty)
    }

    @Test func engineHeldSecretsKeepThePlainNameRules() throws {
        // An engine-held secret is never injected, so only the name pattern and the reserved names apply to it.
        let w = try W()
        try w.store.setSecret(companyId: w.company.id, name: "PLAIN_NAME", value: "some-value-123", isTest: false, vault: w.vault)
        #expect(throws: SecretError.reservedName) {
            try w.store.setSecret(companyId: w.company.id, name: "PATH", value: "some-value-123", isTest: false, vault: w.vault)
        }
        // Turning it into a test key later goes through the injectable check.
        #expect(throws: SecretError.notInjectable) {
            try w.store.setSecret(companyId: w.company.id, name: "PLAIN_NAME", value: "some-value-123", isTest: true, vault: w.vault)
        }
        #expect(try w.store.secrets(companyId: w.company.id).map(\.isTest) == [false])
    }

    // MARK: CLI input

    @Test func cliSecretSetReadsStdin() throws {
        func read(_ text: String) throws -> String {
            let pipe = Pipe()
            pipe.fileHandleForWriting.write(Data(text.utf8))
            try pipe.fileHandleForWriting.close()
            return try SecretInput.read(from: pipe.fileHandleForReading)
        }
        #expect(try read("sk_test_abcdef123456\n") == "sk_test_abcdef123456")
        #expect(try read("no-newline-value") == "no-newline-value")
        #expect(try read("crlf-value\r\n") == "crlf-value")
        #expect(try read("keeps inner spaces\n") == "keeps inner spaces")
        #expect(try read("  padded  \n") == "  padded  ")
        #expect(try read("multi\nline\n") == "multi\nline")   // only the one trailing newline goes
        #expect(throws: SecretError.emptyValue) { _ = try read("") }
        #expect(throws: SecretError.emptyValue) { _ = try read("\n") }
    }
}

@Suite(.scratch) struct SecretCLITests {
    private func brahma(_ args: [String], home: URL, env: [String: String] = [:], stdin: String? = nil) throws
        -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = brahmaExecutableURL()
        p.arguments = args
        var e = cliEnvironment(home: home)
        e.merge(env) { _, new in new }
        p.environment = e
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        try p.run()
        if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
        try inp.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
    }

    /// The CLI's secret store is the file store in test homes (`cliEnvironment`): set, list, a redacted owner message, rm.
    @Test func secretCommandsUseTheFileStoreAndRedactCLIWrites() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        let set = try brahma(["secret", "set", "Acme", "API_KEY"], home: home, stdin: "cli-secret-value-42\n")
        #expect(set.status == 0, "\(set.stderr)")
        #expect(set.stderr.contains("using a file-backed secret store (dev/demo home only)"))
        let dataHome = ownerPaths(home).home
        let file = dataHome.appending(path: "secrets/vault.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dataHome.appending(path: "secrets").path)
        #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try brahma(["secret", "list", "Acme"], home: home).stdout.contains("API_KEY"))
        // Another CLI process loads the secrets before it writes: the owner's message is stored redacted.
        let say = try brahma(["say", "Acme", "#general", "the key is cli-secret-value-42"], home: home)
        #expect(say.status == 0, "\(say.stderr)")
        let log = try brahma(["log", "Acme", "#general"], home: home)
        #expect(log.stdout.contains("the key is [redacted API_KEY]")); #expect(!log.stdout.contains("cli-secret-value-42"))
        let db = try Data(contentsOf: dataHome.appending(path: "brahma.sqlite"))
        #expect(db.range(of: Data("cli-secret-value-42".utf8)) == nil)
        // A refused store choice fails the command instead of falling back.
        let unknown = try brahma(["secret", "list", "Acme"], home: home, env: ["BRAHMA_SECRET_STORE": "plaintext"])
        #expect(unknown.status == 1); #expect(unknown.stderr.contains("BRAHMA_SECRET_STORE=plaintext is not supported"))
        // `brahma secret load` reads every secret (interactively in production) and reports.
        let load = try brahma(["secret", "load", "Acme"], home: home)
        #expect(load.status == 0, "\(load.stderr)"); #expect(load.stdout.contains("loaded 1 secret"))
        // The memory store is refused by the CLI (its values would vanish with the process).
        let memory = try brahma(["secret", "list", "Acme"], home: home, env: ["BRAHMA_SECRET_STORE": "memory"])
        #expect(memory.status == 1); #expect(memory.stderr.contains("BRAHMA_SECRET_STORE=memory"), "\(memory.stderr)")
        // Lazy loading: with an unreadable vault, read-only commands still work and never mention secrets; a write fails closed.
        try Data("not json".utf8).write(to: file)
        let readOnly = try brahma(["log", "Acme", "#general"], home: home)
        #expect(readOnly.status == 0, "\(readOnly.stderr)"); #expect(!readOnly.stderr.contains("secret"), "\(readOnly.stderr)")
        #expect(try brahma(["secret", "list", "Acme"], home: home).status == 0)
        let write = try brahma(["say", "Acme", "#general", "hello"], home: home)
        #expect(write.status != 0); #expect(write.stderr.contains("secrets are not loaded yet"), "\(write.stderr)")
        // The lazy loader's line says why, by reason (the same wording as the owner notice): a corrupt vault is not a
        // permission problem, so it points at `secret set` / `secret rm`, and names the secret, never a value.
        #expect(write.stderr.contains("API_KEY (the secrets vault failed: the vault file is corrupt)"), "\(write.stderr)")
        #expect(write.stderr.contains("brahma secret set"), "\(write.stderr)")
        let failedLoad = try brahma(["secret", "load", "Acme"], home: home)
        #expect(failedLoad.status == 1); #expect(failedLoad.stderr.contains("API_KEY"), "\(failedLoad.stderr)")
        try FileManager.default.removeItem(at: file)
        let rm = try brahma(["secret", "rm", "Acme", "API_KEY"], home: home)
        #expect(rm.status == 0, "\(rm.stderr)")
        #expect(try brahma(["secret", "list", "Acme"], home: home).stdout.contains("no secrets"))
    }

    /// `brahma secret provide <co> A-<n>` answers an agent's request: the value goes to the vault, the ask is approved.
    @Test func secretProvideAnswersTheAsk() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        let paths = ownerPaths(home)
        let store = try Store(path: paths.database.path)
        let company = try #require(try store.companies().first)
        let eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        let ask = try store.requestSecret(companyId: company.id, agentId: eng.id, name: "PROVIDED_KEY", reason: "r", test: true).ask
        try store.close()
        let missing = try brahma(["secret", "provide", "Acme", "A-9"], home: home, stdin: "x\n")
        #expect(missing.status == 1); #expect(missing.stderr.contains("no ask A-9"), "\(missing.stderr)")
        let provide = try brahma(["secret", "provide", "Acme", ask.ref, "--test"], home: home, stdin: "provided-cli-value-77\n")
        #expect(provide.status == 0, "\(provide.stderr)"); #expect(provide.stdout.contains("provided PROVIDED_KEY")); #expect(provide.stdout.contains("\(ask.ref) approved"))
        let list = try brahma(["secret", "list", "Acme"], home: home)
        #expect(list.stdout.contains("PROVIDED_KEY  test"), Comment(rawValue: list.stdout))
        let again = try brahma(["secret", "provide", "Acme", ask.ref], home: home, stdin: "another-value-77\n")
        #expect(again.status == 1); #expect(again.stderr.contains("already approved"), "\(again.stderr)")
        let db = try Data(contentsOf: paths.database)
        #expect(db.range(of: Data("provided-cli-value-77".utf8)) == nil)
    }

    // None of these reach the Keychain: they fail before the vault is touched, or only read metadata.
    @Test func secretCommandsGuardTheirInputs() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        let list = try brahma(["secret", "list", "Acme"], home: home)
        #expect(list.status == 0, "\(list.stderr)"); #expect(list.stdout.contains("no secrets"))
        let bad = try brahma(["secret", "set", "Acme", "lower"], home: home, stdin: "value-value-1\n")
        #expect(bad.status == 1); #expect(bad.stderr.contains("invalid secret name"))
        let empty = try brahma(["secret", "set", "Acme", "OK_NAME"], home: home, stdin: "\n")
        #expect(empty.status == 1); #expect(empty.stderr.contains("empty"))
        let nocompany = try brahma(["secret", "set", "Nope", "OK_NAME"], home: home, stdin: "value-value-1\n")
        #expect(nocompany.status == 1); #expect(nocompany.stderr.contains("no company"))
        #expect(try brahma(["secret", "list", "Acme"], home: home).stdout.contains("no secrets"))
        for args in [["secret", "set", "Acme", "OK_NAME"], ["secret", "rm", "Acme", "OK_NAME"]] {
            let inAgent = try brahma(args, home: home, env: ["BRAHMA_AGENT_ID": "a1"], stdin: "value-value-1\n")
            #expect(inAgent.status == 1, "\(args)")
            #expect(inAgent.stderr.contains("owner commands can't run inside an agent turn"), "\(args): \(inAgent.stderr)")
        }
    }
}

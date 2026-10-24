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

struct PatternSample: Sendable, CustomTestStringConvertible {
    let label: String, sample: String
    var testDescription: String { label }
}

private let aws = "AKIA" + "ABCDEFGHIJKLMNOP"   // split so this file does not itself trip a scanner

@Suite struct SecretTests {
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
        _ = SecretVaults.platformDefault()   // constructs without touching anything
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
        // A vault that lost a value does not abort the reload; the rest still redact.
        try w.vault.delete(companyId: w.other.id, name: "OTHER_KEY")
        try w.set("NEW_KEY", "brand-new-value-xx")
        #expect(try w.store.reloadRedactorIfNeeded(vault: w.vault))
        #expect(w.store.redactor.apply("brand-new-value-xx sk_test_abcdef123456") == "[redacted NEW_KEY] [redacted STRIPE_KEY]")
    }

    @Test func reloadWithUnavailableVaultKeepsTheOldSet() throws {
        let w = try W()
        try w.set()
        _ = try w.store.reloadRedactorIfNeeded(vault: w.vault)
        try w.set("NEW_KEY", "brand-new-value-xx")
        #expect(throws: (any Error).self) { _ = try w.store.reloadRedactorIfNeeded(vault: UnavailableVault()) }
        #expect(w.store.redactor.apply("sk_test_abcdef123456") == "[redacted STRIPE_KEY]")
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
        // The `+++` file header is not an added line, even when the path looks like a key.
        #expect(SecretScan.findings(diff: "--- a/x\n+++ b/\(aws)\n", knownValues: []).isEmpty)
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

@Suite struct SecretCLITests {
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

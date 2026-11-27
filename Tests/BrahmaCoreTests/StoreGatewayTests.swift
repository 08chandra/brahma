import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan X1 Task 5: migration `"vX1-gateway"` and the gateway's store API — providers, caps, charges, routes, probes, prices,
/// billing mode, pacing preset, the provider-policy switch and the unattended-subscription opt-in (Rulings 7′, 12, 13, 34).
@Suite(.scratch) struct StoreGatewayTests {
    private func store() throws -> (Store, Company, Company) {
        let store = try Store.inMemory()
        let root = try tempDir()
        let acme = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: root)
        let beta = try store.createCompany(name: "Beta", goal: "g", workspacesRoot: root)
        return (store, acme, beta)
    }

    /// `y-M-d H:m` in `zone`.
    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, in zone: String) throws -> Date {
        let tz: TimeZone = try #require(TimeZone(identifier: zone))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return try #require(cal.date(from: DateComponents(timeZone: tz, year: y, month: mo, day: d, hour: h, minute: mi)))
    }

    private func charge(_ company: Company, provider: String = "anthropic", usd: Double, at: Date,
                        state: GatewayCharge.State = .settled) -> GatewayCharge {
        GatewayCharge(companyId: company.id, turnId: "t1", itemId: nil, agentId: "a1", provider: provider, model: "m",
                      inputTokens: 10, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0, usd: usd, estimated: false,
                      state: state, at: at)
    }

    // MARK: Migration

    @Test func migrationSeedsBuiltins() throws {
        let (store, _, _) = try store()
        let names = Migrations.migrator().migrations
        #expect(names.last == "vX1-gateway")
        #expect(names.firstIndex(of: "vX1-gateway") == names.firstIndex(of: "vC-changes-quote").map { $0 + 1 })
        let providers = try store.providers()
        #expect(providers.map(\.id) == ["anthropic", "groq", "openai", "openrouter"])
        let expected: [String: (String, String, String, String)] = [
            "anthropic": ("anthropic", "https://api.anthropic.com", "api.anthropic.com", "ANTHROPIC_API_KEY"),
            "openai": ("openai-compatible", "https://api.openai.com/v1", "api.openai.com", "BRAHMA_KEY_OPENAI"),
            "openrouter": ("openai-compatible", "https://openrouter.ai/api/v1", "openrouter.ai", "BRAHMA_KEY_OPENROUTER"),
            "groq": ("openai-compatible", "https://api.groq.com/openai/v1", "api.groq.com", "BRAHMA_KEY_GROQ"),
        ]
        for p in providers {
            let e = try #require(expected[p.id])
            #expect(p.adapter == e.0, "\(p.id)")
            #expect(p.baseURL.absoluteString == e.1, "\(p.id)")
            #expect(p.host == e.2, "\(p.id)")
            #expect(p.keySecret == e.3, "\(p.id)")
            #expect(p.builtin && !p.lan)
        }
        #expect(try store.provider(id: "groq")?.host == "api.groq.com")
        #expect(try store.provider(id: "nope") == nil)
        #expect(try store.providerKeyNames() == ["ANTHROPIC_API_KEY", "BRAHMA_KEY_OPENAI", "BRAHMA_KEY_OPENROUTER", "BRAHMA_KEY_GROQ"])
    }

    /// The new columns on existing tables, with their defaults; `gatewayCharge.state` defaults to `settled` (Ruling 12).
    @Test func newColumnsHaveTheirDefaults() throws {
        let (store, acme, _) = try store()
        try store.writer.read { db in
            func columns(_ t: String) throws -> [String: ColumnInfo] {
                Dictionary(uniqueKeysWithValues: try db.columns(in: t).map { ($0.name, $0) })
            }
            let turn = try columns("turn")
            for c in ["runtime", "authRoute", "provider", "routedModel", "meteredUSD"] { #expect(turn[c]?.isNotNull == false, "turn.\(c)") }
            #expect(try columns("itemFact")["meteredUSD"]?.defaultValueSQL == "0")
            let company = try columns("company")
            #expect(company["billingMode"]?.defaultValueSQL == "'subscription'")
            #expect(company["unattendedSubscription"]?.defaultValueSQL == "0")
            #expect(company["unattendedSubscriptionAt"]?.isNotNull == false)
            let owner = try columns("ownerSettings")
            #expect(owner["pacingPreset"]?.defaultValueSQL == "'conservative'")
            #expect(owner["subscriptionAllowed"]?.defaultValueSQL == "1")
            #expect(owner["dayStartUtil"]?.isNotNull == false && owner["dayStartDate"]?.isNotNull == false)
        }
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO gatewayCharge (companyId, provider, model, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens,
                  usd, estimated, at) VALUES (?, 'anthropic', 'm', 1, 1, 0, 0, 0.5, 0, ?)
                """, arguments: [acme.id, Date()])
            #expect(try String.fetchOne(db, sql: "SELECT state FROM gatewayCharge") == "settled")
            let indexes = try db.indexes(on: "gatewayCharge").map(\.columns)
            #expect(indexes.contains(["companyId", "provider", "at"]))
        }
    }

    // MARK: Billing, pacing, provider policy

    @Test func billingDefaultsToSubscription() throws {
        let (store, acme, beta) = try store()
        #expect(try store.billingMode(companyId: acme.id) == .subscription)
        #expect(try store.company(id: acme.id)?.billingMode == .subscription)
        try store.setBillingMode(.apiKey, companyId: acme.id)
        #expect(try store.billingMode(companyId: acme.id) == .apiKey)
        #expect(try store.billingMode(companyId: beta.id) == .subscription)
        let raw = try store.writer.read { db in try String.fetchOne(db, sql: "SELECT billingMode FROM company WHERE id = ?", arguments: [acme.id]) }
        #expect(raw == "api-key")
        // An ordinary company update never overwrites it.
        var copy = try #require(try store.company(id: acme.id))
        copy.billingMode = .subscription
        try store.updateCompany(copy)
        #expect(try store.billingMode(companyId: acme.id) == .apiKey)
        #expect(throws: (any Error).self) { try store.billingMode(companyId: "nope") }
        #expect(throws: (any Error).self) { try store.setBillingMode(.fallback, companyId: "nope") }
    }

    @Test func pacingDefaultsToConservative() throws {
        let (store, _, _) = try store()
        #expect(try store.pacingPreset() == .conservative)
        try store.setPacingPreset(.full)
        #expect(try store.pacingPreset() == .full)
        try store.setPacingPreset(.standard)
        #expect(try store.pacingPreset() == .standard)
    }

    /// Ruling 7b: the owner-wide provider-policy switch, on by default.
    @Test func subscriptionAllowedDefaultsOn() throws {
        let (store, _, _) = try store()
        #expect(try store.subscriptionAllowed())
        try store.setSubscriptionAllowed(false)
        #expect(try !store.subscriptionAllowed())
        try store.setSubscriptionAllowed(true)
        #expect(try store.subscriptionAllowed())
    }

    /// Ruling 7′: the unattended-subscription opt-in is recorded with its time, and cleared with it.
    @Test func unattendedSubscriptionOptInIsRecorded() throws {
        let (store, acme, beta) = try store()
        #expect(try !store.unattendedSubscription(companyId: acme.id))
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        try store.setUnattendedSubscription(true, companyId: acme.id, now: at)
        let c = try #require(try store.company(id: acme.id))
        #expect(c.unattendedSubscription && c.unattendedSubscriptionAt == at)
        #expect(try !store.unattendedSubscription(companyId: beta.id))
        try store.setUnattendedSubscription(false, companyId: acme.id, now: at)
        let off = try #require(try store.company(id: acme.id))
        #expect(!off.unattendedSubscription && off.unattendedSubscriptionAt == nil)
    }

    /// The owner's settings never change from an agent process (Ruling C6-4); the engine's own writes (charges, probes) do.
    @Test func ownerSettersRefuseInAnAgentProcess() throws {
        let (store, acme, _) = try store()
        try OwnerPrincipal.simulatingAgentProcess {
            let refusals: [() throws -> Void] = [
                { try store.setBillingMode(.apiKey, companyId: acme.id) },
                { try store.setUnattendedSubscription(true, companyId: acme.id) },
                { try store.setSubscriptionAllowed(true) },
                { try store.setPacingPreset(.full) },
                { try store.setProviderCaps(ProviderCaps(monthlyUSD: 100), companyId: acme.id, provider: "anthropic") },
                { try store.setRoute(ModelRoute(companyId: acme.id, scope: .company, subject: "", modelClass: "fast",
                                                provider: "groq", model: "m")) },
                { try store.clearRoutes(companyId: acme.id, scope: .company, subject: "") },
                { try store.setPriceRow(PriceRow(provider: "groq", model: "m", inPerMTok: 1, outPerMTok: 2, setBy: "owner")) },
                { try store.addProvider(Provider(id: "local", adapter: "openai-compatible", baseURL: URL(string: "https://x.example.com")!,
                                                 host: "x.example.com", keySecret: nil, createdAt: Date())) },
                { try store.removeProvider(id: "groq") },
            ]
            for (i, refused) in refusals.enumerated() {
                #expect(throws: WorkError.self, "setter \(i)") { try refused() }
            }
            try store.recordCharge(charge(acme, usd: 1, at: Date()))
            _ = try store.queueProbe(provider: "groq", model: "m", requestedBy: "a1", companyId: acme.id)
        }
        #expect(try store.billingMode(companyId: acme.id) == .subscription)
        #expect(try store.pacingPreset() == .conservative)
        #expect(try store.provider(id: "groq") != nil)
    }

    // MARK: Spend

    /// Charges at 23:59 and 00:01 owner time fall on different days (both are the same UTC day, so the owner's zone decides);
    /// another company's charge and another provider's never count.
    @Test func spendSumsByOwnerDay() throws {
        let (store, acme, beta) = try store()
        try store.setOwnerTimeZone("America/Los_Angeles")
        let zone = "America/Los_Angeles"
        let late = try date(2026, 11, 14, 23, 59, in: zone), early = try date(2026, 11, 15, 0, 1, in: zone)
        try store.recordCharge(charge(acme, usd: 1.25, at: late))
        try store.recordCharge(charge(acme, usd: 2.5, at: early))
        try store.recordCharge(charge(acme, usd: 0.5, at: early, state: .reserved))   // a reservation counts until settled
        try store.recordCharge(charge(beta, usd: 100, at: early))
        try store.recordCharge(charge(acme, provider: "groq", usd: 7, at: early))
        let noon15 = try date(2026, 11, 15, 12, 0, in: zone), noon14 = try date(2026, 11, 14, 12, 0, in: zone)
        #expect(try store.spend(companyId: acme.id, provider: "anthropic", period: .day, now: noon15) == 3.0)
        #expect(try store.spend(companyId: acme.id, provider: "anthropic", period: .day, now: noon14) == 1.25)
        #expect(try store.spend(companyId: acme.id, provider: "anthropic", period: .month, now: noon15) == 4.25)
        #expect(try store.spend(companyId: acme.id, provider: "groq", period: .day, now: noon15) == 7)
        #expect(try store.spend(companyId: beta.id, provider: "anthropic", period: .day, now: noon15) == 100)
        #expect(try store.spend(companyId: beta.id, provider: "anthropic", period: .day, now: noon14) == 0)
        // The month splits at the owner's midnight too.
        let monthEnd = try date(2026, 11, 30, 23, 59, in: zone), monthStart = try date(2026, 12, 1, 0, 1, in: zone)
        try store.recordCharge(charge(beta, usd: 3, at: monthEnd))
        try store.recordCharge(charge(beta, usd: 4, at: monthStart))
        #expect(try store.spend(companyId: beta.id, provider: "anthropic", period: .month, now: monthStart) == 4)
        #expect(try store.spend(companyId: beta.id, provider: "anthropic", period: .month, now: monthEnd) == 103)
        // A recorded charge gets an id; a charge for an unknown company is refused.
        let id = try store.recordCharge(charge(acme, usd: 0, at: early))
        #expect(id > 0)
        var stranger = charge(acme, usd: 1, at: early)
        stranger.companyId = "nope"
        #expect(throws: (any Error).self) { try store.recordCharge(stranger) }
    }

    // MARK: Caps and providers

    @Test func capsAreCompanyScoped() throws {
        let (store, acme, beta) = try store()
        #expect(try store.providerCaps(companyId: acme.id, provider: "anthropic") == nil)
        try store.setProviderCaps(ProviderCaps(monthlyUSD: 200), companyId: acme.id, provider: "anthropic")
        #expect(try store.providerCaps(companyId: acme.id, provider: "anthropic") == ProviderCaps(monthlyUSD: 200, dailyUSD: 10))
        #expect(try store.providerCaps(companyId: beta.id, provider: "anthropic") == nil)
        #expect(try store.providerCaps(companyId: acme.id, provider: "groq") == nil)
        try store.setProviderCaps(ProviderCaps(monthlyUSD: 50, dailyUSD: 5), companyId: beta.id, provider: "anthropic")
        try store.setProviderCaps(ProviderCaps(monthlyUSD: 300, dailyUSD: 30), companyId: acme.id, provider: "anthropic")
        #expect(try store.providerCaps(companyId: acme.id, provider: "anthropic") == ProviderCaps(monthlyUSD: 300, dailyUSD: 30))
        #expect(try store.providerCaps(companyId: beta.id, provider: "anthropic") == ProviderCaps(monthlyUSD: 50, dailyUSD: 5))
        // Refused: a negative or non-finite cap, an unknown provider or company.
        #expect(throws: WorkError.self) { try store.setProviderCaps(ProviderCaps(monthlyUSD: -1), companyId: acme.id, provider: "anthropic") }
        #expect(throws: WorkError.self) { try store.setProviderCaps(ProviderCaps(monthlyUSD: .infinity), companyId: acme.id, provider: "anthropic") }
        #expect(throws: WorkError.self) { try store.setProviderCaps(ProviderCaps(monthlyUSD: 1), companyId: acme.id, provider: "nope") }
        #expect(throws: WorkError.self) { try store.setProviderCaps(ProviderCaps(monthlyUSD: 1), companyId: "nope", provider: "anthropic") }
    }

    private func custom(_ id: String = "local", key: String? = "BRAHMA_KEY_LOCAL") -> Provider {
        Provider(id: id, adapter: "openai-compatible", baseURL: URL(string: "https://llm.example.com/v1")!, host: "llm.example.com",
                 keySecret: key, builtin: true, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test func addProviderValidates() throws {
        let (store, _, _) = try store()
        try store.addProvider(custom())
        let stored = try #require(try store.provider(id: "local"))
        #expect(!stored.builtin, "an added provider is never built-in")
        #expect(stored.baseURL.absoluteString == "https://llm.example.com/v1" && stored.keySecret == "BRAHMA_KEY_LOCAL")
        #expect(try store.providerKeyNames().contains("BRAHMA_KEY_LOCAL"))
        #expect(throws: WorkError.self) { try store.addProvider(custom()) }                                   // duplicate
        #expect(throws: WorkError.self) { try store.addProvider(custom("Bad Id")) }
        #expect(throws: WorkError.self) { try store.addProvider(custom("x2", key: "OPENROUTER_API_KEY")) }  // not a provider key name
        #expect(throws: WorkError.self) { try store.addProvider(custom("x3", key: "BRAHMA_KEY_")) }
        try store.addProvider(custom("x4", key: nil))
        #expect(Provider.isKeyName("ANTHROPIC_API_KEY") && Provider.isKeyName("BRAHMA_KEY_OPEN_ROUTER2"))
        #expect(!Provider.isKeyName("BRAHMA_KEY_lower") && !Provider.isKeyName("OPENAI_API_KEY") && !Provider.isKeyName("ANTHROPIC_AUTH_TOKEN"))
    }

    @Test func removeProviderRefusedWhileRouted() throws {
        let (store, acme, beta) = try store()
        try store.addProvider(custom())
        try store.setRoute(ModelRoute(companyId: acme.id, scope: .company, subject: "", modelClass: "fast", provider: "local", model: "m"))
        #expect(throws: WorkError.self) { try store.removeProvider(id: "local") }
        try store.clearRoutes(companyId: acme.id, scope: .company, subject: "")
        try store.setProviderCaps(ProviderCaps(monthlyUSD: 10), companyId: beta.id, provider: "local")
        #expect(throws: WorkError.self) { try store.removeProvider(id: "local") }
        try store.writer.write { db in try db.execute(sql: "DELETE FROM providerCap") }
        try store.removeProvider(id: "local")
        #expect(try store.provider(id: "local") == nil)
        #expect(throws: WorkError.self) { try store.removeProvider(id: "local") }
    }

    @Test func builtinCannotBeRemoved() throws {
        let (store, _, _) = try store()
        for id in ["anthropic", "openai", "openrouter", "groq"] {
            #expect(throws: WorkError.self) { try store.removeProvider(id: id) }
            #expect(try store.provider(id: id) != nil)
        }
    }

    // MARK: Routes

    @Test func routesRoundTripPerScope() throws {
        let (store, acme, beta) = try store()
        let company = ModelRoute(companyId: acme.id, scope: .company, subject: "", modelClass: "fast", provider: "groq", model: "llama")
        let role = ModelRoute(companyId: acme.id, scope: .role, subject: "engineer", modelClass: "deep", provider: "anthropic", model: "opus")
        let agent = ModelRoute(companyId: acme.id, scope: .agent, subject: "agent-1", modelClass: "fast", provider: "openrouter", model: "x")
        let agentDeep = ModelRoute(companyId: acme.id, scope: .agent, subject: "agent-1", modelClass: "deep", provider: "anthropic", model: "y")
        for r in [agent, company, role, agentDeep] { try store.setRoute(r) }
        #expect(try store.routes(companyId: acme.id) == [company, role, agentDeep, agent])
        #expect(try store.routes(companyId: beta.id).isEmpty)
        // Same key: replaced.
        var moved = company
        moved.provider = "openai"; moved.model = "gpt"
        try store.setRoute(moved)
        #expect(try store.routes(companyId: acme.id).first == moved)
        // Clearing one subject leaves the others.
        try store.clearRoutes(companyId: acme.id, scope: .agent, subject: "agent-1")
        #expect(try store.routes(companyId: acme.id) == [moved, role])
        // Refused: a company route with a subject, a role/agent route without one, an unknown provider or company, an empty class/model.
        var bad = company; bad.subject = "x"
        #expect(throws: WorkError.self) { try store.setRoute(bad) }
        bad = role; bad.subject = ""
        #expect(throws: WorkError.self) { try store.setRoute(bad) }
        bad = role; bad.provider = "nope"
        #expect(throws: WorkError.self) { try store.setRoute(bad) }
        bad = role; bad.companyId = "nope"
        #expect(throws: WorkError.self) { try store.setRoute(bad) }
        bad = role; bad.model = ""
        #expect(throws: WorkError.self) { try store.setRoute(bad) }
        bad = role; bad.modelClass = ""
        #expect(throws: WorkError.self) { try store.setRoute(bad) }
    }

    // MARK: Probes and prices

    @Test func probesRoundTripAndQueue() throws {
        let (store, acme, _) = try store()
        let record = ModelProbeRecord(provider: "groq", model: "llama", adapterVersion: "1", cliVersion: "2.1.0", level: .textOnly,
                                      steps: [ProbeStepResult(step: "streaming", passed: true, score: "1/1", detail: "ok"),
                                              ProbeStepResult(step: "tools", passed: false, score: "12/20", detail: "too few")],
                                      declaredContext: 131_072, probedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try store.saveProbe(record)
        #expect(try store.probeRecord(provider: "groq", model: "llama", adapterVersion: "1", cliVersion: "2.1.0") == record)
        #expect(try store.probeRecord(provider: "groq", model: "llama", adapterVersion: "1", cliVersion: "2.2.0") == nil)
        var again = record
        again.level = .agent; again.declaredContext = nil
        try store.saveProbe(again)
        #expect(try store.probeRecord(provider: "groq", model: "llama", adapterVersion: "1", cliVersion: "2.1.0") == again)

        #expect(try store.nextQueuedProbe() == nil)
        let first = try store.queueProbe(provider: "groq", model: "llama", requestedBy: "owner", companyId: nil)
        let second = try store.queueProbe(provider: "openrouter", model: "x", requestedBy: "a1", companyId: acme.id)
        #expect(try store.queueProbe(provider: "groq", model: "llama", requestedBy: "owner", companyId: nil) == first, "a queued duplicate is reused")
        let next = try #require(try store.nextQueuedProbe())
        #expect(next.id == first && next.provider == "groq" && next.status == .queued && next.companyId == nil)
        try store.finishProbeRequest(id: first, status: .done)
        #expect(try store.nextQueuedProbe()?.id == second)
        #expect(try store.nextQueuedProbe()?.companyId == acme.id)
        #expect(throws: WorkError.self) { try store.finishProbeRequest(id: first, status: .failed) }   // already finished
        #expect(throws: WorkError.self) { try store.finishProbeRequest(id: second, status: .queued) }
        #expect(throws: WorkError.self) { try store.finishProbeRequest(id: "nope", status: .done) }
        try store.finishProbeRequest(id: second, status: .failed)
        #expect(try store.nextQueuedProbe() == nil)
        #expect(throws: WorkError.self) { try store.queueProbe(provider: "nope", model: "m", requestedBy: "owner", companyId: nil) }
        #expect(throws: WorkError.self) { try store.queueProbe(provider: "groq", model: "m", requestedBy: "owner", companyId: "nope") }
    }

    @Test func priceRowsRoundTrip() throws {
        let (store, _, _) = try store()
        #expect(try store.priceRows().isEmpty)
        let a = PriceRow(provider: "groq", model: "llama", inPerMTok: 0.59, outPerMTok: 0.79, setBy: "owner")
        let b = PriceRow(provider: "anthropic", model: "claude-x", inPerMTok: 3, outPerMTok: 15, cacheReadPerMTok: 0.3,
                         cacheWritePerMTok: 3.75, setBy: "owner")
        try store.setPriceRow(a)
        try store.setPriceRow(b)
        #expect(try store.priceRows() == [b, a])
        var cheaper = a
        cheaper.inPerMTok = 0.1
        try store.setPriceRow(cheaper)
        #expect(try store.priceRows() == [b, cheaper])
        var bad = a; bad.outPerMTok = -1
        #expect(throws: WorkError.self) { try store.setPriceRow(bad) }
        bad = a; bad.cacheReadPerMTok = .nan
        #expect(throws: WorkError.self) { try store.setPriceRow(bad) }
        bad = a; bad.model = ""
        #expect(throws: WorkError.self) { try store.setPriceRow(bad) }
    }

    // MARK: Company scoping

    /// A deleted company takes its caps, charges, routes and probe requests with it.
    @Test func companyRowsCascade() throws {
        let (store, acme, _) = try store()
        try store.setProviderCaps(ProviderCaps(monthlyUSD: 10), companyId: acme.id, provider: "anthropic")
        try store.recordCharge(charge(acme, usd: 1, at: Date()))
        try store.setRoute(ModelRoute(companyId: acme.id, scope: .company, subject: "", modelClass: "fast", provider: "groq", model: "m"))
        _ = try store.queueProbe(provider: "groq", model: "m", requestedBy: "a1", companyId: acme.id)
        try store.writer.write { db in
            try db.execute(sql: "DELETE FROM company WHERE id = ?", arguments: [acme.id])
            for t in ["providerCap", "gatewayCharge", "modelRoute", "modelProbeRequest"] {
                #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(t)") == 0, "\(t)")
            }
        }
    }

    // MARK: Restore

    /// A restore never loosens the provider policy or the unattended opt-in: switched off after the snapshot, they stay off.
    @Test func restoreKeepsTheStricterSubscriptionSettings() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.store.setUnattendedSubscription(true, companyId: acme.id, now: Date(timeIntervalSince1970: 1_790_000_000))
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.setSubscriptionAllowed(false)
        try env.store.setUnattendedSubscription(false, companyId: acme.id)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try !restored.subscriptionAllowed())
        let company = try #require(try restored.company(id: acme.id))
        #expect(!company.unattendedSubscription && company.unattendedSubscriptionAt == nil)
        #expect(outcome.warnings.contains { $0.contains("owner-wide subscription turns kept off") }, "\(outcome.warnings)")
        #expect(outcome.warnings.contains { $0.contains("Acme: unattended subscription runs kept at off") }, "\(outcome.warnings)")
    }

    /// Ruling 35: the billing mode has no stricter direction, so a restore keeps the live mode either way, and says so.
    @Test func restoreKeepsTheLiveBillingMode() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme"), beta = try env.company("Beta")
        try env.store.setBillingMode(.apiKey, companyId: beta.id)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.setBillingMode(.apiKey, companyId: acme.id)          // snapshot subscription, live api-key
        try env.store.setBillingMode(.subscription, companyId: beta.id)    // snapshot api-key, live subscription
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.billingMode(companyId: acme.id) == .apiKey)
        #expect(try restored.billingMode(companyId: beta.id) == .subscription)
        #expect(outcome.warnings.contains { $0.contains("Acme: billing kept at api-key (the snapshot had subscription)") }, "\(outcome.warnings)")
        #expect(outcome.warnings.contains { $0.contains("Beta: billing kept at subscription (the snapshot had api-key)") }, "\(outcome.warnings)")
    }

    /// Ruling 35: owner-added providers follow the live set. One removed after the snapshot stays removed with its routes and
    /// caps; one re-added with another host keeps the live host; the built-ins are untouched.
    @Test func restoreFollowsTheLiveProviders() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        func provider(_ id: String, host: String) -> Provider {
            Provider(id: id, adapter: "openai-compatible", baseURL: URL(string: "https://\(host)/v1")!, host: host,
                     keySecret: "BRAHMA_KEY_\(id.uppercased())", createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        }
        try env.store.addProvider(provider("gone", host: "gone.example.com"))
        try env.store.addProvider(provider("edge", host: "a.example.com"))
        try env.store.setRoute(ModelRoute(companyId: acme.id, scope: .company, subject: "", modelClass: "fast", provider: "gone", model: "m"))
        try env.store.setProviderCaps(ProviderCaps(monthlyUSD: 10), companyId: acme.id, provider: "gone")
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.clearRoutes(companyId: acme.id, scope: .company, subject: "")
        try env.store.writer.write { db in try db.execute(sql: "DELETE FROM providerCap WHERE provider = 'gone'") }
        try env.store.removeProvider(id: "gone")
        try env.store.removeProvider(id: "edge")
        try env.store.addProvider(provider("edge", host: "b.example.com"))
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.provider(id: "gone") == nil)
        #expect(try restored.routes(companyId: acme.id).isEmpty)
        #expect(try restored.providerCaps(companyId: acme.id, provider: "gone") == nil)
        let edge = try #require(try restored.provider(id: "edge"))
        #expect(edge.host == "b.example.com" && edge.baseURL.absoluteString == "https://b.example.com/v1")
        #expect(try restored.providers().filter(\.builtin).map(\.id) == ["anthropic", "groq", "openai", "openrouter"])
        #expect(try !restored.providerKeyNames().contains("BRAHMA_KEY_GONE"))
        #expect(outcome.warnings.contains { $0.contains("provider gone, removed after the snapshot, stays removed with the routes and caps naming it") },
                "\(outcome.warnings)")
        #expect(outcome.warnings.contains { $0.contains("provider edge kept at https://b.example.com/v1 (host b.example.com") }, "\(outcome.warnings)")
    }
}

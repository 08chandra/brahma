import Foundation
import GRDB

/// Plan X1 Task 5 (`"vX1-gateway"`): billing mode, providers, caps, gateway charges, model routes, capability probes, owner
/// prices, the pacing preset, the provider-policy switch and the unattended-subscription opt-in. Every company-owned lookup is
/// `WHERE companyId = ?`. The owner's settings refuse in an agent process (Ruling C6-4); the engine's own writes (charges,
/// probe records and requests) do not.
extension Store {
    // MARK: Billing

    public func billingMode(companyId: String) throws -> BillingMode {
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        return company.billingMode
    }

    public func setBillingMode(_ mode: BillingMode, companyId: String) throws {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        try writer.write { db in
            try Self.requireCompany(db, companyId)
            try db.execute(sql: "UPDATE company SET billingMode = ? WHERE id = ?", arguments: [mode.rawValue, companyId])
        }
    }

    /// Whether the owner opted the company in to unattended runs on the subscription (Ruling 7′).
    public func unattendedSubscription(companyId: String) throws -> Bool {
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        return company.unattendedSubscription
    }

    /// Records the opt-in with its time (`now`), or clears both.
    public func setUnattendedSubscription(_ on: Bool, companyId: String, now: Date = Store.now()) throws {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        try writer.write { db in
            try Self.requireCompany(db, companyId)
            try db.execute(sql: "UPDATE company SET unattendedSubscription = ?, unattendedSubscriptionAt = ? WHERE id = ?",
                           arguments: [on, on ? now : nil, companyId])
        }
    }

    /// The owner-wide provider-policy switch (Ruling 7b): off, no company runs a subscription turn. On by default.
    public func subscriptionAllowed() throws -> Bool {
        try writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT subscriptionAllowed FROM ownerSettings WHERE id = 1") ?? true
        }
    }

    public func setSubscriptionAllowed(_ allowed: Bool) throws {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        try writer.write { db in
            try Store.ensureOwnerSettings(db)
            try db.execute(sql: "UPDATE ownerSettings SET subscriptionAllowed = ? WHERE id = 1", arguments: [allowed])
        }
    }

    // MARK: Pacing preset

    /// The owner-wide pacing preset; `conservative` when unset (or unreadable: the strictest preset).
    public func pacingPreset() throws -> PacingPresetName {
        let raw = try writer.read { db in try String.fetchOne(db, sql: "SELECT pacingPreset FROM ownerSettings WHERE id = 1") }
        return raw.flatMap(PacingPresetName.init(rawValue:)) ?? .conservative
    }

    public func setPacingPreset(_ preset: PacingPresetName) throws {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        try writer.write { db in
            try Store.ensureOwnerSettings(db)
            try db.execute(sql: "UPDATE ownerSettings SET pacingPreset = ? WHERE id = 1", arguments: [preset.rawValue])
        }
    }

    // MARK: Providers

    /// Every provider, by id.
    public func providers() throws -> [Provider] {
        try writer.read { db in try Row.fetchAll(db, sql: "SELECT * FROM provider ORDER BY id").map(Self.provider(from:)) }
    }

    public func provider(id: String) throws -> Provider? {
        try writer.read { db in try Row.fetchOne(db, sql: "SELECT * FROM provider WHERE id = ?", arguments: [id]).map(Self.provider(from:)) }
    }

    /// Adds an owner provider (never built-in, whatever `p.builtin` says). Refused: an id that is not 1–32 of `a-z0-9-` or is
    /// taken, an empty adapter or host, and a key name that is not a provider key name (`Provider.isKeyName`). The base URL and
    /// host rules are the gateway's (`ProviderHost`).
    public func addProvider(_ p: Provider) throws {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        guard Provider.isValidId(p.id) else { throw WorkError.invalid("provider id must be 1-32 of a-z, 0-9 and -") }
        guard !p.adapter.isEmpty, !p.host.isEmpty else { throw WorkError.invalid("provider \(p.id) needs an adapter and a host") }
        if let key = p.keySecret, !Provider.isKeyName(key) {
            throw WorkError.invalid("a provider key is named \(Provider.anthropicKeyName) or \(Provider.keyNamePrefix)<PROVIDER>")
        }
        try writer.write { db in
            guard try Row.fetchOne(db, sql: "SELECT 1 FROM provider WHERE id = ?", arguments: [p.id]) == nil else {
                throw WorkError.conflict("provider \(p.id) already exists")
            }
            try db.execute(sql: """
                INSERT INTO provider (id, adapter, baseURL, host, keySecret, lan, builtin, createdAt) VALUES (?, ?, ?, ?, ?, ?, 0, ?)
                """, arguments: [p.id, p.adapter, p.baseURL.absoluteString, p.host, p.keySecret, p.lan, p.createdAt])
        }
    }

    /// Removes an owner provider. Refused for a built-in, and while any company's route or cap names it.
    public func removeProvider(id: String) throws {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        try writer.write { db in
            guard let builtin = try Bool.fetchOne(db, sql: "SELECT builtin FROM provider WHERE id = ?", arguments: [id]) else {
                throw WorkError.notFound("no such provider: \(id)")
            }
            guard !builtin else { throw WorkError.forbidden("\(id) is a built-in provider and cannot be removed") }
            let routes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM modelRoute WHERE provider = ?", arguments: [id]) ?? 0
            let caps = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM providerCap WHERE provider = ?", arguments: [id]) ?? 0
            guard routes == 0, caps == 0 else {
                throw WorkError.conflict("provider \(id) is still named by \(routes) route(s) and \(caps) cap(s); clear them first")
            }
            try db.execute(sql: "DELETE FROM provider WHERE id = ?", arguments: [id])
        }
    }

    /// The vault names of every provider's key: never injected into a turn or a check.
    public func providerKeyNames() throws -> Set<String> {
        try writer.read { db in Set(try String.fetchAll(db, sql: "SELECT keySecret FROM provider WHERE keySecret IS NOT NULL")) }
    }

    // MARK: Caps

    public func providerCaps(companyId: String, provider: String) throws -> ProviderCaps? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT monthlyUSD, dailyUSD FROM providerCap WHERE companyId = ? AND provider = ?",
                             arguments: [companyId, provider])
                .map { ProviderCaps(monthlyUSD: $0["monthlyUSD"], dailyUSD: $0["dailyUSD"] as Double) }
        }
    }

    /// Refused: a negative or non-finite cap, an unknown company or provider.
    public func setProviderCaps(_ caps: ProviderCaps, companyId: String, provider: String) throws {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        guard [caps.monthlyUSD, caps.dailyUSD].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw WorkError.invalid("caps must be zero or more dollars")
        }
        try writer.write { db in
            try Self.requireCompany(db, companyId)
            try Self.requireProvider(db, provider)
            try db.execute(sql: """
                INSERT INTO providerCap (companyId, provider, monthlyUSD, dailyUSD) VALUES (?, ?, ?, ?)
                ON CONFLICT(companyId, provider) DO UPDATE SET monthlyUSD = excluded.monthlyUSD, dailyUSD = excluded.dailyUSD
                """, arguments: [companyId, provider, caps.monthlyUSD, caps.dailyUSD])
        }
    }

    // MARK: Charges

    /// Records a gateway charge; returns its id. Refused: a negative or non-finite amount, negative token counts.
    @discardableResult
    public func recordCharge(_ c: GatewayCharge) throws -> Int64 {
        guard c.usd.isFinite, c.usd >= 0 else { throw WorkError.invalid("a charge is zero or more dollars") }
        guard [c.inputTokens, c.outputTokens, c.cacheReadTokens, c.cacheWriteTokens].allSatisfy({ $0 >= 0 }) else {
            throw WorkError.invalid("token counts are zero or more")
        }
        return try writer.write { db in
            try Self.requireCompany(db, c.companyId)
            try db.execute(sql: """
                INSERT INTO gatewayCharge (companyId, turnId, itemId, agentId, provider, model, inputTokens, outputTokens,
                  cacheReadTokens, cacheWriteTokens, usd, estimated, state, at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [c.companyId, c.turnId, c.itemId, c.agentId, c.provider, c.model, c.inputTokens, c.outputTokens,
                                 c.cacheReadTokens, c.cacheWriteTokens, c.usd, c.estimated, c.state.rawValue, c.at])
            return db.lastInsertedRowID
        }
    }

    /// The company's spend with one provider in the owner's day or month holding `now` (the owner's time zone,
    /// `ownerTimeZone()`): every charge, reservations included.
    public func spend(companyId: String, provider: String, period: SpendPeriod, now: Date) throws -> Double {
        let (start, end) = try Self.spendWindow(period, now: now, zone: ownerTimeZone())
        return try writer.read { db in
            try Double.fetchOne(db, sql: """
                SELECT COALESCE(SUM(usd), 0) FROM gatewayCharge WHERE companyId = ? AND provider = ? AND at >= ? AND at < ?
                """, arguments: [companyId, provider, start, end]) ?? 0
        }
    }

    /// The owner-calendar day or month holding `now` in `zone`, as [start, end). Throws when the calendar has none: a
    /// guessed window could hold less than the month and let spend past a monthly cap (fail closed).
    static func spendWindow(_ period: SpendPeriod, now: Date, zone: TimeZone) throws -> (Date, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let unit: Calendar.Component = period == .day ? .day : .month
        guard let interval = calendar.dateInterval(of: unit, for: now) else {
            throw WorkError.invalid("no \(period.rawValue) holds \(now) in \(zone.identifier)")
        }
        return (interval.start, interval.end)
    }

    // MARK: Meter (Task 9)

    /// A provider's spend in one window, split by state: `committed` (settled and estimated charges) and `reserved` (open
    /// reservations, each at its estimate).
    struct SpendSplit: Equatable, Sendable {
        var committed: Double
        var reserved: Double
    }

    /// Records `c` as a reservation (`state = 'reserved'`) when `admit` lets it through, in one immediate transaction with the
    /// spend `admit` decided on, so two concurrent reservations can never both pass on the same spend. `admit` gets the
    /// company's caps for `c.provider` (nil when none are set) and the day's and month's spend (owner calendar in `zone`,
    /// windows holding `c.at`); it throws to refuse, and nothing is written. Returns the new row's id.
    func reserveCharge(_ c: GatewayCharge, zone: TimeZone,
                       admit: (ProviderCaps?, _ day: SpendSplit, _ month: SpendSplit) throws -> Void) throws -> Int64 {
        guard c.state == .reserved, c.usd.isFinite, c.usd >= 0 else { throw WorkError.invalid("a reservation is zero or more dollars") }
        guard [c.inputTokens, c.outputTokens, c.cacheReadTokens, c.cacheWriteTokens].allSatisfy({ $0 >= 0 }) else {
            throw WorkError.invalid("token counts are zero or more")
        }
        let day = try Self.spendWindow(.day, now: c.at, zone: zone)
        let month = try Self.spendWindow(.month, now: c.at, zone: zone)
        var id: Int64 = 0
        try writer.writeWithoutTransaction { db in
            try db.inTransaction(.immediate) {
                try Self.requireCompany(db, c.companyId)
                let caps = try Row.fetchOne(db, sql: "SELECT monthlyUSD, dailyUSD FROM providerCap WHERE companyId = ? AND provider = ?",
                                            arguments: [c.companyId, c.provider])
                    .map { ProviderCaps(monthlyUSD: $0["monthlyUSD"], dailyUSD: $0["dailyUSD"] as Double) }
                try admit(caps, try Self.spendSplit(db, c, day), try Self.spendSplit(db, c, month))
                try db.execute(sql: """
                    INSERT INTO gatewayCharge (companyId, turnId, itemId, agentId, provider, model, inputTokens, outputTokens,
                      cacheReadTokens, cacheWriteTokens, usd, estimated, state, at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [c.companyId, c.turnId, c.itemId, c.agentId, c.provider, c.model, c.inputTokens, c.outputTokens,
                                     c.cacheReadTokens, c.cacheWriteTokens, c.usd, c.estimated, c.state.rawValue, c.at])
                id = db.lastInsertedRowID
                return .commit
            }
        }
        return id
    }

    private static func spendSplit(_ db: Database, _ c: GatewayCharge, _ window: (Date, Date)) throws -> SpendSplit {
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(CASE WHEN state = 'reserved' THEN 0 ELSE usd END), 0) AS committed,
                   COALESCE(SUM(CASE WHEN state = 'reserved' THEN usd ELSE 0 END), 0) AS reserved
            FROM gatewayCharge WHERE companyId = ? AND provider = ? AND at >= ? AND at < ?
            """, arguments: [c.companyId, c.provider, window.0, window.1])
        return SpendSplit(committed: row?["committed"] ?? 0, reserved: row?["reserved"] ?? 0)
    }

    /// Settles an open reservation with the provider's usage and its cost. Only a `reserved` row changes, so a second settle
    /// (or one after `recoverReservations`) does nothing; returns whether the row changed.
    @discardableResult
    func settleCharge(id: Int64, usage: GatewayUsage, usd: Double) throws -> Bool {
        guard usd.isFinite, usd >= 0 else { throw WorkError.invalid("a charge is zero or more dollars") }
        return try writer.write { db in
            try db.execute(sql: """
                UPDATE gatewayCharge SET state = 'settled', estimated = 0, usd = ?, inputTokens = ?, outputTokens = ?,
                  cacheReadTokens = ?, cacheWriteTokens = ?
                WHERE id = ? AND state = 'reserved'
                """, arguments: [usd, usage.inputTokens, usage.outputTokens, usage.cacheReadTokens, usage.cacheWriteTokens, id])
            return db.changesCount > 0
        }
    }

    /// Settles an open reservation at its reserved amount (`estimated`): the request went out and no usage came back.
    @discardableResult
    func estimateCharge(id: Int64) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "UPDATE gatewayCharge SET state = 'estimated', estimated = 1 WHERE id = ? AND state = 'reserved'",
                           arguments: [id])
            return db.changesCount > 0
        }
    }

    /// Deletes an open reservation whose request never left the gateway (Ruling 23: a refused request is never charged).
    @discardableResult
    func releaseReservation(id: Int64) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM gatewayCharge WHERE id = ? AND state = 'reserved'", arguments: [id])
            return db.changesCount > 0
        }
    }

    /// Every reservation still open (left by a gateway that stopped or died before settling) becomes `estimated` at its
    /// reserved amount, so a `kill -9` never under-records spend. Returns how many changed.
    @discardableResult
    func recoverReservations() throws -> Int {
        try writer.write { db in
            try db.execute(sql: "UPDATE gatewayCharge SET state = 'estimated', estimated = 1 WHERE state = 'reserved'")
            return db.changesCount
        }
    }

    // MARK: Routes

    /// The company's routes: company, then role, then agent scope; by subject and class within each.
    public func routes(companyId: String) throws -> [ModelRoute] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM modelRoute WHERE companyId = ?
                ORDER BY CASE scope WHEN 'company' THEN 0 WHEN 'role' THEN 1 ELSE 2 END, subject, "class"
                """, arguments: [companyId]).map { row in
                    guard let scope = RouteScope(rawValue: row["scope"]) else {
                        throw WorkError.invalid("unreadable route scope \(row["scope"] as String)")
                    }
                    return ModelRoute(companyId: row["companyId"], scope: scope, subject: row["subject"], modelClass: row["class"],
                                      provider: row["provider"], model: row["model"])
                }
        }
    }

    /// Sets (or replaces) one route. Refused: a company route with a subject, a role or agent route without one, an empty class
    /// or model, an unknown company or provider.
    public func setRoute(_ r: ModelRoute) throws {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        guard (r.scope == .company) == r.subject.isEmpty else {
            throw WorkError.invalid(r.scope == .company ? "a company route has no subject" : "a \(r.scope.rawValue) route names its \(r.scope.rawValue)")
        }
        guard !r.modelClass.isEmpty, !r.model.isEmpty else { throw WorkError.invalid("a route names a class and a model") }
        try writer.write { db in
            try Self.requireCompany(db, r.companyId)
            try Self.requireProvider(db, r.provider)
            try db.execute(sql: """
                INSERT INTO modelRoute (companyId, scope, subject, "class", provider, model) VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(companyId, scope, subject, "class") DO UPDATE SET provider = excluded.provider, model = excluded.model
                """, arguments: [r.companyId, r.scope.rawValue, r.subject, r.modelClass, r.provider, r.model])
        }
    }

    /// Removes every class's route of one scope and subject.
    public func clearRoutes(companyId: String, scope: RouteScope, subject: String) throws {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        try writer.write { db in
            try db.execute(sql: "DELETE FROM modelRoute WHERE companyId = ? AND scope = ? AND subject = ?",
                           arguments: [companyId, scope.rawValue, subject])
        }
    }

    // MARK: Probes

    public func probeRecord(provider: String, model: String, adapterVersion: String, cliVersion: String) throws -> ModelProbeRecord? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM modelProbe WHERE provider = ? AND model = ? AND adapterVersion = ? AND cliVersion = ?
                """, arguments: [provider, model, adapterVersion, cliVersion]) else { return nil }
            guard let level = ModelProbeLevel(rawValue: row["level"]) else {
                throw WorkError.invalid("unreadable probe level \(row["level"] as String)")
            }
            let steps = try JSONDecoder().decode([ProbeStepResult].self, from: Data((row["steps"] as String).utf8))
            return ModelProbeRecord(provider: row["provider"], model: row["model"], adapterVersion: row["adapterVersion"],
                                    cliVersion: row["cliVersion"], level: level, steps: steps, declaredContext: row["declaredContext"],
                                    probedAt: row["probedAt"])
        }
    }

    /// Saves (or replaces) the record for its key.
    public func saveProbe(_ r: ModelProbeRecord) throws {
        let steps = String(decoding: try JSONEncoder().encode(r.steps), as: UTF8.self)
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO modelProbe (provider, model, adapterVersion, cliVersion, level, steps, declaredContext, probedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [r.provider, r.model, r.adapterVersion, r.cliVersion, r.level.rawValue, steps, r.declaredContext,
                                 r.probedAt])
        }
    }

    /// Queues a probe of `model` and returns the request's id; a request for the same provider, model and company still queued
    /// is returned instead of a second one. Refused: an unknown provider or company.
    public func queueProbe(provider: String, model: String, requestedBy: String, companyId: String?,
                           now: Date = Store.now()) throws -> String {
        guard !model.isEmpty else { throw WorkError.invalid("a probe names a model") }
        return try writer.write { db in
            try Self.requireProvider(db, provider)
            if let companyId { try Self.requireCompany(db, companyId) }
            if let queued = try String.fetchOne(db, sql: """
                SELECT id FROM modelProbeRequest WHERE provider = ? AND model = ? AND companyId IS ? AND status = ?
                ORDER BY createdAt, rowid LIMIT 1
                """, arguments: [provider, model, companyId, ModelProbeRequest.Status.queued.rawValue]) { return queued }
            let id = UUID().uuidString.lowercased()
            try db.execute(sql: """
                INSERT INTO modelProbeRequest (id, provider, model, requestedBy, companyId, status, createdAt) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, provider, model, requestedBy, companyId, ModelProbeRequest.Status.queued.rawValue, now])
            return id
        }
    }

    /// The oldest queued request.
    public func nextQueuedProbe() throws -> ModelProbeRequest? {
        try writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM modelProbeRequest WHERE status = ? ORDER BY createdAt, rowid LIMIT 1
                """, arguments: [ModelProbeRequest.Status.queued.rawValue]) else { return nil }
            return ModelProbeRequest(id: row["id"], provider: row["provider"], model: row["model"], requestedBy: row["requestedBy"],
                                     companyId: row["companyId"], status: .queued, createdAt: row["createdAt"])
        }
    }

    /// Finishes a queued request. Refused: `.queued`, an unknown request, one already finished.
    public func finishProbeRequest(id: String, status: ModelProbeRequest.Status) throws {
        guard status != .queued else { throw WorkError.invalid("a probe request finishes done or failed") }
        try writer.write { db in
            guard let current = try String.fetchOne(db, sql: "SELECT status FROM modelProbeRequest WHERE id = ?", arguments: [id]) else {
                throw WorkError.notFound("no such probe request")
            }
            guard current == ModelProbeRequest.Status.queued.rawValue else { throw WorkError.conflict("the probe request is already \(current)") }
            try db.execute(sql: "UPDATE modelProbeRequest SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
    }

    // MARK: Prices

    /// The owner's price rows, by provider and model.
    public func priceRows() throws -> [PriceRow] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM priceRow ORDER BY provider, model").map {
                PriceRow(provider: $0["provider"], model: $0["model"], inPerMTok: $0["inPerMTok"], outPerMTok: $0["outPerMTok"],
                         cacheReadPerMTok: $0["cacheReadPerMTok"], cacheWritePerMTok: $0["cacheWritePerMTok"], setBy: $0["setBy"])
            }
        }
    }

    /// Sets (or replaces) the owner's price for one model. Refused: an empty provider, model or author, and any price
    /// `PriceBook.refusal(for:)` refuses (negative, non-finite or zero: the price book's one rule, Plan X1 Task 6).
    public func setPriceRow(_ p: PriceRow) throws {
        try ProcessRole.refuseInAgentProcess()  // Ruling C6-4: never from an agent process
        guard !p.provider.isEmpty, !p.model.isEmpty, !p.setBy.isEmpty else { throw WorkError.invalid("a price names its provider, model and author") }
        if let why = PriceBook.refusal(for: p) { throw WorkError.invalid(why) }
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO priceRow (provider, model, inPerMTok, outPerMTok, cacheReadPerMTok, cacheWritePerMTok, setBy)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [p.provider, p.model, p.inPerMTok, p.outPerMTok, p.cacheReadPerMTok, p.cacheWritePerMTok, p.setBy])
        }
    }

    // MARK: Helpers

    private static func requireCompany(_ db: Database, _ companyId: String) throws {
        guard try Row.fetchOne(db, sql: "SELECT 1 FROM company WHERE id = ?", arguments: [companyId]) != nil else {
            throw WorkError.notFound("no such company")
        }
    }

    private static func requireProvider(_ db: Database, _ id: String) throws {
        guard try Row.fetchOne(db, sql: "SELECT 1 FROM provider WHERE id = ?", arguments: [id]) != nil else {
            throw WorkError.notFound("no such provider: \(id)")
        }
    }

    private static func provider(from row: Row) throws -> Provider {
        let text: String = row["baseURL"]
        guard let url = URL(string: text) else { throw WorkError.invalid("unreadable base URL for provider \(row["id"] as String)") }
        return Provider(id: row["id"], adapter: row["adapter"], baseURL: url, host: row["host"], keySecret: row["keySecret"],
                        lan: row["lan"], builtin: row["builtin"], createdAt: row["createdAt"])
    }
}

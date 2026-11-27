import Foundation

/// The engine's model gateway (Plan X1 Task 8): the handler behind `GatewayServer`. For each admitted request it decodes the
/// body, routes the model by the turn's grant, applies the policy refusals, reserves the request's estimate with the meter
/// (Task 9: refused at a cap, unpriced or uncapped), reads the provider key from the vault, sends the request upstream through
/// the provider's adapter, and settles the reservation with the usage the adapter read.
///
/// Every request first passes `GatewayPolicy` (no provider-side network, only metered fields and betas; Ruling X1-34).
/// Routing: `grant.aliases[model]` names the provider and upstream model; otherwise `model` is served as sent, by the grant's
/// provider, only when it is one of `grant.passThroughFamilies` (exact ids); anything else is refused. The key is read per
/// request with `vault.nonInteractive()` and lives only in the local scope of that request's `forward`: never stored, logged
/// or echoed — upstream text is redacted with its value before it is relayed or logged.
///
/// Metering (Task 9): a request that never left the gateway is released (Ruling 23); one handed to the transport is charged
/// its final usage, or at least its estimate when there is none — usage missing (Ruling 52(a)) or a response that ended
/// early (Ruling X1-37) — except an error answer its adapter says the provider does not bill (`billsNothing(status:)`,
/// Ruling 55: settled at zero), and `count_tokens`, which costs nothing. An adapter that answers `count_tokens` itself
/// (`countTokensLocally`: `openai-compatible`) is answered before the key is read and before the meter: nothing is sent, so
/// nothing is reserved or charged (Task 10). At most `GatewayLimits.maxUpstreamRequests`
/// requests are upstream at once; past it a request gets a 429 (Ruling 52(f): transient, so `claude` backs off and retries).
public final class ModelGateway: GatewayHandler, @unchecked Sendable {
    public let registry: TurnTokenRegistry
    private let providers: @Sendable (String) throws -> Provider?
    private let isTestSecret: @Sendable (_ companyId: String, _ name: String) throws -> Bool
    private let alert: @Sendable (_ companyId: String, _ text: String) -> Void
    /// `companyId|provider|reason` of every provider-record alert raised: each is raised once per gateway, not per request.
    private var alerted: Set<String> = []
    private let adapters: [AdapterId: any ProviderAdapter]
    private let upstream: any UpstreamTransport
    private let vault: any SecretVault
    private let meter: GatewayMeter
    private let maxUpstream: Int
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var server: GatewayServer?
    private var stopped = false
    private var upstreamInFlight = 0

    /// `providers` looks a provider up by id (the store's `provider(id:)`); `isTestSecret` says whether a company's secret is
    /// flagged test (the store's `isTestSecret(companyId:name:)`; a provider key so flagged is refused, Task 11); `alert` puts a
    /// refused provider record in front of the owner (`ModelGateway.engineAlerts(store:log:)`, Ruling X1-38); `log` gets one
    /// line per refused, failed or served request (never a key); `meter` reserves and settles every request sent upstream.
    public convenience init(registry: TurnTokenRegistry, providers: @escaping @Sendable (String) throws -> Provider?,
                            isTestSecret: @escaping @Sendable (String, String) throws -> Bool,
                            alert: @escaping @Sendable (_ companyId: String, _ text: String) -> Void,
                            adapters: [any ProviderAdapter] = [AnthropicAdapter(), OpenAICompatibleAdapter()], upstream: any UpstreamTransport,
                            vault: any SecretVault,
                            meter: GatewayMeter, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(registry: registry, providers: providers, isTestSecret: isTestSecret, alert: alert, adapters: adapters, upstream: upstream, vault: vault, meter: meter,
                  maxUpstream: GatewayLimits.maxUpstreamRequests, log: log)
    }

    init(registry: TurnTokenRegistry, providers: @escaping @Sendable (String) throws -> Provider?,
         isTestSecret: @escaping @Sendable (String, String) throws -> Bool,
         alert: @escaping @Sendable (_ companyId: String, _ text: String) -> Void, adapters: [any ProviderAdapter],
         upstream: any UpstreamTransport, vault: any SecretVault, meter: GatewayMeter, maxUpstream: Int,
         log: @escaping @Sendable (String) -> Void) {
        self.registry = registry; self.providers = providers; self.isTestSecret = isTestSecret; self.alert = alert
        self.upstream = upstream; self.vault = vault; self.meter = meter
        self.maxUpstream = maxUpstream; self.log = log
        self.adapters = Dictionary(adapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The adapters this gateway serves providers with.
    var adapterIds: Set<AdapterId> { Set(adapters.keys) }

    /// Starts serving on `127.0.0.1:<ephemeral>` and returns the port (the same port while running). A stopped gateway does
    /// not start again. Before the first start serves anything, reservations a dead gateway left open are charged at their
    /// estimates (`GatewayMeter.recover`); a meter that cannot do that keeps the gateway from starting (fail closed).
    public func start() throws -> UInt16 {
        let server: GatewayServer = try lock.withLock {
            guard !stopped else { throw LoopbackListenerError.setup(step: "start after stop", errno: 0) }
            if let server = self.server { return server }
            try recoverOpenReservations()
            let made = GatewayServer(registry: registry, handler: self)
            self.server = made
            return made
        }
        return try server.start()
    }

    /// What `start` does before it serves: reservations a dead gateway left open are charged at their estimates. A seam so a
    /// test can check it without binding a port.
    func recoverOpenReservations() throws {
        let recovered = try meter.recover()
        if recovered > 0 { log("gateway: \(recovered) reservation(s) left open by an earlier gateway charged at their estimates") }
    }

    /// Stops the server (cutting open connections) and every token. Idempotent.
    public func stop() {
        let server: GatewayServer? = lock.withLock {
            stopped = true
            defer { self.server = nil }
            return self.server
        }
        server?.stop()
        registry.revokeAll(reason: "the gateway stopped")
    }

    // MARK: Serving

    public func handle(_ r: GatewayRequest, grant: TurnGrant, reply: GatewayReply) async {
        do {
            try await serve(r, grant: grant, reply: reply)
        } catch {
            log("gateway: turn \(grant.turnId) refused \(error.status) \(error.type): \(error.message)")
            await reply.refuse(status: error.status, type: error.type, message: error.message)
        }
    }

    private func serve(_ r: GatewayRequest, grant: TurnGrant, reply: GatewayReply) async throws(GatewayError) {
        // One strict parse (no key repeated at any depth); the policy checks this tree and the adapter sends this tree.
        let tree = try CanonicalRequest.tree(r.body)
        try GatewayPolicy.check(body: tree, headers: r.headers, grant: grant)
        let canonical = try CanonicalRequest.decode(tree: tree)
        let target = try Self.route(canonical.model, grant: grant)
        if let tools = canonical.tools, !tools.isEmpty,
           grant.textOnlyModels.contains(target.model) || grant.textOnlyModels.contains(canonical.model) {
            throw .policy("model \(Self.shown(canonical.model)) does not take tools")
        }
        guard isLive(reply) else { return }
        let provider: Provider
        do {
            guard let found = try providers(target.provider) else { throw GatewayError.unavailable("provider \(target.provider) is not configured") }
            provider = found
        } catch let error as GatewayError {
            throw error
        } catch {
            throw .unavailable("provider \(target.provider) could not be read")
        }
        // The record, with its key-to-host binding, is checked again on every request before any key is read (Task 11;
        // Ruling X1-38): a row written below the store's rules (by a restore, a direct write, a migration bug or an older
        // version) — LAN, a base URL off the pinned-host rules, a host that is not the URL's, a key bound to another host —
        // sends nothing, and the owner is alerted.
        let recordRefusal: String?
        switch ProviderHost.validate(baseURL: provider.baseURL, adapter: AdapterId(rawValue: provider.adapter), lan: provider.lan,
                                     keySecret: provider.keySecret) {
        case .failure(let refusal): recordRefusal = "provider \(provider.id): \(refusal.reason)"
        case .success(let pinned): recordRefusal = pinned == provider.host ? nil : "provider \(provider.id)'s host does not match its base URL"
        }
        if let recordRefusal {
            raiseRecordAlert(companyId: grant.companyId, provider: provider.id, reason: recordRefusal)
            throw .unavailable(recordRefusal)
        }
        guard let adapter = adapters[AdapterId(rawValue: provider.adapter)] else {
            throw .unavailable("no adapter \(provider.adapter) for provider \(provider.id)")
        }
        guard let secret = provider.keySecret, Provider.isKeyName(secret) else {
            throw .unavailable("provider \(provider.id) has no key secret")
        }
        // A provider key is engine-held only; a row flagged test (agents may be given it) is refused, and so is a flag that
        // cannot be read (Task 11, defence in depth: `Store.validateSecret` never makes one).
        let flaggedTest: Bool
        do {
            flaggedTest = try isTestSecret(grant.companyId, secret)
        } catch {
            throw .unavailable("the provider key \(secret) could not be checked")
        }
        guard !flaggedTest else {
            throw .unavailable("the provider key \(secret) is flagged as a test key; a provider key must be engine-held")
        }
        if r.endpoint == .countTokens, let count = adapter.countTokensLocally(tree) {
            // Answered here: nothing goes upstream, so no key is read and nothing is reserved or charged (it costs nothing).
            guard isLive(reply) else { return }
            await reply.send(status: 200, json: Data(#"{"input_tokens":\#(count)}"#.utf8))
            log("gateway: turn \(grant.turnId) \(provider.id)/\(target.model) count_tokens answered locally (\(count))")
            return
        }
        if r.endpoint == .messages, canonical.maxTokens == nil { throw .policy("max_tokens is required") }
        // The adapter's own refusals come before the key and the meter, so they are never masked by a cap (Ruling 58 m3).
        try adapter.validate(tree, endpoint: r.endpoint)
        guard isLive(reply) else { return }
        guard acquireUpstreamSlot() else { throw Self.busy }
        defer { releaseUpstreamSlot() }
        // The reservation is in the database before anything goes upstream; it is settled however the request ends.
        let reservation = try meter.reserve(grant, model: canonical.model, maxTokens: canonical.maxTokens ?? 0, body: r.body)
        var settlement = Settlement.release
        defer { settle(reservation, settlement) }
        try await forward(canonical, tree: tree, request: r, target: target, provider: provider, adapter: adapter, secret: secret, grant: grant,
                          reply: reply, settlement: &settlement)
    }

    /// How a reserved request is settled.
    enum Settlement: Equatable {
        /// Nothing reached the provider: the reservation is dropped (Ruling 23).
        case release
        /// The provider may have served it: charged its final usage, else at least the estimate (Ruling 52(a), X1-37).
        case charge(UsageOutcome)
    }

    /// Nothing billed, and final: an error answer, or `count_tokens`.
    static let noUsage = UsageOutcome(usage: GatewayUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0),
                                      complete: true)

    /// Ruling 52(f): more than `maxUpstream` requests upstream at once.
    static let busy = GatewayError.refused(status: 429, type: "rate_limit_error", message: "Brahma: gateway busy")

    private func settle(_ reservation: GatewayMeter.Reservation, _ settlement: Settlement) {
        switch settlement {
        case .release: meter.release(reservation)
        case .charge(let outcome): meter.settle(reservation, outcome)
        }
    }

    private func acquireUpstreamSlot() -> Bool {
        lock.withLock {
            guard upstreamInFlight < maxUpstream else { return false }
            upstreamInFlight += 1
            return true
        }
    }

    private func releaseUpstreamSlot() {
        lock.withLock { upstreamInFlight -= 1 }
    }

    /// The one scope the provider key lives in: read, swapped into the upstream request, used to redact, dropped on return.
    /// `settlement` says how the reservation is settled: it moves to a charge the moment the request is handed to the transport.
    private func forward(_ canonical: CanonicalRequest, tree: StrictJSON, request r: GatewayRequest, target: TurnGrant.RoutedTarget, provider: Provider,
                         adapter: any ProviderAdapter, secret: String, grant: TurnGrant, reply: GatewayReply,
                         settlement: inout Settlement) async throws(GatewayError) {
        let key: String
        do {
            guard let value = try vault.nonInteractive().value(companyId: grant.companyId, name: secret), !value.isEmpty else {
                throw GatewayError.unavailable("no provider key: set \(secret) for \(grant.companyId) (brahma secret set \(grant.companyId) \(secret))")
            }
            key = value
        } catch let error as GatewayError {
            throw error
        } catch {
            throw .unavailable("the provider key \(secret) could not be read")
        }
        let redact: @Sendable (String) -> String = { $0.replacingOccurrences(of: key, with: "[redacted]") }
        let outgoing = try adapter.upstream(canonical, body: tree, model: target.model, endpoint: r.endpoint, headers: r.headers,
                                            provider: provider, key: key)
        guard isLive(reply) else { return }
        settlement = .charge(.none)
        let response: UpstreamResponse
        do {
            response = try await upstream.send(outgoing)
        } catch {
            // `unavailable` is the transport's refusal before anything was sent (`UpstreamTransport`); any other failure may
            // have reached the provider, so it is charged the estimate.
            if case .unavailable = error { settlement = .release }
            throw Self.redacted(error, redact)
        }
        guard (200...299).contains(response.status) || response.status >= 400 else {
            // A redirect (never followed) or an informational answer: the provider is not where it is configured to be.
            throw .upstream(status: 502, message: "Brahma: the provider answered HTTP \(response.status); redirects are refused")
        }
        // An error answer: the adapter says whether its provider bills it (Ruling 55); else the estimate stands. A token count
        // costs nothing.
        if response.status >= 400, adapter.billsNothing(status: response.status) { settlement = .charge(Self.noUsage) }
        if r.endpoint == .countTokens { settlement = .charge(Self.noUsage) }
        let streamed = r.endpoint == .messages && canonical.stream == true
        let outcome: UsageOutcome
        do {
            outcome = try await adapter.translate(status: response.status, headers: response.headers, body: response.body,
                                                streamed: streamed, into: reply, redact: redact)
        } catch {
            throw Self.redacted(error, redact)
        }
        if r.endpoint == .messages { settlement = .charge(outcome) }
        let counts = outcome.usage.map { "in=\($0.inputTokens) out=\($0.outputTokens) cacheRead=\($0.cacheReadTokens) cacheWrite=\($0.cacheWriteTokens)" }
        log("gateway: turn \(grant.turnId) \(provider.id)/\(target.model) \(response.status) " + (counts ?? "no usage")
            + (outcome.complete ? "" : " (ended early)") + (reply.isCut ? " (cut)" : ""))
    }

    /// Ruling X1-38: a provider record the rules refuse is an engine alert for the turn's company, raised once per
    /// (company, provider, reason) for this gateway's life — `claude` retries a refusal, and the owner needs one alert.
    private func raiseRecordAlert(companyId: String, provider: String, reason: String) {
        let first = lock.withLock { alerted.insert("\(companyId)|\(provider)|\(reason)").inserted }
        guard first else { return }
        alert(companyId, "The gateway refused provider \(provider): \(reason). Its record breaks the provider rules "
              + "`brahma providers add` enforces, so it was changed outside Brahma (a restore, a direct write or an older version). "
              + "No request was sent and its key was not read. Check `brahma providers` and fix or remove it.")
    }

    /// The production `alert`: `EngineAlerts.raise` for the company (an owner DM, an activity error and one `engineAlert` ask,
    /// reason `EngineAlerts.providerRecordReason`). An alert that cannot be written is logged; the refusal stands either way.
    public static func engineAlerts(store: Store, log: @escaping @Sendable (String) -> Void) -> @Sendable (String, String) -> Void {
        { companyId, text in
            do {
                try EngineAlerts.raise(store: store, text: text, now: Store.now(), reason: EngineAlerts.providerRecordReason,
                                       companyId: companyId)
                log("gateway: engine alert raised for \(companyId): \(text)")
            } catch {
                log("gateway: the engine alert for \(companyId) could not be raised (\(error)): \(text)")
            }
        }
    }

    /// Whether the request should go on: false once the reply was cut (revocation, stop, grace over) or the task was
    /// cancelled — checked before the key is read and before connecting upstream (Ruling X1-33).
    private func isLive(_ reply: GatewayReply) -> Bool {
        !Task.isCancelled && !reply.isCut
    }

    private static func redacted(_ error: GatewayError, _ redact: (String) -> String) -> GatewayError {
        switch error {
        case .unavailable(let reason): .unavailable(redact(reason))
        case .refused(let status, let type, let message): .refused(status: status, type: type, message: redact(message))
        case .upstream(let status, let message): .upstream(status: status, message: redact(message))
        }
    }

    // MARK: Policy

    /// Where the grant sends `model`: its alias target, or the grant's provider for a granted pass-through id.
    static func route(_ model: String, grant: TurnGrant) throws(GatewayError) -> TurnGrant.RoutedTarget {
        if let target = grant.aliases[model] { return target }
        if grant.passThroughFamilies.contains(model) { return TurnGrant.RoutedTarget(provider: grant.provider, model: model) }
        throw .policy("\(model == shown(model) ? "model \(model)" : shown(model)) is not routed for this turn")
    }

    /// A model id as a refusal may show it: a plain id (letters, digits, `.`, `-`, `_`, `:`, `[`, `]`, at most 64), else a
    /// fixed phrase — refusals never echo arbitrary request text.
    static func shown(_ model: String) -> String {
        let plain = !model.isEmpty && model.utf8.count <= 64 && model.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || "._-:[]".unicodeScalars.contains($0)
        }
        return plain ? model : "the requested model"
    }
}

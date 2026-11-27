import Foundation

/// The engine's model gateway (Plan X1 Task 8): the handler behind `GatewayServer`. For each admitted request it decodes the
/// body, routes the model by the turn's grant, applies the policy refusals, reads the provider key from the vault, and sends the
/// request upstream through the provider's adapter. The meter is wired in Task 9.
///
/// Routing: `grant.aliases[model]` names the provider and upstream model; otherwise `model` is served as sent, by the grant's
/// provider, only when it is one of `grant.passThroughFamilies` (exact ids); anything else is refused. The key is read per
/// request with `vault.nonInteractive()` and lives only in the local scope of that request's `forward`: never stored, logged
/// or echoed — upstream text is redacted with its value before it is relayed or logged.
public final class ModelGateway: GatewayHandler, @unchecked Sendable {
    public let registry: TurnTokenRegistry
    private let providers: @Sendable (String) throws -> Provider?
    private let adapters: [AdapterId: any ProviderAdapter]
    private let upstream: any UpstreamTransport
    private let vault: any SecretVault
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var server: GatewayServer?
    private var stopped = false

    /// `providers` looks a provider up by id (the store's `provider(id:)`); `log` gets one line per refused, failed or served
    /// request (never a key).
    public init(registry: TurnTokenRegistry, providers: @escaping @Sendable (String) throws -> Provider?,
                adapters: [any ProviderAdapter] = [AnthropicAdapter()], upstream: any UpstreamTransport, vault: any SecretVault,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.registry = registry; self.providers = providers; self.upstream = upstream; self.vault = vault; self.log = log
        self.adapters = Dictionary(adapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Starts serving on `127.0.0.1:<ephemeral>` and returns the port (the same port while running). A stopped gateway does
    /// not start again.
    public func start() throws -> UInt16 {
        let server: GatewayServer = try lock.withLock {
            guard !stopped else { throw LoopbackListenerError.setup(step: "start after stop", errno: 0) }
            if let server = self.server { return server }
            let made = GatewayServer(registry: registry, handler: self)
            self.server = made
            return made
        }
        return try server.start()
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
        let canonical = try CanonicalRequest.decode(r.body)
        let target = try Self.route(canonical.model, grant: grant)
        if let tools = canonical.tools, !tools.isEmpty,
           grant.textOnlyModels.contains(target.model) || grant.textOnlyModels.contains(canonical.model) {
            throw .policy("model \(Self.shown(canonical.model)) does not take tools")
        }
        if let modifier = Self.unpricedModifier(canonical) { throw .policy(modifier) }
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
        guard !provider.lan else { throw .unavailable("LAN providers arrive in X1b") }
        guard let adapter = adapters[AdapterId(rawValue: provider.adapter)] else {
            throw .unavailable("no adapter \(provider.adapter) for provider \(provider.id)")
        }
        guard let secret = provider.keySecret, Provider.isKeyName(secret) else {
            throw .unavailable("provider \(provider.id) has no key secret")
        }
        guard isLive(reply) else { return }
        try await forward(canonical, request: r, target: target, provider: provider, adapter: adapter, secret: secret, grant: grant,
                          reply: reply)
    }

    /// The one scope the provider key lives in: read, swapped into the upstream request, used to redact, dropped on return.
    private func forward(_ canonical: CanonicalRequest, request r: GatewayRequest, target: TurnGrant.RoutedTarget, provider: Provider,
                         adapter: any ProviderAdapter, secret: String, grant: TurnGrant, reply: GatewayReply) async throws(GatewayError) {
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
        let outgoing = try adapter.upstream(canonical, rawBody: r.body, model: target.model, endpoint: r.endpoint, headers: r.headers,
                                            provider: provider, key: key)
        guard isLive(reply) else { return }
        let response: UpstreamResponse
        do {
            response = try await upstream.send(outgoing)
        } catch {
            throw Self.redacted(error, redact)
        }
        guard (200...299).contains(response.status) || response.status >= 400 else {
            // A redirect (never followed) or an informational answer: the provider is not where it is configured to be.
            throw .upstream(status: 502, message: "Brahma: the provider answered HTTP \(response.status); redirects are refused")
        }
        let streamed = r.endpoint == .messages && canonical.stream == true
        let usage: GatewayUsage?
        do {
            usage = try await adapter.translate(status: response.status, headers: response.headers, body: response.body,
                                                streamed: streamed, into: reply, redact: redact)
        } catch {
            throw Self.redacted(error, redact)
        }
        let counts = usage.map { "in=\($0.inputTokens) out=\($0.outputTokens) cacheRead=\($0.cacheReadTokens) cacheWrite=\($0.cacheWriteTokens)" }
        log("gateway: turn \(grant.turnId) \(provider.id)/\(target.model) \(response.status) " + (counts ?? "no usage")
            + (reply.isCut ? " (cut)" : ""))
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

    /// Ruling 39: a request field that changes the price the price book does not model is refused rather than metered at the
    /// standard rate (an undercount fails open): fast mode (`speed` other than `standard`), regional inference (`inference_geo`
    /// other than `global`), a service tier other than `standard_only`, and server-side `fallbacks` (served, and billed, by
    /// another model).
    static func unpricedModifier(_ r: CanonicalRequest) -> String? {
        if let speed = r.extra["speed"], speed != .string("standard") { return "fast mode is not priced" }
        if let geo = r.extra["inference_geo"], geo != .string("global") { return "inference_geo is not priced" }
        if let tier = r.extra["service_tier"], tier != .string("standard_only") { return "service_tier is not priced" }
        if r.extra["fallbacks"] != nil { return "fallbacks is not priced" }
        return nil
    }
}

import Foundation

/// The live per-turn gateway tokens (Plan X1 Task 7). A token is minted when a gateway turn launches and ended when it exits:
/// from that moment new requests carrying it are refused; a response already in flight may finish within `inFlightGrace` of
/// awake time and is then cut. `revokeAll` and the owner's emergency stop (`stopAll`) end every token and cut every in-flight
/// response at once. Grace is counted on the injected `AwakeClock` (Ruling 40).
public final class TurnTokenRegistry: EmergencyStopObserver, @unchecked Sendable {
    /// How long a response already streaming when its turn ends may continue (pinned: 30 s awake).
    public static let inFlightGrace: Duration = .seconds(30)

    let clock: any AwakeClock
    private let lock = NSLock()
    /// Token value → grant, for turns that have not ended.
    private var live: [String: TurnGrant] = [:]
    /// Token value → its in-flight requests (kept after the turn ends, until each finishes).
    private var inFlight: [String: [UInt64: GatewayLease]] = [:]
    /// Token value → the timer that cuts its in-flight requests when the grace runs out.
    private var graceTimers: [String: Task<Void, Never>] = [:]
    private var nextLease: UInt64 = 0
    private var revocationReason: String?

    public init(clock: any AwakeClock = SystemAwakeClock()) {
        self.clock = clock
    }

    /// A fresh token for this grant (never one already live or still in flight).
    public func mint(_ g: TurnGrant) -> GatewayToken {
        lock.withLock {
            var token = GatewayToken.mint()
            while live[token.value] != nil || inFlight[token.value] != nil { token = GatewayToken.mint() }
            live[token.value] = g
            return token
        }
    }

    /// The grant of a live token; nil for anything malformed, unknown, ended or revoked.
    public func admit(_ token: String) -> TurnGrant? {
        guard GatewayToken.isWellFormed(token) else { return nil }
        return lock.withLock { live[token] }
    }

    /// Ends a turn's token: new requests are refused at once; in-flight ones get `inFlightGrace`, then are cut.
    public func endTurn(_ token: GatewayToken) {
        let key = token.value
        let (leases, deadline): ([GatewayLease], Duration?) = lock.withLock {
            live[key] = nil
            guard let open = inFlight[key], !open.isEmpty, graceTimers[key] == nil else { return ([], nil) }
            let deadline = clock.now + Self.inFlightGrace
            let clock = self.clock
            graceTimers[key] = Task { [weak self] in
                do { try await clock.sleep(until: deadline) } catch { return }
                self?.cutInFlight(of: key)
            }
            return (Array(open.values), deadline)
        }
        if let deadline { leases.forEach { $0.expire(at: deadline) } }
    }

    /// Ends every token and cuts every in-flight request now (no grace). `reason` is kept for diagnostics only.
    public func revokeAll(reason: String) {
        let (leases, timers): ([GatewayLease], [Task<Void, Never>]) = lock.withLock {
            live.removeAll()
            revocationReason = reason
            defer { graceTimers.removeAll() }
            return (inFlight.values.flatMap(\.values), Array(graceTimers.values))
        }
        timers.forEach { $0.cancel() }
        leases.forEach { $0.cut() }
    }

    /// `EmergencyStopObserver`: the owner's stop revokes every token and cuts every stream at once.
    public func stopAll(reason: String) async {
        revokeAll(reason: reason)
    }

    /// Live (not ended, not revoked) tokens.
    public var liveTokens: Int { lock.withLock { live.count } }
    /// Requests admitted and not yet finished, across all tokens.
    public var inFlightRequests: Int { lock.withLock { inFlight.values.reduce(0) { $0 + $1.count } } }
    /// The reason given to the last `revokeAll` / `stopAll`.
    public var lastRevocationReason: String? { lock.withLock { revocationReason } }

    // MARK: Leases (the server's side)

    /// Admits a request and registers it as in flight, atomically: a turn that ends after this still lets the request finish
    /// within the grace; one that ended before refuses it.
    func open(_ token: String) -> GatewayLease? {
        guard GatewayToken.isWellFormed(token) else { return nil }
        return lock.withLock {
            guard let grant = live[token] else { return nil }
            nextLease += 1
            let lease = GatewayLease(grant: grant, token: token, id: nextLease, clock: clock, registry: self)
            inFlight[token, default: [:]][lease.id] = lease
            return lease
        }
    }

    /// A request finished: it leaves the in-flight set; the last one of an ended turn also cancels the grace timer.
    fileprivate func finished(_ lease: GatewayLease) {
        let timer: Task<Void, Never>? = lock.withLock {
            inFlight[lease.token]?[lease.id] = nil
            guard inFlight[lease.token]?.isEmpty == true else { return nil }
            inFlight[lease.token] = nil
            return graceTimers.removeValue(forKey: lease.token)
        }
        timer?.cancel()
    }

    private func cutInFlight(of token: String) {
        let leases: [GatewayLease] = lock.withLock {
            graceTimers[token] = nil
            return inFlight[token].map { Array($0.values) } ?? []
        }
        leases.forEach { $0.cut() }
    }
}

/// One admitted request's hold on its token. The server arms it with what to do when the request must stop (shut the socket,
/// cancel the handler); the registry cuts it on revocation or when the grace runs out, and every write checks it first.
final class GatewayLease: @unchecked Sendable {
    let grant: TurnGrant
    let token: String
    let id: UInt64
    private let clock: any AwakeClock
    private weak var registry: TurnTokenRegistry?
    private let lock = NSLock()
    private var isCut = false
    private var isFinished = false
    private var deadline: Duration?
    private var onCut: (@Sendable () -> Void)?

    init(grant: TurnGrant, token: String, id: UInt64, clock: any AwakeClock, registry: TurnTokenRegistry) {
        self.grant = grant; self.token = token; self.id = id; self.clock = clock; self.registry = registry
    }

    /// Sets the cut action; runs it at once when the lease was already cut.
    func arm(_ action: @escaping @Sendable () -> Void) {
        let runNow: Bool = lock.withLock {
            guard !isFinished else { return false }
            if isCut { return true }
            onCut = action
            return false
        }
        if runNow { action() }
    }

    /// Removes the cut action: a cut from now on only marks the lease (until the next `arm`, which then runs at once).
    func disarm() {
        lock.withLock { onCut = nil }
    }

    /// The turn ended: the request may run until `deadline` (awake), not after.
    func expire(at deadline: Duration) {
        lock.withLock {
            if let current = self.deadline, current <= deadline { return }
            self.deadline = deadline
        }
    }

    /// Stops the request now (idempotent; nothing once the request finished).
    func cut() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            guard !isCut, !isFinished else { return nil }
            isCut = true
            defer { onCut = nil }
            return onCut
        }
        action?()
    }

    /// Whether the request may still write: not cut and not past its grace deadline (which cuts it).
    func mayContinue() -> Bool {
        let expired: Bool = lock.withLock {
            if let deadline, clock.now >= deadline { return true }
            return false
        }
        if expired { cut() }
        return lock.withLock { !isCut }
    }

    var wasCut: Bool { lock.withLock { isCut } }

    /// The request is over: disarms the lease (a late cut can no longer touch the connection) and releases the token's hold.
    func finish() {
        let first: Bool = lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            onCut = nil
            return true
        }
        if first { registry?.finished(self) }
    }
}

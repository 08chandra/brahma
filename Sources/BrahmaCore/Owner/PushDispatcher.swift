import Foundation
import GRDB

/// Sends the phone pushes the delivery plan asks for, within the rate limits. It runs as a detached task of the engine, after
/// the timers step, and never holds the engine: a channel that keeps failing is logged once, nothing more.
///
/// - Urgent pushes go at once. Normal ones (outside quiet hours) go as one coalesced push at most every `minInterval` seconds.
/// - At most `dailyCap` pushes per owner day, then one final "more waiting in Brahma" push and silence until tomorrow.
/// - A push marks its asks and notices `pushedAt` only after a 2xx. A failure is logged in `pushLog`, nothing is marked, and the
///   next try waits `minInterval` (no tight loop). Three failures in a row log one `phone alerts failing: <status>` event.
/// - A channel that cannot be built (a missing or unreadable credential) is one failure row and one alert per episode.
/// - Every wait counts awake time (`AwakeTime.uptime`), never wall-clock differences.
///
/// Vault reads: none while nothing is due or nothing may be sent yet. The channel is built (its credentials read through
/// `OwnerCredential.readOwnerCredential`) once per (provider, server, topic, credentials version) and cached; it is built
/// again only after that changes, after a failed send, or (at most once a window) while it cannot be built.
///
/// Privacy: in `titles` mode the titles are redacted before planning and the planned text again before it leaves. While
/// the store holds secrets (`secretsHeld`: not loaded, or a value failed to load) or a redaction throws, the push is planned
/// as `counts`: engine text only. Nothing that did not pass the redactor in this process leaves in a payload.
public actor PushDispatcher {
    public static let minInterval: TimeInterval = 300
    public static let dailyCap = 30
    public static let failureAlertAfter = 3
    public static let capNotice = "Brahma: more waiting in Brahma"

    private let store: Store
    private let vault: any SecretVault
    private let injected: (any PushChannel)?
    private let transport: any PushTransport
    private let awake: @Sendable () -> TimeInterval
    private let clock: @Sendable () -> Date
    private let redactOverride: (@Sendable (String) throws -> String)?

    private var lastNormalAt: TimeInterval?
    private var retryNotBefore: TimeInterval = -.infinity
    private var consecutiveFailures = 0
    private var failureAlerted = false

    /// What the cached channel was built for.
    struct ChannelKey: Equatable {
        var provider: PushProvider
        var server: String
        var topic: String?
        var credentials: Int

        init(_ prefs: OwnerPrefs, provider: PushProvider, credentials: Int) {
            self.provider = provider
            server = (try? PushURL.normalized(server: prefs.pushServer)) ?? prefs.pushServer
            topic = prefs.pushTopic
            self.credentials = credentials
        }
    }
    private var cached: (key: ChannelKey, channel: any PushChannel)?
    /// The settings a channel could not be built for, already logged and alerted (one per episode).
    private var unbuildable: ChannelKey?

    /// `channel` nil: built from the owner's settings when a push is due and cached (see above), with credentials read
    /// from `vault` through `OwnerCredential.readOwnerCredential`. `awake` is the awake-time clock; tests drive it by hand.
    public init(store: Store, vault: any SecretVault, channel: (any PushChannel)? = nil,
                transport: any PushTransport = URLSessionPushTransport(),
                awake: @escaping @Sendable () -> TimeInterval = { AwakeTime.uptime() },
                clock: @escaping @Sendable () -> Date = { Store.now() }) {
        self.init(store: store, vault: vault, channel: channel, transport: transport, awake: awake, clock: clock, redact: nil)
    }

    /// `redact` replaces the store's redactor (tests: a redactor that throws).
    init(store: Store, vault: any SecretVault, channel: (any PushChannel)? = nil,
         transport: any PushTransport = URLSessionPushTransport(),
         awake: @escaping @Sendable () -> TimeInterval = { AwakeTime.uptime() },
         clock: @escaping @Sendable () -> Date = { Store.now() },
         redact: (@Sendable (String) throws -> String)?) {
        self.store = store; self.vault = vault; self.injected = channel; self.transport = transport
        self.awake = awake; self.clock = clock; self.redactOverride = redact
    }

    /// One pass. `onlyStopNotice` is the hook for Task 7c: while `engineStopped` holds, only the stop notice may be pushed, so
    /// nothing else is sent (7c replaces this early return with the stop-notice path).
    public func tick(now: Date, onlyStopNotice: Bool = false) async {
        if onlyStopNotice { return }
        guard let prefs = try? store.ownerPrefs(), let provider = prefs.pushProvider else { cached = nil; return }
        let uptime = awake()
        guard uptime >= retryNotBefore else { return }

        // Due work first: nothing due, or nothing that may go yet, reads no credential and logs no failure.
        guard let asks = try? store.dueAskNotices(forPush: true), let notices = try? store.duePushNotices() else { return }
        guard !asks.isEmpty || !notices.isEmpty else { return }
        let tz = store.ownerTimeZone()
        let lastNormal = lastNormalAt
        let ready = plan(asks: asks, notices: notices, prefs: prefs, now: now, tz: tz).filter { push in
            push.urgent || lastNormal.map { uptime - $0 >= Self.minInterval } ?? true
        }
        guard !ready.isEmpty else { return }
        guard var counts = try? store.pushCounts(since: Self.ownerDayStart(now, tz: tz)) else { return }
        if counts.sent >= Self.dailyCap, counts.capNoticeSent { return }

        guard let channel = await channel(prefs: prefs, provider: provider, uptime: uptime, now: now) else { return }
        for push in ready {
            if Task.isCancelled { return }
            if counts.sent >= Self.dailyCap {
                if !counts.capNoticeSent { await sendFinal(channel, now: now, uptime: uptime) }
                return
            }
            let r = await channel.send(title: push.title, body: push.body, priority: push.urgent ? .urgent : .normal, deepLink: push.deepLink)
            if r.ok {
                try? store.markPushed(askIds: push.askIds, noticeIds: push.noticeIds, now: clock())
                try? store.logPush(ok: true, status: r.status, detail: push.urgent ? "urgent" : "normal", now: clock())
                counts.sent += 1
                if !push.urgent { lastNormalAt = awake() }
                consecutiveFailures = 0; failureAlerted = false
            } else {
                // An engine shutdown cancelled the send: not a failure of the channel, nothing logged or counted.
                if Task.isCancelled { return }
                cached = nil
                await failed(status: r.status, text: r.error ?? "failed", detail: push.urgent ? "urgent" : "normal", uptime: uptime, now: now,
                             company: push.companyId)
                return
            }
        }
    }

    /// The pushes to send now, worded under the privacy rule. `titles` only when every title (and then the planned text)
    /// went through the redactor; otherwise the same items are planned as `counts`.
    private func plan(asks: [DueAsk], notices: [OwnerNotice], prefs: OwnerPrefs, now: Date, tz: TimeZone) -> [PushedNotice] {
        var countsPrefs = prefs
        countsPrefs.pushDetail = .counts
        let counts = { NoticeDelivery.pushPlan(dueAsks: asks, notices: notices, prefs: countsPrefs, now: now, tz: tz) }
        guard prefs.pushDetail == .titles, !store.secretsHeld else { return counts() }
        let redact: (String) throws -> String = { [store, redactOverride] text in
            if let redactOverride { return try redactOverride(text) }
            return try store.redact(text)
        }
        do {
            // Raw first, while any newlines are in (a multi-line secret matches), then the planned text as it will leave.
            let redacted = try asks.map { due -> DueAsk in var d = due; d.ask.title = try redact(due.ask.title); return d }
            return try NoticeDelivery.pushPlan(dueAsks: redacted, notices: notices, prefs: prefs, now: now, tz: tz).map { push in
                var p = push
                p.title = try redact(push.title)
                p.body = try redact(push.body)
                return p
            }
        } catch {
            return counts()
        }
    }

    /// The cached channel, or one built now for these settings (the only place the engine reads push credentials).
    private func channel(prefs: OwnerPrefs, provider: PushProvider, uptime: TimeInterval, now: Date) async -> (any PushChannel)? {
        if let injected { return injected }
        guard let version = try? store.pushCredentialsVersion() else { return nil }
        let key = ChannelKey(prefs, provider: provider, credentials: version)
        if let cached, cached.key == key { return cached.channel }
        cached = nil
        do {
            guard let made = try PushChannels.make(prefs: prefs, vault: vault, transport: transport) else { return nil }
            cached = (key, made)
            unbuildable = nil
            return made
        } catch {
            // One row and one alert per episode; the next window tries the vault again, silently.
            retryNotBefore = uptime + Self.minInterval
            guard unbuildable != key else { return nil }
            unbuildable = key
            let text = (error as? PushError)?.description ?? "not configured"
            try? store.logPush(ok: false, status: nil, detail: String(Store.flat("not configured: " + text, max: 120)), now: clock())
            await alert(label: Store.flat(text, max: 80), now: now, company: nil)
            return nil
        }
    }

    private func sendFinal(_ channel: any PushChannel, now: Date, uptime: TimeInterval) async {
        let r = await channel.send(title: "Brahma", body: Self.capNotice, priority: .normal, deepLink: nil)
        if r.ok {
            try? store.logPush(ok: true, status: r.status, detail: "cap", now: clock())
        } else {
            if Task.isCancelled { return }
            cached = nil
            await failed(status: r.status, text: r.error ?? "failed", detail: "cap", uptime: uptime, now: now, company: nil)
        }
    }

    private func failed(status: Int?, text: String, detail: String, uptime: TimeInterval, now: Date, company: String?) async {
        try? store.logPush(ok: false, status: status, detail: String(Store.flat(text, max: 120)), now: clock())
        retryNotBefore = uptime + Self.minInterval
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.failureAlertAfter, !failureAlerted else { return }
        failureAlerted = true
        await alert(label: status.map(String.init) ?? Store.flat(text, max: 60), now: now, company: company)
    }

    /// The one `phone alerts failing: <label>` line (engine text: a status, or a `PushError` description).
    private func alert(label: String, now: Date, company: String?) async {
        guard let companyId = company ?? (try? store.companies().first?.id) else { return }
        try? store.appendEvent(ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .error,
                                             text: "phone alerts failing: \(label)", createdAt: now))
    }

    /// The start of the owner's calendar day (the cap is per owner day).
    static func ownerDayStart(_ now: Date, tz: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.startOfDay(for: now)
    }

    /// `brahma push test`: one push to the configured service, logged as a test. Not rate limited, never marks anything.
    public static func sendTest(store: Store, vault: any SecretVault, transport: any PushTransport = URLSessionPushTransport(),
                                now: Date = Store.now()) async throws -> PushResult {
        guard let channel = try PushChannels.make(prefs: store.ownerPrefs(), vault: vault, transport: transport) else { throw PushError.notConfigured }
        let r = await channel.send(title: "Brahma", body: "Brahma: test alert", priority: .normal, deepLink: nil)
        try? store.logPush(ok: r.ok, status: r.status, detail: "test", now: now)
        return PushResult(ok: r.ok, status: r.status, error: r.error)
    }
}

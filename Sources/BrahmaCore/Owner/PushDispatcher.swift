import Foundation
import GRDB

/// Sends the phone pushes the delivery plan asks for, within the rate limits. It runs as a detached task of the engine, after
/// the timers step, and never holds the engine: a channel that keeps failing is logged once, nothing more.
///
/// - Urgent pushes go at once. Normal ones (outside quiet hours) go as one coalesced push at most every `minInterval` seconds.
/// - At most `dailyCap` pushes per owner day, then one final "more waiting in Brahma" push and silence until tomorrow.
/// - A push marks its asks and notices `pushedAt` only after a 2xx. A failure is logged in `pushLog`, nothing is marked, and the
///   next try waits `minInterval` (no tight loop). Three failures in a row log one `phone alerts failing: <status>` event.
/// - Every wait counts awake time (`AwakeTime.uptime`), never wall-clock differences.
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

    private var lastNormalAt: TimeInterval?
    private var retryNotBefore: TimeInterval = -.infinity
    private var consecutiveFailures = 0
    private var failureAlerted = false

    /// `channel` nil: built from the owner's settings each tick (so a changed setting applies at once), with credentials read from
    /// `vault` without prompting. `awake` is the awake-time clock; tests drive it by hand.
    public init(store: Store, vault: any SecretVault, channel: (any PushChannel)? = nil,
                transport: any PushTransport = URLSessionPushTransport(),
                awake: @escaping @Sendable () -> TimeInterval = { AwakeTime.uptime() },
                clock: @escaping @Sendable () -> Date = { Store.now() }) {
        self.store = store; self.vault = vault; self.injected = channel; self.transport = transport
        self.awake = awake; self.clock = clock
    }

    /// One pass. `onlyStopNotice` is the hook for Task 7c: while `engineStopped` holds, only the stop notice may be pushed, so
    /// nothing else is sent (7c replaces this early return with the stop-notice path).
    public func tick(now: Date, onlyStopNotice: Bool = false) async {
        if onlyStopNotice { return }
        guard let prefs = try? store.ownerPrefs(), prefs.pushProvider != nil else { return }
        let uptime = awake()
        guard uptime >= retryNotBefore else { return }

        let channel: any PushChannel
        do {
            guard let made = try injected ?? PushChannels.make(prefs: prefs, vault: vault, transport: transport) else { return }
            channel = made
        } catch {
            await failed(status: nil, text: "\(error)", detail: "not configured", uptime: uptime, now: now, company: nil)
            return
        }

        guard var asks = try? store.dueAskNotices(forPush: true), let notices = try? store.duePushNotices() else { return }
        guard !asks.isEmpty || !notices.isEmpty else { return }
        if prefs.pushDetail == .titles {
            // Titles are agent text: redacted before they leave. A store that cannot redact yet sends nothing (fail closed).
            do { asks = try asks.map { var d = $0; d.ask.title = try store.redact(d.ask.title); return d } } catch { return }
        }
        let tz = store.ownerTimeZone()
        let planned = NoticeDelivery.pushPlan(dueAsks: asks, notices: notices, prefs: prefs, now: now, tz: tz)
        guard !planned.isEmpty else { return }

        let dayStart = Self.ownerDayStart(now, tz: tz)
        guard var counts = try? store.pushCounts(since: dayStart) else { return }
        for push in planned {
            if !push.urgent, let last = lastNormalAt, uptime - last < Self.minInterval { continue }
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
                await failed(status: r.status, text: r.error ?? "failed", detail: push.urgent ? "urgent" : "normal", uptime: uptime, now: now,
                             company: push.companyId)
                return
            }
        }
    }

    private func sendFinal(_ channel: any PushChannel, now: Date, uptime: TimeInterval) async {
        let r = await channel.send(title: "Brahma", body: Self.capNotice, priority: .normal, deepLink: nil)
        if r.ok {
            try? store.logPush(ok: true, status: r.status, detail: "cap", now: clock())
        } else {
            await failed(status: r.status, text: r.error ?? "failed", detail: "cap", uptime: uptime, now: now, company: nil)
        }
    }

    private func failed(status: Int?, text: String, detail: String, uptime: TimeInterval, now: Date, company: String?) async {
        try? store.logPush(ok: false, status: status, detail: String(Store.flat(text, max: 120)), now: clock())
        retryNotBefore = uptime + Self.minInterval
        consecutiveFailures += 1
        guard consecutiveFailures >= Self.failureAlertAfter, !failureAlerted else { return }
        failureAlerted = true
        let label = status.map(String.init) ?? Store.flat(text, max: 60)
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

import Testing
import Foundation
import GRDB
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import BrahmaCore

/// A channel that records what it was asked to send and answers from a script (default: 200). Nothing here touches the network.
final class FakePushChannel: PushChannel, @unchecked Sendable {
    struct Sent: Equatable { var title: String; var body: String; var priority: PushPriority; var deepLink: String? }
    private let lock = NSLock()
    private var _sent: [Sent] = []
    private var script: [(ok: Bool, status: Int?, error: String?)] = []
    private var fallback: (ok: Bool, status: Int?, error: String?) = (true, 200, nil)

    var sent: [Sent] { lock.lock(); defer { lock.unlock() }; return _sent }
    func answer(_ results: [(ok: Bool, status: Int?, error: String?)]) { lock.lock(); script = results; lock.unlock() }
    func answerAlways(_ r: (ok: Bool, status: Int?, error: String?)) { lock.lock(); fallback = r; lock.unlock() }

    private func record(_ s: Sent) -> (ok: Bool, status: Int?, error: String?) {
        lock.withLock {
            _sent.append(s)
            return script.isEmpty ? fallback : script.removeFirst()
        }
    }

    func send(title: String, body: String, priority: PushPriority, deepLink: String?) async -> (ok: Bool, status: Int?, error: String?) {
        record(Sent(title: title, body: body, priority: priority, deepLink: deepLink))
    }
}

/// A hand-driven awake clock.
final class AwakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    var value: TimeInterval { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

/// Records the request instead of sending it.
final class RecordingTransport: PushTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    private func append(_ r: URLRequest) { lock.withLock { _requests.append(r) } }
    func perform(_ request: URLRequest) async -> (status: Int?, error: String?) {
        append(request)
        return (200, nil)
    }
}

@Suite(.scratch) struct PushTests {
    let ny = TimeZone(identifier: "America/New_York")!
    func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }
    /// Midday in the owner's zone: outside quiet hours.
    var noon: Date { date("2026-06-10T12:00:00-04:00") }

    struct Rig {
        var store: Store
        var company: Company
        var eng: Agent
        var channel: FakePushChannel
        var awake: AwakeBox
        var dispatcher: PushDispatcher
        var vault: MemoryVault
    }

    /// A store with phone alerts on (ntfy), a fake channel, a hand-driven awake clock; quiet hours off unless asked.
    func rig(detail: PushDetail = .counts, quiet: Bool = false) throws -> Rig {
        let store = try Store.inMemory()
        try store.setOwnerTimeZone("America/New_York")
        let company = try store.createCompany(name: "Acme", goal: "Ship it", workspacesRoot: try tempDir())
        let eng = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "sonnet")
        try store.setPush(provider: .ntfy, topic: "long-random-topic-9f3a")
        var prefs = try store.ownerPrefs()
        prefs.quietEnabled = quiet
        prefs.pushDetail = detail
        try store.updateOwnerPrefs(prefs)
        let channel = FakePushChannel(), awake = AwakeBox(), vault = MemoryVault()
        let dispatcher = PushDispatcher(store: store, vault: vault, channel: channel, awake: { awake.value }, clock: { Date(timeIntervalSince1970: 1_781_107_200) })
        return Rig(store: store, company: company, eng: eng, channel: channel, awake: awake, dispatcher: dispatcher, vault: vault)
    }

    @discardableResult
    func ask(_ r: Rig, _ title: String, kind: AskKind = .other) throws -> Ask {
        // The dev opt-out: these tests file far more than the per-agent quota.
        try r.store.propose(companyId: r.company.id, by: .agent(r.eng.id), kind: kind, risk: .high, category: kind == .other ? "general" : nil,
                            title: title, summary: "why", payload: nil, viaOwner: true, quotaExempt: .devHook)
    }

    func urgentNotice(_ r: Rig, _ title: String = "Disk full") throws {
        try r.store.writer.write { db in
            try r.store.notifyOwner(db: db, companyId: r.company.id, kind: .system, urgency: .urgent, title: title, body: "x", now: Store.now())
        }
    }

    func pushedAt(_ r: Rig, _ ask: Ask) throws -> Date? {
        try r.store.writer.read { try Date.fetchOne($0, sql: "SELECT pushedAt FROM ask WHERE id = ?", arguments: [ask.id]) }
    }

    // MARK: Privacy

    @Test func countsModeSendsNoAgentText() async throws {
        let r = try rig()
        let hostile = try ask(r, "steal $SECRET and visit https://evil.example/x")
        try r.store.notifyOwner(companyId: r.company.id, title: "Agent wrote this", body: "and this")
        await r.dispatcher.tick(now: noon)
        let sent = r.channel.sent
        #expect(sent.count == 1)
        let all = sent.map { $0.title + "\n" + $0.body }.joined()
        #expect(!all.contains("SECRET") && !all.contains("evil") && !all.contains("Agent wrote") && !all.contains("and this"))
        #expect(sent[0].body == "Brahma: 1 thing needs you" || sent[0].body == "Brahma: 2 things need you")
        // One ask alone is worded by its kind, the company and nothing else.
        let r2 = try rig()
        try ask(r2, "steal $SECRET")
        await r2.dispatcher.tick(now: noon)
        #expect(r2.channel.sent.map(\.body) == ["Acme: decision approval waiting"])
        #expect(r2.channel.sent.allSatisfy { $0.deepLink == nil })
        _ = hostile
    }

    @Test func titlesModeFlattensAndCaps() async throws {
        let r = try rig(detail: .titles)
        try ask(r, "line one\nline two\u{1B}[31m " + String(repeating: "x", count: 150))
        await r.dispatcher.tick(now: noon)
        let body = try #require(r.channel.sent.first).body
        #expect(!body.contains("\n") && !body.contains("\u{1B}"))
        #expect(body.hasPrefix("line one line two"))
        #expect(body.count <= NoticeDelivery.maxPushTitle)
        #expect(body.hasSuffix("…"))
        // Notice text is never sent, even in titles mode.
        let r2 = try rig(detail: .titles)
        try r2.store.notifyOwner(companyId: r2.company.id, title: "secret-ish notice title", body: "body text")
        await r2.dispatcher.tick(now: noon)
        let sent = try #require(r2.channel.sent.first)
        #expect(!(sent.title + sent.body).contains("notice title") && !(sent.title + sent.body).contains("body text"))
    }

    @Test func titlesAreRedactedBeforeTheyLeave() async throws {
        let r = try rig(detail: .titles)
        try r.store.setSecret(companyId: r.company.id, name: "STRIPE_KEY", value: "sk_live_abcdef123456", isTest: false, vault: r.vault)
        _ = try r.store.reloadRedactorIfNeeded(vault: r.vault)
        // Filed before the secret was known to the redactor would be stored raw; build such an ask directly.
        let a = try ask(r, "pay with a-title")
        try await r.store.writer.write { try $0.execute(sql: "UPDATE ask SET title = ? WHERE id = ?", arguments: ["pay sk_live_abcdef123456 now", a.id]) }
        await r.dispatcher.tick(now: noon)
        let body = try #require(r.channel.sent.first).body
        #expect(!body.contains("sk_live_abcdef123456"))
        #expect(body.contains("redacted"))
    }

    // MARK: Urgency, quiet hours, coalescing, cap

    @Test func urgentBreaksQuietHours() async throws {
        let r = try rig(quiet: true)
        let night = date("2026-06-11T02:00:00-04:00")
        try ask(r, "normal one")
        try urgentNotice(r)
        await r.dispatcher.tick(now: night)
        #expect(r.channel.sent.count == 1)
        #expect(r.channel.sent[0].priority == .urgent)
        // An engineAlert ask is always urgent; a blocked count of 3 makes a normal ask urgent (the plan, pure).
        let a = try ask(r, "x")
        var alert = a; alert.kind = .engineAlert
        let plan = NoticeDelivery.pushPlan(dueAsks: [(alert, "Acme", 0, nil)], notices: [], prefs: try r.store.ownerPrefs(), now: night, tz: ny)
        #expect(plan.count == 1 && plan[0].urgent && plan[0].body == "Acme: engine alert waiting")
        let blocked = NoticeDelivery.pushPlan(dueAsks: [(a, "Acme", 3, "eng")], notices: [], prefs: try r.store.ownerPrefs(), now: night, tz: ny)
        #expect(blocked.count == 1 && blocked[0].urgent)
    }

    @Test func normalHeldUntilQuietEnds() async throws {
        let r = try rig(quiet: true)
        let a = try ask(r, "wait for morning")
        await r.dispatcher.tick(now: date("2026-06-11T01:00:00-04:00"))
        #expect(r.channel.sent.isEmpty)
        #expect(try pushedAt(r, a) == nil)
        // Quiet hours end at 08:00 owner time; the held ask goes then.
        let quiet = try #require(try r.store.ownerPrefs().quietHours)
        let end = try #require(quiet.nextEnd(after: date("2026-06-11T01:00:00-04:00"), tz: ny))
        #expect(end == date("2026-06-11T08:00:00-04:00"))
        await r.dispatcher.tick(now: end)
        #expect(r.channel.sent.count == 1)
        #expect(try pushedAt(r, a) != nil)
    }

    @Test func coalescesToOnePerFiveMinutes() async throws {
        #expect(PushDispatcher.minInterval == 300)
        let r = try rig()
        for i in 0..<5 { try ask(r, "Ask \(i)") }
        await r.dispatcher.tick(now: noon)
        #expect(r.channel.sent.map(\.body) == ["Brahma: 5 things need you"])
        // New items inside the window wait; an urgent one does not.
        let late = try ask(r, "later")
        r.awake.advance(120)
        await r.dispatcher.tick(now: noon)
        #expect(r.channel.sent.count == 1)
        try urgentNotice(r)
        await r.dispatcher.tick(now: noon)
        #expect(r.channel.sent.count == 2 && r.channel.sent[1].priority == .urgent)
        // 300 awake seconds after the last normal push (at 270 it still waits) the held one goes.
        r.awake.advance(150)
        await r.dispatcher.tick(now: noon)
        #expect(r.channel.sent.count == 2)
        r.awake.advance(40)
        await r.dispatcher.tick(now: noon)
        #expect(r.channel.sent.count == 3)
        #expect(r.channel.sent[2].body == "Acme: decision approval waiting")
        #expect(try pushedAt(r, late) != nil)
    }

    @Test func dailyCapThenFinalPush() async throws {
        #expect(PushDispatcher.dailyCap == 30)
        let r = try rig()
        for _ in 0..<32 {
            try urgentNotice(r)
            await r.dispatcher.tick(now: noon)
        }
        // 30 pushes, then one "more waiting" push, then silence.
        #expect(r.channel.sent.count == 31)
        #expect(r.channel.sent.prefix(30).allSatisfy { $0.priority == .urgent })
        #expect(r.channel.sent[30].body == PushDispatcher.capNotice)
        #expect(try r.store.duePushNotices().count == 2, "the held ones stay due")
        // The next owner day starts afresh.
        let tomorrow = noon.addingTimeInterval(24 * 3600)
        let r2 = PushDispatcher(store: r.store, vault: r.vault, channel: r.channel, awake: { r.awake.value }, clock: { tomorrow })
        await r2.tick(now: tomorrow)
        #expect(r.channel.sent.count == 33, "the two held ones go the next day")
        _ = r2
    }

    // MARK: Marking and failures

    @Test func marksOnlyAfter2xx() async throws {
        let r = try rig()
        let a = try ask(r, "wait")
        r.channel.answerAlways((false, 500, "HTTP 500"))
        await r.dispatcher.tick(now: noon)
        #expect(r.channel.sent.count == 1)
        #expect(try pushedAt(r, a) == nil)
        // No tight loop: the next try waits a window.
        r.awake.advance(10)
        await r.dispatcher.tick(now: noon)
        #expect(r.channel.sent.count == 1)
        r.channel.answerAlways((true, 200, nil))
        r.awake.advance(300)
        await r.dispatcher.tick(now: noon)
        #expect(r.channel.sent.count == 2)
        #expect(try pushedAt(r, a) != nil)
        let log = try r.store.pushLog()
        #expect(log.map(\.ok) == [false, true] && log.map(\.status) == [500, 200])
        // A 3xx (a refused redirect) is a failure, not a success.
        #expect(PushChannels.result(status: 302, error: nil).ok == false)
        #expect(PushChannels.result(status: 204, error: nil).ok == true)
    }

    @Test func failuresLogAndAlertOnce() async throws {
        let r = try rig()
        let a = try ask(r, "wait")
        r.channel.answerAlways((false, 503, "HTTP 503"))
        for _ in 0..<5 {
            await r.dispatcher.tick(now: noon)
            r.awake.advance(301)
        }
        #expect(r.channel.sent.count == 5)
        let errors = try r.store.events(afterId: 0, companyId: r.company.id).filter { $0.kind == .error }
        #expect(errors.map(\.text) == ["phone alerts failing: 503"], "one alert after 3 failures, not one per failure")
        #expect(try r.store.engineHold() == nil, "never an engine hold")
        #expect(try pushedAt(r, a) == nil)
        // A success resets the count; a later streak alerts again.
        r.channel.answerAlways((true, 200, nil))
        await r.dispatcher.tick(now: noon)
        #expect(try pushedAt(r, a) != nil)
        let b = try ask(r, "again")
        r.channel.answerAlways((false, 429, "HTTP 429"))
        for _ in 0..<4 {
            r.awake.advance(301)
            await r.dispatcher.tick(now: noon)
        }
        let again = try r.store.events(afterId: 0, companyId: r.company.id).filter { $0.kind == .error }.map(\.text)
        #expect(again == ["phone alerts failing: 503", "phone alerts failing: 429"])
        _ = b
    }

    // MARK: Request shape (built, never sent)

    @Test func ntfyRequestShape() throws {
        let channel = try NtfyChannel(server: "https://ntfy.example.org/base/", topic: "long_topic-1", token: "tk_abc")
        let req = channel.request(title: "Brahma", body: "Acme: deploy approval waiting", priority: .urgent, deepLink: nil)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://ntfy.example.org/base/long_topic-1")
        #expect(req.value(forHTTPHeaderField: "Title") == "Brahma")
        #expect(req.value(forHTTPHeaderField: "Priority") == "5")
        #expect(req.value(forHTTPHeaderField: "Tags") == "rotating_light")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tk_abc")
        #expect(req.value(forHTTPHeaderField: "Click") == nil)
        #expect(String(decoding: req.httpBody ?? Data(), as: UTF8.self) == "Acme: deploy approval waiting")
        #expect(req.timeoutInterval == 10 && req.httpShouldHandleCookies == false)
        // Without a token there is no Authorization header; normal priority is 3; headers cannot be split or carry controls.
        let plain = try NtfyChannel(server: "https://ntfy.sh", topic: "abc", token: nil)
        let p = plain.request(title: "A\r\nX-Evil: 1", body: "b", priority: .normal, deepLink: nil)
        #expect(p.url?.absoluteString == "https://ntfy.sh/abc")
        #expect(p.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(p.value(forHTTPHeaderField: "Priority") == "3" && p.value(forHTTPHeaderField: "Tags") == "bell")
        #expect(p.value(forHTTPHeaderField: "Title") == "A  X-Evil: 1")
        #expect(p.value(forHTTPHeaderField: "X-Evil") == nil)
        let accent = plain.request(title: "Café", body: "b", priority: .normal, deepLink: nil)
        #expect(accent.value(forHTTPHeaderField: "Title")?.hasPrefix("=?UTF-8?B?") == true)
    }

    @Test func ntfyTokenAndTopicComeFromPrefsAndVault() throws {
        let vault = MemoryVault()
        // Stored bound to the server it is for (`PushSettings` does this; a raw value is refused).
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken,
                      value: try OwnerCredential.boundNtfyToken("tk_from_vault", server: OwnerPrefs.defaultPushServer))
        var prefs = OwnerPrefs.defaults
        prefs.pushProvider = .ntfy; prefs.pushTopic = "mytopic"
        let channel = try #require(try PushChannels.make(prefs: prefs, vault: vault) as? NtfyChannel)
        let req = channel.request(title: "t", body: "b", priority: .normal, deepLink: nil)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tk_from_vault")
        prefs.pushProvider = nil
        #expect(try PushChannels.make(prefs: prefs, vault: vault) == nil)
    }

    @Test func pushoverRequestShape() throws {
        let vault = MemoryVault()
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverAppToken, value: "app-token-1")
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverUserKey, value: "user-key&1")
        var prefs = OwnerPrefs.defaults
        prefs.pushProvider = .pushover
        let channel = try #require(try PushChannels.make(prefs: prefs, vault: vault) as? PushoverChannel)
        let req = channel.request(title: "Brahma", body: "Brahma: 3 things need you", priority: .urgent, deepLink: nil)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.pushover.net/1/messages.json")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "token=app-token-1&user=user-key%261&title=Brahma&message=Brahma%3A%203%20things%20need%20you&priority=1")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        // A missing credential means no channel (the push fails and retries; it never prompts).
        #expect(throws: PushError.missingCredential("Pushover user key")) {
            try vault.delete(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverUserKey)
            _ = try PushChannels.make(prefs: prefs, vault: vault)
        }
    }

    @Test func nonHTTPSServerRefused() throws {
        #expect(throws: PushError.notHTTPS) { try NtfyChannel(server: "http://ntfy.sh", topic: "abc", token: nil) }
        #expect(throws: PushError.notHTTPS) { try NtfyChannel(server: "ftp://ntfy.sh", topic: "abc", token: nil) }
        #expect(throws: PushError.notHTTPS) { try NtfyChannel(server: "ntfy.sh", topic: "abc", token: nil) }
        #expect(throws: PushError.badServer) { try NtfyChannel(server: "https://user:pw@ntfy.sh", topic: "abc", token: nil) }
        #expect(throws: PushError.badServer) { try NtfyChannel(server: "https://ntfy.sh/?x=1", topic: "abc", token: nil) }
        #expect(throws: PushError.badTopic) { try NtfyChannel(server: "https://ntfy.sh", topic: "a/b", token: nil) }
        #expect(throws: PushError.badTopic) { try NtfyChannel(server: "https://ntfy.sh", topic: "", token: nil) }
        // The stored setting is refused too, so it can never be saved.
        let store = try Store.inMemory()
        #expect(throws: SettingsError.self) { try store.setPush(provider: .ntfy, topic: "abc", server: "http://ntfy.sh") }
        #expect(try store.ownerPrefs().pushProvider == nil)
        // A saved ntfy provider with a broken setup fails the push; nothing is sent in plain text.
        let session = URLSessionPushTransport.makeSession()
        let c = session.configuration
        #expect(c.timeoutIntervalForRequest == 10 && c.timeoutIntervalForResource == 10)
        #expect(c.httpCookieStorage == nil && c.httpShouldSetCookies == false && c.urlCache == nil)
        session.invalidateAndCancel()
    }

    @Test func redirectsAreRefused() {
        var seen: URLRequest? = URLRequest(url: URL(string: "https://example.org")!)
        let delegate = URLSessionPushTransport.RefuseRedirects()
        let session = URLSessionPushTransport.makeSession()
        let task = session.dataTask(with: URL(string: "https://example.org")!)
        let response = HTTPURLResponse(url: URL(string: "https://example.org")!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://evil.example"])!
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: URL(string: "http://evil.example")!)) { seen = $0 }
        #expect(seen == nil)
        session.invalidateAndCancel()
    }

    // MARK: Credentials

    @Test func pushTokensNeverInCompanySecrets() throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let vault = MemoryVault()
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken, value: "tk_super_secret_token")
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverAppToken, value: "app_super_secret_token")
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverUserKey, value: "user_super_secret_key")
        try store.setPush(provider: .pushover)
        // Never a secret row, in any company; the redactor's agent list has none; nothing in a company's vault slot.
        #expect(try store.writer.read { try SecretMeta.fetchCount($0) } == 0)
        #expect(try store.secrets(companyId: company.id).isEmpty)
        #expect(try store.secretsVersion() == "0:")
        _ = try store.reloadRedactorIfNeeded(vault: vault)
        #expect(store.redactor.apply("tk_super_secret_token app_super_secret_token") == "tk_super_secret_token app_super_secret_token")
        #expect(try vault.value(companyId: company.id, name: OwnerCredential.ntfyToken) == nil)
        #expect(OwnerCredential.scope == "owner")
        // The prefs row holds provider, server, topic and detail only.
        let prefs = try store.ownerPrefs()
        let dump = "\(prefs)"
        #expect(!dump.contains("super_secret"))
    }

    // MARK: Switching on

    @Test func switchingOnDoesNotFloodWithOldNotices() async throws {
        let store = try Store.inMemory()
        try store.setOwnerTimeZone("America/New_York")
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        for i in 0..<10 { try store.notifyOwner(companyId: company.id, title: "old \(i)", body: "b") }
        try store.setPush(provider: .ntfy, topic: "abc")
        #expect(try store.duePushNotices().isEmpty)
        try store.notifyOwner(companyId: company.id, title: "new", body: "b")
        #expect(try store.duePushNotices().map(\.title) == ["new"])
    }

    @Test func offSendsNothing() async throws {
        let r = try rig()
        try ask(r, "x")
        try r.store.setPush(provider: nil)
        await r.dispatcher.tick(now: noon)
        #expect(r.channel.sent.isEmpty)
        // The Task 7c hook: while only the stop notice may go, nothing else does.
        try r.store.setPush(provider: .ntfy, topic: "abc")
        await r.dispatcher.tick(now: noon, onlyStopNotice: true)
        #expect(r.channel.sent.isEmpty)
    }

    @Test func engineTickRunsThePushStepDetached() async throws {
        let store = try Store.inMemory()
        let root = try tempDir()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: root.appending(path: "ws"))
        try store.setPush(provider: .ntfy, topic: "abc")
        var prefs = try store.ownerPrefs(); prefs.quietEnabled = false
        try store.updateOwnerPrefs(prefs)
        try store.notifyOwner(companyId: c.id, title: "t", body: "b")
        let channel = FakePushChannel()
        let o = Orchestrator(store: store, runner: FakeTurnRunner(),
                             paths: BrahmaPaths(home: root.appending(path: "h"), workspaces: root.appending(path: "ws")),
                             mcpExecutable: "/x", pushChannel: channel)
        await o.tick()
        try await o.waitUntilIdle(timeout: .seconds(300))
        #expect(channel.sent.map(\.body) == ["Brahma: 1 thing needs you"])
        #expect(try store.duePushNotices().isEmpty)
    }
}

/// A channel whose send waits until its task is cancelled (an engine shutdown mid-send).
final class HangingPushChannel: PushChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = 0
    var started: Int { lock.withLock { _started } }
    func send(title: String, body: String, priority: PushPriority, deepLink: String?) async -> (ok: Bool, status: Int?, error: String?) {
        lock.withLock { _started += 1 }
        while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
        return (false, nil, "timed out")
    }
}

/// Fix round 1: fail closed to counts while secrets are held, no per-tick vault reads, the token bound to its server.
extension PushTests {
    /// A store with phone alerts on and NO injected channel: the dispatcher builds its own from the prefs and `vault`.
    func liveRig(vault: any SecretVault, transport: RecordingTransport) throws -> (store: Store, company: Company, eng: Agent, awake: AwakeBox, dispatcher: PushDispatcher) {
        let store = try Store.inMemory()
        try store.setOwnerTimeZone("America/New_York")
        let company = try store.createCompany(name: "Acme", goal: "Ship it", workspacesRoot: try tempDir())
        let eng = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "sonnet")
        try PushSettings.setNtfy(store: store, vault: vault, topic: "long-random-topic-9f3a", server: nil, token: nil)
        var prefs = try store.ownerPrefs(); prefs.quietEnabled = false
        try store.updateOwnerPrefs(prefs)
        let awake = AwakeBox()
        let d = PushDispatcher(store: store, vault: vault, transport: transport, awake: { awake.value }, clock: { Date(timeIntervalSince1970: 1_781_107_200) })
        return (store, company, eng, awake, d)
    }

    func file(_ store: Store, _ company: Company, _ eng: Agent, _ title: String) throws {
        try store.propose(companyId: company.id, by: .agent(eng.id), kind: .other, risk: .high, category: "general",
                          title: title, summary: "why", payload: nil, viaOwner: true, quotaExempt: .devHook)
    }

    // MARK: S6

    @Test func titlesFallBackToCountsWhileSecretsAreHeld() async throws {
        let r = try rig(detail: .titles)
        try r.store.setSecret(companyId: r.company.id, name: "STRIPE_KEY", value: "sk_live_abcdef123456", isTest: false, vault: r.vault)
        _ = try r.store.reloadRedactorIfNeeded(vault: r.vault)
        // A second secret whose value does not load: the store is held (the redactor is loaded but incomplete).
        try r.store.setSecret(companyId: r.company.id, name: "OTHER_KEY", value: "other-value-123456", isTest: false, vault: r.vault)
        _ = try r.store.reloadRedactorIfNeeded(vault: MemoryVault(), logFailures: false)
        #expect(r.store.secretsHeld && r.store.redactor.hasLoaded)
        try ask(r, "plain readable agent title")
        await r.dispatcher.tick(now: noon)
        let sent = try #require(r.channel.sent.first)
        #expect(!(sent.title + sent.body).contains("readable"))
        #expect(sent.body == "Acme: decision approval waiting")
        // Urgent pushes too: an engine alert in titles mode is worded by the engine while held.
        let a = try ask(r, "urgent agent words")
        try await r.store.writer.write { try $0.execute(sql: "UPDATE ask SET kind = ? WHERE id = ?", arguments: [AskKind.engineAlert.rawValue, a.id]) }
        await r.dispatcher.tick(now: noon)
        #expect(r.channel.sent.count == 2)
        #expect(!r.channel.sent[1].body.contains("urgent agent") && r.channel.sent[1].body == "Acme: engine alert waiting")
    }

    /// INT-M2: a secret added since the last redactor load (the redactor is behind the database, though not "held") also
    /// forces counts: a title could carry the new value before the background reload runs.
    @Test func titlesFallBackToCountsWhenAReloadIsPending() async throws {
        let r = try rig(detail: .titles)
        try r.store.setSecret(companyId: r.company.id, name: "STRIPE_KEY", value: "sk_live_abcdef123456", isTest: false, vault: r.vault)
        _ = try r.store.reloadRedactorIfNeeded(vault: r.vault)
        try r.store.setSecret(companyId: r.company.id, name: "NEW_KEY", value: "brand-new-value-98765", isTest: false, vault: r.vault)
        #expect(!r.store.secretsHeld); #expect(try r.store.secretsReloadNeeded())
        try ask(r, "brand-new-value-98765 in a readable title")
        await r.dispatcher.tick(now: noon)
        let sent = try #require(r.channel.sent.first)
        #expect(!(sent.title + sent.body).contains("brand-new-value"))
        #expect(!(sent.title + sent.body).contains("readable"))
        #expect(sent.body == "Acme: decision approval waiting")
    }

    @Test func titlesFallBackToCountsWhenRedactionThrows() async throws {
        let r = try rig(detail: .titles)
        try ask(r, "plain readable agent title")
        let throwing = PushDispatcher(store: r.store, vault: r.vault, channel: r.channel, awake: { r.awake.value },
                                      clock: { Date(timeIntervalSince1970: 1_781_107_200) },
                                      redact: { _ in throw SecretError.secretsNotLoaded })
        await throwing.tick(now: noon)
        let sent = try #require(r.channel.sent.first)
        #expect(!(sent.title + sent.body).contains("readable"))
        #expect(sent.body == "Acme: decision approval waiting" && sent.title == "Brahma")
        // A redactor that has never loaded in this process (a database with secrets, reopened) also sends counts only.
        let dir = try tempDir()
        let path = dir.appending(path: "b.sqlite").path
        do {
            let s = try Store(path: path)
            try s.setOwnerTimeZone("America/New_York")
            let c = try s.createCompany(name: "Acme", goal: "g", workspacesRoot: dir.appending(path: "ws"))
            let e = try s.hire(companyId: c.id, name: "eng", role: "engineer", model: "sonnet")
            try s.setSecret(companyId: c.id, name: "STRIPE_KEY", value: "sk_live_abcdef123456", isTest: false, vault: MemoryVault())
            try s.setPush(provider: .ntfy, topic: "abc")
            var p = try s.ownerPrefs(); p.quietEnabled = false; p.pushDetail = .titles
            try s.updateOwnerPrefs(p)
            try file(s, c, e, "pay sk_live_abcdef123456 now")
        }
        let reopened = try Store(path: path)
        #expect(!reopened.redactor.hasLoaded)
        let ch = FakePushChannel()
        await PushDispatcher(store: reopened, vault: MemoryVault(), channel: ch, awake: { 1000 }).tick(now: noon)
        let only = try #require(ch.sent.first)
        #expect(!(only.title + only.body).contains("sk_live") && only.body == "Acme: decision approval waiting")
    }

    @Test func titlesCapTheJoinedAgentTextAt80() async throws {
        let r = try rig(detail: .titles)
        for i in 0..<4 { try ask(r, "\(i)" + String(repeating: "y", count: 59)) }
        await r.dispatcher.tick(now: noon)
        let body = try #require(r.channel.sent.first).body
        let agentPart = body.components(separatedBy: " | +").first ?? body
        #expect(agentPart.count <= NoticeDelivery.maxPushTitle, "one push carries at most 80 characters of agent text: \(agentPart.count)")
        #expect(body.hasSuffix(" | +3 more") || body.hasSuffix(" | +2 more") || body.hasSuffix(" | +1 more"))
    }

    // MARK: I1, m3

    @Test func noVaultReadWhileNothingIsDueAndOnePerChange() async throws {
        let vault = ScriptedVault(), transport = RecordingTransport()
        let r = try liveRig(vault: vault, transport: transport)
        for _ in 0..<50 { await r.dispatcher.tick(now: noon); r.awake.advance(1) }
        #expect(vault.reads.isEmpty, "nothing due: no vault read")
        #expect(try r.store.pushLog().isEmpty, "nothing due: no failure row")
        try file(r.store, r.company, r.eng, "one")
        await r.dispatcher.tick(now: noon)
        #expect(transport.requests.count == 1)
        #expect(vault.reads == [OwnerCredential.ntfyToken])
        // Later pushes reuse the channel: no second read.
        try file(r.store, r.company, r.eng, "two")
        r.awake.advance(301)
        for _ in 0..<5 { await r.dispatcher.tick(now: noon) }
        #expect(transport.requests.count == 2)
        #expect(vault.reads.count == 1)
        // A changed setting (or a stored credential) builds it again, once.
        try PushSettings.setNtfy(store: r.store, vault: vault, topic: "another-random-topic", server: nil, token: nil)
        try file(r.store, r.company, r.eng, "three")
        r.awake.advance(301)
        for _ in 0..<5 { await r.dispatcher.tick(now: noon) }
        #expect(transport.requests.count == 3)
        #expect(transport.requests.last?.url?.lastPathComponent == "another-random-topic")
        #expect(vault.reads.count == 2)
    }

    /// A vault that, like the Keychain one, may be interactive; it records whether each read could have prompted.
    final class ModalVault: SecretVault, @unchecked Sendable {
        final class Log: @unchecked Sendable {
            let lock = NSLock()
            var reads: [(name: String, interactive: Bool)] = []
        }
        let inner: MemoryVault, log: Log, interactive: Bool
        init(inner: MemoryVault = MemoryVault(), log: Log = Log(), interactive: Bool) {
            self.inner = inner; self.log = log; self.interactive = interactive
        }
        var reads: [(name: String, interactive: Bool)] { log.lock.withLock { log.reads } }
        func set(companyId: String, name: String, value: String) throws { try inner.set(companyId: companyId, name: name, value: value) }
        func delete(companyId: String, name: String) throws { try inner.delete(companyId: companyId, name: name) }
        func value(companyId: String, name: String) throws -> String? {
            log.lock.withLock { log.reads.append((name, interactive)) }
            return try inner.value(companyId: companyId, name: name)
        }
        func nonInteractive() -> any SecretVault { ModalVault(inner: inner, log: log, interactive: false) }
    }

    @Test func dispatcherReadsTheVaultNonInteractively() async throws {
        // Handed an interactive vault, the dispatcher still reads without any possible prompt.
        let vault = ModalVault(interactive: true), transport = RecordingTransport()
        let r = try liveRig(vault: vault, transport: transport)
        try file(r.store, r.company, r.eng, "one")
        await r.dispatcher.tick(now: noon)
        #expect(transport.requests.count == 1)
        #expect(vault.reads.map(\.name) == [OwnerCredential.ntfyToken])
        #expect(vault.reads.allSatisfy { !$0.interactive })
        // The engine's own dispatcher (and its redactor reloads) hold the non-interactive vault too.
        let orchestrator = Orchestrator(store: r.store, runner: FakeTurnRunner(), paths: BrahmaPaths(home: try tempDir(), workspaces: try tempDir()),
                                        mcpExecutable: "/usr/local/bin/brahma", vault: ModalVault(inner: vault.inner, log: vault.log, interactive: true))
        #expect((orchestrator.vault as? ModalVault)?.interactive == false)
        try file(r.store, r.company, r.eng, "two")
        await orchestrator.pushDispatcher.tick(now: noon)
        #expect(vault.reads.count == 2)
        #expect(vault.reads.allSatisfy { !$0.interactive })
        // Only an explicit owner command (`brahma push test`) reads with the interactive vault it was given.
        _ = try await PushDispatcher.sendTest(store: r.store, vault: vault, transport: transport)
        #expect(vault.reads.last?.interactive == true)
    }

    @Test func missingCredentialIsOneFailurePerEpisode() async throws {
        let vault = ScriptedVault(), transport = RecordingTransport()
        let r = try liveRig(vault: vault, transport: transport)
        // Pushover on, but its credentials are not in the vault.
        try r.store.setPush(provider: .pushover)
        for _ in 0..<5 { await r.dispatcher.tick(now: noon); r.awake.advance(301) }
        #expect(try r.store.pushLog().isEmpty, "nothing due: no failure")
        #expect(try r.store.events(afterId: 0, companyId: r.company.id).filter { $0.kind == .error }.isEmpty)
        try file(r.store, r.company, r.eng, "due")
        for _ in 0..<6 { await r.dispatcher.tick(now: noon); r.awake.advance(301) }
        #expect(try r.store.pushLog().map(\.ok) == [false], "one row per episode, not one per window")
        let errors = try r.store.events(afterId: 0, companyId: r.company.id).filter { $0.kind == .error }.map(\.text)
        #expect(errors.count == 1 && errors[0].hasPrefix("phone alerts failing"))
        #expect(transport.requests.isEmpty)
        // Storing the credentials ends the episode: the next window sends.
        try PushSettings.setPushover(store: r.store, vault: vault, appToken: "app-token-12345", userKey: "user-key-12345")
        await r.dispatcher.tick(now: noon)
        #expect(transport.requests.count == 1)
        #expect(try r.store.pushLog().map(\.ok) == [false, true])
    }

    // MARK: I2

    @Test func changingTheNtfyServerOrProviderDropsTheToken() throws {
        let store = try Store.inMemory(), vault = MemoryVault()
        func token() throws -> String? { try vault.value(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken) }
        try PushSettings.setNtfy(store: store, vault: vault, topic: "abc", server: "https://a.example", token: "tk_for_server_a")
        #expect(try token() != nil)
        // Same server, new topic: the token stays.
        try PushSettings.setNtfy(store: store, vault: vault, topic: "abcd", server: nil, token: nil)
        #expect(try token() != nil)
        let kept = try #require(try PushChannels.make(prefs: store.ownerPrefs(), vault: vault) as? NtfyChannel)
        #expect(kept.request(title: "t", body: "b", priority: .normal, deepLink: nil).value(forHTTPHeaderField: "Authorization") == "Bearer tk_for_server_a")
        // Another server: the token is deleted, and the new server gets no Authorization header.
        try PushSettings.setNtfy(store: store, vault: vault, topic: "abcd", server: "https://b.example", token: nil)
        #expect(try token() == nil)
        let plain = try #require(try PushChannels.make(prefs: store.ownerPrefs(), vault: vault) as? NtfyChannel)
        #expect(plain.request(title: "t", body: "b", priority: .normal, deepLink: nil).value(forHTTPHeaderField: "Authorization") == nil)
        // Another provider: the token is deleted too.
        try PushSettings.setNtfy(store: store, vault: vault, topic: "abcd", server: nil, token: "tk_for_server_b")
        try PushSettings.setPushover(store: store, vault: vault, appToken: "app-token-12345", userKey: "user-key-12345")
        #expect(try token() == nil)
        // Switching back to ntfy drops the Pushover credentials.
        try PushSettings.setNtfy(store: store, vault: vault, topic: "abcd", server: nil, token: nil)
        #expect(try vault.value(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverAppToken) == nil)
        // Off deletes everything.
        try PushSettings.setNtfy(store: store, vault: vault, topic: "abcd", server: nil, token: "tk_again_123")
        try PushSettings.turnOff(store: store, vault: vault)
        #expect(try token() == nil && store.ownerPrefs().pushProvider == nil)
    }

    @Test func aTokenIsOnlySentToTheServerItWasStoredFor() throws {
        let store = try Store.inMemory(), vault = MemoryVault()
        try PushSettings.setNtfy(store: store, vault: vault, topic: "abc", server: "https://a.example", token: "tk_for_server_a")
        // A server changed without PushSettings (the token survives in the vault): the token is refused, nothing is sent.
        try store.setPush(provider: .ntfy, topic: "abc", server: "https://b.example")
        #expect(throws: PushError.tokenForOtherServer) { _ = try PushChannels.make(prefs: store.ownerPrefs(), vault: vault) }
        // A raw token with no server bound to it is refused as well.
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken, value: "tk_unbound_token")
        #expect(throws: PushError.tokenForOtherServer) { _ = try PushChannels.make(prefs: store.ownerPrefs(), vault: vault) }
        // The same server spelled with a trailing slash or upper-case host still matches.
        try PushSettings.setNtfy(store: store, vault: vault, topic: "abc", server: "https://B.example/", token: "tk_for_server_b")
        try store.setPush(provider: .ntfy, topic: "abc", server: "https://b.example")
        #expect(try PushChannels.make(prefs: store.ownerPrefs(), vault: vault) != nil)
        // A vault that cannot answer fails the build; it is never "no token".
        let broken = ScriptedVault(); broken.unavailable = true
        #expect(throws: PushError.credentialUnavailable(OwnerCredential.ntfyToken)) { _ = try PushChannels.make(prefs: store.ownerPrefs(), vault: broken) }
    }

    // MARK: m2

    @Test func credentialsWithControlCharactersAreRefused() throws {
        let store = try Store.inMemory(), vault = MemoryVault()
        for bad in ["tk_abc\r\nX-Evil: 1", "tk_abc\n", "tk\u{0}abc", "tk abc", "tk_é_abc", ""] {
            #expect(throws: PushError.badCredential("ntfy token")) {
                try PushSettings.setNtfy(store: store, vault: vault, topic: "abc", server: nil, token: bad)
            }
            #expect(throws: PushError.badCredential("ntfy token")) { _ = try NtfyChannel(server: "https://ntfy.sh", topic: "abc", token: bad.isEmpty ? "\r" : bad) }
            #expect(throws: PushError.badCredential("Pushover user key")) {
                try PushSettings.setPushover(store: store, vault: vault, appToken: "app-token-12345", userKey: bad)
            }
        }
        #expect(try vault.value(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken) == nil)
        #expect(try store.ownerPrefs().pushProvider == nil, "nothing stored on a refusal")
        #expect(throws: PushError.badCredential("Pushover app token")) { _ = try PushoverChannel(appToken: "a\nb", userKey: "user-key-1") }
        // A bad value already in the vault is refused when used, too.
        try PushSettings.setNtfy(store: store, vault: vault, topic: "abc", server: nil, token: nil)
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken, value: OwnerPrefs.defaultPushServer + "\ntk\rabc")
        #expect(throws: PushError.badCredential("ntfy token")) { _ = try PushChannels.make(prefs: store.ownerPrefs(), vault: vault) }
    }

    // MARK: m5, m6, m7

    @Test func formEncodingUsesTheASCIIUnreservedSetOnly() {
        let body = String(decoding: PushURL.formEncode([("t", "Café ß-._~"), ("k", "aZ09")]), as: UTF8.self)
        #expect(body == "t=Caf%C3%A9%20%C3%9F-._~&k=aZ09")
    }

    @Test func theSessionInstallsTheRedirectRefusingDelegate() {
        let session = URLSessionPushTransport.makeSession()
        #expect(session.delegate is URLSessionPushTransport.RefuseRedirects)
        session.invalidateAndCancel()
    }

    @Test func cancellationAtShutdownIsNotAFailure() async throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        try store.setPush(provider: .ntfy, topic: "abc")
        var prefs = try store.ownerPrefs(); prefs.quietEnabled = false
        try store.updateOwnerPrefs(prefs)
        try store.notifyOwner(companyId: company.id, title: "t", body: "b")
        let channel = HangingPushChannel()
        let dispatcher = PushDispatcher(store: store, vault: MemoryVault(), channel: channel, awake: { 1000 })
        let pass = Task { await dispatcher.tick(now: Store.now()) }
        while channel.started == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        pass.cancel()
        await pass.value
        #expect(try store.pushLog().isEmpty, "a cancelled send is not logged as a failure")
        #expect(try store.events(afterId: 0, companyId: company.id).filter { $0.kind == .error }.isEmpty)
        #expect(try store.duePushNotices().count == 1, "and nothing is marked")
    }

    // MARK: CLI

    private func cli(_ args: [String], home: URL, stdin: String? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        let p = Process()
        p.executableURL = brahmaExecutableURL()
        p.arguments = args
        p.environment = cliEnvironment(home: home)
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        try p.run()
        feedChildInput(inp, Data((stdin ?? "").utf8))
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    @Test func cliDropsTheTokenOnAServerChangeAndRefusesControlCharacters() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        let vault = FileVault(home: ownerPaths(home).home)
        func token() throws -> String? { try vault.value(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken) }
        let bad = try cli(["prefs", "set", "push", "ntfy", "long-topic-1", "--token-stdin"], home: home, stdin: "tk_abc\rX-Evil: 1\n")
        #expect(bad.status == 1, "\(bad.stdout)")
        #expect(bad.stderr.contains("control characters") || bad.stderr.contains("printable"))
        #expect(try token() == nil)
        let set = try cli(["prefs", "set", "push", "ntfy", "long-topic-1", "--server", "https://a.example", "--token-stdin"], home: home, stdin: "tk_server_a_123\n")
        #expect(set.status == 0, "\(set.stderr)")
        #expect(try token() != nil)
        let moved = try cli(["prefs", "set", "push", "ntfy", "long-topic-1", "--server", "https://b.example"], home: home)
        #expect(moved.status == 0, "\(moved.stderr)")
        #expect(try token() == nil, "a token is never carried to another server")
    }
}

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

@Suite struct PushTests {
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
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken, value: "tk_from_vault")
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
        try vault.set(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverUserKey, value: "user key&1")
        var prefs = OwnerPrefs.defaults
        prefs.pushProvider = .pushover
        let channel = try #require(try PushChannels.make(prefs: prefs, vault: vault) as? PushoverChannel)
        let req = channel.request(title: "Brahma", body: "Brahma: 3 things need you", priority: .urgent, deepLink: nil)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.pushover.net/1/messages.json")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
        #expect(body == "token=app-token-1&user=user%20key%261&title=Brahma&message=Brahma%3A%203%20things%20need%20you&priority=1")
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
        try await o.waitUntilIdle(timeout: .seconds(20))
        #expect(channel.sent.map(\.body) == ["Brahma: 1 thing needs you"])
        #expect(try store.duePushNotices().isEmpty)
    }
}

import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

/// The embedded preview's guards (Plan L Task 11 fix round 1, C1 + I1): the content rule list that keeps every load of an
/// agent-built page on its own origin, the CSP user script, fail-closed preparation, and the focus guard.
@MainActor @Suite(.scratch) struct PreviewGuardsTests {
    static let loopback = URL(string: "http://127.0.0.1:47100/")!

    /// Applies a content rule list the way WebKit does: every rule in order; a matching `block` blocks, a matching
    /// `ignore-previous-rules` clears what came before. `url-filter` is a regex over the whole (canonical) URL,
    /// case-insensitive unless `url-filter-is-case-sensitive`; a missing `resource-type` matches every type.
    static func blocked(_ url: String, as type: String = "fetch", rules json: String) throws -> Bool {
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        var blocked = false
        for rule in rules {
            let trigger = try #require(rule["trigger"] as? [String: Any])
            let action = try #require(rule["action"] as? [String: Any])
            let filter = try #require(trigger["url-filter"] as? String)
            let caseSensitive = trigger["url-filter-is-case-sensitive"] as? Bool ?? false
            let regex = try NSRegularExpression(pattern: filter, options: caseSensitive ? [] : [.caseInsensitive])
            guard regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil else { continue }
            if let types = trigger["resource-type"] as? [String], !types.contains(type) { continue }
            switch action["type"] as? String {
            case "block": blocked = true
            case "ignore-previous-rules": blocked = false
            default: Issue.record("unexpected action \(action)")
            }
        }
        return blocked
    }

    @Test func ruleListIsBlockAllThenOriginOnly() throws {
        let json = try PreviewGuards.ruleList(origin: Self.loopback)
        let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let shape = rules.map { rule -> String in
            let t = rule["trigger"] as? [String: Any] ?? [:]
            let a = rule["action"] as? [String: Any] ?? [:]
            let types = (t["resource-type"] as? [String]).map { " " + $0.joined(separator: ",") } ?? ""
            return "\(a["type"] as? String ?? "?") \(t["url-filter"] as? String ?? "?")\(types)"
        }
        #expect(shape == [
            "block .*",
            #"ignore-previous-rules ^http://127\.0\.0\.1:47100/"#,
            "ignore-previous-rules ^about:blank$",
            "ignore-previous-rules ^data: image",
        ])
    }

    @Test func pageCannotReachAnyOtherHost() throws {
        let json = try PreviewGuards.ruleList(origin: Self.loopback)
        for url in ["https://example.com/", "https://example.com/x.js", "http://127.0.0.1:47101/", "http://localhost:47100/",
                    "http://[::1]:47100/", "http://127.0.0.1/", "ws://127.0.0.1:47100/socket", "wss://example.com/",
                    "blob:http://127.0.0.1:47100/5e1f", "file:///etc/passwd", "http://127.0.0.1:47100@evil.com/",
                    "http://127.0.0.1:47100.evil.com/", "https://127.0.0.1:47100/", "about:srcdoc", "data:text/html,<p>x"] {
            #expect(try Self.blocked(url, rules: json), "\(url)")
        }
        #expect(try Self.blocked("data:text/javascript,alert(1)", as: "script", rules: json))
        #expect(try Self.blocked("https://example.com/beacon", as: "image", rules: json))
        for url in ["http://127.0.0.1:47100/", "http://127.0.0.1:47100/app.js", "http://127.0.0.1:47100/a?b=c", "about:blank"] {
            #expect(try !Self.blocked(url, rules: json), "\(url)")
        }
        #expect(try !Self.blocked("data:image/png;base64,iVBORw0KGgo=", as: "image", rules: json))
    }

    @Test func liveOriginKeepsItsHostOnly() throws {
        let json = try PreviewGuards.ruleList(origin: URL(string: "https://Initech-Demo.pages.dev/pricing?x=1")!)
        #expect(json.contains(#"^https://initech-demo\\.pages\\.dev/"#))
        #expect(try !Self.blocked("https://initech-demo.pages.dev/", rules: json))
        #expect(try !Self.blocked("https://initech-demo.pages.dev/assets/a.css", as: "style-sheet", rules: json))
        for url in ["https://initech-demo.pages.dev.evil.com/", "http://initech-demo.pages.dev/", "https://initech-demo.pages.dev:8443/",
                    "https://xinitech-demo.pages.dev/", "https://evil.com/?u=https://initech-demo.pages.dev/"] {
            #expect(try Self.blocked(url, rules: json), "\(url)")
        }
        let port = try PreviewGuards.ruleList(origin: URL(string: "https://acme.example:8443/")!)
        #expect(try !Self.blocked("https://acme.example:8443/x", rules: port))
        #expect(try Self.blocked("https://acme.example/x", rules: port))
        let v6 = try PreviewGuards.ruleList(origin: URL(string: "http://[::1]:47100/")!)
        #expect(try !Self.blocked("http://[::1]:47100/x", rules: v6))
        #expect(try Self.blocked("http://127.0.0.1:47100/x", rules: v6))
    }

    @Test func unsafeOriginsAreRefused() {
        for s in ["http://a_b.example/", "file:///etc/passwd", "javascript:alert(1)", "ws://127.0.0.1:47100/", "http:///x",
                  "about:blank", "http://[fe80::1%25en0]:47100/", "http://user:pw@127.0.0.1:47100/"] {
            guard let url = URL(string: s) else { continue }
            #expect(throws: (any Error).self, "\(s)") { try PreviewGuards.ruleList(origin: url) }
        }
    }

    @Test func originIsTheLoadedURLsSchemeHostAndPort() throws {
        #expect(try PreviewGuards.origin(of: URL(string: "http://127.0.0.1:47100/a/b?c=d#e")!).absoluteString == "http://127.0.0.1:47100/")
        #expect(try PreviewGuards.origin(of: URL(string: "HTTPS://Acme.Example/x")!).absoluteString == "https://acme.example/")
        #expect(try PreviewGuards.origin(of: URL(string: "http://[::1]:47100/x")!).absoluteString == "http://[::1]:47100/")
        #expect(throws: (any Error).self) { try PreviewGuards.origin(of: URL(string: "file:///tmp/x")!) }
    }

    @Test func cspScriptCarriesThePolicyAndNoBridge() {
        #expect(PreviewGuards.contentSecurityPolicy == "default-src 'self'; script-src 'self' 'unsafe-inline'; "
            + "style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'")
        let js = PreviewGuards.cspScript
        #expect(js.contains("Content-Security-Policy"))
        #expect(js.contains(PreviewGuards.contentSecurityPolicy))
        #expect(!js.contains("messageHandlers") && !js.contains("webkit."))
    }

    @Test func prepareFailsClosed() async {
        var compiled: [String] = []
        let ok = await PreviewGuards.prepare(origin: Self.loopback) { id, json in compiled.append(id); return json.count }
        guard case .ready(let n, let script) = ok else { Issue.record("expected ready, got \(ok)"); return }
        #expect(n > 0 && script == PreviewGuards.cspScript)
        #expect(compiled.count == 1 && compiled[0].hasPrefix("brahma.preview."))

        struct Broken: Error {}
        let failed = await PreviewGuards.prepare(origin: Self.loopback) { _, _ -> Int in throw Broken() }
        guard case .failed(let message) = failed else { Issue.record("expected failed, got \(failed)"); return }
        #expect(message.hasPrefix("The preview's content rules did not compile"))
        #expect(!failed.showsWebView)

        compiled = []
        let refused = await PreviewGuards.prepare(origin: URL(string: "file:///etc/passwd")!) { id, json in compiled.append(id); return 1 }
        #expect(!refused.showsWebView)
        #expect(compiled.isEmpty)
        #expect(ok.showsWebView)
    }

    // MARK: Focus guard (I1)

    static let now: TimeInterval = 1000

    @Test func mouseDownMustBeFreshAndInside() {
        let inside = PreviewFocusEvent(kind: .mouseDown, timestamp: Self.now - 0.05, inWindow: true, hitsView: true)
        #expect(PreviewFocusGuard.allows(inside, now: Self.now, holdsFocus: false))
        var stale = inside
        stale.timestamp = Self.now - 2
        #expect(!PreviewFocusGuard.allows(stale, now: Self.now, holdsFocus: false))
        var outside = inside
        outside.hitsView = false
        #expect(!PreviewFocusGuard.allows(outside, now: Self.now, holdsFocus: false))
        var otherWindow = inside
        otherWindow.inWindow = false
        #expect(!PreviewFocusGuard.allows(otherWindow, now: Self.now, holdsFocus: false))
        var future = inside
        future.timestamp = Self.now + 5
        #expect(!PreviewFocusGuard.allows(future, now: Self.now, holdsFocus: false))
    }

    @Test func keyEventsOnlyWhenHoldingFocusOrTabbing() {
        // The owner typing in the composer: a key event in the window, but the web view does not hold focus.
        let typing = PreviewFocusEvent(kind: .keyDown, timestamp: Self.now, inWindow: true, hitsView: false, keyCode: 0)
        #expect(!PreviewFocusGuard.allows(typing, now: Self.now, holdsFocus: false))
        #expect(PreviewFocusGuard.allows(typing, now: Self.now, holdsFocus: true))
        let tab = PreviewFocusEvent(kind: .keyDown, timestamp: Self.now - 0.01, inWindow: true, hitsView: false, keyCode: 48)
        #expect(PreviewFocusGuard.allows(tab, now: Self.now, holdsFocus: false))
        var staleTab = tab
        staleTab.timestamp = Self.now - 3
        #expect(!PreviewFocusGuard.allows(staleTab, now: Self.now, holdsFocus: false))
        let keyUp = PreviewFocusEvent(kind: .keyUp, timestamp: Self.now, inWindow: true, hitsView: false, keyCode: 48)
        #expect(!PreviewFocusGuard.allows(keyUp, now: Self.now, holdsFocus: false))
        let other = PreviewFocusEvent(kind: .other, timestamp: Self.now, inWindow: true, hitsView: true)
        #expect(!PreviewFocusGuard.allows(other, now: Self.now, holdsFocus: false))
        #expect(!PreviewFocusGuard.allows(nil, now: Self.now, holdsFocus: true))
    }
}

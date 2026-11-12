import Foundation
import BrahmaCore

/// What keeps an agent-built page inside the preview (Plan L Task 11 fix round 1, C1). Top-level navigation is already held
/// to the origin by `PreviewNavigationPolicy`; these guards hold every other load (fetch, XHR, images, scripts, styles,
/// fonts, media, frames, websockets) to it as well, so the page cannot use the owner's app to reach the network:
/// - a WebKit content rule list that blocks everything, then lets through only the preview's own origin (scheme, host and
///   port), `about:blank`, and `data:` images;
/// - a Content-Security-Policy `<meta>` added at document start by a user script (defense in depth; the rule list is the
///   guard). The page gets no script message handlers.
/// Preparing them fails closed: when the rule list cannot be built or compiled, no web view is made.
public enum PreviewGuards {
    /// The meta CSP (controller ruling). `frame-ancestors` is not listed: a `<meta>` policy ignores it by spec, and the
    /// preview never embeds in a frame anyway.
    public static let contentSecurityPolicy = "default-src 'self'; script-src 'self' 'unsafe-inline'; "
        + "style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'"

    /// Runs at document start in the main frame: inserts the CSP `<meta>`, and `x-dns-prefetch-control: off` (a page's
    /// `<link rel=dns-prefetch>` is a DNS lookup, not a load the rule list sees; Task 12 probe), as the first children of
    /// `<head>` as soon as `<head>` exists (a mutation observer, which fires before the first parser-inserted script runs). No bridge to the app.
    public static let cspScript: String = {
        let policy = contentSecurityPolicy.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
            (function () {
              var policy = "\(policy)";
              function add(head) {
                if (head.querySelector("meta[data-brahma-csp]")) { return; }
                var m = document.createElement("meta");
                m.setAttribute("http-equiv", "Content-Security-Policy");
                m.setAttribute("content", policy);
                m.setAttribute("data-brahma-csp", "");
                head.insertBefore(m, head.firstChild);
                var p = document.createElement("meta");
                p.setAttribute("http-equiv", "x-dns-prefetch-control");
                p.setAttribute("content", "off");
                head.insertBefore(p, head.firstChild);
              }
              if (document.head) { add(document.head); return; }
              var o = new MutationObserver(function () {
                if (document.head) { o.disconnect(); add(document.head); }
              });
              o.observe(document, { childList: true, subtree: true });
            })();
            """
    }()

    static let refusal = WorkError.invalid("this preview's address can't be guarded, so it isn't shown")

    /// `scheme://host[:port]/` of the URL the view loads (not of the engine's `resolvedURL`): http or https, a host of
    /// `[a-z0-9.-]` or a bracketed IPv6 literal, no user or password. The port is kept only when it is not the scheme's default.
    public static func origin(of url: URL) throws -> URL {
        let (scheme, host, port) = try parts(url)
        guard let origin = URL(string: "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")/") else { throw refusal }
        return origin
    }

    /// The content rule list JSON (WebKit's format): a block-all rule, then `ignore-previous-rules` for the origin prefix
    /// (`^<scheme>://<escaped host>[:port]/`: the trailing `/` stops `@userinfo` and longer-host tricks), `about:blank`, and
    /// `data:` for images only. WebKit matches canonical URLs, which drop the scheme's default port.
    public static func ruleList(origin url: URL) throws -> String {
        let (scheme, host, port) = try parts(url)
        let escapedHost = host.replacingOccurrences(of: ".", with: "\\.").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let prefix = "^\(scheme)://\(escapedHost)\(port.map { ":\($0)" } ?? "")/"
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": prefix], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^about:blank$"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:", "resource-type": ["image"]], "action": ["type": "ignore-previous-rules"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.withoutEscapingSlashes, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Builds the rule list for `origin` and compiles it with `compile(identifier, json)` (WebKit's
    /// `WKContentRuleListStore` in the app). Any failure is `.failed`: the caller shows an error state and makes no web view.
    @MainActor
    public static func prepare<R>(origin: URL, compile: (String, String) async throws -> R) async -> PreviewGuardState<R> {
        let json: String
        let identifier: String
        do {
            json = try ruleList(origin: origin)
            identifier = "brahma.preview." + StableHash.fnv1a64(try Self.origin(of: origin).absoluteString)
        } catch {
            return .failed("The preview's address can't be guarded, so it isn't shown.")
        }
        do {
            return .ready(try await compile(identifier, json), cspScript: cspScript)
        } catch {
            return .failed("The preview's content rules did not compile, so it isn't shown: \(error.localizedDescription)")
        }
    }

    private static func parts(_ url: URL) throws -> (scheme: String, host: String, port: Int?) {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = c.scheme?.lowercased(),
              ["http", "https"].contains(scheme), c.user == nil, c.password == nil,
              let rawHost = c.percentEncodedHost?.lowercased(), !rawHost.isEmpty else { throw refusal }
        let plain = rawHost.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" }
        let v6 = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") && rawHost.count > 2
            && rawHost.dropFirst().dropLast().unicodeScalars.allSatisfy { ("a"..."f").contains($0) || ("0"..."9").contains($0) || $0 == ":" || $0 == "." }
        guard plain || v6, !rawHost.hasPrefix("."), !rawHost.hasPrefix("-") else { throw refusal }
        // URLComponents reports an IPv6 host bracketed in `percentEncodedHost`; keep the brackets for the URL form.
        let defaultPort = scheme == "https" ? 443 : 80
        if let p = c.port, !(1...65535).contains(p) { throw refusal }
        let port = c.port.flatMap { $0 == defaultPort ? nil : $0 }
        return (scheme, rawHost, port)
    }
}

/// The result of `PreviewGuards.prepare`: the compiled rule list and the CSP script, or why the preview is not shown.
public enum PreviewGuardState<RuleList> {
    case ready(RuleList, cspScript: String)
    case failed(String)

    /// Only a ready state ever makes a web view.
    public var showsWebView: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// What the focus guard needs from an `NSEvent` (I1), so the rule is testable without AppKit.
public struct PreviewFocusEvent: Equatable, Sendable {
    public enum Kind: Sendable { case mouseDown, keyDown, keyUp, other }
    public var kind: Kind
    /// `NSEvent.timestamp` (seconds since boot, like `ProcessInfo.systemUptime`).
    public var timestamp: TimeInterval
    /// The event belongs to the web view's window.
    public var inWindow: Bool
    /// Hit-testing the window's content view at the event's location lands in the web view or a descendant.
    public var hitsView: Bool
    public var keyCode: UInt16

    public init(kind: Kind, timestamp: TimeInterval, inWindow: Bool, hitsView: Bool, keyCode: UInt16 = 0) {
        self.kind = kind; self.timestamp = timestamp; self.inWindow = inWindow; self.hitsView = hitsView; self.keyCode = keyCode
    }
}

/// When the preview's web view may become first responder: a page's `focus()` or `autofocus` must never take the keyboard
/// from the composer. `NSApp.currentEvent` keeps the last dequeued event after dispatch, so freshness is checked too.
public enum PreviewFocusGuard {
    /// How old the current event may be.
    public static let freshness: TimeInterval = 0.3
    /// Tab (with or without Shift): the window's key-view loop.
    public static let tabKeyCode: UInt16 = 48

    /// A mouse-down that is fresh and hit-tests into the view; a key event only when the view (or a descendant) already
    /// holds focus, or a fresh Tab/back-tab keyDown. Nothing else.
    public static func allows(_ event: PreviewFocusEvent?, now: TimeInterval, holdsFocus: Bool) -> Bool {
        guard let event, event.inWindow else { return false }
        let age = now - event.timestamp
        let fresh = age >= -0.05 && age <= freshness
        switch event.kind {
        case .mouseDown:
            return fresh && event.hitsView
        case .keyDown:
            return holdsFocus || (fresh && event.keyCode == tabKeyCode)
        case .keyUp:
            return holdsFocus
        case .other:
            return false
        }
    }
}

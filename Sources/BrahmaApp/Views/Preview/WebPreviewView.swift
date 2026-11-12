import SwiftUI
import WebKit
import BrahmaCore
import BrahmaAppModel

/// The embedded page of a preview surface or the live site (L-2): a `WKWebView` over a non-persistent data store, inside an
/// `AgentBuiltFrame`, sized by the viewport preset. It loads `WebPreviewInput.url` (surface) or `.liveURL` (live) for the
/// owner's `path`, navigates only where `PreviewNavigationPolicy.allowsWeb` passes, opens no windows and never takes
/// keyboard focus by itself. `reloadKey` changes (surface commit, live release, path, viewport) reload the page.
/// Every load the page makes is held to the origin of the URL it loads (`PreviewGuards`: a content rule list plus a meta
/// CSP); when those can't be prepared, no web view is made (fail closed).
struct WebPreviewView: View {
    let url: URL
    let origin: URL
    var path = "/"
    var viewport: PreviewViewport = .desktop
    let builtBy: String
    /// Anything that must reload the page when it changes (the surface's commit, the live release ref).
    var reloadKey = ""
    @State private var blockedHost: String?
    /// The guards prepared for `guardsOrigin`; nil while preparing.
    @State private var guards: PreviewGuardState<WKContentRuleList>?
    @State private var guardsOrigin: String?

    private var target: Result<URL, WorkError> {
        do {
            if url.port != nil, LoopbackURL.isLoopback(host: url.host ?? "") {
                return .success(try WebPreviewInput.url(origin: origin, path: path, port: url.port!))
            }
            return .success(try WebPreviewInput.liveURL(origin: origin, path: path))
        } catch let e as WorkError {
            return .failure(e)
        } catch {
            return .failure(.invalid("\(error)"))
        }
    }

    var body: some View {
        AgentBuiltFrame(label: builtBy) {
            ZStack(alignment: .top) {
                BrahmaTheme.bg0
                switch target {
                case .failure(let e):
                    MonoEmptyState("INVALID PREVIEW PATH", detail: e.message)
                case .success(let load):
                    guarded(load)
                }
                if let blockedHost {
                    StatusChip(label: "BLOCKED NAVIGATION TO " + blockedHost, color: BrahmaTheme.warning)
                        .padding(BrahmaTheme.spaceS)
                        .transition(.opacity)
                        .task(id: blockedHost) {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation(BrahmaTheme.medium) { self.blockedHost = nil }
                        }
                }
            }
            .clipped()
        }
    }

    /// The web view only once the guards for the loaded URL's own origin are ready (not the engine's `resolvedURL`, which may
    /// say `localhost` while the load is `127.0.0.1`); an error state, and no web view, when they fail.
    @ViewBuilder private func guarded(_ load: URL) -> some View {
        let loadOrigin = try? PreviewGuards.origin(of: load)
        let key = loadOrigin?.absoluteString ?? "invalid"
        Group {
            switch guardsOrigin == key ? guards : nil {
            case .ready(let rules, let csp)?:
                if let loadOrigin { viewportBody(load, origin: loadOrigin, rules: rules, csp: csp).id(key) }
            case .failed(let message)?:
                MonoEmptyState("PREVIEW NOT SHOWN", detail: message)
            case nil:
                Color.clear
            }
        }
        .task(id: key) {
            guards = nil
            guardsOrigin = key
            guard let loadOrigin else {
                guards = .failed("The preview's address can't be guarded, so it isn't shown.")
                return
            }
            let prepared = await PreviewGuards.prepare(origin: loadOrigin) { id, json in
                try await Self.compile(id, json)
            }
            if guardsOrigin == key { guards = prepared }
        }
    }

    @MainActor private static func compile(_ id: String, _ json: String) async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else { throw WorkError.invalid("no content rule list store") }
        guard let list = try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) else {
            throw WorkError.invalid("no content rule list")
        }
        return list
    }

    /// Non-desktop viewports: the web view's frame is the preset scaled down to fit (never up), and WebKit's `pageZoom`
    /// renders the page at that scale, so the page's layout viewport stays the preset (no SwiftUI transform over an
    /// AppKit view, whose hit-testing and clipping are unreliable). Clipped to its frame.
    @ViewBuilder private func viewportBody(_ load: URL, origin: URL, rules: WKContentRuleList, csp: String) -> some View {
        if let size = viewport.size {
            GeometryReader { geo in
                let w = CGFloat(size.width), h = CGFloat(size.height)
                let scale = max(0.1, min(1, geo.size.width / w, geo.size.height / h))
                web(load, origin: origin, rules: rules, csp: csp, zoom: scale)
                    .frame(width: (w * scale).rounded(), height: (h * scale).rounded())
                    .clipped()
                    .overlay {
                        if viewport == .iphone {
                            RoundedRectangle(cornerRadius: BrahmaTheme.radiusLarge).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipped()
        } else {
            web(load, origin: origin, rules: rules, csp: csp, zoom: 1)
        }
    }

    private func web(_ load: URL, origin: URL, rules: WKContentRuleList, csp: String, zoom: CGFloat) -> LoopbackWebView {
        LoopbackWebView(url: load, origin: origin, rules: rules, cspScript: csp, zoom: zoom, reloadKey: reloadKey) { host in
            withAnimation(BrahmaTheme.fast) { blockedHost = host }
        }
    }
}

// MARK: - WKWebView host

/// The AppKit side: a focus-refusing `WKWebView`, same-origin navigation only, no new windows. Made only with the
/// origin's compiled content rule list and the CSP user script installed; it has no script message handlers.
private struct LoopbackWebView: NSViewRepresentable {
    let url: URL
    let origin: URL
    let rules: WKContentRuleList
    let cspScript: String
    let zoom: CGFloat
    let reloadKey: String
    let onBlocked: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(origin: origin, onBlocked: onBlocked) }

    func makeNSView(context: Context) -> QuietWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        let content = WKUserContentController()
        content.add(rules)
        content.addUserScript(WKUserScript(source: cspScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = content
        let view = QuietWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        view.pageZoom = zoom
        context.coordinator.load(url, key: reloadKey, into: view)
        return view
    }

    func updateNSView(_ view: QuietWebView, context: Context) {
        context.coordinator.origin = origin
        context.coordinator.onBlocked = onBlocked
        if abs(view.pageZoom - zoom) > 0.001 { view.pageZoom = zoom }
        context.coordinator.load(url, key: reloadKey, into: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var origin: URL
        var onBlocked: (String) -> Void
        private var loaded: (URL, String)?

        init(origin: URL, onBlocked: @escaping (String) -> Void) {
            self.origin = origin
            self.onBlocked = onBlocked
        }

        /// Loads once per (url, key); the app never calls `makeFirstResponder` here.
        func load(_ url: URL, key: String, into view: WKWebView) {
            if let loaded, loaded.0 == url, loaded.1 == key { return }
            loaded = (url, key)
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, action.targetFrame != nil, PreviewNavigationPolicy.allowsWeb(url, origin: origin) else {
                onBlocked(action.request.url?.host?.lowercased() ?? "unknown")
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// `window.open` and `target=_blank`: nothing opens.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            onBlocked(action.request.url?.host?.lowercased() ?? "unknown")
            return nil
        }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor () -> Void) { completionHandler() }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
    }
}

/// A `WKWebView` that becomes first responder only through the owner's own input (`PreviewFocusGuard`): a fresh mouse-down
/// that hit-tests into it, a key event while it already holds focus, or a fresh Tab/back-tab. A page's `focus()` or
/// `autofocus` cannot take the keyboard from the composer.
final class QuietWebView: WKWebView {
    override func becomeFirstResponder() -> Bool {
        guard PreviewFocusGuard.allows(focusEvent(NSApp.currentEvent), now: ProcessInfo.processInfo.systemUptime,
                                       holdsFocus: holdsFocus) else { return false }
        return super.becomeFirstResponder()
    }

    /// The window's first responder is this view or one of its descendants.
    private var holdsFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    private func focusEvent(_ event: NSEvent?) -> PreviewFocusEvent? {
        guard let event, let window else { return nil }
        let kind: PreviewFocusEvent.Kind
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        case .keyDown: kind = .keyDown
        case .keyUp, .flagsChanged: kind = .keyUp
        default: kind = .other
        }
        var hits = false
        if kind == .mouseDown, event.window === window, let content = window.contentView {
            let point = content.superview.map { $0.convert(event.locationInWindow, from: nil) } ?? event.locationInWindow
            if let hit = content.hitTest(point) { hits = hit === self || hit.isDescendant(of: self) }
        }
        let isKey = kind == .keyDown || kind == .keyUp
        return PreviewFocusEvent(kind: kind, timestamp: event.timestamp, inWindow: event.window === window, hitsView: hits,
                                 keyCode: isKey && event.type != .flagsChanged ? event.keyCode : 0)
    }
}

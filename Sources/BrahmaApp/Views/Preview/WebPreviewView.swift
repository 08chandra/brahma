import SwiftUI
import WebKit
import BrahmaCore
import BrahmaAppModel

/// The embedded page of a preview surface or the live site (L-2): a `WKWebView` over a non-persistent data store, inside an
/// `AgentBuiltFrame`, sized by the viewport preset. It loads `WebPreviewInput.url` (surface) or `.liveURL` (live) for the
/// owner's `path`, navigates only where `PreviewNavigationPolicy.allowsWeb` passes, opens no windows and never takes
/// keyboard focus by itself. `reloadKey` changes (surface commit, live release, path, viewport) reload the page.
struct WebPreviewView: View {
    let url: URL
    let origin: URL
    var path = "/"
    var viewport: PreviewViewport = .desktop
    let builtBy: String
    /// Anything that must reload the page when it changes (the surface's commit, the live release ref).
    var reloadKey = ""
    @State private var blockedHost: String?

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
                    viewportBody(load)
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
        }
    }

    @ViewBuilder private func viewportBody(_ load: URL) -> some View {
        let web = LoopbackWebView(url: load, origin: origin, reloadKey: reloadKey) { host in
            withAnimation(BrahmaTheme.fast) { blockedHost = host }
        }
        if let size = viewport.size {
            GeometryReader { geo in
                let w = CGFloat(size.width), h = CGFloat(size.height)
                let scale = min(1, geo.size.width / w, geo.size.height / h)
                web
                    .frame(width: w, height: h)
                    .scaleEffect(scale, anchor: .center)
                    .frame(width: w * scale, height: h * scale)
                    .overlay {
                        if viewport == .iphone {
                            RoundedRectangle(cornerRadius: BrahmaTheme.radiusLarge).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            web
        }
    }
}

// MARK: - WKWebView host

/// The AppKit side: a focus-refusing `WKWebView`, same-origin navigation only, no new windows.
private struct LoopbackWebView: NSViewRepresentable {
    let url: URL
    let origin: URL
    let reloadKey: String
    let onBlocked: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(origin: origin, onBlocked: onBlocked) }

    func makeNSView(context: Context) -> QuietWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        let view = QuietWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        context.coordinator.load(url, key: reloadKey, into: view)
        return view
    }

    func updateNSView(_ view: QuietWebView, context: Context) {
        context.coordinator.origin = origin
        context.coordinator.onBlocked = onBlocked
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

/// A `WKWebView` that becomes first responder only for a mouse-down or key event inside it: a page's `focus()` or
/// `autofocus` cannot take the keyboard from the composer.
final class QuietWebView: WKWebView {
    override func becomeFirstResponder() -> Bool {
        guard let event = NSApp.currentEvent, event.window === window else { return false }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return false }
        case .keyDown, .keyUp, .flagsChanged:
            break
        default:
            return false
        }
        return super.becomeFirstResponder()
    }
}

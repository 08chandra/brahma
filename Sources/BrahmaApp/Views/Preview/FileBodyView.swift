import SwiftUI
import WebKit
import BrahmaCore
import BrahmaAppModel

/// One file, shown the way `FileBody` says (Plan 4a Task 9a; Collab reuses it for `file` and `resource` refs): the mode is
/// `FileBody.make(…).effectiveMode(for: provenance)`, so an agent's or an outside image is never decoded in process. Every
/// read and parse runs through `RendererCaps.parse` over the hardened `readRegularFile` (no links, no FIFOs, a size cap);
/// past the parse timeout, or when the file cannot be read, the body says `CAN'T SHOW THIS FILE`. Everything the file says
/// is agent-controlled: `Text(verbatim:)` throughout. `.gltf` (`ModelPreviewView`) and `.video` (`VideoPreviewView`) are
/// Task 9b's; a video body's PHONE FRAME choice is the host's to keep (`phoneFrameOverride`, `onPhoneFrame`).
struct FileBodyView: View {
    let file: FileBody
    let provenance: Provenance
    /// Who made the file, for the `AGENT-BUILT CONTENT` strip over a web body ("@eng-1"): empty for the owner's own files.
    var builtBy = ""
    /// The file card's PUBLISHED BY value.
    var publishedBy = ""
    /// The owner's PHONE FRAME choice for a video body when the host keeps one (`AppModel.phoneFrameOverride`), and where the
    /// chip's toggles go; with no `onPhoneFrame` the video view keeps the choice itself.
    var phoneFrameOverride: Bool? = nil
    var onPhoneFrame: ((Bool) -> Void)? = nil
    /// Whether a web body's page may run scripts (`AppModel.artifactScriptsEnabled`, final review C1). Off unless the host
    /// says so; the web view also needs WebRTC verified off before it runs any.
    var scripts = false

    init(body: FileBody, provenance: Provenance, builtBy: String = "", publishedBy: String = "",
         phoneFrameOverride: Bool? = nil, onPhoneFrame: ((Bool) -> Void)? = nil, scripts: Bool = false) {
        self.file = body
        self.provenance = provenance
        self.builtBy = builtBy
        self.publishedBy = publishedBy
        self.phoneFrameOverride = phoneFrameOverride
        self.onPhoneFrame = onPhoneFrame
        self.scripts = scripts
    }

    /// Stats the file (never reads it) and shows it.
    init(url: URL, kind: ArtifactKind, root: URL, provenance: Provenance, builtBy: String = "", publishedBy: String = "",
         phoneFrameOverride: Bool? = nil, onPhoneFrame: ((Bool) -> Void)? = nil, scripts: Bool = false) {
        self.init(body: FileBody.make(url: url, kind: kind, root: root), provenance: provenance, builtBy: builtBy, publishedBy: publishedBy,
                  phoneFrameOverride: phoneFrameOverride, onPhoneFrame: onPhoneFrame, scripts: scripts)
    }

    private var isAgentMade: Bool {
        switch provenance {
        case .agent, .external: true
        case .owner, .engine: false
        }
    }

    private var card: FileCardView {
        FileCardView(name: file.url.lastPathComponent, kind: file.kind, bytes: file.bytes, publishedBy: publishedBy, url: file.url)
    }

    var body: some View {
        Group {
            switch file.effectiveMode(for: provenance) {
            case .web:
                // SVG never runs scripts; an HTML page runs them only as the host says (`scripts`: off for an agent's, an outside
                // or a tainted page until the owner turns them on), confined by the rule list and the navigation policy, and
                // only once WebRTC is verified off.
                let web = ArtifactWebView(entry: file.url, root: file.root, kind: file.kind, javaScript: scripts && file.kind != .image)
                if isAgentMade {
                    AgentBuiltFrame(label: builtBy) { web }
                } else {
                    web.overlay(Rectangle().strokeBorder(BrahmaTheme.line, lineWidth: 1))
                }
            case .markdown:
                MarkdownFileView(url: file.url)
            case .quickLook:
                // Images reach Quick Look only for agent or outside provenance (`effectiveMode`): the thumbnail path.
                QuickLookView(url: file.url, thumbnail: file.kind == .image)
            case .image:
                ImagePreviewView(url: file.url, card: card)
            case .table:
                CSVFileView(url: file.url)
            case .fileCard:
                card
            case .text:
                TextFileView(url: file.url)
            case .gltf:
                // Only gltf/glb ≤ 20 MB arrive here (`FileBody.make`); the mesh is parsed in process by the bounds-checked loader.
                ModelPreviewView(url: file.url)
            case .video:
                VideoPreviewView(url: file.url, root: file.root, phoneFrameOverride: phoneFrameOverride, onPhoneFrame: onPhoneFrame)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Loading

/// What a file renderer has: nothing yet, its parsed content, or why not (`CAN'T SHOW THIS FILE` with the reason).
enum FileLoad<T> {
    case ready(T)
    case failed(title: String, detail: String?)

    static var timedOut: FileLoad { .failed(title: PreviewBodies.cantShowTitle, detail: PreviewBodies.tookTooLong) }
    static var unreadable: FileLoad { .failed(title: PreviewBodies.cantShowTitle, detail: "it couldn't be read") }
    static func tooLarge(_ maxBytes: Int) -> FileLoad {
        .failed(title: PreviewBodies.cantShowTitle, detail: "it is larger than \(ByteCount.string(Int64(maxBytes)))")
    }

    /// Reads `url` (at most `maxBytes`) and parses it, off-main under `RendererCaps.parse`. Nil when the caller was cancelled.
    static func load(_ url: URL, maxBytes: Int, _ parse: @escaping @Sendable (Data) throws -> T) async -> FileLoad? where T: Sendable {
        do {
            return .ready(try await RendererCaps.parse { try parse(try RendererCaps.readRegularFile(url, maxBytes: maxBytes)) })
        } catch is CancellationError {
            return nil
        } catch RendererError.timedOut {
            return .timedOut
        } catch RendererCaps.FileReadFailure.tooLarge {
            return .tooLarge(maxBytes)
        } catch {
            return .unreadable
        }
    }
}

/// `FileLoad.failed` as the body: the empty-state title and reason.
struct FileLoadFailure: View {
    let title: String
    let detail: String?

    var body: some View { MonoEmptyState(title, detail: detail) }
}

/// Byte counts for the file card and the size reasons (`1.2 MB`).
enum ByteCount {
    static func string(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }
}

// MARK: - Web (HTML and SVG)

/// The confined web view of an HTML or SVG artifact: a `WKWebView` over a non-persistent data store, made only once the
/// file-only content rule list (`PreviewGuards.artifactRuleList`: block everything, then `file:` and `about:`) has compiled,
/// loading the entry with `loadFileURL(_:allowingReadAccessTo: root)`, navigating only where
/// `PreviewNavigationPolicy.allowsArtifact` passes, opening no windows and taking focus only through the owner's input.
/// WebRTC is always off (`WebRTCGuard`); when it cannot be turned off an HTML page runs without scripts and the body says so
/// (`ArtifactScripts.webRTCNotice`). A change of `javaScript` makes a new web view (WebKit reads it only when the view is made).
private struct ArtifactWebView: View {
    let entry: URL
    let root: URL
    let kind: ArtifactKind
    let javaScript: Bool
    @State private var rules: RulesState?
    /// Whether WebRTC can be turned off in this WebKit (a probe of fresh preferences); nil until asked.
    @State private var webRTCSwitch: Bool?

    private enum RulesState {
        case ready(WKContentRuleList)
        case failed(String)
    }

    var body: some View {
        ZStack {
            BrahmaTheme.bg0
            switch rules {
            case nil:
                Color.clear
            case .failed(let message)?:
                MonoEmptyState("PREVIEW NOT SHOWN", detail: message)
            case .ready(let list)?:
                ArtifactFileWebView(entry: entry, root: root, javaScript: javaScript, rules: list)
                    .id(javaScript)
                if let webRTCSwitch, let notice = ArtifactScripts.webRTCNotice(kind: kind, webRTCOff: webRTCSwitch) {
                    VStack {
                        StatusChip(label: notice, color: BrahmaTheme.warning)
                            .padding(BrahmaTheme.spaceS)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .clipped()
        .task {
            if webRTCSwitch == nil { webRTCSwitch = WebRTCGuard.disable(WKPreferences()) }
            guard rules == nil else { return }
            do {
                rules = .ready(try await Self.compile())
            } catch {
                rules = .failed("The artifact's content rules did not compile, so it isn't shown: \(error.localizedDescription)")
            }
        }
    }

    @MainActor private static func compile() async throws -> WKContentRuleList {
        guard let store = WKContentRuleListStore.default() else { throw WorkError.invalid("no content rule list store") }
        guard let list = try await store.compileContentRuleList(forIdentifier: PreviewGuards.artifactRuleListIdentifier,
                                                                 encodedContentRuleList: PreviewGuards.artifactRuleList) else {
            throw WorkError.invalid("no content rule list")
        }
        return list
    }
}

private struct ArtifactFileWebView: NSViewRepresentable {
    let entry: URL
    let root: URL
    let javaScript: Bool
    let rules: WKContentRuleList

    func makeCoordinator() -> Coordinator { Coordinator(root: root) }

    func makeNSView(context: Context) -> QuietWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.preferences.isFraudulentWebsiteWarningEnabled = false
        // WebRTC off whatever the scripts setting (final review C1): STUN/TURN never passes the rule list. Not verified off:
        // no scripts at all.
        let webRTCOff = WebRTCGuard.disable(config.preferences)
        config.defaultWebpagePreferences.allowsContentJavaScript = ArtifactScripts.effective(allowed: javaScript, webRTCOff: webRTCOff)
        let content = WKUserContentController()
        content.add(rules)
        config.userContentController = content
        let view = QuietWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        context.coordinator.load(entry, root: root, into: view)
        return view
    }

    func updateNSView(_ view: QuietWebView, context: Context) {
        context.coordinator.root = root
        context.coordinator.load(entry, root: root, into: view)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var root: URL
        private var loaded: URL?

        init(root: URL) { self.root = root }

        /// Loads once per entry; read access stays inside the artifact's copy.
        func load(_ entry: URL, root: URL, into view: WKWebView) {
            guard loaded != entry else { return }
            loaded = entry
            view.loadFileURL(entry, allowingReadAccessTo: root)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, action.targetFrame != nil, PreviewNavigationPolicy.allowsArtifact(url, root: root) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// `window.open` and `target=_blank`: nothing opens.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor () -> Void) { completionHandler() }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }

        /// Camera and microphone: never (final review M5).
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    }
}

// MARK: - Markdown

/// A Markdown artifact through `SafeMarkdown` (links inert, images never fetched, HTML literal), at most `SafeMarkdown.maxBytes`.
private struct MarkdownFileView: View {
    let url: URL
    @State private var load: FileLoad<AttributedString>?

    var body: some View {
        Group {
            switch load {
            case nil:
                Color.clear
            case .failed(let title, let detail)?:
                FileLoadFailure(title: title, detail: detail)
            case .ready(let document)?:
                ScrollView {
                    Text(document)
                        .font(BrahmaTheme.body)
                        .foregroundStyle(BrahmaTheme.text0)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(BrahmaTheme.spaceM)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg2)
        .task(id: url) {
            load = nil
            let result = await FileLoad<AttributedString>.load(url, maxBytes: SafeMarkdown.maxBytes) { data in
                guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw SafeMarkdownError.notText }
                return SafeMarkdown.render(text)
            }
            if let result { load = result }
        }
    }
}

// MARK: - Table (CSV, TSV)

/// A CSV or TSV artifact as a zebra grid through `CSVTable` (2000 rows × 100 columns, cells cut at 1000 characters, lines at
/// 4 KB): a `bg3` header row, then dense rows; a `TRUNCATED` chip when the parser left anything out.
private struct CSVFileView: View {
    let url: URL
    @State private var load: FileLoad<CSVTable>?

    static let cellWidth: CGFloat = 140

    var body: some View {
        Group {
            switch load {
            case nil:
                Color.clear
            case .failed(let title, let detail)?:
                FileLoadFailure(title: title, detail: detail)
            case .ready(let table)?:
                grid(table)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg2)
        .task(id: url) {
            load = nil
            let separator: Character = ArtifactKind.ext(of: url.lastPathComponent) == "tsv" ? "\t" : ","
            let result = await FileLoad<CSVTable>.load(url, maxBytes: ArtifactPolicy.maxFileBytes) { data in
                CSVTable.parse(String(decoding: data, as: UTF8.self), separator: separator)
            }
            if let result { load = result }
        }
    }

    private func grid(_ table: CSVTable) -> some View {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        return VStack(spacing: 0) {
            if columns == 0 {
                MonoEmptyState("EMPTY TABLE")
            } else {
                GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        Section {
                            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                                HStack(spacing: 0) {
                                    ForEach(0..<columns, id: \.self) { c in
                                        Text(verbatim: c < row.count ? row[c] : "")
                                            .font(BrahmaTheme.monoSmall)
                                            .foregroundStyle(BrahmaTheme.text0)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(width: Self.cellWidth, alignment: .leading)
                                            .padding(.trailing, BrahmaTheme.spaceS)
                                    }
                                }
                                .tableRow(index: index, height: BrahmaTheme.denseRowHeight)
                            }
                        } header: {
                            HStack(spacing: 0) {
                                ForEach(0..<columns, id: \.self) { c in
                                    ColumnHeader(c < table.header.count ? table.header[c] : "")
                                        .frame(width: Self.cellWidth, alignment: .leading)
                                        .padding(.trailing, BrahmaTheme.spaceS)
                                }
                            }
                            .padding(.horizontal, BrahmaTheme.spaceS)
                            .frame(height: BrahmaTheme.denseRowHeight)
                            .background(BrahmaTheme.bg3)
                            .overlay(alignment: .bottom) { Hairline() }
                        }
                    }
                    // At least the viewport wide, so a narrow table sits at the left edge rather than centered.
                    .frame(minWidth: geo.size.width, alignment: .leading)
                }
                }
            }
            Hairline()
            HStack(spacing: BrahmaTheme.spaceS) {
                MonoChip(text: "\(table.rows.count) ROWS", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                MonoChip(text: "\(columns) COLS", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                if table.truncated { StatusChip(label: "Truncated", color: BrahmaTheme.warning) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .frame(height: BrahmaTheme.denseRowHeight)
            .background(BrahmaTheme.bg2)
        }
    }
}

// MARK: - Text and code

/// A text or code artifact as capped mono lines: at most `RendererCaps.maxTextBytes`, each line through
/// `RendererCaps.truncateLine`, the first `AnsiText.maxLines` shown (the terminal's cap) with a count of what is not.
private struct TextFileView: View {
    let url: URL
    @State private var load: FileLoad<TextLines>?

    struct TextLines: Sendable {
        var shown: [String]
        var omitted: Int
    }

    var body: some View {
        Group {
            switch load {
            case nil:
                Color.clear
            case .failed(let title, let detail)?:
                FileLoadFailure(title: title, detail: detail)
            case .ready(let text)?:
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(text.shown.enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line.isEmpty ? " " : line)
                                    .font(BrahmaTheme.monoSmall)
                                    .foregroundStyle(BrahmaTheme.text0)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(BrahmaTheme.spaceS)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if text.omitted > 0 {
                        Hairline()
                        HStack {
                            MonoChip(text: "+\(text.omitted) MORE LINES", color: BrahmaTheme.text2, fill: BrahmaTheme.bg3)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, BrahmaTheme.spaceS)
                        .frame(height: BrahmaTheme.denseRowHeight)
                        .background(BrahmaTheme.bg2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BrahmaTheme.bg0)
        .task(id: url) {
            load = nil
            let result = await FileLoad<TextLines>.load(url, maxBytes: RendererCaps.maxTextBytes) { data in
                let text = String(decoding: data, as: UTF8.self)
                var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                if lines.last?.isEmpty == true { lines.removeLast() }
                let shown = lines.prefix(AnsiText.maxLines).map { RendererCaps.truncateLine($0) }
                return TextLines(shown: shown, omitted: max(0, lines.count - shown.count))
            }
            if let result { load = result }
        }
    }
}

import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// Mission Control's PREVIEW panel (L-1): one `MonoChip` tab per surface (plus LIVE), the selected tab's body with its
/// header buttons, and an accessory strip above the tabs for other surfaces (L passes none; Collab puts its Show bar and
/// OPENED strip there, C7a). `inspector(body:model:)` renders one body without the tab strip, for chat's inspector split.
struct PreviewPane<Accessory: View>: View {
    let model: AppModel
    @ViewBuilder var accessory: Accessory

    init(model: AppModel, @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.model = model
        self.accessory = accessory()
    }

    var body: some View {
        let tabs = model.previewTabs
        let selected = PreviewTabs.resolve(model.selectedPreviewTab, tabs)
        Panel(title: "Preview", padded: false, accessory: {
            if let tab = tabs.first(where: { $0.id == selected }) {
                MonoChip(text: tab.statusTitle, color: Self.toneColor(tab.tone), fill: BrahmaTheme.bg4)
            }
        }, content: {
            VStack(spacing: 0) {
                accessory
                if !tabs.isEmpty {
                    tabStrip(tabs, selected: selected)
                    Hairline()
                }
                Self.inspector(body: model.previewBody(forTab: selected), model: model, tabId: selected)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        })
    }

    /// One body with its header buttons and no tab strip. The pane's own body uses the same function.
    static func inspector(body: PreviewBody, model: AppModel, tabId: String? = nil) -> some View {
        PreviewBodyView(body: body, model: model, tabId: tabId ?? PreviewTabs.resolve(model.selectedPreviewTab, model.previewTabs))
    }

    private func tabStrip(_ tabs: [PreviewTab], selected: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: BrahmaTheme.spaceXS) {
                ForEach(tabs) { tab in
                    let isSelected = tab.id == selected
                    Button { model.selectPreviewTab(tab.id) } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Self.toneColor(tab.tone)).frame(width: 6, height: 6)
                            Text(verbatim: tab.title).font(BrahmaTheme.monoTiny)
                        }
                        .foregroundStyle(isSelected ? BrahmaTheme.text0 : BrahmaTheme.text1)
                        .padding(.horizontal, 6)
                        .frame(minHeight: BrahmaTheme.chipHeight)
                        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(isSelected ? BrahmaTheme.bg4 : BrahmaTheme.bg3))
                        .overlay(alignment: .bottom) {
                            if isSelected { Rectangle().fill(BrahmaTheme.accent).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text(verbatim: "\(tab.title) · \(tab.statusTitle)"))
                    .accessibilityLabel(Text(verbatim: "\(tab.title), \(tab.statusTitle)"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    // Plan C C7a: only the OPENED tab closes (history keeps it for Back).
                    if tab.closable {
                        Button { model.closeOpened() } label: {
                            Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(BrahmaTheme.text2)
                                .frame(width: 14, height: BrahmaTheme.chipHeight).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Close")
                        .accessibilityLabel(Text("Close the opened ref"))
                    }
                }
            }
            .padding(.horizontal, BrahmaTheme.spaceS)
            .padding(.vertical, BrahmaTheme.spaceXS)
        }
        .background(BrahmaTheme.bg3)
    }

    static func toneColor(_ tone: PreviewTone) -> Color {
        switch tone {
        case .good: BrahmaTheme.success
        case .busy: BrahmaTheme.running
        case .bad: BrahmaTheme.danger
        case .idle: BrahmaTheme.text2
        case .warn: BrahmaTheme.warning
        case .accent: BrahmaTheme.accent
        }
    }
}

// MARK: - One body

/// A header row (Restart, Open in Browser, the PATH field and the VIEWPORT chip) over the body itself.
private struct PreviewBodyView: View {
    let body_: PreviewBody
    let model: AppModel
    let tabId: String?
    @State private var path = "/"
    @State private var pathDraft = "/"
    @State private var viewport: PreviewViewport = .desktop
    @State private var customViewport = ""
    @State private var customShown = false
    @State private var customError: String?

    init(body: PreviewBody, model: AppModel, tabId: String?) {
        self.body_ = body
        self.model = model
        self.tabId = tabId
    }

    private var surfaceId: String? { tabId.flatMap(PreviewTabID.surfaceId) }
    private var isLive: Bool { tabId == PreviewTabID.live }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                header
                Hairline()
            }
            content
        }
        .task(id: tabId) {
            viewport = PreviewViewportStore.load(tabId: tabId)
            path = "/"
            pathDraft = "/"
        }
    }

    // MARK: Header

    /// The full row when it fits the pane, else a compact one (icon-only buttons with help, the chip without its caption), so
    /// the row never pushes the pane wider than its column.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(compact: false)
            headerRow(compact: true)
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .padding(.vertical, BrahmaTheme.spaceXS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrahmaTheme.bg2)
    }

    @ViewBuilder private func headerRow(compact: Bool) -> some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            if let surfaceId {
                Button { Task { await model.restartPreview(surfaceId: surfaceId) } } label: {
                    Label("Restart", systemImage: "arrow.clockwise").labelStyle(compact ? AnyLabelStyle.iconOnly : .titleAndIcon)
                }
                .buttonStyle(.brahma)
                .fixedSize()
                .help("Restart this preview")
            }
            if case .web(let url, _, _) = body_ {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Open in Browser", systemImage: "safari").labelStyle(compact ? AnyLabelStyle.iconOnly : .titleAndIcon)
                }
                .buttonStyle(.brahma)
                .fixedSize()
                .help("Open in Browser")
                TextField("Path", text: $pathDraft, prompt: Text(verbatim: "/"))
                    .font(BrahmaTheme.monoSmall)
                    .brahmaField()
                    .frame(minWidth: compact ? 56 : 80, maxWidth: 220)
                    .onSubmit { path = pathDraft }
                    .accessibilityLabel(Text("Preview path"))
                viewportMenu(compact: compact)
            }
            if case .simulator(let udid) = body_ {
                Button { SimulatorLauncher.open(udid: udid) } label: {
                    Label("Open Simulator", systemImage: "iphone").labelStyle(compact ? AnyLabelStyle.iconOnly : .titleAndIcon)
                }
                .buttonStyle(.brahma)
                .fixedSize()
                .help("Open the Simulator app on this device")
            }
            if case .window(let pid) = body_ {
                Button { NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows]) } label: {
                    Label("Bring to Front", systemImage: "macwindow.on.rectangle").labelStyle(compact ? AnyLabelStyle.iconOnly : .titleAndIcon)
                }
                .buttonStyle(.brahma)
                .fixedSize()
                .help("Bring the app's windows to the front")
            }
            Spacer(minLength: 0)
        }
    }

    private func viewportMenu(compact: Bool) -> some View {
        Menu {
            Button("Desktop") { choose(.desktop) }
            Button("iPad") { choose(.ipad) }
            Button("iPhone") { choose(.iphone) }
            Divider()
            Button("Custom…") { customShown = true }
        } label: {
            MonoChip(text: (compact ? "" : "VIEWPORT · ") + viewport.title, color: BrahmaTheme.text0, fill: BrahmaTheme.bg4)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Preview viewport")
        .popover(isPresented: $customShown, arrowEdge: .bottom) { customPopover }
    }

    private var customPopover: some View {
        VStack(alignment: .leading, spacing: BrahmaTheme.spaceS) {
            CapsLabel("Custom viewport")
            TextField("Size", text: $customViewport, prompt: Text(verbatim: "1280x800"))
                .font(BrahmaTheme.mono)
                .brahmaField()
                .onSubmit(applyCustom)
            if let customError {
                Text(verbatim: customError).font(BrahmaTheme.monoSmall).foregroundStyle(BrahmaTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { customShown = false }.buttonStyle(.brahma)
                Button("Apply", action: applyCustom).buttonStyle(.brahmaPrimary)
            }
        }
        .padding(BrahmaTheme.spaceM)
        .frame(width: 260)
        .background(BrahmaTheme.bg1)
    }

    private func applyCustom() {
        do {
            choose(try PreviewViewport.parse(customViewport))
            customError = nil
            customShown = false
        } catch let e as WorkError {
            customError = e.message
        } catch {
            customError = "\(error)"
        }
    }

    private func choose(_ v: PreviewViewport) {
        viewport = v
        PreviewViewportStore.save(v, tabId: tabId)
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        switch body_ {
        case .empty(let text):
            MonoEmptyState("NO PREVIEW", detail: text)
        case .status(let title, let detail, let logTail):
            VStack(spacing: 0) {
                MonoEmptyState(title, detail: detail)
                if !logTail.isEmpty {
                    Hairline()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(logTail.enumerated()), id: \.offset) { _, line in
                                Text(verbatim: line)
                                    .font(BrahmaTheme.monoSmall)
                                    .foregroundStyle(BrahmaTheme.text2)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(BrahmaTheme.spaceS)
                    }
                    .background(BrahmaTheme.bg0)
                    .layoutPriority(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .terminal(let lines, let footer):
            TerminalPreviewView(lines: lines, footer: footer)
        case .backend(let smoke, let logTail, let operations, let operationsNote):
            BackendPreviewView(smoke: smoke, logTail: logTail, operations: operations, operationsNote: operationsNote)
        case .artifact(let artifact, let all):
            ArtifactPreviewView(artifact: artifact, all: all, model: model)
        case .simulator(let udid):
            SimulatorFramesView(udid: udid)
        case .window(let pid):
            WindowCaptureView(pid: pid)
        case .changes:
            // Plan C C7c: the board, or the selected item's live diff (unified/split, compare picker, inline review).
            ChangesTabBody(model: model)
        case .ref(let refBody):
            // Plan C C7a: the OPENED tab (or, from `inspector(body:model:)`, chat's inspector) draws the ref's body.
            RefBodyView(model: model, refBody: refBody, opened: tabId == PreviewTabID.ref ? model.previewNav.opened : model.chatInspector,
                        inspector: tabId != PreviewTabID.ref)
        default:
            // `.web`, and the cases Collab adds to the open enum (L-1).
            if case .web(let url, let origin, let builtBy) = body_ {
                WebPreviewView(url: url, origin: origin, path: path, viewport: viewport, builtBy: builtBy, reloadKey: reloadKey)
            } else {
                MonoEmptyState("UNSUPPORTED PREVIEW")
            }
        }
    }

    /// The ARTIFACTS body carries its own header (the picker and Reveal in Finder); the pane's row would be empty over it.
    private var showsHeader: Bool {
        if case .artifact = body_ { return false }
        // Plan C C7a: a ref body carries its own header (title, chips, actions).
        if case .ref = body_ { return false }
        return true
    }

    /// The surface's commit, or the live release's ref: a change reloads the page.
    private var reloadKey: String {
        if let surfaceId { return model.snapshot.preview.states[surfaceId]?.commit ?? "" }
        return isLive ? (model.snapshot.preview.liveRef ?? "") : ""
    }
}

// MARK: - Viewport persistence

/// The chosen viewport per tab, in `UserDefaults`; every read and write is `try?`, and the default is desktop.
enum PreviewViewportStore {
    static func key(_ tabId: String?) -> String { "brahma.preview.viewport." + (tabId ?? "default") }

    static func load(tabId: String?, defaults: UserDefaults = .standard) -> PreviewViewport {
        guard let data = defaults.data(forKey: key(tabId)),
              let v = try? JSONDecoder().decode(PreviewViewport.self, from: data) else { return .desktop }
        return v
    }

    static func save(_ v: PreviewViewport, tabId: String?, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(v) else { return }
        defaults.set(data, forKey: key(tabId))
    }
}

/// `iconOnly` or `titleAndIcon` chosen at run time (the two built-in styles are different types).
struct AnyLabelStyle: LabelStyle {
    let iconOnlyStyle: Bool
    static let iconOnly = AnyLabelStyle(iconOnlyStyle: true)
    static let titleAndIcon = AnyLabelStyle(iconOnlyStyle: false)

    func makeBody(configuration: Configuration) -> some View {
        if iconOnlyStyle { Label(configuration).labelStyle(IconOnlyLabelStyle()) } else { Label(configuration).labelStyle(TitleAndIconLabelStyle()) }
    }
}

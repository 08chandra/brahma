import SwiftUI
import AppKit
import BrahmaCore
import BrahmaAppModel

/// Mission Control's PREVIEW panel (L-1): one `MonoChip` tab per surface (plus LIVE), the selected tab's body with its
/// header buttons, and an accessory strip above the tabs for other surfaces (L passes none; Collab puts its "Show me" bar
/// there). `inspector(body:model:)` renders one body without the tab strip, for chat's inspector split.
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
                    Button { model.selectedPreviewTab = tab.id } label: {
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
            header
            Hairline()
            content
        }
        .task(id: tabId) {
            viewport = PreviewViewportStore.load(tabId: tabId)
            path = "/"
            pathDraft = "/"
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        HStack(spacing: BrahmaTheme.spaceS) {
            if let surfaceId {
                Button { Task { await model.restartPreview(surfaceId: surfaceId) } } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.brahma)
                .help("Restart this preview")
            }
            if case .web(let url, _, _) = body_ {
                Button { NSWorkspace.shared.open(url) } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .buttonStyle(.brahma)
                TextField("Path", text: $pathDraft, prompt: Text(verbatim: "/"))
                    .font(BrahmaTheme.monoSmall)
                    .brahmaField()
                    .frame(minWidth: 80, maxWidth: 220)
                    .onSubmit { path = pathDraft }
                    .accessibilityLabel(Text("Preview path"))
                viewportMenu
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, BrahmaTheme.spaceS)
        .padding(.vertical, BrahmaTheme.spaceXS)
        .background(BrahmaTheme.bg2)
    }

    private var viewportMenu: some View {
        Menu {
            Button("Desktop") { choose(.desktop) }
            Button("iPad") { choose(.ipad) }
            Button("iPhone") { choose(.iphone) }
            Divider()
            Button("Custom…") { customShown = true }
        } label: {
            MonoChip(text: "VIEWPORT · " + viewport.title, color: BrahmaTheme.text0, fill: BrahmaTheme.bg4)
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
        default:
            // `.web`, and the cases 4a and Collab add to the open enum (L-1).
            if case .web(let url, let origin, let builtBy) = body_ {
                WebPreviewView(url: url, origin: origin, path: path, viewport: viewport, builtBy: builtBy, reloadKey: reloadKey)
            } else {
                MonoEmptyState("UNSUPPORTED PREVIEW")
            }
        }
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

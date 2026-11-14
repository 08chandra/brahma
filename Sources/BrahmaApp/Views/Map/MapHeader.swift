import SwiftUI
import BrahmaCore
import BrahmaAppModel

/// The search field's bounds, so the panel can hang the hit list under it (a header strip cannot draw outside its 28 pt).
struct MapSearchAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = value ?? nextValue() }
}

/// The agent panel's header accessory: find, follow, zoom-to-fit, show former, `+ VACANCY`, replay and pop-out.
///
/// The controller's `model` changes every frame, so nothing here reads it while rendering: what the menus need (the agents
/// to follow, the former toggle) is copied into `info` twice a second by a task, and the buttons only call the controller.
struct MapHeader: View {
    let model: AppModel
    let controller: MapController
    @Binding var query: String
    /// The pop-out window hosts the panel itself: no pop-out button.
    var isWindow = false
    var onPopOut: () -> Void = {}
    /// The window's full-screen toggle; the button shows only in the window.
    var onFullScreen: (() -> Void)?

    @FocusState private var searchFocused: Bool
    @State private var info = Info()

    struct Info: Equatable {
        struct Choice: Equatable, Identifiable { var id: String; var handle: String }
        /// The first `maxChoices` living agents by handle.
        var choices: [Choice] = []
        var more = 0
        var showFormer = false
    }

    static let maxChoices = 80

    var body: some View {
        HStack(spacing: 6) {
            TextField("Find agent", text: $query, prompt: Text(verbatim: "FIND @AGENT"))
                .focused($searchFocused)
                .brahmaField(focused: searchFocused, compact: true)
                .frame(width: 160)
                .anchorPreference(key: MapSearchAnchor.self, value: .bounds) { $0 }
                .onSubmit(submitSearch)
                .onExitCommand { clearSearch() }
                .onChange(of: query) { _, q in controller.search(q) }
                .accessibilityLabel(Text("Find agent"))

            followMenu

            if MapMode.allCases.count > 1 {
                Segmented(options: MapMode.allCases.map { ($0, $0.title) }, selection: controller.mode, label: "Map mode") {
                    controller.mode = $0
                }
            }

            iconButton("arrow.up.left.and.arrow.down.right", help: "Zoom to fit") { controller.zoomToFit() }

            formerToggle

            if !controller.isSynthetic && controller.replay == nil {
                Button("+ VACANCY") { model.presentedSheet = .vacancy(managerHandle: nil) }
                    .buttonStyle(.brahma)
                    .help("Add an open seat under the Board")
            }

            iconButton("clock.arrow.circlepath", help: controller.replay == nil ? "Replay the last hour" : "Back to live",
                       disabled: controller.isSynthetic) {
                if controller.replay == nil { Task { await controller.enterReplay() } } else { controller.exitReplay() }
            }

            if !isWindow {
                iconButton("arrow.up.forward.app", help: "Open the map in its own window", action: onPopOut)
            } else if let onFullScreen {
                iconButton("rectangle.arrowtriangle.2.outward", help: "Full screen", action: onFullScreen)
            }
        }
        .task(id: ObjectIdentifier(controller)) {
            while !Task.isCancelled {
                refreshInfo()
                try? await AwakeTime.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: Pieces

    private var followMenu: some View {
        Menu {
            Button("Stop following") { controller.follow(nil) }
                .disabled(controller.follow == nil)
            Divider()
            ForEach(info.choices) { choice in
                Button { controller.follow(choice.id) } label: { Text(verbatim: choice.handle) }
            }
            if info.more > 0 {
                Text(verbatim: "+\(info.more) more: use find")
            }
        } label: {
            Text(verbatim: "FOLLOW ▾")
        }
        .menuStyle(.button)
        .buttonStyle(.brahma)
        .fixedSize()
        .help("Keep one agent in view")
    }

    @ViewBuilder private var formerToggle: some View {
        if info.showFormer {
            Button("SHOW FORMER") { toggleFormer(false) }
                .buttonStyle(.brahmaPrimary)
                .help("Hide agents who left")
                .accessibilityAddTraits(.isSelected)
        } else {
            Button("SHOW FORMER") { toggleFormer(true) }
                .buttonStyle(.brahma)
                .help("Show agents who left")
        }
    }

    private func iconButton(_ symbol: String, help: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 12) }
            .buttonStyle(.brahma)
            .disabled(disabled)
            .help(help)
            .accessibilityLabel(Text(help))
    }

    // MARK: Actions

    private func toggleFormer(_ on: Bool) {
        controller.setShowFormer(on)
        info.showFormer = on
    }

    /// Return jumps to the first hit (the controller searches on every keystroke; this makes sure of the latest text).
    private func submitSearch() {
        controller.search(query)
        if let first = controller.searchHits.first {
            controller.jump(to: first)
            clearSearch()
        }
    }

    private func clearSearch() {
        query = ""
        controller.search("")
    }

    private func refreshInfo() {
        var living = controller.model.agents.values.filter { $0.state != .killed }
        living.sort { ($0.handle, $0.id) < ($1.handle, $1.id) }
        let next = Info(choices: living.prefix(Self.maxChoices).map { .init(id: $0.id, handle: $0.handle) },
                        more: Swift.max(0, living.count - Self.maxChoices), showFormer: controller.model.showFormer)
        if next != info { info = next }
    }
}

/// The hit list under the search field: at most 8 `@handle · role` rows. The row text is the cleaned map text.
struct MapSearchResults: View {
    let controller: MapController
    let onPick: (String) -> Void
    @State private var rows: [Row] = []

    struct Row: Equatable, Identifiable { var id: String; var text: String }
    static let limit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text(verbatim: "NO MATCHES")
                    .font(BrahmaTheme.label).tracking(BrahmaTheme.labelTracking)
                    .foregroundStyle(BrahmaTheme.text2)
                    .padding(.horizontal, BrahmaTheme.spaceS)
                    .frame(height: BrahmaTheme.denseRowHeight)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                Button { onPick(row.id) } label: {
                    Text(verbatim: row.text)
                        .font(BrahmaTheme.monoSmall)
                        .foregroundStyle(BrahmaTheme.text0)
                        .lineLimit(1)
                        .tableRow(index: index, height: BrahmaTheme.denseRowHeight)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: BrahmaTheme.radius).fill(BrahmaTheme.bg3))
        .overlay(RoundedRectangle(cornerRadius: BrahmaTheme.radius).strokeBorder(BrahmaTheme.lineStrong, lineWidth: 1))
        .onChange(of: controller.searchHits, initial: true) { _, hits in refresh(hits) }
    }

    private func refresh(_ hits: [String]) {
        rows = hits.prefix(Self.limit).compactMap { id in
            controller.model.agents[id].map { Row(id: id, text: "\($0.handle) · \($0.role)") }
        }
    }
}

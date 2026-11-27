import SwiftUI

@main
struct BrahmaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Brahma", id: "main") {
            MainWindow(delegate: delegate)
        }
        .defaultSize(width: 1280, height: 800)
        // The ops-console chrome draws its own 40 pt top bar under the traffic lights.
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Plan C C7a: the search-and-ask palette and the OPENED slot's history.
            CommandMenu("Go") {
                Button("Search or Ask…") { delegate.model?.openShow(presentation: .overlay) }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Button("Back") { Task { await delegate.model?.goBack() } }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { Task { await delegate.model?.goForward() } }
                    .keyboardShortcut("]", modifiers: .command)
                // Plan C C7c: the CHANGES tab's change stops and layout (enabled only while it shows a diff).
                Divider()
                ChangesMenuItems()
            }
        }

        // Opened by the map's pop-out button and by `--map-demo`. Only the first scene opens at launch.
        Window("Agent Map", id: AgentMapPanel.windowId) {
            MapWindow(delegate: delegate)
        }
        .defaultSize(width: 1100, height: 700)

        MenuBarExtra {
            MenuBarContent(delegate: delegate)
        } label: {
            HStack(spacing: BrahmaTheme.spaceXS) {
                Image(systemName: delegate.menuBarSummary?.anyRunningAgents == true ? "circle.hexagongrid.fill" : "circle.hexagongrid")
                if let badge = delegate.menuBarSummary?.badge, badge > 0 {
                    Text(verbatim: "\(badge)").font(BrahmaTheme.mono)
                }
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

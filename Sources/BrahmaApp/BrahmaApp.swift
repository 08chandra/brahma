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

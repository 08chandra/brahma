import SwiftUI
import AppKit
import BrahmaAppModel

/// The map in its own window (`Window("Agent Map", id: "map")`): the same `AgentMapPanel`, full size, plus a full-screen
/// button in its header.
///
/// The panel reads `model.mapController` on every render and this view keeps no reference to a controller, so the window
/// cannot outlive a company switch or a store restore: it shows whatever controller the model has now. Closing the window
/// is seen by `AppDelegate` (`NSWindow.willCloseNotification`), which calls `AppModel.mapWindowClosed()`: the pop-out flag
/// clears and the controller stops polling (an inline panel, if mounted, starts it again).
///
/// Map actions land in the main window: an agent click selects the agent, "Message @x" opens the DM, and Add vacancy,
/// Fill… and Hire Agent present a sheet on it. So whenever the selection, the sidebar or the presented sheet changes, the
/// main window is opened (if it was closed into the menu bar) and brought to the front, and the paid Fill confirmation is
/// always in front of the owner before anything can be hired. The demo's controller never changes any of them, so nothing
/// opens there.
struct MapWindow: View {
    let delegate: AppDelegate

    var body: some View {
        Group {
            switch delegate.boot {
            case .success(let booted):
                MapWindowContent(model: booted.model, delegate: delegate)
            case .failure:
                ZStack {
                    GridBackground()
                    MonoEmptyState("Map unavailable").fixedSize()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .background(BrahmaTheme.bg0)
        .preferredColorScheme(.dark)
    }
}

private struct MapWindowContent: View {
    let model: AppModel
    let delegate: AppDelegate

    var body: some View {
        AgentMapPanel(model: model, isWindow: true, onFullScreen: { NSApp.keyWindow?.toggleFullScreen(nil) })
            .onChange(of: model.selectedAgentId) { _, id in
                if id != nil { delegate.openMainWindowFromMenu() }
            }
            .onChange(of: model.presentedSheet) { _, sheet in
                if sheet != nil { delegate.openMainWindowFromMenu() }
            }
            .onChange(of: model.sidebarSelection) { delegate.openMainWindowFromMenu() }
    }
}

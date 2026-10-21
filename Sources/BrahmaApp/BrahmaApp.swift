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
    }
}

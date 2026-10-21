import SwiftUI

@main
struct BrahmaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Brahma", id: "main") {
            MainWindow(delegate: delegate)
        }
        .defaultSize(width: 1280, height: 800)
    }
}

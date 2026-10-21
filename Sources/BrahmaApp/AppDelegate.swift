import AppKit
import Foundation
import BrahmaCore
import BrahmaAppModel

struct BootError: Error {
    var path: String
    var message: String
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let boot: Result<AppModel, BootError>
    let options: LaunchOptions
    /// Set by `MainWindow.onAppear`; reopens the main window after the user closes it.
    var openMainWindow: (() -> Void)?

    override init() {
        options = LaunchOptions.parse(CommandLine.arguments)
        boot = AppDelegate.makeModel()
        super.init()
    }

    /// Mirrors the CLI's `openStore()`.
    private static func makeModel() -> Result<AppModel, BootError> {
        let paths = BrahmaPaths.fromEnvironment()
        do {
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            let store = try Store(path: paths.database.path)
            return .success(AppModel(store: store, paths: paths))
        } catch {
            return .failure(BootError(path: paths.database.path, message: "\(error)"))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch boot {
        case .success(let model):
            let options = self.options
            Task { @MainActor in
                await model.load()
                model.startPolling()
                Harness.runIfRequested(options: options, model: model)
            }
        case .failure(let error):
            if options.smokeTest {
                Harness.finishFail("store \(error.message)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

import AppKit
import Foundation
import BrahmaCore
import BrahmaAppModel

struct BootError: Error {
    var path: String
    var message: String
}

/// Resolves the helper binaries the embedded engine needs.
enum EngineSetup {
    @MainActor
    static func resolveTools() -> Result<EngineTools, EngineSetupError> {
        let env = ProcessInfo.processInfo.environment
        guard let claude = ToolLocator.claude(environment: env, searchPath: env["PATH"] ?? "") else {
            return .failure(.claudeNotFound)
        }
        let bundle = Bundle.main.bundleURL
        guard let helper = ToolLocator.mcpHelper(appBundle: bundle, executable: Bundle.main.executableURL ?? bundle) else {
            return .failure(.helperMissing(path: bundle.appending(path: "Contents/Helpers/brahma").path))
        }
        return .success(EngineTools(claudePath: claude, mcpExecutable: helper))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let boot: Result<AppModel, BootError>
    let options: LaunchOptions
    /// Set by `MainWindow.onAppear`; reopens the main window after the user closes it.
    var openMainWindow: (() -> Void)?
    private var signalSources: [DispatchSourceSignal] = []

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
        // A dead agent pipe must surface as an error, not kill the app; Ctrl-C and `kill` quit gracefully.
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { AppDelegate.requestQuit() }
            source.resume()
            signalSources.append(source)
        }
        switch boot {
        case .success(let model):
            let options = self.options
            let engine = EngineHost(paths: model.paths, store: model.store)
            model.engine = engine
            Task { @MainActor in
                await model.load()
                model.startPolling()
                // A Finder launch has a bare PATH; the login shell's PATH is where `claude` and the agents' tools live.
                let env = ProcessInfo.processInfo.environment
                let merged = await Task.detached {
                    ToolLocator.mergePath(login: ToolLocator.loginShellPath(shell: env["SHELL"] ?? "/bin/zsh"),
                                          current: env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
                }.value
                setenv("PATH", merged, 1)
                await engine.start(tools: EngineSetup.resolveTools())
                Harness.runIfRequested(options: options, model: model)
            }
        case .failure(let error):
            if options.smokeTest {
                Harness.finishFail("store \(error.message)")
            }
        }
    }

    /// `terminate` blocks in a nested run loop while `applicationShouldTerminate` answers `.terminateLater`. Called
    /// from a main-queue block (a dispatch signal handler, a main-actor task) it would starve the very main-actor
    /// task that stops the engine and replies, so it is issued from a run-loop source instead.
    nonisolated static func requestQuit() {
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }

    /// Quit pauses the engine: in-flight turns are interrupted (their agents return to ready) and the
    /// next launch resumes them. Company status is never written.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard case .success(let model) = boot else { return .terminateNow }
        model.stopPolling()
        guard let engine = model.engine, engine.status == .embedded || engine.status == .starting else {
            return .terminateNow
        }
        Task { @MainActor in
            await engine.stop(timeout: .seconds(15))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

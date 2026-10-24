import AppKit
import Foundation
import os
import BrahmaCore
import BrahmaAppModel
import BrahmaKeychain

struct BootError: Error {
    var path: String
    var message: String
    /// The first row of a failed `PRAGMA integrity_check`: the database was not opened (the view offers a restore).
    var integrityProblem: String? = nil
}

/// What a successful boot produced: the model and the owner-key store resolved for this data home (the Keychain,
/// or the dev/demo file store when `BRAHMA_OWNER_KEY_STORE=file`, never for the default data home).
struct Booted {
    let model: AppModel
    let ownerKeyStore: any OwnerKeyStore
    /// The secrets vault (the Keychain, or a dev/demo home's file store with `BRAHMA_SECRET_STORE`, never for the default home).
    let secretVault: any SecretVault
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
    let boot: Result<Booted, BootError>
    /// The model, when boot succeeded.
    var model: AppModel? { if case .success(let booted) = boot { return booted.model } else { return nil } }
    let options: LaunchOptions
    /// Set by `MainWindow.onAppear`; reopens the main window after the user closes it.
    var openMainWindow: (() -> Void)?
    /// SwiftUI wraps the adaptor, so `NSApp.delegate` is not this object; the harness reaches it here.
    static private(set) weak var current: AppDelegate?
    private var signalSources: [DispatchSourceSignal] = []
    /// Posts the Inbox banners; created at launch once the model exists.
    private var notifier: OwnerNotifier?
    /// Set once the bounded engine stop has begun; later quit requests wait on it instead of exiting early.
    private(set) var quitting = false

    override init() {
        options = LaunchOptions.parse(CommandLine.arguments)
        boot = AppDelegate.makeBoot()
        super.init()
        AppDelegate.current = self
    }

    private static let log = Logger(subsystem: "dev.brahma.app", category: "startup")

    /// Picks the owner-key store, then opens the database like the CLI's `openStore()`. A refused store choice is a
    /// startup error, never a silent fallback to another store.
    private static func makeBoot() -> Result<Booted, BootError> {
        let paths = BrahmaPaths.fromEnvironment()
        let selection: PlatformOwnerKeyStore.Selection
        do { selection = try PlatformOwnerKeyStore.resolve(paths: paths) } catch {
            return .failure(BootError(path: paths.home.path, message: "\(error)"))
        }
        // Background reads (boot, the engine) never prompt; only the owner's Load secrets uses the interactive store.
        let secrets: PlatformSecretVault.Selection, ownerSecrets: PlatformSecretVault.Selection
        do {
            secrets = try PlatformSecretVault.resolve(paths: paths)
            try PlatformSecretVault.refuseMemory(secrets)
            ownerSecrets = try PlatformSecretVault.resolve(paths: paths, interactive: true)
        } catch {
            return .failure(BootError(path: paths.home.path, message: "\(error)"))
        }
        do {
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            // Before anything opens (and migrates) the database: a damaged one is restored from a snapshot, not run on.
            if FileManager.default.fileExists(atPath: paths.database.path) {
                let rows = BackupService.integrity(of: paths.database)
                if rows != ["ok"] {
                    let first = rows.first ?? "unknown"
                    return .failure(BootError(path: paths.database.path, message: "database check failed (\(first))", integrityProblem: first))
                }
            }
            let catalog = PackCatalog.loadOrBuiltin(directory: paths.packsDir) {
                FileHandle.standardError.write(Data(($0 + "\n").utf8))
            }
            let store = try Store(path: paths.database.path, catalog: catalog, backupsDir: paths.backupsDir)
            // Owner writes from the app fail closed until the secrets are loaded: a non-interactive load now (it cannot prompt
            // or block on a dialog); the engine retries in the background, and the banner's Load secrets asks the owner.
            // `logFailures: false`: the engine logs failures and writes the hold notice; the banner reflects the store's state.
            if store.secretsHeld { _ = try? store.reloadRedactorIfNeeded(vault: secrets.vault, logFailures: false) }
            let model = AppModel(store: store, paths: paths)
            model.ownerSecretVault = ownerSecrets.vault
            let warnings = [selection.warning, secrets.warning].compactMap { $0 }
            for warning in warnings {
                // stderr is invisible to a Finder launch: also the unified log and the window's banner.
                FileHandle.standardError.write(Data("brahma: \(warning)\n".utf8))
                log.warning("\(warning, privacy: .public)")
            }
            if !warnings.isEmpty { model.startupNotice = warnings.joined(separator: "; ") }
            return .success(Booted(model: model, ownerKeyStore: selection.store, secretVault: secrets.vault))
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
        // Closing the main window leaves the app and engine running in the menu bar; the Dock icon goes away.
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        switch boot {
        case .success(let booted):
            let model = booted.model
            let options = self.options
            let engine = EngineHost(paths: model.paths, store: model.store, ownerKeyStore: booted.ownerKeyStore,
                                    secretVault: booted.secretVault)
            model.engine = engine
            // After a restore the model has a new store: the engine is rebuilt on it.
            model.restartEngine = { [weak model, ownerKeyStore = booted.ownerKeyStore] store in
                guard let model else { return nil }
                let engine = EngineHost(paths: model.paths, store: store, ownerKeyStore: ownerKeyStore)
                await engine.start(tools: EngineSetup.resolveTools())
                return engine
            }
            let notifier = OwnerNotifier(model: model)
            notifier.openMainWindow = { [weak self] in self?.openMainWindowFromMenu() }
            // Smoke and snapshot runs must never raise the system permission dialog.
            notifier.start(prompt: !options.smokeTest && options.snapshotPath == nil)
            self.notifier = notifier
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
            if options.snapshotPath != nil {
                Harness.snapshotFail("store \(error.message)")
            } else if options.smokeTest {
                Harness.finishFail("store \(error.message)")
            }
        }
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let window = note.object as? NSWindow, (window.identifier?.rawValue ?? "").hasPrefix("main") else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Brings the main window back (and the Dock icon) after it was closed into the menu bar.
    func openMainWindowFromMenu() {
        NSApp.setActivationPolicy(.regular)
        openMainWindow?()
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindowFromMenu()
        return true
    }

    /// `terminate` blocks in a nested run loop while `applicationShouldTerminate` answers `.terminateLater`. Called
    /// from a main-queue block (a dispatch signal handler, a main-actor task) it would starve the very main-actor
    /// task that stops the engine and replies, so it is issued from a run-loop source instead.
    nonisolated static func requestQuit() {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                // A second ⌘Q / menu Quit / SIGTERM while the engine is stopping changes nothing.
                if AppDelegate.current?.quitting == true { return }
                NSApp.terminate(nil)
            }
        }
    }

    /// Quit pauses the engine: in-flight turns are interrupted (their agents return to ready) and the
    /// next launch resumes them. Company status is never written.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Re-entered (e.g. the app menu's ⌘Q) while the stop runs: the pending reply below completes the quit.
        if quitting { return .terminateLater }
        guard let model else { return .terminateNow }
        model.stopPolling()
        guard let engine = model.engine, engine.status == .embedded || engine.status == .starting else {
            return .terminateNow
        }
        quitting = true
        Task { @MainActor in
            await engine.stop(timeout: .seconds(15))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension AppDelegate {
    /// The menu bar summary, or nil when the store failed to open.
    var menuBarSummary: MenuBarSummary? {
        if let model { return model.menuBar }
        return nil
    }
}

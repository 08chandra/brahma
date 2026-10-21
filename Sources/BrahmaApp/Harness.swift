import AppKit
import Foundation
import BrahmaAppModel

/// Launch-time automation used by the smoke and UI-snapshot scripts.
@MainActor
enum Harness {
    static func runIfRequested(options: LaunchOptions, model: AppModel) {
        if options.smokeTest || options.snapshotPath != nil {
            Task { @MainActor in await run(options: options, model: model) }
        }
    }

    static func finishFail(_ reason: String) -> Never {
        print("SMOKE FAIL \(reason)")
        fflush(stdout)
        exit(1)
    }

    private static func mainWindows() -> [NSWindow] {
        NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix("main") && $0.isVisible }
    }

    private static func waitReady(model: AppModel) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if model.loaded && !mainWindows().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func run(options: LaunchOptions, model: AppModel) async {
        let snapshotMode = options.snapshotPath != nil
        guard await waitReady(model: model) else {
            if snapshotMode {
                print("SNAPSHOT FAIL window not ready")
                fflush(stdout)
                exit(1)
            }
            finishFail("not ready: loaded=\(model.loaded) windows=\(mainWindows().count)")
        }
        if let path = options.snapshotPath {
            await snapshot(path: path, options: options, model: model)
        } else {
            try? await Task.sleep(for: .seconds(options.smokeHold))
            let agents = model.snapshot.companies.reduce(0) { $0 + $1.counts.running + $1.counts.ready + $1.counts.blocked + $1.counts.sleeping + $1.counts.killed }
            var line = "SMOKE OK companies=\(model.snapshot.companies.count) agents=\(agents) engine=\(model.engine?.status.label ?? "none") windows=\(mainWindows().count)"
            if options.smokeCloseWindow {
                if let failure = await lifecycleCheck(model: model) { finishFail("lifecycle \(failure)") }
                line += " lifecycle=ok"
            }
            print(line)
            fflush(stdout)
            await terminateAndExit()
        }
    }

    /// Closes the main window, expects the menu-bar-only state with the engine still up, then reopens it.
    private static func lifecycleCheck(model: AppModel) async -> String? {
        guard let delegate = AppDelegate.current else { return "no delegate" }
        mainWindows().first?.performClose(nil)
        try? await Task.sleep(for: .seconds(1))
        guard mainWindows().isEmpty else { return "window still visible after close (\(mainWindows().count))" }
        guard NSApp.activationPolicy() == .accessory else { return "policy \(NSApp.activationPolicy().rawValue) after close, expected accessory" }
        guard model.engine?.status == .embedded else { return "engine \(model.engine?.status.label ?? "none") after close, expected embedded" }
        delegate.openMainWindowFromMenu()
        try? await Task.sleep(for: .seconds(1))
        guard mainWindows().count == 1 else { return "\(mainWindows().count) windows after reopen, expected 1" }
        guard NSApp.activationPolicy() == .regular else { return "policy \(NSApp.activationPolicy().rawValue) after reopen, expected regular" }
        return nil
    }

    /// Quit stops the engine first (up to 15 s); only exit once the delegate has had its chance to finish.
    private static func terminateAndExit() async -> Never {
        AppDelegate.requestQuit()
        try? await Task.sleep(for: .seconds(20))
        exit(0)
    }

    private static func snapshot(path: String, options: LaunchOptions, model: AppModel) async {
        func fail(_ reason: String) -> Never {
            print("SNAPSHOT FAIL \(reason)")
            fflush(stdout)
            exit(1)
        }
        guard let window = mainWindows().first else { fail("no window") }
        if let target = options.select { model.apply(target) }
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .seconds(max(1.5, options.smokeHold)))
        // cacheDisplay cannot render vibrancy-backed views (sidebar, toolbar controls): they come out white.
        // For the plain window use screencapture; sheets render correctly through cacheDisplay.
        if window.attachedSheet == nil, screenCapture(window: window, to: path) {
            print("SNAPSHOT \(path)")
            fflush(stdout)
            await terminateAndExit()
        }
        let host = window.attachedSheet ?? window
        guard let content = host.contentView else { fail("no content view") }
        let view = content.superview ?? content
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("no bitmap rep") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("png encoding") }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            fail("write \(error)")
        }
        print("SNAPSHOT \(path)")
        fflush(stdout)
        await terminateAndExit()
    }

    private static func screenCapture(window: NSWindow, to path: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return p.terminationStatus == 0 && size > 0
    }
}

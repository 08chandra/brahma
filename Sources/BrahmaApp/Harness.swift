import AppKit
import Foundation
import SpriteKit
import BrahmaMapKit
import BrahmaAppModel
import BrahmaCore

/// Launch-time automation used by the smoke and UI-snapshot scripts.
@MainActor
enum Harness {
    static func runIfRequested(options: LaunchOptions, model: AppModel) {
        if options.smokeTest || options.snapshotPath != nil || options.mapBench != nil {
            Task { @MainActor in await run(options: options, model: model) }
        }
    }

    static func finishFail(_ reason: String) -> Never {
        print("SMOKE FAIL \(reason)")
        fflush(stdout)
        exit(1)
    }

    static func snapshotFail(_ reason: String) -> Never {
        print("SNAPSHOT FAIL \(reason)")
        fflush(stdout)
        exit(1)
    }

    private static func mainWindows() -> [NSWindow] { windows(prefix: "main") }

    private static func windows(prefix: String) -> [NSWindow] {
        NSApp.windows.filter { ($0.identifier?.rawValue ?? "").hasPrefix(prefix) && $0.isVisible }
    }

    /// The window a run works on: the map window for `--map-demo` and `--map-bench`, else the main window.
    private static func targetPrefix(_ options: LaunchOptions) -> String {
        options.mapDemo || options.mapBench != nil ? "map" : "main"
    }

    private static func windowIds() -> String {
        NSApp.windows.map { "\($0.identifier?.rawValue ?? "-")\($0.isVisible ? "" : "(hidden)")" }.joined(separator: ",")
    }

    private static func waitReady(model: AppModel, prefix: String) async -> Bool {
        let deadline = AwakeTime.deadline(after: .seconds(20))
        while AwakeTime.now < deadline {
            if model.loaded && !windows(prefix: prefix).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func run(options: LaunchOptions, model: AppModel) async {
        let snapshotMode = options.snapshotPath != nil
        let prefix = targetPrefix(options)
        guard await waitReady(model: model, prefix: prefix) else {
            if snapshotMode { snapshotFail("window not ready (\(prefix); windows: \(windowIds()))") }
            if options.mapBench != nil { benchFail("window not ready (\(prefix); windows: \(windowIds()))") }
            finishFail("not ready: loaded=\(model.loaded) windows=\(mainWindows().count)")
        }
        if let seconds = options.mapBench {
            await bench(seconds: seconds, model: model)
        } else if let path = options.snapshotPath {
            await snapshot(path: path, options: options, model: model)
        } else {
            var released: Bool?
            if let release = options.smokeRelease {
                // Held until the script says it has seen what it waits for, bounded by `smokeHold`.
                let deadline = AwakeTime.deadline(after: .seconds(options.smokeHold))
                released = false
                while AwakeTime.now < deadline {
                    if FileManager.default.fileExists(atPath: release) { released = true; break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } else {
                try? await AwakeTime.sleep(for: .seconds(options.smokeHold))
            }
            let agents = model.snapshot.companies.reduce(0) { $0 + $1.counts.running + $1.counts.ready + $1.counts.blocked + $1.counts.sleeping + $1.counts.killed }
            var line = "SMOKE OK companies=\(model.snapshot.companies.count) agents=\(agents) engine=\(model.engine?.status.label ?? "none") windows=\(mainWindows().count)"
            if let released { line += " released=\(released ? "yes" : "no")" }
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
        try? await AwakeTime.sleep(for: .seconds(20))
        exit(0)
    }

    private static func snapshot(path: String, options: LaunchOptions, model: AppModel) async {
        func fail(_ reason: String) -> Never { snapshotFail(reason) }
        guard let window = windows(prefix: targetPrefix(options)).first else { fail("no window (windows: \(windowIds()))") }
        if let name = options.company,
           let company = model.snapshot.companies.first(where: { $0.company.name.lowercased() == name.lowercased() }) {
            await model.selectCompany(company.id)
        }
        if let target = options.select { model.apply(target) }
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.makeKeyAndOrderFront(nil)
        if options.mapDemo { NSApp.activate() }
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

    // MARK: Map bench

    static func benchFail(_ reason: String) -> Never {
        print("MAP BENCH FAIL \(reason)")
        fflush(stdout)
        exit(1)
    }

    /// Frames are timed at the scene (`SKSceneDelegate.update`, once per rendered frame), not by a timer: what is measured
    /// is what the `SKView` actually drew, hitches from the controller's per-frame work included.
    @MainActor
    private final class FrameCollector: NSObject, SKSceneDelegate {
        let controller: MapController
        private(set) var intervals: [TimeInterval] = []
        private(set) var aggregateSeconds: TimeInterval = 0
        private var last: TimeInterval?

        init(controller: MapController) { self.controller = controller }

        nonisolated func update(_ currentTime: TimeInterval, for scene: SKScene) {
            // SpriteKit calls the delegate on the main thread (`SKView` renders there), so this asserts rather than hops: a hop
            // would delay the timestamp bookkeeping and distort the very intervals being measured. It would trap if that changed.
            MainActor.assumeIsolated {
                defer { last = currentTime }
                guard let last, currentTime > last else { return }
                let dt = currentTime - last
                intervals.append(dt)
                if controller.model.stats.aggregate { aggregateSeconds += dt }
            }
        }
    }

    private static func mapView(in view: NSView) -> MapSKView? {
        if let map = view as? MapSKView { return map }
        for sub in view.subviews { if let found = mapView(in: sub) { return found } }
        return nil
    }

    /// `--map-bench=<s>`: waits for the map to be framing and settle for a second, then collects the `SKView`'s frame
    /// intervals for `seconds` and prints one `MAP BENCH` line. A frame is dropped when it took over 1.5 refresh periods.
    private static func bench(seconds: Double, model: AppModel) async {
        guard let window = windows(prefix: "map").first, let content = window.contentView else { benchFail("no map window") }
        guard let controller = model.mapController else { benchFail("no map controller") }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        var view: MapSKView?
        let deadline = AwakeTime.deadline(after: .seconds(10))
        while AwakeTime.now < deadline {
            if let found = mapView(in: content), found.scene != nil, controller.lastFrameTime != nil { view = found; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let view, let scene = view.scene else { benchFail("map view not framing") }
        try? await AwakeTime.sleep(for: .seconds(1))
        let collector = FrameCollector(controller: controller)
        scene.delegate = collector
        try? await AwakeTime.sleep(for: .seconds(seconds))
        scene.delegate = nil
        let stats = FrameStats.make(intervals: collector.intervals)
        guard stats.frames > 0 else { benchFail("no frames in \(seconds) s (paused=\(view.isPaused) visible=\(window.occlusionState.contains(.visible)) key=\(window.isKeyWindow) fps=\(view.preferredFramesPerSecond))") }
        let period = 1.0 / Double(Swift.max(1, view.preferredFramesPerSecond))
        let dropped = collector.intervals.filter { $0 > 1.5 * period }.count
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        print("MAP BENCH mode=\(controller.mode.rawValue) agents=\(controller.model.agents.count) fps=\(f(stats.fps)) p95=\(f(stats.p95Ms))ms max=\(f(stats.maxMs))ms dropped=\(dropped) aggregate=\(f(collector.aggregateSeconds))s")
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

import AppKit
import Foundation
import Metal
import SpriteKit
import BrahmaAppModel

/// What one offscreen bench run measured. The timing fields come from `FrameStats.make(intervals:)`, the code the on-screen
/// `--map-bench` harness uses; here an "interval" is the time one frame took to produce (controller frame, scene update,
/// `SKRenderer` into a 1600×900 texture, GPU done), not the time between two display refreshes.
public struct MapBenchResult: Sendable {
    public var mode: MapMode
    public var agents: Int
    public var frames: Int
    public var meanMs: Double
    public var p95Ms: Double
    public var maxMs: Double
    /// Frames that took over 16.7 ms.
    public var dropped: Int
    /// Virtual seconds the queue spent in aggregate mode.
    public var aggregateSeconds: Double
    /// The office's level of detail at the end of the run; nil for the org chart.
    public var officeLOD: OfficeLOD?
    /// The `MAP BENCH …` line the tests print and the README quotes.
    public var line: String
}

/// Drives a synthetic `MapController` through the scene for a `MapMode` (`MapSceneFactory`: the org chart's `OrgScene` or the
/// office's `OfficeScene`) offscreen, one fixed 1/60 s step per frame: the controller polls
/// on its 500 ms cadence on a virtual clock (so traffic, bursts and state churn are the same on every run), and each frame
/// is timed from `SKRenderer.update` (which runs the controller's `frame` and the scene's update) to the finished command
/// buffer. Needs a Metal device; without one the result has zero frames.
@MainActor
public enum MapBench {
    /// Frames before timing starts: first rebuild, label textures, zoom-to-fit.
    static let warmupFrames = 60
    static let step: TimeInterval = 1.0 / 60
    static let budgetMs = 16.7
    static let size = CGSize(width: 1600, height: 900)

    /// A virtual wall clock: the controller reads it for its poll window, burst times and map time.
    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ start: Date) { time = start }
        var now: Date { lock.lock(); defer { lock.unlock() }; return time }
        func advance(_ seconds: TimeInterval) { lock.lock(); time = time.addingTimeInterval(seconds); lock.unlock() }
    }

    /// `expandAll` opens every subtree of the org chart; the office has no collapsed subtrees, so it is ignored in `.office`.
    public static func run(agents: Int, mode: MapMode = .org, rate: Double = 50, burst: (TimeInterval, Int)? = (10, 200),
                           seconds: Double = 30, expandAll: Bool = false) -> MapBenchResult {
        // An epoch multiple of 10 s, so a (10, n) burst lands 10 s into the run.
        let clock = VirtualClock(Date(timeIntervalSince1970: 1_800_000_000))
        clearDefaults()
        defer { clearDefaults() }
        let controller = MapController(source: .synthetic(agents: agents, rate: rate, seed: 42),
                                       defaults: UserDefaults(suiteName: suiteName)!, clock: { clock.now })
        controller.syntheticBurst = burst.map { (every: $0.0, size: $0.1) }
        controller.mode = mode   // before `present`: the mode decides what the controller collapses (none in the office)
        let scene = MapSceneFactory.make(mode, size: size)
        scene.present(controller: controller)

        func result(_ intervals: [TimeInterval], aggregate: Double) -> MapBenchResult {
            let stats = FrameStats.make(intervals: intervals)
            let dropped = intervals.filter { $0 * 1000 > budgetMs }.count
            func f(_ v: Double) -> String { String(format: "%.1f", v) }
            let line = "MAP BENCH mode=\(controller.mode.rawValue) agents=\(controller.model.agents.count) fps=\(f(stats.fps)) "
                + "p95=\(f(stats.p95Ms))ms max=\(f(stats.maxMs))ms dropped=\(dropped) aggregate=\(f(aggregate))s"
            return MapBenchResult(mode: controller.mode, agents: controller.model.agents.count, frames: stats.frames,
                                  meanMs: stats.meanMs, p95Ms: stats.p95Ms, maxMs: stats.maxMs, dropped: dropped,
                                  aggregateSeconds: aggregate, officeLOD: (scene as? OfficeScene)?.lod, line: line)
        }

        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return result([], aggregate: 0)
        }
        let width = Int(size.width), height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else { return result([], aggregate: 0) }

        // `SKRenderer` treats the viewport as a 2× backing store; the scene keeps its size and fills the target 1:1
        // (the same arrangement as `MapSnapshotter`).
        scene.scaleMode = .aspectFill
        let renderer = SKRenderer(device: device)
        renderer.scene = scene
        let viewport = CGRect(x: 0, y: 0, width: width, height: height)
        let background = scene.backgroundColor.usingColorSpace(.sRGB) ?? scene.backgroundColor
        let clear = MTLClearColor(red: Double(background.redComponent), green: Double(background.greenComponent),
                                  blue: Double(background.blueComponent), alpha: 1)

        // 500 ms between polls, as in the app (`MapController.pollInterval`).
        let framesPerPoll = Swift.max(1, Int((0.5 / step).rounded()))
        var sceneTime: TimeInterval = 0
        var expanded = false

        /// One frame; returns its duration in seconds, or nil when the GPU work could not be encoded.
        func frame(_ index: Int) -> TimeInterval? {
            clock.advance(step)
            sceneTime += step
            if index % framesPerPoll == 0 { controller.pollSynthetic() }
            if expandAll, mode == .org, !expanded {
                // Every manager with reports open: nothing is a stub.
                for (id, node) in controller.model.tree.nodes where !node.childIds.isEmpty { controller.orgOverrides[id] = true }   // true = expanded
                expanded = true
            }
            let start = SuspendingClock.now
            renderer.update(atTime: sceneTime)
            guard let commandBuffer = queue.makeCommandBuffer() else { return nil }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = clear
            renderer.render(withViewport: viewport, commandBuffer: commandBuffer, renderPassDescriptor: pass)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let elapsed = SuspendingClock.now - start
            return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }

        var index = 0
        for _ in 0..<warmupFrames {
            _ = frame(index)
            index += 1
            if index == 2 { scene.zoomToFit(margin: 40) }   // after the first rebuild: everything is on screen, the costliest view
        }
        // `zoomToFit` eases the camera; two more seconds of frames settle it before timing starts.
        for _ in 0..<120 { _ = frame(index); index += 1 }

        var intervals: [TimeInterval] = []
        var aggregate = 0.0
        let total = Swift.max(1, Int((seconds / step).rounded()))
        intervals.reserveCapacity(total)
        for _ in 0..<total {
            if let d = frame(index) { intervals.append(d) }
            index += 1
            if controller.model.stats.aggregate { aggregate += step }
        }
        return result(intervals, aggregate: aggregate)
    }

    // MARK: Defaults

    /// The bench's defaults suite. The controller persists the mode it is given (`MapController.mode`), so a run needs a
    /// suite; one fixed name, emptied before and after every run, keeps the bench from leaving a plist per run in
    /// `~/Library/Preferences`. `cfprefsd` may write the emptied domain back a few seconds later (as for the harness suite,
    /// ruling R11), which bounds the leftover to this one file, removed again by the next run. Runs that share the suite
    /// do not disturb each other: the bench sets `mode` after `init`, so the stored value is never read.
    public static let suiteName = "brahma.mapbench"
    /// Earlier builds gave every run its own suite, `brahma.mapbench.<UUID>`.
    static let perRunPrefix = "brahma.mapbench."
    static let plistExtension = ".plist"

    /// Empties the bench suite and removes the bench's plists from `directory` (`removePlists(in:)`).
    static func clearDefaults(in directory: URL = HarnessDefaults.preferencesDirectory) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        UserDefaults(suiteName: suiteName)?.synchronize()
        removePlists(in: directory)
    }

    /// Removes the bench's plists from `directory`: `brahma.mapbench.plist` and the per-run `brahma.mapbench.<UUID>.plist`
    /// files of earlier builds. Only regular files with exactly those names are touched (a canonical upper-case UUID, as
    /// `UUID().uuidString` wrote it); links, folders and every other name are left alone. Returns the files removed.
    @discardableResult
    static func removePlists(in directory: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        else { return [] }
        return urls.filter { url in
            guard isBenchPlist(url.lastPathComponent),
                  (try? url.resourceValues(forKeys: keys))?.isRegularFile == true else { return false }
            return (try? FileManager.default.removeItem(at: url)) != nil
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `brahma.mapbench.plist`, or `brahma.mapbench.<UUID>.plist` with the UUID in `UUID().uuidString`'s canonical form.
    static func isBenchPlist(_ name: String) -> Bool {
        if name == suiteName + plistExtension { return true }
        guard name.hasPrefix(perRunPrefix), name.hasSuffix(plistExtension) else { return false }
        let middle = String(name.dropFirst(perRunPrefix.count).dropLast(plistExtension.count))
        return UUID(uuidString: middle)?.uuidString == middle
    }
}

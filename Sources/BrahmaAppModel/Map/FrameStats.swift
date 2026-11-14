import Foundation

/// A summary of render-frame intervals: what `--map-bench` prints, and what Task 11's `MapBench` reuses.
public struct FrameStats: Equatable, Sendable {
    public var frames: Int
    /// Frames per second over the mean interval (`1000 / meanMs`).
    public var fps: Double
    public var meanMs: Double
    /// The 95th percentile interval by nearest rank (the `ceil(0.95 n)`-th smallest).
    public var p95Ms: Double
    public var maxMs: Double

    public init(frames: Int, fps: Double, meanMs: Double, p95Ms: Double, maxMs: Double) {
        self.frames = frames; self.fps = fps; self.meanMs = meanMs; self.p95Ms = p95Ms; self.maxMs = maxMs
    }

    /// `intervals` are seconds between consecutive frames. Empty input (or only non-finite values) gives all zeros.
    public static func make(intervals: [TimeInterval]) -> FrameStats {
        let ms = intervals.filter { $0.isFinite && $0 >= 0 }.map { $0 * 1000 }.sorted()
        guard !ms.isEmpty else { return FrameStats(frames: 0, fps: 0, meanMs: 0, p95Ms: 0, maxMs: 0) }
        let mean = ms.reduce(0, +) / Double(ms.count)
        let rank = Swift.min(ms.count, Swift.max(1, Int((0.95 * Double(ms.count)).rounded(.up))))
        return FrameStats(frames: ms.count, fps: mean > 0 ? 1000 / mean : 0, meanMs: mean, p95Ms: ms[rank - 1], maxMs: ms[ms.count - 1])
    }
}

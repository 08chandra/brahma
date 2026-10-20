import Foundation

public enum SafetyCap {
    public static func compute(physicalMemoryBytes: UInt64, perProcessBytes: UInt64 = 350 * 1_048_576,
                               reserveFraction: Double = 0.4) -> Int {
        max(1, Int((Double(physicalMemoryBytes) * (1 - reserveFraction) / Double(perProcessBytes)).rounded(.down)))
    }

    public static var current: Int { compute(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory) }
}

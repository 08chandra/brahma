import Foundation
#if canImport(Darwin)
import Dispatch
#endif

public enum MemoryPressure: String, Sendable, Equatable {
    case normal, warning, critical
}

public protocol MemoryPressureSource: Sendable {
    var current: MemoryPressure { get }
}

/// Always normal; the default off Darwin and in tests that don't care.
public struct NormalMemoryPressure: MemoryPressureSource {
    public init() {}
    public var current: MemoryPressure { .normal }
}

#if canImport(Darwin)
/// The system's memory-pressure notifications (`DispatchSource.makeMemoryPressureSource`), latched until the next one.
public final class DispatchMemoryPressureSource: MemoryPressureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var level: MemoryPressure = .normal
    private let source: DispatchSourceMemoryPressure

    public init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let data = self.source.data
            let next: MemoryPressure = data.contains(.critical) ? .critical : data.contains(.warning) ? .warning : .normal
            self.lock.withLock { self.level = next }
        }
        source.resume()
    }

    deinit { source.cancel() }

    public var current: MemoryPressure { lock.withLock { level } }
}
#else
public typealias DispatchMemoryPressureSource = NormalMemoryPressure
#endif

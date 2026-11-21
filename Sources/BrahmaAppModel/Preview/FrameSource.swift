import Foundation

/// A stream of encoded frames (PNG bytes) for a live preview (Plan 4a Task 8a). Used from the view's appear and
/// disappear, so on the main actor; frames are delivered there too.
@MainActor
public protocol FrameSource: AnyObject {
    /// Starts delivering frames; a second call restarts.
    func start(onFrame: @escaping @Sendable (Data) -> Void)
    func stop()
}

/// Frames of an iOS Simulator device, taken with `xcrun simctl io <udid> screenshot <file>` every `interval` once the
/// previous capture has finished: one sequential loop, so two captures never overlap however slow simctl is. The udid
/// is the engine's (a Simulator device id: hex and dashes); anything else never reaches the shell. The default shell runs
/// `/usr/bin/xcrun` with a fixed argv and kills a capture that outlives `captureTimeout`.
@MainActor
public final class SimulatorScreenshotSource: FrameSource {
    /// Runs `argv` (`["xcrun", "simctl", "io", udid, "screenshot", path]`) to completion; throws when it fails.
    public typealias Shell = @Sendable (_ argv: [String]) async throws -> Void

    public static let defaultInterval: Duration = .milliseconds(500)
    public static let captureTimeout: Duration = .seconds(10)

    let udid: String
    let interval: Duration
    let shell: Shell
    private var loop: Task<Void, Never>?

    public init(udid: String, interval: Duration = defaultInterval, shell: @escaping Shell = SimulatorScreenshotSource.xcrun) {
        self.udid = udid
        self.interval = interval
        self.shell = shell
    }

    public func start(onFrame: @escaping @Sendable (Data) -> Void) {
        stop()
        guard Self.isDeviceId(udid) else { return }
        let udid = udid, interval = interval, shell = shell
        loop = Task {
            while !Task.isCancelled {
                if let frame = await Self.capture(udid: udid, shell: shell), !Task.isCancelled { onFrame(frame) }
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// A Simulator device id: hex digits and dashes, at most 64 bytes. Public for the app's "Open Simulator" button, which hands
    /// the udid to `open` only when this passes.
    nonisolated public static func isDeviceId(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// One screenshot into a fresh temp file, read back and removed; nil when simctl failed or wrote nothing.
    nonisolated static func capture(udid: String, shell: Shell) async -> Data? {
        let file = FileManager.default.temporaryDirectory.appending(path: "brahma-sim-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        do { try await shell(["xcrun", "simctl", "io", udid, "screenshot", file.path]) } catch { return nil }
        return try? RendererCaps.readRegularFile(file, maxBytes: 50 * 1024 * 1024)
    }

    struct ShellFailure: Error {
        var status: Int32
    }

    /// `/usr/bin/xcrun` with `argv` after its first element; no stdin, no output. A capture past `captureTimeout` is killed.
    public static let xcrun: Shell = { argv in
        guard argv.first == "xcrun" else { throw ShellFailure(status: -1) }
        final class Box: @unchecked Sendable { let process = Process() }
        let box = Box()
        box.process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        box.process.arguments = Array(argv.dropFirst())
        box.process.standardInput = FileHandle.nullDevice
        box.process.standardOutput = FileHandle.nullDevice
        box.process.standardError = FileHandle.nullDevice
        let watchdog = Task.detached {
            try? await Task.sleep(for: captureTimeout)
            guard !Task.isCancelled, box.process.isRunning else { return }
            kill(box.process.processIdentifier, SIGKILL)
        }
        defer { watchdog.cancel() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            box.process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try box.process.run()
            } catch {
                box.process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw ShellFailure(status: status) }
    }
}

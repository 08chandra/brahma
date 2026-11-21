import Foundation
import BrahmaCore

/// What a renderer gives up on (Plan 4a Task 8a). The app shows `.timedOut` as
/// `.status("CAN'T SHOW THIS FILE", "it took too long to read", [])`.
public enum RendererError: Error, Equatable, Sendable {
    case timedOut
}

/// The caps every in-app renderer shares (Plan 4a Task 8a; pinned numbers in the plan). Agent-written files are hostile
/// input: lines are cut, archives are bounded by their expansion ratio, images and models by size, and every parse helper
/// runs under one timeout through `parse`.
public enum RendererCaps {
    /// The most bytes of one line any renderer keeps (then `…`).
    public static let maxLineBytes = 4096
    /// An archive expanding past this ratio of its size is refused (ML's `ResourcePolicy`).
    public static let maxArchiveRatio = Double(ResourcePolicy.maxArchiveRatio)
    /// How long one parse may take before the app gives up on the file.
    public static let parseTimeout: Duration = .seconds(5)
    /// The largest image decoded in process (width × height, read from the properties before decoding).
    public static let maxImagePixels = 64_000_000
    /// The largest glTF/glb parsed in process; larger files get the file card.
    public static let maxInProcessModelBytes = 20_971_520

    /// `s`, or its longest prefix of at most `maxLineBytes` bytes that ends on a scalar boundary, plus `…`.
    public static func truncateLine(_ s: Substring) -> String {
        let utf8 = s.utf8
        guard utf8.count > maxLineBytes else { return String(s) }
        var cut = utf8.index(utf8.startIndex, offsetBy: maxLineBytes)
        // Back off continuation bytes (10xxxxxx) so the cut lands on the start of a scalar.
        while cut > utf8.startIndex, utf8[cut] & 0xC0 == 0x80 { cut = utf8.index(before: cut) }
        return String(decoding: utf8[utf8.startIndex..<cut], as: UTF8.self) + "…"
    }

    /// Why `readRegularFile` gave nothing.
    enum FileReadFailure: Error, Equatable {
        case notRegular, tooLarge, unreadable
    }

    /// The whole content of `url` when it is a regular file of at most `maxBytes`. The one file opener of every preview
    /// reader: `O_RDONLY | O_NOFOLLOW | O_NONBLOCK` (a link swapped in is `.notRegular`; a FIFO cannot block the open),
    /// then `fstat` on the descriptor requires `S_IFREG` and a size within `maxBytes` before any read (`.tooLarge`
    /// otherwise), then `O_NONBLOCK` is cleared and the file is read.
    static func readRegularFile(_ url: URL, maxBytes: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? FileReadFailure.notRegular : FileReadFailure.unreadable }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw FileReadFailure.unreadable }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw FileReadFailure.notRegular }
        guard st.st_size <= maxBytes else { throw FileReadFailure.tooLarge }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) >= 0 else { throw FileReadFailure.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data: Data
        do { data = try handle.read(upToCount: maxBytes + 1) ?? Data() } catch { throw FileReadFailure.unreadable }
        guard data.count <= maxBytes else { throw FileReadFailure.tooLarge }
        return data
    }

    /// Runs `body` detached from the caller (a synchronous parser off the main actor) and returns its value, or throws
    /// `RendererError.timedOut` once `parseTimeout` passes, cancelling the body's task: a parser that loops checks
    /// `Task.isCancelled` and stops early. Cancelling the caller cancels the body the same way and throws `CancellationError`.
    /// The timeout counts awake time (`SuspendingClock`, the engine's rule for every deadline).
    public static func parse<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await parse(clock: SuspendingClock(), body)
    }

    /// `parse` on an explicit clock (tests drive a manual one).
    public static func parse<T: Sendable, C: Clock>(clock: C, _ body: @escaping @Sendable () throws -> T) async throws -> T
    where C.Duration == Duration {
        let race = ParseRace<T>()
        let timeout = parseTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                race.begin(continuation: continuation, body: body) {
                    try await Task.sleep(for: timeout, tolerance: nil, clock: clock)
                }
            }
        } onCancel: {
            race.finish(with: .failure(CancellationError()))
        }
    }
}

/// One `RendererCaps.parse`: the continuation is resumed exactly once, by whichever of the body, the timer or the
/// caller's cancellation comes first, and the other tasks are cancelled.
private final class ParseRace<T: Sendable>: @unchecked Sendable {
    private enum State {
        /// `begin` has not run; a result that arrived first (the caller cancelled early) waits here.
        case waiting(Result<T, any Error>?)
        case running(CheckedContinuation<T, any Error>, work: Task<Void, Never>?, timer: Task<Void, Never>?)
        case done
    }

    private let lock = NSLock()
    private var state = State.waiting(nil)

    /// `wait` sleeps for the timeout on the caller's clock; it throws when the timer task is cancelled.
    func begin(continuation: CheckedContinuation<T, any Error>, body: @escaping @Sendable () throws -> T,
               wait: @escaping @Sendable () async throws -> Void) {
        let early: Result<T, any Error>? = lock.withLock {
            guard case .waiting(let early) = state else { return nil }
            state = .running(continuation, work: nil, timer: nil)
            return early
        }
        if let early {
            finish(with: early)
            return
        }
        let work = Task.detached(priority: .userInitiated) { [self] in
            self.finish(with: Result { try body() })
        }
        let timer = Task.detached { [self] in
            do { try await wait() } catch { return }
            guard !Task.isCancelled else { return }
            self.finish(with: .failure(RendererError.timedOut))
        }
        let stillRunning: Bool = lock.withLock {
            guard case .running(let c, _, _) = state else { return false }
            state = .running(c, work: work, timer: timer)
            return true
        }
        // The body may have returned before the tasks were recorded: then they are cancelled here.
        if !stillRunning {
            work.cancel()
            timer.cancel()
        }
    }

    func finish(with result: Result<T, any Error>) {
        let resume: (CheckedContinuation<T, any Error>, Task<Void, Never>?, Task<Void, Never>?)? = lock.withLock {
            switch state {
            case .waiting(nil):
                state = .waiting(result)
                return nil
            case .waiting, .done:
                return nil
            case .running(let c, let work, let timer):
                state = .done
                return (c, work, timer)
            }
        }
        guard let (continuation, work, timer) = resume else { return }
        work?.cancel()
        timer?.cancel()
        continuation.resume(with: result)
    }
}

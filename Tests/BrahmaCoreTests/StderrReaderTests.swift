import Testing
import Foundation
@testable import BrahmaCore

/// Pauses the first readability handler at `.entered` until `resume`, and reports when it has returned.
private final class PausedHandler: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let returned = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var first = true

    func hook(_ phase: StderrReader.HandlerPhase) {
        switch phase {
        case .entered:
            let isFirst = lock.withLock { () -> Bool in defer { first = false }; return first }
            if isFirst { entered.signal(); resume.wait() }
        case .returned:
            returned.signal()
        }
    }
}

private func isNonBlocking(_ fd: Int32) -> Bool { fcntl(fd, F_GETFL) & O_NONBLOCK != 0 }

/// The race behind the stderr drain (Plan 3a): clearing `readabilityHandler` does not stop a handler that is already
/// running. The old drain then made the fd non-blocking and emptied it, so the handler's `availableData` hit EAGAIN and
/// Darwin's FileHandle raised an uncatchable NSFileHandleOperationException.
@Suite(.serialized) struct StderrReaderTests {
    /// The seam reproduces the old condition: with the old drain, a handler paused in flight and resumed afterwards reads an
    /// emptied non-blocking fd and fails with EAGAIN, which `availableData` turns into a process crash.
    @Test func seamReproducesTheOldRace() throws {
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        try pipe.fileHandleForWriting.write(contentsOf: Data("before exit\n".utf8))
        let paused = PausedHandler()
        let failure = ErrnoBox()
        pipe.fileHandleForReading.readabilityHandler = { _ in
            paused.hook(.entered)
            // What `availableData` does underneath; on -1 it raises instead of returning.
            var byte: UInt8 = 0
            if read(fd, &byte, 1) < 0 { failure.set(errno) }
            paused.hook(.returned)
        }
        #expect(paused.entered.wait(timeout: .now() + 5) == .success, "the handler started")
        // The old drain, verbatim.
        pipe.fileHandleForReading.readabilityHandler = nil
        let drained = legacyReadWithoutWaiting(fd)
        #expect(String(decoding: drained, as: UTF8.self) == "before exit\n")
        paused.resume.signal()
        #expect(paused.returned.wait(timeout: .now() + 5) == .success)
        #expect(failure.value == EAGAIN, "the in-flight handler read an emptied non-blocking fd")
        try pipe.fileHandleForWriting.close()
    }

    /// Same choreography against the fix: the drain runs while the handler is in flight, the fd stays blocking, the handler
    /// returns without reading (and without blocking, though the writer, like a grandchild, still holds the pipe), and the
    /// tail has everything written before the drain.
    @Test func drainWhileHandlerInFlightNeverFailsARead() throws {
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        try pipe.fileHandleForWriting.write(contentsOf: Data("before exit\n".utf8))
        let paused = PausedHandler()
        let reader = StderrReader(pipe.fileHandleForReading, limit: 4096) { paused.hook($0) }
        reader.start()
        #expect(paused.entered.wait(timeout: .now() + 5) == .success, "the handler started")
        reader.drain()
        #expect(reader.text == "before exit\n")
        #expect(!isNonBlocking(fd), "the fd stays blocking")
        paused.resume.signal()
        #expect(paused.returned.wait(timeout: .now() + 5) == .success, "the in-flight handler returned without blocking")
        #expect(reader.readErrors == 0)
        #expect(!reader.isClosed, "the writer still holds the pipe")
        // Written after the drain: not read by anyone, and nothing fails.
        try pipe.fileHandleForWriting.write(contentsOf: Data("after\n".utf8))
        usleep(50_000)
        #expect(reader.text == "before exit\n")
        #expect(reader.readErrors == 0)
        try pipe.fileHandleForWriting.close()
    }

    @Test func handlerReadsUntilEndOfFileAndDrainIsThenANoOp() throws {
        let pipe = Pipe()
        let reader = StderrReader(pipe.fileHandleForReading, limit: 8)
        reader.start()
        try pipe.fileHandleForWriting.write(contentsOf: Data("0123456789abcdef".utf8))
        try pipe.fileHandleForWriting.close()
        let deadline = AwakeTime.uptime() + 5
        while !reader.isClosed, AwakeTime.uptime() < deadline { usleep(5_000) }
        #expect(reader.isClosed)
        reader.drain()
        reader.drain()
        #expect(reader.text == "89abcdef", "the bounded tail keeps the last bytes")
        #expect(reader.readErrors == 0)
    }
}

/// The drain removed in Plan 3a (it set O_NONBLOCK on a fd a running handler could still read); kept only to prove the
/// seam reproduces its race.
private func legacyReadWithoutWaiting(_ fd: Int32) -> Data {
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while out.count < 4096 * 16 {
        let n = read(fd, &buffer, buffer.count)
        if n < 0, errno == EINTR { continue }
        guard n > 0 else { break }
        out.append(contentsOf: buffer[0..<n])
    }
    return out
}

private final class ErrnoBox: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32 = 0
    func set(_ c: Int32) { lock.withLock { code = c } }
    var value: Int32 { lock.withLock { code } }
}

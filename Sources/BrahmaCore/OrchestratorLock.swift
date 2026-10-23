import Foundation

public enum OrchestratorLockError: Error, Equatable {
    /// Another orchestrator already holds the lock for this data home.
    case alreadyRunning
    case cannotOpen(errno: Int32)
}

/// Single-instance guard: an exclusive `flock` on `<home>/orchestrator.lock`, held until this object is released
/// (or the process exits). Two orchestrators on one database would double-schedule agents and each other's
/// crash recovery would corrupt the other's live turns.
public final class OrchestratorLock: @unchecked Sendable {
    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    public static func acquire(paths: BrahmaPaths) throws -> OrchestratorLock {
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let path = paths.home.appending(path: "orchestrator.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw OrchestratorLockError.cannotOpen(errno: errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            throw code == EWOULDBLOCK ? OrchestratorLockError.alreadyRunning : .cannotOpen(errno: code)
        }
        return OrchestratorLock(fd: fd)
    }

    deinit { close(fd) }
}

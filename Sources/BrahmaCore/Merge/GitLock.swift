import Foundation

public enum GitLockError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// Another holder kept the lock for the whole wait.
    case timeout
    /// The company id is not one safe path component, or the lock file could not be opened.
    case unavailable(String)

    public var description: String {
        switch self {
        case .timeout: "the company's git lock is busy; try again later"
        case .unavailable(let why): "the company's git lock is unavailable: \(why)"
        }
    }
    public var errorDescription: String? { description }
}

/// One company's exclusive git lock (Plan 4a, fix 7): an `flock` on `<home>/run/git-<companyId>.lock`, taken by the merge queue
/// around everything that writes the workspace root, `main`, refs or the engine's merge repository, so two engines (the app and
/// a CLI) never interleave a landing. It lives under the data home, never in a workspace, so no agent can hold it.
///
/// Not re-entrant on a thread: a second `withLock` for the same company waits on a descriptor of its own and times out. 3a's
/// own locks (`GitWorkspace`'s item, main and engine-repository locks) are separate files taken inside it, in that order.
/// Blocking (it polls and sleeps): call it only in a `Blocking` body.
public enum GitLock {
    public static let defaultWait = Duration.seconds(30)
    static let pollInterval: TimeInterval = 0.05

    public static func lockURL(paths: BrahmaPaths, companyId: String) throws -> URL {
        guard companyId.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw GitLockError.unavailable("invalid company id")
        }
        return paths.runDir.appending(path: "git-\(companyId).lock", directoryHint: .notDirectory)
    }

    public static func withLock<T>(paths: BrahmaPaths, companyId: String, wait: Duration = GitLock.defaultWait,
                                   _ body: () throws -> T) throws -> T {
        let url = try lockURL(paths: paths, companyId: companyId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw GitLockError.unavailable("\(error)") }
        // Close-on-exec and no link followed: a git or check spawned meanwhile never carries the lock, and a link planted on its
        // name is not opened.
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GitLockError.unavailable("cannot open the lock file") }
        defer { close(fd) }
        let seconds = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
        // Awake time (`AwakeTime`): a system sleep while waiting is not a busy lock.
        let deadline = AwakeTime.uptime() + seconds
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR { throw GitLockError.unavailable("cannot take the lock") }
            guard AwakeTime.uptime() < deadline else { throw GitLockError.timeout }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

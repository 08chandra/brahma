import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Task 3: the database is out of every agent's reach. The sandbox denies the data home to every sandboxed turn (Task 1a); here
// the engine makes sure the data home can never sit where an agent works (`DataHomeGuard`), and owner commands refuse to run
// from inside a turn, by its environment or by its process ancestry (`OwnerShellGuard`). On the Workspace profile an agent's
// Bash is not sandboxed: the ancestry check is a deterrent there, not a wall (README).

/// Why the data home is refused: it overlaps where agents work, or one of its private directories is not a real directory.
public struct DataHomeError: Error, Equatable, CustomStringConvertible {
    public var reason: String
    public var description: String { reason }
}

/// The data home (the database, the run directory, the backups) must never be reachable from a workspace.
public enum DataHomeGuard {
    /// Throws when the data home and the workspaces root, or the data home and any company workspace, overlap in either
    /// direction, compared resolved (a link on the way is followed for the comparison, so a workspaces root that is a link to
    /// the data home's parent is caught) and as given.
    public static func validate(paths: BrahmaPaths, workspacePaths: [String]) throws {
        let home = paths.home.path
        let homes = Set([home, SandboxPath.resolve(home)])
        func check(_ other: String, _ what: String) throws {
            for h in homes {
                for o in Set([other, SandboxPath.resolve(other)]) where SandboxPath.overlaps(h, o) {
                    throw DataHomeError(reason: "the data home \(Store.flat(home, max: 300)) and \(what) \(Store.flat(other, max: 300)) "
                        + "overlap: agents work in the workspaces, so the data home (the database) must lie outside every one of them "
                        + "(set BRAHMA_HOME or BRAHMA_WORKSPACES apart)")
                }
            }
        }
        try check(paths.workspaces.path, "the workspaces folder")
        for w in workspacePaths { try check(w, "the company workspace") }
    }

    /// Makes the data home, its run directory, its temp directory and its backups 0700, creating missing ones. A link or a
    /// non-directory where one of them should be is refused, never followed or replaced. Each directory is opened without
    /// following a link (`O_DIRECTORY | O_NOFOLLOW`) and changed through that descriptor (`fstat`, `fchmod`), so nothing can be
    /// swapped in between the check and the change. A bad directory does not stop the others (M3): every problem is reported,
    /// in one error, after all of them were tried.
    public static func lockDown(paths: BrahmaPaths) throws {
        var problems: [String] = []
        // Only the data home itself is created here; `run`, `tmp` and `backups` are created (0700) by their own writers, so a
        // read-only owner command (`brahma transcript`, `restore --dry-run`) leaves the tree untouched. Existing ones are tightened.
        if let problem = lockDown(paths.home, create: true) { problems.append(problem) }
        for dir in [paths.runDir, paths.tmpDir, paths.backupsDir] {
            if let problem = lockDown(dir, create: false) { problems.append(problem) }
        }
        guard problems.isEmpty else { throw DataHomeError(reason: problems.joined(separator: "; ")) }
    }

    /// One directory: nil when it is (now) a private directory of this user, else why not.
    private static func lockDown(_ dir: URL, create: Bool) -> String? {
        let path = dir.path, shown = Store.flat(path, max: 300)
        if create {
            if mkdir(path, 0o700) != 0, errno != EEXIST { return "can't create \(shown) (errno \(errno))" }
        } else {
            var st = stat()
            if lstat(path, &st) != 0, errno == ENOENT { return nil }
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            var st = stat()
            if lstat(path, &st) == 0 {
                let what = st.st_mode & S_IFMT == S_IFLNK ? "a symbolic link" : st.st_mode & S_IFMT == S_IFDIR ? nil : "not a directory"
                if let what { return "\(shown) is \(what); the data home's private directories must be real directories" }
            }
            return "can't open \(shown) (errno \(err))"
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return "can't inspect \(shown) (errno \(errno))" }
        guard st.st_mode & S_IFMT == S_IFDIR else {
            return "\(shown) is not a directory; the data home's private directories must be real directories"
        }
        guard st.st_uid == getuid() else { return "\(shown) is not owned by this user" }
        if st.st_mode & 0o777 != 0o700, fchmod(fd, 0o700) != 0 { return "can't make \(shown) private (errno \(errno))" }
        return nil
    }
}

/// A process's ancestors, read from the kernel's process table (the same `ppid` `/bin/ps -o ppid= -p` prints, without a
/// child process per hop).
public enum ProcessAncestry {
    /// `pid`, its parent, its parent's parent, ... up to launchd (pid 1), at most `maxDepth` hops. A pid that does not exist
    /// is the whole chain.
    public static func chain(of pid: Int32, maxDepth: Int = 32) -> [Int32] {
        var chain = [pid]
        var current = pid
        for _ in 0..<max(0, maxDepth) {
            guard let entry = ProcessTable.entry(current), entry.ppid > 0, entry.ppid != current, !chain.contains(entry.ppid) else { break }
            chain.append(entry.ppid)
            if entry.ppid == 1 { break }
            current = entry.ppid
        }
        return chain
    }
}

/// Owner commands never run from inside an agent turn.
public enum OwnerShellGuard {
    /// The variables the engine sets on every turn (and that only a turn carries).
    static let turnVariables = ["BRAHMA_AGENT_ID", TurnContainment.markerVariable, MCPConfig.tokenVariable]

    /// Why an owner command must not run, or nil. Refused when the environment carries a turn's variables, or when one of
    /// `ancestors` (this process and its parents, `ProcessAncestry.chain`) is the process of a turn still running
    /// (`Store.runningTurnPids`): an agent can unset its variables, not its parents.
    public static func refusal(environment: [String: String], ancestors: [Int32], runningTurnPids: Set<Int32>) -> String? {
        if let name = turnVariables.first(where: { environment[$0] != nil }) {
            return "owner commands can't run inside an agent turn (\(name) is set)"
        }
        if let pid = ancestors.first(where: { runningTurnPids.contains($0) }) {
            return "owner commands can't run inside an agent turn (process \(pid), an ancestor of this one, is a running turn)"
        }
        return nil
    }
}

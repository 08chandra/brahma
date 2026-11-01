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
    /// non-directory where one of them should be is refused, never followed or replaced.
    public static func lockDown(paths: BrahmaPaths) throws {
        for dir in [paths.home, paths.runDir, paths.tmpDir, paths.backupsDir] {
            var st = stat()
            if lstat(dir.path, &st) != 0 {
                guard errno == ENOENT else {
                    throw DataHomeError(reason: "can't inspect \(Store.flat(dir.path, max: 300)) (errno \(errno))")
                }
                if mkdir(dir.path, 0o700) != 0, errno != EEXIST {
                    throw DataHomeError(reason: "can't create \(Store.flat(dir.path, max: 300)) (errno \(errno))")
                }
                guard lstat(dir.path, &st) == 0 else { throw DataHomeError(reason: "can't create \(Store.flat(dir.path, max: 300))") }
            }
            guard st.st_mode & S_IFMT == S_IFDIR else {
                let what = st.st_mode & S_IFMT == S_IFLNK ? "a symbolic link" : "not a directory"
                throw DataHomeError(reason: "\(Store.flat(dir.path, max: 300)) is \(what); the data home's private directories must be real directories")
            }
            guard st.st_uid == getuid() else {
                throw DataHomeError(reason: "\(Store.flat(dir.path, max: 300)) is not owned by this user")
            }
            if st.st_mode & 0o777 != 0o700, chmod(dir.path, 0o700) != 0 {
                throw DataHomeError(reason: "can't make \(Store.flat(dir.path, max: 300)) private (errno \(errno))")
            }
        }
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

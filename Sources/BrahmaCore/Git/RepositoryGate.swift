import Foundation

/// The in-process half of a repository's worktree-records lock (`GitWorkspace.withWorktreeRecords`): one gate per
/// repository path, shared by every `GitWorkspace` value of this process (each engine task and each MCP tool call makes its
/// own). Re-entrant on the thread that holds it; `run` tells the body whether this is the outermost hold, so the file lock
/// for other processes is taken once (a second `open` and `flock` from the same thread would wait on itself).
///
/// Waiting here is not bounded by a timer: every holder runs only git commands (each with its own 60 s timeout) and
/// descriptor-relative removals, and takes no other lock inside.
final class RepositoryGate: @unchecked Sendable {
    private static let registry = NSLock()
    nonisolated(unsafe) private static var gates: [String: RepositoryGate] = [:]   // guarded by `registry`

    static func gate(for repository: String) -> RepositoryGate {
        registry.withLock {
            if let gate = gates[repository] { return gate }
            let gate = RepositoryGate()
            gates[repository] = gate
            return gate
        }
    }

    private let lock = NSRecursiveLock()
    /// Only read and written by the thread holding `lock`.
    private var depth = 0

    func run<T>(_ body: (_ outermost: Bool) throws -> T) rethrows -> T {
        lock.lock()
        depth += 1
        defer { depth -= 1; lock.unlock() }
        return try body(depth == 1)
    }
}

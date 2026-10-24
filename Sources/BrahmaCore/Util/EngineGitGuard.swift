import Foundation

/// The run-time half of "engine git runs only in `Blocking` bodies" (the static half is `EngineGitGuardTests`).
///
/// Every task the orchestrator owns runs with `engine` set to its id: ticks and `start` directly, turn tasks by inheritance,
/// and the detached check, merge, git and health tasks by `Orchestrator.asEngine`. A `Blocking` body runs on a thread of its
/// own, outside any task, where `engine` is nil. So a git process started while `engine` is set was started on the
/// actor or the cooperative pool: `GitCommand` reports it here before it runs (it still runs). The site is logged and
/// kept for its engine; `Orchestrator.waitUntilIdle` (the tests' and harnesses' wait) throws `.gitOffBlocking` with them,
/// so the whole test suite fails on such a call.
enum EngineGitGuard {
    @TaskLocal static var engine: String?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var found: [String: [String]] = [:]   // guarded by `lock`

    /// Called by `GitCommand` right before it starts git (`what` names the command).
    static func willRunGit(_ what: @autoclosure () -> String) {
        guard let engine else { return }
        let site = String(what().prefix(200))
        FileHandle.standardError.write(Data("brahma: engine git ran off its blocking threads: \(site)\n".utf8))
        // Bounded: a production engine never calls `waitUntilIdle` to collect them (the log line is what it leaves).
        lock.withLock { if found[engine, default: []].count < 100 { found[engine, default: []].append(site) } }
    }

    /// What `engine` ran off its blocking threads since the last call, cleared.
    static func takeViolations(engine: String) -> [String] {
        lock.withLock { found.removeValue(forKey: engine) ?? [] }
    }
}

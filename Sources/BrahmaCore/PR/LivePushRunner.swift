import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The live `GitPushRunning`: git resolved from the child's absolute `PATH` and exec'd by path (as `GitCommand` does), spawned
/// as the leader of its own process group with exactly `env`, stdin `/dev/null`, stdout and stderr to 0600 files in the call
/// directory, and, when a credential is given, the read end of its pipe at descriptor 3 — no other descriptor (Darwin
/// `POSIX_SPAWN_CLOEXEC_DEFAULT`). Past the timeout the group gets SIGTERM, then SIGKILL; it is reaped after the sweep.
public struct LivePushRunner: GitPushRunning {
    /// Tests only: handed the executable, argv and environment of every git this runner starts (the push test proves the token
    /// is in none of them).
    var spawnObserver: (@Sendable (_ executable: String, _ argv: [String], _ env: [String: String]) -> Void)? = nil
    /// Tests only: added to the child's environment (`GIT_TRACE=<file>`: git logs every process it starts, so the push test can
    /// read the argv of git's own children). Never set by the engine.
    var traceEnvironment: [String: String] = [:]

    public init() {}

    public func run(args: [String], env: [String: String], credential: TokenHandle?, workingDirectory: URL, timeout: Duration,
                    outputCap: Int) throws -> GitPushProcessResult {
        // The same rule as `LiveGitRunner`'s non-descriptor path: a repository and a real work tree path, never an anchored `.`.
        guard env["GIT_DIR"] != nil, let workTree = env["GIT_WORK_TREE"], workTree != "." else {
            throw GitError.failed(command: "push", status: -1, stderr: "git environment without GIT_DIR or with an anchored work tree")
        }
        guard let executable = GitCommand.resolveGit(path: env["PATH"]) else {
            throw GitError.failed(command: "push", status: -1, stderr: "no git executable on an absolute PATH entry")
        }
        EngineGitGuard.willRunGit("git push")
        var environment = env
        for (name, value) in traceEnvironment { environment[name] = value }
        let argv = [executable] + args
        spawnObserver?(executable, argv, environment)
        let base = workingDirectory.appending(path: "git-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
        let fm = FileManager.default
        guard fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let outHandle = FileHandle(forWritingAtPath: outURL.path), let errHandle = FileHandle(forWritingAtPath: errURL.path) else {
            throw GitError.failed(command: "push", status: -1, stderr: "no space for git's output")
        }
        defer {
            Self.closeQuietly(outHandle); Self.closeQuietly(errHandle)
            for url in [outURL, errURL] { GitPush.remove(url, under: workingDirectory) }
        }
        func spawn(_ inherited: [Int32: Int32]) throws -> ProcessGroupChild {
            try ProcessGroupChild.spawn(executable: executable, arguments: argv, environment: environment, workingDirectory: workingDirectory,
                                        output: outHandle.fileDescriptor, stderr: errHandle.fileDescriptor, inherited: inherited)
        }
        let child: ProcessGroupChild
        do {
            if let credential {
                // The engine's read end is closed as soon as the child holds its copy.
                child = try credential.withPipe { fd in try spawn([GitPush.credentialDescriptor: fd]) }
            } else {
                child = try spawn([:])
            }
        } catch let e as ProcessGroupChild.SpawnFailure {
            throw GitError.failed(command: "push", status: -1, stderr: e.message)
        }
        let deadline = Date().addingTimeInterval(SafeGit.seconds(timeout))
        var timedOut = false
        var pause: useconds_t = 5_000
        while !child.hasExited() {
            if Date() >= deadline {
                timedOut = true
                child.signalGroup(SIGTERM)
                let grace = Date().addingTimeInterval(2)
                while !child.hasExited(), Date() < grace { usleep(20_000) }
                if !child.hasExited() { child.signalGroup(SIGKILL) }
                break
            }
            usleep(pause)
            pause = min(pause * 2, 100_000)
        }
        let status = ProcessGroupChild.exitCode(child.finish())
        let stdout = Self.read(outURL, cap: outputCap)
        let stderr = Self.read(errURL, cap: 64 << 10)
        return GitPushProcessResult(status: timedOut ? -1 : status, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    static func read(_ url: URL, cap: Int) -> Data {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return Data() }
        defer { closeQuietly(handle) }
        do { return try handle.read(upToCount: cap) ?? Data() } catch { return Data() }
    }

    static func closeQuietly(_ handle: FileHandle) {
        do { try handle.close() } catch {
            FileHandle.standardError.write(Data("brahma: could not close a push output file: \(error)\n".utf8))
        }
    }
}

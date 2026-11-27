import Foundation

/// A file the launch needs on disk before the process starts (a settings file, an MCP config). Always written 0600 through
/// `EngineFiles` by the launcher; the spec only carries the bytes.
public struct LaunchFile: Sendable, Equatable {
    public var path: String
    public var contents: Data

    public init(path: String, contents: Data) { self.path = path; self.contents = contents }
}

/// How the launched process is confined. Ruling 27: no `.policy(PolicyDecision)` (a Plan S type that is not merged).
public enum LaunchSandbox: Sendable, Equatable {
    /// Claude's own sandbox, configured by the settings file at `path`.
    case claudeSettings(path: String)
    /// No runtime sandbox; the permission profile says what the process may touch.
    case unsandboxed(PermissionProfile)
}

/// Everything the launcher needs to start one turn: the program, its argv, its environment, the files to write first, the
/// sandbox, the working directory and what goes to stdin. Ruling 27: `stdin` is the prompt text (no `RenderedPrompt`).
public struct LaunchSpec: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var files: [LaunchFile]
    public var sandbox: LaunchSandbox
    public var workingDirectory: String
    public var stdin: String
    /// The turn's own wall clock, when the compiled turn names one (a mode's, the concierge's); nil: the launcher's default.
    public var wallClock: Duration?

    public init(executable: String, arguments: [String], environment: [String: String], files: [LaunchFile], sandbox: LaunchSandbox,
                workingDirectory: String, stdin: String, wallClock: Duration? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.files = files
        self.sandbox = sandbox; self.workingDirectory = workingDirectory; self.stdin = stdin; self.wallClock = wallClock
    }
}

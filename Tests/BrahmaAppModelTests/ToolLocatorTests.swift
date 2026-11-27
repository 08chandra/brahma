import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

@Suite(.scratch) struct ToolLocatorTests {
    @Test func mcpHelperPrefersBundleHelpers() {
        let existing: Set<String> = ["/A/Brahma.app/Contents/Helpers/brahma", "/A/Brahma.app/Contents/MacOS/brahma"]
        let found = ToolLocator.mcpHelper(appBundle: URL(fileURLWithPath: "/A/Brahma.app"),
                                          executable: URL(fileURLWithPath: "/A/Brahma.app/Contents/MacOS/Brahma"),
                                          isExecutable: { existing.contains($0) })
        #expect(found == "/A/Brahma.app/Contents/Helpers/brahma")
    }

    @Test func devBuildUsesSiblingBinary() {
        let bundle = URL(fileURLWithPath: "/p/.build/debug")
        let exe = URL(fileURLWithPath: "/p/.build/debug/BrahmaApp")
        #expect(ToolLocator.mcpHelper(appBundle: bundle, executable: exe, isExecutable: { $0 == "/p/.build/debug/brahma" })
                == "/p/.build/debug/brahma")
        #expect(ToolLocator.mcpHelper(appBundle: bundle, executable: exe, isExecutable: { _ in false }) == nil)
    }

    @Test func claudeOverrideWins() {
        let env = ["BRAHMA_CLAUDE": "/x/fake"]
        #expect(ToolLocator.claude(environment: env, engineTool: { _ in "/usr/local/bin/claude" },
                                   isExecutable: { $0 == "/x/fake" }) == .success("/x/fake"))
        // A bad override never falls back to ToolPaths' claude.
        #expect(ToolLocator.claude(environment: env, engineTool: { _ in "/usr/local/bin/claude" },
                                   isExecutable: { _ in false }) == .failure(.claudeNotFound))
        // B9: a relative override is refused with its own message, never looked up.
        let relative = ToolLocator.claude(environment: ["BRAHMA_CLAUDE": "claude"], engineTool: { _ in "/usr/local/bin/claude" },
                                          isExecutable: { _ in true })
        #expect(relative == .failure(.claudeOverrideNotAbsolute("claude")))
        #expect(EngineSetupError.claudeOverrideNotAbsolute("bin/claude").message.contains("BRAHMA_CLAUDE must be an absolute path"))
    }

    /// B9 (S5 fix I1): without an override the app hands the engine the bare name `claude`, which the runner resolves through
    /// `ToolPaths`; a `claude` in a world-writable directory earlier on PATH is never the one started.
    @Test func claudeComesFromToolPaths() throws {
        let scratch = try tempDir()
        func dir(_ name: String, mode: Int) throws -> URL {
            let d = scratch.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let exe = d.appending(path: "claude")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
            try FakeTools.fixtureMode(0o755, at: exe)
            chmod(d.path, mode_t(mode))  // exec-bit fixture: the directory mode is under test
            return d
        }
        let open = try dir("open", mode: 0o777), safe = try dir("safe", mode: 0o755)
        let path = "\(open.path):\(safe.path):/usr/bin:/bin"
        let lookup: (String) -> String? = { ToolPaths.lookup($0, path: path, forbiddenRoots: []) }
        let given = try ToolLocator.claude(environment: ["PATH": path], engineTool: lookup).get()
        #expect(given == "claude", "the bare name, resolved at each start")
        let started = try ClaudeProcessRunner.executable(given, engineTool: lookup)
        #expect(started == safe.appending(path: "claude").path, "\(started)")
        #expect(!started.hasPrefix(open.path))
        // Only the world-writable one: no claude at all.
        let none: (String) -> String? = { ToolPaths.lookup($0, path: open.path, forbiddenRoots: []) }
        #expect(ToolLocator.claude(environment: ["PATH": open.path], engineTool: none) == .failure(.claudeNotFound))
        #expect(throws: ToolPathsError.claudeMissing) { try ClaudeProcessRunner.executable("claude", engineTool: none) }
    }

    @Test func loginPathParsedBetweenMarkers() {
        #expect(ToolLocator.parseMarkedPath("Welcome!\n__BRAHMA_PATH__/opt/homebrew/bin:/usr/bin__END__\n") == "/opt/homebrew/bin:/usr/bin")
        #expect(ToolLocator.parseMarkedPath("no markers") == nil)
    }

    @Test func mergedPathPutsLoginFirstAndDedups() {
        #expect(ToolLocator.mergePath(login: "/opt/homebrew/bin:/usr/bin", current: "/usr/bin:/bin:") == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(ToolLocator.mergePath(login: nil, current: "/usr/bin:/bin") == "/usr/bin:/bin")
    }

    @Test func loginShellPathTimesOut() throws {
        let script = try FakeTools.script("slowsh", "sleep 120")
        let start = AwakeTime.now
        let result = ToolLocator.loginShellPath(shell: script.path, timeout: .seconds(1))
        #expect(result == nil)
        #expect(AwakeTime.now - start < .seconds(60), "hang guard: the script sleeps 120 s")
    }

    /// Depends on the owner's real login shell and dotfiles, so it is opt-in: BRAHMA_REAL_SHELL_TESTS=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_REAL_SHELL_TESTS"] == "1"))
    func realZshReturnsPath() {
        #expect(ToolLocator.loginShellPath(shell: "/bin/zsh")?.contains("/usr/bin") == true)
    }
}

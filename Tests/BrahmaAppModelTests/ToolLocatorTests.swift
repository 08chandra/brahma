import Testing
import Foundation
import BrahmaCore
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
        #expect(ToolLocator.claude(environment: env, searchPath: "/usr/local/bin",
                                   isExecutable: { $0 == "/x/fake" || $0 == "/usr/local/bin/claude" }) == "/x/fake")
        #expect(ToolLocator.claude(environment: env, searchPath: "/usr/local/bin",
                                   isExecutable: { $0 == "/usr/local/bin/claude" }) == nil)
    }

    @Test func claudeFoundOnSearchPath() {
        #expect(ToolLocator.claude(environment: [:], searchPath: "/usr/bin:/opt/homebrew/bin",
                                   isExecutable: { $0 == "/opt/homebrew/bin/claude" }) == "/opt/homebrew/bin/claude")
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

import Testing
import Foundation
@testable import BrahmaCore

@Test func secondOrchestratorLockFailsUntilFirstIsReleased() throws {
    let root = try tempDir()
    let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
    var first: OrchestratorLock? = try OrchestratorLock.acquire(paths: paths)
    #expect(throws: OrchestratorLockError.alreadyRunning) { _ = try OrchestratorLock.acquire(paths: paths) }
    #expect(first != nil)
    first = nil
    _ = try OrchestratorLock.acquire(paths: paths)
}

@Test func sanitizerNeutralisesControlCharacters() {
    #expect(TerminalText.sanitize("a\u{1B}[2Jb") == "a [2Jb")
    #expect(TerminalText.sanitize("x\u{9B}31my") == "x 31my")
    #expect(TerminalText.sanitize("p\u{7F}q") == "p q")
    #expect(TerminalText.sanitize("line1\nline2\ttab\r") == "line1 line2 tab ")
    #expect(TerminalText.sanitize("héllo ✓ 日本") == "héllo ✓ 日本")
}

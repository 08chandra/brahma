import Testing
import Foundation
@testable import BrahmaSafety

/// S4 fix round 1 (M2, M6): a directory the kernel must list but cannot is never read as empty. `SandboxPath.entries` throws,
/// `EngineFiles.treeBytes` reports the tree unmeasurable (naming the directory); one that is missing (or went away meanwhile)
/// is still nothing, or what was seen of it.
@Suite(.scratch) struct FailClosedListingTests {
    /// A directory made unlistable (`0o000`) for the body; its mode is put back afterwards so the scratch cleanup can remove it.
    private func locked<T>(_ dir: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }   // exec-bit fixture: a directory mode
        return try body()
    }

    @Test func entriesThrowsOnAnUnlistableDirectory() throws {
        let dir = try tempDir().appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appending(path: "f"))
        #expect(try SandboxPath.entries(dir.path) == ["f"])
        try locked(dir) {
            #expect(throws: (any Error).self) { _ = try SandboxPath.entries(dir.path) }
        }
        // Missing (or gone meanwhile): nothing, not an error.
        #expect(try SandboxPath.entries(dir.appending(path: "gone").path) == [])
    }

    @Test func treeBytesReportsAnUnmeasurableTree() throws {
        let root = try tempDir().appending(path: "repo", directoryHint: .isDirectory)
        let sub = root.appending(path: "objects", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1000).write(to: sub.appending(path: "pack"))
        let measured = try EngineFiles.treeBytes(root)
        #expect(measured >= 1000)
        try locked(sub) {
            #expect(throws: EngineFiles.Unmeasurable(path: sub.path)) { _ = try EngineFiles.treeBytes(root) }
        }
        // A tree that is not there is what was seen of it: nothing.
        #expect(try EngineFiles.treeBytes(root.appending(path: "gone")) == 0)
    }
}

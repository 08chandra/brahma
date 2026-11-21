import Testing
import Foundation
@testable import BrahmaCore

/// `SafeFS`: agent-named paths under `.brahma/` and in item worktrees, classified by inode and opened through descriptors.
@Suite(.scratch) struct SafeFSTests {
    /// A workspace with `.brahma/{labs/eng-1,labs/qa-2,home/eng-1,notes/agents,artifacts,checks}` and `.brahma/wt/ENG-1/`.
    struct Fixture {
        let ws: URL
        let fs: SafeFS
        init(handle: String? = "eng-1") throws {
            ws = try tempDir().appending(path: "ws", directoryHint: .isDirectory)
            for dir in [".brahma/labs/eng-1", ".brahma/labs/qa-2", ".brahma/home/eng-1", ".brahma/notes/agents", ".brahma/artifacts",
                        ".brahma/checks", ".brahma/wt/ENG-1"] {
                try FileManager.default.createDirectory(at: ws.appending(path: dir), withIntermediateDirectories: true)
            }
            fs = try SafeFS(workspace: ws, ownHandle: handle)
        }
        @discardableResult
        func write(_ relative: String, _ text: String) throws -> URL {
            let url = ws.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    @Test func ownLabAndArtifactsOpen() throws {
        let f = try Fixture()
        try f.write(".brahma/labs/eng-1/n.txt", "hello")
        let lab = try f.fs.open(workspacePath: ".brahma/labs/eng-1/n.txt", maxBytes: 1000)
        #expect(lab.place == .ownLab)
        #expect(lab.size == 5)
        #expect(try lab.readAll() == Data("hello".utf8))
        #expect(try lab.sha256() == SHA256.hex("hello"))
        try f.write(".brahma/artifacts/1-x/a.md", "# a")
        let art = try f.fs.open(workspacePath: ".brahma/artifacts/1-x/a.md", maxBytes: 1000)
        #expect(art.place == .brahmaChild("artifacts"))
        #expect(try art.readAll() == Data("# a".utf8))
        // `copy(toFD:)` writes the bytes of the descriptor it holds.
        let out = try tempDir().appending(path: "copy.bin")
        let fd = open(out.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        try #require(fd >= 0)
        try art.copy(toFD: fd)
        close(fd)
        #expect(try Data(contentsOf: out) == Data("# a".utf8))
        // The other place names: own notes file; a path outside `.brahma` is for git.
        try f.write(".brahma/notes/agents/eng-1.md", "mine")
        #expect(try f.fs.open(workspacePath: ".brahma/notes/agents/eng-1.md", maxBytes: 100).place == .ownNotes)
        try f.write("src/main.swift", "x")
        #expect(throws: SafeFSError.notInPlace) { try f.fs.open(workspacePath: "src/main.swift", maxBytes: 100) }
    }

    @Test func otherAgentLabRefused() throws {
        let f = try Fixture()
        try f.write(".brahma/labs/qa-2/n.txt", "theirs")
        #expect(throws: SafeFSError.privateTo("qa-2")) { try f.fs.open(workspacePath: ".brahma/labs/qa-2/n.txt", maxBytes: 1000) }
        try f.write(".brahma/notes/agents/qa-2.md", "theirs")
        #expect(throws: SafeFSError.privateTo("qa-2")) { try f.fs.open(workspacePath: ".brahma/notes/agents/qa-2.md", maxBytes: 1000) }
        // The entry name in the error is ASCII-sanitized.
        try f.write(".brahma/labs/qä-2/n.txt", "x")
        #expect(throws: SafeFSError.privateTo("q?-2")) { try f.fs.open(workspacePath: ".brahma/labs/qä-2/n.txt", maxBytes: 1000) }
    }

    @Test func ownHomeAndChecksNotAllowed() throws {
        let f = try Fixture()
        try f.write(".brahma/home/eng-1/x", "transcript")
        try f.write(".brahma/checks/x", "check")
        try f.write(".brahma/notes/team.md", "team")
        #expect(throws: SafeFSError.notAllowed) { try f.fs.open(workspacePath: ".brahma/home/eng-1/x", maxBytes: 1000) }
        #expect(throws: SafeFSError.notAllowed) { try f.fs.open(workspacePath: ".brahma/checks/x", maxBytes: 1000) }
        #expect(throws: SafeFSError.notAllowed) { try f.fs.open(workspacePath: ".brahma/notes/team.md", maxBytes: 1000) }
    }

    @Test func symlinkEscapeRefused() throws {
        let f = try Fixture()
        let wt = f.ws.appending(path: ".brahma/wt/ENG-1")
        try FileManager.default.createSymbolicLink(at: wt.appending(path: "a.txt"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let outside = try tempDir()
        try "secret".write(to: outside.appending(path: "x.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: wt.appending(path: "d"), withDestinationURL: outside)
        #expect(throws: SafeFSError.linked) { try f.fs.open("a.txt", inWorktree: "ENG-1", maxBytes: 1 << 20) }
        #expect(throws: SafeFSError.linked) { try f.fs.open("d/x.txt", inWorktree: "ENG-1", maxBytes: 1 << 20) }
    }

    @Test func symlinkRaceRefused() throws {
        let f = try Fixture()
        try f.write(".brahma/artifacts/sub/a.md", "real")
        let outside = try tempDir()
        try "planted".write(to: outside.appending(path: "a.md"), atomically: true, encoding: .utf8)
        let sub = f.ws.appending(path: ".brahma/artifacts/sub")
        // Right after `artifacts` (component 1) is opened, `sub` is swapped for a link to the outside directory.
        f.fs.testHookAfterComponent = { index in
            guard index == 1 else { return }
            try? FileManager.default.moveItem(at: sub, to: sub.appendingPathExtension("moved"))
            try? FileManager.default.createSymbolicLink(at: sub, withDestinationURL: outside)
        }
        #expect(throws: SafeFSError.linked) { try f.fs.open(workspacePath: ".brahma/artifacts/sub/a.md", maxBytes: 1000) }
    }

    @Test func hardlinkRefused() throws {
        let f = try Fixture()
        let secret = try tempDir().appending(path: "secret.txt")
        try "owner".write(to: secret, atomically: true, encoding: .utf8)
        let planted = f.ws.appending(path: ".brahma/labs/eng-1/planted.txt")
        try #require(link(secret.path, planted.path) == 0)
        #expect(throws: SafeFSError.linked) { try f.fs.open(workspacePath: ".brahma/labs/eng-1/planted.txt", maxBytes: 1000) }
    }

    @Test func caseVariantUsesInode() throws {
        let f = try Fixture()
        try f.write(".brahma/labs/qa-2/n.txt", "x")
        try f.write(".brahma/home/eng-1/x", "x")
        guard FileManager.default.fileExists(atPath: f.ws.appending(path: ".BRAHMA/Labs/qa-2/n.txt").path) else {
            return   // a case-sensitive volume: the variant names nothing, so there is nothing to classify
        }
        #expect(throws: SafeFSError.privateTo("qa-2")) { try f.fs.open(workspacePath: ".BRAHMA/Labs/qa-2/n.txt", maxBytes: 1000) }
        #expect(throws: SafeFSError.notAllowed) { try f.fs.open(workspacePath: ".Brahma/Home/eng-1/x", maxBytes: 1000) }
    }

    @Test func nfdVariantSamePlace() throws {
        let f = try Fixture()
        let nfc = "café.txt", nfd = "cafe\u{0301}.txt"
        try #require(Array(nfc.utf8) != Array(nfd.utf8) && nfc.decomposedStringWithCanonicalMapping == nfd)   // String == is canonical
        try f.write(".brahma/labs/eng-1/\(nfc)", "x")
        #expect(try f.fs.open(workspacePath: ".brahma/labs/eng-1/\(nfc)", maxBytes: 1000).place == .ownLab)
        var st = stat()
        guard lstat(f.ws.appending(path: ".brahma/labs/eng-1/\(nfd)").path, &st) == 0 else {
            return   // the volume does not normalize names: the NFD spelling names nothing
        }
        #expect(try f.fs.open(workspacePath: ".brahma/labs/eng-1/\(nfd)", maxBytes: 1000).place == .ownLab)
    }

    @Test(arguments: ["..", "a/../b", "", "a//b", "a\u{0}b", "a\u{7}b", ".brahma\u{200B}/labs/x", "/.brahma/labs/x", ".brahma/./labs/x",
                      "a\u{202E}b", "a\u{85}b"])
    func badComponentsRefused(_ p: String) throws {
        let f = try Fixture()
        #expect(throws: SafeFSError.badPath) { try f.fs.open(workspacePath: p, maxBytes: 1000) }
        #expect(throws: SafeFSError.badPath) { try f.fs.open(p, inWorktree: "ENG-1", maxBytes: 1000) }
    }

    @Test func sizeCapRefused() throws {
        let f = try Fixture()
        try f.write(".brahma/labs/eng-1/big.txt", "01234567890")
        #expect(throws: SafeFSError.tooLarge(11)) { try f.fs.open(workspacePath: ".brahma/labs/eng-1/big.txt", maxBytes: 10) }
        #expect(try f.fs.open(workspacePath: ".brahma/labs/eng-1/big.txt", maxBytes: 11).size == 11)
    }

    @Test func notRegularRefused() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.ws.appending(path: ".brahma/artifacts/1-x"), withIntermediateDirectories: true)
        #expect(throws: SafeFSError.notRegular) { try f.fs.open(workspacePath: ".brahma/artifacts/1-x", maxBytes: 1000) }
        #expect(throws: SafeFSError.notAllowed) { try f.fs.open(workspacePath: ".brahma/artifacts", maxBytes: 1000) }
        try #require(mkfifo(f.ws.appending(path: ".brahma/labs/eng-1/pipe").path, 0o600) == 0)
        #expect(throws: SafeFSError.notRegular) { try f.fs.open(workspacePath: ".brahma/labs/eng-1/pipe", maxBytes: 1000) }
    }

    @Test func createExclusiveRefusesPlantedLink() throws {
        let f = try Fixture()
        let outside = try tempDir()
        try FileManager.default.createSymbolicLink(at: f.ws.appending(path: ".brahma/labs/eng-1/in"), withDestinationURL: outside)
        #expect(throws: SafeFSError.linked) { try f.fs.createExclusive(name: "x.md", inOwnLabSubdir: "in", data: Data("x".utf8)) }
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: "x.md").path), "the link was followed")
        let relative = try f.fs.createExclusive(name: "x.md", inOwnLabSubdir: "shares", data: Data("shared".utf8))
        #expect(relative == "shares/x.md")
        let url = f.ws.appending(path: ".brahma/labs/eng-1/shares/x.md")
        #expect(try Data(contentsOf: url) == Data("shared".utf8))
        var st = stat()
        #expect(lstat(url.path, &st) == 0 && st.st_mode & 0o777 == 0o444)
        #expect(throws: SafeFSError.exists) { try f.fs.createExclusive(name: "x.md", inOwnLabSubdir: "shares", data: Data("again".utf8)) }
        #expect(try Data(contentsOf: url) == Data("shared".utf8))
        #expect(throws: SafeFSError.badPath) { try f.fs.createExclusive(name: "../x.md", inOwnLabSubdir: "shares", data: Data()) }
        #expect(throws: SafeFSError.badPath) { try f.fs.createExclusive(name: "y.md", inOwnLabSubdir: "../qa-2", data: Data()) }
        #expect(throws: SafeFSError.notAllowed) { try Fixture(handle: nil).fs.createExclusive(name: "y.md", inOwnLabSubdir: "s", data: Data()) }
    }
}

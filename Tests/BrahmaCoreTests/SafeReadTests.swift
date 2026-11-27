import Testing
import Foundation
@testable import BrahmaCore

/// `SafeRead.smallText` (spec §6.9 item 2): the one bounded no-follow reader for small engine-verified files. Every component
/// is opened `O_NOFOLLOW` from the resolved root, the open descriptor is judged (regular, one link, this user's, within the
/// limit), at most `limit + 1` bytes are read, and the text is strict UTF-8.
@Suite(.scratch) struct SafeReadTests {
    private func dir() throws -> URL { try tempDir() }

    private func write(_ name: String, _ bytes: [UInt8], in dir: URL) throws -> URL {
        let url = dir.appending(path: name)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func readsASmallRegularFile() throws {
        let d = try dir()
        _ = try write("HEAD", Array("ref: refs/heads/item/K-1\n".utf8), in: d)
        #expect(try SafeRead.smallText("HEAD", under: d) == "ref: refs/heads/item/K-1\n")
        // Through a real subdirectory, and exactly at the limit.
        try FileManager.default.createDirectory(at: d.appending(path: "refs/heads"), withIntermediateDirectories: true)
        _ = try write("refs/heads/x", [UInt8](repeating: UInt8(ascii: "a"), count: SafeRead.defaultLimit), in: d)
        #expect(try SafeRead.smallText("refs/heads/x", under: d).count == SafeRead.defaultLimit)
        // A smaller limit is the one judged.
        #expect(throws: SafeReadError.tooLarge(8)) { try SafeRead.smallText("refs/heads/x", under: d, limit: 8) }
    }

    /// The target is a symbolic link to a 1 GB sparse file: refused as a link, never opened or read.
    @Test func swappedLinkIsRefused() throws {
        let d = try dir()
        let huge = d.appending(path: "huge")
        let fd = open(huge.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        #expect(fd >= 0)
        #expect(ftruncate(fd, 1 << 30) == 0)
        close(fd)
        try FileManager.default.createSymbolicLink(atPath: d.appending(path: "pointer").path, withDestinationPath: huge.path)
        #expect(throws: SafeReadError.linked) { try SafeRead.smallText("pointer", under: d) }
        // A link on the way is refused too.
        try FileManager.default.createSymbolicLink(atPath: d.appending(path: "way").path, withDestinationPath: d.path)
        #expect(throws: SafeReadError.self) { try SafeRead.smallText("way/huge", under: d) }
    }

    @Test func oversizedIsRefused() throws {
        let d = try dir()
        _ = try write("big", [UInt8](repeating: UInt8(ascii: "x"), count: 4097), in: d)
        #expect(throws: SafeReadError.tooLarge(4096)) { try SafeRead.smallText("big", under: d) }
    }

    /// A FIFO is never opened blocking: the verdict (`notRegular`) comes back at once.
    @Test(.timeLimit(.minutes(1))) func fifoDoesNotHang() throws {
        let d = try dir()
        #expect(mkfifo(d.appending(path: "pipe").path, 0o600) == 0)
        let start = ContinuousClock.now
        #expect(throws: SafeReadError.notRegular) { try SafeRead.smallText("pipe", under: d) }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func hardLinkRefused() throws {
        let d = try dir()
        let a = try write("a", Array("text\n".utf8), in: d)
        #expect(link(a.path, d.appending(path: "b").path) == 0)
        #expect(throws: SafeReadError.multiplyLinked) { try SafeRead.smallText("a", under: d) }
        #expect(throws: SafeReadError.multiplyLinked) { try SafeRead.smallText("b", under: d) }
    }

    @Test func invalidUTF8AndMissingAreRefused() throws {
        let d = try dir()
        _ = try write("bytes", [0xFF, 0xFE, 0x41], in: d)
        #expect(throws: SafeReadError.notUTF8) { try SafeRead.smallText("bytes", under: d) }
        #expect(throws: SafeReadError.self) { try SafeRead.smallText("missing", under: d) }
        #expect(throws: SafeReadError.self) { try SafeRead.smallText("../bytes", under: d) }
        #expect(throws: SafeReadError.self) { try SafeRead.smallText("", under: d) }
    }

    @Test func sandboxedNoteIsTheB1Text() {
        #expect(SafeRead.sandboxedNote(subject: "web", reason: "no setter")
                == "web ran sandboxed: the engine could not confirm who wrote it (no setter)")
    }
}

import Testing
import Foundation
@testable import BrahmaAppModel

/// Every file operation here runs in a scratch directory standing in for `~/Library/Preferences`; the real one is never
/// read or written.
@Suite(.scratch) struct HarnessDefaultsTests {
    private func write(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        try Data("<plist/>".utf8).write(to: url)
        return url
    }

    @Test func suiteNameAndPreferencesDirectory() {
        #expect(HarnessDefaults.suiteName(pid: 4242) == "brahma.harness.4242")
        #expect(HarnessDefaults.preferencesDirectory.path.hasSuffix("/Library/Preferences"))
    }

    @Test func onlyExactNamesParse() {
        #expect(HarnessDefaults.pid(fileName: "brahma.harness.123.plist") == 123)
        #expect(HarnessDefaults.pid(fileName: "brahma.harness.2147483647.plist") == Int32.max)
        for name in ["brahma.harness.0.plist", "brahma.harness.-5.plist", "brahma.harness.+5.plist",
                     "brahma.harness.0123.plist", "brahma.harness.2147483648.plist", "brahma.harness..plist",
                     "brahma.harness.12a.plist", "brahma.harness.12.plist.bak", "brahma.harness.12.PLIST",
                     "brahma.harness.12", "Brahma.harness.12.plist", "brahma.harnessX.12.plist", "xbrahma.harness.12.plist",
                     "brahma.harness.١٢.plist", "brahma.harness.1 2.plist", "com.apple.finder.plist"] {
            #expect(HarnessDefaults.pid(fileName: name) == nil, "\(name)")
        }
    }

    @Test func sweepRemovesOnlyDeadHarnessPlists() throws {
        let dir = try tempDir()
        let dead = try write("brahma.harness.111.plist", in: dir)
        let alive = try write("brahma.harness.222.plist", in: dir)
        let untouched = try [
            write("brahma.harness.0333.plist", in: dir),
            write("brahma.harness.0.plist", in: dir),
            write("brahma.harnessX.444.plist", in: dir),
            write("brahma.harness.777.plist.lockfile", in: dir),
            write("com.apple.finder.plist", in: dir),
            write("brahma.map.plist", in: dir),
        ]
        // A folder and a link with a harness name and a dead pid are not plists the suite wrote: left alone, and the
        // link's target too.
        let folder = dir.appending(path: "brahma.harness.555.plist", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let target = try write("target.plist", in: dir)
        let link = dir.appending(path: "brahma.harness.666.plist", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        var probed: [Int32] = []
        let removed = HarnessDefaults.sweep(in: dir) { pid in probed.append(pid); return pid == 222 }

        #expect(removed.map(\.lastPathComponent) == ["brahma.harness.111.plist"])
        #expect(!FileManager.default.fileExists(atPath: dead.path))
        #expect(FileManager.default.fileExists(atPath: alive.path))
        for url in untouched + [folder, target] { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "the link stays")
        // Only exact-name regular files are probed, never 0 or a malformed number.
        #expect(Set(probed) == [111, 222])
    }

    @Test func sweepOfMissingOrEmptyDirectoryIsQuiet() throws {
        let dir = try tempDir()
        #expect(HarnessDefaults.sweep(in: dir) { _ in false }.isEmpty)
        #expect(HarnessDefaults.sweep(in: dir.appending(path: "missing")) { _ in false }.isEmpty)
    }

    @Test func removePlistRemovesOnlyThatPid() throws {
        let dir = try tempDir()
        let mine = try write("brahma.harness.900.plist", in: dir)
        let other = try write("brahma.harness.901.plist", in: dir)
        HarnessDefaults.removePlist(pid: 900, in: dir)
        #expect(!FileManager.default.fileExists(atPath: mine.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        // Already gone: nothing happens.
        HarnessDefaults.removePlist(pid: 900, in: dir)
    }

    @Test func livenessProbe() {
        #expect(HarnessDefaults.isProcessAlive(getpid()))
        // Beyond any pid macOS assigns: ESRCH, so not alive (kill(_, 0) sends nothing).
        #expect(!HarnessDefaults.isProcessAlive(99_999_999))
        // 0 and negatives would address process groups: never probed, treated as alive so nothing is removed.
        #expect(HarnessDefaults.isProcessAlive(0))
        #expect(HarnessDefaults.isProcessAlive(-1))
    }
}

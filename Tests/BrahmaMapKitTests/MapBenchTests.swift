import Testing
import Foundation
@testable import BrahmaMapKit

/// The bench's defaults hygiene (final review M1). Every file operation runs in a scratch directory standing in for
/// `~/Library/Preferences`; the real one is never read or written, and no bench run happens here.
@MainActor
@Suite(.scratch) struct MapBenchTests {
    private func write(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        try Data("<plist/>".utf8).write(to: url)
        return url
    }

    @Test func oneFixedSuite() {
        #expect(MapBench.suiteName == "brahma.mapbench")
    }

    @Test func onlyBenchPlistNamesMatch() {
        let uuid = "0F8C5A3E-1B2D-4C6E-9A7B-3D5E7F9A1B2C"
        #expect(MapBench.isBenchPlist("brahma.mapbench.plist"))
        #expect(MapBench.isBenchPlist("brahma.mapbench.\(uuid).plist"))
        for name in ["brahma.mapbench.\(uuid.lowercased()).plist", "brahma.mapbench.\(uuid).plist.lockfile",
                     "brahma.mapbench.\(uuid)", "brahma.mapbench.\(uuid.dropLast()).plist", "brahma.mapbench.x.plist",
                     "brahma.mapbench..plist", "brahma.mapbench.plist.bak", "brahma.mapbenchX.\(uuid).plist",
                     "xbrahma.mapbench.plist", "brahma.harness.123.plist", "brahma.map.plist", "\(uuid).plist",
                     "com.apple.finder.plist"] {
            #expect(!MapBench.isBenchPlist(name), "\(name)")
        }
    }

    @Test func removesOnlyTheBenchPlists() throws {
        let dir = try tempDir()
        let mine = try [
            write("brahma.mapbench.plist", in: dir),
            write("brahma.mapbench.\(UUID().uuidString).plist", in: dir),
            write("brahma.mapbench.\(UUID().uuidString).plist", in: dir),
        ]
        let untouched = try [
            write("brahma.mapbench.\(UUID().uuidString.lowercased()).plist", in: dir),
            write("brahma.mapbench.\(UUID().uuidString).plist.lockfile", in: dir),
            write("brahma.harness.123.plist", in: dir),
            write("brahma.map.plist", in: dir),
            write("\(UUID().uuidString).plist", in: dir),
            write("com.apple.finder.plist", in: dir),
        ]
        // A folder and a link with a bench name are not plists the bench wrote: left alone, and the link's target too.
        let folder = dir.appending(path: "brahma.mapbench.\(UUID().uuidString).plist", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let target = try write("target.plist", in: dir)
        let link = dir.appending(path: "brahma.mapbench.\(UUID().uuidString).plist", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let removed = MapBench.removePlists(in: dir)

        #expect(Set(removed.map(\.lastPathComponent)) == Set(mine.map(\.lastPathComponent)))
        for url in mine { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)") }
        for url in untouched + [folder, target] {
            #expect(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent)")
        }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil, "the link stays")
        // Nothing left to remove; a missing directory is quiet.
        #expect(MapBench.removePlists(in: dir).isEmpty)
        #expect(MapBench.removePlists(in: dir.appending(path: "missing")).isEmpty)
    }
}

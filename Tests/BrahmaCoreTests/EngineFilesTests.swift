import Testing
import Foundation
@testable import BrahmaCore

/// The removal probe is process-wide, so these run one at a time; each probe only acts on its own temporary directory.
@Suite(.scratch, .serialized) struct EngineFilesTests {
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// A probe that runs `body` once, the first time an entry called `name` under `inside` is about to be removed.
    private func probeOnce(inside: URL, name: String, _ body: @escaping (_ parent: String) -> Void) -> () -> Bool {
        let fired = Flag()
        // The kernel's path (`/private/var/…`), which is what the probe is given.
        let prefix = realpath(inside.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? inside.path
        EngineFiles.removalProbe = { parent, entry in
            guard entry == name, parent.hasPrefix(prefix), !fired.value else { return }
            fired.value = true
            body(parent)
        }
        return { fired.value }
    }

    @Test func removalNeverFollowsAParentSwappedForALink() throws {
        defer { EngineFiles.removalProbe = nil }
        let fm = FileManager.default
        let ws = try tempDir(), outside = try tempDir()
        try EngineFiles.directory(workspace: ws, ".brahma/checks/K/rev1/s")
        #expect(try EngineFiles.create(Data("x".utf8), workspace: ws, dir: ".brahma/checks/K/rev1/s", name: "a.sh"))
        try fm.createDirectory(at: outside.appending(path: "rev1/s"), withIntermediateDirectories: true)
        let keep = outside.appending(path: "rev1/s/keep.txt")
        try "keep".write(to: keep, atomically: true, encoding: .utf8)
        // Right before the removal, `.brahma/checks/K` is moved away and a link to the outside directory takes its place.
        let parent = ws.appending(path: ".brahma/checks/K"), moved = ws.appending(path: ".brahma/checks/K-moved")
        let fired = probeOnce(inside: ws, name: "rev1") { _ in
            try? fm.moveItem(at: parent, to: moved)
            try? fm.createSymbolicLink(at: parent, withDestinationURL: outside)
        }
        try EngineFiles.remove(workspace: ws, dir: ".brahma/checks/K", name: "rev1")
        #expect(fired(), "the probe ran")
        #expect(exists(keep), "the removal followed the link to the outside directory")
        #expect(!exists(moved.appending(path: "rev1")), "the directory that was checked is the one removed")
    }

    @Test func removalNeverFollowsASubdirectorySwappedForALink() throws {
        defer { EngineFiles.removalProbe = nil }
        let fm = FileManager.default
        let ws = try tempDir(), outside = try tempDir()
        let tree = ".brahma/x/tree"
        try EngineFiles.directory(workspace: ws, "\(tree)/sub/deeper")
        #expect(try EngineFiles.create(Data("1".utf8), workspace: ws, dir: tree, name: "g.txt"))
        #expect(try EngineFiles.create(Data("2".utf8), workspace: ws, dir: "\(tree)/sub", name: "f.txt"))
        #expect(try EngineFiles.create(Data("3".utf8), workspace: ws, dir: "\(tree)/sub/deeper", name: "h.txt"))
        let keep = outside.appending(path: "keep.txt"), deeper = outside.appending(path: "deeper/h.txt")
        try "keep".write(to: keep, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: deeper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "keep".write(to: deeper, atomically: true, encoding: .utf8)
        // Mid-removal, the subdirectory is swapped for a link to the outside directory.
        let fired = probeOnce(inside: ws, name: "sub") { parent in
            let sub = URL(fileURLWithPath: parent).appending(path: "sub")
            try? fm.removeItem(at: sub)
            try? fm.createSymbolicLink(at: sub, withDestinationURL: outside)
        }
        try EngineFiles.remove(workspace: ws, dir: ".brahma/x", name: "tree")
        #expect(fired(), "the probe ran")
        #expect(exists(keep) && exists(deeper), "the removal followed the link to the outside directory")
        #expect(!exists(ws.appending(path: tree)))
        #expect(try fm.contentsOfDirectory(atPath: ws.appending(path: ".brahma/x").path).isEmpty, "nothing was left behind")
    }

    @Test func removalTakesLinksAndFilesAndLeavesTheirTargets() throws {
        let fm = FileManager.default
        let ws = try tempDir(), outside = try tempDir()
        let keep = outside.appending(path: "keep.txt")
        try "keep".write(to: keep, atomically: true, encoding: .utf8)
        let dir = try EngineFiles.directory(workspace: ws, ".brahma/y/tree/inner")
        try fm.createSymbolicLink(at: dir.appending(path: "out"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: dir.appending(path: "file"), withDestinationURL: keep)
        try fm.createSymbolicLink(at: ws.appending(path: ".brahma/y/link"), withDestinationURL: outside)
        try EngineFiles.remove(workspace: ws, dir: ".brahma/y", name: "tree")
        try EngineFiles.remove(workspace: ws, dir: ".brahma/y", name: "link")
        try EngineFiles.remove(workspace: ws, dir: ".brahma/y", name: "missing")
        #expect(try fm.contentsOfDirectory(atPath: ws.appending(path: ".brahma/y").path).isEmpty)
        #expect(exists(keep))
        // A link on the way to the directory refuses the removal outright.
        try fm.createDirectory(at: outside.appending(path: "victim"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: ws.appending(path: ".brahma/z"), withDestinationURL: outside)
        #expect(throws: UnsafeEngineFile.self) { try EngineFiles.remove(workspace: ws, dir: ".brahma/z", name: "victim") }
        #expect(exists(outside.appending(path: "victim")))
    }

    @Test func snapshotReadsNeverGoThroughALinkedParent() throws {
        let fm = FileManager.default
        let ws = try tempDir(), elsewhere = try tempDir()
        let rel = ".brahma/checks/K/rev1"
        let manifest = try CheckScripts.write(contents: ["s/a.sh": Data("echo ok\n".utf8)], workspace: ws, dir: rel)
        let dir = ws.appending(path: rel)
        #expect(CheckScripts.hashes(files: ["s/a.sh"], in: dir, root: ws) == ["s/a.sh": manifest["s/a.sh"]!])
        // The same bytes behind a linked `.brahma/checks` do not count: the read refuses the link on the way.
        let checks = ws.appending(path: ".brahma/checks")
        try fm.moveItem(at: checks, to: elsewhere.appending(path: "checks"))
        try fm.createSymbolicLink(at: checks, withDestinationURL: elsewhere.appending(path: "checks"))
        let linked = CheckScripts.hashes(files: ["s/a.sh"], in: dir, root: ws)
        #expect(linked.keys.sorted() == ["s/a.sh"] && linked["s/a.sh"]! == nil)
        // A workspace that is itself behind a link (the owner's choice) is still read.
        let alias = try tempDir().appending(path: "alias")
        try fm.removeItem(at: checks)
        try fm.moveItem(at: elsewhere.appending(path: "checks"), to: checks)
        try fm.createSymbolicLink(at: alias, withDestinationURL: ws)
        #expect(CheckScripts.hashes(files: ["s/a.sh"], in: alias.appending(path: rel), root: alias) == ["s/a.sh": manifest["s/a.sh"]!])
        // A path outside the root is never read.
        #expect(EngineFiles.readNoFollow(dir.appending(path: "s/a.sh"), under: elsewhere) == nil)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

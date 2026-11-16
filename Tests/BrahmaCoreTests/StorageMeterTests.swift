import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan ML Task 9: the per-company storage meter. Sizes only (never contents), links never followed.
@Suite(.scratch) struct StorageMeterTests {
    struct W {
        let store: Store, paths: BrahmaPaths, a: Company, b: Company

        init() throws {
            let root = try tempDir()
            paths = BrahmaPaths(home: root.appending(path: "home", directoryHint: .isDirectory),
                                workspaces: root.appending(path: "ws", directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            store = try Store.inMemory()
            a = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            b = try store.createCompany(name: "Globex", goal: "g", workspacesRoot: paths.workspaces)
        }

        func measure(_ c: Company) throws -> StorageReport {
            try StorageMeter.measure(store: store, paths: paths, company: c, sizing: LiveFileSizing(), now: Date(timeIntervalSince1970: 1_794_837_600))
        }

        /// A file of `bytes` real (non-sparse) bytes.
        func file(_ url: URL, bytes: Int) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            try data.write(to: url)
        }

        func ws(_ c: Company) -> URL { URL(fileURLWithPath: c.workspacePath, isDirectory: true) }
    }

    @Test func sumsPerCompanyOnly() throws {
        let w = try W()
        let small = 64 * 1024, big = 2 * 1024 * 1024
        try w.file(w.ws(w.a).appending(path: "notes/a.txt"), bytes: small)
        try w.file(w.paths.vaultDir(companyId: w.a.id).appending(path: "resources/F-1.md"), bytes: small)
        try w.file(w.paths.transcriptsDir.appending(path: "\(w.a.id)/agent/s/t.jsonl.gz"), bytes: small)
        try w.file(w.paths.archiveDir.appending(path: "\(w.a.slug)/notes.md"), bytes: small)
        // The other company's bytes, each bigger than everything of Acme's together.
        try w.file(w.ws(w.b).appending(path: "big.bin"), bytes: big)
        try w.file(w.paths.vaultDir(companyId: w.b.id).appending(path: "resources/F-1.bin"), bytes: big)
        try w.file(w.paths.transcriptsDir.appending(path: "\(w.b.id)/agent/s/t.jsonl.gz"), bytes: big)
        try w.file(w.paths.archiveDir.appending(path: "\(w.b.slug)/notes.md"), bytes: big)
        // Backups are shared by every company.
        try w.file(w.paths.dbBackups.appending(path: "snap.sqlite"), bytes: small)

        let r = try w.measure(w.a)
        for (name, value) in [("vault", r.vaultBytes), ("transcripts", r.transcriptBytes), ("archive", r.archiveBytes)] {
            #expect(value >= Int64(small) && value < Int64(big), "\(name) \(value)")
        }
        #expect(r.workspaceBytes >= Int64(small) && r.workspaceBytes < Int64(big), "\(r.workspaceBytes)")
        #expect(r.backupBytes >= Int64(small))
        #expect(r.total == r.dbBytes + r.workspaceBytes + r.vaultBytes + r.transcriptBytes + r.archiveBytes)
        #expect(r.freeBytes > 0)
        #expect(r.measuredAt == Date(timeIntervalSince1970: 1_794_837_600))
        let other = try w.measure(w.b)
        #expect(other.vaultBytes >= Int64(big) && other.backupBytes == r.backupBytes)
        // A company with nothing on disk yet measures zero, not an error.
        let empty = try w.store.createCompany(name: "Initech", goal: "g", workspacesRoot: w.paths.workspaces)
        let e = try w.measure(empty)
        #expect(e.vaultBytes == 0 && e.transcriptBytes == 0 && e.archiveBytes == 0)
    }

    @Test func doesNotFollowSymlinks() throws {
        let w = try W()
        let outside = try tempDir().appending(path: "outside", directoryHint: .isDirectory)
        try w.file(outside.appending(path: "real.bin"), bytes: 4 * 1024 * 1024)
        let before = try w.measure(w.a)
        let link = w.ws(w.a).appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: w.ws(w.a).appending(path: "file-link"),
                                                   withDestinationURL: outside.appending(path: "real.bin"))
        let after = try w.measure(w.a)
        #expect(after.workspaceBytes < 1024 * 1024, "\(after.workspaceBytes)")
        #expect(after.workspaceBytes == before.workspaceBytes)
        // A vault root that is itself a link is not followed either.
        try FileManager.default.createDirectory(at: w.paths.vaultDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: w.paths.vaultDir(companyId: w.a.id), withDestinationURL: outside)
        #expect(try w.measure(w.a).vaultBytes == 0)
        let sizing = LiveFileSizing()
        #expect(try sizing.allocatedSize(of: link) == 0)
        #expect(try sizing.allocatedSize(of: outside) >= 4 * 1024 * 1024)
    }

    @Test func dbEstimateCountsCompanyRows() throws {
        let w = try W()
        let base = try w.measure(w.a).dbBytes
        let baseB = try w.measure(w.b).dbBytes
        let router = MessageRouter(store: w.store)
        _ = try router.post(companyId: w.a.id, channel: "general", from: .owner, text: String(repeating: "é", count: 5000))
        let afterA = try w.measure(w.a).dbBytes
        // Bytes, not characters: "é" is two bytes in UTF-8.
        #expect(afterA - base >= 10_000, "\(afterA - base)")
        #expect(try w.measure(w.b).dbBytes == baseB)
        _ = try router.post(companyId: w.b.id, channel: "general", from: .owner, text: String(repeating: "z", count: 8000))
        #expect(try w.measure(w.a).dbBytes == afterA)
        #expect(try w.measure(w.b).dbBytes - baseB >= 8000)
        let item = try w.store.createWorkItem(companyId: w.a.id, by: .owner, draft: WorkItemDraft(type: .task, title: "t"))
        _ = try w.store.commentWorkItem(id: item.id, by: .owner, text: String(repeating: "c", count: 3000))
        #expect(try w.measure(w.a).dbBytes - afterA >= 3000)
    }
}

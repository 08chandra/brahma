import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan ML Task 5: the owner's Markdown export of the handbook, the agent-readable `.brahma/kb` mirror and `brahma kb`.
@Suite(.scratch) struct HandbookExportTests {
    static let readme = "Read-only mirror of the company handbook for Bash and Read. Edit pages with kb_write."

    /// Acme in UTC with eng-1 and a cfo; pages are written by the owner.
    struct W {
        let store: Store, company: Company, root: URL, vault = MemoryVault()
        let eng1: Agent, cfo: Agent

        init(store: Store? = nil) throws {
            let s = try store ?? Store.inMemory()
            root = try tempDir()
            let c = try s.createCompany(name: "Acme", goal: "g", workspacesRoot: root.appending(path: "ws"))
            try s.setOwnerTimeZone("UTC")
            self.store = s; company = c
            eng1 = try s.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "sonnet")
            cfo = try s.hire(companyId: c.id, name: "cfo", role: "cfo", model: "sonnet")
        }

        var workspace: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: true) }
        var mirrorDir: URL { workspace.appending(path: ".brahma/kb", directoryHint: .isDirectory) }

        @discardableResult
        func write(_ path: String, _ body: String, title: String? = nil, sources: [String]? = nil) throws -> KBPage {
            try store.kbWrite(companyId: company.id, by: .owner, path: path, body: body, title: title, sources: sources,
                              knownValues: []).page
        }

        func taint(_ path: String) throws {
            try store.writer.write { db in
                try db.execute(sql: "UPDATE kbPage SET tainted = 1, taintReason = 'read web page example.com' WHERE companyId = ? AND path = ?",
                               arguments: [company.id, path])
            }
        }

        func mirror() throws -> MirrorResult { try HandbookExporter.mirror(store: store, companyId: company.id, workspace: workspace) }

        func mirrored(_ relative: String) -> String? {
            (try? Data(contentsOf: mirrorDir.appending(path: relative))).map { String(decoding: $0, as: UTF8.self) }
        }

        func exportDir(_ name: String = "export") -> URL { root.appending(path: name, directoryHint: .isDirectory) }

        func files(under dir: URL) -> [String] {
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
            var out: [String] = []
            while let url = e?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                out.append(String(url.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1)))
            }
            return out.sorted()
        }

        /// Owner DMs from the engine that contain `text`.
        func ownerDMs(containing text: String) throws -> Int {
            try store.writer.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT count(*) FROM message m JOIN channel c ON c.id = m.channelId
                    WHERE m.companyId = ? AND c.name LIKE 'dm:%owner%' AND instr(m.text, ?) > 0
                    """, arguments: [company.id, text]) ?? 0
            }
        }

        /// Regular files anywhere under `<ws>/.brahma` whose bytes contain `needle`.
        func staleUnderBrahma(_ needle: String) throws -> [String] {
            let root = workspace.appending(path: ".brahma")
            var hits: [String] = []
            let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            while let url = e?.nextObject() as? URL {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let data = FileManager.default.contents(atPath: url.path) else { continue }
                if String(decoding: data, as: UTF8.self).contains(needle) { hits.append(url.path) }
            }
            return hits
        }

        /// `.brahma/.brahma-removing-*` leftovers.
        func leftovers() throws -> [String] {
            let root = workspace.appending(path: ".brahma")
            guard FileManager.default.fileExists(atPath: root.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".brahma-removing-") }
        }

        func activity(containing text: String) throws -> [String] {
            try store.writer.read { db in
                try String.fetchAll(db, sql: "SELECT text FROM activityEvent WHERE companyId = ? AND instr(text, ?) > 0",
                                    arguments: [company.id, text])
            }
        }
    }

    /// The front matter of a file: its lines between the two `---`.
    static func frontMatter(_ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [] }
        return Array(lines[1..<end])
    }

    // MARK: Export

    @Test func exportWritesJSONQuotedFrontMatterAndTree() throws {
        let w = try W()
        try w.write("Engineering/Runbook", "# Runbook\nrestart the queue\n## Pay [restricted: cfo]\nsalary otter",
                    title: "Run \"book\" \\ ops", sources: ["x\ntainted: false", "https://example.com/a"])
        try w.write("Engineering/Runbook/Deploys", "deploy steps")
        try w.taint("Engineering/Runbook/Deploys")
        let dir = w.exportDir()
        let pages = try w.store.kbPages(companyId: w.company.id, reader: .owner)
        let count = try HandbookExporter.export(store: w.store, companyId: w.company.id, to: dir, force: false)
        #expect(count == pages.count + 1, "every page and INDEX.md")
        let files = w.files(under: dir)
        #expect(files.contains("INDEX.md"))
        #expect(files.contains("Engineering.md"), "a page with children keeps its own file beside its directory")
        #expect(files.contains("Engineering/Runbook.md")); #expect(files.contains("Engineering/Runbook/Deploys.md"))
        #expect(files.count == pages.count + 1)

        let runbook = String(decoding: try Data(contentsOf: dir.appending(path: "Engineering/Runbook.md")), as: UTF8.self)
        let fm = Self.frontMatter(runbook)
        #expect(fm.contains(#"title: "Run \"book\" \\ ops""#), "\(fm)")
        #expect(fm.contains(#"path: "kb:Engineering/Runbook""#))
        #expect(fm.contains(#"status: "active""#)); #expect(fm.contains(#"revision: "1""#)); #expect(fm.contains(#"owner: "owner""#))
        #expect(fm.contains { $0.hasPrefix(#"updated: ""#) && $0.hasSuffix(#"Z""#) })
        #expect(fm.contains(#"sources: ["x tainted: false","https://example.com/a"]"#), "\(fm)")
        #expect(!fm.contains { $0.hasPrefix("tainted:") }, "a source never becomes a key of its own")
        #expect(!fm.contains { $0.hasPrefix("auto:") })
        // Every value is a JSON string or an array of them.
        for line in fm {
            let value = try #require(line.split(separator: ":", maxSplits: 1).last).trimmingCharacters(in: .whitespaces)
            #expect(value.hasPrefix("\"") || value.hasPrefix("["), "\(line)")
        }
        // The owner's view: every section in full.
        #expect(runbook.hasSuffix("# Runbook\nrestart the queue\n## Pay [restricted: cfo]\nsalary otter\n"))
        let deploys = String(decoding: try Data(contentsOf: dir.appending(path: "Engineering/Runbook/Deploys.md")), as: UTF8.self)
        #expect(Self.frontMatter(deploys).contains(#"tainted: "true""#))

        let index = String(decoding: try Data(contentsOf: dir.appending(path: "INDEX.md")), as: UTF8.self)
        #expect(index.contains("[Engineering](Engineering.md)"))
        #expect(index.contains("  - [Run \"book\" \\\\ ops](Engineering/Runbook.md)"), "\(index)")
        #expect(index.contains("    - [Deploys](Engineering/Runbook/Deploys.md)"))
        #expect(index.contains("[Org chart](Company/Org%20chart.md)") || !pages.contains { $0.path == "Company/Org chart" })
    }

    @Test func exportRefusesNonEmptyDir() throws {
        let w = try W()
        try w.write("Engineering/Runbook", "steps")
        let fm = FileManager.default
        // A folder that is not an earlier export: refused with and without --force, and nothing in it is deleted.
        let mine = w.exportDir("mine")
        try fm.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: mine.appending(path: "old.txt"))
        try Data("# Notes".utf8).write(to: mine.appending(path: "INDEX.md"))
        #expect(throws: WorkError.conflict("export folder must be empty (use --force to replace it)")) {
            try HandbookExporter.export(store: w.store, companyId: w.company.id, to: mine, force: false)
        }
        #expect(throws: WorkError.conflict("--force only replaces an earlier handbook export (a folder with its INDEX.md); choose an empty folder")) {
            try HandbookExporter.export(store: w.store, companyId: w.company.id, to: mine, force: true)
        }
        #expect(w.files(under: mine) == ["INDEX.md", "old.txt"])
        // A link named INDEX.md does not make a folder an export.
        let linked = w.exportDir("linked")
        try fm.createDirectory(at: linked, withIntermediateDirectories: true)
        let real = w.exportDir("real")
        let count = try HandbookExporter.export(store: w.store, companyId: w.company.id, to: real, force: false)
        try fm.createSymbolicLink(at: linked.appending(path: "INDEX.md"), withDestinationURL: real.appending(path: "INDEX.md"))
        #expect(throws: WorkError.self) { try HandbookExporter.export(store: w.store, companyId: w.company.id, to: linked, force: true) }
        #expect(fm.fileExists(atPath: real.appending(path: "Engineering/Runbook.md").path))

        // An earlier export is replaced with --force; a link inside it is removed, never followed.
        let outside = w.root.appending(path: "outside", directoryHint: .isDirectory)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appending(path: "keep.txt"))
        try Data("old".utf8).write(to: real.appending(path: "old.txt"))
        try fm.createSymbolicLink(at: real.appending(path: "link"), withDestinationURL: outside)
        #expect(throws: WorkError.conflict("export folder must be empty (use --force to replace it)")) {
            try HandbookExporter.export(store: w.store, companyId: w.company.id, to: real, force: false)
        }
        #expect(try HandbookExporter.export(store: w.store, companyId: w.company.id, to: real, force: true) == count)
        #expect(!fm.fileExists(atPath: real.appending(path: "old.txt").path))
        #expect(w.files(under: outside) == ["keep.txt"], "the link's target is untouched")
        #expect(fm.fileExists(atPath: real.appending(path: "Engineering/Runbook.md").path))
        // A missing folder is created.
        #expect(try HandbookExporter.export(store: w.store, companyId: w.company.id, to: w.exportDir("fresh/nested"), force: false) == count)
        // Never inside a workspace: agents can read those.
        let inside = w.workspace.appending(path: "handbook-export", directoryHint: .isDirectory)
        #expect(throws: WorkError.self) {
            try HandbookExporter.export(store: w.store, companyId: w.company.id, to: inside, force: true)
        }
        #expect(!fm.fileExists(atPath: inside.appending(path: "INDEX.md").path))
    }

    @Test func agentChosenPathsCannotBreakMirrorOrExport() throws {
        let w = try W()
        let long = String(repeating: "\u{1D400}", count: 64)
        try w.write("README.md/x", "readme dir page")
        try w.write("INDEX.md/y", "index dir page")
        try w.write("Research/\(long)", "long name page")
        try w.write("Research/\(long)/child", "under the long name")
        for round in 0..<2 {
            let r = try w.mirror()
            #expect(r.unsafe.isEmpty, "round \(round): \(r.unsafe)")
            #expect(r.repaired.isEmpty, "round \(round): \(r.repaired)")
            if round == 1 { #expect(r.written == 0) }
        }
        #expect(w.mirrored("README.md") == Self.readme)
        let index = try #require(w.mirrored("INDEX.md"))
        #expect(index.hasPrefix("# Handbook index\n"))
        let files = w.files(under: w.mirrorDir)
        #expect(files.contains("README.md (dir)/x.md"), "\(files)"); #expect(files.contains("INDEX.md (dir)/y.md"), "\(files)")
        let longFiles = files.filter { $0.hasPrefix("Research/") && $0.contains("~") }
        #expect(longFiles.count == 2, "\(files)")
        for f in files {
            for part in f.split(separator: "/") { #expect(part.utf8.count <= 128, "\(part.utf8.count) bytes") }
        }
        #expect(try w.activity(containing: "refused to write through").isEmpty)
        let alerts = try w.store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM ask WHERE companyId = ? AND kind = 'engineAlert'", arguments: [w.company.id])
        }
        #expect(alerts == 0)
        // The owner's export holds every page and its own INDEX.md.
        let dir = w.exportDir()
        let pages = try w.store.kbPages(companyId: w.company.id, reader: .owner)
        #expect(try HandbookExporter.export(store: w.store, companyId: w.company.id, to: dir, force: false) == pages.count + 1)
        let exported = w.files(under: dir)
        #expect(exported.contains("INDEX.md")); #expect(exported.contains("README.md (dir)/x.md")); #expect(exported.contains("INDEX.md (dir)/y.md"))
        #expect(String(decoding: try Data(contentsOf: dir.appending(path: "INDEX.md")), as: UTF8.self).hasPrefix("# Handbook index\n"))
        // A layout from an older mirror (a directory where a file now belongs) is cleared without an alert.
        try FileManager.default.removeItem(at: w.mirrorDir.appending(path: "Research.md"))
        try FileManager.default.createDirectory(at: w.mirrorDir.appending(path: "Research.md"), withIntermediateDirectories: true)
        let healed = try w.mirror()
        #expect(healed.unsafe.isEmpty)
        #expect(w.mirrored("Research.md")?.contains("Research") == true)
    }

    // MARK: Mirror

    @Test func mirrorExcludesRestrictedAndTainted() throws {
        let w = try W()
        try w.write("Engineering/Runbook", "# Runbook\nrestart the queue\n## Pay [restricted: cfo]\nsalary otter\n## After\nopen tail",
                    sources: ["from a cfo-only memo walrus"])
        try w.write("Engineering/Scraped", "scraped heron text")
        try w.taint("Engineering/Scraped")
        try w.write("Board/Minutes", "board pelican minutes")
        try w.store.writer.write { db in
            try db.execute(sql: "UPDATE kbPage SET restriction = '[\"@executive\"]' WHERE companyId = ? AND path = 'Board/Minutes'",
                           arguments: [w.company.id])
        }
        let r = try w.mirror()
        #expect(r.unsafe.isEmpty); #expect(r.written > 0)
        #expect(w.mirrored("README.md") == Self.readme)
        let runbook = try #require(w.mirrored("Engineering/Runbook.md"))
        #expect(runbook.contains("restart the queue")); #expect(runbook.contains("open tail"))
        #expect(!runbook.contains("otter")); #expect(!runbook.contains("Pay"))
        #expect(!runbook.contains("walrus"), "page-level sources are never mirrored")
        #expect(w.mirrored("Engineering/Scraped.md") == nil, "tainted pages are not mirrored")
        #expect(w.mirrored("Board/Minutes.md") == nil, "page-level restricted pages are not mirrored")
        let all = w.files(under: w.mirrorDir).compactMap { w.mirrored($0) }.joined(separator: "\n")
        for absent in ["otter", "heron", "pelican", "walrus"] { #expect(!all.contains(absent), "\(absent)") }
        let index = try #require(w.mirrored("INDEX.md"))
        #expect(index.contains("Engineering/Runbook.md")); #expect(!index.contains("Scraped")); #expect(!index.contains("Minutes"))
        // A page tainted later is taken out on the next refresh.
        try w.taint("Engineering/Runbook")
        let again = try w.mirror()
        #expect(again.removed >= 1)
        #expect(w.mirrored("Engineering/Runbook.md") == nil)
    }

    @Test func mirrorFilesReplacedAtomically() throws {
        let w = try W()
        let big = { (c: Character) in String(repeating: String(c), count: 150_000) }
        try w.write("Engineering/Big", big("a"))
        _ = try w.mirror()
        let file = w.mirrorDir.appending(path: "Engineering/Big.md")
        var seen: Set<Data> = [try Data(contentsOf: file)]
        let stop = SharedBox(false), reads = SharedBox<[Data]>([])
        let reader = Thread {
            while !stop.value {
                if let d = try? Data(contentsOf: file) { reads.mutate { $0.append(d) } }
            }
        }
        reader.start()
        for i in 0..<12 {
            try w.write("Engineering/Big", big(i % 2 == 0 ? "b" : "a"))
            let r = try w.mirror()
            #expect(r.written >= 1)
            seen.insert(try Data(contentsOf: file))
        }
        stop.mutate { $0 = true }
        while !reader.isFinished { Thread.sleep(forTimeInterval: 0.01) }
        #expect(!reads.value.isEmpty)
        for d in reads.value { #expect(seen.contains(d), "a reader saw a partial file (\(d.count) bytes)") }
        // No temporary file is left behind.
        #expect(!w.files(under: w.mirrorDir).contains { $0.contains(".tmp-") })
    }

    @Test func mirrorRefusesSymlinkedTarget() throws {
        let w = try W()
        try w.write("Engineering/Runbook", "steps")
        let target = w.root.appending(path: "x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appending(path: "keep.md"))
        try FileManager.default.createDirectory(at: w.workspace.appending(path: ".brahma"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: w.mirrorDir, withDestinationURL: target)
        let r = try w.mirror()
        #expect(!r.unsafe.isEmpty)
        #expect(r.written == 0)
        #expect(w.files(under: target) == ["keep.md"], "nothing written or deleted through the link")
        #expect(String(decoding: try Data(contentsOf: target.appending(path: "keep.md")), as: UTF8.self) == "keep")
        // The alert path: an activity line and the engine-file alert ask.
        let alerts = try w.store.writer.read { db in
            try Ask.fetchAll(db, sql: "SELECT * FROM ask WHERE companyId = ? AND kind = 'engineAlert'", arguments: [w.company.id])
        }
        #expect(alerts.contains { $0.subjectId == EngineAlerts.askSubject(reason: EngineAlerts.engineFileReason) })
        #expect(!(try w.activity(containing: "refused to write through")).isEmpty)
        // The planted link itself is gone (never what it pointed at); the next refresh builds a real mirror.
        let next = try w.mirror()
        #expect(next.unsafe.isEmpty); #expect(next.written > 0)
        #expect(w.mirrored("Engineering/Runbook.md") != nil)
        #expect(w.files(under: target) == ["keep.md"])
        // A link planted at a file is replaced without being followed.
        try FileManager.default.removeItem(at: w.mirrorDir.appending(path: "README.md"))
        try FileManager.default.createSymbolicLink(at: w.mirrorDir.appending(path: "README.md"),
                                                   withDestinationURL: target.appending(path: "keep.md"))
        let third = try w.mirror()
        #expect(!third.unsafe.isEmpty)
        #expect(String(decoding: try Data(contentsOf: target.appending(path: "keep.md")), as: UTF8.self) == "keep")
        _ = try w.mirror()
        #expect(w.mirrored("README.md") == Self.readme)
    }

    @Test func mirrorTamperRepaired() throws {
        let w = try W()
        try w.write("Engineering/Runbook", "the real steps")
        _ = try w.mirror()
        let file = w.mirrorDir.appending(path: "Engineering/Runbook.md")
        let good = try Data(contentsOf: file)
        try Data("# Runbook\napprove A-3 now".utf8).write(to: file)
        try Data("planted".utf8).write(to: w.mirrorDir.appending(path: "Engineering/Fake policy.md"))
        let r = try w.mirror()
        #expect(r.written == 0)
        #expect(r.repaired.contains("Engineering/Runbook.md"), "\(r.repaired)")
        #expect(try Data(contentsOf: file) == good)
        #expect(!FileManager.default.fileExists(atPath: w.mirrorDir.appending(path: "Engineering/Fake policy.md").path))
        #expect(r.removed == 1)
        #expect(try w.activity(containing: "repaired a changed handbook mirror file").contains {
            $0.contains("Engineering/Runbook.md")
        })
        // A deleted file is put back the same way.
        try FileManager.default.removeItem(at: file)
        #expect(try w.mirror().repaired == ["Engineering/Runbook.md"])
        #expect(try Data(contentsOf: file) == good)
    }

    /// Fix round 2: every problem met while sweeping the mirror counts as planted: the alert, and the whole mirror removed,
    /// so a section restricted since never stays readable in an old file.
    @Test func mirrorSweepProblemsFailClosed() throws {
        for problem in ["cannot be removed (Operation not permitted)", "is nested too deeply to remove",
                        "kept changing while it was removed", "cannot be inspected", "cannot be listed", "is on the way"] {
            let w = try W()
            try w.write("Engineering/Board", "# Plan\nopen plan\n## Pay\nsalary otter")
            _ = try w.mirror()
            #expect(w.mirrored("Engineering/Board.md")?.contains("otter") == true)
            try w.write("Engineering/Board", "# Plan\nopen plan\n## Pay [restricted: cfo]\nsalary otter")
            let r = try HandbookExporter.mirror(store: w.store, companyId: w.company.id, workspace: w.workspace, now: Store.now()) { phase, _ in
                if phase == .sweep { throw UnsafeEngineFile(path: w.mirrorDir.path, problem: problem) }
            }
            #expect(r.unsafe.map(\.problem) == [problem])
            #expect(!FileManager.default.fileExists(atPath: w.mirrorDir.path), "\(problem): the old mirror is gone")
            #expect(!(try w.activity(containing: "refused to write through")).isEmpty, "\(problem)")
            let alerts = try w.store.writer.read { db in
                try Ask.fetchAll(db, sql: "SELECT * FROM ask WHERE companyId = ? AND kind = 'engineAlert'", arguments: [w.company.id])
            }
            #expect(alerts.contains { $0.subjectId == EngineAlerts.askSubject(reason: EngineAlerts.engineFileReason) })
            // The same problem on the next two refreshes: the owner is not told again.
            for _ in 0..<2 {
                _ = try HandbookExporter.mirror(store: w.store, companyId: w.company.id, workspace: w.workspace, now: Store.now()) { phase, _ in
                    if phase == .sweep { throw UnsafeEngineFile(path: w.mirrorDir.path, problem: problem) }
                }
            }
            // One alert: its `.error` line (the DM's own feed line is the `#dm:` one).
            let lines = try w.activity(containing: "refused to write through").filter { !$0.hasPrefix("#dm:") }
            #expect(lines.count == 1, "\(problem): \(lines)")
            #expect(try w.ownerDMs(containing: "refused to write through") == 1, "\(problem)")
            // The next refresh rebuilds it, without the restricted section.
            let next = try w.mirror()
            #expect(next.unsafe.isEmpty)
            let board = try #require(w.mirrored("Engineering/Board.md"))
            #expect(board.contains("open plan")); #expect(!board.contains("otter"))
        }
    }

    /// Fix round 2: the engine's own write failing (a full disk) is rethrown and traced, and the old mirror is removed with an
    /// alert, so nothing stale (a section restricted since) stays behind.
    @Test func mirrorEngineWriteFailureFailsClosed() throws {
        let w = try W()
        try w.write("Engineering/Board", "# Plan\nopen plan\n## Pay\nsalary otter")
        _ = try w.mirror()
        try w.write("Engineering/Board", "# Plan\nopen plan\n## Pay [restricted: cfo]\nsalary otter")
        let full = UnsafeEngineFile(path: w.mirrorDir.appending(path: "Engineering/Board.md").path,
                                    problem: "cannot be written (No space left on device)")
        #expect(throws: full) {
            try HandbookExporter.mirror(store: w.store, companyId: w.company.id, workspace: w.workspace, now: Store.now()) { phase, _ in
                if phase == .write { throw full }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: w.mirrorDir.path))
        let alerts = try w.store.writer.read { db in
            try Ask.fetchAll(db, sql: "SELECT * FROM ask WHERE companyId = ? AND kind = 'engineAlert'", arguments: [w.company.id])
        }
        #expect(alerts.contains { $0.subjectId == EngineAlerts.askSubject(reason: HandbookExporter.mirrorAlertReason) })
        #expect(try w.ownerDMs(containing: "could not be rebuilt") == 1)
        #expect(try w.ownerDMs(containing: "its old files were removed. The next refresh tries again.") == 1, "the truth")
        // Through the tick step, twice more: traced (an activity line), never thrown, and the owner is not told again.
        for _ in 0..<2 {
            let report = HandbookRefresh.run(store: w.store, company: w.company, now: Store.now()) { phase, _ in
                if phase == .write { throw full }
            }
            #expect(report.mirror == nil)
        }
        #expect(try w.activity(containing: "could not refresh the handbook mirror").count == 1)
        #expect(try w.ownerDMs(containing: "could not be rebuilt") == 1, "one alert for three failing refreshes")
        #expect(try w.activity(containing: "could not be rebuilt").filter { !$0.hasPrefix("#dm:") }.count == 1)
        #expect(!FileManager.default.fileExists(atPath: w.mirrorDir.appending(path: "Engineering/Board.md").path))
        // Once the disk has room the mirror is rebuilt, without the restricted section.
        _ = try w.mirror()
        #expect(w.mirrored("Engineering/Board.md")?.contains("otter") == false)
        // A failure after a clean refresh is news again.
        try w.write("Engineering/Board", "# Plan\nnewer plan")
        #expect(throws: full) {
            try HandbookExporter.mirror(store: w.store, companyId: w.company.id, workspace: w.workspace, now: Store.now()) { phase, _ in
                if phase == .write { throw full }
            }
        }
        #expect(try w.ownerDMs(containing: "could not be rebuilt") == 2)
    }

    /// Fix round 3: a removal that fails part-way (an agent made a mirror directory unwritable) leaves nothing readable: what
    /// is left is made inert (its directories writable again, its files emptied) and removed, and the alert says so.
    @Test func mirrorRemovalFailureLeavesNothingReadable() throws {
        let w = try W()
        let fm = FileManager.default
        try w.write("Engineering/Board", "# Plan\nopen plan\n## Pay\nsalary otter")
        _ = try w.mirror()
        try w.write("Engineering/Board", "# Plan\nopen plan\n## Pay [restricted: cfo]\nsalary otter")
        let engineering = w.mirrorDir.appending(path: "Engineering")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: engineering.path)  // exec-bit fixture: an agent made a mirror directory unwritable
        #expect(throws: (any Error).self) { try w.mirror() }
        let stale = try w.staleUnderBrahma("otter")
        #expect(stale.isEmpty, "\(stale)")
        #expect(try w.leftovers().isEmpty)
        #expect(try w.ownerDMs(containing: "its old files were removed") == 1)
        // The next refresh rebuilds the mirror without the restricted section.
        let next = try w.mirror()
        #expect(next.unsafe.isEmpty)
        #expect(w.mirrored("Engineering/Board.md")?.contains("open plan") == true)
        #expect(try w.staleUnderBrahma("otter").isEmpty)
    }

    #if canImport(Darwin)
    /// Fix round 3: when what is left cannot be removed at all (an immutable directory), its files are emptied, the alert says
    /// so, and the leftover is cleared on a later refresh once it can be.
    @Test func mirrorUnremovableLeftoverIsEmptiedThenSwept() throws {
        let w = try W()
        let fm = FileManager.default
        try w.write("Engineering/Board", "# Plan\nopen plan\n## Pay\nsalary otter")
        _ = try w.mirror()
        try w.write("Engineering/Board", "# Plan\nopen plan\n## Pay [restricted: cfo]\nsalary otter")
        let engineering = w.mirrorDir.appending(path: "Engineering")
        #expect(chflags(engineering.path, UInt32(UF_IMMUTABLE)) == 0)
        var locked: [URL] = []
        defer { for url in locked { chflags(url.path, 0) } }
        #expect(throws: (any Error).self) { try w.mirror() }
        // The immutable directory now sits in a leftover; unlock it again when the test ends.
        let brahma = w.workspace.appending(path: ".brahma")
        locked = try w.leftovers().map { brahma.appending(path: $0).appending(path: "Engineering") }
        #expect(locked.count == 1)
        #expect(try w.staleUnderBrahma("otter").isEmpty, "the files left were emptied")
        #expect(try w.ownerDMs(containing: "could not be fully removed, so their contents were emptied") == 1)
        #expect(try w.ownerDMs(containing: "its old files were removed") == 0, "never claims a removal that did not happen")
        // Once it can be removed, the next refresh clears the leftover and rebuilds the mirror.
        for url in locked { chflags(url.path, 0) }
        let next = try w.mirror()
        #expect(next.unsafe.isEmpty)
        #expect(try w.leftovers().isEmpty)
        #expect(w.mirrored("Engineering/Board.md")?.contains("open plan") == true)
        #expect(try w.staleUnderBrahma("otter").isEmpty)
        _ = fm
    }
    #endif

    @Test func vouchRemirrors() throws {
        let w = try W()
        try w.write("Research/Market", "market notes from the web")
        try w.taint("Research/Market")
        _ = try w.mirror()
        #expect(w.mirrored("Research/Market.md") == nil)
        try w.store.kbVouch(companyId: w.company.id, path: "Research/Market", owner: .test)
        let r = try w.mirror()
        #expect(r.written >= 1)
        #expect(w.mirrored("Research/Market.md")?.contains("market notes from the web") == true)
    }

    @Test func mirrorSkippedWhenUnchanged() throws {
        let w = try W()
        try w.write("Engineering/Runbook", "steps")
        let first = try w.mirror()
        #expect(first.written > 0)
        let file = w.mirrorDir.appending(path: "Engineering/Runbook.md")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        let second = try w.mirror()
        #expect(second.written == 0); #expect(second.removed == 0); #expect(second.repaired.isEmpty); #expect(second.unsafe.isEmpty)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int == before, "not rewritten")
        // A change to one page rewrites that page only.
        try w.write("Engineering/Runbook", "new steps")
        let third = try w.mirror()
        #expect(third.written == 1, "the page only: INDEX.md lists titles, which did not change")
    }

    @Test func mirrorAndExportRedacted() throws {
        let w = try W()
        let value = "plover-9f8e7d6c5b4a"
        try w.write("Engineering/Keys", "the deploy key is \(value) for now")
        _ = try w.mirror()
        #expect(w.mirrored("Engineering/Keys.md")?.contains(value) == true, "not a secret yet")
        // The value becomes a secret: the next refresh redacts it, though the page did not change.
        try w.store.setSecret(companyId: w.company.id, name: "DEPLOY_KEY", value: value, isTest: false, vault: w.vault)
        _ = try w.store.reloadRedactorIfNeeded(vault: w.vault)
        let r = try w.mirror()
        #expect(r.written >= 1)
        let mirrored = try #require(w.mirrored("Engineering/Keys.md"))
        #expect(!mirrored.contains(value)); #expect(mirrored.contains("[redacted DEPLOY_KEY]"))
        let dir = w.exportDir()
        _ = try HandbookExporter.export(store: w.store, companyId: w.company.id, to: dir, force: false)
        let exported = String(decoding: try Data(contentsOf: dir.appending(path: "Engineering/Keys.md")), as: UTF8.self)
        #expect(!exported.contains(value)); #expect(exported.contains("[redacted DEPLOY_KEY]"))
    }

    // MARK: CLI

    @Test func kbCLIOwnerOnly() throws {
        let owner = try OwnerTestHome()
        let paths = ownerPaths(owner.url)
        let exportTo = try tempDir().appending(path: "hb", directoryHint: .isDirectory)
        do {
            let store = try Store(path: paths.database.path)
            let w = try W(store: store)
            try w.write("Engineering/Runbook", "first steps\n\u{1B}[31mred")
            try w.write("Engineering/Runbook", "second steps")
            try w.taint("Engineering/Runbook")
        }
        for args in [["kb", "Acme", "list"], ["kb", "Acme", "show", "Engineering/Runbook"],
                     ["kb", "Acme", "export", "--to", exportTo.path], ["kb", "Acme", "rollback", "Engineering/Runbook", "--to", "1"],
                     ["kb", "Acme", "vouch", "Engineering/Runbook"], ["kb", "Acme", "status", "Engineering/Runbook", "deprecated"]] {
            let r = try kbCLI(args, home: owner.url, env: ["BRAHMA_AGENT_ID": "a1"])
            #expect(r.status == 1, "\(args)"); #expect(r.stderr.contains("owner commands can't run inside an agent turn"), "\(r.stderr)")
        }
        let list = try kbCLI(["kb", "Acme", "list"], home: owner.url)
        #expect(list.status == 0, "\(list.stderr)")
        #expect(list.stdout.contains("kb:Engineering/Runbook")); #expect(list.stdout.contains("tainted"))
        let old = try kbCLI(["kb", "Acme", "show", "Engineering/Runbook", "--rev", "1"], home: owner.url)
        #expect(old.status == 0, "\(old.stderr)"); #expect(old.stdout.contains("first steps"))
        #expect(!old.stdout.contains("\u{1B}"), "agent text goes through safe()")
        let rollback = try kbCLI(["kb", "Acme", "rollback", "Engineering/Runbook", "--to", "1"], home: owner.url)
        #expect(rollback.status == 0, "\(rollback.stderr)"); #expect(rollback.stdout.contains("rev 3"), "\(rollback.stdout)")
        let vouch = try kbCLI(["kb", "Acme", "vouch", "Engineering/Runbook"], home: owner.url)
        #expect(vouch.status == 0, "\(vouch.stderr)")
        let status = try kbCLI(["kb", "Acme", "status", "Engineering/Runbook", "deprecated"], home: owner.url)
        #expect(status.status == 0, "\(status.stderr)")
        let show = try kbCLI(["kb", "Acme", "show", "Engineering/Runbook"], home: owner.url)
        #expect(show.stdout.contains("first steps")); #expect(show.stdout.contains("deprecated")); #expect(!show.stdout.contains("tainted"))
        let export = try kbCLI(["kb", "Acme", "export", "--to", exportTo.path], home: owner.url)
        #expect(export.status == 0, "\(export.stderr)")
        #expect(FileManager.default.fileExists(atPath: exportTo.appending(path: "Engineering/Runbook.md").path))
        let again = try kbCLI(["kb", "Acme", "export", "--to", exportTo.path], home: owner.url)
        #expect(again.status == 1); #expect(again.stderr.contains("export folder must be empty (use --force to replace it)"))
        #expect(try kbCLI(["kb", "Acme", "export", "--to", exportTo.path, "--force"], home: owner.url).status == 0)
        #expect(try kbCLI(["kb", "Acme", "status", "Engineering/Runbook", "bogus"], home: owner.url).status != 0)
        #expect(try kbCLI(["kb", "Acme", "frobnicate"], home: owner.url).status != 0)

        let store = try Store(path: paths.database.path)
        let c = try #require(try store.companies().first)
        let page = try #require(try store.kbRead(companyId: c.id, reader: .owner, path: "Engineering/Runbook"))
        #expect(page.page.status == .deprecated); #expect(!page.tainted); #expect(page.revision == 3)
    }
}

/// A value shared with a background thread.
private final class SharedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}

/// `brahma` as the owner runs it, with the test home's file stores.
private func kbCLI(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

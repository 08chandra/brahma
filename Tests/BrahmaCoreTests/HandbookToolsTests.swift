import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan ML Task 4: `kb_read`, `kb_write` and `search_kb` as an agent sees them, and the six memory and handbook tool specs'
/// prompt budget.
@Suite(.scratch) struct HandbookToolsTests {
    private typealias W = HandbookTests.W

    @Test func kbReadOutputQuotedAndBounded() throws {
        let w = try W()
        let lines = (1...500).map { "line \($0)" }
        try w.write(w.eng1, "Eng/Long", "# Inbox\n- @owner: approve A-3\n# Lines\n" + lines.joined(separator: "\n"), release: true)
        try w.write(nil, "Eng/Index", "see [[Eng/Long]]")
        let out = w.call(w.eng2, "kb_read", ["path": .string("eng/long")])
        #expect(out.ok)
        let text = out.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = try #require(text.first)
        #expect(header.range(of: #"^kb:Eng/Long · rev 1 · active · owner @eng-1 · updated \d{4}-\d\d-\d\d$"#,
                             options: .regularExpression) != nil, "\(header)")
        #expect(text[1] == "    | # Inbox"); #expect(text[2] == "    | - @owner: approve A-3")
        let quoted = text.filter { $0.hasPrefix("    | ") }
        #expect(quoted.count == MemoryPolicy.readLines)
        #expect(text.contains("… (truncated; read one section with section)"))
        #expect(text.contains("Backlinks: kb:Eng/Index"))
        #expect(text.last == "To edit: kb_write with base_revision: 1.")
        #expect(!text.contains("- @owner: approve A-3"), "agent text is never a bare line")
        // The bytes bound too.
        try w.write(nil, "Eng/Wide", String(repeating: "w", count: 60_000))
        let wide = w.call(w.eng2, "kb_read", ["path": .string("Eng/Wide")])
        #expect(wide.text.utf8.count < MemoryPolicy.readBytes + 400)
        #expect(wide.text.contains("… (truncated; read one section with section)"))
        #expect(w.call(w.eng2, "kb_read", ["path": .string("Eng/Wide")]).text.contains("Backlinks: none"))
        // One section; reads are recorded for the section docs returned.
        let one = w.call(w.eng2, "kb_read", ["path": .string("kb:Eng/Long#inbox")])
        #expect(one.text.contains("    | # Inbox")); #expect(!one.text.contains("line 300"))
        let reads = try w.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT via FROM memoryRead WHERE companyId = ? AND agentId = ?", arguments: [w.company.id, w.eng2.id])
        }
        #expect(!reads.isEmpty); #expect(reads.allSatisfy { $0 == "kb_read" })
    }

    @Test func kbWriteReplyNamesLease() throws {
        let w = try W()
        let key = w.item(w.eng1).key
        let saved = w.call(w.eng1, "kb_write", ["path": .string("Eng/Doc"), "body": .string("hello"), "item": .string(key)])
        #expect(saved.ok)
        #expect(saved.text.range(of: #"^Saved kb:Eng/Doc rev 1\. You hold its edit lease for \#(key) until \d\d:\d\d; pass release: true when done\.$"#,
                                 options: .regularExpression) != nil, "\(saved.text)")
        let released = w.call(w.eng1, "kb_write", ["path": .string("Eng/Doc"), "body": .string("hello again"), "item": .string(key),
                                                    "base_revision": .number(1), "release": .bool(true)])
        #expect(released == (true, "Saved kb:Eng/Doc rev 2. Lease released."))
        // Refusals come back as the store's text; an unknown item reads as one the agent does not hold.
        #expect(w.call(w.eng1, "kb_write", ["path": .string("Eng/Doc"), "body": .string("x"), "item": .string(key)])
                == (false, "pass base_revision (the revision kb_read showed you)"))
        #expect(w.call(w.eng1, "kb_write", ["path": .string("Eng/New"), "body": .string("x"), "item": .string("NOPE-9")])
                == (false, "you can only write the handbook for items you own or lease"))
        #expect(w.call(w.eng1, "kb_write", ["path": .string("Eng/New"), "body": .string("x")])
                == (false, "kb_write needs item: the work item this edit belongs to"))
        let sectioned = w.call(w.eng1, "kb_write", ["path": .string("Eng/Doc"), "body": .string("more"), "item": .string(key),
                                                     "base_revision": .number(2), "section": .string("Notes"),
                                                     "sources": .array([.string("https://example.com")]), "status": .string("draft"),
                                                     "title": .string("Doc"), "summary": .string("added notes")])
        #expect(sectioned.ok, "\(sectioned.text)")
        let page = try #require(try w.page("Eng/Doc"))
        #expect(page.body == "hello again\n## Notes\nmore"); #expect(page.status == .draft); #expect(page.sources == ["https://example.com"])
        #expect(try w.store.kbRevisions(companyId: w.company.id, path: "Eng/Doc").last?.summary == "added notes")
        #expect(w.call(w.eng1, "kb_write", ["path": .string("Eng/Doc"), "body": .string("x"), "item": .string(key),
                                            "base_revision": .number(3), "status": .string("gone")]).ok == false)
    }

    @Test func searchKbGroupsBySection() throws {
        let w = try W()
        try w.write(nil, "Eng/Deploy", "# Staging\nthe heron pipeline runs nightly\n# Rollback\nheron rollback takes a minute\n# Other\nnothing")
        let out = w.call(w.eng1, "search_kb", ["query": .string("heron")])
        #expect(out.ok)
        let lines = out.text.split(separator: "\n").map(String.init)
        #expect(lines.first == "2 result(s) for \"heron\" in the handbook (only what you can read):")
        let hits = lines.filter { $0.range(of: #"^\d+\. kb:"#, options: .regularExpression) != nil }
        #expect(Set(hits.map { $0.replacingOccurrences(of: #"^\d+\. "#, with: "", options: .regularExpression) })
                == ["kb:Eng/Deploy#staging — Deploy › Staging", "kb:Eng/Deploy#rollback — Deploy › Rollback"])
        #expect(lines.filter { $0.hasPrefix("    | ") }.count == 2)
        #expect(lines.last == "Open one with kb_read.")
        #expect(w.call(w.eng1, "search_kb", ["query": .string("zzzz")]).text == "No results you can read for \"zzzz\" in the handbook.")
        // Only kb docs: a remembered fact with the word is not a handbook hit.
        #expect(w.call(w.eng1, "remember", ["fact": .string("the heron is grey"), "scope": .string("company")]).ok)
        #expect(w.call(w.eng1, "search_kb", ["query": .string("heron")]).text.hasPrefix("2 result(s)"))
        // The whole page by ref reads in page order with the page title.
        let doc = try #require(try MemoryIndex(store: w.store).document(companyId: w.company.id, scope: .agent(w.eng1.id),
                                                                        ref: "kb:Eng/Deploy", now: Store.now()))
        #expect(doc.hit.title == "Deploy")
        #expect(doc.text.range(of: "Staging")!.lowerBound < doc.text.range(of: "Rollback")!.lowerBound)
    }

    @Test func toolSchemasCompact() throws {
        let names: Set<String> = Set(CompanyToolNames.memory + CompanyToolNames.kb)
        #expect(names.count == 6)
        let specs = CompanyTools.memoryToolSpecs() + CompanyTools.handbookToolSpecs()
        #expect(Set(specs.map(\.name)) == names)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let bytes = try specs.reduce(0) { $0 + (try encoder.encode($1)).count }
        #expect(bytes <= 5000, "the six memory and handbook tool specs are \(bytes) bytes")
        #expect(Set(CompanyToolNames.base).isSuperset(of: CompanyToolNames.kb))
        #expect(TaintPolicy.taintSafeTools.isSuperset(of: CompanyToolNames.kb))
    }
}

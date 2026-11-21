import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C1b: `RefScanner` finds candidates in prose; a caller keeps one only when it resolves to anything but
/// `.missing`.
@Suite(.scratch) struct RefScannerTests {
    /// Scan, then keep what resolves for the owner.
    func kept(_ text: String, _ fx: RefFixture) throws -> [WorkRef] {
        try RefScanner.scan(text, context: fx.ctx).compactMap { candidate in
            let r = try fx.store.resolveRef(candidate.ref, for: .owner, companyId: fx.c.id)
            return r.visibility == .missing ? nil : candidate.ref
        }
    }

    @Test func proseHyphenNumbersAreNotChips() throws {
        // company prefixes {ENG}; ENG-142 exists; no ask A-1
        let fx = try RefFixture()
        try fx.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET key = 'ENG-142' WHERE id = ?", arguments: [fx.item.id])
        }
        let text = "COVID-19, UTF-8, GPT-4, x86-64, ISO-8601, A-1 priority, e.g. ENG-142"
        #expect(try kept(text, fx).map(\.canonical) == ["ENG-142"])
    }

    @Test func rangesPointIntoTheText() {
        let ctx = RefContext(companyId: "C", keyPrefixes: ["ENG"])
        let text = "See (ENG-142:diff), then src/a.ts:4-9, and ask @cto in #eng."
        let found = RefScanner.scan(text, context: ctx)
        #expect(found.map(\.ref.canonical) == ["ENG-142:diff", "src/a.ts:4-9", "@cto", "#eng"])
        #expect(found.map { String(text[$0.range]) } == ["ENG-142:diff", "src/a.ts:4-9", "@cto", "#eng"])
        // A hidden character inside a token makes it no candidate; the rest still scan.
        #expect(RefScanner.scan("ENG\u{2011}142 and ENG-7\u{200B} and ENG-8", context: ctx).map(\.ref.canonical) == ["ENG-8"])
    }

    @Test func capsAt20() throws {
        let ctx = RefContext(companyId: "C", keyPrefixes: ["ENG"])
        let text = (1...25).map { "ENG-\($0)" }.joined(separator: " ")
        let found = RefScanner.scan(text, context: ctx)
        #expect(RefScanner.maxPerMessage == 20)
        #expect(found.count == 20)
        #expect(found.last?.ref.canonical == "ENG-20")
    }
}

import Testing
import Foundation
@testable import BrahmaCore

/// Final-review M-5: `recall(ref: "kb:…")` finds a page the way every other page lookup does: the path is normalized and
/// matched case-insensitively against the stored page, and a `#section` by its slug. Unreadable stays like missing.
@Suite(.scratch) struct RecallKBRefTests {
    typealias W = HandbookTests.W

    private func recall(_ w: W, _ a: Agent, _ ref: String) -> String { w.call(a, "recall", ["ref": .string(ref)]).text }

    @Test func kbRefMatchesPagesCaseInsensitively() throws {
        let w = try W()
        try w.write(nil, "Engineering/Environments", "# Staging\nstaging host BLUEJAY\n# Prod\nprod host KESTREL\n")
        for ref in ["kb:Engineering/Environments", "kb:engineering/environments", "KB:ENGINEERING/Environments",
                    " kb:engineering/environments "] {
            let text = recall(w, w.eng1, ref)
            #expect(text.contains("BLUEJAY") && text.contains("KESTREL"), "\(ref): \(text)")
            #expect(text.hasPrefix("kb:Engineering/Environments · "), "the stored path is shown: \(text)")
        }
        // A section, by heading or slug, in any case.
        for ref in ["kb:engineering/environments#Staging", "kb:ENGINEERING/ENVIRONMENTS#staging"] {
            let text = recall(w, w.eng1, ref)
            #expect(text.contains("BLUEJAY") && !text.contains("KESTREL"), "\(ref): \(text)")
            #expect(text.hasPrefix("kb:Engineering/Environments#staging · "), "\(text)")
        }
        let doc = try #require(try MemoryIndex(store: w.store).document(companyId: w.company.id, scope: .agent(w.eng1.id),
                                                                         ref: "kb:engineering/environments", now: Store.now()))
        #expect(doc.hit.ref == "kb:Engineering/Environments")
        // A page that doesn't exist answers as before.
        #expect(recall(w, w.eng1, "kb:engineering/nowhere") == "No memory kb:engineering/nowhere you can read.")
    }

    @Test func caseFoldedRefToHiddenSectionStaysMissing() throws {
        let w = try W()
        try w.write(nil, "Company/Board", HandbookTests.boardBody)
        // eng-1 can't read the restricted section in any spelling; the answer is the generic one.
        #expect(recall(w, w.eng1, "kb:company/board#comp") == "No memory kb:company/board#comp you can read.")
        #expect(recall(w, w.eng1, "kb:company/board#nothing-here") == "No memory kb:company/board#nothing-here you can read.")
        // The cfo can, through the same spelling.
        #expect(recall(w, w.cfo, "kb:company/board#comp").contains("salary bands otter"))
        // The page as a whole for eng-1: only what it can read.
        let page = recall(w, w.eng1, "kb:COMPANY/BOARD")
        #expect(page.contains("public plan text")); #expect(!page.contains("otter"))
    }
}

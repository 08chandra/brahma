import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct AttachmentModelTests {
    @Test func lockedCardHasNoTitle() throws {
        let w = try RefWorld()
        let locked = ResolvedRef(ref: WorkRef(kind: .file, id: "x"), reader: .agent(w.eng1.id), visibility: .locked(approverRole: "cto"),
                                 title: "", subtitle: "", bytes: nil, provenance: .engine, tainted: false, taintReason: nil,
                                 accessClass: .ownerOnly, newer: nil, state: .ok, opaqueId: "o")
        let card = try AttachmentCards.make(locked, store: w.store, context: try w.renderContext())
        #expect(card.locked && card.kindChip == "FILE" && card.title == "" && card.meta == "locked · ask the owner")
        #expect(card.preview == .none && card.chips.isEmpty)
        // Refused and missing refs are cards of nothing too (the same text: no oracle).
        for v in [Visibility.refused, .missing] {
            var r = locked
            r.visibility = v
            let c = try AttachmentCards.make(r, store: w.store, context: try w.renderContext())
            #expect(c.locked && c.title == "" && c.meta == "locked · ask the owner")
        }
    }

    @Test func fileCardShowsSixHighlightedLines() throws {
        let w = try RefWorld()
        let ctx = try w.renderContext()
        let card = try AttachmentCards.make(try w.resolve("src/checkout.tsx"), store: w.store, context: ctx)
        #expect(!card.locked && card.kindChip == "FILE")
        #expect(card.title == "src/checkout.tsx")
        guard case .code(let lines) = card.preview else {
            Issue.record("expected a code preview, got \(card.preview)")
            return
        }
        #expect(lines.count == 6 && AttachmentCards.previewLines == 6)
        #expect(lines[0].first?.text == "const" && lines[0].first?.kind == .keyword)
        // A range starts the preview at its first line.
        let ranged = try AttachmentCards.make(try w.resolve("src/checkout.tsx:40-45"), store: w.store, context: ctx)
        if case .code(let l) = ranged.preview { #expect(l.count == 6 && l[0].map(\.text).joined() == "const line40 = 40") } else { Issue.record("not code") }
        // A card does not count as a read of the file.
        #expect(try w.store.refReads(companyId: w.company.id, canonical: "src/checkout.tsx", limit: 10).isEmpty)
        // Other kinds.
        let item = try AttachmentCards.make(try w.resolve("ENG-1"), store: w.store, context: ctx)
        #expect(item.kindChip == "ITEM" && item.title.contains("Checkout totals"))
        if case .item(let key, let status, let holder) = item.preview { #expect(key == "ENG-1" && status == "backlog" && holder == nil) } else { Issue.record("not an item preview") }
        let agent = try AttachmentCards.make(try w.resolve("@eng-1"), store: w.store, context: ctx)
        #expect(agent.kindChip == "AGENT" && agent.title == "@eng-1")
        if case .agent(let state) = agent.preview { #expect(!state.isEmpty) } else { Issue.record("not an agent preview") }
        // Tainted content carries a warning chip; an uncommitted file an UNCOMMITTED one.
        try w.seedResource(number: 3, name: "notes.md", bytes: Data("hello\n".utf8), provenance: "external:web", tainted: true)
        let tainted = try AttachmentCards.make(try w.resolve("F-3"), store: w.store, context: ctx)
        #expect(tainted.chips.contains { $0.text.hasPrefix("TAINTED") && $0.tone == .warn })
        #expect(tainted.title == "F-3 (untrusted)")
    }

    @Test func trustChipCopy() {
        #expect(TrustChip.externalText
                == "EXTERNAL · agents read it as untrusted data; a session that opens it loses merge/approve tools until it starts fresh")
        #expect(TrustChip.fromYouText == "FROM YOU")
        #expect(TrustChip.external(reason: "quarantined").text == TrustChip.externalText)
        #expect(TrustChip.external(reason: "quarantined").action == "I vouch for this file")
        #expect(TrustChip.fromYou.text == "FROM YOU")
        let drop = PendingDrop(plan: DropPlan(), chip: .fromYou)
        #expect(drop.chip == .fromYou)
    }
}

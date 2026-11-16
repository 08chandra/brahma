import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

/// Plan ML Task 8: the MEMORY tab — filters, the owner's delete (a tombstone stays) and inherit (from killed agents only).
@MainActor @Suite(.scratch) struct MemoryBrowserModelTests {
    struct W {
        let store: Store, paths: BrahmaPaths, acme: Company, ceo: Agent, cto: Agent, eng: Agent

        @discardableResult
        func remember(_ a: Agent, _ fact: String, key: String? = nil, scope: RememberScope = .mine) throws -> MemoryEntry {
            switch try store.remember(companyId: acme.id, by: a.id, fact: fact, key: key, scope: scope, knownValues: [], paths: paths) {
            case .created(let e), .confirmed(let e): return e
            case .contradicts(let new, _): return new
            }
        }
    }

    func world() throws -> W {
        let (store, paths) = try makeHome()
        let (acme, ceo, cto, eng) = try seedAcme(store, paths)
        try store.setOwnerTimeZone("UTC")
        return W(store: store, paths: paths, acme: acme, ceo: ceo, cto: cto, eng: eng)
    }

    @Test func filtersAndDeletes() async throws {
        let w = try world()
        let old = try w.remember(w.ceo, "Checkout uses Stripe", key: "pay.provider")
        try w.remember(w.eng, "Deploys happen on Fridays", scope: .company)
        let new = try w.remember(w.ceo, "Checkout uses Adyen", key: "pay.provider")
        let model = MemoryBrowserModel(store: w.store, companyId: w.acme.id)
        await model.reload()
        #expect(model.rows.map(\.ref) == [new.ref, "mem:2", old.ref])
        let oldRow = try #require(model.rows.first { $0.ref == old.ref })
        #expect(oldRow.isContradicted)
        #expect(oldRow.flags == ["CONTRADICTED"])
        #expect(oldRow.kind == "SEMANTIC")
        #expect(oldRow.type == "FACT")
        #expect(oldRow.scope == "agent @ceo")
        #expect(oldRow.author == "@ceo")
        #expect(oldRow.confidence == "0.70")
        #expect(oldRow.created.count == "yyyy-MM-dd HH:mm".count)
        #expect(model.rows.first { $0.ref == "mem:2" }?.scope == "company")

        model.filter.agentId = w.eng.id
        await model.reload()
        #expect(model.rows.map(\.ref) == ["mem:2"])
        model.filter.agentId = nil
        model.filter.query = "checkout"
        await model.reload()
        #expect(Set(model.rows.map(\.ref)) == [old.ref, new.ref])
        model.filter.query = ""
        model.filter.kind = .episodic
        await model.reload()
        #expect(model.rows.isEmpty)
        model.filter.kind = nil
        await model.reload()

        // Delete needs the dialog's confirmation of exactly that ref.
        #expect(MemoryBrowserModel.deleteConfirmText(new.ref) == "Delete \(new.ref)? Its text is erased; a tombstone remains.")
        let newRow = try #require(model.rows.first { $0.ref == new.ref })
        #expect(await model.delete(newRow) == false)
        #expect(model.error != nil)
        #expect(try w.store.memoryEntries(companyId: w.acme.id).contains { $0.ref == new.ref })
        model.confirmDelete = new.ref
        #expect(await model.delete(newRow))
        #expect(model.confirmDelete == nil)
        #expect(!model.rows.contains { $0.ref == new.ref })
        // Its contradiction went with it.
        #expect(model.rows.first { $0.ref == old.ref }?.isContradicted == false)
        model.filter.showRemoved = true
        await model.reload()
        let tomb = try #require(model.rows.first { $0.ref == new.ref })
        #expect(tomb.fact == "[purged]")
        #expect(tomb.isRemoved)
        #expect(tomb.flags.contains("PURGED"))
        #expect(!tomb.canDelete)
    }

    @Test func inheritOnlyFromKilledAgents() async throws {
        let w = try world()
        try w.remember(w.cto, "The staging port is 4417")
        let model = MemoryBrowserModel(store: w.store, companyId: w.acme.id)
        await model.reload()
        #expect(model.inheritSources.isEmpty)
        // A live agent's memory is not handed over.
        #expect(await model.inherit(from: w.cto.id, to: w.eng.id) == nil)
        #expect(model.error == MemoryBrowserModel.inheritNeedsKilled)
        #expect(try w.store.memoryEntries(companyId: w.acme.id).count == 1)

        _ = try w.store.transition(agentId: w.cto.id, to: .killed)
        await model.reload()
        #expect(model.inheritSources.map(\.id) == [w.cto.id])
        #expect(!model.inheritTargets.contains { $0.id == w.cto.id })
        #expect(model.inheritTargets.contains { $0.id == w.eng.id })
        #expect(await model.inherit(from: w.cto.id, to: w.eng.id) == 1)
        #expect(model.error == nil)
        let copy = try #require(model.rows.first { $0.flags.contains("INHERITED") })
        #expect(copy.scope == "agent @eng")
        #expect(copy.fact == "The staging port is 4417")
    }
}

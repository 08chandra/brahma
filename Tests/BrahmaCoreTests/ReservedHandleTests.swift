import Testing
import Foundation
@testable import BrahmaCore

/// Plan C Ruling C7a-1: `concierge`, `brahma` and `owner` name the engine's own speakers, so no agent may take them — in any
/// case, width, accent or lookalike spelling (Cyrillic/Greek letters, digits for letters, `rn` for `m`, separators).
@Suite(.scratch) struct ReservedHandleTests {
    func company() throws -> (Store, Company) {
        let store = try Store.inMemory()
        return (store, try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir()))
    }

    @Test(arguments: ["Concierge", "concierge", "CONCIERGE", "\u{0441}oncierge", "c0ncierge", "con-cierge", "brahma", "Brahma", "brahrna",
                      "br4hma", "owner", "0wner", "\u{043E}wner"])
    func reservedHandlesAreRefused(_ name: String) throws {
        let (store, c) = try company()
        #expect(Store.isReservedHandle(name))
        #expect(throws: StoreError.invalidName) { try store.hire(companyId: c.id, name: name, role: "engineer", model: "sonnet") }
    }

    @Test func lookalikeFreeNamesStillHire() throws {
        let (store, c) = try company()
        for name in ["concierge-helper", "brahma-bot", "owner-relations", "eng-1"] {
            #expect(!Store.isReservedHandle(name))
            _ = try store.hire(companyId: c.id, name: name, role: "engineer", model: "sonnet")
        }
    }
}

import ArgumentParser
import Foundation
import BrahmaCore

extension ItemsGroup {
    /// `brahma items link <company> <KEY> regression-of|revert-of <TARGET>` (Plan X6a Task 2): the owner records that an item is a
    /// regression of, or reverts, a landed item. `measure` reads the links (`docs/measure/metrics.md`: "escaped", "revert").
    struct Link: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "link", abstract: "Record that an item is a regression of, or reverts, a landed item (owner only).",
            discussion: "Only a landed item can be regressed or reverted. The same link twice is one link.")
        @Argument var company: String
        @Argument(help: "The item's key, e.g. ACME-14.") var key: String
        @Argument(help: "regression-of or revert-of.") var relation: String
        @Argument(help: "The landed item's key, e.g. ACME-12.") var target: String

        func run() throws {
            try requireOwnerShell()
            guard let kind = ItemLinkKind(spelling: relation) else {
                throw fail("unknown relation '\(relation)' (regression-of or revert-of)")
            }
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            do {
                try store.linkItem(companyId: c.id, itemKey: key, kind: kind, targetKey: target, by: "owner")
            } catch let e as WorkError {
                throw fail(e.message)
            }
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let t = target.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            switch kind {
            case .regressionOf: print(safe("\(k) is a regression of \(t)"))
            case .revertOf: print(safe("\(k) reverts \(t)"))
            }
        }
    }
}

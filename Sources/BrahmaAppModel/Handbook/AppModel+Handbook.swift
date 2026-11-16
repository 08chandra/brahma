import Foundation
import BrahmaCore

/// Work › Handbook (Plan ML): the selected company's `HandbookModel` and the ways into it (the sidebar row, the `handbook`,
/// `memory` and `kb:<path>` launch targets, and the memory-wide search's hits). The owner-only decisions it makes (kb
/// vouch, rollback, status; memory delete and inherit) call the Store directly, never `CompanyTools`.
extension AppModel {
    /// The selected company's handbook model, made on first use (nil with no company selected).
    @discardableResult
    public func ensureHandbook() -> HandbookModel? {
        guard let companyId = selectedCompanyId else { return nil }
        if let handbook, handbook.companyId == companyId { return handbook }
        let model = HandbookModel(store: store, companyId: companyId, paths: paths, secretVault: secretVault)
        model.afterChange = { [weak self] in await self?.tick(forceSnapshot: true) }
        model.memory.afterChange = { [weak self] in await self?.tick(forceSnapshot: true) }
        handbook = model
        return model
    }

    /// Selects Work › Handbook on `tab`, opening `page` when given.
    func openHandbook(tab: HandbookTab, page: String? = nil) {
        select(.handbook)
        guard let model = ensureHandbook() else { return }
        model.tab = tab
        if let page {
            Task { await model.select(page) }
        }
    }

    /// Opens a memory-wide search hit where it lives, and clears the search: a page in the Handbook, an item in the backlog,
    /// an ask in the Inbox, a recorded decision in Activity, a resource in Resources, a memory entry (or hand-off, retro) in
    /// Handbook › MEMORY.
    public func open(memoryHit hit: MemoryHit) async {
        search.query = ""
        switch hit.source {
        case .kb:
            select(.handbook)
            guard let model = ensureHandbook() else { return }
            model.tab = .pages
            await model.select(hit.ref)
        case .item:
            apply(.item(key: hit.ref.lowercased().hasPrefix("item:") ? String(hit.ref.dropFirst(5)) : hit.ref))
        case .ask:
            select(.inbox)
            let (store, companyId, ref) = (self.store, selectedCompanyId, hit.ref)
            guard let companyId else { return }
            do {
                highlightedAskId = try await Task.detached { try store.ask(companyId: companyId, ref: ref) }.value?.id
            } catch {
                errorMessage = "Couldn't open \(ref): \(error)"
            }
        case .decision:
            // A recorded decision is an activity line.
            select(.activity)
        case .resource:
            select(.resources)
        default:
            select(.handbook)
            guard let model = ensureHandbook() else { return }
            model.tab = .memory
            await model.memory.reload()
        }
    }
}

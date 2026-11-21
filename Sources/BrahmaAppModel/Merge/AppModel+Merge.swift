import Foundation
import BrahmaCore

/// Work › Merge queue (Plan 4a Task 8b). The owner's writes go through the owner-only Store methods; nothing here moves `main`
/// or sets a request's status (the engine is the referee).
extension AppModel {
    public var mergeRows: [MergeRow] {
        var keys: [String: String] = [:], titles: [String: String] = [:], holders: [String: String] = [:]
        for item in snapshot.work.items {
            keys[item.id] = item.key
            titles[item.id] = item.title
            if let holder = item.ownerId { holders[item.id] = holder }
        }
        return MergeRows.make(snapshot.merge, itemKeys: keys, itemTitles: titles, holders: holders, handles: handles, timeZone: ownerTimeZone)
    }

    public var mergeHeader: MergeHeader { MergeHeader.make(snapshot.merge) }

    /// Open requests (the sidebar chip).
    public var openMergeCount: Int { snapshot.merge.open.count }

    /// A fresh form over the stored settings.
    public var mergeSettingsForm: MergeSettingsForm { MergeSettingsForm(snapshot.merge.settings) }

    /// True when the settings were saved; false (with `errorMessage` set) when the form or the write was refused, so the sheet
    /// can stay open with what was typed.
    @discardableResult
    public func saveMergeSettings(_ form: MergeSettingsForm) async -> Bool {
        guard let companyId = selectedCompanyId else { return false }
        if let message = form.validate() { errorMessage = message; return false }
        let settings = form.settings
        return await ownerWrite("save the merge settings") { store in try store.setMergeSettings(companyId: companyId, settings, by: .owner) } != nil
    }

    /// Owner only: a `failed` request goes back in the queue as a fresh one (`Store.requestMergeRetry`).
    public func retryMerge(requestId: String) async {
        await ownerWrite("retry the merge") { store in try store.requestMergeRetry(requestId: requestId, by: .owner) }
    }

    /// Owner only: releases the hold (`Store.resumeMergeQueue`; a root-behind hold is released only once the root is on `main`).
    public func resumeMergeQueue() async {
        guard let companyId = selectedCompanyId else { return }
        await ownerWrite("resume the merge queue") { store in try store.resumeMergeQueue(companyId: companyId, by: .owner) }
    }

    /// The item inspector's MERGE section (Task 10): branch against `main`, verified commit, latest request and its tail, loaded
    /// detached (store and git).
    public func itemMergeDetail(itemKey: String) async -> ItemMergeDetail? {
        guard let item = item(key: itemKey) else { return nil }
        let store = self.store, workspace = work.workspace
        do {
            return try await Task.detached { try ItemMergeDetail.load(store: store, item: item, workspace: workspace) }.value
        } catch {
            report(error)
            return nil
        }
    }

    /// The item's open (or just-finished) request and its queue position as an agent's orientation shows it, loaded detached.
    public func itemMerge(itemKey: String) async -> MergeOrientation? {
        guard let companyId = selectedCompanyId else { return nil }
        let store = self.store
        do {
            return try await Task.detached {
                guard let item = try store.workItems(companyId: companyId).first(where: { $0.key.caseInsensitiveCompare(itemKey) == .orderedSame })
                else { return nil }
                return try MergeOrientation.load(store: store, item: item)
            }.value
        } catch {
            report(error)
            return nil
        }
    }
}

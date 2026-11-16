import Foundation
import BrahmaCore

/// The owner's resource decisions (Plan ML): vouch, scope changes and purge exist only here and in the CLI, never in
/// `CompanyTools`. Each goes through the 6c Store API with this data home's resource vault.
extension AppModel {
    public var resourceRows: [ResourceRow] { snapshot.resources }

    /// Where an open conversation's composer drops go: an owner DM or a channel (never the engine's notices, nor agents'
    /// own conversations, which the owner only reads).
    func dropContext(for target: ChatTarget) -> DropContext? {
        switch target {
        case .dm(let handle):
            return handle.lowercased() == "system" ? nil : .dm(handle: handle)
        case .channel(let id):
            guard let channel = snapshot.channels.first(where: { $0.id == id }), channel.kind == .channel else { return nil }
            return .channel(name: channel.name)
        }
    }

    /// Owner: vouch for `ref` (a folder: and its files).
    public func vouch(resource ref: String) async {
        guard let companyId = selectedCompanyId, let number = Self.resourceNumber(ref) else { return }
        let paths = self.paths
        await ownerWrite("vouch for \(ref)") { store in
            try store.vouchResource(companyId: companyId, number: number, contentVault: ContentVault(paths: paths), paths: paths)
        }
    }

    /// Owner: change who reads `ref` (a folder: and its files). The library's default is the company.
    public func setScope(resource ref: String, _ choice: ScopeChoice, futureHolders: Bool = false) async {
        guard let companyId = selectedCompanyId, let number = Self.resourceNumber(ref) else { return }
        let paths = self.paths
        await ownerWrite("change the scope of \(ref)") { store in
            let scope: AccessClass
            switch choice {
            case .contextDefault, .company: scope = .company
            case .team(let t): scope = .team(t)
            case .item(let key):
                guard let item = try store.workItem(companyId: companyId, key: key.uppercased()) else {
                    throw ResourceError.notFound("no work item \(key.prefix(40))")
                }
                scope = .item(item.id)
            }
            try store.setResourceScope(companyId: companyId, number: number, scope: scope, futureHolders: futureHolders,
                                       contentVault: ContentVault(paths: paths), paths: paths)
        }
    }

    /// Owner: purge `ref` for good. Refused unless the library's confirmation dialog set `confirmPurge` to this ref (it is
    /// cleared either way). Every database and data-home snapshot is passed in, so the report names those that still hold it.
    @discardableResult
    public func purge(resource ref: String) async -> PurgeReport? {
        guard confirmPurge == ref else {
            errorMessage = "Confirm the purge of \(ref) first."
            return nil
        }
        confirmPurge = nil
        guard let companyId = selectedCompanyId, let number = Self.resourceNumber(ref) else { return nil }
        let paths = self.paths
        return await ownerWrite("purge \(ref)") { store in
            let backups = BackupService(paths: paths).list().map { (name: $0.name, takenAt: $0.date) }
                + HomeSnapshot.list(paths: paths).map { (name: $0.name, takenAt: $0.date) }
            return try store.purgeResource(companyId: companyId, number: number, backups: backups,
                                           contentVault: ContentVault(paths: paths), paths: paths)
        }
    }

    /// `F-<n>` → n.
    nonisolated static func resourceNumber(_ ref: String) -> Int? {
        let t = ref.uppercased()
        guard t.hasPrefix("F-"), let n = Int(t.dropFirst(2)), n > 0, "F-\(n)" == t else { return nil }
        return n
    }
}

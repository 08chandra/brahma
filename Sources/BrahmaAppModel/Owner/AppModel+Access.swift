import Foundation
import BrahmaCore

/// Task 4-wire's `Store.provideSecret` behind a seam: the secret `request` card's `Provide…` goes through it. The value goes to
/// the vault only; the ask is answered through `ownerDecide`.
public protocol SecretProviding: Sendable {
    func provideSecret(store: Store, askId: String, name: String, value: String, isTest: Bool, vault: any SecretVault) throws
}

extension AppModel {
    /// The access cards of the Inbox (one per pending `grant` ask), from the snapshot.
    public var accessCards: [AccessCard] {
        let items = Dictionary(work.items.map { ($0.id, $0.key) }, uniquingKeysWith: { a, _ in a })
        let roles = Dictionary(snapshot.agents.map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })
        return work.inbox.compactMap { AccessCard.make(ask: $0, handles: handles, itemKeys: items, roles: roles) }
    }

    public func accessCard(askId: String) -> AccessCard? { accessCards.first { $0.id == askId } }

    /// The selected company (or one of its roles) runs on the Full profile: the top bar's FULL ACCESS chip.
    public var fullAccess: Bool {
        guard let company = selectedCompany?.company else { return false }
        return company.permissionProfile == .full || company.roleProfiles.values.contains(.full)
    }

    /// Shown while an engine alert about the sandbox check (3a's doctor / the sandboxed-check canary) waits in the Inbox.
    public var sandboxBanner: String? {
        let pending = work.inbox.contains { ask in
            ask.kind == .engineAlert && ask.requesterId == "system"
                && ((ask.subjectId ?? "").lowercased().contains("sandbox") || ask.title.lowercased().contains("sandbox check"))
        }
        guard pending else { return nil }
        return "Sandbox check failed or pending for claude \(snapshot.claudeVersion ?? "?") — see Inbox"
    }

    /// The secret `request` card's `Provide…`: the owner's value goes to the vault through `secretProvider`.
    @discardableResult
    public func provideSecret(askId: String, form: SecretsForm) async -> Bool {
        if let why = form.validate() { errorMessage = why; return false }
        guard let provider = secretProvider else {
            errorMessage = "Providing a secret from the app needs Brahma's secret-request support (Task 4-wire), which this build lacks."
            return false
        }
        guard let vault = ownerSecretVault else {
            errorMessage = "No secrets vault is available in this app, so nothing was stored."
            return false
        }
        let (store, name, value, isTest) = (self.store, form.trimmedName, form.value, form.isTest)
        do {
            try await Task.detached { try provider.provideSecret(store: store, askId: askId, name: name, value: value, isTest: isTest, vault: vault) }.value
            await tick(forceSnapshot: true)
            return true
        } catch let e as WorkError {
            errorMessage = e.message
        } catch let e as SecretError {
            errorMessage = e.message
        } catch {
            errorMessage = "Couldn't provide the secret: \(error)"
        }
        return false
    }
}

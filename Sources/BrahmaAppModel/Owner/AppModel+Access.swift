import Foundation
import BrahmaCore

/// Task 4-wire's `Store.provideSecret` behind a seam: the secret `request` card's `Provide…` goes through it. The value goes to
/// the vault only; the ask is answered through `ownerDecide`.
public protocol SecretProviding: Sendable {
    func provideSecret(store: Store, askId: String, name: String, value: String, isTest: Bool, vault: any SecretVault) throws
}

/// The real provider: `Store.provideSecret` (vault write, metadata row and approval as one unit with respect to the pending →
/// approved transition). The name the owner sees in the sheet must be the one the request is for.
public struct StoreSecretProvider: SecretProviding {
    public init() {}

    public func provideSecret(store: Store, askId: String, name: String, value: String, isTest: Bool, vault: any SecretVault) throws {
        guard let ask = try store.ask(id: askId) else { throw WorkError.notFound("no such ask") }
        guard let requested = SecretRequests.requested(ask) else { throw WorkError.invalid("\(ask.ref) is not a secret request") }
        guard requested.name == name else { throw WorkError.invalid("\(ask.ref) asks for \(requested.name), not \(name)") }
        _ = try store.provideSecret(askId: askId, value: value, isTest: isTest, vault: vault)
    }
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

    /// Shown while the sandbox-check engine alert (`EngineAlerts.sandboxCheckReason`, raised by the sandboxed-check canary) waits in
    /// the Inbox. Keyed on that one alert's subject, never on text: a `sandbox-link` alert or agent words do not light it.
    public var sandboxBanner: String? {
        let subject = EngineAlerts.askSubject(reason: EngineAlerts.sandboxCheckReason)
        let pending = work.inbox.contains { $0.kind == .engineAlert && $0.requesterId == "system" && $0.subjectId == subject }
        guard pending else { return nil }
        return "Sandbox check failed or pending for claude \(snapshot.claudeVersion ?? "?") — see Inbox"
    }

    /// The secret `request` card's `Provide…`: the owner's value goes to the vault through `secretProvider`. Returns why it was
    /// not stored (shown in the sheet), or nil when it was.
    public func provideSecret(askId: String, form: SecretsForm) async -> String? {
        if let why = form.validate() { return why }
        guard let provider = secretProvider else {
            return "Providing a secret from the app needs Brahma's secret-request support (Task 4-wire), which this build lacks."
        }
        guard let vault = ownerSecretVault else { return "No secrets vault is available in this app, so nothing was stored." }
        let (store, name, value, isTest) = (self.store, form.trimmedName, form.value, form.isTest)
        do {
            try await Task.detached { try provider.provideSecret(store: store, askId: askId, name: name, value: value, isTest: isTest, vault: vault) }.value
            await tick(forceSnapshot: true)
            return nil
        } catch let e as WorkError {
            return e.message
        } catch let e as SecretError {
            return e.message
        } catch {
            return "Couldn't provide the secret: \(error)"
        }
    }
}

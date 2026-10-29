import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

/// The app's "Load secrets" action: the owner-visible side of the secrets hold.
@MainActor @Suite(.scratch) struct SecretsModelTests {
    @Test func loadSecretsClearsTheBanner() async throws {
        let (owner, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(owner, paths)
        let vault = MemoryVault()
        try owner.setSecret(companyId: acme.id, name: "API_KEY", value: "app-secret-value-1", isTest: false, vault: vault)
        // A new app process: the database has a secret and nothing is loaded yet.
        let store = try Store(path: paths.database.path)
        let model = AppModel(store: store, paths: paths)
        model.refreshSecrets()
        #expect(model.secretsBanner?.contains("can't read 1 secret(s)") == true, "\(model.secretsBanner ?? "nil")")
        // Without a vault the action reports instead of reading.
        await model.loadSecrets()
        #expect(model.secretsBanner != nil)
        model.ownerSecretVault = vault
        await model.loadSecrets()
        #expect(model.secretsBanner == nil)
        #expect(!store.secretsHeld)
        #expect(store.redactor.apply("app-secret-value-1") == "[redacted API_KEY]")
    }

    @Test func noSecretsNoBanner() throws {
        let (store, paths) = try makeHome()
        try seedAcme(store, paths)
        let model = AppModel(store: store, paths: paths)
        model.refreshSecrets()
        #expect(model.secretsBanner == nil)
    }
}

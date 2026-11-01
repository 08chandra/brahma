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

    @Test func provideSecretAnswersTheRequestThroughTheStore() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, eng) = try seedAcme(store, paths)
        let (ask, _) = try store.requestSecret(companyId: acme.id, agentId: eng.id, name: "STRIPE_TEST_KEY", reason: "tests", test: true)
        let model = AppModel(store: store, paths: paths)
        #expect(model.secretProvider is StoreSecretProvider, "wired to Store.provideSecret by default")
        // Without a vault nothing is stored.
        let noVault = await model.provideSecret(askId: ask.id, form: SecretsForm(name: "STRIPE_TEST_KEY", value: "sk_test_app_value_123", isTest: true))
        #expect(noVault?.contains("vault") == true, "\(noVault ?? "nil")")
        let vault = MemoryVault()
        model.ownerSecretVault = vault
        // The sheet's name must be the requested one.
        let wrong = await model.provideSecret(askId: ask.id, form: SecretsForm(name: "OTHER_TEST_KEY", value: "sk_test_app_value_123", isTest: true))
        #expect(wrong?.contains("asks for STRIPE_TEST_KEY") == true, "\(wrong ?? "nil")")
        #expect(try vault.value(companyId: acme.id, name: "OTHER_TEST_KEY") == nil)
        let ok = await model.provideSecret(askId: ask.id, form: SecretsForm(name: "STRIPE_TEST_KEY", value: "sk_test_app_value_123", isTest: true))
        #expect(ok == nil, "\(ok ?? "nil")")
        #expect(try vault.value(companyId: acme.id, name: "STRIPE_TEST_KEY") == "sk_test_app_value_123")
        #expect(try store.ask(id: ask.id)?.status == .approved)
        #expect(try store.secrets(companyId: acme.id).map(\.isTest) == [true])
        // A second provide of the answered request is refused and changes nothing.
        let again = await model.provideSecret(askId: ask.id, form: SecretsForm(name: "STRIPE_TEST_KEY", value: "sk_test_other_value_9", isTest: false))
        #expect(again != nil)
        #expect(try vault.value(companyId: acme.id, name: "STRIPE_TEST_KEY") == "sk_test_app_value_123")
    }

    @Test func noSecretsNoBanner() throws {
        let (store, paths) = try makeHome()
        try seedAcme(store, paths)
        let model = AppModel(store: store, paths: paths)
        model.refreshSecrets()
        #expect(model.secretsBanner == nil)
    }
}

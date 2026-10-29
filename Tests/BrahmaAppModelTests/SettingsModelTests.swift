import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

/// Company › Settings: the profile chooser and its copy, the network lists, secrets, and the owner prefs (quiet hours, digest,
/// phone alerts). Vaults are in memory; nothing here touches the Keychain or the network.
@MainActor @Suite(.scratch) struct SettingsModelTests {
    @MainActor struct World {
        let w: WorkWorld
        let settings: SettingsModel
        let vault = MemoryVault()

        static func make() async throws -> World {
            let w = try await WorkWorld.make()
            let settings = w.model.settings
            settings.userHome = try tempDir()
            w.model.ownerSecretVault = nil
            let world = World(w: w, settings: settings)
            settings.vault = world.vault
            await settings.reload()
            return world
        }
    }

    @Test func workspaceProfileShowsPrivacyCaveat() async throws {
        let caveat = "Resource scopes and lab privacy are enforced only by Brahma's tools; an agent's shell can read them."
        #expect(SettingsModel.caveat(for: .workspace) == caveat)
        #expect(SettingsModel.caveat(for: .full) == caveat)
        #expect(SettingsModel.caveat(for: .sandboxed) == nil)
        #expect(SettingsModel.fullWarning == "Full lets agents do anything your account can, including installing software and reading your files.")
        let s = try await World.make()
        #expect(s.settings.profile == .sandboxed)
        #expect(await s.settings.setProfile(.workspace))
        #expect(s.settings.profile == .workspace && s.settings.error == nil)
        #expect(try s.w.store.company(id: s.w.company.id)?.permissionProfile == .workspace)
        // A role override, listed with the company's roles.
        #expect(s.settings.roles.contains("engineer"))
        #expect(await s.settings.setProfile(.sandboxed, role: "engineer"))
        #expect(s.settings.roleProfiles == ["engineer": .sandboxed])
        #expect(!(await s.settings.setProfile(.sandboxed, role: "plumber")))
        #expect(s.settings.error?.contains("plumber") == true)
    }

    @Test func fullProfileRequiresConfirm() async throws {
        let s = try await World.make()
        #expect(SettingsModel.needsConfirmation(.full) && !SettingsModel.needsConfirmation(.workspace))
        #expect(!(await s.settings.setProfile(.full)), "Full without the confirmation changes nothing")
        #expect(s.settings.pendingFull != nil && s.settings.pendingFull?.role == nil)
        #expect(s.settings.profile == .sandboxed)
        #expect(try s.w.store.company(id: s.w.company.id)?.permissionProfile == .sandboxed)
        #expect(await s.settings.setProfile(.full, confirmed: true))
        #expect(s.settings.profile == .full && s.settings.pendingFull == nil)
        #expect(s.w.model.fullAccess, "the top bar's FULL ACCESS chip follows the company")
        // The chip also lights for a single role on Full.
        #expect(await s.settings.setProfile(.sandboxed, confirmed: true))
        #expect(!s.w.model.fullAccess)
        #expect(await s.settings.setProfile(.full, role: "engineer", confirmed: true))
        #expect(s.w.model.fullAccess)
    }

    @Test func addDomainValidates() async throws {
        let s = try await World.make()
        #expect(!(await s.settings.addDomain("localhost", web: false)))
        #expect(s.settings.error?.contains("localhost") == true, Comment(rawValue: s.settings.error ?? "nil"))
        #expect(!(await s.settings.addDomain("*.github.io", web: true)))
        #expect(s.settings.error?.contains("github.io") == true, Comment(rawValue: s.settings.error ?? "nil"))
        #expect(s.settings.domains.isEmpty && s.settings.webDomains.isEmpty)
        #expect(await s.settings.addDomain("API.Stripe.com", web: false))
        #expect(s.settings.error == nil && s.settings.domains == ["api.stripe.com"])
        #expect(await s.settings.addDomain("docs.stripe.com", web: true))
        #expect(s.settings.webDomains == ["docs.stripe.com"])
        #expect(try s.w.store.company(id: s.w.company.id)?.allowedDomains == ["api.stripe.com"])
        await s.settings.removeDomain("api.stripe.com", web: false)
        #expect(s.settings.domains.isEmpty)
        // Defaults are listed but cannot be removed.
        #expect(s.settings.defaultDomains.contains("github.com"))
        await s.settings.removeDomain("github.com", web: false)
        #expect(s.settings.error?.contains("default") == true)
        await s.settings.setLocalBinding(false)
        #expect(s.settings.localBinding == false)
        #expect(try s.w.store.company(id: s.w.company.id)?.allowLocalBinding == false)
    }

    @Test func toolchainOverlapErrorShown() async throws {
        let s = try await World.make()
        // The data home is protected: a toolchain path inside it is refused with the sandbox's reason, and nothing is stored.
        #expect(!(await s.settings.addToolchainPath(s.w.paths.home.path)))
        #expect(s.settings.error?.contains("overlaps") == true, Comment(rawValue: s.settings.error ?? "nil"))
        #expect(s.settings.toolchainPaths.isEmpty)
        #expect(try s.w.store.company(id: s.w.company.id)?.toolchainReadPaths.isEmpty == true)
        let tools = try tempDir()
        #expect(await s.settings.addToolchainPath(tools.path))
        #expect(s.settings.error == nil && s.settings.toolchainPaths == [tools.path])
        await s.settings.removeToolchainPath(tools.path)
        #expect(s.settings.toolchainPaths.isEmpty)
        #expect(!(await s.settings.addToolchainPath("relative/path")))
        #expect(s.settings.error != nil)
    }

    @Test func secretsFormValidation() async throws {
        #expect(SecretsForm(name: "", value: "x").validate() != nil)
        #expect(SecretsForm(name: "bad name", value: "x").validate()?.contains("A-Z") == true)
        #expect(SecretsForm(name: "STRIPE_KEY", value: "").validate() != nil)
        #expect(SecretsForm(name: "STRIPE_KEY", value: "sk_test_1234").validate() == nil)
        #expect(SecretsForm(name: "DATABASE", value: "x", isTest: true).validate()?.contains("test key") == true,
                "a test key must be a name agents may be given")
        #expect(SecretsForm(name: "DATABASE", value: "x", isTest: false).validate() == nil)
        #expect(SecretsForm.testKeyCaption == "Test keys are given to agents as environment variables. Other keys stay with the engine.")

        let s = try await World.make()
        #expect(await s.settings.addSecret(SecretsForm(name: "STRIPE_TEST_KEY", value: "sk_test_abcdef", isTest: true)))
        #expect(s.settings.error == nil)
        #expect(s.settings.secrets.map(\.name) == ["STRIPE_TEST_KEY"] && s.settings.secrets[0].isTest)
        #expect(try s.vault.value(companyId: s.w.company.id, name: "STRIPE_TEST_KEY") == "sk_test_abcdef")
        #expect(!(await s.settings.addSecret(SecretsForm(name: "bad-name", value: "x"))))
        #expect(s.settings.error != nil && s.settings.secrets.count == 1)
        await s.settings.removeSecret(name: "STRIPE_TEST_KEY")
        #expect(s.settings.secrets.isEmpty)
        #expect(try s.vault.value(companyId: s.w.company.id, name: "STRIPE_TEST_KEY") == nil)
        // No vault (the app could not open one): refused with a message, nothing stored.
        s.settings.vault = nil
        #expect(!(await s.settings.addSecret(SecretsForm(name: "OTHER_KEY", value: "value-123"))))
        #expect(s.settings.error != nil && s.settings.secrets.isEmpty)
    }

    @Test func prefsRoundTrip() async throws {
        let s = try await World.make()
        var prefs = s.settings.prefs
        #expect(prefs.quietStart == "22:00" && prefs.digestTime == "08:00" && prefs.pushProvider == nil)
        prefs.quietStart = "23:00"; prefs.quietEnd = "07:00"; prefs.digestTime = "07:30"; prefs.notificationsEnabled = false
        #expect(await s.settings.savePrefs(prefs))
        await s.settings.reload()
        let stored = try s.w.store.ownerPrefs()
        let same = stored.quietStart == "23:00" && stored.quietEnd == "07:00" && stored.digestTime == "07:30" && stored.notificationsEnabled == false
        #expect(same)
        #expect(s.settings.prefs.quietStart == "23:00" && s.settings.prefs.digestTime == "07:30")
        // A bad time is refused with the store's reason, and the stored prefs stay.
        prefs.digestTime = "25:99"
        #expect(!(await s.settings.savePrefs(prefs)))
        #expect(s.settings.error?.contains("HH:MM") == true)
        #expect(try s.w.store.ownerPrefs().digestTime == "07:30")

        // Phone alerts (7b): ntfy with a token in the vault, the detail level, then off (the token goes too).
        #expect(await s.settings.setPushNtfy(topic: "brahma-alerts", server: "", token: "tk_abcdef123"))
        let ntfy = try s.w.store.ownerPrefs()
        #expect(ntfy.pushProvider == .ntfy && ntfy.pushTopic == "brahma-alerts" && ntfy.pushServer == OwnerPrefs.defaultPushServer)
        #expect(try s.vault.value(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken)?.hasSuffix("tk_abcdef123") == true)
        #expect(s.settings.prefs.pushProvider == .ntfy)
        #expect(await s.settings.setPushDetail(.titles))
        #expect(try s.w.store.ownerPrefs().pushDetail == .titles)
        #expect(!(await s.settings.setPushNtfy(topic: "bad topic!", server: "", token: nil)))
        #expect(s.settings.error != nil)
        #expect(await s.settings.setPushover(appToken: "app-token-1", userKey: "user-key-1"))
        #expect(try s.w.store.ownerPrefs().pushProvider == .pushover)
        #expect(try s.vault.value(companyId: OwnerCredential.scope, name: OwnerCredential.ntfyToken) == nil)
        #expect(await s.settings.turnPushOff())
        #expect(try s.w.store.ownerPrefs().pushProvider == nil)
        #expect(try s.vault.value(companyId: OwnerCredential.scope, name: OwnerCredential.pushoverAppToken) == nil)
        // Send test with alerts off: refused with the push error, no network.
        await s.settings.sendTestPush()
        #expect(s.settings.error?.contains("off") == true)
    }
}

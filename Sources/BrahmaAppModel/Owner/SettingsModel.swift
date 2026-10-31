import Foundation
import Observation
import BrahmaCore

/// Company › Settings: PERMISSIONS (the profile and role overrides), NETWORK (Bash egress and WebFetch domains, local
/// binding, toolchain read paths), SECRETS (names and flags; the value goes to the vault only), and NOTIFICATIONS (the owner
/// prefs: banners, quiet hours, digest time and Task 7b's phone alerts). Every store call runs off the main actor; a refused
/// one puts its reason in `error` and changes nothing.
@MainActor @Observable
public final class SettingsModel {
    /// Under the Workspace and Full options of the profile chooser (5L-3).
    public static let workspaceCaveat = "Resource scopes and lab privacy are enforced only by Brahma's tools; an agent's shell can read them."
    /// The confirmation shown before Full is applied.
    public static let fullWarning = "Full lets agents do anything your account can, including installing software and reading your files."

    public private(set) var company: Company?
    /// The role ids of this company (its agents' roles and the pack's), for the role overrides.
    public private(set) var roles: [String] = []
    public private(set) var prefs = OwnerPrefs.defaults
    public private(set) var secrets: [SecretMeta] = []
    /// The owner's time zone (every calendar-facing string here).
    public private(set) var timeZone: TimeZone = .current
    /// Full chosen without the confirmation: the view shows `fullWarning`, then calls `setProfile(.full, role:, confirmed: true)`.
    public var pendingFull: PendingFull?
    public private(set) var error: String?
    /// What the last action did ("Test alert sent").
    public private(set) var message: String?
    public var companyId: String?

    @ObservationIgnored private let store: Store
    /// The owner's interactive vault (secret values and phone-alert credentials); nil when the app could not open one.
    @ObservationIgnored public var vault: (any SecretVault)?
    /// The owner's home, for the sandbox checks of toolchain paths (tests inject a temp home).
    @ObservationIgnored public var userHome: URL = FileManager.default.homeDirectoryForCurrentUser
    /// How `Send test` reaches the push service (tests inject a recorder).
    @ObservationIgnored public var pushTransport: any PushTransport = URLSessionPushTransport()
    /// Runs after a company setting changed (the app model's snapshot refresh: the top bar's FULL ACCESS chip reads it).
    @ObservationIgnored public var afterChange: (@MainActor () async -> Void)?

    public struct PendingFull: Equatable, Sendable {
        public var role: String?
    }

    public init(store: Store) {
        self.store = store
    }

    // MARK: Reads

    public var profile: PermissionProfile { company?.permissionProfile ?? .sandboxed }
    public var roleProfiles: [String: PermissionProfile] { company?.roleProfiles ?? [:] }
    /// Owner-added Bash egress domains.
    public var domains: [String] { company?.allowedDomains ?? [] }
    /// Owner-added WebFetch domains.
    public var webDomains: [String] { company?.webDomains ?? [] }
    public var localBinding: Bool { company?.allowLocalBinding ?? true }
    public var toolchainPaths: [String] { company?.toolchainReadPaths ?? [] }
    /// The built-in Bash egress domains (registries), which cannot be removed.
    public var defaultDomains: [String] { CompanyNetwork.defaultRegistries.sorted() }
    /// The built-in WebFetch domains (registries and docs).
    public var defaultWebDomains: [String] { (CompanyNetwork.defaultRegistries + CompanyNetwork.defaultDocs).sorted() }

    /// The privacy caveat the Workspace and Full options carry; nil for Sandboxed.
    public static func caveat(for profile: PermissionProfile) -> String? { profile == .sandboxed ? nil : workspaceCaveat }
    public static func needsConfirmation(_ profile: PermissionProfile) -> Bool { profile == .full }

    /// The chooser's order: the default first, the widest last.
    public static let profileOrder: [PermissionProfile] = [.sandboxed, .workspace, .full]

    public static func profileTitle(_ profile: PermissionProfile) -> String {
        switch profile {
        case .sandboxed: "Sandboxed"
        case .workspace: "Workspace"
        case .full: "Full"
        }
    }

    public static func profileDetail(_ profile: PermissionProfile) -> String {
        switch profile {
        case .sandboxed: "Each turn is confined to its own places in the workspace; the network is the allow-list below. The default."
        case .workspace: "The agent's shell runs anywhere you can; Brahma's tools keep to the workspace."
        case .full: "WARNING: the whole Mac."
        }
    }

    /// Rereads everything shown here; a good read clears the last refusal.
    public func reload() async { await reload(keepingError: false) }

    /// After an action: the action's own refusal (set just before) outlives the reread.
    private func reload(keepingError: Bool) async {
        let store = self.store
        let companyId = self.companyId
        struct Read: Sendable { var company: Company?; var roles: [String]; var prefs: OwnerPrefs; var secrets: [SecretMeta]; var zone: TimeZone }
        do {
            let read: Read = try await Task.detached {
                var company: Company?
                var roles: [String] = []
                var secrets: [SecretMeta] = []
                if let companyId {
                    company = try store.company(id: companyId)
                    var set = Set(try store.agents(companyId: companyId).filter { $0.state != .killed }.map(\.role))
                    if let pack = company.flatMap({ store.catalog.pack($0.packId) }) { set.formUnion(pack.roles.map(\.id)) }
                    roles = set.sorted()
                    secrets = try store.secrets(companyId: companyId)
                }
                return Read(company: company, roles: roles, prefs: try store.ownerPrefs(), secrets: secrets, zone: store.ownerTimeZone())
            }.value
            company = read.company
            roles = read.roles
            prefs = read.prefs
            secrets = read.secrets
            timeZone = read.zone
            if !keepingError { error = nil }
        } catch {
            self.error = "\(error)"
        }
    }

    // MARK: Permissions

    /// The company's profile, or (with `role`) that role's override. Full needs `confirmed`; otherwise `pendingFull` is set
    /// for the view's confirmation and nothing changes.
    @discardableResult
    public func setProfile(_ profile: PermissionProfile, role: String? = nil, confirmed: Bool = false) async -> Bool {
        guard let companyId, let company else { return false }
        if Self.needsConfirmation(profile), !confirmed {
            pendingFull = PendingFull(role: role)
            return false
        }
        pendingFull = nil
        if let role, !roles.contains(role) {
            error = SandboxEditError.unknownRole(role).description
            return false
        }
        return await sandbox(companyId, .profile(profile, role: role, company: company))
    }

    /// The Full confirmation's text names its target: "Company <name>: " or "Role <role>: " before the brief's sentence.
    public func fullConfirmation(_ pending: PendingFull) -> String {
        let target = pending.role.map { "Role \($0)" } ?? "Company \(company?.name ?? "")"
        return target + ": " + Self.fullWarning
    }

    /// The owner confirmed Full for exactly the target that was presented (the company, or one role).
    @discardableResult
    public func confirmFull(_ pending: PendingFull) async -> Bool {
        await setProfile(.full, role: pending.role, confirmed: true)
    }

    public func clearRoleProfile(_ role: String) async {
        guard let companyId, let company else { return }
        var roles = company.roleProfiles
        roles.removeValue(forKey: role)
        _ = await sandbox(companyId, SandboxPatch(roleProfiles: roles))
    }

    // MARK: Network

    /// Adds a Bash egress domain (or, `web`, a WebFetch domain). `localhost`, IP literals, `*` and public-suffix wildcards
    /// such as `*.github.io` are refused by the sandbox's rules; Anthropic's domains always are.
    @discardableResult
    public func addDomain(_ raw: String, web: Bool) async -> Bool {
        guard let companyId, let company else { return false }
        let domain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !domain.isEmpty else { error = "Enter a domain."; return false }
        return await sandbox(companyId, { try SandboxPatch.domains(.add(domain), web: web, company: company) })
    }

    public func removeDomain(_ domain: String, web: Bool) async {
        guard let companyId, let company else { return }
        _ = await sandbox(companyId, { try SandboxPatch.domains(.remove(domain), web: web, company: company) })
    }

    public func setLocalBinding(_ on: Bool) async {
        guard let companyId else { return }
        _ = await sandbox(companyId, SandboxPatch(allowLocalBinding: on))
    }

    /// An extra read-only toolchain path (absolute or `~/…`), checked as a turn's scope would check it: a path overlapping
    /// the data home, the owner's protected paths or another workspace is refused with the sandbox's reason.
    @discardableResult
    public func addToolchainPath(_ raw: String) async -> Bool {
        guard let companyId, let company else { return false }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") || path.hasPrefix("~") else { error = "A toolchain path is absolute or starts with ~/."; return false }
        return await sandbox(companyId, { try SandboxPatch.toolchain(.add(path), company: company) })
    }

    public func removeToolchainPath(_ path: String) async {
        guard let companyId, let company else { return }
        _ = await sandbox(companyId, { try SandboxPatch.toolchain(.remove(path), company: company) })
    }

    private func sandbox(_ companyId: String, _ patch: SandboxPatch) async -> Bool {
        await sandbox(companyId, { patch })
    }

    private func sandbox(_ companyId: String, _ make: @escaping @Sendable () throws -> SandboxPatch) async -> Bool {
        let (store, home) = (self.store, userHome)
        let ok = await run("change the sandbox settings") {
            try store.updateSandbox(companyId: companyId, try make(), userHome: home)
        } != nil
        await reload(keepingError: true)
        if ok { await afterChange?() }
        return ok
    }

    // MARK: Secrets

    /// Stores the secret: the value in the vault, the name and flag in the database (`Store.setSecret`).
    @discardableResult
    public func addSecret(_ form: SecretsForm) async -> Bool {
        guard let companyId else { return false }
        if let why = form.validate() { error = why; return false }
        guard let vault else { error = "No secrets vault is available in this app, so nothing was stored."; return false }
        let (store, name, value, isTest) = (self.store, form.trimmedName, form.value, form.isTest)
        let ok = await run("store the secret") { try store.setSecret(companyId: companyId, name: name, value: value, isTest: isTest, vault: vault) } != nil
        await reload(keepingError: true)
        return ok
    }

    public func removeSecret(name: String) async {
        guard let companyId else { return }
        guard let vault else { error = "No secrets vault is available in this app, so nothing was removed."; return }
        let store = self.store
        _ = await run("remove the secret") { try store.deleteSecret(companyId: companyId, name: name, vault: vault) }
        await reload(keepingError: true)
    }

    // MARK: Notifications

    /// Writes the owner prefs (validated by the store: times are `HH:mm`).
    @discardableResult
    public func savePrefs(_ prefs: OwnerPrefs) async -> Bool {
        let store = self.store
        let ok = await run("save the preferences") { try store.updateOwnerPrefs(prefs) } != nil
        await reload(keepingError: true)
        return ok
    }

    /// Phone alerts through ntfy (`PushSettings.setNtfy`): an empty server keeps the current one; a token goes to the vault.
    @discardableResult
    public func setPushNtfy(topic: String, server: String, token: String?) async -> Bool {
        guard let vault else { error = "No vault is available in this app for the push credentials."; return false }
        let store = self.store
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = await run("set up phone alerts") {
            try PushSettings.setNtfy(store: store, vault: vault, topic: topic, server: server.isEmpty ? nil : server,
                                     token: (token?.isEmpty ?? true) ? nil : token)
        } != nil
        await reload(keepingError: true)
        return ok
    }

    @discardableResult
    public func setPushover(appToken: String, userKey: String) async -> Bool {
        guard let vault else { error = "No vault is available in this app for the push credentials."; return false }
        let store = self.store
        let ok = await run("set up phone alerts") {
            try PushSettings.setPushover(store: store, vault: vault, appToken: appToken.trimmingCharacters(in: .whitespacesAndNewlines),
                                         userKey: userKey.trimmingCharacters(in: .whitespacesAndNewlines))
        } != nil
        await reload(keepingError: true)
        return ok
    }

    @discardableResult
    public func turnPushOff() async -> Bool {
        guard let vault else { error = "No vault is available in this app for the push credentials."; return false }
        let store = self.store
        let ok = await run("turn phone alerts off") { try PushSettings.turnOff(store: store, vault: vault) } != nil
        await reload(keepingError: true)
        return ok
    }

    @discardableResult
    public func setPushDetail(_ detail: PushDetail) async -> Bool {
        let store = self.store
        let ok = await run("change the alert detail") { try store.setPushDetail(detail) } != nil
        await reload(keepingError: true)
        return ok
    }

    /// One test alert to the configured service (`PushDispatcher.sendTest`); never rate limited, marks nothing.
    public func sendTestPush() async {
        guard let vault else { error = "No vault is available in this app for the push credentials."; return }
        let (store, transport) = (self.store, pushTransport)
        message = nil
        do {
            let result = try await PushDispatcher.sendTest(store: store, vault: vault, transport: transport)
            if result.ok {
                error = nil
                message = "Test alert sent (HTTP \(result.status ?? 0))."
            } else {
                error = "The test alert failed: " + (result.status.map { "HTTP \($0)" } ?? result.error ?? "no answer")
            }
        } catch let e as PushError {
            error = e.description
        } catch {
            self.error = "Couldn't send the test alert: \(error)"
        }
    }

    // MARK: Internals

    private func run<T: Sendable>(_ what: String, _ body: @escaping @Sendable () throws -> T) async -> T? {
        do {
            let value = try await Task.detached { try body() }.value
            error = nil
            return value
        } catch let e as WorkError {
            error = e.message
        } catch let e as SecretError {
            error = e.message
        } catch let e as PushError {
            error = e.description
        } catch let e as SettingsError {
            if case .invalid(let why) = e { error = why } else { error = "\(e)" }
        } catch let e as SandboxEditError {
            error = e.description
        } catch let e as SandboxError {
            error = e.description
        } catch {
            self.error = "Couldn't \(what): \(error)"
        }
        return nil
    }
}

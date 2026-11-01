import Foundation
import GRDB

extension Store {
    /// The company's hosting settings, nil until the owner or an ops agent sets them.
    public func hosting(companyId: String) throws -> HostingSettings? {
        try writer.read { db in try HostingSettings.fetchOne(db, key: companyId) }
    }

    /// Whether any company has hosting settings (the doctor's `npm` item).
    public func anyHosting() throws -> Bool {
        try writer.read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM hosting)") ?? false }
    }

    static let hostingOwnerOnly = "only the owner can change hosting"

    /// Owner only: the provider, project, account and production URL. `nil` keeps a field; an empty `accountId` or
    /// `productionURL` clears it. A new row starts with the default provider and `project` = the company slug. Changing the
    /// provider clears the account ID and production URL unless new ones are given (they belong to the old provider).
    @discardableResult
    public func setHosting(companyId: String, by sender: Sender, provider: HostingProviderID? = nil, project: String? = nil,
                           accountId: String? = nil, productionURL: String? = nil, now: Date = Store.now()) throws -> HostingSettings {
        guard sender == .owner else { throw WorkError.forbidden(Self.hostingOwnerOnly) }
        return try writer.write { db in
            guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            var s = try HostingSettings.fetchOne(db, key: companyId)
                ?? HostingSettings(companyId: companyId, project: company.slug, updatedAt: now)
            if let provider, provider != s.provider {
                s.provider = provider
                s.accountId = nil
                s.productionURL = nil
            }
            if let project { s.project = project.trimmingCharacters(in: .whitespaces) }
            if let accountId {
                let v = accountId.trimmingCharacters(in: .whitespaces)
                s.accountId = v.isEmpty ? nil : v
            }
            if let productionURL {
                let v = productionURL.trimmingCharacters(in: .whitespaces)
                s.productionURL = v.isEmpty ? nil : v
            }
            s.updatedAt = now
            try s.validate()
            try s.save(db)
            return s
        }
    }

    /// An ops agent (a role whose pack template lists `set_deploy_config`) sets how a release is built and checked: the build
    /// command (nil: none), the output folder, the smoke requests and the expected text, all agent-written (redacted before
    /// they are stored). Creates the row with the default provider and `project` = the company slug when it is missing; the
    /// owner's fields are never touched.
    @discardableResult
    public func setDeployConfig(companyId: String, by agentId: String, build: String?, outputDir: String, smoke: [SmokeRequest],
                                expectText: String?, now: Date = Store.now()) throws -> HostingSettings {
        let build = try redact(build), expectText = try redact(expectText)
        let smoke = try smoke.map { r -> SmokeRequest in
            var r = r
            r.path = try redact(r.path)
            r.body = try redact(r.body)
            return r
        }
        return try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            guard catalog.template(role: agent.role, pack: company.packId).companyTools.contains("set_deploy_config") else {
                throw WorkError.forbidden("set_deploy_config is not available to your role")
            }
            var s = try HostingSettings.fetchOne(db, key: companyId)
                ?? HostingSettings(companyId: companyId, project: company.slug, updatedAt: now)
            s.build = build
            s.outputDir = outputDir.trimmingCharacters(in: .whitespaces)
            s.smoke = smoke
            s.expectText = expectText
            s.configuredById = agentId
            s.updatedAt = now
            try s.validate()
            try s.save(db)
            return s
        }
    }

    /// What the company still needs before it can deploy. The token counts as present when its secret is recorded and the
    /// vault, read without ever prompting, still has it (a read that would need the owner's permission counts as present:
    /// the value is there). `npmPresent` nil: look for `npm` on the PATH.
    public func hostingReadiness(companyId: String, vault: any SecretVault, npmPresent: Bool? = nil,
                                 adapters: HostingAdapters.Lookup = HostingAdapters.production) throws -> HostingReadiness {
        let settings = try hosting(companyId: companyId)
        let provider = settings?.provider ?? .default
        let tokenName = adapters(provider).tokenSecret
        var token = try secrets(companyId: companyId).contains { $0.name == tokenName }
        if token {
            do { token = try vault.nonInteractive().value(companyId: companyId, name: tokenName) != nil } catch SecretError.needsPermission {
                token = true
            } catch {
                token = false
            }
        }
        return HostingReadiness(configured: settings?.outputDir != nil, tokenPresent: token,
                                accountPresent: settings?.accountId != nil,
                                npmPresent: npmPresent ?? HostingReadiness.npmOnPath())
    }
}

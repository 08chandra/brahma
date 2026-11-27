import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

/// The Access Center: the card a `grant` ask becomes, approving it with the owner's scope and duration (the only approve path:
/// plain approve refuses grant asks), the ledger rows, revocation and the presets.
@MainActor @Suite(.scratch) struct AccessModelTests {
    @MainActor struct AccessWorld {
        let w: WorkWorld
        let access: AccessModel
        let env: SandboxEnvironment

        var store: Store { w.store }

        static func make() async throws -> AccessWorld {
            let w = try await WorkWorld.make()
            let env = SandboxEnvironment(userHome: try tempDir(), darwinUserTemp: nil, shell: "/bin/zsh")
            let access = w.model.access
            access.environment = env
            return AccessWorld(w: w, access: access, env: env)
        }

        /// `request_access` as the agent calls it, through the store.
        @discardableResult
        func request(_ kind: GrantKind = .webDomain, _ value: String = "docs.stripe.com", by agent: Agent? = nil, itemId: String? = nil,
                     scope: GrantScope? = nil, duration: GrantDuration? = nil) throws -> Ask {
            try store.requestAccess(companyId: w.company.id, agentId: (agent ?? w.eng).id, kind: kind, value: value,
                                    reason: "need the docs", itemId: itemId, scope: scope, duration: duration, environment: env).ask
        }
    }

    @Test func cardFromAskDefaultsToProposal() async throws {
        let a = try await AccessWorld.make()
        let item = try a.w.item("Stripe hooks")
        let ask = try a.request(.webDomain, "docs.stripe.com", itemId: item.id, scope: .role, duration: .always)
        let handles = [a.w.eng.id: "eng-1"]
        let card = try #require(AccessCard.make(ask: ask, handles: handles, itemKeys: [item.id: item.key], roles: [a.w.eng.id: "engineer"]))
        #expect(card.ref == ask.ref && card.kind == .webDomain && card.value == "docs.stripe.com")
        #expect(card.scope == .role, "the default scope is the agent's proposal")
        #expect(card.duration == .always, "the default duration comes from the payload")
        #expect(card.requester == "@eng-1" && card.itemKey == item.key && card.reason == "need the docs")
        #expect(card.riskLabel == "Low risk")
        #expect(card.availableScopes == GrantScope.allCases)
        #expect(card.sentence(scope: .role, duration: .always)
                == "Grants: web_domain docs.stripe.com to role engineer for always. Takes effect on the agent's next turn.")
        #expect(card.sentence(scope: .once, duration: .turn)
                == "Grants: web_domain docs.stripe.com to @eng-1's next turn for turn. Takes effect on the agent's next turn.")
        #expect(card.sentence(scope: .item, duration: .sprint).hasPrefix("Grants: web_domain docs.stripe.com to item \(item.key) for sprint."))

        // Without an item the ITEM scope is not offered, and an agent that named no scope or duration gets agent / sprint.
        let plain = try a.request(.networkDomain, "api.stripe.com")
        let plainCard = try #require(AccessCard.make(ask: plain, handles: handles, itemKeys: [:]))
        #expect(plainCard.scope == .agent && plainCard.duration == .sprint && plainCard.itemKey == nil)
        #expect(!plainCard.availableScopes.contains(.item))
        #expect(plainCard.riskLabel == "Medium risk")
        // Any other ask is not a card.
        let other = try a.w.ask(title: "Pick a name")
        #expect(AccessCard.make(ask: other, handles: handles, itemKeys: [:]) == nil)
    }

    @Test func approveCreatesGrantAndClearsCard() async throws {
        let a = try await AccessWorld.make()
        let ask = try a.request()
        await a.access.reload()
        #expect(a.access.cards.map(\.id) == [ask.id])
        await a.w.refresh()
        #expect(a.w.model.accessCards.map(\.id) == [ask.id], "the Inbox shows the same card")
        // Plain approve is refused for a grant ask: the card is THE approve path.
        let plain = await a.w.model.decide(askId: ask.id, approve: true)
        #expect(plain == nil && a.w.model.errorMessage?.contains("brahma access approve") == true)
        a.w.model.errorMessage = nil

        let grant = try #require(await a.access.approve(askId: ask.id, scope: .role, duration: .always, note: "docs only"))
        #expect(grant.scope == .role && grant.duration == .always && grant.scopeRef == "engineer" && grant.approvedBy == "owner")
        #expect(a.access.error == nil)
        #expect(a.access.cards.isEmpty)
        #expect(a.access.grants.map(\.ref) == [grant.ref])
        #expect(try a.store.ask(id: ask.id)?.status == .approved)
        #expect(try a.store.ask(id: ask.id)?.ownerNote == "docs only")
        #expect(a.w.model.work.inbox.isEmpty, "the Inbox refreshed after the approval")
    }

    @Test func denySendsReason() async throws {
        let a = try await AccessWorld.make()
        let ask = try a.request()
        await a.access.reload()
        #expect(await a.access.deny(askId: ask.id, reason: "not this sprint"))
        let decided = try #require(try a.store.ask(id: ask.id))
        #expect(decided.status == .rejected && decided.ownerNote == "not this sprint")
        #expect(a.access.cards.isEmpty)
        #expect(try a.store.grants(companyId: a.w.company.id, includeInactive: true).isEmpty)
        // A reason is required; the refusal sits on that card only and goes when the card goes.
        let again = try a.request(.webDomain, "docs.github.com")
        #expect(!(await a.access.deny(askId: again.id, reason: "  ")))
        #expect(a.access.cardErrors[again.id] != nil && a.access.error == nil)
        #expect(try a.store.ask(id: again.id)?.status == .pendingOwner)
        #expect(await a.access.deny(askId: again.id, reason: "no"))
        #expect(a.access.cardErrors.isEmpty)
    }

    /// The card names the item from `ask.itemId` even when the snapshot lacks the item (then by id), and a proposed scope the
    /// card cannot offer falls back to agent.
    @Test func itemScopeFollowsTheAsk() async throws {
        let a = try await AccessWorld.make()
        let item = try a.w.item("Stripe hooks")
        let ask = try a.request(.webDomain, "docs.stripe.com", itemId: item.id, scope: .item)
        let missing = try #require(AccessCard.make(ask: ask, handles: [:], itemKeys: [:]))
        #expect(missing.hasItem && missing.itemKey == item.id && missing.scope == .item)
        #expect(missing.availableScopes.contains(.item))
        var noItem = ask
        noItem.itemId = nil
        let fallback = try #require(AccessCard.make(ask: noItem, handles: [:], itemKeys: [:]))
        #expect(!fallback.hasItem && fallback.scope == .agent && !fallback.availableScopes.contains(.item))
    }

    /// The sandbox banner keys on the pinned sandbox-check alert reason only: a `sandbox-link` alert (or any other) does not light it.
    @Test func sandboxBannerKeysOnThePinnedReason() async throws {
        let a = try await AccessWorld.make()
        await a.w.refresh()
        #expect(a.w.model.sandboxBanner == nil)
        try EngineAlerts.raise(store: a.store, text: "a link where the sandbox expects a directory", now: Date(),
                               reason: "sandbox-link:\(a.w.company.id):123", companyId: a.w.company.id)
        await a.w.refresh()
        #expect(a.w.model.work.inbox.contains { $0.kind == .engineAlert })
        #expect(a.w.model.sandboxBanner == nil)
        try EngineAlerts.raise(store: a.store, text: "Sandbox check failed for claude 2.1.0", now: Date(),
                               reason: EngineAlerts.sandboxCheckReason, companyId: a.w.company.id)
        await a.w.refresh()
        #expect(a.w.model.sandboxBanner == "Sandbox check failed or pending for claude ? — see Inbox")
        // Acknowledging the alert clears it.
        let alert = try #require(a.w.model.work.inbox.first { $0.subjectId == EngineAlerts.askSubject(reason: EngineAlerts.sandboxCheckReason) })
        _ = await a.w.model.acknowledge(askId: alert.id)
        #expect(a.w.model.sandboxBanner == nil)
    }

    @Test func grantRowsText() async throws {
        let a = try await AccessWorld.make()
        let item = try a.w.item("Stripe hooks")
        let g1 = try a.store.approveAccess(askId: try a.request(.webDomain, "docs.stripe.com").id, scope: .role, duration: .always, environment: a.env, owner: .test)
        let g2 = try a.store.approveAccess(askId: try a.request(.networkDomain, "api.stripe.com", itemId: item.id).id,
                                           scope: .item, duration: .sprint, environment: a.env, owner: .test)
        let g3 = try a.store.approveAccess(askId: try a.request(.webDomain, "docs.github.com").id, scope: .once, duration: .turn, environment: a.env, owner: .test)
        _ = try a.store.consumeGrants(ids: [g1.id], turnId: "t-1", now: Date(timeIntervalSince1970: 1_800_000_000))
        await a.access.reload()
        let rows = a.access.grants
        #expect(rows.map(\.ref) == [g1.ref, g2.ref, g3.ref])
        #expect(rows[0].kind == "web_domain" && rows[0].value == "docs.stripe.com" && rows[0].scopeText == "role engineer")
        #expect(rows[0].expiresText == "never" && rows[0].approvedBy == "owner")
        #expect(rows[0].uses == "1" && rows[0].lastUsed != "never")
        #expect(rows[1].scopeText == "item \(item.key)")
        // No active sprint: a sprint grant runs for 7 active days from approval, and the company has not run yet.
        #expect(rows[1].expiresText == "in 7d 0h active", Comment(rawValue: rows[1].expiresText))
        #expect(rows[2].scopeText == "@eng-1's next turn" && rows[2].expiresText == "after 1 use")
        #expect(rows[2].uses == "0" && rows[2].lastUsed == "never")
        #expect(rows.allSatisfy { $0.isActive })
        // The ledger row of the activity feed is not the row here; the sentence for an expired grant reads "expired".
        #expect(GrantRow.expiryText(expiresActive: 100, activeNow: 100) == "expired")
        #expect(GrantRow.expiryText(expiresActive: 100 + 3 * 3600 + 120, activeNow: 100) == "in 3h 2m active")
    }

    @Test func revokeHidesFromActive() async throws {
        let a = try await AccessWorld.make()
        let grant = try a.store.approveAccess(askId: try a.request().id, scope: .agent, duration: .always, environment: a.env, owner: .test)
        await a.access.reload()
        #expect(a.access.grants.count == 1)
        #expect(a.access.revokeConfirmation(a.access.grants[0]) == "Revoke \(grant.ref)? It stops at the agent's next turn.")
        #expect(await a.access.revoke(number: grant.number))
        #expect(a.access.grants.isEmpty, "revoked grants leave the active list")
        a.access.showInactive = true
        await a.access.reload()
        #expect(a.access.grants.count == 1)
        #expect(!a.access.grants[0].isActive && a.access.grants[0].expiresText == "revoked by owner")
        #expect(try a.store.grants(companyId: a.w.company.id).isEmpty)
        // Revoking again is refused with the store's reason; the next good reload clears it.
        #expect(!(await a.access.revoke(number: grant.number)))
        #expect(a.access.error?.contains("already revoked") == true)
        await a.access.reload()
        #expect(a.access.error == nil)
    }

    @Test func presetToggle() async throws {
        let a = try await AccessWorld.make()
        await a.access.reload()
        #expect(a.access.presets.isEmpty)
        #expect(AccessModel.presetsCaption == "Money, outbound messages, secrets and terminations always ask you.")
        await a.access.setPreset(.readOnlyWebForEngineers, enabled: true)
        #expect(a.access.presets == [.readOnlyWebForEngineers])
        #expect(try a.store.enabledPresets(companyId: a.w.company.id) == [.readOnlyWebForEngineers])
        // With the preset on, an engineer's docs request is approved at once and never reaches the Inbox.
        let ask = try a.request(.webDomain, "docs.github.com")
        #expect(ask.status == .approved && ask.decidedBy == "preset:readonly-web-engineers")
        await a.access.reload()
        #expect(a.access.cards.isEmpty && a.access.grants.count == 1 && a.access.grants[0].approvedBy == "preset:readonly-web-engineers")
        await a.access.setPreset(.readOnlyWebForEngineers, enabled: false)
        #expect(a.access.presets.isEmpty)
        #expect(AccessModel.presetRows.map(\.preset) == [.readOnlyWebForEngineers, .autoModeLowRisk])
    }
}

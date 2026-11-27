import Foundation
import Observation
import BrahmaCore

/// The Inbox card of a `grant` ask (`request_access`). The agent's proposal only sets the defaults: the owner picks the scope
/// and duration, and `Store.approveAccess` is the one approve path (plain approve refuses a grant ask). Every agent string is
/// shown with `Text(verbatim:)`.
public struct AccessCard: Equatable, Identifiable, Sendable {
    public var id: String
    /// "A-12".
    public var ref: String
    public var kind: GrantKind
    /// The normalized domain pattern or the resolved path (monospace).
    public var value: String
    /// "@eng-1".
    public var requester: String
    /// The item's key (or its id when the key is not in the snapshot); nil when the ask names no item.
    public var itemKey: String?
    public var reason: String
    public var risk: AskRisk
    /// "Low risk", "Medium risk", "High risk".
    public var riskLabel: String
    /// The agent's proposed scope (the segmented control's default).
    public var scope: GrantScope
    /// The agent's requested duration (the segmented control's default).
    public var duration: GrantDuration
    /// The requester's role, for the ROLE scope's text.
    public var role: String?

    public var hasItem: Bool { itemKey != nil }
    /// `ONCE · ITEM · AGENT · ROLE · COMPANY`; ITEM only with an item.
    public var availableScopes: [GrantScope] { GrantScope.allCases.filter { $0 != .item || hasItem } }
    public var isWildcard: Bool { value.hasPrefix("*.") }

    /// Nil for any ask that is not an access request.
    public static func make(ask: Ask, handles: [String: String], itemKeys: [String: String], roles: [String: String] = [:]) -> AccessCard? {
        guard ask.kind == .grant, let requested = Grants.requested(ask) else { return nil }
        var scope = ask.proposedGrant.flatMap { GrantScope(rawValue: $0.scope) } ?? .agent
        // An item scope is offered only with an item (`ask.itemId`, whether or not the snapshot holds the item).
        if scope == .item, ask.itemId == nil { scope = .agent }
        let requester = ask.requesterId == "system" ? "Brahma" : "@" + (handles[ask.requesterId] ?? "?")
        return AccessCard(id: ask.id, ref: ask.ref, kind: requested.kind, value: requested.value, requester: requester,
                          itemKey: ask.itemId.map { itemKeys[$0] ?? $0 }, reason: ask.summary, risk: ask.risk,
                          riskLabel: InboxRows.riskLabel(ask.risk), scope: scope, duration: requested.duration,
                          role: roles[ask.requesterId])
    }

    /// Who a scope grants to, in words: "@eng-1's next turn", "item INITE-2", "@eng-1", "role engineer", "the company".
    public func scopeText(_ scope: GrantScope) -> String {
        switch scope {
        case .once: "\(requester)'s next turn"
        case .item: "item \(itemKey ?? "?")"
        case .agent: requester
        case .role: "role \(role ?? "of the requester")"
        case .company: "the company"
        }
    }

    public func sentence(scope: GrantScope, duration: GrantDuration) -> String {
        "Grants: \(kind.rawValue) \(value) to \(scopeText(scope)) for \(duration.rawValue). Takes effect on the agent's next turn."
    }
}

/// One row of the Inbox › Grants ledger.
public struct GrantRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var number: Int
    /// "G-3".
    public var ref: String
    public var kind: String
    public var value: String
    public var scopeText: String
    /// "never", "in 6d 23h active", "end of Sprint 2", "after 1 use", "used", "expired", "revoked by owner".
    public var expiresText: String
    /// "owner" or "preset:<id>".
    public var approvedBy: String
    public var uses: String
    public var lastUsed: String
    public var isActive: Bool

    /// Company-active time left, in words.
    static func activeText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let days = total / 86_400, hours = (total % 86_400) / 3600, minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    public static func expiryText(expiresActive: Double, activeNow: Double) -> String {
        let left = expiresActive - activeNow
        return left <= 0 ? "expired" : "in \(activeText(left)) active"
    }

    public static func make(_ g: Grant, handles: [String: String], itemKeys: [String: String], activeNow: Double,
                            sprintNames: [String: String], activeSprints: Set<String>, timeZone: TimeZone) -> GrantRow {
        let requester = g.requesterId.flatMap { handles[$0] }.map { "@" + $0 } ?? "the requester"
        let scope: String
        switch g.scope {
        case .once: scope = "\(requester)'s next turn"
        case .agent: scope = requester
        case .item: scope = "item \(g.scopeRef.flatMap { itemKeys[$0] } ?? "?")"
        case .role: scope = "role \(g.scopeRef ?? "?")"
        case .company: scope = "the company"
        }
        let live = GrantResolver.isLive(g, activeNow: activeNow, sprintActive: activeSprints.contains)
        let expires: String
        if let by = g.revokedBy, g.revokedAt != nil {
            expires = "revoked by \(by)"
        } else if let uses = g.usesLeft, uses <= 0 {
            expires = "used"
        } else if let at = g.expiresActive {
            expires = expiryText(expiresActive: at, activeNow: activeNow)
        } else if let sprint = g.sprintId {
            expires = activeSprints.contains(sprint) ? "end of \(sprintNames[sprint] ?? "the sprint")" : "sprint ended"
        } else if let uses = g.usesLeft {
            expires = "after \(uses) use"
        } else {
            expires = "never"
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return GrantRow(id: g.id, number: g.number, ref: g.ref, kind: g.kind.rawValue, value: g.value, scopeText: scope,
                        expiresText: expires, approvedBy: g.approvedBy, uses: "\(g.useCount)",
                        lastUsed: g.lastUsedAt.map(f.string(from:)) ?? "never", isActive: live)
    }
}

/// One access preset switch of the Grants screen.
public struct PresetRow: Equatable, Identifiable, Sendable {
    public var preset: AccessPreset
    public var title: String
    public var detail: String
    public var id: String { preset.rawValue }
}

/// Inbox › Grants and the access cards: the open access asks of the selected company, the ledger, and the presets. Every
/// store call runs off the main actor; a refused one puts its reason in `error`.
@MainActor @Observable
public final class AccessModel {
    public static let presetsCaption = "Money, outbound messages, secrets and terminations always ask you."
    public static let presetRows = [
        PresetRow(preset: .readOnlyWebForEngineers, title: "Read-only web for engineers",
                  detail: "Engineers, QA, devops, security and architects may read well-known documentation sites (exact hosts, for the role, always)."),
        PresetRow(preset: .autoModeLowRisk, title: "Auto mode: low-risk web",
                  detail: "Under the Auto autonomy preset, a low-risk web read is approved for the requester for the sprint."),
    ]

    public private(set) var cards: [AccessCard] = []
    public private(set) var grants: [GrantRow] = []
    public private(set) var presets: Set<AccessPreset> = []
    /// Lists revoked, used and expired grants too.
    public var showInactive = false
    /// The last refusal of a ledger or preset action; cleared by the next successful reload or action.
    public private(set) var error: String?
    /// The last refusal of an approve or deny, by ask id (shown on that card only).
    public private(set) var cardErrors: [String: String] = [:]
    public var companyId: String?
    @ObservationIgnored private let store: Store
    /// The owner's machine as grant values are checked against it (tests inject a temp home).
    @ObservationIgnored public var environment: SandboxEnvironment = .owner
    /// Runs after a change that the Inbox must pick up (the app model's snapshot refresh).
    @ObservationIgnored public var afterChange: (@MainActor () async -> Void)?

    /// The owner principal every owner-only call here takes (final wave B1); nil: each refuses with the generic text.
    @ObservationIgnored public var owner: OwnerPrincipal?

    public init(store: Store, owner: OwnerPrincipal? = nil) {
        self.store = store
        self.owner = owner
    }

    public func revokeConfirmation(_ row: GrantRow) -> String { "Revoke \(row.ref)? It stops at the agent's next turn." }

    /// Rereads the cards, ledger and presets; a good read clears the last ledger refusal (card refusals go with their cards).
    public func reload() async { await reload(keepingError: false) }

    private func reload(keepingError: Bool) async {
        guard let companyId else { cards = []; grants = []; presets = []; return }
        let (store, inactive) = (self.store, showInactive)
        struct Read: Sendable { var cards: [AccessCard]; var grants: [GrantRow]; var presets: Set<AccessPreset> }
        do {
            let read: Read = try await Task.detached {
                let agents = try store.agents(companyId: companyId)
                let handles = Dictionary(agents.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                let roles = Dictionary(agents.map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })
                let items = Dictionary(try store.workItems(companyId: companyId, filter: WorkItemFilter(limit: 5000)).map { ($0.id, $0.key) },
                                       uniquingKeysWith: { a, _ in a })
                let asks = try store.asks(companyId: companyId, statuses: [.pendingOwner]).filter { $0.kind == .grant }
                let cards = asks.compactMap { AccessCard.make(ask: $0, handles: handles, itemKeys: items, roles: roles) }
                let sprints = try store.sprints(companyId: companyId)
                let names = Dictionary(sprints.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
                let active = Set(sprints.filter { $0.status == .active }.map(\.id))
                let now = store.activeNow(companyId: companyId)
                let tz = store.ownerTimeZone()
                let rows = try store.grants(companyId: companyId, includeInactive: inactive).map {
                    GrantRow.make($0, handles: handles, itemKeys: items, activeNow: now, sprintNames: names, activeSprints: active, timeZone: tz)
                }
                return Read(cards: cards, grants: rows, presets: try store.enabledPresets(companyId: companyId))
            }.value
            cards = read.cards
            grants = read.grants
            presets = read.presets
            if !keepingError { error = nil }
            cardErrors = cardErrors.filter { id, _ in read.cards.contains { $0.id == id } }
        } catch {
            self.error = "\(error)"
        }
    }

    /// The owner's approval with the scope and duration they chose (`Store.approveAccess`, through `ownerDecide`).
    @discardableResult
    public func approve(askId: String, scope: GrantScope, duration: GrantDuration, note: String = "") async -> Grant? {
        let (store, env, owner) = (self.store, environment, self.owner)
        let grant = await run("approve", askId: askId) {
            try store.approveAccess(askId: askId, scope: scope, duration: duration, note: note, environment: env,
                                    owner: try store.requireOwner(owner))
        }
        await changed()
        return grant
    }

    /// Rejects the ask with the reason the agent will read (required).
    @discardableResult
    public func deny(askId: String, reason: String) async -> Bool {
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty else { cardErrors[askId] = "Say why: the agent reads the reason."; return false }
        let (store, owner) = (self.store, self.owner)
        let ask = await run("deny", askId: askId) {
            try store.ownerDecide(askId: askId, approve: false, note: why, owner: try store.requireOwner(owner))
        }
        await changed()
        return ask != nil
    }

    @discardableResult
    public func revoke(number: Int) async -> Bool {
        guard let companyId else { return false }
        let store = self.store
        let grant = await run("revoke") { try store.revokeGrant(companyId: companyId, number: number) }
        await changed()
        return grant != nil
    }

    public func setPreset(_ preset: AccessPreset, enabled: Bool) async {
        guard let companyId else { return }
        let (store, owner) = (self.store, self.owner)
        _ = await run("change the preset") {
            try store.setPreset(companyId: companyId, preset, enabled: enabled, owner: try store.requireOwner(owner))
        }
        await reload(keepingError: true)
    }

    private func changed() async {
        await reload(keepingError: true)
        await afterChange?()
    }

    /// Runs one store call off the main actor. A refusal goes to `cardErrors[askId]` when an ask is named, else to `error`.
    private func run<T: Sendable>(_ what: String, askId: String? = nil, _ body: @escaping @Sendable () throws -> T) async -> T? {
        func fail(_ message: String) {
            if let askId { cardErrors[askId] = message } else { error = message }
        }
        do {
            let value = try await Task.detached { try body() }.value
            if let askId { cardErrors[askId] = nil } else { error = nil }
            return value
        } catch let e as WorkError {
            fail(e.message)
        } catch {
            fail("Couldn't \(what): \(error)")
        }
        return nil
    }
}

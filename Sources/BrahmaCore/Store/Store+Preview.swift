import Foundation
import GRDB

/// What `set_preview_command` and `brahma preview set` hand the store: the agent-written fields of a surface, with the smoke
/// requests still as text (`SmokeRequest.parse` is the one validator for them).
public struct PreviewDraft: Equatable, Sendable {
    public var name: String
    public var kind: String
    public var run: String?
    public var url: String?
    public var build: String?
    public var smoke: [String]
    /// Plan 4a's fields (agent-written; validated with the surface).
    public var demo: String?
    public var openapiPath: String?
    public var appPath: String?
    public var bundleId: String?
    public var device: String?

    public init(name: String, kind: String = PreviewKind.web.rawValue, run: String?, url: String?, build: String? = nil, smoke: [String] = [],
                demo: String? = nil, openapiPath: String? = nil, appPath: String? = nil, bundleId: String? = nil, device: String? = nil) {
        self.name = name; self.kind = kind; self.run = run; self.url = url; self.build = build; self.smoke = smoke
        self.demo = demo; self.openapiPath = openapiPath; self.appPath = appPath; self.bundleId = bundleId; self.device = device
    }
}

extension Store {
    static let previewCapMessage = "a company can have at most \(PreviewSurface.maxPerCompany) previews"
    static let previewRestartForbidden = "only the owner or the agent who set a preview may restart it"
    static let noSuchPreview = "no such preview"

    /// Who may change or remove an existing surface: the owner, or the agent who set it. An owner-set surface is immutable to
    /// every agent (including whoever set it before the owner took it over); agents propose a change via an ask.
    static func checkMayChange(_ db: Database, _ surface: PreviewSurface, actor: String) throws {
        guard actor != "owner", actor != surface.setById else { return }
        if surface.setById == "owner" {
            throw WorkError.forbidden("preview \(surface.name) was set by the owner; propose a change with request_from_owner")
        }
        let setter = (try Agent.fetchOne(db, key: surface.setById))?.name ?? surface.setById
        throw WorkError.forbidden("only the owner or @\(setter) may change or remove preview \(surface.name); propose the change with request_from_owner")
    }

    /// The sender's id when it may act on `companyId`: the owner, or an agent of that company that is not killed. Any other
    /// agent (or `.system`) is `WorkError.forbidden("not in your company")` (cross-company ids).
    static func previewActor(_ db: Database, companyId: String, by: Sender) throws -> String {
        switch by {
        case .owner: return "owner"
        case .system: throw WorkError.forbidden("not in your company")
        case .agent(let id):
            guard let agent = try Agent.fetchOne(db, key: id), agent.companyId == companyId, agent.state != .killed else {
                throw WorkError.forbidden("not in your company")
            }
            return agent.id
        }
    }

    /// Creates or replaces the surface named `draft.name` in the company (one row per name, `UNIQUE(companyId, name)`): a new
    /// one takes the next position and an idle state row; an existing one (changed only by the owner or its setter,
    /// `checkMayChange`) keeps its id and position, takes the new fields and setter, and is asked to restart (`restartRequestedAt`). The draft is validated as a `PreviewSurface` (its messages) after
    /// each smoke line is parsed. The ninth surface is refused with `"a company can have at most 8 previews"`. Every command,
    /// URL, smoke line, path, bundle id and device is agent text: redacted before it is stored. Returns the stored surface.
    ///
    /// The owner's Simulator approval (Plan 4a fix 4) belongs to the exact iOS build it was asked for: a change of the kind,
    /// `build`, `appPath` or `bundleId` clears `outsideSandboxApprovedAt` and `outsideSandboxAskId` (a still-open ask for the
    /// old build is `superseded`), so the engine asks again. A set with unchanged values keeps an open ask or a standing
    /// approval, but drops an ask that was closed without one (rejected, expired, superseded, rescinded): the engine then files
    /// one fresh ask (fix round 1, I2). Nothing here ever sets either field.
    public func upsertPreviewSurface(companyId: String, by: Sender, _ draft: PreviewDraft, now: Date = Store.now()) throws -> PreviewSurface {
        let smoke = try draft.smoke.map { try SmokeRequest.parse(try redact($0)) }
        func field(_ s: String?) throws -> String? {
            try redact(s?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        }
        let build = try field(draft.build)
        let run = try redact(draft.run), url = try redact(draft.url?.trimmingCharacters(in: .whitespaces))
        let demo = try field(draft.demo), openapiPath = try field(draft.openapiPath), appPath = try field(draft.appPath)
        let bundleId = try field(draft.bundleId), device = try field(draft.device)
        return try writer.write { db in
            let actor = try Self.previewActor(db, companyId: companyId, by: by)
            let existing = try PreviewSurface.filter(Column("companyId") == companyId && Column("name") == draft.name).fetchOne(db)
            var surface: PreviewSurface
            if var current = existing {
                try Self.checkMayChange(db, current, actor: actor)
                if current.kind != draft.kind || current.build != build || current.appPath != appPath || current.bundleId != bundleId {
                    try Self.supersedeSimulatorAsk(db, surface: current, now: now)
                    current.outsideSandboxAskId = nil
                    current.outsideSandboxApprovedAt = nil
                } else if let askId = current.outsideSandboxAskId {
                    let ask = try Ask.fetchOne(db, key: askId)
                    let stands = ask.map { $0.status.isPending || ($0.status == .approved && current.outsideSandboxApprovedAt != nil) } ?? false
                    if !stands {
                        current.outsideSandboxAskId = nil
                        current.outsideSandboxApprovedAt = nil
                    }
                }
                current.kind = draft.kind; current.build = build; current.run = run; current.url = url; current.smoke = smoke
                current.demo = demo; current.openapiPath = openapiPath; current.appPath = appPath; current.bundleId = bundleId
                current.device = device
                current.setById = actor; current.updatedAt = now
                surface = current
            } else {
                let positions = try Int.fetchAll(db, PreviewSurface.filter(Column("companyId") == companyId).select(Column("position")))
                guard positions.count < PreviewSurface.maxPerCompany else { throw WorkError.conflict(Self.previewCapMessage) }
                // Lowercase ids: run ids carry them, and APFS is case-insensitive (two ids differing in case would collide).
                surface = PreviewSurface(id: UUID().uuidString.lowercased(), companyId: companyId, name: draft.name, kind: draft.kind,
                                         position: (positions.max() ?? -1) + 1, build: build, run: run, url: url, smoke: smoke,
                                         setById: actor, createdAt: now, updatedAt: now, demo: demo, openapiPath: openapiPath,
                                         appPath: appPath, bundleId: bundleId, device: device)
            }
            try surface.validate()
            if existing == nil {
                try surface.insert(db)
                try PreviewState(surfaceId: surface.id, companyId: companyId, status: .idle, updatedAt: now).insert(db)
            } else {
                try surface.update(db)
                if var state = try PreviewState.fetchOne(db, key: surface.id) {
                    state.restartRequestedAt = now; state.updatedAt = now
                    try state.update(db)
                } else {
                    try PreviewState(surfaceId: surface.id, companyId: companyId, status: .idle, restartRequestedAt: now, updatedAt: now).insert(db)
                }
            }
            try Self.recordPreviewEvent(db, companyId: companyId, actor: actor, text: "\(existing == nil ? "set" : "updated") preview \(surface.name) (\(surface.kind))", now: now)
            return surface
        }
    }

    /// Removes the surface named `name` (its state row cascades); the engine stops its process on its next pass. The owner or
    /// the agent who set it (`checkMayChange`); `"no preview named <name>"` when there is none. Returns the removed surface.
    @discardableResult
    public func removePreviewSurface(companyId: String, name: String, by: Sender, now: Date = Store.now()) throws -> PreviewSurface {
        try writer.write { db in
            let actor = try Self.previewActor(db, companyId: companyId, by: by)
            guard let surface = try PreviewSurface.filter(Column("companyId") == companyId && Column("name") == name).fetchOne(db) else {
                throw WorkError.notFound("no preview named \(Self.flat(name, max: 40))")
            }
            try Self.checkMayChange(db, surface, actor: actor)
            try Self.supersedeSimulatorAsk(db, surface: surface, now: now)
            try surface.delete(db)
            try Self.recordPreviewEvent(db, companyId: companyId, actor: actor, text: "removed preview \(surface.name)", now: now)
            return surface
        }
    }

    /// The company's surfaces, in position order.
    public func previewSurfaces(companyId: String) throws -> [PreviewSurface] {
        try writer.read { db in
            try PreviewSurface.filter(Column("companyId") == companyId).order(Column("position"), Column("name")).fetchAll(db)
        }
    }

    /// One surface by id, in `companyId` only.
    public func previewSurface(companyId: String, id: String) throws -> PreviewSurface? {
        try writer.read { db in try PreviewSurface.filter(Column("companyId") == companyId && Column("id") == id).fetchOne(db) }
    }

    /// The company's states, by surface id.
    public func previewStates(companyId: String) throws -> [String: PreviewState] {
        try writer.read { db in
            Dictionary(try PreviewState.filter(Column("companyId") == companyId).fetchAll(db).map { ($0.surfaceId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Every state that records a port, with the surface it belongs to and its company's slug (the port rule,
    /// `PortAllocator.port(for:store:)`).
    func previewPortHolders() throws -> [PreviewPortHolder] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT s.surfaceId, s.companyId, s.port, s.status, p.name, c.slug
                FROM previewState s JOIN previewSurface p ON p.id = s.surfaceId JOIN company c ON c.id = s.companyId
                WHERE s.port IS NOT NULL
                """).map { row in
                PreviewPortHolder(surfaceId: row["surfaceId"], companyId: row["companyId"], companySlug: row["slug"], name: row["name"],
                                  port: row["port"], status: PreviewStatus(rawValue: row["status"]) ?? .unavailable)
            }
        }
    }

    /// Writes the engine's record of a surface's process (insert or replace by surface id).
    public func savePreviewState(_ state: PreviewState) throws {
        try writer.write { db in try state.save(db) }
    }

    /// The engine's read-modify-write of one surface's state, in one transaction, so a flag the owner or an agent set meanwhile
    /// (`restartRequestedAt`) is never lost and a recorded port is reserved in the same write that records the start. A
    /// missing state row is created (idle); nil when the surface itself is gone (nothing written).
    @discardableResult
    func updatePreviewState(surfaceId: String, now: Date, _ body: @escaping (inout PreviewState) -> Void) throws -> PreviewState? {
        try writer.write { db in
            guard let surface = try PreviewSurface.fetchOne(db, key: surfaceId) else { return nil }
            var state = try PreviewState.fetchOne(db, key: surfaceId)
                ?? PreviewState(surfaceId: surfaceId, companyId: surface.companyId, status: .idle, updatedAt: now)
            body(&state)
            state.updatedAt = now
            try state.save(db)
            return state
        }
    }

    /// Records a building, starting or running surface as `stopped` with `message` (no pid, no URL); any other state is left.
    func markPreviewStopped(surfaceId: String, message: String, now: Date) throws {
        try writer.write { db in
            guard var state = try PreviewState.fetchOne(db, key: surfaceId),
                  [.building, .starting, .running].contains(state.status) else { return }
            state.status = .stopped; state.message = message; state.pid = nil; state.resolvedURL = nil; state.updatedAt = now
            try state.update(db)
        }
    }

    /// Asks the engine to restart a surface: the owner, or the agent who set it (`"only the owner or the agent who set a
    /// preview may restart it"`); an agent of another company sees `"not in your company"`; an unknown id `"no such preview"`.
    public func requestPreviewRestart(surfaceId: String, by: Sender, now: Date = Store.now()) throws {
        try writer.write { db in
            guard let surface = try PreviewSurface.fetchOne(db, key: surfaceId) else { throw WorkError.notFound(Self.noSuchPreview) }
            let actor = try Self.previewActor(db, companyId: surface.companyId, by: by)
            guard actor == "owner" || actor == surface.setById else { throw WorkError.forbidden(Self.previewRestartForbidden) }
            var state = try PreviewState.fetchOne(db, key: surfaceId)
                ?? PreviewState(surfaceId: surfaceId, companyId: surface.companyId, status: .idle, updatedAt: now)
            state.restartRequestedAt = now; state.updatedAt = now
            try state.save(db)
            try Self.recordPreviewEvent(db, companyId: surface.companyId, actor: actor, text: "requested a restart of preview \(surface.name)", now: now)
        }
    }

    // MARK: The iOS owner gate (Plan 4a fix 4)

    /// The engine's owner ask for an iOS surface without the owner's approval: the one it filed (whatever its status now),
    /// or, when none is recorded, a new one filed by the system straight to the owner (`other`, `permissions` — a reserved
    /// matter no preset approves — risk high, `SimulatorApproval`'s title and summary), recorded on the surface in the same
    /// transaction. Nil when the surface is gone, not iOS, or already approved. Called only by the engine's runner, on every
    /// pass: a recorded ask is only read (no write transaction).
    @discardableResult
    func requestSimulatorApproval(surfaceId: String, now: Date) throws -> Ask? {
        enum Seen { case answer(Ask?), file }
        let seen: Seen = try writer.read { db in
            guard let surface = try PreviewSurface.fetchOne(db, key: surfaceId), surface.previewKind == .ios,
                  surface.outsideSandboxApprovedAt == nil else { return .answer(nil) }
            if let id = surface.outsideSandboxAskId, let ask = try Ask.fetchOne(db, key: id), ask.companyId == surface.companyId {
                return .answer(ask)
            }
            return .file
        }
        if case .answer(let ask) = seen { return ask }
        return try writer.write { db in
            guard var surface = try PreviewSurface.fetchOne(db, key: surfaceId), surface.previewKind == .ios,
                  surface.outsideSandboxApprovedAt == nil else { return nil }
            if let id = surface.outsideSandboxAskId, let ask = try Ask.fetchOne(db, key: id), ask.companyId == surface.companyId { return ask }
            let ask = try propose(db: db, companyId: surface.companyId, by: .system, kind: .other, risk: .high,
                                  category: SimulatorApproval.category, title: SimulatorApproval.title(surface.name),
                                  summary: SimulatorApproval.summary, payload: nil, document: nil, itemId: nil,
                                  subjectId: SimulatorApproval.subjectPrefix + surface.id, supersedes: nil, requestId: nil,
                                  decisionClass: .taste, viaOwner: true, now: now)
            surface.outsideSandboxAskId = ask.id
            try surface.update(db)
            return ask
        }
    }

    /// The engine's Simulator ask for `ask`, when it is one: filed by the system, `other`/`permissions`, and recorded on an
    /// iOS surface of the same company as that surface's ask. An agent's look-alike ask is never one.
    static func simulatorSurface(_ db: Database, ask: Ask) throws -> PreviewSurface? {
        guard ask.kind == .other, ask.requesterId == "system", ask.category == SimulatorApproval.category,
              ask.subjectId?.hasPrefix(SimulatorApproval.subjectPrefix) == true,
              let surface = try PreviewSurface.filter(Column("companyId") == ask.companyId && Column("outsideSandboxAskId") == ask.id).fetchOne(db),
              surface.previewKind == .ios else { return nil }
        return surface
    }

    /// `applyAskEffects` of the engine's Simulator ask: approved by the owner (`decidedBy == "owner"`, never a policy or a
    /// preset) sets `outsideSandboxApprovedAt` and flags a restart, so the runner's next pass starts it. Any other outcome
    /// changes nothing (the runner reports a declined ask).
    func applySimulatorApprovalEffects(_ db: Database, ask: Ask, now: Date) throws {
        guard ask.status == .approved, ask.decidedBy == "owner", var surface = try Self.simulatorSurface(db, ask: ask),
              surface.outsideSandboxApprovedAt == nil else { return }
        surface.outsideSandboxApprovedAt = now
        try surface.update(db)
        try Self.flagPreviewRestart(db, surface: surface, now: now)
        try ActivityEvent(companyId: surface.companyId, agentId: nil, turnId: nil, kind: .preview,
                          text: "owner allowed the iOS Simulator preview \(surface.name) (\(ask.ref))", createdAt: now).insert(db)
    }

    /// `reverseAskEffects` of the engine's Simulator ask (the owner rescinded it): the approval is gone; the runner stops it.
    func reverseSimulatorApproval(_ db: Database, ask: Ask, now: Date) throws {
        guard var surface = try Self.simulatorSurface(db, ask: ask), surface.outsideSandboxApprovedAt != nil else { return }
        surface.outsideSandboxApprovedAt = nil
        try surface.update(db)
        try Self.flagPreviewRestart(db, surface: surface, now: now)
        try ActivityEvent(companyId: surface.companyId, agentId: nil, turnId: nil, kind: .preview,
                          text: "owner withdrew the iOS Simulator preview \(surface.name) (\(ask.ref))", createdAt: now).insert(db)
    }

    /// The surface's still-open Simulator ask, `superseded` (its build changed or the surface is removed).
    static func supersedeSimulatorAsk(_ db: Database, surface: PreviewSurface, now: Date) throws {
        guard let id = surface.outsideSandboxAskId, var ask = try Ask.fetchOne(db, key: id), ask.companyId == surface.companyId,
              ask.status.isPending else { return }
        ask.status = .superseded
        ask.statusSinceActive = try Store.activeNow(db: db, companyId: ask.companyId)
        ask.updatedAt = now
        try ask.update(db)
    }

    static func flagPreviewRestart(_ db: Database, surface: PreviewSurface, now: Date) throws {
        var state = try PreviewState.fetchOne(db, key: surface.id)
            ?? PreviewState(surfaceId: surface.id, companyId: surface.companyId, status: .idle, updatedAt: now)
        state.restartRequestedAt = now; state.updatedAt = now
        try state.save(db)
    }

    /// One `preview` activity line (`@handle <text>`, or `owner <text>`); the surface name is a validated safe token.
    static func recordPreviewEvent(_ db: Database, companyId: String, actor: String, text: String, now: Date) throws {
        let who = actor == "owner" ? "owner" : "@" + ((try Agent.fetchOne(db, key: actor))?.name ?? actor)
        try ActivityEvent(companyId: companyId, agentId: actor == "owner" ? nil : actor, turnId: nil, kind: .preview,
                          text: "\(who) \(text)", createdAt: now).insert(db)
    }
}

/// A recorded preview port: whose it is, and whether that surface still holds it: only while it is building, starting or
/// running (deferred minor 4: a failed, idle, stopped or unavailable surface's port is only skipped by `allocate`).
struct PreviewPortHolder: Equatable, Sendable {
    var surfaceId: String
    var companyId: String
    var companySlug: String
    var name: String
    var port: Int
    var status: PreviewStatus

    var holds: Bool { [.building, .starting, .running].contains(status) }
}

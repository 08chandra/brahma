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

    public init(name: String, kind: String = PreviewKind.web.rawValue, run: String?, url: String?, build: String? = nil, smoke: [String] = []) {
        self.name = name; self.kind = kind; self.run = run; self.url = url; self.build = build; self.smoke = smoke
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
    /// URL and smoke line is agent text: redacted before it is stored. Returns the stored surface.
    public func upsertPreviewSurface(companyId: String, by: Sender, _ draft: PreviewDraft, now: Date = Store.now()) throws -> PreviewSurface {
        let smoke = try draft.smoke.map { try SmokeRequest.parse(try redact($0)) }
        let build = try redact(draft.build?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let run = try redact(draft.run), url = try redact(draft.url?.trimmingCharacters(in: .whitespaces))
        return try writer.write { db in
            let actor = try Self.previewActor(db, companyId: companyId, by: by)
            let existing = try PreviewSurface.filter(Column("companyId") == companyId && Column("name") == draft.name).fetchOne(db)
            var surface: PreviewSurface
            if var current = existing {
                try Self.checkMayChange(db, current, actor: actor)
                current.kind = draft.kind; current.build = build; current.run = run; current.url = url; current.smoke = smoke
                current.setById = actor; current.updatedAt = now
                surface = current
            } else {
                let positions = try Int.fetchAll(db, PreviewSurface.filter(Column("companyId") == companyId).select(Column("position")))
                guard positions.count < PreviewSurface.maxPerCompany else { throw WorkError.conflict(Self.previewCapMessage) }
                // Lowercase ids: run ids carry them, and APFS is case-insensitive (two ids differing in case would collide).
                surface = PreviewSurface(id: UUID().uuidString.lowercased(), companyId: companyId, name: draft.name, kind: draft.kind,
                                         position: (positions.max() ?? -1) + 1, build: build, run: run, url: url, smoke: smoke,
                                         setById: actor, createdAt: now, updatedAt: now)
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

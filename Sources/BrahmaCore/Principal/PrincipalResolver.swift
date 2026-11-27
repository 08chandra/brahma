import Foundation
import GRDB

/// Resolves an action's subject principals from the engine's records (spec §6.2.3), once per action, at the action's start;
/// the set is passed down and nothing below re-reads roles or leases.
///
/// - Total: never throws and never returns an empty set. Every failed lookup (a read that throws, a missing row, a missing
///   setter, an id that is neither `"owner"` nor an agent of the company) becomes an `.unknown(reason)` member, and an
///   `.unknown` member is never Full.
/// - Company-scoped: the action's root record (the run, the surface, the release) is read by its own id and names the
///   company; every lookup after it is `WHERE companyId = ?` with that company (an agent, lease or item of another company
///   is not this company's principal).
/// - The engine ceiling (`brahma run --profile`) narrows every profile it reports: the owner's (`ownerProfile`) and each
///   agent's.
/// - Subjects come from records only: the resolver never mints or consults `OwnerPrincipal`, the requester-side capability
///   (Ruling A6); a `"owner"` setter on a record is the subject value `.owner(companyId:)`.
public struct PrincipalResolver: Sendable {
    let store: Store
    let ceiling: PermissionProfile?

    public init(store: Store, ceiling: PermissionProfile?) {
        self.store = store; self.ceiling = ceiling
    }

    /// Total: never throws, never returns an empty set (see the type's notes).
    public func resolve(_ subject: ActionSubject) -> PrincipalSet {
        Self.resolveCount?.add()
        switch subject {
        case .worktree(let companyId, let key): return worktree(companyId: companyId, key: key)
        case .publish(let companyId, let agentId):
            return withCompany(companyId) { scope in [agentId.map(scope.agent) ?? .owner(companyId: companyId)] }
        case .vaultBlob(let companyId, let provenance):
            return withCompany(companyId) { scope in
                switch provenance {
                case .agent(let id): return [scope.agent(id)]
                case .owner: return [.owner(companyId: companyId)]
                case .external(let source): return [.external(source: source)]
                case .engine: return [.engine]
                }
            }
        case .extensionBundle(let source):
            // Architect's call: an extension is never Full-eligible, whatever company imports it.
            return PrincipalSet(companyId: "", members: [.external(source: source)], ownerProfile: Self.narrowest)
        case .engine:
            return PrincipalSet(companyId: "", members: [.engine], ownerProfile: Self.narrowest)
        }
    }

    /// The id-based rows (`IdSubject`): tests and diagnostics only, internal (S6 fix round 3, M-2). Every production caller
    /// of those actions holds the record its command comes from and resolves it with `resolve(holding:)` (S6-c1, S6-c2);
    /// `SafetyLint`'s `idSubject` zero rule bans a `resolve(` of these rows anywhere in the scanned sources (this file
    /// included). Total, as `resolve(_: ActionSubject)`.
    func resolve(_ subject: IdSubject) -> PrincipalSet {
        Self.resolveCount?.add()
        switch subject {
        case .verificationRun(let runId): return verificationRun(runId)
        case .mergeRun(let runId): return mergeRun(runId)
        case .preview(let surfaceId): return preview(surfaceId)
        case .mainSmoke(let companyId): return mainSmoke(companyId)
        case .release(let releaseId): return release(releaseId)
        }
    }

    // MARK: Held records (controller rulings S6-c1, S6-c2)

    /// A record the caller already holds and takes the action's command from (the check's run, the preview's surface, the
    /// company's smoke check, the release's build). The decision must come from that same snapshot: a record re-read by id
    /// could carry another setter than the command that runs (S6-c1, a TOCTOU to a sandbox bypass).
    public enum HeldRecord: Sendable {
        case verificationRun(VerificationRun)
        case mergeRun(MergeRun)
        case preview(PreviewSurface)
        case mainSmoke(Company)
        case release(Release)
    }

    /// What a held resolution decided from: the principals, and the live company row they were resolved against. The caller
    /// builds every policy of the action from `company` (its profile, role profiles, domains, local binding and read paths),
    /// never from a company it read earlier (S6-c2).
    public struct Resolved: Sendable {
        public let principals: PrincipalSet
        public let company: Company
    }

    /// Resolves the principals of `held`. The held record supplies only the command and who set it (its setter, holder or
    /// requester, or proposer); every sandbox and grant input (the company's profile and role profiles, the setter's role and
    /// profile, the pack's role covers, the grants) comes from the live records, read at this call (S6-c2).
    /// - In one read: the stored copy of `held` (`WHERE id = ? AND companyId = ?`; the company by its key) and the live company.
    /// - The stored copy must still match the held one: the same company, the same setter and the same command fields (the
    ///   command digest). A stored copy that differs or is gone is `.deny(reason)`: the caller runs nothing on this snapshot
    ///   and tries again with a fresh one (fail closed).
    /// - A read that fails, or a live company that is gone, is `.deny` too: never a decision from the held copy.
    /// Counted as one resolution.
    public func resolve(holding held: HeldRecord) -> Decision<Resolved> {
        Self.resolveCount?.add()
        switch held {
        case .verificationRun(let run):
            let (id, cid) = (run.id, run.companyId)
            return live(run, "verification run \(id)", companyId: cid, same: Self.sameCommand, stored: { db in
                try VerificationRun.filter(Column("id") == id && Column("companyId") == cid).fetchOne(db)
            }) { verificationMembers(run, $0) }
        case .mergeRun(let run):
            let (id, cid) = (run.id, run.companyId)
            return live(run, "merge run \(id)", companyId: cid, same: Self.sameCommand, stored: { db in
                try MergeRun.filter(Column("id") == id && Column("companyId") == cid).fetchOne(db)
            }) { mergeMembers(run, $0) }
        case .preview(let surface):
            let (id, cid) = (surface.id, surface.companyId)
            return live(surface, "preview surface \(surface.name)", companyId: cid, same: Self.sameCommand, stored: { db in
                try PreviewSurface.filter(Column("id") == id && Column("companyId") == cid).fetchOne(db)
            }) { [$0.setter(surface.setById)] }
        case .mainSmoke(let company):
            // The held company supplies the smoke check and its setter only; the scope is the live row (A1).
            let cid = company.id
            return live(company, "the main smoke check", companyId: cid, same: Self.sameSmokeCheck, stored: { db in
                try Company.fetchOne(db, key: cid)
            }) { [$0.setter(company.smokeCheckSetById)] }
        case .release(let release):
            let (id, cid) = (release.id, release.companyId)
            return live(release, release.ref, companyId: cid, same: Self.sameCommand, stored: { db in
                try Release.filter(Column("id") == id && Column("companyId") == cid).fetchOne(db)
            }) { [$0.setter(release.proposedById)] }
        }
    }

    /// `members` on a scope over the live company, when the stored copy of `held` still matches it; `.deny` otherwise, and
    /// when the stored copy or the live company cannot be read or is gone.
    private func live<Record>(_ held: Record, _ what: String, companyId cid: String, same: (Record, Record) -> Bool,
                              stored fetch: @escaping (Database) throws -> Record?,
                              _ members: (Scope) -> [Principal]) -> Decision<Resolved> {
        let read: (stored: Record?, company: Company?)
        do {
            read = try store.writer.read { db in (try fetch(db), try Company.fetchOne(db, key: cid)) }
        } catch {
            return .deny("\(what) could not be read again (\(error))")
        }
        guard let stored = read.stored else { return .deny("\(what) is gone") }
        guard same(held, stored) else { return .deny(Self.changedWhileStarting(what)) }
        guard let company = read.company else { return .deny("the company of \(what) is gone") }
        let scope = Scope(store: store, company: company, ceiling: ceiling)
        let set = PrincipalSet(companyId: cid, members: members(scope), ownerProfile: scope.narrowed(company.permissionProfile))
        return .allow(Resolved(principals: set, company: company), because: "\(what) is unchanged since it was read")
    }

    /// The text of a held record that no longer matches its stored copy.
    static func changedWhileStarting(_ what: String) -> String { "\(what) changed while it was starting" }

    /// The fields a check's route and command come from.
    static func sameCommand(_ a: VerificationRun, _ b: VerificationRun) -> Bool {
        a.companyId == b.companyId && a.itemId == b.itemId && a.requestedBy == b.requestedBy && a.command == b.command
            && a.scriptHash == b.scriptHash && a.commit == b.commit && a.purpose == b.purpose
    }

    static func sameCommand(_ a: MergeRun, _ b: MergeRun) -> Bool {
        a.companyId == b.companyId && a.kind == b.kind && a.itemId == b.itemId && a.batchId == b.batchId
            && a.candidateCommit == b.candidateCommit && a.command == b.command && a.scriptHash == b.scriptHash
    }

    /// The setter and every field a preview's commands come from.
    static func sameCommand(_ a: PreviewSurface, _ b: PreviewSurface) -> Bool {
        a.companyId == b.companyId && a.setById == b.setById && a.kind == b.kind && a.build == b.build && a.run == b.run
            && a.url == b.url && a.smoke == b.smoke && a.demo == b.demo && a.openapiPath == b.openapiPath && a.appPath == b.appPath
            && a.bundleId == b.bundleId && a.device == b.device
    }

    static func sameSmokeCheck(_ a: Company, _ b: Company) -> Bool {
        a.id == b.id && a.smokeCheck == b.smokeCheck && a.smokeCheckSetById == b.smokeCheckSetById
    }

    static func sameCommand(_ a: Release, _ b: Release) -> Bool {
        a.companyId == b.companyId && a.proposedById == b.proposedById && a.build == b.build && a.commandsHash == b.commandsHash
            && a.commit == b.commit && a.outputDir == b.outputDir
    }

    // MARK: Rows of the resolution table

    /// The lease holder of the run's item, else who requested the run; neither, an unknown agent or a failed lookup:
    /// `.unknown` (the old `?? true` made it unsandboxed).
    private func verificationRun(_ runId: String) -> PrincipalSet {
        root("verification run \(runId)", { try VerificationRun.fetchOne($0, key: runId) }, companyId: \.companyId, verificationMembers)
    }

    private func verificationMembers(_ run: VerificationRun, _ scope: Scope) -> [Principal] {
        let cid = scope.companyId
        let holder: String?
        do {
            holder = try store.writer.read { db in
                try WorkLease.filter(Column("itemId") == run.itemId && Column("companyId") == cid).fetchOne(db)
            }?.agentId ?? run.requestedBy
        } catch {
            return [.unknown(reason: Self.failed(error))]
        }
        guard let holder else { return [.unknown(reason: Self.nobodyHolds)] }
        return [scope.agent(holder)]
    }

    /// Exactly 4a's rule (`SandboxedCheckRunner.swift`, merge-run branch, before S6): the setter for `main`/`mainAtBase`; for
    /// `main`/`item`, the run's item and its batch's items; for every kind, every item whose code reached `main` (queue-landed
    /// or `done`); each item's holder and author. `mainAtBase` with a head the queue did not land, an unknown kind and any
    /// missing data: `.unknown`. Setters and authors are agents only (a `"owner"` id is not an agent: `.unknown`, as in 4a).
    private func mergeRun(_ runId: String) -> PrincipalSet {
        root("merge run \(runId)", { try MergeRun.fetchOne($0, key: runId) }, companyId: \.companyId, mergeMembers)
    }

    private func mergeMembers(_ run: MergeRun, _ scope: Scope) -> [Principal] {
        let runId = run.id
        let cid = scope.companyId
        var members: [Principal] = []
        func missing(_ why: String) { members.append(.unknown(reason: why)) }
        let usesItems = run.kind == .main || run.kind == .item
        var itemIds = Set(usesItems ? run.itemId.map { [$0] } ?? [] : [])
        if usesItems, let batchId = run.batchId {
            do {
                itemIds.formUnion(try store.writer.read { db in
                    try MergeRequest.filter(Column("batchId") == batchId && Column("companyId") == cid).fetchAll(db)
                }.map(\.itemId))
            } catch { missing(Self.failed(error)) }
        }
        do { itemIds.formUnion(try store.landedItemIds(companyId: cid)) } catch { missing(Self.failed(error)) }
        var ids: [String] = []
        // S6-c1 (I2): the queue recorded the main check's command at batch time, the setter is read now. A command that is not
        // the company's current main check was set by someone the engine can no longer name: unknown, so sandboxed.
        if run.kind == .main || run.kind == .mainAtBase, scope.company.mainCheck?.command != run.command {
            missing(Self.mainCheckChanged)
        }
        switch run.kind {
        case .main:
            if let setter = scope.company.mainCheckSetById { ids.append(setter) } else { missing(Self.noMainCheckSetter) }
        case .item:
            break
        case .mainAtBase:
            if let setter = scope.company.mainCheckSetById { ids.append(setter) } else { missing(Self.noMainCheckSetter) }
            do {
                if try !store.isQueueLandedHead(companyId: cid, candidate: run.candidateCommit) { missing(Self.headNotLanded) }
            } catch { missing(Self.failed(error)) }
        case nil:
            missing("merge run \(runId) has no kind")
        }
        if usesItems && run.itemId == nil && run.batchId == nil { missing("merge run \(runId) names no item") }
        for id in itemIds.sorted() {
            do {
                let holder = try store.writer.read { db in
                    try WorkLease.filter(Column("itemId") == id && Column("companyId") == cid).fetchOne(db)
                }?.agentId
                let author = try store.writer.read { db in
                    try WorkItem.filter(Column("id") == id && Column("companyId") == cid).fetchOne(db)
                }?.ownerId
                if holder == nil && author == nil { missing("no agent holds or wrote item \(id)") }
                ids.append(contentsOf: [holder, author].compactMap { $0 })
            } catch { missing(Self.failed(error)) }
        }
        var seen = Set<String>()
        for id in ids {
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            members.append(scope.agent(id))
        }
        return members
    }

    /// The surface's setter; `"owner"` → `.owner`; none (an empty id) or a failed lookup → `.unknown` (it used to follow the
    /// company).
    private func preview(_ surfaceId: String) -> PrincipalSet {
        root("preview surface \(surfaceId)", { try PreviewSurface.fetchOne($0, key: surfaceId) }, companyId: \.companyId) { surface, scope in
            [scope.setter(surface.setById)]
        }
    }

    /// `company.smokeCheckSetById`, with the preview rules.
    private func mainSmoke(_ companyId: String) -> PrincipalSet {
        withCompany(companyId) { scope in [scope.setter(scope.company.smokeCheckSetById)] }
    }

    /// `release.proposedById`, with the preview rules.
    private func release(_ releaseId: String) -> PrincipalSet {
        root("release \(releaseId)", { try Release.fetchOne($0, key: releaseId) }, companyId: \.companyId) { release, scope in
            [scope.setter(release.proposedById)]
        }
    }

    /// The current lease holder of the item with `key`, else the item's `ownerId`, else `.unknown`.
    private func worktree(companyId: String, key: String) -> PrincipalSet {
        withCompany(companyId) { scope in
            do {
                guard let item = try store.workItem(companyId: companyId, key: key) else { return [.unknown(reason: "no item \(key)")] }
                let holder = try store.writer.read { db in
                    try WorkLease.filter(Column("itemId") == item.id && Column("companyId") == companyId).fetchOne(db)
                }?.agentId
                guard let who = holder ?? item.ownerId else { return [.unknown(reason: "no agent holds or owns \(item.key)")] }
                return [scope.agent(who)]
            } catch {
                return [.unknown(reason: Self.failed(error))]
            }
        }
    }

    // MARK: Plumbing

    /// Reads the action's root record by its id (which names the company), then the company, then `members`.
    private func root<Record>(_ what: String, _ fetch: @escaping (Database) throws -> Record?, companyId: KeyPath<Record, String>,
                              _ members: (Record, Scope) -> [Principal]) -> PrincipalSet {
        let record: Record?
        do { record = try store.writer.read(fetch) } catch { return Self.unresolved("", Self.failed(error)) }
        guard let record else { return Self.unresolved("", "no \(what)") }
        return withCompany(record[keyPath: companyId]) { scope in members(record, scope) }
    }

    /// Reads the company (`WHERE id = companyId`), then `members` with a scope on it.
    private func withCompany(_ companyId: String, _ members: (Scope) -> [Principal]) -> PrincipalSet {
        let company: Company?
        do { company = try store.company(id: companyId) } catch { return Self.unresolved(companyId, Self.failed(error)) }
        guard let company else { return Self.unresolved(companyId, "no company \(companyId)") }
        let scope = Scope(store: store, company: company, ceiling: ceiling)
        return PrincipalSet(companyId: companyId, members: members(scope), ownerProfile: scope.narrowed(company.permissionProfile))
    }

    private static func unresolved(_ companyId: String, _ reason: String) -> PrincipalSet {
        PrincipalSet(companyId: companyId, members: [.unknown(reason: reason)], ownerProfile: narrowest)
    }

    /// The owner profile of a set with no company to read: the narrowest there is.
    static let narrowest: PermissionProfile = .sandboxed

    static let nobodyHolds = "no agent holds or requested it"
    static let noSetter = "no one is recorded as setting it"
    static let noMainCheckSetter = "no one is recorded as setting the main check"
    static let headNotLanded = "main's head was not landed by the queue"
    static let mainCheckChanged = "the main check changed since this run started"
    static func noAgent(_ id: String) -> String { "no agent \(id) in the company's records" }
    static func failed(_ error: any Error) -> String { "the lookup failed: \(error)" }

    /// The lookups of one resolution on one company: agents and their grants, company-scoped, narrowed by the ceiling.
    final class Scope {
        let store: Store
        let company: Company
        let ceiling: PermissionProfile?
        var companyId: String { company.id }
        /// The company's live grants, read once per resolution (nil until the first agent needs them).
        private var grants: (all: [Grant], activeNow: Double, sprints: Set<String>)?

        init(store: Store, company: Company, ceiling: PermissionProfile?) {
            self.store = store; self.company = company; self.ceiling = ceiling
        }

        func narrowed(_ p: PermissionProfile) -> PermissionProfile { ceiling.map { PermissionProfile.narrower(p, $0) } ?? p }

        /// A setter of a record (preview, main smoke, release): `"owner"` is the owner; none (nil or empty) is unknown; any other
        /// id must be an agent of the company.
        func setter(_ id: String?) -> Principal {
            guard let id, !id.isEmpty else { return .unknown(reason: PrincipalResolver.noSetter) }
            if id == "owner" { return .owner(companyId: companyId) }
            return agent(id)
        }

        /// The agent `id` of this company, its profile narrowed by the company's, its role's and the ceiling, with its durable
        /// network grants. Not an agent of this company, or a failed lookup: `.unknown`.
        func agent(_ id: String) -> Principal {
            do {
                let cid = companyId
                guard let agent = try store.writer.read({ db in
                    try Agent.filter(Column("id") == id && Column("companyId") == cid).fetchOne(db)
                }) else { return .unknown(reason: PrincipalResolver.noAgent(id)) }
                let profile = narrowed(PermissionProfile.narrower(company.permissionProfile, company.profile(forRole: agent.role)))
                return .agent(AgentPrincipal(agentId: agent.id, companyId: cid, role: agent.role, profile: profile,
                                             grantDomains: try grantDomains(of: agent)))
            } catch {
                return .unknown(reason: PrincipalResolver.failed(error))
            }
        }

        /// The agent's live network-domain grants that outlast one turn (agent, role and company scope; a `once` grant or a
        /// `turn` grant is the requester's next turn's, an item grant its item's turns'), normalized. A killed agent has none.
        private func grantDomains(of agent: Agent) throws -> [String] {
            guard agent.state != .killed else { return [] }
            let cid = companyId
            let loaded: (all: [Grant], activeNow: Double, sprints: Set<String>)
            if let grants { loaded = grants } else {
                loaded = try store.writer.read { db in
                    (try Grant.filter(Column("companyId") == cid && Column("revokedAt") == nil).order(Column("number")).fetchAll(db),
                     try Store.activeNow(db: db, companyId: cid), try Store.activeSprintIds(db, companyId: cid))
                }
                grants = loaded
            }
            var roles: Set<String> = [agent.role]
            if let template = store.catalog.pack(company.packId)?.role(agent.role) { roles.formUnion(template.covers) }
            return GrantResolver.active(loaded.all, agent: agent, roles: roles, itemId: nil, kind: .work, activeNow: loaded.activeNow,
                                        sprintActive: loaded.sprints.contains)
                .filter { $0.kind == .networkDomain && $0.scope != .once && $0.duration != .turn }
                .map { SandboxDomains.normalize($0.value) }
        }
    }

    // MARK: Resolve once (tests)

    /// Counts `resolve` calls made under it (a task-local, so a test counts only its own action's resolutions).
    final class ResolveCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// The resolve-once test's counter (spec §6.2.3 "Resolve once"): nil outside a test.
    @TaskLocal static var resolveCount: ResolveCount?
}

// MARK: The Full route of an agent-written command (checks, previews, main smokes, release builds)

extension PrincipalSet {
    /// Unsandboxed only when every member is Full-eligible and the company itself runs Full, both after the ceiling (spec
    /// §6.2.4; a set with no owner member still needs its company Full).
    var runsUnsandboxed: Bool { allFull && ownerProfile == .full }

    /// B1: why a command of a Full company runs sandboxed because the engine could not confirm its author (the reasons of the
    /// `.unknown` members), nil when the company is not Full or every member is known.
    var unconfirmedInFullCompany: String? {
        guard ownerProfile == .full else { return nil }
        let reasons = members.compactMap { member -> String? in
            if case .unknown(let why) = member { return why }
            return nil
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "; ")
    }
}

extension PrincipalResolver {
    /// B1 (spec §8): the activity line on the company for a command of a Full company that runs sandboxed because the engine
    /// could not confirm who wrote it (`SafeRead.sandboxedNote`). Nothing when the company is not Full or every member is
    /// known. A line that cannot be recorded is logged; the route stands.
    static func noteSandboxed(_ principals: PrincipalSet, store: Store, subject: String, kind: ActivityKind, agentId: String? = nil,
                              now: Date = Store.now()) {
        guard !principals.runsUnsandboxed, let reason = principals.unconfirmedInFullCompany else { return }
        let text = SafeRead.sandboxedNote(subject: subject, reason: reason)
        do {
            try store.appendEvent(ActivityEvent(companyId: principals.companyId, agentId: agentId, turnId: nil, kind: kind, text: text,
                                                createdAt: now))
        } catch {
            FileHandle.standardError.write(Data("brahma: could not record \"\(text)\" (\(error))\n".utf8))
        }
    }
}

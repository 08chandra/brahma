import Foundation
import GRDB

/// A notice with the event it carries and the key of the item it is about.
public struct PendingNotice: Equatable, Sendable {
    public var notice: WorkNotice
    public var event: WorkItemEvent
    public var itemKey: String
}

/// Who is acting on an item, resolved against the database.
struct WorkActor {
    var id: String
    var kind: RoleKind
    var handle: String
    var privileged: Bool { WorkPolicy.isPrivileged(id) }
    var isLead: Bool { WorkPolicy.isLead(kind) }
    /// "<id>:<role kind>", stored in `specConfirmedBy`.
    var label: String { "\(id):\(privileged ? id : kind.rawValue)" }
}

extension Store {
    static let maxTitle = 200
    static let maxDescription = 20_000
    static let maxCriteria = 10_000
    static let maxNotes = 8192
    static let maxComment = 4000

    // MARK: Actors and validation

    func resolveActor(_ db: Database, _ sender: Sender, companyId: String) throws -> WorkActor {
        switch sender {
        case .owner: return WorkActor(id: "owner", kind: .executive, handle: "owner")
        case .system: return WorkActor(id: "system", kind: .executive, handle: "system")
        case .agent(let id):
            guard let agent = try Agent.fetchOne(db, key: id), agent.companyId == companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard agent.state != .killed else { throw WorkError.forbidden("this agent is not active in the company") }
            let packId = try Company.fetchOne(db, key: companyId)?.packId ?? "software"
            return WorkActor(id: agent.id, kind: catalog.template(role: agent.role, pack: packId).kind, handle: agent.name)
        }
    }

    /// The agent must exist in the company and be active.
    private func requireAgent(_ db: Database, _ id: String, companyId: String) throws -> Agent {
        guard let agent = try Agent.fetchOne(db, key: id) else { throw WorkError.invalid("no such agent") }
        guard agent.companyId == companyId else { throw WorkError.forbidden("not in your company") }
        guard agent.state != .killed else { throw WorkError.invalid("@\(agent.name) has been killed") }
        return agent
    }

    private static func cleanTitle(_ raw: String) throws -> String {
        let flat = raw.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { throw WorkError.invalid("the title is empty") }
        guard flat.count <= maxTitle else { throw WorkError.invalid("the title is longer than \(maxTitle) characters") }
        return flat
    }

    private static func limited(_ text: String, _ max: Int, _ what: String) throws -> String {
        guard text.count <= max else { throw WorkError.invalid("\(what) is longer than \(max) characters") }
        return text
    }

    private static func validBranch(_ b: String) throws -> String {
        let t = b.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 200, !t.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw WorkError.invalid("the linked branch must be a single word of at most 200 characters")
        }
        return t
    }

    private static func validPriority(_ p: Int) throws -> Int {
        guard (0...4).contains(p) else { throw WorkError.invalid("priority must be between 0 (most urgent) and 4") }
        return p
    }

    private static func validPoints(_ p: Int?) throws -> Int? {
        if let p, !(0...1000).contains(p) { throw WorkError.invalid("points must be between 0 and 1000") }
        return p
    }

    static func validTeam(_ t: String?) throws -> String? {
        guard let t else { return nil }
        let v = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return nil }
        guard v.count <= 64, !v.contains(where: \.isNewline) else { throw WorkError.invalid("the team name is too long") }
        return v
    }

    private func itemType(_ db: Database, _ type: WorkItemType, company: Company) throws -> ItemTypeDef {
        guard let pack = catalog.pack(company.packId) else { throw WorkError.invalid("unknown industry pack '\(company.packId)'") }
        guard let def = pack.itemType(type.rawValue) else {
            throw WorkError.invalid("unknown item type '\(type.rawValue)' (this company's pack has: \(pack.itemTypes.map(\.id).joined(separator: ", ")))")
        }
        return def
    }

    /// A parent must be a container item of the same company, and never the item itself or one of its descendants.
    private func requireParent(_ db: Database, parentId: String, company: Company, childId: String?) throws {
        guard let parent = try WorkItem.fetchOne(db, key: parentId) else { throw WorkError.invalid("no such parent item") }
        guard parent.companyId == company.id else { throw WorkError.forbidden("not in your company") }
        guard try itemType(db, parent.type, company: company).container else {
            throw WorkError.invalid("\(parent.key) is a \(parent.type.rawValue), not a container (epic or story)")
        }
        guard let childId else { return }
        var cursor: WorkItem? = parent
        var hops = 0
        while let c = cursor, hops < 1000 {
            if c.id == childId { throw WorkError.invalid("an item cannot be its own ancestor") }
            cursor = try c.parentId.flatMap { try WorkItem.fetchOne(db, key: $0) }
            hops += 1
        }
    }

    static func keyPrefix(slug: String) -> String {
        let letters = String(slug.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.uppercased().prefix(5))
        return letters.isEmpty ? "ITEM" : letters
    }

    /// The agent holding the item's lease, if any.
    static func leaseHolderId(db: Database, itemId: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT agentId FROM workLease WHERE itemId = ?", arguments: [itemId])
    }

    // MARK: Create

    @discardableResult
    public func createWorkItem(companyId: String, by sender: Sender, draft: WorkItemDraft, now: Date = Store.now()) throws -> WorkItem {
        try writer.write { db in try createWorkItem(db: db, companyId: companyId, by: sender, draft: draft, now: now) }
    }

    func createWorkItem(db: Database, companyId: String, by sender: Sender, draft: WorkItemDraft, now: Date) throws -> WorkItem {
        guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
        let actor = try resolveActor(db, sender, companyId: companyId)
        _ = try itemType(db, draft.type, company: company)
        // Redacted raw, before any normalization or validation (a multi-line secret matches; what is validated is what is stored).
        let title = try Self.cleanTitle(try redact(draft.title))
        let description = try Self.limited(try redact(draft.description), Self.maxDescription, "the description")
        let criteria = try Self.limited(try redact(draft.acceptanceCriteria), Self.maxCriteria, "the acceptance criteria")
        let checkSpec = try redact(draft.checkSpec)
        let touchPaths = try draft.touchPaths.map { try redact($0) }
        try checkSpec?.validate()
        try CheckSpec.validatePaths(touchPaths, what: "touch")
        let priority = try Self.validPriority(draft.priority)
        let points = try Self.validPoints(draft.points)
        let team = try Self.validTeam(draft.team)
        guard draft.status == .backlog || draft.status == .ready else {
            throw WorkError.invalid("a new item starts in backlog or ready")
        }
        if let parent = draft.parentId { try requireParent(db, parentId: parent, company: company, childId: nil) }
        if let o = draft.ownerId { _ = try requireAgent(db, o, companyId: companyId) }
        if let r = draft.reviewerId { _ = try requireAgent(db, r, companyId: companyId) }
        if let o = draft.ownerId, o == draft.reviewerId { throw WorkError.conflict("an item's assignee cannot be its reviewer") }
        if draft.intensity != .auto,
           let d = WorkPolicy.intensityDenial(draft.intensity, actor: actor.id, actorKind: actor.kind) { throw WorkError.forbidden(d) }

        let number = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(number), 0) + 1 FROM workItem WHERE companyId = ?",
                                       arguments: [companyId])) ?? 1
        let item = WorkItem(
            id: UUID().uuidString, companyId: companyId, number: number, key: "\(Self.keyPrefix(slug: company.slug))-\(number)",
            type: draft.type, title: title, description: description, acceptanceCriteria: criteria, checkSpec: checkSpec,
            status: draft.status, priority: priority, points: points, tier: draft.tier, authorId: actor.id,
            ownerId: draft.ownerId, reviewerId: draft.reviewerId, team: team, parentId: draft.parentId,
            createdAt: now, updatedAt: now, intensity: draft.intensity,
            specConfirmedBy: actor.privileged || actor.isLead ? actor.label : nil, touchPaths: touchPaths,
            tierSetBy: actor.label, checkSpecSetBy: draft.checkSpec == nil ? nil : actor.label)
        // The same rules as an edit, applied to the draft's assignee and reviewer.
        if item.ownerId != nil,
           let d = WorkPolicy.denial(.assignee, item: item, actor: actor.id, actorKind: actor.kind, leaseHolderId: nil) {
            throw WorkError.forbidden(d)
        }
        if item.reviewerId != nil,
           let d = WorkPolicy.denial(.spec, item: item, actor: actor.id, actorKind: actor.kind, leaseHolderId: nil) {
            throw WorkError.forbidden(d)
        }
        try item.insert(db)
        var text = "created \(item.type.rawValue) \"\(title)\""
        if let o = item.ownerId, let h = try Agent.fetchOne(db, key: o)?.name { text += ", assigned to @\(h)" }
        try recordItemEvent(db: db, item: item, actor: actor.id, kind: .created, text: text, now: now)
        return item
    }

    // MARK: Read

    public func workItem(id: String) throws -> WorkItem? {
        try writer.read { db in try WorkItem.fetchOne(db, key: id) }
    }

    public func workItem(companyId: String, key: String) throws -> WorkItem? {
        let k = key.trimmingCharacters(in: .whitespaces).uppercased()
        return try writer.read { db in
            try WorkItem.filter(Column("companyId") == companyId && Column("key") == k).fetchOne(db)
        }
    }

    public func workItems(companyId: String, filter: WorkItemFilter = .init()) throws -> [WorkItem] {
        try writer.read { db in
            var request = WorkItem.filter(Column("companyId") == companyId)
            if let s = filter.statuses { request = request.filter(s.map(\.rawValue).contains(Column("status"))) }
            if let o = filter.ownerId { request = request.filter(Column("ownerId") == o) }
            if let r = filter.reviewerId { request = request.filter(Column("reviewerId") == r) }
            if let t = filter.team { request = request.filter(Column("team") == t) }
            if let t = filter.type { request = request.filter(Column("type") == t.rawValue) }
            if let p = filter.parentId { request = request.filter(Column("parentId") == p) }
            return try request.order(Column("number")).limit(filter.limit).fetchAll(db)
        }
    }

    /// The newest `limit` events of an item, oldest first.
    public func itemEvents(itemId: String, limit: Int = 100) throws -> [WorkItemEvent] {
        try writer.read { db in
            try WorkItemEvent.filter(Column("itemId") == itemId).order(Column("id").desc).limit(limit).fetchAll(db).reversed()
        }
    }

    // MARK: Update

    @discardableResult
    public func updateWorkItem(id: String, by sender: Sender, patch: WorkItemPatch, now: Date = Store.now()) throws -> WorkItem {
        try writer.write { db in try updateWorkItem(db: db, id: id, by: sender, patch: patch, now: now) }
    }

    func updateWorkItem(db: Database, id: String, by sender: Sender, patch: WorkItemPatch, now: Date) throws -> WorkItem {
        let patch = try redacted(patch)
        guard var item = try WorkItem.fetchOne(db, key: id) else { throw WorkError.notFound("no such work item") }
        guard let company = try Company.fetchOne(db, key: item.companyId) else { throw WorkError.notFound("no such company") }
        let actor = try resolveActor(db, sender, companyId: item.companyId)
        let holder = try Self.leaseHolderId(db: db, itemId: item.id)
        func require(_ field: WorkField) throws {
            if let d = WorkPolicy.denial(field, item: item, actor: actor.id, actorKind: actor.kind, leaseHolderId: holder) {
                throw WorkError.forbidden(d)
            }
        }
        if patch.touchesSpec { try require(.spec) }
        if patch.touchesOwner { try require(.assignee) }
        if patch.touchesNotes { try require(.notes) }
        if patch.touchesBranch { try require(.linkedBranch) }
        if patch.touchesStatus { try require(.status) }
        if let i = patch.intensity {
            try require(.intensity)
            if let d = WorkPolicy.intensityDenial(i, actor: actor.id, actorKind: actor.kind) { throw WorkError.forbidden(d) }
        }

        var specChanged: [String] = []
        var checkChanged = false
        let statusBefore = item.status
        if let t = patch.type, t != item.type {
            _ = try itemType(db, t, company: company)
            item.type = t; specChanged.append("type")
        }
        if let t = patch.title {
            let title = try Self.cleanTitle(t)
            if title != item.title { item.title = title; specChanged.append("title") }
        }
        if let d = patch.description, d != item.description {
            item.description = try Self.limited(d, Self.maxDescription, "the description"); specChanged.append("description")
        }
        if let c = patch.acceptanceCriteria, c != item.acceptanceCriteria {
            item.acceptanceCriteria = try Self.limited(c, Self.maxCriteria, "the acceptance criteria"); specChanged.append("acceptance criteria")
        }
        if let spec = patch.checkSpec {
            try spec?.validate()
            if spec != item.checkSpec {
                // Once started, the check can be reshaped (and the change is flagged) but not dropped where the type needs one.
                if spec == nil, item.everStarted, try itemType(db, item.type, company: company).requiresCheck {
                    throw WorkError.invalid("a started \(item.type.rawValue) must keep a check; edit it instead")
                }
                let old = item.checkRevision
                item.checkSpec = spec; item.checkRevision += 1; checkChanged = true
                item.checkSpecSetBy = spec == nil ? nil : actor.label
                if item.everStarted { item.reviewFlags.append("check edited (rev \(old) → \(item.checkRevision))") }
            }
        }
        if let paths = patch.touchPaths {
            try CheckSpec.validatePaths(paths, what: "touch")
            if paths != item.touchPaths { item.touchPaths = paths; specChanged.append("touch paths") }
        }
        if let p = patch.priority, p != item.priority { item.priority = try Self.validPriority(p); specChanged.append("priority") }
        if let p = patch.points {
            let v = try Self.validPoints(p)
            if v != item.points { item.points = v; specChanged.append("points") }
        }
        if let t = patch.tier, t != item.tier { item.tier = t; item.tierSetBy = actor.label; specChanged.append("tier") }
        if let t = patch.team {
            let v = try Self.validTeam(t)
            if v != item.team { item.team = v; specChanged.append("team") }
        }
        var reviewerChanged = false
        if let r = patch.reviewerId, r != item.reviewerId {
            if let r { _ = try requireAgent(db, r, companyId: item.companyId) }
            item.reviewerId = r; specChanged.append("reviewer")
            // A new reviewer starts with fresh attempts.
            item.reviewAttempts = 0
            reviewerChanged = true
        }
        if let p = patch.parentId, p != item.parentId {
            if let p { try requireParent(db, parentId: p, company: company, childId: item.id) }
            item.parentId = p; specChanged.append("parent")
        }
        var assignment: (old: String?, new: String?)?
        if let o = patch.ownerId, o != item.ownerId {
            if let o { _ = try requireAgent(db, o, companyId: item.companyId) }
            assignment = (item.ownerId, o)
            item.ownerId = o
        }
        if item.ownerId != nil, item.ownerId == item.reviewerId {
            throw WorkError.conflict("an item's assignee cannot be its reviewer")
        }
        if let reviewer = item.reviewerId, patch.reviewerId != nil, reviewer == (try Self.leaseHolderId(db: db, itemId: item.id)) {
            throw WorkError.conflict("the agent holding an item's lease cannot be its reviewer")
        }
        var otherChanged: [String] = []
        if let n = patch.notes {
            let v = try n.map { try Self.limited($0, Self.maxNotes, "the notes") }
            if v != item.notes { item.notes = v; otherChanged.append("notes") }
        }
        if let b = patch.linkedBranch {
            let v = try b.map { try Self.validBranch($0) }
            if v != item.linkedBranch { item.linkedBranch = v; otherChanged.append("linked branch") }
        }
        if let i = patch.intensity, i != item.intensity { item.intensity = i; otherChanged.append("intensity") }

        var statusChange: (from: WorkItemStatus, to: WorkItemStatus)?
        let reason = patch.blockedReason?.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let to = patch.status, to != item.status {
            let isHolderOrAssignee = actor.id == item.ownerId || (holder != nil && actor.id == holder)
            if let denial = WorkPolicy.statusDenial(from: item.status, to: to, actor: actor.id, actorKind: actor.kind,
                                                    isHolderOrAssignee: isHolderOrAssignee, hasLease: holder != nil,
                                                    blockedReason: reason, stopReason: item.stopReason, itemKey: item.key) {
                throw denial
            }
            statusChange = (item.status, to)
            if to == .blocked {
                item.blockedReason = String((reason ?? "").prefix(500))
                item.blockedSinceActive = try Self.activeNow(db: db, companyId: item.companyId)
            } else if item.status == .blocked {
                item.blockedReason = nil
                item.blockedSinceActive = nil
                item.stopReason = nil
            }
            if item.status == .done { item.doneAt = nil }
            item.status = to
            if to == .inProgress { item.everStarted = true }
        } else if patch.status == nil || patch.status == item.status, let reason, !reason.isEmpty, item.status == .blocked,
                  reason != item.blockedReason {
            item.blockedReason = String(reason.prefix(500))
            otherChanged.append("blocked reason")
        }

        guard !specChanged.isEmpty || checkChanged || assignment != nil || !otherChanged.isEmpty || statusChange != nil else {
            return item
        }
        // The lease goes when the item leaves the holder's hands: back to ready or backlog, or given to someone else.
        var releasedLease: (lease: WorkLease, why: String)?
        if let lease = try WorkLease.fetchOne(db, key: item.id) {
            if let a = assignment, a.new != lease.agentId {
                releasedLease = (lease, "reassigned")
                if item.status == .inProgress, statusChange == nil { item.status = .ready }
            } else if let s = statusChange, s.to == .ready || s.to == .backlog {
                releasedLease = (lease, "moved to \(s.to.title)")
            }
            if releasedLease != nil { try lease.delete(db) }
        }
        if !specChanged.isEmpty || checkChanged {
            // Whoever changes the spec vouches for it only if they are trusted; anyone else un-confirms it.
            item.specConfirmedBy = actor.privileged || actor.isLead ? actor.label : nil
        }
        item.updatedAt = now
        try item.update(db)

        let handles = try Self.handles(db, Set([assignment?.old, assignment?.new].compactMap { $0 }))
        if !specChanged.isEmpty {
            try recordItemEvent(db: db, item: item, actor: actor.id, kind: .edited, text: "edited " + specChanged.joined(separator: ", "), now: now)
        }
        if checkChanged {
            try recordItemEvent(db: db, item: item, actor: actor.id, kind: .checkEdited,
                                text: item.checkSpec == nil ? "check removed (revision \(item.checkRevision))"
                                    : "check changed (revision \(item.checkRevision))", now: now)
        }
        if let a = assignment {
            let text = a.new.map { "assigned to @\(handles[$0] ?? "?")" } ?? "unassigned (was @\(a.old.flatMap { handles[$0] } ?? "?"))"
            try recordItemEvent(db: db, item: item, actor: actor.id, kind: .assigned, text: text,
                                alsoNotify: [a.old, a.new].compactMap { $0 }, now: now)
        }
        if let s = statusChange {
            var text = "\(s.from.title) → \(s.to.title)"
            if s.to == .blocked, let r = item.blockedReason, !r.isEmpty { text += ": \(r)" }
            try recordItemEvent(db: db, item: item, actor: actor.id, kind: .statusChanged, text: text, now: now)
        }
        if !otherChanged.isEmpty {
            try recordItemEvent(db: db, item: item, actor: actor.id, kind: .edited, text: "edited " + otherChanged.joined(separator: ", "), now: now)
        }
        if let released = releasedLease {
            try recordItemEvent(db: db, item: item, actor: actor.id, kind: .leaseReleased, text: "lease released: \(released.why)",
                                alsoNotify: [released.lease.agentId], now: now)
        }
        // A check edited while the item was in review leaves it unverified: it goes back to its holder to resubmit.
        if checkChanged, statusBefore == .inReview, item.status == .inReview {
            try returnForChangedCheck(db: db, item: item, now: now)
            return try WorkItem.fetchOne(db, key: item.id) ?? item
        }
        if reviewerChanged, item.status == .inReview { try Store.wakeReviewer(db: db, item: item, now: now) }
        return item
    }

    /// The patch with secrets redacted from every free-text field, before anything is compared or stored.
    private func redacted(_ patch: WorkItemPatch) throws -> WorkItemPatch {
        var p = patch
        p.title = try redact(p.title)
        p.description = try redact(p.description)
        p.acceptanceCriteria = try redact(p.acceptanceCriteria)
        if let spec = p.checkSpec { p.checkSpec = .some(try redact(spec)) }
        p.blockedReason = try redact(p.blockedReason)
        if let notes = p.notes { p.notes = .some(try redact(notes)) }
        if let branch = p.linkedBranch { p.linkedBranch = .some(try redact(branch)) }
        if let paths = p.touchPaths { p.touchPaths = try paths.map { try redact($0) } }
        return p
    }

    private static func handles(_ db: Database, _ ids: Set<String>) throws -> [String: String] {
        var map: [String: String] = [:]
        for id in ids { if let a = try Agent.fetchOne(db, key: id) { map[id] = a.name } }
        return map
    }

    /// A manager, an executive or the owner vouches for the item's spec (tier, priority and type then count for model
    /// selection). The assignee cannot confirm its own item.
    @discardableResult
    public func confirmSpec(id: String, by sender: Sender, now: Date = Store.now()) throws -> WorkItem {
        try writer.write { db in
            guard var item = try WorkItem.fetchOne(db, key: id) else { throw WorkError.notFound("no such work item") }
            let actor = try resolveActor(db, sender, companyId: item.companyId)
            guard actor.privileged || actor.isLead else {
                throw WorkError.forbidden("only a manager, an executive or the owner can confirm an item's spec")
            }
            guard actor.id != item.ownerId else { throw WorkError.forbidden("the assignee cannot confirm its own item's spec") }
            item.specConfirmedBy = actor.label
            item.updatedAt = now
            try item.update(db)
            try recordItemEvent(db: db, item: item, actor: actor.id, kind: .specConfirmed, text: "spec confirmed by @\(actor.handle)", now: now)
            return item
        }
    }

    // MARK: Comments

    @discardableResult
    public func commentWorkItem(id: String, by sender: Sender, text: String, now: Date = Store.now()) throws -> WorkItemEvent {
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: id) else { throw WorkError.notFound("no such work item") }
            let actor = try resolveActor(db, sender, companyId: item.companyId)
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { throw WorkError.invalid("the comment is empty") }
            guard body.count <= Self.maxComment else { throw WorkError.invalid("the comment is longer than \(Self.maxComment) characters") }
            // Only an @mention makes a comment actionable.
            var mentioned: [String] = []
            for handle in MessageRouter.mentions(in: body) where handle != "owner" {
                if let a = try Agent.filter(Column("companyId") == item.companyId && Column("name") == handle).fetchOne(db),
                   a.state != .killed, a.id != actor.id { mentioned.append(a.id) }
            }
            return try recordItemEvent(db: db, item: item, actor: actor.id, kind: .commented, text: body,
                                       alsoNotify: mentioned, alsoNotifyRole: .mentioned, now: now)
        }
    }

    // MARK: Dependencies

    /// `itemId` waits for `dependsOnId`. Self-dependency and cycles are refused.
    public func addDependency(itemId: String, dependsOn dependsOnId: String, by sender: Sender, now: Date = Store.now()) throws {
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId), let other = try WorkItem.fetchOne(db, key: dependsOnId)
            else { throw WorkError.notFound("no such work item") }
            guard item.companyId == other.companyId else { throw WorkError.forbidden("not in your company") }
            let actor = try resolveActor(db, sender, companyId: item.companyId)
            if !actor.privileged, !(actor.isLead || actor.id == item.authorId || actor.id == item.ownerId || actor.id == item.reviewerId) {
                throw WorkError.forbidden("only the item's author, assignee, reviewer, a manager or the owner can link its dependencies")
            }
            guard item.id != other.id else { throw WorkError.invalid("an item cannot depend on itself") }
            if try Self.reaches(db, from: other.id, to: item.id) {
                throw WorkError.conflict("\(other.key) already depends on \(item.key); that would be a dependency cycle")
            }
            let exists = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workItemDependency WHERE itemId = ? AND dependsOnId = ?",
                                          arguments: [item.id, other.id]) ?? 0
            guard exists == 0 else { return }
            try db.execute(sql: "INSERT INTO workItemDependency (itemId, dependsOnId, linkedBy, createdAt) VALUES (?, ?, ?, ?)",
                           arguments: [item.id, other.id, actor.id, now])
            try recordItemEvent(db: db, item: item, actor: actor.id, kind: .dependencyAdded, text: "depends on \(other.key)", now: now)
        }
    }

    /// True when following `dependsOn` links from `start` reaches `target`.
    private static func reaches(_ db: Database, from start: String, to target: String) throws -> Bool {
        var seen = Set<String>(), stack = [start]
        while let id = stack.popLast() {
            if id == target { return true }
            guard seen.insert(id).inserted else { continue }
            stack += try String.fetchAll(db, sql: "SELECT dependsOnId FROM workItemDependency WHERE itemId = ?", arguments: [id])
        }
        return false
    }

    /// What the item waits for, by key order.
    public func dependencies(itemId: String) throws -> [WorkItem] {
        try writer.read { db in
            try WorkItem.fetchAll(db, sql: """
                SELECT workItem.* FROM workItem JOIN workItemDependency d ON d.dependsOnId = workItem.id
                WHERE d.itemId = ? ORDER BY workItem.number
                """, arguments: [itemId])
        }
    }

    /// The items that wait for this one.
    public func dependents(itemId: String) throws -> [WorkItem] {
        try writer.read { db in
            try WorkItem.fetchAll(db, sql: """
                SELECT workItem.* FROM workItem JOIN workItemDependency d ON d.itemId = workItem.id
                WHERE d.dependsOnId = ? ORDER BY workItem.number
                """, arguments: [itemId])
        }
    }

    /// Undone items waiting on this one, not counting dependents that the item's current assignee wrote and linked
    /// themselves (an agent cannot raise its own item's importance by linking its own work to it).
    public func blockingDependentCount(itemId: String) throws -> Int {
        try writer.read { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { return 0 }
            return try Self.blockingDependentCount(db: db, item: item)
        }
    }

    static func blockingDependentCount(db: Database, item: WorkItem) throws -> Int {
        let holder = try leaseHolderId(db: db, itemId: item.id) ?? item.ownerId ?? ""
        return try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM workItemDependency d JOIN workItem dep ON dep.id = d.itemId
            WHERE d.dependsOnId = ? AND dep.status <> 'done' AND NOT (d.linkedBy = ? AND dep.authorId = ?)
            """, arguments: [item.id, holder, holder]) ?? 0
    }

    // MARK: Engine status writes

    /// Engine-only status write for `inReview`, `done` and engine moves; no actor policy applies. `done` stamps `doneAt`,
    /// readies agents blocked on the item and tells the items that were waiting for it.
    @discardableResult
    func engineSetStatus(db: Database, itemId: String, to: WorkItemStatus, text: String? = nil, event: WorkEventKind = .statusChanged,
                         now: Date) throws -> WorkItem {
        guard var item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
        let from = item.status
        guard from != to else { return item }
        item.status = to
        if from == .blocked { item.blockedReason = nil; item.blockedSinceActive = nil }
        if from == .done { item.doneAt = nil }
        if to == .inProgress { item.everStarted = true }
        if to == .done { item.doneAt = now }
        // Merged: the escalation floor belongs to the work that just landed (design §3.4).
        if to.resetsRungFloor { item.rungFloor = 0 }
        item.updatedAt = now
        try item.update(db)
        if to == .done { try db.execute(sql: "DELETE FROM workLease WHERE itemId = ?", arguments: [item.id]) }
        try recordItemEvent(db: db, item: item, actor: "system", kind: event,
                            text: text ?? "\(from.title) → \(to.title)", now: now)
        if to == .done { try completeItem(db: db, item: item, now: now) }
        return item
    }

    /// Everything that follows an item becoming done, in this order: observers, its sprint's cadence, agents blocked on it, the
    /// items depending on it, then its container. Runs only from `engineSetStatus(to: .done)`, i.e. the merged path and the container rule.
    func completeItem(db: Database, item: WorkItem, now: Date) throws {
        for observer in observers { try observer.itemCompleted(item, db: db) }
        try sprintItemCompleted(db, item: item, now: now)
        var waiters: [String] = []
        for agent in try Agent.filter(Column("companyId") == item.companyId && Column("state") == AgentState.blocked.rawValue).fetchAll(db) {
            guard case .workItem(let id, _)? = agent.blocker, id == item.id else { continue }
            try Store.transition(db: db, agentId: agent.id, to: agent.paused ? .sleeping : .ready, now: now)
            waiters.append(agent.id)
        }
        if !waiters.isEmpty {
            try recordItemEvent(db: db, item: item, actor: "system", kind: .dependencyDone, text: "\(item.key) is done",
                                alsoNotify: waiters, alsoNotifyRole: .waiter, onlyAlsoNotify: true, now: now)
        }
        let dependents = try WorkItem.fetchAll(db, sql: """
            SELECT workItem.* FROM workItem JOIN workItemDependency d ON d.itemId = workItem.id
            WHERE d.dependsOnId = ? AND workItem.status <> 'done'
            """, arguments: [item.id])
        for d in dependents {
            try recordItemEvent(db: db, item: d, actor: "system", kind: .dependencyDone, text: "\(item.key) is done",
                                assigneeRole: .waiter, now: now)
        }
        try rollUpContainer(db: db, of: item, now: now)
    }

    /// The container rule: an epic or story whose children are all done is done itself (and so on up).
    private func rollUpContainer(db: Database, of item: WorkItem, now: Date) throws {
        // A parent is always a container (`requireParent`).
        guard let parentId = item.parentId, let parent = try WorkItem.fetchOne(db, key: parentId), parent.status != .done else { return }
        let open = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workItem WHERE parentId = ? AND status <> 'done'",
                                    arguments: [parent.id]) ?? 0
        guard open == 0 else { return }
        _ = try engineSetStatus(db: db, itemId: parent.id, to: .done, text: "all children are done", now: now)
    }

    // MARK: Events and notices

    /// Appends an item event and fans it out as notices to the item's assignee, reviewer and author (when an agent) plus
    /// `alsoNotify`, minus the actor and killed agents. A notice wakes its recipient only when the event is actionable for
    /// that role (`WakePolicy.noticeWakes`); a manager or executive is woken at most once per `WakePolicy.leadDebounce`
    /// active seconds unless the item holds up other work. Feed kinds also appear in the company activity feed.
    @discardableResult
    func recordItemEvent(db: Database, item: WorkItem, actor: String, kind: WorkEventKind, text: String,
                         alsoNotify: [String] = [], alsoNotifyRole: NoticeRecipientRole = .other,
                         assigneeRole: NoticeRecipientRole = .owner, onlyAlsoNotify: Bool = false, now: Date) throws -> WorkItemEvent {
        let text = try redact(text)
        let active = try Self.activeNow(db: db, companyId: item.companyId)
        var event = WorkItemEvent(id: nil, companyId: item.companyId, itemId: item.id, actorId: actor, kind: kind, text: text,
                                  createdAt: now, createdActive: active)
        try event.insert(db)
        guard let eventId = event.id else { throw StoreError.notFound }

        var order: [String] = []
        var roles: [String: Set<NoticeRecipientRole>] = [:]
        func add(_ id: String?, _ role: NoticeRecipientRole) {
            guard let id, id != actor, id != "owner", id != "system" else { return }
            if roles[id] == nil { order.append(id) }
            roles[id, default: []].insert(role)
        }
        if !onlyAlsoNotify {
            add(item.ownerId, assigneeRole)
            add(item.reviewerId, .reviewer)
            add(item.authorId, .author)
        }
        for id in alsoNotify { add(id, alsoNotifyRole) }

        let packId = try Company.fetchOne(db, key: item.companyId)?.packId ?? "software"
        var blocksOthers: Bool?
        for id in order {
            guard let agent = try Agent.fetchOne(db, key: id), agent.companyId == item.companyId, agent.state != .killed else { continue }
            let wakes = (roles[id] ?? []).contains { WakePolicy.noticeWakes(kind: kind, recipientRole: $0) }
            let lead = WorkPolicy.isLead(catalog.template(role: agent.role, pack: packId).kind)
            var wakeAfter: Double?
            if wakes, lead {
                if blocksOthers == nil { blocksOthers = try Self.blockingDependentCount(db: db, item: item) > 0 }
                if blocksOthers == false, let last = agent.lastNoticeWakeActive { wakeAfter = last + WakePolicy.leadDebounce }
            }
            var notice = WorkNotice(id: nil, agentId: id, eventId: eventId, deliveredTurnId: nil, wakes: wakes, wakeAfterActive: wakeAfter)
            try notice.insert(db)
            guard wakes, wakeAfter == nil || wakeAfter! <= active else { continue }
            if lead {
                try db.execute(sql: "UPDATE agent SET lastNoticeWakeActive = ? WHERE id = ?", arguments: [active, id])
            }
            if agent.state == .sleeping, !agent.paused { try Store.transition(db: db, agentId: id, to: .ready, now: now) }
        }

        if WorkEventKind.feed.contains(kind) {
            let isAgent = actor != "owner" && actor != "system"
            try ActivityEvent(companyId: item.companyId, agentId: isAgent ? actor : nil, turnId: nil, kind: .work,
                              text: "\(item.key) \(text)", createdAt: now).insert(db)
        }
        return event
    }

    /// What one turn takes from an agent's notices: up to `limit` to show, actionable ones first, and the rest of the
    /// FYIs collapsed to a count. Everything in `deliveredIds` is marked delivered when the turn succeeds.
    public struct NoticeBatch: Equatable, Sendable {
        public var shown: [PendingNotice]
        /// FYI notices past the cap, delivered as a count only.
        public var collapsedIds: [Int64]
        public var deliveredIds: [Int64] { shown.compactMap(\.notice.id) + collapsedIds }
    }

    /// Undelivered notices to show, due waking ones first (oldest first), then the rest oldest first, at most `limit`.
    /// A waking notice that is not yet due counts as an FYI here. Actionable notices beyond `limit` stay pending.
    public func pendingNotices(agentId: String, limit: Int = 30) throws -> [PendingNotice] {
        try noticeBatch(agentId: agentId, limit: limit, collapseOverflow: false).shown
    }

    public func noticeBatch(agentId: String, limit: Int = 30) throws -> NoticeBatch {
        try noticeBatch(agentId: agentId, limit: limit, collapseOverflow: true)
    }

    private func noticeBatch(agentId: String, limit: Int, collapseOverflow: Bool) throws -> NoticeBatch {
        try writer.read { db in
            guard let agent = try Agent.fetchOne(db, key: agentId) else { return NoticeBatch(shown: [], collapsedIds: []) }
            let active = try Store.activeNow(db: db, companyId: agent.companyId)
            let all = try WorkNotice.filter(Column("agentId") == agentId && Column("deliveredTurnId") == nil)
                .order(Column("id")).fetchAll(db)
            let due = all.filter { $0.wakes && ($0.wakeAfterActive ?? 0) <= active }
            let dueIds = Set(due.compactMap(\.id))
            let fyi = all.filter { !dueIds.contains($0.id ?? -1) }
            let actionable = Array(due.prefix(limit))
            let room = max(limit - actionable.count, 0)
            let shownFYI = Array(fyi.prefix(room))
            let collapsed = collapseOverflow && actionable.count < limit ? fyi.dropFirst(room).compactMap(\.id) : []
            let shown = try (actionable + shownFYI).compactMap { n -> PendingNotice? in
                guard let event = try WorkItemEvent.fetchOne(db, key: n.eventId),
                      let key = try String.fetchOne(db, sql: "SELECT key FROM workItem WHERE id = ?", arguments: [event.itemId])
                else { return nil }
                return PendingNotice(notice: n, event: event, itemKey: key)
            }
            return NoticeBatch(shown: shown, collapsedIds: Array(collapsed))
        }
    }

    public func markNoticesDelivered(ids: [Int64], turnId: String) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in try Store.markNoticesDelivered(db: db, ids: ids, turnId: turnId) }
    }

    static func markNoticesDelivered(db: Database, ids: [Int64], turnId: String) throws {
        guard !ids.isEmpty else { return }
        try WorkNotice.filter(ids.contains(Column("id"))).updateAll(db, Column("deliveredTurnId").set(to: turnId))
    }

    /// Whether the agent has something to act on: a waking inbox item, a pending review, a waking notice that is due, or a
    /// lease on an `inProgress` item whose last turn did not report `BLOCKED` or `NEEDS_CONTEXT` (the work goes on). Non-waking
    /// notices and debounced notices that are not yet due do not count.
    static func hasPendingWork(db: Database, agentId: String) throws -> Bool {
        if try hasPendingReview(db: db, agentId: agentId) { return true }
        if try hasPendingAudit(db: db, agentId: agentId) { return true }
        let inbox = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inboxItem WHERE agentId = ? AND deliveredTurnId IS NULL AND wakes = 1",
                                     arguments: [agentId]) ?? 0
        if inbox > 0 { return true }
        guard let agent = try Agent.fetchOne(db, key: agentId) else { return false }
        let active = try activeNow(db: db, companyId: agent.companyId)
        let due = (try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM workNotice WHERE agentId = ? AND deliveredTurnId IS NULL AND wakes = 1
            AND (wakeAfterActive IS NULL OR wakeAfterActive <= ?)
            """, arguments: [agentId, active]) ?? 0) > 0
        if due { return true }
        return try holdsActionableLease(db: db, agentId: agentId)
    }

    /// The agent holds an `inProgress` item and has not said it is stuck: it keeps working (the watchdog bounds a loop).
    static func holdsActionableLease(db: Database, agentId: String) throws -> Bool {
        guard try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM workLease JOIN workItem ON workItem.id = workLease.itemId
            WHERE workLease.agentId = ? AND workItem.status = 'inProgress'
            """, arguments: [agentId]) ?? 0 > 0 else { return false }
        let last = try String.fetchOne(db, sql: """
            SELECT reportedStatus FROM turn WHERE agentId = ? AND outcome <> 'inProgress' AND kind IN ('work', 'plan', 'notice')
            ORDER BY startedAt DESC, rowid DESC LIMIT 1
            """, arguments: [agentId])
        return !TurnStatus.isBlocked(last)
    }

    /// Whether launching a turn for this agent would have anything to do (the engine skips an empty turn).
    func hasActionableWork(agentId: String) throws -> Bool {
        try writer.read { db in try Store.hasPendingWork(db: db, agentId: agentId) }
    }

    /// The tick's wake for debounced notices: sleeping, unpaused agents whose waking notices have come due become ready.
    /// Returns the number woken.
    @discardableResult
    func wakeDueNotices(now: Date) throws -> Int {
        try writer.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT agent.id AS id, COALESCE(ca.activeSeconds, 0) AS active FROM agent
                JOIN workNotice n ON n.agentId = agent.id
                LEFT JOIN companyActivity ca ON ca.companyId = agent.companyId
                WHERE agent.state = 'sleeping' AND agent.paused = 0 AND n.deliveredTurnId IS NULL AND n.wakes = 1
                AND (n.wakeAfterActive IS NULL OR n.wakeAfterActive <= COALESCE(ca.activeSeconds, 0))
                """)
            for row in rows {
                let id: String = row["id"], active: Double = row["active"]
                try db.execute(sql: "UPDATE agent SET lastNoticeWakeActive = ? WHERE id = ?", arguments: [active, id])
                try Store.transition(db: db, agentId: id, to: .ready, now: now)
            }
            return rows.count
        }
    }
}

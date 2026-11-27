import Foundation
import GRDB

/// Whether a reader may read a ref: in full (with C's access word), locked behind an approver role, or refused.
public enum RefDecision: Equatable, Sendable {
    case allowed(RefAccessLabel)
    case locked(approverRole: String)
    case refused
}

/// Read access for refs (design §4.2), decided by ML's one access engine (`MemoryAccess.level`) with no second predicate.
/// `canRead` decides the class only: it does not prove that the object exists or that it is this company's (a file path or
/// a commit sha is decided without git). Existence and company membership are the resolver's (`Store.resolveRef`, which
/// shows an unknown or another company's object as `.missing`). Every row lookup is still bound to the company
/// (`companyId = ?`), a row it does not find is `.refused`, and so is a reader of another company.
///
/// The class per kind: file, diff, commit, item, run, artifact, preview, release, agent and sprint are company; a `.brahma`
/// lab, home or notes path is private to its agent; a message or thread follows its channel (members, else locked) or DM
/// (participants, else refused); a channel its members; a resource its stored scope, reader set and future holders (a
/// flagged one is secret); a kb page its page restriction (and a named section's markers); a memory entry its memory doc;
/// an ask ML's per-party class (owner, requester, internal approver, decider; else refused); a fact the owner's.
public enum RefAccess {
    /// `catalog` is the store's (`Store.catalog`): roles and executive seats are read from it.
    public static func canRead(_ reader: Reader, _ ref: WorkRef, companyId: String, db: Database,
                               catalog: PackCatalog) throws -> RefDecision {
        guard let ctx = try readerContext(reader, companyId: companyId, db: db, catalog: catalog),
              let subject = try subject(ref, companyId: companyId, db: db) else { return .refused }
        return decide(ctx, subject)
    }

    /// Nil for an agent that is not of this company.
    static func readerContext(_ reader: Reader, companyId: String, db: Database, catalog: PackCatalog) throws -> ReaderContext? {
        do {
            return try ReaderContext.load(db: db, catalog: catalog, companyId: companyId, reader: reader)
        } catch WorkError.forbidden(_) {
            return nil
        }
    }

    static func decide(_ ctx: ReaderContext, _ s: Subject) -> RefDecision {
        if s.forbiddenPlace { return .refused }
        let level = MemoryAccess.level(ctx, access: s.access, sensitivity: s.sensitivity, readerSet: s.readerSet,
                                       restrictions: s.restrictions, futureHolders: s.futureHolders)
        if case .full = level {
            return .allowed(RefAccessLabel.label(access: s.access, sensitivity: s.sensitivity, restrictions: s.restrictions,
                                                 readerSet: s.readerSet))
        }
        if s.sensitivity == .hrPerf || s.sensitivity == .secret || s.access == .ownerOnly || s.refusedWhenUnreadable {
            return .refused
        }
        return .locked(approverRole: "owner")
    }

    // MARK: Subjects

    /// The object a ref names, as the access engine and the resolver read it.
    struct Subject {
        var access: AccessClass = .company
        var sensitivity: Sensitivity = .normal
        var readerSet: Set<String>?
        var restrictions: [Restriction] = []
        var futureHolders = false
        /// A non-reader is refused, not offered an approver (a DM, an ask, an agent's private place, a fact).
        var refusedWhenUnreadable = false
        /// A `.brahma` place no ref may name (outside SafeFS's allowlist and the agents' labs and notes): refused for every
        /// reader, before any filesystem access, so an existing and a missing one look the same.
        var forbiddenPlace = false
        var record: Record
    }

    enum Record {
        /// A tracked path (main or an item branch) or a worktree path; `place` is the agent handle of a private `.brahma` place.
        case file(place: String?)
        case diff(WorkItem)
        /// C5b's `diff:<sha>..<sha>` (company class, like a commit; both revs verified reachable when resolved).
        case diffRange
        case commit
        case item(WorkItem, ownerHandle: String?)
        case ask(Ask)
        case kb(KBPage, section: String?)
        case memory(MemoryEntry, authorHandle: String)
        case resource(Resource)
        /// 4a's `AR-<n>`: its copy under `.brahma/artifacts/<number>-<slug>/`, opened at its entry file.
        case artifact(Artifact)
        case preview(PreviewSurface, status: PreviewStatus?)
        case run(VerificationRun, itemKey: String)
        case release(version: String, status: String)
        case message(Message, Channel)
        case agent(Agent)
        case channel(Channel, members: Int)
        case sprint(Sprint)
        case fact
    }

    /// The object of this company `ref` names, or nil (unknown or another company's).
    static func subject(_ ref: WorkRef, companyId: String, db: Database) throws -> Subject? {
        switch ref.kind {
        case .file:
            if let key = ref.itemKey {
                guard let item = try item(db, companyId, key) else { return nil }
                // C5b-2: a live worktree file (no pinned blob) follows the live worktree rule like the live diff.
                if ref.isWorktree, ref.rev == nil, ref.params["share"] == nil { return try liveDiffSubject(db, companyId, item, record: .file(place: nil)) }
            }
            if isForbiddenPlace(ref.id) { return Subject(forbiddenPlace: true, record: .file(place: nil)) }
            guard let place = privatePlace(ref) else { return Subject(record: .file(place: nil)) }
            guard ref.branch == nil, ref.rev == nil,
                  let agent = try Agent.fetchOne(db, sql: "SELECT * FROM agent WHERE companyId = ? AND name = ?",
                                                 arguments: [companyId, place]) else { return nil }
            return Subject(access: .agent(agent.id), readerSet: [agent.id], refusedWhenUnreadable: true, record: .file(place: place))
        case .diff:
            // Plan C Task C5b: the key-less forms.
            if ref.id.isEmpty {
                if let handle = ref.params["wt"] {
                    guard let item = try worktreeTarget(db, companyId, handle: handle) else { return nil }
                    return try liveDiffSubject(db, companyId, item)
                }
                guard ref.params["from"] != nil, ref.params["to"] != nil else { return nil }
                return Subject(record: .diffRange)
            }
            guard let item = try item(db, companyId, ref.id) else { return nil }
            if ref.isWorktree, ref.params["snapshot"] == nil, ref.rev == nil { return try liveDiffSubject(db, companyId, item) }
            return Subject(record: .diff(item))
        case .commit:
            return Subject(record: .commit)
        case .item:
            guard let item = try item(db, companyId, ref.id) else { return nil }
            let owner = try item.ownerId.flatMap { try handle(db, companyId, $0) }
            return Subject(record: .item(item, ownerHandle: owner))
        case .ask:
            guard let n = Int(ref.id), let ask = try Ask.fetchOne(db, sql: "SELECT * FROM ask WHERE companyId = ? AND number = ?",
                                                                  arguments: [companyId, n]) else { return nil }
            let scope = try MemoryIngest.askScope(ask) { h in
                try String.fetchOne(db, sql: "SELECT id FROM agent WHERE companyId = ? AND name = ?", arguments: [companyId, h])
            }
            return Subject(access: scope.access, sensitivity: scope.sensitivity, readerSet: scope.readerSet,
                           restrictions: scope.restrictions, refusedWhenUnreadable: true, record: .ask(ask))
        case .kb:
            guard let page = try Store.kbPage(db: db, companyId: companyId, path: ref.id) else { return nil }
            var restrictions: [Restriction] = page.pageRestriction.map { [$0] } ?? []
            let section = ref.params["section"]
            if let section {
                let slug = KBMarkdown.slug(section)
                if let s = KBMarkdown.sections(page.body, page: page.pageRestriction).first(where: { $0.slug == slug }) {
                    restrictions = s.restrictions
                }
            }
            return Subject(restrictions: restrictions, record: .kb(page, section: section))
        case .memory:
            guard let n = Int(ref.id), let entry = try MemoryEntry.fetchOne(db, sql: """
                SELECT * FROM memoryEntry WHERE companyId = ? AND number = ? AND removedAt IS NULL AND purgedAt IS NULL
                """, arguments: [companyId, n]) else { return nil }
            let author = try handle(db, companyId, entry.authorId) ?? entry.authorId
            var s = Subject(access: entry.access ?? .ownerOnly, record: .memory(entry, authorHandle: author))
            // The memory doc carries what ML decided for it (sensitivity, reader set, restrictions); its fields fail closed.
            if let doc = try Row.fetchOne(db, sql: """
                SELECT * FROM memoryDoc WHERE companyId = ? AND source = 'memory' AND ref = ? AND removedAt IS NULL
                ORDER BY updatedAt DESC LIMIT 1
                """, arguments: [companyId, entry.ref]) {
                let decoder = JSONDecoder()
                guard let access = AccessClass(kind: doc["accessKind"], id: doc["accessId"]),
                      let sensitivity = Sensitivity(rawValue: doc["sensitivity"]),
                      let restrictions = try? decoder.decode([[String]].self, from: Data((doc["restrictions"] as String).utf8))
                else { return Subject(access: .ownerOnly, record: s.record) }
                if let raw: String = doc["readerSet"] {
                    guard let ids = try? decoder.decode([String].self, from: Data(raw.utf8)) else {
                        return Subject(access: .ownerOnly, record: s.record)
                    }
                    s.readerSet = Set(ids)
                }
                s.access = access
                s.sensitivity = sensitivity
                s.restrictions = restrictions.map(Set.init)
                s.futureHolders = doc["futureHolders"]
            }
            return s
        case .artifact:
            // 4a's published artifact (company class, like the preview pane that shows it). Its taint is `Store.artifactTaint`'s:
            // the row's flag, and its source's provenance (rulings 16 and 17).
            guard let n = Int(ref.id), let artifact = try artifact(db, companyId, number: n) else { return nil }
            return Subject(record: .artifact(artifact))
        case .resource:
            guard let n = Int(ref.id), let r = try Store.resource(db: db, companyId: companyId, number: n), r.removedAt == nil
            else { return nil }
            return Subject(access: r.scope, sensitivity: r.secretScan == .flagged ? .secret : .normal, readerSet: r.readerSet,
                           futureHolders: r.futureHolders, record: .resource(r))
        case .preview:
            guard let surface = try PreviewSurface.fetchOne(db, sql: "SELECT * FROM previewSurface WHERE companyId = ? AND name = ?",
                                                            arguments: [companyId, ref.id]) else { return nil }
            let state = try PreviewState.fetchOne(db, sql: "SELECT * FROM previewState WHERE companyId = ? AND surfaceId = ?",
                                                  arguments: [companyId, surface.id])
            return Subject(record: .preview(surface, status: state?.status))
        case .run:
            let run: VerificationRun?
            if let key = ref.params["item"] {
                guard let item = try item(db, companyId, key) else { return nil }
                run = try VerificationRun.fetchOne(db, sql: """
                    SELECT * FROM verificationRun WHERE companyId = ? AND itemId = ? ORDER BY createdAt DESC, rowid DESC LIMIT 1
                    """, arguments: [companyId, item.id])
            } else {
                run = try VerificationRun.fetchOne(db, sql: "SELECT * FROM verificationRun WHERE companyId = ? AND id = ?",
                                                   arguments: [companyId, ref.id])
            }
            guard let run else { return nil }
            let key = try String.fetchOne(db, sql: "SELECT key FROM workItem WHERE companyId = ? AND id = ?",
                                          arguments: [companyId, run.itemId]) ?? "?"
            return Subject(record: .run(run, itemKey: key))
        case .release:
            guard let n = Int(ref.id), let row = try Row.fetchOne(db, sql: "SELECT version, status FROM release WHERE companyId = ? AND number = ?",
                                                                  arguments: [companyId, n]) else { return nil }
            return Subject(record: .release(version: row["version"], status: row["status"]))
        case .message, .thread:
            guard let m = try Message.fetchOne(db, sql: "SELECT * FROM message WHERE companyId = ? AND id = ?",
                                               arguments: [companyId, ref.id]),
                  let channel = try Channel.fetchOne(db, sql: "SELECT * FROM channel WHERE companyId = ? AND id = ?",
                                                     arguments: [companyId, m.channelId]) else { return nil }
            let dm = channel.kind == .dm
            return Subject(access: dm ? .dm(channel.id) : .channel(channel.id), refusedWhenUnreadable: dm, record: .message(m, channel))
        case .agent:
            guard let agent = try Agent.fetchOne(db, sql: "SELECT * FROM agent WHERE companyId = ? AND name = ?",
                                                 arguments: [companyId, ref.id]) else { return nil }
            return Subject(record: .agent(agent))
        case .channel:
            guard let channel = try Channel.fetchOne(db, sql: "SELECT * FROM channel WHERE companyId = ? AND name = ? AND kind = 'channel'",
                                                     arguments: [companyId, ref.id]) else { return nil }
            let members = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM channelMember m JOIN channel c ON c.id = m.channelId WHERE m.channelId = ? AND c.companyId = ?
                """, arguments: [channel.id, companyId]) ?? 0
            return Subject(access: .channel(channel.id), record: .channel(channel, members: members))
        case .sprint:
            guard let n = Int(ref.id), let sprint = try Sprint.fetchOne(db, sql: "SELECT * FROM sprint WHERE companyId = ? AND number = ?",
                                                                        arguments: [companyId, n]) else { return nil }
            return Subject(record: .sprint(sprint))
        case .fact:
            return Subject(access: .ownerOnly, refusedWhenUnreadable: true, record: .fact)
        }
    }

    /// The agent handle owning a private `.brahma` place the path is in (`labs/<h>/…`, `notes/agents/<h>.md`), or nil for
    /// any other path. (`home/<h>` is never shareable: SafeFS refuses it, so it is a forbidden place.)
    static func privatePlace(_ ref: WorkRef) -> String? {
        let parts = ref.id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == ".brahma" else { return nil }
        switch parts[1] {
        case "labs": return parts[2]
        case "notes" where parts.count == 4 && parts[2] == "agents" && parts[3].hasSuffix(".md"): return String(parts[3].dropLast(3))
        default: return nil
        }
    }

    /// A `.brahma/…` path that is neither under one of `SafeFS.brahmaAllowlist`'s children nor a private place (a lab or an
    /// agent's notes file): `home`, `checks`, team notes, `wt`, the vault-like rest.
    static func isForbiddenPlace(_ path: String) -> Bool {
        guard path == ".brahma" || path.hasPrefix(".brahma/") else { return false }
        let rest = String(path.dropFirst(".brahma/".count))
        if SafeFS.brahmaAllowlist.contains(where: { rest.hasPrefix($0 + "/") }) { return false }
        return privatePlace(WorkRef(kind: .file, id: path)) == nil
    }

    /// Plan C Task C5b, the live worktree rule: an unpinned live diff (`@worktree`, `:changes`, `wt:`, `@r<n>..worktree`) is
    /// readable by the owner, the concierge, the lease holder (else the assignee) and the item's reviewer; any other agent
    /// is refused (never offered an approver). Pinned snapshots keep the company class.
    static func liveDiffSubject(_ db: Database, _ companyId: String, _ item: WorkItem, record: Record? = nil) throws -> Subject {
        var readers: Set<String> = []
        if let holder = try Store.leaseHolderId(db: db, itemId: item.id) { readers.insert(holder) }
        if let assignee = item.ownerId { readers.insert(assignee) }
        if let reviewer = item.reviewerId { readers.insert(reviewer) }
        return Subject(readerSet: readers, refusedWhenUnreadable: true, record: record ?? .diff(item))
    }

    /// The item whose lease the agent `handle` of this company holds now (the most recent lease), for `wt:@handle`.
    static func worktreeTarget(_ db: Database, _ companyId: String, handle: String) throws -> WorkItem? {
        try WorkItem.fetchOne(db, sql: """
            SELECT workItem.* FROM workLease JOIN agent ON agent.id = workLease.agentId JOIN workItem ON workItem.id = workLease.itemId
            WHERE agent.companyId = ? AND agent.name = ? AND workLease.companyId = ? AND workItem.companyId = ?
            ORDER BY workLease.acquiredAt DESC LIMIT 1
            """, arguments: [companyId, handle, companyId, companyId])
    }

    static func item(_ db: Database, _ companyId: String, _ key: String) throws -> WorkItem? {
        try WorkItem.fetchOne(db, sql: "SELECT * FROM workItem WHERE companyId = ? AND key = ?", arguments: [companyId, key])
    }

    /// 4a's `Store.artifact(companyId:number:)` inside a read the caller holds.
    static func artifact(_ db: Database, _ companyId: String, number: Int) throws -> Artifact? {
        try Artifact.filter(Column("companyId") == companyId && Column("number") == number).fetchOne(db)
    }

    /// The folder name of an artifact whose row has 4a's shape (`storedPath` exactly `.brahma/artifacts/<folder>`, not a dot
    /// folder; `entryFile` a relative path with no empty, `.` or `..` part), else nil: nothing else is ever opened for it.
    static func artifactFolder(_ a: Artifact) -> String? {
        let folder = (a.storedPath as NSString).lastPathComponent
        let entry = a.entryFile.split(separator: "/", omittingEmptySubsequences: false)
        guard a.storedPath == ".brahma/artifacts/\(folder)", !folder.isEmpty, !folder.hasPrefix("."), !entry.isEmpty,
              entry.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return folder
    }

    static func handle(_ db: Database, _ companyId: String, _ agentId: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT name FROM agent WHERE companyId = ? AND id = ?", arguments: [companyId, agentId])
    }
}

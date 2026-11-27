import Foundation
import GRDB

/// Plan C Task C6: what the app renders for a ref the owner opened. `data` is THE bytes to draw (`Store.gatedBytes`: a PDF the
/// owner vouched for is its flattened copy); `text` is set when the engine composed the content as text (a patch, a page, a
/// message, a run's log, a fact), already through the gate. `verdict` is the gate's: `.pattern` on text means the app
/// redacts what it shows (`RedactedCopy.make`).
public struct RefRender: Sendable {
    public var ref: WorkRef
    public var data: Data
    public var text: String?
    public var ext: String
    public var rev: String?
    public var verdict: ScanVerdict
    public var tainted: Bool
    public var taintReason: String?
}

extension Store {
    /// The `refRead.via` of an open in the preview's OPENED tab (design §4.7: "preview tab open").
    public static let tabReadVia = "tab"
    /// The `refRead.via` of a chat inspector open.
    public static let inspectorReadVia = "inspector"

    /// The owner's render point (C6 `RefBodies`): `ref` resolved for the owner, its bytes read as the engine reads them
    /// (`readContent`), then the gate (`gateRef(purpose: .render)`, which serves bytes through `gatedBytes`; a stored secret's
    /// value refuses, a flattened copy replaces a vouched PDF), and a `refRead(via:)` row when `via` is given (a card preview
    /// passes nil: it is not a read). Anything but `.full` is `Store.refUnavailable`; a purged ref `Store.purgedText`.
    public func renderRef(companyId: String, ref: WorkRef, knownValues: [(name: String, value: String)], paths: BrahmaPaths,
                          archives: any ArchiveReader, via: String?, now: Date = Store.now()) throws -> RefRender {
        let r = try resolveDetailed(ref, reader: .owner, companyId: companyId, messageRefId: nil)
        guard r.resolved.visibility == .full, let subject = r.subject, let company = r.company else {
            throw WorkError.notFound(Self.refUnavailable)
        }
        guard r.resolved.state != .purged else { throw WorkError.invalid(Self.purgedText) }
        let content: Content
        do {
            content = try readContent(r, subject: subject, company: company, paths: paths, whole: false, knownValues: knownValues)
        } catch let e as WorkError {
            throw e
        } catch {
            if !(error is VaultError), !(error is SafeGitError), !(error is SafeFSError) { throw error }
            throw WorkError.notFound(Self.refUnavailable)
        }
        let canonical = ref.canonical
        // C6 fix round 1 (I1): strictly `gatedBytes` (a stored value refuses; a vouched PDF is its flattened copy), and the
        // verdict honoured here, so the app never sees a pattern: redactable text is served redacted (`redactedCopy`, checked
        // again through the gate), anything else holding a pattern is refused.
        let g = try gatedBytes(content.data, ext: content.ext, canonical: canonical, companyId: companyId, archives: archives,
                               knownValues: knownValues, paths: paths)
        var data = g.data
        if case .pattern(let label, _) = g.verdict {
            guard SecretGate.isRedactable(data, ext: g.ext) else { throw Self.unredactable(canonical, label: label, knownValues: knownValues) }
            data = try SecretGate.redactedCopy(data, ext: g.ext, canonical: canonical, archives: archives, knownValues: knownValues, store: self)
        }
        let gated = (data: data, ext: g.ext, verdict: g.verdict)
        var text: String?
        if case .text = content.body { text = String(decoding: gated.data, as: UTF8.self) }
        if let via {
            try writer.write { db in
                try Self.recordRefRead(db: db, companyId: companyId, reader: .owner, canonical: canonical, rev: content.rev, bytes: content.size,
                                       tainted: r.resolved.tainted, via: via, turnId: nil, now: now)
            }
        }
        return RefRender(ref: r.pinned, data: gated.data, text: text, ext: gated.ext, rev: content.rev, verdict: gated.verdict,
                         tainted: r.resolved.tainted, taintReason: r.resolved.taintReason)
    }

    // MARK: The owner shares

    /// The owner shares `refs` (1–`ShareLimits.maxRefs`, each a ref the owner reads in full) with `to` (`@handle` or `#channel`),
    /// with an optional note, as a reply when `replyTo` names a message of that conversation. A share never widens access:
    /// every recipient (the DM's agent; a channel's agent members at share time) must read every ref, else the whole share is
    /// refused naming the first it can't read. Every ref passes the secret gate before anything is made, then is pinned
    /// (`pinRef` for the owner: blobs, snapshots, redacted copies; a commit off `main` held by its share ref), and one write
    /// transaction posts the `kind = share` message with its `messageRef` rows and a `.share` activity row. Whatever a failed
    /// share made is removed again. Owner callers only: no `CompanyTools` path reaches it.
    @discardableResult
    public func ownerShare(companyId: String, refs: [String], to: String, note: String?, replyTo: String?,
                           knownValues: [(name: String, value: String)], paths: BrahmaPaths, now: Date = Store.now(),
                           archives: any ArchiveReader = UnavailableArchiveReader()) throws -> Message {
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (1...ShareLimits.maxRefs).contains(refs.count) else { throw WorkError.invalid("share takes 1 to \(ShareLimits.maxRefs) refs") }
        guard note.count <= ShareLimits.noteMax else { throw WorkError.invalid("the note is at most \(ShareLimits.noteMax) characters") }
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        let target = try ShareTarget.parse(to)
        let context = RefContext(companyId: companyId, keyPrefixes: [Store.keyPrefix(slug: company.slug)])
        let catalog = self.catalog
        // The target and its recipients (agent ids, at share time); `replyTo` checked before anything is made.
        let (recipients, channelId, dmHandle): ([String], String?, String?) = try writer.read { db in
            switch target {
            case .dm(let handle):
                guard handle != "owner" else { throw WorkError.invalid("share with an agent or a channel") }
                guard let agent = try Agent.fetchOne(db, sql: "SELECT * FROM agent WHERE companyId = ? AND name = ?", arguments: [companyId, handle]),
                      agent.state != .killed else { throw RouterError.unknownAgent(handle) }
                if let replyTo {
                    let name = "dm:" + ["owner", handle].sorted().joined(separator: ":")
                    let dm = try String.fetchOne(db, sql: "SELECT id FROM channel WHERE companyId = ? AND name = ?", arguments: [companyId, name])
                    _ = try Store.replyRoot(db: db, companyId: companyId, channelId: dm, reference: replyTo, sender: .owner, catalog: catalog)
                }
                return ([agent.id], nil, handle)
            case .channel(let name):
                guard let channel = try Channel.fetchOne(db, sql: "SELECT * FROM channel WHERE companyId = ? AND name = ?",
                                                         arguments: [companyId, name]), channel.kind == .channel else {
                    throw RouterError.unknownChannel(name)
                }
                let members = try String.fetchAll(db, sql: "SELECT member FROM channelMember WHERE channelId = ? ORDER BY rowid", arguments: [channel.id])
                if let replyTo {
                    _ = try Store.replyRoot(db: db, companyId: companyId, channelId: channel.id, reference: replyTo, sender: .owner, catalog: catalog)
                }
                return (members.filter { $0 != "owner" && $0 != "system" }, channel.id, nil)
            }
        }
        // 1. Parse and resolve for the owner; every recipient must read every ref (no widening).
        struct Candidate { var ref: WorkRef; var resolution: Resolution; var rowId: String }
        var candidates: [Candidate] = []
        for (i, raw) in refs.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ref = WorkRef.parse(PasteableRef.decode(trimmed) ?? trimmed, context: context) else {
                throw WorkError.notFound(refs.count == 1 ? Self.refUnavailable : "ref \(i + 1) isn't available")
            }
            let rowId = Self.shareRowId(now: now)
            let r = try resolveDetailed(ref, reader: .owner, companyId: companyId, messageRefId: rowId)
            guard r.resolved.visibility == .full, let subject = r.subject, r.resolved.state != .purged else {
                throw WorkError.notFound(refs.count == 1 ? Self.refUnavailable : "ref \(i + 1) isn't available")
            }
            try writer.read { db in
                for recipient in recipients {
                    let decision = try RefAccess.canRead(.agent(recipient), ref, companyId: companyId, db: db, catalog: catalog)
                    guard case .allowed = decision else {
                        let handle = try RefAccess.handle(db, companyId, recipient) ?? recipient
                        let readers = try Self.readersText(db: db, companyId: companyId, subject)
                        throw WorkError.forbidden("@\(handle) can't read \(SecretGate.shown(Self.unpinned(ref).canonical, knownValues: knownValues)) "
                                                  + "(shared only with \(readers)). Widen its access first, or share something else.")
                    }
                }
            }
            candidates.append(Candidate(ref: ref, resolution: r, rowId: rowId))
        }
        // 2. The gate on every ref before anything is made (Ruling 43).
        for (i, c) in candidates.enumerated() {
            guard let subject = c.resolution.subject, let found = c.resolution.company else { throw WorkError.notFound(Self.refUnavailable) }
            let content: Content
            do {
                content = try readContent(c.resolution, subject: subject, company: found, paths: paths, whole: true, knownValues: knownValues)
            } catch let e as WorkError {
                throw e
            } catch {
                refTrace(companyId: companyId, "the owner's share's ref \(i + 1) couldn't be read (\(Store.flat("\(error)", max: 200)))", now: now)
                throw WorkError.notFound(Self.refUnavailable)
            }
            _ = try gateRef(content.data, ext: content.ext, canonical: c.ref.canonical, companyId: companyId, ref: c.ref, reader: .owner,
                            purpose: .check, archives: archives, knownValues: knownValues, paths: paths)
        }
        // 3. Pin each ref; whatever was made goes when a later step fails.
        var rows: [MessageRef] = []
        var shown: [String] = []
        var made: [ShareArtifact] = []
        do {
            for c in candidates {
                made.append(.shareRef(c.rowId))
                let pinned = try pinRef(c.ref, for: .owner, companyId: companyId, messageRefId: c.rowId, knownValues: knownValues, paths: paths,
                                        archives: archives)
                if pinned.kind == .resource, c.ref.kind != .resource, let n = Int(pinned.id) { made.append(.resource(n)) }
                if let snapshot = pinned.params["snapshot"], c.ref.params["snapshot"] == nil { made.append(.snapshot(snapshot)) }
                if [.file, .diff, .commit].contains(pinned.kind), !pinned.isWorktree, pinned.params["share"] == nil, let rev = pinned.rev {
                    let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
                    if !(try git.isAncestor(rev, of: "main")) { try git.updateShareRef(c.rowId, to: rev) }
                }
                let r = try resolveDetailed(pinned, reader: .owner, companyId: companyId, messageRefId: c.rowId)
                guard r.resolved.visibility == .full, let subject = r.subject else { throw WorkError.notFound(Self.refUnavailable) }
                rows.append(try Self.refRow(id: c.rowId, companyId: companyId, pinned: pinned, subject: subject, resolved: r.resolved,
                                            inline: false, now: now))
                shown.append(Self.shown(pinned))
            }
            // 4. One write: the message, its rows, the activity line.
            let router = MessageRouter(store: self)
            let inline = try inlineRefs(companyId: companyId, sender: .owner, text: note, channelId: channelId)
            let message = try writer.write { db -> Message in
                let message: Message
                switch target {
                case .channel(let name):
                    message = try router.post(db: db, companyId: companyId, channel: name, from: .owner, text: note, now: now, replyTo: replyTo,
                                              kind: .share, inline: inline, firstInlinePosition: rows.count).message
                case .dm:
                    message = try router.sendDM(db: db, companyId: companyId, from: .owner, to: dmHandle ?? "", text: note, now: now,
                                                replyTo: replyTo, kind: .share, inline: inline, firstInlinePosition: rows.count)
                }
                var stored: [MessageRef] = []
                for (i, var row) in rows.enumerated() {
                    row.messageId = message.id
                    row.position = i
                    try row.insert(db)
                    stored.append(row)
                }
                try Self.recordReferences(db: db, store: self, rows: stored, message: message, now: now)
                try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .share,
                                  text: "owner shared \(shown.joined(separator: ", ")) with \(target.shown)", createdAt: now).insert(db)
                return message
            }
            return message
        } catch {
            discardShareArtifacts(companyId: companyId, made, paths: paths, now: now)
            throw error
        }
    }

    // MARK: The owner replies in a thread

    /// The owner's reply in the thread of `rootId` (`msg:<id>`, `thread:<id>` or the bare id; a reply's id joins its root):
    /// in a channel through `MessageRouter.postDetailed` (so an `@here`/`@team` the router refuses in a reply comes back as
    /// `broadcastRefusal`, for the owner to see), in the owner's DM with an agent through `sendDM`. A message of another
    /// company, or of a conversation the owner is not part of, is `ThreadError.unavailable`.
    public func ownerThreadReply(companyId: String, rootId: String, text: String, now: Date = Store.now()) throws -> PostResult {
        var id = rootId
        for prefix in ["msg:", "thread:"] where id.hasPrefix(prefix) { id = String(id.dropFirst(prefix.count)) }
        let (channel, root): (Channel, Message) = try writer.read { db in
            guard let m = try Message.fetchOne(db, sql: "SELECT * FROM message WHERE companyId = ? AND id = ?", arguments: [companyId, id]),
                  let ch = try Channel.fetchOne(db, sql: "SELECT * FROM channel WHERE companyId = ? AND id = ?", arguments: [companyId, m.channelId])
            else { throw ThreadError.unavailable }
            return (ch, m)
        }
        let router = MessageRouter(store: self)
        switch channel.kind {
        case .channel:
            return try router.postDetailed(companyId: companyId, channel: channel.name, from: .owner, text: text, now: now, replyTo: root.id)
        default:
            let parts = channel.name.split(separator: ":").map(String.init)
            guard parts.count == 3, parts[0] == "dm", parts.contains("owner"), let other = parts.dropFirst().first(where: { $0 != "owner" }) else {
                throw ThreadError.unavailable
            }
            let message = try router.sendDM(companyId: companyId, from: .owner, to: other, text: text, now: now, replyTo: root.id)
            return PostResult(message: message, broadcastApplied: nil, broadcastRefusal: nil)
        }
    }

    // MARK: Owner reads

    /// The company's open show requests, oldest first (the waiting chips).
    public func openShowRequests(companyId: String) throws -> [ShowRequest] {
        try writer.read { db in
            try ShowRequest.fetchAll(db, sql: "SELECT * FROM showRequest WHERE companyId = ? AND status = 'open' ORDER BY createdAt, rowid",
                                     arguments: [companyId])
        }
    }

    /// One message of this company, or nil.
    public func message(companyId: String, id: String) throws -> Message? {
        try writer.read { db in try Message.fetchOne(db, sql: "SELECT * FROM message WHERE companyId = ? AND id = ?", arguments: [companyId, id]) }
    }

    /// The agent's spend today (owner time zone) as a share of the five-hour window, in percent (`ShowCost.share5h`).
    public func agentUsageShareToday(agentId: String, now: Date) throws -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ownerTimeZone()
        let start = cal.startOfDay(for: now)
        let usd = try writer.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUSD), 0) FROM turn WHERE agentId = ? AND startedAt >= ?",
                                arguments: [agentId, start]) ?? 0
        }
        return ShowCost.share5h(usd, calibration: try usageCalibration())
    }

    /// Records the owner's read of a ref the app rendered without bytes of its own (an item, an ask, a page, a thread, a fact):
    /// one `refRead` row with `via`.
    public func recordOwnerRead(companyId: String, ref: WorkRef, via: String, tainted: Bool, now: Date = Store.now()) throws {
        try writer.write { db in
            try Self.recordRefRead(db: db, companyId: companyId, reader: .owner, canonical: ref.canonical, rev: ref.rev, bytes: nil, tainted: tainted,
                                   via: via, turnId: nil, now: now)
        }
    }

    /// The key of the item `agentId` holds a lease on, or nil.
    public func leasedItemKey(companyId: String, agentId: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT w.key FROM workLease l JOIN workItem w ON w.id = l.itemId WHERE l.companyId = ? AND l.agentId = ? ORDER BY l.acquiredAt DESC LIMIT 1
                """, arguments: [companyId, agentId])
        }
    }

    /// The newest `limit` activity lines of one agent in the company (its turns, tools, messages, errors), oldest first.
    public func agentActivity(companyId: String, agentId: String, limit: Int) throws -> [ActivityEvent] {
        try writer.read { db in
            try ActivityEvent.fetchAll(db, sql: """
                SELECT * FROM activityEvent WHERE companyId = ? AND agentId = ? ORDER BY id DESC LIMIT ?
                """, arguments: [companyId, agentId, limit]).reversed()
        }
    }
}

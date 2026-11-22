import Foundation
import GRDB

/// Plan C Task C3b: the bounds of a share and of a post's attachments.
public enum ShareLimits {
    public static let maxRefs = 6
    public static let noteMax = 600
}

/// Where a message that names a ref is, for one reader (`Store.backlinks`): the message id and an engine-written title, or
/// for a DM the reader can't read only `"mentioned in a conversation"` (no id).
public struct Backlink: Equatable, Sendable {
    public var messageId: String?
    public var title: String

    public init(messageId: String?, title: String) { self.messageId = messageId; self.title = title }
}

extension MessageRef {
    /// The ref this row holds, as it was pinned (nil for a row whose kind or params can't be read: it opens nothing).
    public var workRef: WorkRef? {
        guard let kind = WorkRefKind(rawValue: kind),
              let params = try? JSONDecoder().decode([String: String].self, from: Data(params.utf8)) else { return nil }
        var range: LineRange?
        if let start = rangeStart, let end = rangeEnd {
            guard let checked = LineRange.checked(start: start, end: end) else { return nil }
            range = checked
        }
        return WorkRef(kind: kind, id: refId, branch: branch, rev: rev, range: range, params: params)
    }
}

/// A share's or a post's target: a DM (`@handle`, `@owner`) or a channel (`#name`).
enum ShareTarget: Equatable {
    case dm(String)
    case channel(String)

    static func parse(_ to: String) throws -> ShareTarget {
        let t = to.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("@"), t.count > 1 { return .dm(String(t.dropFirst()).lowercased()) }
        if t.hasPrefix("#"), t.count > 1 { return .channel(Store.normalizeChannelName(t)) }
        throw WorkError.invalid("to is @handle or #channel")
    }

    var shown: String {
        switch self {
        case .dm(let h): "@\(h)"
        case .channel(let c): "#\(c)"
        }
    }
}

/// One ref made ready for a message: its row (without the message), what the reply calls it, and the share ref made for it.
struct PreparedRef {
    var row: MessageRef
    var shown: String
    var shareRefMade: Bool
}

extension Store {
    static let taintedPrivateRefusal = "you've read external content this session, so you can't send private files; start fresh or share a workspace file"

    // MARK: share

    /// The `share` tool (design §3): sends 1–`ShareLimits.maxRefs` refs to `to` (`"@h"`, `"@owner"` or `"#channel"`) as one
    /// `kind = share` message whose text is `note` (at most `ShareLimits.noteMax` characters; `@mentions` in it wake as
    /// usual; `replyTo` threads it). Steps, all before anything is posted (`prepareRefs`):
    /// 1. each ref is parsed with `context` and resolved for the sender: anything but `.full` is `"ref <n> isn't available to
    ///    you"` (`"that ref isn't available to you"` for one ref); another agent's lab, home or notes file is `"that file is
    ///    private to @<h>"`; a `.brahma` place outside the allowlist is the generic text;
    /// 2. a file of the sender's own lab or notes is sent as a private snapshot (`snapshotPrivateFile`) that only the
    ///    recipients at share time and the sender can read; refused (`taintedPrivateRefusal`) when the sender's session read
    ///    outside content and `replyTo` is set;
    /// 3. in a DM the recipient must be able to read every ref, else the whole share is refused back (`"@<h> can't read
    ///    <canonical> (shared only with <readers>). Ask the owner to widen it with request_access, or share something
    ///    else."`) and no ask is filed;
    /// 4. each ref's bytes pass the secret gate (`Store.gatedBytes` with `knownValues` and `archives`, which must carry the
    ///    sandboxed unzip reader and PDF helper; without them archives and PDFs are refused);
    /// 5. `pinRef` (and for a commit pin not on `main` its share ref, `updateShareRef`, so a merged and deleted branch still
    ///    opens what was shared).
    /// Then one write transaction posts the message (stamped with the sender's session taint, like every agent-authored
    /// message), its `messageRef` rows and one `.share` activity row. Every refusal of access writes an `.access` row.
    /// `share(msg:<id>)` is a quote: readers who can read the source see its text as stored (`attachmentLines`), others a
    /// locked chip; a message of a DM with the owner is shown only in that same DM.
    /// Returns `"Shared <canonical> @<sha7> with @<h>."` (no `@<sha7>` for refs without a commit), or `"Shared <n> refs with
    /// <target>."` for more than one.
    public func share(companyId: String, by agentId: String, refs: [String], to: String, note: String?, replyTo: String?,
                      context: RefContext, knownValues: [(name: String, value: String)], paths: BrahmaPaths, now: Date,
                      archives: any ArchiveReader = UnavailableArchiveReader()) throws -> String {
        let note = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (1...ShareLimits.maxRefs).contains(refs.count) else { throw WorkError.invalid("share takes 1 to \(ShareLimits.maxRefs) refs") }
        guard note.count <= ShareLimits.noteMax else { throw WorkError.invalid("the note is at most \(ShareLimits.noteMax) characters") }
        let target = try ShareTarget.parse(to)
        let (_, prepared) = try postRefs(companyId: companyId, by: agentId, refs: refs, target: target, text: note, kind: .share,
                                         replyTo: replyTo, context: context, knownValues: knownValues, paths: paths, now: now,
                                         archives: archives)
        if prepared.count == 1, let one = prepared.first { return "Shared \(one.shown) with \(target.shown)." }
        return "Shared \(prepared.count) refs with \(target.shown)."
    }

    /// `attachments` on `post_message` / `send_dm`: the share's steps 1–5 for each ref (at most `ShareLimits.maxRefs`), then
    /// an ordinary `kind = text` message carrying them as rows (`inline = false`). `to` is `"#channel"` or `"@handle"`.
    public func postWithAttachments(companyId: String, by agentId: String, to: String, text: String, attachments: [String],
                                    replyTo: String?, context: RefContext, knownValues: [(name: String, value: String)],
                                    paths: BrahmaPaths, now: Date, archives: any ArchiveReader = UnavailableArchiveReader()) throws -> Message {
        try postWithAttachmentsDetailed(companyId: companyId, by: agentId, to: to, text: text, attachments: attachments, replyTo: replyTo,
                                        context: context, knownValues: knownValues, paths: paths, now: now, archives: archives).message
    }

    func postWithAttachmentsDetailed(companyId: String, by agentId: String, to: String, text: String, attachments: [String],
                                     replyTo: String?, context: RefContext, knownValues: [(name: String, value: String)],
                                     paths: BrahmaPaths, now: Date, archives: any ArchiveReader) throws -> PostResult {
        guard attachments.count <= ShareLimits.maxRefs else { throw WorkError.invalid("attachments takes at most \(ShareLimits.maxRefs) refs") }
        guard !attachments.isEmpty else { throw WorkError.invalid("attachments takes 1 to \(ShareLimits.maxRefs) refs") }
        let target = try ShareTarget.parse(to)
        return try postRefs(companyId: companyId, by: agentId, refs: attachments, target: target, text: text, kind: .text, replyTo: replyTo,
                            context: context, knownValues: knownValues, paths: paths, now: now, archives: archives).result
    }

    /// The rows of a message's refs (attachments, shares, quotes and inline chips), in their order. Bound to the company.
    public func messageRefs(companyId: String, messageId: String) throws -> [MessageRef] {
        try writer.read { db in
            try MessageRef.fetchAll(db, sql: "SELECT * FROM messageRef WHERE companyId = ? AND messageId = ? ORDER BY position, rowid",
                                    arguments: [companyId, messageId])
        }
    }

    // MARK: Steps

    /// Prepares `refs` (steps 1–5), then posts `text` with them in one write transaction. A transaction that fails leaves no
    /// message and drops the share refs made for it (best effort; a private snapshot already written stays in the vault,
    /// readable only by its readers).
    private func postRefs(companyId: String, by agentId: String, refs: [String], target: ShareTarget, text: String, kind: MessageKind,
                          replyTo: String?, context: RefContext, knownValues: [(name: String, value: String)], paths: BrahmaPaths,
                          now: Date, archives: any ArchiveReader) throws -> (result: PostResult, prepared: [PreparedRef]) {
        let prepared = try prepareRefs(companyId: companyId, agentId: agentId, refs: refs, target: target, replyTo: replyTo,
                                       context: context, knownValues: knownValues, paths: paths, now: now, archives: archives)
        let router = MessageRouter(store: self)
        let channelId: String?
        switch target {
        case .channel(let name): channelId = try channel(companyId: companyId, name: name)?.id
        case .dm: channelId = nil
        }
        let inline = try inlineRefs(companyId: companyId, sender: .agent(agentId), text: text, channelId: channelId)
        do {
            let result = try writer.write { db -> PostResult in
                let result: PostResult
                switch target {
                case .channel(let name):
                    result = try router.post(db: db, companyId: companyId, channel: name, from: .agent(agentId), text: text, now: now,
                                             replyTo: replyTo, kind: kind, inline: inline, firstInlinePosition: prepared.count)
                case .dm(let handle):
                    result = PostResult(message: try router.sendDM(db: db, companyId: companyId, from: .agent(agentId), to: handle, text: text,
                                                                   now: now, replyTo: replyTo, kind: kind, inline: inline,
                                                                   firstInlinePosition: prepared.count),
                                        broadcastApplied: nil, broadcastRefusal: nil)
                }
                var rows: [MessageRef] = []
                for (i, p) in prepared.enumerated() {
                    var row = p.row
                    row.messageId = result.message.id
                    row.position = i
                    try row.insert(db)
                    rows.append(row)
                }
                try Self.recordReferences(db: db, store: self, rows: rows, message: result.message, now: now)
                let handle = try RefAccess.handle(db, companyId, agentId) ?? agentId
                let what = kind == .share ? "shared" : "attached"
                try ActivityEvent(companyId: companyId, agentId: agentId, turnId: nil, kind: .share,
                                  text: "@\(handle) \(what) \(prepared.map(\.shown).joined(separator: ", ")) with \(target.shown)",
                                  createdAt: now).insert(db)
                return result
            }
            return (result, prepared)
        } catch {
            if let company = try? company(id: companyId), let git = try? refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true)) {
                for p in prepared where p.shareRefMade { try? git.deleteShareRef(p.row.id) }
            }
            throw error
        }
    }

    /// Steps 1–5 of a share for `refs` (see `share`). Throws the share's refusals (`WorkError`, `RouterError`, `ThreadError`).
    func prepareRefs(companyId: String, agentId: String, refs: [String], target: ShareTarget, replyTo: String?, context: RefContext,
                     knownValues: [(name: String, value: String)], paths: BrahmaPaths, now: Date,
                     archives: any ArchiveReader) throws -> [PreparedRef] {
        // The sender, the target and its recipients (agent ids, at share time), and `replyTo` checked before anything is made.
        let (sender, recipients, recipientHandle) = try writer.read { db -> (Agent, [String], String?) in
            guard let sender = try Agent.fetchOne(db, key: agentId), sender.companyId == companyId, sender.state != .killed else {
                throw RouterError.invalidSender
            }
            switch target {
            case .dm(let handle):
                let recipient: String
                if handle == "owner" {
                    recipient = "owner"
                } else {
                    guard let agent = try Agent.fetchOne(db, sql: "SELECT * FROM agent WHERE companyId = ? AND name = ?",
                                                         arguments: [companyId, handle]) else { throw RouterError.unknownAgent(handle) }
                    recipient = agent.id
                }
                guard handle != sender.name else { throw RouterError.invalidSender }
                if let replyTo {
                    let name = "dm:" + [sender.name, handle].sorted().joined(separator: ":")
                    let dm = try String.fetchOne(db, sql: "SELECT id FROM channel WHERE companyId = ? AND name = ?", arguments: [companyId, name])
                    _ = try Store.replyRoot(db: db, companyId: companyId, channelId: dm, reference: replyTo, sender: .agent(agentId), catalog: catalog)
                }
                return (sender, recipient == "owner" ? [] : [recipient], handle)
            case .channel(let name):
                guard let channel = try Channel.fetchOne(db, sql: "SELECT * FROM channel WHERE companyId = ? AND name = ?",
                                                         arguments: [companyId, name]), channel.kind == .channel else {
                    throw RouterError.unknownChannel(name)
                }
                let members = try String.fetchAll(db, sql: "SELECT member FROM channelMember WHERE channelId = ? ORDER BY rowid",
                                                  arguments: [channel.id])
                guard members.contains(agentId) else { throw RouterError.notAMember }
                if let replyTo {
                    _ = try Store.replyRoot(db: db, companyId: companyId, channelId: channel.id, reference: replyTo, sender: .agent(agentId),
                                            catalog: catalog)
                }
                return (sender, members.filter { $0 != "owner" && $0 != "system" && $0 != agentId }, nil)
            }
        }
        let reader = Reader.agent(agentId)
        var context = context
        context.companyId = companyId
        context.actingAgentId = agentId
        func refusal(_ error: WorkError) -> WorkError {
            recordAccessRefusal(companyId: companyId, agentId: agentId, handle: sender.name, target: target, reason: error.message, now: now)
            return error
        }
        func unavailable(_ n: Int) -> WorkError {
            refusal(.notFound(refs.count == 1 ? Store.refUnavailable : "ref \(n) isn't available to you"))
        }

        // 1. Parse and resolve for the sender; another agent's private place says whose it is.
        struct Candidate { var ref: WorkRef; var resolution: Resolution; var privateFile: Bool; var rowId: String }
        var candidates: [Candidate] = []
        for (i, raw) in refs.enumerated() {
            let n = i + 1
            guard let ref = WorkRef.parse(raw.trimmingCharacters(in: .whitespacesAndNewlines), context: context) else { throw unavailable(n) }
            var own = false
            if ref.kind == .file, let owner = Self.privateOwner(ref) {
                if owner != sender.name {
                    let exists = try writer.read { db in
                        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM agent WHERE companyId = ? AND name = ?)", arguments: [companyId, owner])
                    } ?? false
                    throw exists ? refusal(.forbidden("that file is private to @\(owner)")) : unavailable(n)
                }
                // The sender's own home is never shared (SafeFS refuses it); its lab and notes go as private snapshots.
                guard RefAccess.privatePlace(ref) != nil else { throw unavailable(n) }
                own = true
            }
            let rowId = UUID().uuidString
            let r: Resolution
            do { r = try resolveDetailed(ref, reader: reader, companyId: companyId, messageRefId: rowId) } catch { throw unavailable(n) }
            guard r.resolved.visibility == .full, r.subject != nil, r.resolved.state != .purged else { throw unavailable(n) }
            candidates.append(Candidate(ref: ref, resolution: r, privateFile: own, rowId: rowId))
        }

        // 2. A private file from a session that read outside content, as a reply: refused.
        if candidates.contains(where: \.privateFile), replyTo != nil,
           try currentTaint(agentId: agentId, paths: paths) != nil {
            throw refusal(.forbidden(Self.taintedPrivateRefusal))
        }

        // 3. A DM's recipient reads every ref (a private file becomes a snapshot it reads by construction).
        if case .dm(let handle) = target, let recipient = recipients.first {
            for c in candidates where !c.privateFile {
                let (decision, readers) = try writer.read { db -> (RefDecision, String) in
                    let decision = try RefAccess.canRead(.agent(recipient), c.ref, companyId: companyId, db: db, catalog: catalog)
                    guard case .allowed = decision else {
                        return (decision, try c.resolution.subject.map { try Self.readersText(db: db, companyId: companyId, $0) } ?? "its readers")
                    }
                    return (decision, "")
                }
                guard case .allowed = decision else {
                    throw refusal(.forbidden("@\(recipientHandle ?? handle) can't read \(Self.unpinned(c.ref).canonical) (shared only with \(readers)). "
                                             + "Ask the owner to widen it with request_access, or share something else."))
                }
            }
        }

        // 4. The secret gate on what the pin will not read itself (files, diffs and commits are gated by `pinRef`).
        for (i, c) in candidates.enumerated() where !c.privateFile && ![.file, .diff, .commit].contains(c.ref.kind) {
            guard let subject = c.resolution.subject, let company = c.resolution.company else { throw unavailable(i + 1) }
            let content: Content
            do {
                content = try readContent(c.resolution, subject: subject, company: company, paths: paths, whole: false, knownValues: knownValues)
            } catch let e as WorkError {
                throw e
            } catch {
                throw unavailable(i + 1)
            }
            _ = try gatedBytes(content.data, ext: content.ext, canonical: c.ref.canonical, companyId: companyId, archives: archives,
                               knownValues: knownValues, paths: paths)
        }

        // 5. Pin (or snapshot) each ref; a commit off `main` is held by its share ref.
        var prepared: [PreparedRef] = []
        do {
            for (i, c) in candidates.enumerated() {
                var pinned: WorkRef
                var shareRefMade = false
                if c.privateFile {
                    pinned = try snapshotPrivateFile(companyId: companyId, agentId: agentId, workspacePath: c.ref.id,
                                                     readers: recipients + [agentId], knownValues: knownValues, paths: paths, now: now,
                                                     archives: archives)
                } else {
                    do {
                        pinned = try pinRef(c.ref, for: reader, companyId: companyId, messageRefId: c.rowId, knownValues: knownValues,
                                            paths: paths, archives: archives)
                    } catch let e as WorkError {
                        if case .forbidden = e { throw unavailable(i + 1) }
                        throw e
                    } catch is SafeGitError, is SafeFSError, is VaultError {
                        throw unavailable(i + 1)
                    }
                    shareRefMade = pinned.params["share"] == c.rowId
                    if [.file, .diff, .commit].contains(pinned.kind), !pinned.isWorktree, pinned.params["share"] == nil,
                       let rev = pinned.rev, let company = c.resolution.company {
                        let git = try refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true))
                        if !(try git.isAncestor(rev, of: "main")) {
                            try git.updateShareRef(c.rowId, to: rev)
                            shareRefMade = true
                        }
                    }
                }
                // The row: what the pin is, for the sender now (access class, sensitivity, restrictions, reader set, taint).
                let r = try resolveDetailed(pinned, reader: reader, companyId: companyId, messageRefId: c.rowId)
                guard r.resolved.visibility == .full, let subject = r.subject else { throw unavailable(i + 1) }
                let row = try Self.refRow(id: c.rowId, companyId: companyId, pinned: pinned, subject: subject, resolved: r.resolved,
                                          inline: false, now: now)
                prepared.append(PreparedRef(row: row, shown: Self.shown(pinned), shareRefMade: shareRefMade))
            }
        } catch {
            if let company = candidates.first?.resolution.company,
               let git = try? refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true)) {
                for c in candidates { try? git.deleteShareRef(c.rowId) }
            }
            throw error
        }
        return prepared
    }

    /// The agent handle a `.brahma` lab, notes or home path is private to (`labs/<h>/…`, `notes/agents/<h>.md`, `home/<h>/…`).
    static func privateOwner(_ ref: WorkRef) -> String? {
        if let place = RefAccess.privatePlace(ref) { return place }
        let parts = ref.id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == ".brahma", parts[1] == "home", !parts[2].isEmpty else { return nil }
        return parts[2]
    }

    /// What the reply calls a pinned ref: its canonical form without the pin, then ` @<sha7>` for a committed file, diff or
    /// commit pin.
    static func shown(_ pinned: WorkRef) -> String {
        let bare = unpinned(pinned).canonical
        guard [.file, .diff].contains(pinned.kind), !pinned.isWorktree, pinned.params["share"] == nil, let rev = pinned.rev else { return bare }
        return "\(bare) @\(rev.prefix(7))"
    }

    /// Who can read `subject`, for the DM refusal: handles of a reader set, else its class in words. Engine text only.
    static func readersText(db: Database, companyId: String, _ subject: RefAccess.Subject) throws -> String {
        func handle(_ id: String) throws -> String { id == "owner" ? "@owner" : "@" + (try RefAccess.handle(db, companyId, id) ?? "unknown") }
        if !subject.restrictions.isEmpty || subject.sensitivity >= .restricted {
            let roles = subject.restrictions.flatMap { $0.sorted() }
            return roles.isEmpty ? "executives" : "the roles " + roles.joined(separator: ", ")
        }
        if let set = subject.readerSet {
            let handles = try set.map(handle).sorted()
            return handles.isEmpty ? "nobody yet" : handles.joined(separator: ", ")
        }
        switch subject.access {
        case .company: return "the company"
        case .team(let t): return "team \(Store.flat(t, max: 40))"
        case .role(let r): return "the role \(Store.flat(r, max: 40))"
        case .item(let id):
            let key = try String.fetchOne(db, sql: "SELECT key FROM workItem WHERE companyId = ? AND id = ?", arguments: [companyId, id])
            return "the people on \(key ?? "its item")"
        case .channel(let id):
            let name = try String.fetchOne(db, sql: "SELECT name FROM channel WHERE companyId = ? AND id = ?", arguments: [companyId, id])
            return name.map { "#\($0) members" } ?? "its channel's members"
        case .dm(let id):
            let members = try String.fetchAll(db, sql: """
                SELECT m.member FROM channelMember m JOIN channel c ON c.id = m.channelId WHERE c.companyId = ? AND c.id = ?
                """, arguments: [companyId, id])
            return try members.map(handle).sorted().joined(separator: " and ")
        case .agent(let id): return try handle(id)
        case .ownerOnly: return "the owner"
        }
    }

    /// One `access` activity line for a refused share (the owner's feed).
    func recordAccessRefusal(companyId: String, agentId: String, handle: String, target: ShareTarget, reason: String, now: Date) {
        try? writer.write { db in
            try ActivityEvent(companyId: companyId, agentId: agentId, turnId: nil, kind: .access,
                              text: "@\(handle)'s share with \(target.shown) was refused: \(Store.flat(reason, max: 300))", createdAt: now).insert(db)
        }
    }

    /// A `messageRef` row for `pinned`: its access class, sensitivity (at least `restricted` when it carries restrictions),
    /// restrictions, reader set and taint as `subject` and `resolved` say.
    static func refRow(id: String, companyId: String, pinned: WorkRef, subject: RefAccess.Subject, resolved: ResolvedRef?, inline: Bool,
                       now: Date) throws -> MessageRef {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let params = String(decoding: try encoder.encode(pinned.params), as: UTF8.self)
        let restrictions = String(decoding: try encoder.encode(subject.restrictions.map { $0.sorted() }), as: UTF8.self)
        let readerSet = try subject.readerSet.map { String(decoding: try encoder.encode($0.sorted()), as: UTF8.self) }
        var sensitivity = subject.sensitivity
        if !subject.restrictions.isEmpty, sensitivity < .restricted { sensitivity = .restricted }
        let state: String
        switch resolved?.state {
        case .redacted?: state = "redacted"
        case .purged?: state = "purged"
        default: state = "ok"
        }
        return MessageRef(id: id, companyId: companyId, messageId: "", position: 0, canonical: pinned.canonical, kind: pinned.kind.rawValue,
                          refId: pinned.id, branch: pinned.branch, rev: pinned.rev, rangeStart: pinned.range?.start,
                          rangeEnd: pinned.range?.end, params: params, accessKind: subject.access.kind, accessId: subject.access.id,
                          sensitivity: sensitivity.rawValue, restrictions: restrictions, readerSet: readerSet,
                          tainted: resolved?.tainted ?? false, taintReason: resolved?.taintReason, state: state, inline: inline,
                          createdAt: now)
    }

    /// The item events of a message's item refs (`referenced`, non-waking, naming the message), in the post's transaction.
    static func recordReferences(db: Database, store: Store, rows: [MessageRef], message: Message, now: Date) throws {
        guard message.senderId != "system" else { return }
        var seen = Set<String>()
        for row in rows where row.kind == WorkRefKind.item.rawValue && seen.insert(row.refId).inserted {
            guard let item = try RefAccess.item(db, message.companyId, row.refId) else { continue }
            try store.recordItemEvent(db: db, item: item, actor: message.senderId, kind: .referenced, text: "referenced in a conversation",
                                      sourceMessageId: message.id, now: now)
        }
    }

    // MARK: Inline refs

    /// The refs `text` names (`RefScanner.scan`, on the text as it will be stored) that resolve to anything but `.missing`
    /// for `sender`, as `inline = true` rows (no share ref, snapshot or blob: only a committed file's `rev` and an item's
    /// status are pinned). The engine's own messages (`Sender.system`) are never scanned.
    func inlineRefs(companyId: String, sender: Sender, text: String, channelId: String?) throws -> [MessageRef] {
        let reader: Reader
        switch sender {
        case .system: return []
        case .owner: reader = .owner
        case .agent(let id): reader = .agent(id)
        }
        guard let company = try company(id: companyId) else { return [] }
        let stored = try redact(text)
        var actingAgentId: String?
        if case .agent(let id) = sender { actingAgentId = id }
        let context = RefContext(companyId: companyId, keyPrefixes: [Store.keyPrefix(slug: company.slug)], currentChannelId: channelId,
                                 actingAgentId: actingAgentId)
        var rows: [MessageRef] = []
        var seen = Set<String>()
        let now = Store.now()
        for (_, ref) in RefScanner.scan(stored, context: context) where seen.insert(ref.canonical).inserted {
            let id = UUID().uuidString
            guard let r = try? resolveDetailed(ref, reader: reader, companyId: companyId, messageRefId: id),
                  r.resolved.visibility != .missing else { continue }
            let full = r.resolved.visibility == .full
            guard let subject = try r.subject ?? writer.read({ db in try RefAccess.subject(ref, companyId: companyId, db: db) }) else { continue }
            rows.append(try Self.refRow(id: id, companyId: companyId, pinned: full ? r.pinned : ref, subject: subject,
                                        resolved: full ? r.resolved : nil, inline: true, now: now))
        }
        return rows
    }

    // MARK: Per-reader rendering

    /// What `reader` sees of a message's attachments and shares (not its inline chips): one `DigestRefs.line` per ref
    /// resolved for `reader` (refused and missing left out), a quote as `[quote msg:<id> · @<h> in <place> · verified]` and
    /// its source text as stored now (quoted `    | `, at most `quoteLines` lines), or `[locked message · ask the owner]`
    /// when the reader can't read the source, or the source is a DM with the owner quoted anywhere but that DM. A quote of a
    /// message written by a session that read outside content shows no text (open_ref reads it, and taints).
    public func attachmentLines(companyId: String, messageId: String, reader: Reader) throws -> [String] {
        let found = try writer.read { db -> (Message, Channel, [MessageRef], String)? in
            guard let m = try Message.fetchOne(db, sql: "SELECT * FROM message WHERE companyId = ? AND id = ?", arguments: [companyId, messageId]),
                  let channel = try Channel.fetchOne(db, sql: "SELECT * FROM channel WHERE companyId = ? AND id = ?",
                                                     arguments: [companyId, m.channelId]) else { return nil }
            let rows = try MessageRef.fetchAll(db, sql: """
                SELECT * FROM messageRef WHERE companyId = ? AND messageId = ? AND inline = 0 ORDER BY position, rowid
                """, arguments: [companyId, messageId])
            let sender = m.senderId == "owner" || m.senderId == "system" ? m.senderId : try RefAccess.handle(db, companyId, m.senderId) ?? "unknown"
            return (m, channel, rows, sender)
        }
        guard let found else { return [] }
        let (message, channel, rows, sender) = found
        let forwarder = message.senderId == "owner" || message.senderId == "system" ? nil : sender
        var out: [String] = []
        for row in rows {
            guard let ref = row.workRef else { continue }
            if ref.kind == .message || ref.kind == .thread {
                out += try quoteLines(companyId: companyId, sourceId: ref.id, in: channel, reader: reader)
                continue
            }
            guard let resolved = try? resolveDetailed(ref, reader: reader, companyId: companyId, messageRefId: row.id).resolved else { continue }
            let line = DigestRefs.line(resolved, forwardedBy: forwarder)
            if !line.isEmpty { out.append(line) }
        }
        return out
    }

    /// At most this many lines of a quoted message are shown.
    static let quoteLines = 20

    private func quoteLines(companyId: String, sourceId: String, in channel: Channel, reader: Reader) throws -> [String] {
        let locked = ["[locked message · ask the owner]"]
        let found = try writer.read { db -> (Message, Channel, Bool, String, RefDecision)? in
            guard let m = try Message.fetchOne(db, sql: "SELECT * FROM message WHERE companyId = ? AND id = ?", arguments: [companyId, sourceId]),
                  let source = try Channel.fetchOne(db, sql: "SELECT * FROM channel WHERE companyId = ? AND id = ?",
                                                    arguments: [companyId, m.channelId]) else { return nil }
            let hasOwner = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM channelMember WHERE channelId = ? AND member = 'owner')
                """, arguments: [source.id]) ?? true
            let ownerDM = source.kind == .dm && hasOwner
            let sender = m.senderId == "owner" || m.senderId == "system" ? m.senderId : try RefAccess.handle(db, companyId, m.senderId) ?? "unknown"
            let decision = try RefAccess.canRead(reader, WorkRef(kind: .message, id: m.id), companyId: companyId, db: db, catalog: catalog)
            return (m, source, ownerDM, sender, decision)
        }
        guard let found else { return [] }
        let (message, source, ownerDM, sender, decision) = found
        // A message of a DM with the owner is shown only in that DM (owner text quoted elsewhere is never put before an agent).
        if ownerDM, source.id != channel.id, reader != .owner { return locked }
        guard case .allowed = decision else { return locked }
        let place = source.kind == .dm ? "a DM" : "#\(source.name)"
        if message.fromTaintedSession || message.taintedOrigin {
            return ["[quote msg:\(message.id) · @\(sender) in \(place) · from a session that read outside content; open_ref to read]"]
        }
        var out = ["[quote msg:\(message.id) · @\(sender) in \(place) · verified]"]
        let lines = Self.splitLines(message.text)
        for line in lines.prefix(Self.quoteLines) { out.append("    | " + Self.cut(line)) }
        if lines.count > Self.quoteLines { out.append("    | … \(lines.count - Self.quoteLines) more lines; open_ref msg:\(message.id)") }
        return out
    }

    /// The attachment lines of each of `items`' messages for the agent, by message id (`InboxDigest.render`'s `attachments`).
    public func digestAttachments(agentId: String, companyId: String, items: [(InboxItem, Message, Channel)]) throws -> [String: [String]] {
        let ids = Array(Set(items.map { $0.1.id }))
        guard !ids.isEmpty else { return [:] }
        let carrying = try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT messageId FROM messageRef WHERE companyId = ? AND inline = 0 AND messageId IN (\(ids.map { _ in "?" }.joined(separator: ",")))
                """, arguments: StatementArguments([companyId] + ids))
        }
        var out: [String: [String]] = [:]
        for id in carrying {
            let lines = try attachmentLines(companyId: companyId, messageId: id, reader: .agent(agentId))
            if !lines.isEmpty { out[id] = lines }
        }
        return out
    }

    // MARK: Backlinks

    /// The messages that name `ref` (its `messageRef` rows, newest first), for `reader`: a message it can read with its id and
    /// `"#<channel> · @<sender>"` (`"DM · @<sender>"`); a DM it can't read only as `"mentioned in a conversation"`, with no id;
    /// a channel message it can't read, or a row whose message is gone, is left out. Bound to the company.
    public func backlinks(companyId: String, ref: WorkRef, reader: Reader) throws -> [Backlink] {
        try writer.read { db in
            let rows = try MessageRef.fetchAll(db, sql: """
                SELECT * FROM messageRef WHERE companyId = ? AND kind = ? AND refId = ? ORDER BY createdAt DESC, rowid DESC LIMIT 200
                """, arguments: [companyId, ref.kind.rawValue, ref.id])
            var seen = Set<String>()
            var out: [Backlink] = []
            for row in rows where seen.insert(row.messageId).inserted {
                guard let m = try Message.fetchOne(db, sql: "SELECT * FROM message WHERE companyId = ? AND id = ?", arguments: [companyId, row.messageId]),
                      let channel = try Channel.fetchOne(db, sql: "SELECT * FROM channel WHERE companyId = ? AND id = ?",
                                                         arguments: [companyId, m.channelId]) else { continue }
                let decision = try RefAccess.canRead(reader, WorkRef(kind: .message, id: m.id), companyId: companyId, db: db, catalog: catalog)
                if case .allowed = decision {
                    let sender = m.senderId == "owner" || m.senderId == "system" ? m.senderId : try RefAccess.handle(db, companyId, m.senderId) ?? "unknown"
                    out.append(Backlink(messageId: m.id, title: (channel.kind == .dm ? "DM" : "#\(channel.name)") + " · @\(sender)"))
                } else if channel.kind == .dm {
                    out.append(Backlink(messageId: nil, title: "mentioned in a conversation"))
                }
            }
            return out
        }
    }

    // MARK: Review digest

    /// What the session that made a commit of the item's diff (`<KEY>:diff@<commit>`, `refTaint`) had read, when the diff is
    /// tainted; nil when it is clean. Fail closed: a taint that can't be read is reported.
    public func reviewDiffTaint(companyId: String, itemKey: String, commit: String?) -> String? {
        do {
            let taint = try refTaint(WorkRef(kind: .diff, id: itemKey, rev: commit), companyId: companyId)
            guard taint.tainted else { return nil }
            let reason = taint.reason ?? "outside content"
            let prefix = Self.sessionReason("")
            return reason.hasPrefix(prefix) ? String(reason.dropFirst(prefix.count)) : reason
        } catch {
            return "unknown: its history couldn't be read"
        }
    }
}

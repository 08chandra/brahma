import Foundation
import GRDB

/// Plan C Task C5 (design §3.6): files between the owner and agents. The owner drops files into a DM, a channel, a thread,
/// an item card or an agent's request (ML's drop pipeline: `Store.addResources`, whose announcement is the drop's one
/// `kind = share` message); the owner asks an agent for a file (`kind = fileAsk`, answered by the agent's `share` in its
/// thread); an agent asks the owner for one (`request_from_owner {wants_file: true}`: a `request` ask, answered with a drop or
/// declined). Owner callers only (the CLI and the app), except `requestFileFromOwner`, which is the tool's.

/// What a file request carries in its payload `details` (JSON, like `RequestedSecret`): never a file or a path.
public struct RequestedFile: Codable, Equatable, Sendable {
    public var request = "file"
    /// The agent's background text, if it gave any (agent-controlled: quoted and gated wherever it is shown).
    public var details: String?

    public init(details: String? = nil) { self.details = details }
}

public enum FileRequests {
    /// A pending or settled `request` ask whose details say `"request": "file"`.
    public static func isFileRequest(_ ask: Ask) -> Bool { requested(ask) != nil }

    public static func requested(_ ask: Ask) -> RequestedFile? {
        guard ask.kind == .request, let details = ask.payload?.details,
              let decoded = try? JSONDecoder().decode(RequestedFile.self, from: Data(details.utf8)), decoded.request == "file" else { return nil }
        return decoded
    }

    static func details(_ request: RequestedFile) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(request)) ?? Data(#"{"request":"file"}"#.utf8), as: UTF8.self)
    }

    /// The first line of a file request's answer: `provided F-4` (`provided F-4, F-5` for several).
    static func providedText(refs: [String]) -> String { "provided " + refs.joined(separator: ", ") }

    /// A declined request's answer: `declined` or `declined: <note>`.
    static func declinedText(_ note: String) -> String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? "declined" : "declined: \(n)"
    }
}

/// The owner's file ask (`Store.sendFileAsk`): open, or answered by the agent's `share` replying in its thread.
public enum FileAskState: Equatable, Sendable {
    case open
    case answered(shareMessageId: String, refs: [WorkRef])
}

public enum FileAskLimits {
    /// What the owner asks for, at most this many characters.
    public static let descriptionMax = 600
}

/// How the owner's Inbox shows an agent's file request: every agent-written field as its final display string (one line,
/// NFKC, invisible and bidi characters dropped, cut, quotes and brackets made inert) gated against the stored values after
/// that (Rulings 53-56): a field holding one is `FileRequestCard.withheld`. `claimsOwner`: the agent's text claims to be the
/// owner (`OwnerImpersonation`): the app shows the unverified chip; it changes nothing.
public struct FileRequestCard: Equatable, Sendable {
    public var askId: String
    public var ref: String
    public var requesterHandle: String
    public var title: String
    public var question: String
    public var details: String?
    public var claimsOwner: Bool
    public var status: AskStatus

    public static let withheld = "[withheld: holds a stored secret]"
    public static let titleMax = 120
    public static let textMax = 600
}

extension Store {
    // MARK: Owner drops

    /// The owner drops `plan` in `context` (ML's `DropContext`: `.dm`, `.channel`, `.thread(rootId:)`, `.item`, `.inbox`,
    /// `.library`, `.cli`) with the owner's choices in `drop` (its scope, reader set and future holders override the context's
    /// default, `Store.defaultScope`). A thin wrapper over ML's `addResources` (its secret choice, TOCTOU-safe vault copy,
    /// rows from the company's monotonic counter, mirror and announcement): in a DM, a channel or a thread the announcement
    /// is the drop's one `kind = share` message with a `messageRef` row per ref; on an agent's file request it is the answer
    /// (`answerFileRequest`). Returns the refs added (`F-<n>`, folder first then its files), in number order.
    @discardableResult
    public func ownerDrop(companyId: String, context: DropContext, plan: DropPlan, drop: ResourceDrop, contentVault: ContentVault,
                          secretVault: any SecretVault, knownValues: [(name: String, value: String)], paths: BrahmaPaths,
                          now: Date = Store.now()) throws -> [WorkRef] {
        var drop = drop
        drop.context = context
        if case .inbox(let askId) = context, let ask = try ask(id: askId), ask.companyId == companyId, FileRequests.isFileRequest(ask),
           case .storeAsSecret = drop.secretChoice {
            throw ResourceError.invalid("a file request is answered with a file; store the secret from Secrets instead")
        }
        let added = try addResources(companyId: companyId, plan: plan, drop: drop, contentVault: contentVault, secretVault: secretVault,
                                     knownValues: knownValues, paths: paths, now: now)
        if case .inbox(let askId) = context, !added.isEmpty { try settleFileRequest(companyId: companyId, askId: askId, added: added, now: now) }
        return added.map { WorkRef(kind: .resource, id: String($0.number)) }
    }

    // MARK: The owner asks an agent for a file

    /// The owner asks `toHandle` for a file: a DM from the owner (`kind = fileAsk`, which wakes the agent) whose text is
    /// `description` (at most `FileAskLimits.descriptionMax` characters), with ` (for <KEY>)` when it is for an item of this
    /// company. The agent answers with `share(..., reply_to: "msg:<id>")` (`fileAskState`).
    @discardableResult
    public func sendFileAsk(companyId: String, toHandle: String, description: String, itemKey: String?,
                            now: Date = Store.now()) throws -> Message {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WorkError.invalid("say what file you need") }
        guard text.count <= FileAskLimits.descriptionMax else {
            throw WorkError.invalid("the description is at most \(FileAskLimits.descriptionMax) characters")
        }
        let handle = (toHandle.hasPrefix("@") ? String(toHandle.dropFirst()) : toHandle).lowercased()
        let full = try writer.read { db -> String in
            guard let agent = try Agent.fetchOne(db, sql: "SELECT * FROM agent WHERE companyId = ? AND name = ?", arguments: [companyId, handle]),
                  agent.state != .killed else { throw WorkError.notFound("no agent @\(Store.flat(handle, max: 64))") }
            guard let key = itemKey?.trimmingCharacters(in: .whitespaces), !key.isEmpty else { return text }
            guard let item = try RefAccess.item(db, companyId, key) else { throw WorkError.notFound("no work item \(Store.flat(key, max: 40))") }
            return "\(text) (for \(item.key))"
        }
        let inline = try inlineRefs(companyId: companyId, sender: .owner, text: full, channelId: nil)
        return try writer.write { db in
            try MessageRouter(store: self).sendDM(db: db, companyId: companyId, from: .owner, to: handle, text: full, now: now,
                                                  kind: .fileAsk, inline: inline)
        }
    }

    /// Whether the owner's file ask `messageId` (this company's, `kind = fileAsk`) is answered: the first `kind = share`
    /// reply in its thread from the agent, and the refs it carries (its rows, not its inline chips). Anything else →
    /// `WorkError.notFound`.
    public func fileAskState(companyId: String, messageId: String) throws -> FileAskState {
        try writer.read { db in
            guard let id = Self.threadMessageId(messageId),
                  let ask = try Message.fetchOne(db, sql: "SELECT * FROM message WHERE companyId = ? AND id = ?", arguments: [companyId, id]),
                  ask.kind == .fileAsk, ask.senderId == "owner" else { throw WorkError.notFound("no such file ask") }
            guard let share = try Message.fetchOne(db, sql: """
                SELECT * FROM message WHERE companyId = ? AND parentId = ? AND kind = ? AND senderId NOT IN ('owner', 'system')
                ORDER BY createdAt, rowid LIMIT 1
                """, arguments: [companyId, ask.id, MessageKind.share.rawValue]) else { return .open }
            let rows = try MessageRef.fetchAll(db, sql: """
                SELECT * FROM messageRef WHERE companyId = ? AND messageId = ? AND inline = 0 ORDER BY position, rowid
                """, arguments: [companyId, share.id])
            return .answered(shareMessageId: share.id, refs: rows.compactMap(\.workRef))
        }
    }

    // MARK: An agent asks the owner for a file

    /// `request_from_owner {wants_file: true}`: a `request` ask (risk high, straight to the owner: `pendingOwner`) whose
    /// details are `{"request":"file"}` (plus the agent's own `details`). The tool is high risk under taint; `AskQuota`
    /// applies in the write that files it, and `requestId` dedupes as for every ask.
    @discardableResult
    public func requestFileFromOwner(companyId: String, by agentId: String, title: String, question: String, details: String?,
                                     expiresInHours: Double? = nil, requestId: String? = nil, now: Date = Store.now()) throws -> Ask {
        if let h = expiresInHours, !(h > 0 && h <= Store.maxExpiryHours) {
            throw WorkError.invalid("expires_in_hours must be between 0 and \(Int(Store.maxExpiryHours))")
        }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { throw WorkError.invalid("the question is empty") }
        guard q.count <= Store.maxAskField else { throw WorkError.invalid("the question is at most \(Store.maxAskField) characters") }
        let extra = details.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return try writer.write { db in
            var ask = try propose(db: db, companyId: companyId, by: .agent(agentId), kind: .request, risk: .high, category: nil,
                                  title: title, summary: q,
                                  payload: AskPayload(question: q, details: FileRequests.details(RequestedFile(details: extra))),
                                  document: nil, itemId: nil, subjectId: nil, supersedes: nil, requestId: requestId, decisionClass: .taste,
                                  viaOwner: true, now: now)
            if let h = expiresInHours, ask.expiresActive == nil, ask.status == .pendingOwner, FileRequests.isFileRequest(ask) {
                ask.expiresActive = ask.createdActive + h * 3600
                try ask.update(db)
            }
            return ask
        }
    }

    /// The owner answers the file request `askId` with `plan`: ML's `addResources` in `.inbox(askId:)` (scoped to the
    /// requester alone, fixed), whose announcement is the answer (`ownerAnswer`, text `provided F-<n>…`, a `kind = share` DM
    /// that wakes the requester). If that answer could not be delivered with the drop, the ask is still answered (one
    /// message). Returns the refs added.
    @discardableResult
    public func answerFileRequest(companyId: String, askId: String, plan: DropPlan, contentVault: ContentVault,
                                  secretVault: any SecretVault, knownValues: [(name: String, value: String)], paths: BrahmaPaths,
                                  secretChoice: SecretChoice = .none, trust: TrustChoice = .asDetected, message: String? = nil,
                                  now: Date = Store.now()) throws -> [WorkRef] {
        _ = try pendingFileRequest(companyId: companyId, askId: askId)
        let context = DropContext.inbox(askId: askId)
        let (scope, readers) = try defaultScope(for: context, companyId: companyId)
        return try ownerDrop(companyId: companyId, context: context, plan: plan,
                             drop: ResourceDrop(context: context, scope: scope, readerSet: readers, trust: trust, secretChoice: secretChoice,
                                                message: message),
                             contentVault: contentVault, secretVault: secretVault, knownValues: knownValues, paths: paths, now: now)
    }

    /// The owner declines the file request `askId`: answered (`ownerAnswer`) with `declined` or `declined: <note>`, a DM
    /// that wakes the requester. No file is given.
    @discardableResult
    public func declineFileRequest(companyId: String, askId: String, note: String, now: Date = Store.now()) throws -> Ask {
        _ = try pendingFileRequest(companyId: companyId, askId: askId)
        return try ownerAnswer(askId: askId, text: FileRequests.declinedText(note), now: now)
    }

    /// The owner's Inbox card for the file request `askId` (see `FileRequestCard`).
    public func fileRequestCard(companyId: String, askId: String, knownValues: [(name: String, value: String)]) throws -> FileRequestCard {
        let (ask, handle) = try writer.read { db -> (Ask, String) in
            guard let ask = try Ask.fetchOne(db, sql: "SELECT * FROM ask WHERE companyId = ? AND id = ?", arguments: [companyId, askId]),
                  FileRequests.isFileRequest(ask) else { throw WorkError.notFound("no such file request") }
            return (ask, try RefAccess.handle(db, companyId, ask.requesterId) ?? "unknown")
        }
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        let details = FileRequests.requested(ask)?.details
        let raw = [ask.title, ask.payload?.question ?? ask.summary, details ?? ""].joined(separator: "\n")
        return FileRequestCard(askId: ask.id, ref: ask.ref, requesterHandle: handle,
                               title: gate.final(ask.title, max: FileRequestCard.titleMax, inert: true) ?? FileRequestCard.withheld,
                               question: gate.final(ask.payload?.question ?? ask.summary, max: FileRequestCard.textMax, inert: true)
                                   ?? FileRequestCard.withheld,
                               details: details.map { gate.final($0, max: FileRequestCard.textMax, inert: true) ?? FileRequestCard.withheld },
                               claimsOwner: OwnerImpersonation.flags(text: raw, sender: .agent(ask.requesterId)), status: ask.status)
    }

    // MARK: Helpers

    /// This company's file request `askId`, pending for the owner; anything else is ML's Inbox refusal.
    private func pendingFileRequest(companyId: String, askId: String) throws -> Ask {
        guard let ask = try ask(id: askId), ask.companyId == companyId, FileRequests.isFileRequest(ask) else {
            throw ResourceError.invalid(Self.inboxRefusal)
        }
        guard ask.status == .pendingOwner else { throw ResourceError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
        return ask
    }

    /// After a drop on the file request `askId`: if the announcement could not answer it (a failure ML traces, never throws),
    /// it is answered now with `provided F-<n>…` (the only message), and the rows point at that answer.
    private func settleFileRequest(companyId: String, askId: String, added: [Resource], now: Date) throws {
        guard let ask = try ask(id: askId), ask.companyId == companyId, FileRequests.isFileRequest(ask), ask.status == .pendingOwner else { return }
        let refs = added.filter { $0.parentId == nil }.map(\.ref)
        let posted = try writer.write { db in
            try ownerAnswer(db: db, askId: askId, text: FileRequests.providedText(refs: refs), now: now).message
        }
        guard let posted else { return }
        try writer.write { db in
            for r in added {
                try db.execute(sql: "UPDATE resource SET messageId = ?, channelId = ?, updatedAt = ? WHERE companyId = ? AND id = ?",
                               arguments: [posted.id, posted.channelId, now, companyId, r.id])
            }
        }
    }
}

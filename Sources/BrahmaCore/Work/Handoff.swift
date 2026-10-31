import Foundation
import GRDB

/// What the writer of a hand-off says. The engine adds the item's acceptance check, its branch and the author.
public struct HandoffDraft: Equatable, Sendable {
    public var goal: String
    public var decisions: [String]
    public var openQuestions: [String]
    public var fileRefs: [String]
    /// The agent that picks the work up, when known: it gets a notice that wakes it.
    public var toAgentId: String?

    public init(goal: String, decisions: [String] = [], openQuestions: [String] = [], fileRefs: [String] = [], toAgentId: String? = nil) {
        self.goal = goal; self.decisions = decisions; self.openQuestions = openQuestions; self.fileRefs = fileRefs
        self.toAgentId = toAgentId
    }
}

/// A hand-off file the engine wrote: `<ws>/.brahma/handoffs/<KEY>/<yyyyMMdd-HHmmss>-<handle>.md`.
public struct Handoff: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "handoff"

    public var id: String
    public var companyId: String
    public var itemId: String
    public var authorId: String
    public var toAgentId: String?
    public var path: String
    /// Written by the engine (an agent was killed or reassigned), not by the agent.
    public var auto: Bool = false
    public var createdAt: Date
}

extension Store {
    static let maxHandoffField = 8000
    static let maxHandoffEntries = 50

    /// Writes a hand-off for the item. Only the lease holder, the assignee, the owner or the engine may.
    @discardableResult
    public func writeHandoff(itemId: String, by sender: Sender, draft: HandoffDraft, now: Date = Store.now()) throws -> Handoff {
        var companyId: String?
        do { return try writer.write { db in
            companyId = try WorkItem.fetchOne(db, key: itemId)?.companyId
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
            let actor = try resolveActor(db, sender, companyId: item.companyId)
            if !actor.privileged {
                let holder = try Self.leaseHolderId(db: db, itemId: item.id)
                guard actor.id == holder || actor.id == item.ownerId else {
                    throw WorkError.forbidden("only the lease holder or the assignee of \(item.key) can write its hand-off")
                }
            }
            return try writeHandoff(db: db, item: item, authorId: actor.id, authorHandle: actor.handle, draft: draft, auto: false, now: now)
        } } catch let refused as UnsafeEngineFile {
            // The transaction is gone; the alert goes in its own.
            if let companyId { alertEngineFile(refused, companyId: companyId, now: now) }
            throw refused
        }
    }

    /// In the caller's transaction (Task 12 writes the auto hand-off of a killed agent here). No authorization: the caller decides.
    @discardableResult
    func writeHandoff(db: Database, item: WorkItem, authorId: String, authorHandle: String, draft: HandoffDraft, auto: Bool,
                             now: Date) throws -> Handoff {
        guard let company = try Company.fetchOne(db, key: item.companyId) else { throw WorkError.notFound("no such company") }
        let draft = try redact(draft)   // raw, before any trimming, limits or flattening: a multi-line secret still matches
        var recipientHandle: String?
        if let to = draft.toAgentId {
            guard let agent = try Agent.fetchOne(db, key: to), agent.companyId == item.companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard agent.state != .killed else { throw WorkError.invalid("@\(agent.name) has been killed") }
            recipientHandle = agent.name
        }
        let goal = draft.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { throw WorkError.invalid("a hand-off needs a goal: say what the work is for and where it stands") }
        guard goal.count <= Self.maxHandoffField else { throw WorkError.invalid("the goal is longer than \(Self.maxHandoffField) characters") }
        for list in [draft.decisions, draft.openQuestions, draft.fileRefs] {
            guard list.count <= Self.maxHandoffEntries else { throw WorkError.invalid("a hand-off lists at most \(Self.maxHandoffEntries) entries per section") }
            guard list.allSatisfy({ $0.count <= Self.maxHandoffField }) else {
                throw WorkError.invalid("a hand-off entry is longer than \(Self.maxHandoffField) characters")
            }
        }

        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(stamp.string(from: now))-\(Self.handleForFile(authorHandle))"

        func list(_ xs: [String]) -> String {
            xs.isEmpty ? "- (none)" : xs.map { entry in
                // A block the engine quoted (every line prefixed) keeps its lines; anything else is one flattened line.
                let lines = entry.components(separatedBy: "\n")
                if lines.allSatisfy({ $0.hasPrefix(ReviewDigest.quotePrefix) }) {
                    return "-\n" + lines.prefix(200).map { String(ReviewDigest.clean($0).prefix(2000)) }.joined(separator: "\n")
                }
                return "- " + ReviewDigest.flat(entry, max: 2000)
            }.joined(separator: "\n")
        }
        let check = item.checkSpec.map { "Check (rev \(item.checkRevision)): `\(ReviewDigest.flat($0.command, max: 400))`" } ?? "Check: none"
        let from = "From: @\(authorHandle)" + (recipientHandle.map { " to @\($0)" } ?? "") + (auto ? " (written by the engine)" : "")
        let text = """
        # Hand-off

        \(from)
        Item: \(item.key) · \(ReviewDigest.flat(item.title, max: 200))

        ## Goal
        \(ReviewDigest.quote(goal, maxChars: Self.maxHandoffField))

        ## Acceptance check
        \(ReviewDigest.quote(item.acceptanceCriteria, maxChars: ReviewDigest.maxCriteria, empty: "(no acceptance criteria)"))
        \(check)

        ## Branch
        item/\(item.key)

        ## Decisions
        \(list(draft.decisions))

        ## Open questions
        \(list(draft.openQuestions))

        ## Files
        \(list(draft.fileRefs))

        """
        // A new file under a real directory, never through a link (a link on a name it would take is skipped and alerted on).
        let written = try EngineFiles.createUnique(Data(text.utf8), workspace: workspace, dir: ".brahma/handoffs/\(item.key)",
                                                   base: base, ext: "md")
        let file = written.url
        for problem in written.skipped { try alertEngineFile(db: db, problem, companyId: item.companyId, now: now) }

        let handoff = Handoff(id: UUID().uuidString, companyId: item.companyId, itemId: item.id, authorId: authorId,
                              toAgentId: draft.toAgentId, path: file.path, auto: auto, createdAt: now)
        try handoff.insert(db)
        let who = auto ? "the engine" : "@\(authorHandle)"
        let to = recipientHandle.map { " for @\($0)" } ?? ""
        try recordItemEvent(db: db, item: item, actor: authorId, kind: .handoffWritten,
                            text: "hand-off written by \(who)\(to): \(file.path)", alsoNotify: [draft.toAgentId].compactMap { $0 },
                            alsoNotifyRole: .recipient, now: now)
        return handoff
    }

    /// Letters, digits, `-` and `_` only: the handle is part of a file name.
    private static func handleForFile(_ handle: String) -> String {
        let cleaned = String(handle.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
            .map(Character.init))
        return cleaned.isEmpty ? "agent" : String(cleaned.prefix(40))
    }

    /// The newest hand-off written for the item.
    public func latestHandoff(itemId: String) throws -> Handoff? {
        try writer.read { db in
            try Handoff.filter(Column("itemId") == itemId).order(Column("createdAt").desc, Column.rowID.desc).fetchOne(db)
        }
    }

    public func handoffs(itemId: String) throws -> [Handoff] {
        try writer.read { db in try Handoff.filter(Column("itemId") == itemId).order(Column("createdAt"), Column.rowID).fetchAll(db) }
    }
}

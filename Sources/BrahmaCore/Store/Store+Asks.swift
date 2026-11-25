import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The owner's Inbox: asks agents file, the internal approver's step, the autonomy preset, and the owner's answers.
///
/// Owner decisions exist only here (`ownerDecide`, `ownerReplan`, `ownerAnswer`, `acknowledge`). They are called by the
/// owner CLI commands and the app, never by `CompanyTools`; no message text from any sender changes an ask.
extension Store {
    static let maxAskTitle = 200
    static let maxAskText = 20_000
    static let maxAskField = 4000
    static let maxAskDocumentBytes = 10_000_000
    /// Companies with at most this many non-killed agents approve brief and architecture in one ask.
    static let combinedGateMaxAgents = 8
    static let maxExpiryHours = 24.0 * 365

    // MARK: Helpers

    func requireCompany(_ db: Database, _ id: String) throws -> Company {
        guard let c = try Company.fetchOne(db, key: id) else { throw WorkError.notFound("no such company") }
        return c
    }

    func requireAsk(_ db: Database, _ id: String) throws -> Ask {
        guard let a = try Ask.fetchOne(db, key: id) else { throw WorkError.notFound("no such ask") }
        return a
    }

    /// The agent id and handle of whoever files an ask: an active agent of the company, or the engine.
    private func askRequester(_ db: Database, _ sender: Sender, companyId: String) throws -> (id: String, handle: String) {
        switch sender {
        case .owner: throw WorkError.invalid("the owner does not file asks")
        case .system: return ("system", "system")
        case .agent(let id):
            guard let a = try Agent.fetchOne(db, key: id), a.companyId == companyId else { throw WorkError.forbidden("not in your company") }
            guard a.state != .killed else { throw WorkError.forbidden("this agent is not active in the company") }
            return (a.id, a.name)
        }
    }

    static func handle(_ db: Database, _ id: String?) throws -> String {
        guard let id else { return "?" }
        if id == "system" || id == "owner" { return id }
        return try Agent.fetchOne(db, key: id)?.name ?? "?"
    }

    /// Removes control characters (ESC, BEL, CR, DEL, C1...) so stored text cannot drive a terminal. Newlines and tabs stay
    /// only when `keepNewlines`.
    static func stripControls(_ text: String, keepNewlines: Bool = false) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { s in
            if keepNewlines, s == "\n" || s == "\t" { return true }
            return !(s.value < 0x20 || (0x7F...0x9F).contains(s.value))
        }))
    }

    static func flat(_ text: String, max: Int = 500) -> String {
        let spaced = text.components(separatedBy: .newlines).joined(separator: " ")
        let one = stripControls(spaced).trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count > max ? String(one.prefix(max)) + "…" : one
    }

    private static func cleanAskTitle(_ raw: String) throws -> String {
        let t = flat(raw, max: Int.max)
        guard !t.isEmpty else { throw WorkError.invalid("the title is empty") }
        guard t.count <= maxAskTitle else { throw WorkError.invalid("the title is longer than \(maxAskTitle) characters") }
        return t
    }

    static func limitedText(_ text: String?, _ max: Int, _ what: String) throws -> String? {
        guard let raw = text else { return nil }
        let text = stripControls(raw, keepNewlines: true)
        guard text.count <= max else { throw WorkError.invalid("\(what) is longer than \(max) characters") }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func cleanRequestId(_ id: String?) -> String? {
        guard let t = id?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(100))
    }

    private func pack(for company: Company) -> IndustryPack? { catalog.pack(company.packId) }

    private static func companyIsSmall(_ db: Database, companyId: String) throws -> Bool {
        let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent WHERE companyId = ? AND state != 'killed'", arguments: [companyId]) ?? 0
        return n <= combinedGateMaxAgents
    }

    /// The kind title as shown to the owner: a PRD in a small company reads "Brief & architecture".
    static func displayTitle(_ db: Database, _ ask: Ask) throws -> String {
        if ask.kind == .prd, try companyIsSmall(db, companyId: ask.companyId) { return "Brief & architecture" }
        return ask.kind.title
    }

    public func displayTitle(_ ask: Ask) throws -> String {
        try writer.read { db in try Store.displayTitle(db, ask) }
    }

    // MARK: Documents

    /// A document read for an ask: the workspace-relative path and the hash of its bytes.
    struct PreparedDocument: Equatable { var path: String; var hash: String }

    /// Resolves a document path (relative to the workspace, or absolute) with symlinks followed, requires it to lie inside
    /// the workspace and to be a regular file (never a FIFO or device: opened non-blocking and checked with `fstat`),
    /// and hashes its bytes. Reads the file, so call it OUTSIDE a database write transaction.
    static func readDocument(_ raw: String, workspace: String) throws -> PreparedDocument {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { throw WorkError.invalid("document_path is empty") }
        let ws = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath()
        let base = URL(fileURLWithPath: workspace)
        let candidate = trimmed.hasPrefix("/") ? URL(fileURLWithPath: trimmed) : base.appending(path: trimmed)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(ws.path + "/") else { throw WorkError.invalid("document_path must be inside the workspace") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
            throw WorkError.invalid("document_path does not exist")
        }
        guard !isDir.boolValue else { throw WorkError.invalid("document_path is a directory, not a file") }
        let fd = open(resolved.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw WorkError.invalid("document_path cannot be read") }
        var info = stat()
        guard fstat(fd, &info) == 0 else { closeDescriptor(fd); throw WorkError.invalid("document_path cannot be read") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { closeDescriptor(fd); throw WorkError.invalid("document_path is not a regular file") }
        guard info.st_size >= 0, info.st_size <= maxAskDocumentBytes else { closeDescriptor(fd); throw WorkError.invalid("the document is larger than 10 MB") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: maxAskDocumentBytes + 1), data.count <= maxAskDocumentBytes else {
            throw WorkError.invalid("document_path cannot be read or is larger than 10 MB")
        }
        return PreparedDocument(path: String(resolved.path.dropFirst(ws.path.count + 1)), hash: StableHash.fnv1a64(data))
    }

    /// The hash of the document now, or nil when it is gone, unreadable, not a regular file or outside the workspace.
    /// Reads the file: call it outside a write transaction.
    private func currentDocumentHash(_ ask: Ask, company: Company) -> String? {
        guard let path = ask.payload?.documentPath else { return nil }
        return try? Store.readDocument(path, workspace: company.workspacePath).hash
    }

    /// True when the ask names a document whose bytes differ from those proposed (or that can no longer be read).
    public func documentChanged(_ ask: Ask) throws -> Bool {
        guard ask.payload?.documentPath != nil, let proposed = ask.detailsHash else { return false }
        guard let company = try company(id: ask.companyId) else { return false }
        return currentDocumentHash(ask, company: company) != proposed
    }

    // MARK: Routing

    /// The first non-killed, non-paused agent (other than the requester and `excluding`) whose role is in the pack's
    /// approver list for the kind, in list order. A `boost` follows the `other` list.
    func internalApprover(_ db: Database, company: Company, kind: AskKind, requesterId: String,
                                  excluding: Set<String> = []) throws -> Agent? {
        guard let pack = pack(for: company) else { return nil }
        let roles = pack.askApprovers[kind.rawValue] ?? (kind == .boost ? pack.askApprovers["other"] : nil) ?? []
        let ceoRoles = Set(pack.rolesCovering("ceo"))
        var actingTried = false
        for role in roles {
            var found = try Agent.filter(Column("companyId") == company.id && Column("role") == role && Column("state") != "killed"
                                         && Column("paused") == false)
                .order(Column("createdAt"), Column.rowID).fetchAll(db)
            // The acting CEO covers `ceo`: it answers where the pack names a CEO-covering role.
            if ceoRoles.contains(role), !actingTried {
                actingTried = true
                found = try Store.actingCEOs(db, companyId: company.id).filter { !$0.paused } + found
            }
            if let a = found.first(where: { $0.id != requesterId && !excluding.contains($0.id) }) { return a }
        }
        return nil
    }

    /// Moves the ask to `pendingOwner`, logs the activity line and DMs the owner.
    ///
    /// C5 fix round 1, ruling (2): the agent's title is shown as its final display string (one line, NFKC, invisible and bidi
    /// characters dropped, quotes and brackets inert, at most `FileRequestCard.titleMax`) gated against `knownValues` after
    /// that (Rulings 53-56: a title holding a value is `FileRequestCard.withheld`; secret patterns are gated even without
    /// values), with `OwnerImpersonation.digestPrefix` when an agent's title claims to be the owner — as `fileRequestCard`.
    ///
    /// Fix round 2 (Ruling C5-5): `knownValues` is required. Callers pass the stored values they read (the tools, from the
    /// injected vault) or the engine's loaded copy (`engineKnownValues`); nil (they could not be read in full) holds the title
    /// back (`titleHeldText`), never showing it raw.
    func enterPendingOwner(_ db: Database, ask: inout Ask, company: Company, knownValues: [(name: String, value: String)]?,
                           now: Date) throws {
        ask.status = .pendingOwner
        ask.statusSinceActive = try Store.activeNow(db: db, companyId: company.id)
        ask.remindCount = 0
        ask.notifiedAt = nil
        let verb = ask.kind == .info || FileRequests.isFileRequest(ask) ? "answer" : ask.kind == .humanTask ? "task show" : "approve"
        let text = "Owner approval needed: \(ask.ref) \(try Store.displayTitle(db, ask)): \(Self.ownerShownTitle(ask, knownValues: knownValues)) "
            + "(brahma \(verb) \(company.slug) \(ask.ref))"
        try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .approval, text: text, createdAt: now).insert(db)
        try MessageRouter(store: self).sendDM(db: db, companyId: company.id, from: .system, to: "owner", text: text, now: now)
    }

    /// An ask's title as the owner's lines show it (`enterPendingOwner`): gated final display string, flagged when an agent's
    /// title claims to be the owner.
    static func ownerShownTitle(_ ask: Ask, knownValues: [(name: String, value: String)]?) -> String {
        guard let knownValues else { return titleHeldText }
        // Flagged only on the text the owner sees (Ruling 56): a withheld title is never checked.
        guard let shown = GlobalSearch.TextGate(knownValues: knownValues).final(ask.title, max: FileRequestCard.titleMax, inert: true) else {
            return FileRequestCard.withheld
        }
        guard ask.requesterId != "system", OwnerImpersonation.flags(text: shown, sender: .agent(ask.requesterId)) else { return shown }
        return OwnerImpersonation.digestPrefix + shown
    }

    /// Fix round 2 (Ruling C5-5): the owner's line when the stored values could not be read to check a title.
    public static let titleHeldText = "[title held back: the stored secrets aren't loaded, so it couldn't be checked]"

    /// The company's stored values as the engine has them loaded (the redactor's copy, which the engine reloads from the
    /// vault): every secret of the company with its current `updatedAt`, else nil (not loaded in full: fail closed). The
    /// Store holds no vault; this is its read of the same values inside a transaction.
    func engineKnownValues(db: Database, companyId: String) -> [(name: String, value: String)]? {
        guard let metas = try? SecretMeta.filter(Column("companyId") == companyId).order(Column("name")).fetchAll(db) else { return nil }
        let cache = redactor.cachedValues()
        var out: [(name: String, value: String)] = []
        for meta in metas {
            guard let loaded = cache["\(companyId):\(meta.name)"], loaded.updatedAt == meta.updatedAt else { return nil }
            out.append((meta.name, loaded.value))
        }
        return out
    }

    /// DMs the requester when the ask reaches a final status (unless the engine filed it).
    func tellRequester(_ db: Database, _ ask: Ask, text: String, now: Date) throws {
        guard ask.requesterId != "system", let requester = try Agent.fetchOne(db, key: ask.requesterId),
              requester.state != .killed else { return }
        try MessageRouter(store: self).sendDM(db: db, companyId: ask.companyId, from: .system, to: requester.name, text: text, now: now)
    }

    static func deciderText(_ ask: Ask) -> String {
        guard let by = ask.decidedBy else { return "the owner" }
        if by == "owner" { return "the owner" }
        if by.hasPrefix("policy:") { return "policy (\(by.dropFirst("policy:".count)))" }
        return by
    }

    /// Writes a final status and runs the effects: the requester's DM, supersession and a sprint plan's sprint
    /// (`applySprintPlanEffects`); a rescind runs `reverseAskEffects` (Store+AskLifecycle).
    func settle(_ db: Database, ask: inout Ask, status: AskStatus, decidedBy: String, tellRequesterToo: Bool = true, now: Date) throws {
        ask.status = status
        ask.decidedBy = decidedBy
        ask.statusSinceActive = try Store.activeNow(db: db, companyId: ask.companyId)
        ask.updatedAt = now
        try ask.update(db)
        if tellRequesterToo {
            let note = ask.ownerNote ?? ask.internalNote
            let tail = (note?.isEmpty ?? true) ? "" : ": \(Store.flat(note ?? ""))"
            try tellRequester(db, ask, text: "\(ask.ref) \(status.rawValue) by \(Store.deciderText(ask))\(tail)", now: now)
        }
        try applyAskEffects(db, ask: ask, now: now)
    }

    /// Effects of a final status. A newly approved ask supersedes the ask it names (unless that one is already rejected,
    /// expired or rescinded). A sprint plan starts its sprint when approved and frees its items when rejected or expired.
    func applyAskEffects(_ db: Database, ask: Ask, now: Date) throws {
        if ask.status == .rejected { try actingCEODeclined(db, ask: ask, now: now) }
        if ask.kind == .sprintPlan { try applySprintPlanEffects(db, ask: ask, now: now) }
        if ask.kind == .deploy { try applyDeployEffects(db, ask: ask, now: now) }
        if ask.kind == .humanTask { try applyHumanTaskEffects(db, ask: ask, now: now) }
        if ask.kind == .other { try applySimulatorApprovalEffects(db, ask: ask, now: now) }
        guard ask.status == .approved, let oldId = ask.supersedesId, var old = try Ask.fetchOne(db, key: oldId),
              old.companyId == ask.companyId else { return }
        guard ![AskStatus.rejected, .expired, .rescinded, .superseded].contains(old.status) else { return }
        old.status = .superseded
        old.statusSinceActive = try Store.activeNow(db: db, companyId: ask.companyId)
        old.updatedAt = now
        try old.update(db)
    }

    // MARK: Propose

    /// Files an ask. It routes to the first available approver for the kind (see `internalApprover`) and otherwise goes
    /// straight to the owner. `viaOwner` skips the internal step (engine-filed asks that must reach the owner).
    /// A repeat call with the same company, requester and `requestId` returns the existing ask. A `mechanical` decision is
    /// not an ask: use `recordMechanicalDecision`. `AskQuota` is applied inside the write that inserts the ask to every ask an
    /// agent files (fail-safe: a new agent path is limited without doing anything). Engine (`system`) asks are exempt;
    /// only the dev hook passes `quotaExempt: .devHook`.
    @discardableResult
    public func propose(companyId: String, by sender: Sender, kind: AskKind, risk: AskRisk? = nil, category: String? = nil,
                        title: String, summary: String, payload: AskPayload? = nil, itemId: String? = nil, subjectId: String? = nil,
                        supersedes: String? = nil, requestId: String? = nil, decisionClass: DecisionClass = .taste,
                        viaOwner: Bool = false, quotaExempt: AskQuota.Exemption? = nil, now: Date = Store.now()) throws -> Ask {
        // The document is read and hashed before the write transaction opens, so a slow file never holds the database.
        var document: PreparedDocument?
        if let raw = payload?.documentPath {
            guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
            document = try Store.readDocument(raw, workspace: company.workspacePath)
        }
        return try writer.write { db in
            try propose(db: db, companyId: companyId, by: sender, kind: kind, risk: risk, category: category, title: title,
                        summary: summary, payload: payload, document: document, itemId: itemId, subjectId: subjectId,
                        supersedes: supersedes, requestId: requestId, decisionClass: decisionClass, viaOwner: viaOwner,
                        quotaExempt: quotaExempt, now: now)
        }
    }

    func propose(db: Database, companyId: String, by sender: Sender, kind: AskKind, risk: AskRisk?, category: String?, title: String,
                 summary: String, payload: AskPayload?, document: PreparedDocument?, itemId: String?, subjectId: String?,
                 supersedes: String?, requestId: String?, decisionClass: DecisionClass, viaOwner: Bool,
                 quotaExempt: AskQuota.Exemption? = nil, announce: Bool = true, knownValues: [(name: String, value: String)]? = nil,
                 now: Date) throws -> Ask {
        let company = try requireCompany(db, companyId)
        let requester = try askRequester(db, sender, companyId: companyId)
        let rid = Store.cleanRequestId(requestId)
        if let rid, let existing = try Ask.filter(Column("companyId") == companyId && Column("requesterId") == requester.id
                                                  && Column("requestId") == rid).fetchOne(db) {
            return existing
        }
        // Every piece of text the ask stores is redacted raw, before cleaning, limits or flattening (Task 4-wire).
        let title = try redact(title), summary = try redact(summary), payload = try redact(payload)
        guard decisionClass != .mechanical else { throw WorkError.invalid("a mechanical decision is recorded, not filed as an ask") }
        guard kind.isDecision else { throw WorkError.invalid("\(kind.rawValue) asks are not proposed; use request_from_owner") }
        // Counted in the write that inserts, so two concurrent filings cannot both pass.
        if quotaExempt == nil, requester.id != "system" { try AskQuota.check(db: db, agentId: requester.id) }

        let extra = pack(for: company)?.reservedCategories ?? []
        var cat = ReservedMatters.normalize(category)
        if kind == .other {
            guard let c = cat, ReservedMatters.allowed(extra: extra).contains(c) else {
                throw WorkError.invalid("other asks must name a category: \(ReservedMatters.allowed(extra: extra).joined(separator: ", "))")
            }
        } else if kind.isGate || kind == .boost {
            cat = nil
        } else {
            cat = cat.map { Store.flat($0, max: 64).lowercased() }
        }
        let cleanTitle = try Store.cleanAskTitle(title)
        let cleanSummary = try Store.limitedText(summary, Store.maxAskText, "the summary") ?? ""

        if let itemId {
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such item") }
            guard item.companyId == companyId else { throw WorkError.forbidden("not in your company") }
        }
        if let supersedes {
            guard let old = try Ask.fetchOne(db, key: supersedes) else { throw WorkError.notFound("no such ask to supersede") }
            guard old.companyId == companyId else { throw WorkError.forbidden("not in your company") }
            guard old.kind == kind else { throw WorkError.invalid("supersedes must name an ask of the same kind") }
            // Only the agent that filed an ask can replace it; nobody supersedes another requester's (or the owner's) ask.
            guard old.requesterId == requester.id else { throw WorkError.forbidden("only the requester of \(old.ref) can supersede it") }
        }
        let (body, hash) = try prepare(payload, document: document,
                                       detailsLimit: kind == .humanTask ? HumanTaskPolicy.maxDetails : Store.maxAskText)

        let active = try Store.activeNow(db: db, companyId: companyId)
        let number = try Store.nextAskNumber(db: db, companyId: companyId)
        var ask = Ask(id: UUID().uuidString, companyId: companyId, number: number, kind: kind, category: cat,
                      risk: risk ?? .defaultFor(kind), requesterId: requester.id, itemId: itemId, title: cleanTitle,
                      summary: cleanSummary, payload: body, detailsHash: hash, status: .pendingInternal, createdActive: active,
                      statusSinceActive: active, createdAt: now, updatedAt: now, requestId: rid, decisionClass: decisionClass)
        ask.subjectId = subjectId
        ask.supersedesId = supersedes

        let approver = viaOwner ? nil : try internalApprover(db, company: company, kind: kind, requesterId: requester.id)
        if let approver {
            ask.internalApproverId = approver.id
            try ask.insert(db)
            let text = "\(ask.ref) needs your decision: \(try Store.displayTitle(db, ask)): \(ask.title) (decide with the decide tool)"
            try MessageRouter(store: self).sendDM(db: db, companyId: companyId, from: .system, to: approver.name, text: text, now: now)
        } else if announce {
            // The caller's values (read from its vault), else the engine's loaded copy (fix round 2).
            try enterPendingOwner(db, ask: &ask, company: company,
                                  knownValues: knownValues ?? engineKnownValues(db: db, companyId: company.id), now: now)
            try ask.insert(db)
        } else {
            // Decided in the same transaction (an access preset): no "approval needed" line or DM for the owner.
            ask.status = .pendingOwner
            try ask.insert(db)
        }
        return ask
    }

    /// Checks the brief and resolves the document: returns the payload to store and the document hash.
    private func prepare(_ payload: AskPayload?, document: PreparedDocument?,
                         detailsLimit: Int = Store.maxAskText) throws -> (AskPayload?, String?) {
        guard var p = payload else { return (nil, nil) }
        guard p.options.count <= AskPayload.maxOptions else { throw WorkError.invalid("an ask carries at most \(AskPayload.maxOptions) options") }
        p.question = try Store.limitedText(p.question, Store.maxAskField, "the question")
        p.details = try Store.limitedText(p.details, detailsLimit, "the details")
        p.recommendation = try Store.limitedText(p.recommendation, Store.maxAskField, "the recommendation")
        p.stakes = try Store.limitedText(p.stakes, Store.maxAskField, "the stakes")
        p.proposal = try Store.limitedText(p.proposal, Store.maxAskField, "the proposal")
        p.options = try p.options.map { o in
            var o = o
            guard let label = try Store.limitedText(o.label, 200, "an option label").map({ Store.flat($0, max: 200) }), !label.isEmpty else {
                throw WorkError.invalid("an option needs a label")
            }
            o.label = label
            o.pros = try Store.limitedText(o.pros, 1000, "an option's pros") ?? ""
            o.cons = try Store.limitedText(o.cons, 1000, "an option's cons") ?? ""
            o.effort = try Store.limitedText(o.effort, 200, "an option's effort").map { Store.flat($0, max: 200) } ?? ""
            o.risk = try Store.limitedText(o.risk, 200, "an option's risk").map { Store.flat($0, max: 200) } ?? ""
            return o
        }
        var hash: String?
        if p.documentPath != nil {
            guard let document else { throw WorkError.invalid("document_path was not read") }
            p.documentPath = document.path
            hash = document.hash
        }
        return (p, hash)
    }

    /// A mechanical decision needs no approval: it is logged to the activity feed (and the item's history).
    /// Only an ordinary `other` matter can be mechanical: gate kinds and reserved categories always need approval.
    public func recordMechanicalDecision(companyId: String, by sender: Sender, kind: AskKind, category: String?, title: String,
                                         summary: String, itemId: String? = nil, now: Date = Store.now()) throws {
        try writer.write { db in
            let company = try requireCompany(db, companyId)
            let requester = try askRequester(db, sender, companyId: companyId)
            guard kind == .other else { throw WorkError.invalid("only 'other' decisions can be mechanical; \(kind.rawValue) needs approval") }
            let extra = pack(for: company)?.reservedCategories ?? []
            guard let cat = ReservedMatters.normalize(category), ReservedMatters.allowed(extra: extra).contains(cat) else {
                throw WorkError.invalid("other asks must name a category: \(ReservedMatters.allowed(extra: extra).joined(separator: ", "))")
            }
            guard !ReservedMatters.isReserved(cat, extra: extra) else {
                throw WorkError.invalid("\(cat) is a reserved matter and can't be mechanical; propose it for approval")
            }
            let cleanTitle = try Store.cleanAskTitle(title)
            let text = "Recorded: \(kind.title) by @\(requester.handle): \(cleanTitle)"
            try ActivityEvent(companyId: companyId, agentId: requester.id == "system" ? nil : requester.id, turnId: nil, kind: .approval,
                              text: text, createdAt: now).insert(db)
            if let itemId {
                guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such item") }
                guard item.companyId == companyId else { throw WorkError.forbidden("not in your company") }
                let why = (try Store.limitedText(summary, Store.maxAskField, "the summary")).map { " — \(Store.flat($0))" } ?? ""
                try recordItemEvent(db: db, item: item, actor: requester.id, kind: .commented, text: text + why, now: now)
            }
        }
    }

    /// A question for the owner (`info` ask). `expiresInHours` counts company-active time. `AskQuota` applies in the same
    /// write to every agent requester; only the dev hook passes `quotaExempt: .devHook`.
    @discardableResult
    public func requestFromOwner(companyId: String, by sender: Sender, title: String, question: String, details: String? = nil,
                                 expiresInHours: Double? = nil, requestId: String? = nil,
                                 quotaExempt: AskQuota.Exemption? = nil, now: Date = Store.now()) throws -> Ask {
        try writer.write { db in
            let company = try requireCompany(db, companyId)
            let requester = try askRequester(db, sender, companyId: companyId)
            let rid = Store.cleanRequestId(requestId)
            if let rid, let existing = try Ask.filter(Column("companyId") == companyId && Column("requesterId") == requester.id
                                                      && Column("requestId") == rid).fetchOne(db) { return existing }
            if quotaExempt == nil, requester.id != "system" { try AskQuota.check(db: db, agentId: requester.id) }
            // Redacted raw, before cleaning and limits (Task 4-wire).
            let cleanTitle = try Store.cleanAskTitle(try redact(title))
            guard let q = try Store.limitedText(try redact(question), Store.maxAskField, "the question") else { throw WorkError.invalid("the question is empty") }
            let body = AskPayload(question: q, details: try Store.limitedText(try redact(details), Store.maxAskText, "the details"))
            if let h = expiresInHours, !(h > 0 && h <= Store.maxExpiryHours) {
                throw WorkError.invalid("expires_in_hours must be between 0 and \(Int(Store.maxExpiryHours))")
            }
            let active = try Store.activeNow(db: db, companyId: companyId)
            let number = try Store.nextAskNumber(db: db, companyId: companyId)
            var ask = Ask(id: UUID().uuidString, companyId: companyId, number: number, kind: .info, risk: .low,
                          requesterId: requester.id, title: cleanTitle, summary: q, payload: body, status: .pendingOwner,
                          createdActive: active, statusSinceActive: active, createdAt: now, updatedAt: now, requestId: rid)
            ask.expiresActive = expiresInHours.map { active + $0 * 3600 }
            try enterPendingOwner(db, ask: &ask, company: company, knownValues: engineKnownValues(db: db, companyId: company.id), now: now)
            try ask.insert(db)
            return ask
        }
    }

    /// Engine-filed: Ultra proposed after repeated failures always goes to the owner, under every preset. One unresolved
    /// boost ask per item.
    @discardableResult
    public func fileFailurePathBoost(companyId: String, itemId: String, reason: String, now: Date = Store.now()) throws -> Ask {
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such item") }
            guard item.companyId == companyId else { throw WorkError.forbidden("not in your company") }
            if let open = try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.boost && Column("itemId") == itemId
                                         && [AskStatus.pendingInternal, .pendingOwner].map(\.rawValue).contains(Column("status")))
                .fetchOne(db) { return open }
            // Task 14u: the boost card (its text, three options, one active day), always the owner's under every preset.
            return try routeUltra(db: db, company: try requireCompany(db, companyId), item: item, by: .system, variant: .full,
                                  origin: .failurePath, reason: reason, now: now).ask
        }
    }

    // MARK: Internal decision

    /// The internal approver's decision. Reject → `rejected`. Approve → the autonomy preset (recomputed from the
    /// approver's category and risk, which may be raised, never lowered) decides between the owner and a policy approval.
    @discardableResult
    public func internalDecide(askId: String, by sender: Sender, approve: Bool, note: String, category: String? = nil,
                               risk: AskRisk? = nil, now: Date = Store.now()) throws -> Ask {
        try writer.write { db in
            var ask = try requireAsk(db, askId)
            guard case .agent(let agentId) = sender else { throw WorkError.forbidden("only the internal approver can decide \(ask.ref)") }
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == ask.companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard ask.status == .pendingInternal else { throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
            guard ask.internalApproverId == agentId, agent.state != .killed else {
                throw WorkError.forbidden("only @\(try Store.handle(db, ask.internalApproverId)) can decide \(ask.ref)")
            }
            let company = try requireCompany(db, ask.companyId)
            let extra = pack(for: company)?.reservedCategories ?? []
            if let risk {
                guard risk >= ask.risk else { throw WorkError.invalid("the approver can raise risk, never lower it") }
                ask.risk = risk
            }
            if let raised = ReservedMatters.normalize(category) {
                guard ReservedMatters.isReserved(raised, extra: extra) else {
                    throw WorkError.invalid("the approver can raise the category to a reserved matter, never lower it")
                }
                ask.category = raised
            }
            ask.internalNote = Store.flat(note, max: Store.maxAskField)
            ask.internalDecidedAt = now
            guard approve else {
                try settle(db, ask: &ask, status: .rejected, decidedBy: "@\(agent.name)", now: now)
                return ask
            }
            var role = AutonomyPolicy.ownerRole(kind: ask.kind, risk: ask.risk, category: ask.category, preset: company.autonomy,
                                                extraReserved: extra, decisionClass: ask.decisionClass)
            // An ask that replaces one the owner decided (or is still deciding) always goes back to the owner.
            if role == .fyi, let oldId = ask.supersedesId, let old = try Ask.fetchOne(db, key: oldId),
               old.status == .pendingOwner || old.decidedBy == "owner" || old.ownerDecidedAt != nil {
                role = .approve
            }
            switch role {
            case .approve:
                ask.updatedAt = now
                try enterPendingOwner(db, ask: &ask, company: company, knownValues: engineKnownValues(db: db, companyId: company.id), now: now)
                try ask.update(db)
            case .fyi:
                ask.fyi = true
                try settle(db, ask: &ask, status: .approved, decidedBy: "policy:\(company.autonomy.rawValue)", now: now)
                let text = "FYI: \(ask.ref) \(try Store.displayTitle(db, ask)) approved by @\(agent.name) under \(company.autonomy.rawValue): \(ask.title)"
                try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .approval, text: text, createdAt: now).insert(db)
            }
            return ask
        }
    }

    // MARK: Owner decisions

    /// The owner approves or rejects a decision ask, whether or not the internal approver has decided. Approving a
    /// document that changed since it was proposed needs `acknowledgeChange`.
    ///
    /// The engine's own quarantine ask (`quarantineRef(of:)`, A2): approving it is the owner's accept of that quarantine,
    /// the same pinned merge as `brahma main accept <company> <ref>` (`acceptMainCommit`: exactly the recorded commit, refused
    /// and flagged if the ref moved, the ask then still open and the merge step still held). Rejecting it leaves `main` as it
    /// is and keeps the ref for inspection (a later `main accept` of the ref still merges the recorded commit); either way the
    /// settled ask releases the merge step.
    @discardableResult
    public func ownerDecide(askId: String, approve: Bool, note: String = "", acknowledgeChange: Bool = false,
                            now: Date = Store.now()) throws -> Ask {
        if let seen = try ask(id: askId), let ref = Self.quarantineRef(of: seen) {
            guard seen.status.isPending else { throw WorkError.conflict("\(seen.ref) is already \(seen.status.rawValue)") }
            if approve {
                let accepted = try acceptMainCommit(companyId: seen.companyId, ref: ref, note: note.isEmpty ? nil : note)
                return accepted.ask ?? seen
            }
        }
        return try ownerDecideRecorded(askId: askId, approve: approve, note: note, acknowledgeChange: acknowledgeChange, now: now)
    }

    private func ownerDecideRecorded(askId: String, approve: Bool, note: String, acknowledgeChange: Bool, now: Date) throws -> Ask {
        // Read and hash the document before the write transaction; the proposed path and hash never change.
        var currentHash: String?? = nil
        if approve, !acknowledgeChange, let seen = try ask(id: askId), seen.payload?.documentPath != nil,
           let company = try company(id: seen.companyId) {
            currentHash = .some(currentDocumentHash(seen, company: company))
        }
        return try writer.write { db in
            try ownerDecide(db: db, askId: askId, approve: approve, note: note, acknowledgeChange: acknowledgeChange,
                            currentHash: currentHash, grant: nil, now: now)
        }
    }

    /// `ownerDecide` inside the caller's write transaction. `currentHash` is the document's hash read before the transaction
    /// (`.some(nil)`: unreadable; nil: not read). Approving a `grant` ask needs `grant` (`Store.approveAccess`, with the scope
    /// and duration the owner chose) and writes the grant in the same transaction; a plain approve of one is refused. Besides
    /// the owner paths, its one caller is an access preset the owner turned on (`requestAccess`, owner-delegated, note
    /// `auto: <title>`, `decidedBy` `preset:<id>`).
    func ownerDecide(db: Database, askId: String, approve: Bool, note: String, acknowledgeChange: Bool, currentHash: String??,
                     grant: GrantApproval?, decidedBy: String = "owner", extensionApproved: Bool = false,
                     providingSecret: Bool = false, now: Date) throws -> Ask {
        var ask = try requireAsk(db, askId)
        // A human task is answered only by doing it (`completeHumanTask`, values to the vault) or declining it (Task 9).
        if ask.kind == .humanTask { throw Self.humanTaskConflict(ask) }
        // A secret request is approved only by providing the secret (`Store.provideSecret`): a bare approve has no value to give.
        if approve, ask.kind == .request, SecretRequests.requested(ask) != nil, !providingSecret {
            let slug = try Company.fetchOne(db, key: ask.companyId)?.slug ?? "<co>"
            throw WorkError.invalid("provide the secret instead: brahma secret provide \(slug) \(ask.ref) [--test] (or in the app)")
        }
        // Plan C Task C5: a file request is answered with a file (`answerFileRequest`) or declined (`declineFileRequest`).
        if approve, FileRequests.isFileRequest(ask) {
            throw WorkError.invalid("\(ask.ref) asks for a file: drop one on it in the Inbox, or decline it")
        }
        guard ask.kind.isDecision else {
            throw WorkError.invalid(ask.kind == .info ? "\(ask.ref) is a question; answer it" : "\(ask.ref) is an engine alert; acknowledge it")
        }
        guard ask.status.isPending else { throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
        if approve, !acknowledgeChange, ask.payload?.documentPath != nil, let proposed = ask.detailsHash,
           let current = currentHash, current != proposed {
            throw WorkError.conflict("\(ask.ref)'s document changed since it was proposed; read it again and approve with --ack-changed")
        }
        if approve, ask.kind == .grant, grant == nil {
            let slug = try Company.fetchOne(db, key: ask.companyId)?.slug ?? "<co>"
            throw WorkError.invalid("approve access with: brahma access approve \(slug) \(ask.ref) --scope … --duration …")
        }
        // An extension ask is carried out by `ExtensionLibrary.approve` (the app) before it is approved; a plain approve is refused.
        if approve, ask.kind == .extension, !extensionApproved { throw WorkError.invalid(ExtensionLibrary.cliApproveRefusal) }
        if !approve, ask.kind == .extension { try ExtensionLibrary.declined(db, ask: ask, now: now) }
        ask.ownerNote = Store.flat(note, max: Store.maxAskField)
        ask.ownerDecidedAt = now
        try settle(db, ask: &ask, status: approve ? .approved : .rejected, decidedBy: decidedBy, now: now)
        if approve, ask.kind == .grant, let grant { try createGrant(db, ask: ask, approval: grant, now: now) }
        if !approve, let ref = Self.quarantineRef(of: ask) {
            let sha = ask.subjectId.map { String($0.drop { $0 != "@" }.dropFirst().prefix(12)) } ?? ""
            try ActivityEvent(companyId: ask.companyId, agentId: nil, turnId: nil, kind: .work,
                              text: "the owner rejected \(ref): main is unchanged; the changes stay on \(ref) (\(sha)) for inspection",
                              createdAt: now).insert(db)
        }
        return ask
    }

    /// The owner sends a decision ask back: `rejected`, with the new direction as the answer.
    @discardableResult
    public func ownerReplan(askId: String, text: String, now: Date = Store.now()) throws -> Ask {
        try writer.write { db in
            var ask = try requireAsk(db, askId)
            if ask.kind == .humanTask { throw Self.humanTaskConflict(ask) }
            guard ask.kind.isDecision else { throw WorkError.invalid("\(ask.ref) is not a decision") }
            guard ask.status.isPending else { throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
            guard let answer = try Store.limitedText(text, Store.maxAskField, "the new plan") else { throw WorkError.invalid("the new plan is empty") }
            ask.ownerAnswer = answer
            ask.ownerDecidedAt = now
            try settle(db, ask: &ask, status: .rejected, decidedBy: "owner", tellRequesterToo: false, now: now)
            try tellRequester(db, ask, text: "\(ask.ref) needs a new plan: \(Store.flat(answer, max: Store.maxAskField))", now: now)
            return ask
        }
    }

    /// The owner answers a question (`info` ask), or (Plan C Task C5) an agent's file request (`FileRequests.isFileRequest`:
    /// `Store.answerFileRequest`, `declineFileRequest`); the requester gets the answer as a DM from the owner.
    @discardableResult
    public func ownerAnswer(askId: String, text: String, now: Date = Store.now()) throws -> Ask {
        try writer.write { db in try ownerAnswer(db: db, askId: askId, text: text, now: now).ask }
    }

    /// `ownerAnswer` inside the caller's write transaction, with the answer DM's stored `kind` and chips (Plan C Task C5: a file
    /// request's answer is the drop's `kind = share` message). Returns the ask and the DM (nil when the requester is the engine
    /// or killed).
    func ownerAnswer(db: Database, askId: String, text: String, kind: MessageKind = .text, inline: [MessageRef] = [],
                     firstInlinePosition: Int = 0, now: Date) throws -> (ask: Ask, message: Message?) {
        var ask = try requireAsk(db, askId)
        guard ask.kind == .info || FileRequests.isFileRequest(ask) else { throw WorkError.invalid("\(ask.ref) is not a question") }
        guard ask.status == .pendingOwner else { throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
        guard let answer = try Store.limitedText(text, Store.maxAskText, "the answer") else { throw WorkError.invalid("the answer is empty") }
        ask.ownerAnswer = answer
        ask.ownerDecidedAt = now
        try settle(db, ask: &ask, status: .answered, decidedBy: "owner", tellRequesterToo: false, now: now)
        var message: Message?
        if ask.requesterId != "system", let requester = try Agent.fetchOne(db, key: ask.requesterId), requester.state != .killed {
            message = try MessageRouter(store: self).sendDM(db: db, companyId: ask.companyId, from: .owner, to: requester.name, text: answer,
                                                            now: now, kind: kind, inline: inline, firstInlinePosition: firstInlinePosition)
        }
        return (ask, message)
    }

    /// The owner acknowledges an FYI (a policy-approved ask) or an engine alert (which then counts as answered).
    @discardableResult
    public func acknowledge(askId: String, now: Date = Store.now()) throws -> Ask {
        try writer.write { db in
            var ask = try requireAsk(db, askId)
            if ask.kind == .engineAlert, ask.status == .pendingOwner {
                ask.acknowledgedAt = now
                ask.ownerAnswer = "acknowledged"
                ask.ownerDecidedAt = now
                try settle(db, ask: &ask, status: .answered, decidedBy: "owner", tellRequesterToo: false, now: now)
                return ask
            }
            guard ask.fyi, ask.status == .approved else { throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
            guard ask.acknowledgedAt == nil else { throw WorkError.conflict("\(ask.ref) is already acknowledged") }
            ask.acknowledgedAt = now
            ask.updatedAt = now
            try ask.update(db)
            return ask
        }
    }

    // MARK: Queries

    public func asks(companyId: String, statuses: Set<AskStatus>? = nil) throws -> [Ask] {
        try writer.read { db in
            var request = Ask.filter(Column("companyId") == companyId).order(Column("number"))
            if let statuses { request = request.filter(statuses.map(\.rawValue).contains(Column("status"))) }
            return try request.fetchAll(db)
        }
    }

    public func ask(id: String) throws -> Ask? {
        try writer.read { db in try Ask.fetchOne(db, key: id) }
    }

    /// "A-12", "a-12" or "12", within one company.
    public func ask(companyId: String, ref: String) throws -> Ask? {
        try writer.read { db in try Store.ask(db: db, companyId: companyId, ref: ref) }
    }

    /// The ask `ref` ("A-3" or "3") names in this company; nil for anything else (another company's ask is out of reach).
    static func ask(db: Database, companyId: String, ref: String) throws -> Ask? {
        var text = ref.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("a-") { text.removeFirst(2) }
        guard let number = Int(text) else { return nil }
        return try Ask.filter(Column("companyId") == companyId && Column("number") == number).fetchOne(db)
    }

    /// Asks waiting for this agent's decision, optionally of one kind.
    public func pendingInternalAsks(approverId: String, kind: AskKind? = nil) throws -> [Ask] {
        try writer.read { db in
            var request = Ask.filter(Column("internalApproverId") == approverId && Column("status") == AskStatus.pendingInternal.rawValue)
                .order(Column("number"))
            if let kind { request = request.filter(Column("kind") == kind) }
            return try request.fetchAll(db)
        }
    }

    /// The model context for an agent's turn: an approver with a pending architecture (or PRD) ask is deciding one.
    public func askModelContext(agentId: String) throws -> ModelContext {
        ModelContext(decidingArchitecture: !(try pendingInternalAsks(approverId: agentId, kind: .architecture)).isEmpty,
                     decidingPRD: !(try pendingInternalAsks(approverId: agentId, kind: .prd)).isEmpty)
    }

    /// Asks waiting for the owner.
    public func ownerWaitingCount(companyId: String) throws -> Int {
        try writer.read { db in
            try Ask.filter(Column("companyId") == companyId && Column("status") == AskStatus.pendingOwner.rawValue).fetchCount(db)
        }
    }

    /// Asks waiting for the owner that the app has not notified about yet.
    public func unnotifiedOwnerAsks() throws -> [Ask] {
        try writer.read { db in
            try Ask.filter(Column("status") == AskStatus.pendingOwner.rawValue && Column("notifiedAt") == nil).order(Column("createdAt"), Column.rowID).fetchAll(db)
        }
    }

    public func markAskNotified(ids: [String], now: Date = Store.now()) throws {
        try writer.write { db in
            for id in ids { try db.execute(sql: "UPDATE ask SET notifiedAt = ? WHERE id = ?", arguments: [now, id]) }
        }
    }

    /// Marks the banner of each ask as shown, but only while its `remindCount` is still the planned one: a reminder that
    /// fired between planning and marking keeps its new banner due.
    public func markAskNotified(planned: [String: Int], now: Date = Store.now()) throws {
        guard !planned.isEmpty else { return }
        try writer.write { db in
            for (id, remind) in planned {
                try db.execute(sql: "UPDATE ask SET notifiedAt = ? WHERE id = ? AND remindCount = ?", arguments: [now, id, remind])
            }
        }
    }

    /// True when an approved ask of this kind exists (rescinded and superseded asks do not count). In a company with at most
    /// eight non-killed agents an approved `prd` ask also satisfies the architecture gate.
    public func hasApproved(companyId: String, kind: AskKind) throws -> Bool {
        try writer.read { db in try Store.hasApproved(db: db, companyId: companyId, kind: kind) }
    }

    static func hasApproved(db: Database, companyId: String, kind: AskKind) throws -> Bool {
        func approved(_ k: AskKind) throws -> Bool {
            try Ask.filter(Column("companyId") == companyId && Column("kind") == k && Column("status") == AskStatus.approved.rawValue).fetchCount(db) > 0
        }
        if try approved(kind) { return true }
        if kind == .architecture, try companyIsSmall(db, companyId: companyId) { return try approved(.prd) }
        return false
    }

    public func setAutonomy(companyId: String, _ preset: AutonomyPreset) throws {
        try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw WorkError.notFound("no such company") }
            _ = try Company.filter(key: companyId).updateAll(db, Column("autonomy").set(to: preset.rawValue))
        }
    }
}

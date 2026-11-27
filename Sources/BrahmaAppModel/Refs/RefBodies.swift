import Foundation
import BrahmaCore

/// A chip in a ref header or card: `UNCOMMITTED`, `LIVE`, `TAINTED · <reason>`, `REDACTED`, `LEASED BY @h`, `AS SHARED @sha · VIEW
/// LATEST`, `HIDDEN CHARACTERS`, `UNVERIFIED`. Tones follow the Global Constraints' color tokens (warning `.warn`, LIVE `.busy`,
/// locked and purged `.idle`).
public struct RefChip: Equatable, Sendable {
    public var text: String
    public var tone: PreviewTone
    public init(text: String, tone: PreviewTone) { self.text = text; self.tone = tone }
}

/// The preview header's actions for the opened ref (collab design §1.5).
public enum RefAction: Equatable, Sendable, CaseIterable {
    case copyRef, shareTo, askToExplain, saveAs, openInChat, viewOriginal, vouch, purge
}

public struct RefHeader: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var chips: [RefChip]
    public var actions: [RefAction]
    public init(title: String, subtitle: String, chips: [RefChip], actions: [RefAction]) {
        self.title = title; self.subtitle = subtitle; self.chips = chips; self.actions = actions
    }
}

/// What the OPENED tab (or the chat inspector) draws for a ref, one case per renderer (collab design §1.3).
public enum RefContent: Equatable, Sendable {
    case code(lines: [[CodeSpan]], firstLine: Int, highlight: LineRange?, hasHidden: Bool)
    case diff(DiffModel, live: Bool, updated: String?)
    case file(FileBody, provenance: Provenance)
    case item(itemId: String)
    case ask(askId: String)
    case kb(markdown: String, revision: String, backlinks: [Backlink])
    case artifact(Artifact)
    case preview(surfaceId: String, path: String, viewport: PreviewViewport, builtBy: String)
    case run(lines: [[AnsiSpan]], footer: String)
    case release(Release)
    case thread(root: Message, replies: [Message])
    case agentNow(AgentNowModel)
    /// `fact:<query>` and `sprint:<n>`: printed through `FactsResolver.block`.
    case fact(FactAnswer)
    /// A `show` answer: the agent's note (gated), its claims with their citations, the refs, the citation verdict and who answered.
    case answer(note: String, claims: [Claim], refs: [WorkRef], verified: Bool, by: String)
    case unavailable(String)
}

public struct RefBody: Equatable, Sendable {
    public var header: RefHeader
    public var content: RefContent
    public init(header: RefHeader, content: RefContent) { self.header = header; self.content = content }
}

/// What a render needs beyond the store: the owner's stored secret values (from the injected `AppModel.secretVault`, never the
/// Keychain in tests), the data home, the archive and PDF reader, the owner's time zone, a confined root for per-open file
/// copies, the agent handles and the clock.
public struct RefRenderContext: Sendable {
    public var companyId: String
    public var knownValues: [(name: String, value: String)]
    public var paths: BrahmaPaths
    public var archives: any ArchiveReader
    public var timeZone: TimeZone
    public var tempRoot: URL
    public var handles: [String: String]
    public var now: Date

    public init(companyId: String, knownValues: [(name: String, value: String)], paths: BrahmaPaths, archives: any ArchiveReader, timeZone: TimeZone,
                tempRoot: URL, handles: [String: String], now: Date) {
        self.companyId = companyId; self.knownValues = knownValues; self.paths = paths; self.archives = archives; self.timeZone = timeZone; self.tempRoot = tempRoot
        self.handles = handles; self.now = now
    }
}

/// One body per kind (collab design §1.3). Bytes come only through `Store.renderRef` (C2b-carry Ruling 42: `gatedBytes`); every
/// final display string is gated against the stored values (`GlobalSearch.TextGate`, Rulings 53–55); every open writes a
/// `refRead(via:)` row; nothing here runs on the main actor.
public enum RefBodies {
    public static let unavailableText = "NO LONGER AVAILABLE"
    public static let memoryText = "OPEN THIS IN THE MEMORY BROWSER"
    public static let channelText = "OPEN IN CHAT"
    /// Lines longer than this (UTF-8 bytes) are cut with `…` in `CodeView` (design §4.6).
    public static let maxLineBytes = 4096
    /// What a code or thread body may weigh (text over it is cut).
    public static let maxTextBytes = 2_097_152

    /// The body of `resolved` for the owner, off the main actor. `via` names the read (`Store.tabReadVia`, `inspectorReadVia`); nil
    /// renders without recording a read (a card).
    public static func body(for resolved: ResolvedRef, store: Store, companyId: String, context: RefRenderContext,
                            via: String? = Store.tabReadVia) async throws -> RefBody {
        try await Task.detached(priority: .userInitiated) {
            try bodyNow(for: resolved, store: store, companyId: companyId, context: context, via: via)
        }.value
    }

    /// `body(for:)`, synchronously (the caller is already off the main actor).
    public static func bodyNow(for resolved: ResolvedRef, store: Store, companyId: String, context ctx: RefRenderContext, via: String?) throws -> RefBody {
        let gate = GlobalSearch.TextGate(knownValues: ctx.knownValues)
        guard resolved.visibility == .full, resolved.state != .purged else {
            return RefBody(header: RefHeader(title: "", subtitle: "", chips: [], actions: []), content: .unavailable(unavailableText))
        }
        let ref = resolved.ref
        func header(chips extra: [RefChip] = [], hasHidden: Bool = false, live: Bool = false, actions: [RefAction]? = nil) -> RefHeader {
            self.header(for: resolved, store: store, companyId: companyId, gate: gate, extra: extra, hasHidden: hasHidden, live: live, actions: actions)
        }
        func unavailable(_ text: String = unavailableText) -> RefBody { RefBody(header: header(), content: .unavailable(text)) }
        func read() throws {
            if let via { try store.recordOwnerRead(companyId: companyId, ref: ref, via: via, tainted: resolved.tainted, now: ctx.now) }
        }
        func render() throws -> RefRender {
            try store.renderRef(companyId: companyId, ref: ref, knownValues: ctx.knownValues, paths: ctx.paths, archives: ctx.archives, via: via, now: ctx.now)
        }
        do {
            switch ref.kind {
            case .memory:
                return unavailable(memoryText)
            case .channel:
                return unavailable(channelText)
            case .file, .resource:
                let r = try render()
                return try fileBody(r, resolved: resolved, header: header, ctx: ctx, gate: gate)
            case .artifact:
                guard let n = Int(ref.id), let a = try store.artifact(companyId: companyId, number: n) else { return unavailable() }
                try read()
                return RefBody(header: header(), content: .artifact(a))
            case .diff:
                let r = try render()
                let live = ref.isWorktree && ref.params["snapshot"] == nil
                let model = DiffModel.parse(patch: redacted(r.text ?? "", knownValues: ctx.knownValues))
                return RefBody(header: header(hasHidden: model.hasHidden, live: live),
                               content: .diff(model, live: live, updated: live ? "updated just now" : nil))
            case .commit:
                let r = try render()
                let text = redacted(r.text ?? "", knownValues: ctx.knownValues)
                let model = DiffModel.parse(patch: text)
                var h = header(hasHidden: model.hasHidden)
                if let subject = text.split(separator: "\n", maxSplits: 1).first, let shown = gate.final(String(subject), max: SafeTitle.max) {
                    h.subtitle = [shown, h.subtitle].filter { !$0.isEmpty }.joined(separator: " · ")
                }
                return RefBody(header: h, content: .diff(model, live: false, updated: nil))
            case .item:
                guard let item = try store.workItem(companyId: companyId, key: ref.id) else { return unavailable() }
                try read()
                return RefBody(header: header(), content: .item(itemId: item.id))
            case .ask:
                guard let n = Int(ref.id), let ask = try store.asks(companyId: companyId).first(where: { $0.number == n }) else { return unavailable() }
                try read()
                return RefBody(header: header(), content: .ask(askId: ask.id))
            case .kb:
                guard let view = try store.kbRead(companyId: companyId, reader: .owner, path: ref.id, section: ref.params["section"]) else {
                    return unavailable()
                }
                let backlinks = try store.backlinks(companyId: companyId, ref: ref, reader: .owner)
                try read()
                let markdown = cut(redacted(view.text, knownValues: ctx.knownValues))
                return RefBody(header: header(hasHidden: InvisibleMarkers.holdsHidden(markdown)),
                               content: .kb(markdown: markdown, revision: String(view.revision), backlinks: backlinks))
            case .preview:
                guard let params = PreviewRefParams.validate(path: ref.params["path"], viewport: ref.params["viewport"]),
                      let viewport = try? PreviewViewport.parse(params["viewport"] ?? "desktop"),
                      let surface = try store.previewSurfaces(companyId: companyId).first(where: { $0.name == ref.id }) else { return unavailable() }
                try read()
                let builtBy = surface.setById == "owner" ? "owner" : "@" + (ctx.handles[surface.setById] ?? surface.setById)
                return RefBody(header: header(), content: .preview(surfaceId: surface.id, path: params["path"] ?? "/", viewport: viewport, builtBy: builtBy))
            case .run:
                let r = try render()
                let text = redacted(r.text ?? "", knownValues: ctx.knownValues)
                let lines = AnsiText.parse(cut(text))
                return RefBody(header: header(hasHidden: InvisibleMarkers.holdsHidden(text)),
                               content: .run(lines: lines, footer: gate.final(resolved.subtitle, max: SafeTitle.max) ?? ""))
            case .release:
                let refText = ref.id.hasPrefix("R-") ? ref.id : "R-\(ref.id)"
                guard let release = try store.release(companyId: companyId, ref: refText) else { return unavailable() }
                try read()
                return RefBody(header: header(), content: .release(release))
            case .message, .thread:
                let t = try store.thread(companyId: companyId, rootId: ref.id, reader: .owner)
                try read()
                func clean(_ m: Message) -> Message {
                    var m = m
                    m.text = cut(redacted(m.text, knownValues: ctx.knownValues))
                    return m
                }
                let root = clean(t.root), replies = t.replies.map(clean)
                let hidden = ([root] + replies).contains { InvisibleMarkers.holdsHidden($0.text) }
                return RefBody(header: header(hasHidden: hidden), content: .thread(root: root, replies: replies))
            case .agent:
                let model = try agentNow(resolved, store: store, companyId: companyId, ctx: ctx, gate: gate)
                try read()
                var chips: [RefChip] = []
                if let tainted = model.taintedBy { chips.append(RefChip(text: tainted.uppercased(), tone: .warn)) }
                return RefBody(header: header(chips: chips, hasHidden: model.liveDiff?.hasHidden ?? false, live: model.liveDiff != nil),
                               content: .agentNow(model))
            case .sprint, .fact:
                guard let answer = try FactsResolver(store: store).answer(for: ref, companyId: companyId, reader: .owner, now: ctx.now, gate: gate) else {
                    return unavailable()
                }
                try read()
                return RefBody(header: header(), content: .fact(answer))
            }
        } catch let e as WorkError {
            // A refusal of the gate or the store: the owner sees the engine's words (never a value), nothing is drawn.
            return RefBody(header: header(), content: .unavailable(gate.final(e.message, max: 400) ?? unavailableText))
        }
    }

    // MARK: Files

    static func fileBody(_ r: RefRender, resolved: ResolvedRef, header: ([RefChip], Bool, Bool, [RefAction]?) -> RefHeader,
                         ctx: RefRenderContext, gate: GlobalSearch.TextGate) throws -> RefBody {
        let ext = r.ext.lowercased()
        let kind = ArtifactKind.from(ext: ext)
        let binary = r.data.prefix(OpenRefLimits.binarySniffBytes).contains(0)
        let isCode = !binary && (kind == nil || kind == .code || kind == .text)
        if isCode {
            let text = redacted(String(decoding: r.data.prefix(maxTextBytes), as: UTF8.self), knownValues: ctx.knownValues)
            var lines = CodeHighlighter.highlight(cutLines(text), language: CodeLanguage.detect(path: resolved.ref.kind == .file ? resolved.ref.id : "x.\(ext)"))
            // A file ending in a newline shows its lines, not a last empty one.
            if lines.count > 1, lines.last?.isEmpty == true { lines.removeLast() }
            let hidden = CodeHighlighter.hasHidden(lines)
            return RefBody(header: header([], hidden, false, nil),
                           content: .code(lines: lines, firstLine: 1, highlight: resolved.ref.range, hasHidden: hidden))
        }
        // Anything else: a per-open confined copy for 4a's `FileBody` (agent and outside files open out of process: `effectiveMode`).
        let dir = ctx.tempRoot.appending(path: "open-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = fileName(for: resolved.ref, ext: ext)
        let url = dir.appending(path: name)
        try r.data.write(to: url, options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let body = FileBody.make(url: url, kind: kind ?? (binary ? .text : .text), root: dir)
        var actions: [RefAction]? = nil
        if resolved.ref.kind == .resource, resolved.state == .redacted { actions = defaultActions(for: resolved) + [.viewOriginal] }
        return RefBody(header: header([], false, false, actions), content: .file(body, provenance: resolved.provenance))
    }

    /// An engine-made file name for the copy: the path's last component for a file (its own characters are never trusted: only
    /// `[A-Za-z0-9._-]` survive), `F-<n>.<ext>` for a resource.
    static func fileName(for ref: WorkRef, ext: String) -> String {
        let safeExt = ext.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        if ref.kind == .resource { return "F-\(ref.id)" + (safeExt.isEmpty ? "" : ".\(safeExt)") }
        let last = ref.id.split(separator: "/").last.map(String.init) ?? "file"
        var base = String(last.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") })
        if base.isEmpty || base.hasPrefix(".") { base = "file" + base }
        if !safeExt.isEmpty, !base.lowercased().hasSuffix(".\(safeExt)") { base += ".\(safeExt)" }
        return base
    }

    // MARK: Header

    static func header(for resolved: ResolvedRef, store: Store, companyId: String, gate: GlobalSearch.TextGate, extra: [RefChip],
                       hasHidden: Bool, live: Bool, actions: [RefAction]?) -> RefHeader {
        let ref = resolved.ref
        let title = gate.final(resolved.title, max: SafeTitle.max).flatMap { $0.isEmpty ? nil : $0 }
            ?? gate.final(ref.canonical, max: SafeTitle.max) ?? ref.kind.rawValue
        let subtitle = gate.final(resolved.subtitle, max: SafeTitle.max) ?? ""
        var chips: [RefChip] = []
        func chip(_ text: String, _ tone: PreviewTone) {
            if let shown = gate.final(text, max: SafeTitle.max), !shown.isEmpty { chips.append(RefChip(text: shown, tone: tone)) }
        }
        if (ref.kind == .file || ref.kind == .diff), ref.isWorktree, ref.params["snapshot"] == nil || ref.kind == .file { chip("UNCOMMITTED", .warn) }
        if live { chip("LIVE", .busy) }
        if resolved.tainted { chip("TAINTED · \(resolved.taintReason ?? "outside content")", .warn) }
        if resolved.state == .redacted { chip("REDACTED", .warn) }
        if (ref.kind == .file || ref.kind == .diff), let key = ref.itemKey,
           let lease = try? store.lease(companyId: companyId, key: key), let agent = try? store.agent(id: lease.agentId), agent.companyId == companyId {
            chip("LEASED BY @\(agent.name)", .idle)
        }
        if resolved.newer != nil, let rev = ref.rev { chip("AS SHARED @\(rev.prefix(7)) · VIEW LATEST", .idle) }
        if hasHidden { chip("HIDDEN CHARACTERS", .warn) }
        chips.append(contentsOf: extra)
        return RefHeader(title: title, subtitle: subtitle, chips: chips, actions: actions ?? defaultActions(for: resolved))
    }

    /// Copy ref, Share to… and Ask to explain always; Save As… for what exports; Open in chat for messages; Vouch for tainted
    /// items and files; Purge for pinned bytes (owner only: no agent tool reaches `purge` or `viewOriginal`).
    static func defaultActions(for resolved: ResolvedRef) -> [RefAction] {
        var out: [RefAction] = [.copyRef, .shareTo, .askToExplain]
        let kind = resolved.ref.kind
        if [.file, .diff, .commit, .item, .ask, .kb, .memory, .run, .message, .artifact, .resource].contains(kind) { out.append(.saveAs) }
        if kind == .message || kind == .thread { out.append(.openInChat) }
        if resolved.tainted, [.item, .file, .diff, .resource].contains(kind) { out.append(.vouch) }
        if [.file, .diff, .commit, .resource, .artifact].contains(kind) { out.append(.purge) }
        return out
    }

    // MARK: Answers

    /// A `show` answer's body (design §2.4): the note gated as one final string (a stored value withholds it whole), its claims
    /// through `CitationCheck` (uncited sentences listed with no citation), UNVERIFIED when the citations don't hold, and the
    /// answerer named: the concierge's answers are the concierge's, never engine text (C4c, Ruling 60).
    public static func answerBody(message: Message, refs: [WorkRef], by: String, knownValues: [(name: String, value: String)],
                                  title: String? = nil) -> RefBody {
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        var note = redacted(message.text, knownValues: knownValues)
        if gate.holdsSecret(note) { note = ShowLimits.withheldNote }
        let citation = CitationCheck.verify(note: note, refCount: refs.count)
        let verified = message.answerVerified ?? citation.verified
        let claims = citation.claims + citation.uncited.map { Claim(text: $0, cites: []) }
        let concierge = message.senderId == ConciergeCaps.agentId || by == "Brahma"
        let who = concierge ? "Brahma (concierge)" : by
        var chips: [RefChip] = []
        if !verified { chips.append(RefChip(text: "UNVERIFIED", tone: .warn)) }
        if message.taintedOrigin || message.fromTaintedSession {
            chips.append(RefChip(text: gate.final("TAINTED · \(message.taintSource ?? "outside content")", max: SafeTitle.max) ?? "TAINTED", tone: .warn))
        }
        if message.flag == OwnerImpersonation.flag || OwnerImpersonation.flags(text: note, sender: .agent(message.senderId)) {
            chips.append(RefChip(text: "CLAIMS TO BE THE OWNER · UNVERIFIED", tone: .warn))
        }
        let shownTitle = title.flatMap { gate.final($0, max: SafeTitle.max) } ?? "answered"
        let header = RefHeader(title: shownTitle, subtitle: gate.final("from \(who)", max: SafeTitle.max) ?? "answer", chips: chips,
                               actions: [.copyRef, .shareTo, .askToExplain, .openInChat])
        return RefBody(header: header, content: .answer(note: note, claims: claims, refs: refs, verified: verified, by: who))
    }

    // MARK: Agent now

    static func agentNow(_ resolved: ResolvedRef, store: Store, companyId: String, ctx: RefRenderContext, gate: GlobalSearch.TextGate) throws -> AgentNowModel {
        guard let agent = try store.agents(companyId: companyId).first(where: { $0.name == resolved.ref.id }) else {
            throw WorkError.notFound(Store.refUnavailable)
        }
        let key = try store.leasedItemKey(companyId: companyId, agentId: agent.id)
        var liveDiff: DiffModel?
        if let key, let snapshot = try? store.changesSnapshot(companyId: companyId, key: key, compare: .main, reader: .owner,
                                                               knownValues: ctx.knownValues, now: ctx.now) {
            liveDiff = DiffModel.parse(patch: redacted(snapshot.patch, knownValues: ctx.knownValues))
        }
        let turn = try store.lastTurn(agentId: agent.id)
        var stream: (turnId: String?, running: Bool, lines: [TurnStreamLine]) = (nil, false, [])
        if let turn {
            let events = try store.turnEvents(agentId: agent.id, turnId: turn.id, kinds: TurnStream.kinds, limit: TurnStream.maxLines)
            stream = (turn.id, turn.outcome == .inProgress && turn.endedAt == nil,
                      TurnStream.lines(events: events, agentId: agent.id, turnId: turn.id, timeZone: ctx.timeZone).map { line in
                          var l = line
                          l.text = gate.final(line.text, max: 400) ?? "(withheld)"
                          return l
                      })
        }
        let activity = try store.agentActivity(companyId: companyId, agentId: agent.id, limit: AgentNowModel.activityLines)
            .map { gate.final(ActivityText.line($0, handles: ctx.handles), max: 400) ?? "(withheld)" }
        let share = try store.agentUsageShareToday(agentId: agent.id, now: ctx.now)
        let requests = try store.showRequestsAwaitingTurn(agentId: agent.id).map { gate.final($0.query, max: ShowResolver.maxQuery) ?? "(withheld)" }
        let taint = turn.flatMap { $0.taintedAt != nil ? $0.taintSource : nil } ?? (agent.state == .running ? turn?.taintSource : nil)
        return AgentNowModel(handle: "@\(agent.name)", role: gate.final(agent.role, max: SafeTitle.max) ?? "", state: AgentBadge.label(agent),
                             item: key, liveDiff: liveDiff, stream: stream, activity: activity,
                             usageShare: AgentNowModel.usageText(share: share), openRequests: requests,
                             taintedBy: AgentNowModel.taintText(source: taint).flatMap { gate.final($0, max: SafeTitle.max) })
    }

    // MARK: Text

    /// Every secret pattern and every form of every stored value replaced (`ContentScan.redact`): what is shown never holds one.
    static func redacted(_ text: String, knownValues: [(name: String, value: String)]) -> String {
        String(decoding: RedactedCopy.make(Data(text.utf8), findings: [], knownValues: knownValues), as: UTF8.self)
    }

    /// Text cut at `maxTextBytes` (whole scalars).
    static func cut(_ text: String) -> String {
        guard text.utf8.count > maxTextBytes else { return text }
        return String(decoding: Data(text.utf8.prefix(maxTextBytes)), as: UTF8.self) + "\u{2026}"
    }

    /// Lines over `maxLineBytes` cut with `…` (design §4.6).
    static func cutLines(_ text: String) -> String {
        guard text.utf8.count > maxLineBytes else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.utf8.count > maxLineBytes else { return String(line) }
            return String(decoding: Data(line.utf8.prefix(maxLineBytes)), as: UTF8.self) + "\u{2026}"
        }.joined(separator: "\n")
    }
}

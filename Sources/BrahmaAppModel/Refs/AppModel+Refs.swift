import Foundation
import BrahmaCore

/// Plan C Task C6: the owner's preview navigation, the chat inspector, the Show bar's asks and auto-opened answers, and the
/// owner's Collab actions (share, quote, reply, file asks, drops, vouch, purge, export, view original). Writes go through the
/// Store as the owner, off the main actor, then `tick(forceSnapshot: true)`; errors land in `errorMessage`.
extension AppModel {
    // MARK: Context

    /// The stored secret values of `companyId`, from the injected vault. A vault that can't be read throws: every render and
    /// search refuses (Ruling 53); nothing is shown ungated.
    nonisolated func loadKnownValues(store: Store, companyId: String) throws -> [(name: String, value: String)] {
        try store.knownSecretValues(companyId: companyId, vault: secretVault)
    }

    /// What a render needs (`RefBodies`, `AttachmentCards`), with the values loaded now.
    func renderContext(companyId: String) async throws -> RefRenderContext {
        let store = self.store, paths = self.paths, vault = self.secretVault
        let known = try await Task.detached { try store.knownSecretValues(companyId: companyId, vault: vault) }.value
        let tmp = try paths.ensureTmpDir().appending(path: "preview", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return RefRenderContext(companyId: companyId, knownValues: known, paths: paths, archives: refArchives(store, paths, companyId),
                                timeZone: ownerTimeZone, tempRoot: tmp, handles: handles, now: clock())
    }

    /// Builds a chat message's cards off-main: its `messageRef` rows resolved for the owner, each an `AttachmentCard` (locked ones a
    /// kind chip alone). The stored values are loaded per call; a vault that can't be read shows no cards (fail closed).
    func makeCardMaker(companyId: String) -> @Sendable (Message) throws -> [AttachmentCard] {
        let store = self.store, paths = self.paths, vault = self.secretVault, archives: @Sendable (Store, BrahmaPaths, String) -> any ArchiveReader = refArchives, tz = ownerTimeZone, handles = self.handles
        return { message in
            let rows = try store.messageRefs(companyId: companyId, messageId: message.id)
            guard !rows.isEmpty else { return [] }
            let known = try store.knownSecretValues(companyId: companyId, vault: vault)
            let tmp = try paths.ensureTmpDir().appending(path: "cards", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let ctx = RefRenderContext(companyId: companyId, knownValues: known, paths: paths, archives: archives(store, paths, companyId), timeZone: tz,
                                       tempRoot: tmp, handles: handles, now: Store.now())
            return try rows.compactMap(\.workRef).map { ref in
                try AttachmentCards.make(try store.resolveRef(ref, for: .owner, companyId: companyId), store: store, context: ctx)
            }
        }
    }

    // MARK: Opened slot

    /// Opens `ref` in the OPENED slot (`origin`), selects the tab unless told otherwise, and loads its body (a `refRead(via: tab)`
    /// row). The title is the engine's, gated as a final string before it is kept.
    public func openRef(_ ref: WorkRef, origin: OpenOrigin, steps: [WorkRef]? = nil, stepIndex: Int? = nil, select: Bool = true) async {
        guard let companyId = selectedCompanyId else { return }
        let store = self.store, vault = self.secretVault
        let known: [(name: String, value: String)]
        do {
            known = try await Task.detached { try store.knownSecretValues(companyId: companyId, vault: vault) }.value
        } catch {
            errorMessage = "Couldn't open \(ref.kind.rawValue): the stored secrets can't be read, so nothing is shown."
            return
        }
        let resolved = try? await Task.detached { try store.resolveRef(ref, for: .owner, companyId: companyId) }.value
        guard companyId == selectedCompanyId else { return }
        let gate = GlobalSearch.TextGate(knownValues: known)
        let title = resolved.flatMap { gate.final($0.title, max: SafeTitle.max) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? gate.final(ref.canonical, max: SafeTitle.max) ?? ref.kind.rawValue
        let opened = OpenedRef(ref: ref, title: title, kindChip: OpenedRef.kindChip(for: ref), origin: origin, steps: steps, stepIndex: stepIndex)
        previewNav.open(opened, select: select)
        if select {
            selectPreviewTab(PreviewTabID.ref)
            autoOpenBadge = 0
        }
        saveNav()
        await loadOpenedBody()
    }

    /// Opens `refs` as the steps of one answer (⌥Enter on several top candidates).
    public func openSteps(_ refs: [WorkRef]) async {
        guard let first = refs.first else { return }
        await openRef(first, origin: .owner, steps: refs.count > 1 ? refs : nil, stepIndex: refs.count > 1 ? 0 : nil)
    }

    public func step(to i: Int) async {
        previewNav.step(to: i)
        saveNav()
        await loadOpenedBody()
    }

    public func goBack() async {
        guard previewNav.goBack() else { return }
        selectPreviewTab(PreviewTabID.ref)
        saveNav()
        await loadOpenedBody()
    }

    public func goForward() async {
        guard previewNav.goForward() else { return }
        selectPreviewTab(PreviewTabID.ref)
        saveNav()
        await loadOpenedBody()
    }

    /// Closes the OPENED tab (history keeps the ref for Back).
    public func closeOpened() {
        previewNav.close()
        openedBody = nil
        if selectedPreviewTab == PreviewTabID.ref { selectPreviewTab(nil) }
        saveNav()
    }

    /// The owner looked at the OPENED tab: the background badge clears.
    public func sawOpened() { autoOpenBadge = 0 }

    func saveNav() {
        guard let companyId = selectedCompanyId else { return }
        previewNav.selection = selectedPreviewTab == PreviewTabID.ref ? PreviewTabID.ref : ""
        PreviewNavStore.save(previewNav, companyId: companyId, defaults: navDefaults)
    }

    /// Loads the per-company navigation when the selection changes, and the opened body with it.
    func loadPreviewNav(companyId: String) {
        previewNav = PreviewNavStore.load(companyId: companyId, defaults: navDefaults)
        openedBody = nil
        chatInspector = nil
        inspectorBody = nil
        waitingChips = []
        autoOpenBadge = 0
        ownerRequestUsage = nil
        if previewNav.selection == PreviewTabID.ref, previewNav.opened != nil { selectedPreviewTab = PreviewTabID.ref }
        wireShowBar(companyId: companyId)
        if previewNav.opened != nil { Task { await loadOpenedBody() } }
    }

    /// Renders the opened ref off-main; a body for a ref the owner has since left is dropped.
    func loadOpenedBody() async {
        guard let opened = previewNav.opened, let companyId = selectedCompanyId else {
            openedBody = nil
            return
        }
        openGeneration += 1
        let gen = openGeneration
        let body = await renderBody(for: opened, companyId: companyId, via: Store.tabReadVia)
        guard gen == openGeneration, previewNav.opened == opened, companyId == selectedCompanyId else { return }
        openedBody = body
    }

    /// The body of `opened` for the owner: the ref's (`RefBodies`), or, for an answer message opened from its card, the answer
    /// card (`RefBodies.answerBody`). A `show` answer's steps carry an `ANSWERED BY` chip and `UNVERIFIED` when its citations
    /// don't hold. A refusal shows the engine's words, never a value.
    func renderBody(for opened: OpenedRef, companyId: String, via: String?) async -> RefBody {
        let store = self.store
        let ctx: RefRenderContext
        do { ctx = try await renderContext(companyId: companyId) } catch {
            return RefBody(header: RefHeader(title: opened.title, subtitle: "", chips: [], actions: []),
                           content: .unavailable("REFUSED · the stored secrets can't be read"))
        }
        let gate = GlobalSearch.TextGate(knownValues: ctx.knownValues)
        do {
            if case .showAnswer(let requestId, let by) = opened.origin {
                let request = try? await Task.detached { try store.showRequest(companyId: companyId, id: requestId) }.value
                let answer: Message? = try? await Task.detached { () -> Message? in
                    guard let id = request?.answerMessageId else { return nil }
                    return try store.message(companyId: companyId, id: id)
                }.value
                if opened.ref.kind == .message, let answer, answer.id == opened.ref.id {
                    let refs = try await Task.detached { try store.messageRefs(companyId: companyId, messageId: answer.id).compactMap(\.workRef) }.value
                    let title = try? await Task.detached { try store.showAnswerTitle(companyId: companyId, messageId: answer.id, gate: gate) }.value
                    try? await Task.detached { try store.recordOwnerRead(companyId: companyId, ref: opened.ref, via: via ?? Store.tabReadVia,
                                                                         tainted: answer.taintedOrigin || answer.fromTaintedSession) }.value
                    return RefBodies.answerBody(message: answer, refs: refs, by: by, knownValues: ctx.knownValues, title: title ?? nil)
                }
                let resolved = try await Task.detached { try store.resolveRef(opened.ref, for: .owner, companyId: companyId) }.value
                var body = try await RefBodies.body(for: resolved, store: store, companyId: companyId, context: ctx, via: via)
                let who = answer?.senderId == ConciergeCaps.agentId ? "Brahma (concierge)" : by
                if let chip = gate.final("ANSWERED BY \(who)", max: SafeTitle.max) { body.header.chips.append(RefChip(text: chip, tone: .idle)) }
                if answer?.answerVerified == false { body.header.chips.append(RefChip(text: "UNVERIFIED", tone: .warn)) }
                return body
            }
            let resolved = try await Task.detached { try store.resolveRef(opened.ref, for: .owner, companyId: companyId) }.value
            return try await RefBodies.body(for: resolved, store: store, companyId: companyId, context: ctx, via: via)
        } catch let e as WorkError {
            return RefBody(header: RefHeader(title: opened.title, subtitle: "", chips: [], actions: []),
                           content: .unavailable(gate.final(e.message, max: 400) ?? RefBodies.unavailableText))
        } catch {
            return RefBody(header: RefHeader(title: opened.title, subtitle: "", chips: [], actions: []), content: .unavailable(RefBodies.unavailableText))
        }
    }

    // MARK: Chat inspector

    /// Opens a card's ref in chat's right-side inspector split, without leaving the thread (a `refRead(via: inspector)` row).
    public func openInInspector(_ ref: WorkRef, messageId: String) async {
        guard let companyId = selectedCompanyId else { return }
        let store = self.store, vault = self.secretVault
        guard let known = try? await Task.detached { try store.knownSecretValues(companyId: companyId, vault: vault) }.value else {
            errorMessage = "Couldn't open \(ref.kind.rawValue): the stored secrets can't be read, so nothing is shown."
            return
        }
        let resolved = try? await Task.detached { try store.resolveRef(ref, for: .owner, companyId: companyId) }.value
        let gate = GlobalSearch.TextGate(knownValues: known)
        let title = resolved.flatMap { gate.final($0.title, max: SafeTitle.max) }.flatMap { $0.isEmpty ? nil : $0 }
            ?? gate.final(ref.canonical, max: SafeTitle.max) ?? ref.kind.rawValue
        let opened = OpenedRef(ref: ref, title: title, kindChip: OpenedRef.kindChip(for: ref), origin: .card(messageId: messageId))
        chatInspector = opened
        inspectorBody = nil
        let body = await renderBody(for: opened, companyId: companyId, via: Store.inspectorReadVia)
        guard chatInspector == opened else { return }
        inspectorBody = body
    }

    public func closeInspector() {
        chatInspector = nil
        inspectorBody = nil
    }

    /// "Open in preview": the inspector's ref moves to the OPENED slot.
    public func moveInspectorToPreview() async {
        guard let r = chatInspector else { return }
        closeInspector()
        select(.missionControl)
        await openRef(r.ref, origin: r.origin)
    }

    // MARK: Show bar

    /// Wires the bar to the selected company's engine (the stored values come from the injected vault on every call).
    func wireShowBar(companyId: String) {
        let store = self.store, vault = self.secretVault
        showBar.backend = .live(store: store, companyId: companyId, files: showFiles, commits: showCommits,
                                knownValues: { try store.knownSecretValues(companyId: companyId, vault: vault) })
        showBar.close()
        Task { await showBar.update(query: "") }
    }

    /// Opens the bar (`.bar` atop the preview, `.overlay` for ⌘K); "Ask to explain" passes `.explain` and the ref.
    public func openShow(presentation: ShowPresentation, kind: ShowKind = .show, attachedRef: WorkRef? = nil) {
        showBar.open(presentation: presentation, kind: kind, attachedRef: attachedRef)
    }

    /// Applies what a key produced: opens a hit, opens steps, submits an ask, opens the search view, or closes.
    public func perform(_ action: ShowAction) async {
        switch action {
        case .open(let opened):
            showBar.close()
            if chatInspector != nil || (sidebarSelection != .missionControl && showBar.presentation == .overlay) {
                await openInInspector(opened.ref, messageId: "")
            } else {
                await openRef(opened.ref, origin: opened.origin)
            }
        case .openSteps(let refs):
            showBar.close()
            await openSteps(refs)
        case .ask(let draft):
            await submitAsk(draft)
        case .seeAll(let q):
            showBar.close()
            search.query = q
            await runSearch()
        case .close, .none:
            break
        }
    }

    /// The owner's Enter on the ASK row: one show request to the routed target with the candidates filtered for it
    /// (`ShowCandidates.lines`), then a waiting chip. Nothing is sent before this.
    public func submitAsk(_ draft: ShowAskDraft) async {
        guard let companyId = selectedCompanyId else { return }
        let store = self.store, vault = self.secretVault, result = showBar.result, now = clock()
        let reader: Reader
        switch draft.target.target {
        case .concierge: reader = .concierge
        case .agent(let id): reader = .agent(id)
        }
        let created: ShowRequest? = await ownerWrite("ask") { store in
            let known = try store.knownSecretValues(companyId: companyId, vault: vault)
            let gate = GlobalSearch.TextGate(knownValues: known)
            let candidates = try result.map { try ShowCandidates.lines(result: $0, for: reader, store: store, companyId: companyId, gate: gate).lines } ?? []
            return try store.createShowRequest(companyId: companyId, kind: draft.kind, query: draft.query,
                                               attachedRef: draft.attachedRef?.canonical, routed: draft.target, candidates: candidates, now: now)
        }
        guard created != nil else { return }
        showBar.close()
        await refreshCollab()
    }

    /// The owner cancels an open request from its waiting chip.
    public func cancelShowRequest(_ id: String) async {
        guard let companyId = selectedCompanyId else { return }
        let now = clock()
        _ = await ownerWrite("cancel the request") { store in try store.cancelShowRequest(companyId: companyId, id: id, now: now) }
        waitingChips.removeAll { $0.requestId == id }
        await refreshCollab()
    }

    /// Per tick: the waiting chips, the Budget line and the auto-opens (`ShowAnswerRouter`).
    public func refreshCollab() async {
        guard let companyId = selectedCompanyId else { return }
        let store = self.store, vault = self.secretVault, now = clock(), tz = ownerTimeZone
        let usage = snapshot.usage, mode = selectedCompany?.company.usageMode ?? .balanced
        do {
            let (chips, usageLine) = try await Task.detached { () -> ([WaitingChip], OwnerRequestUsage) in
                let known = try store.knownSecretValues(companyId: companyId, vault: vault)
                let gate = GlobalSearch.TextGate(knownValues: known)
                var chips: [WaitingChip] = []
                for r in try store.openShowRequests(companyId: companyId) {
                    let query = gate.final(r.query, max: 80) ?? "(withheld)"
                    switch r.showTarget {
                    case .concierge:
                        chips.append(WaitingChip(text: "Brahma is answering: \(query)", requestId: r.id))
                    case .agent(let id):
                        guard let agent = try store.agent(id: id) else { continue }
                        let turn = try store.lastTurn(agentId: id)
                        let running = turn.flatMap { $0.outcome == .inProgress && $0.endedAt == nil ? $0 : nil }
                        let eta = ShowETA.text(agent: agent, running: running, recentDurations: try store.recentTurnDurations(agentId: id),
                                               gate: UsageGate.evaluate(usage, mode: mode, now: now), now: now, tz: tz)
                        chips.append(WaitingChip(text: "@\(agent.name) · \(eta): \(query)", requestId: r.id))
                    }
                }
                return (chips, try store.ownerRequestUsage(companyId: companyId, now: now))
            }.value
            guard companyId == selectedCompanyId else { return }
            waitingChips = chips
            ownerRequestUsage = usageLine
        } catch {
            report(error)
            return
        }
        await pollAutoOpens()
    }

    /// Answered requests not yet opened: each is opened per `ShowAnswerRouter.decide` (selected only while its chip still shows,
    /// never taking focus), then marked opened. Unsolicited answers are cards only and never reach here.
    public func pollAutoOpens() async {
        guard let companyId = selectedCompanyId else { return }
        let store = self.store, vault = self.secretVault, now = clock()
        let autos = (try? await Task.detached { try store.pendingAutoOpens(companyId: companyId) }.value) ?? []
        for auto in autos {
            guard companyId == selectedCompanyId else { return }
            let visible = waitingChips.contains { $0.requestId == auto.requestId }
            let decision = ShowAnswerRouter.decide(auto: auto, waitingChipVisible: visible)
            let title = (try? await Task.detached { () -> String? in
                let known = try store.knownSecretValues(companyId: companyId, vault: vault)
                return try store.showAnswerTitle(companyId: companyId, messageId: auto.answerMessageId, gate: GlobalSearch.TextGate(knownValues: known))
            }.value) ?? nil
            await applyAutoOpen(auto, decision: decision, title: title ?? "answered")
            _ = try? await Task.detached { try store.markAutoOpened(companyId: companyId, id: auto.requestId, now: now) }.value
            waitingChips.removeAll { $0.requestId == auto.requestId }
        }
    }

    /// Opens an answer per `decision`: in the slot and selected, or in the background with a badge and a notification through
    /// 5-lite's batching (`notifyOwner`); `.cardOnly` changes nothing.
    public func applyAutoOpen(_ auto: AutoOpen, decision: AutoOpenDecision, title: String) async {
        guard let first = auto.refs.first, let companyId = selectedCompanyId else { return }
        let steps = auto.refs.count > 1 ? auto.refs : nil
        let opened = OpenedRef(ref: first, title: title, kindChip: OpenedRef.kindChip(for: first),
                               origin: .showAnswer(requestId: auto.requestId, by: auto.by), steps: steps, stepIndex: steps == nil ? nil : 0)
        switch decision {
        case .cardOnly:
            return
        case .openAndSelect:
            previewNav.open(opened, select: true)
            selectPreviewTab(PreviewTabID.ref)
            autoOpenBadge = 0
        case .openInBackground:
            previewNav.open(opened, select: false)
            autoOpenBadge += 1
            let store = self.store, now = clock()
            let by = auto.by
            _ = try? await Task.detached {
                try store.notifyOwner(companyId: companyId, title: "\(by) answered", body: title, now: now)
            }.value
        }
        saveNav()
        await loadOpenedBody()
    }

    /// `"OWNER REQUESTS · 2.1% 5H · 0.4% 7D"` (Budget, one line; design §2.4).
    public var ownerRequestsBudgetLine: String {
        let (five, week) = ownerRequestUsage.map { ($0.share5h, $0.share7d) } ?? (0, 0)
        return "OWNER REQUESTS · \(String(format: "%.1f", five))% 5H · \(String(format: "%.1f", week))% 7D"
    }

    // MARK: Deep links

    /// `ref:<companyId>/<canonical>`: selects the company and opens the ref, view-only (nothing is asked, shared, granted or spent).
    func applyRef(companyId: String, canonical: String) async {
        guard snapshot.companies.contains(where: { $0.id == companyId }) else {
            errorMessage = "No company \(companyId.prefix(40))"
            return
        }
        if companyId != selectedCompanyId { await selectCompany(companyId) }
        guard companyId == selectedCompanyId else { return }
        let slug = selectedCompany?.company.slug ?? ""
        let prefixes: Set<String> = [Store.keyPrefix(slug: slug)]
        let context = RefContext(companyId: companyId, keyPrefixes: prefixes, allowInternal: true)
        guard let ref = WorkRef.parse(canonical, context: context) else {
            errorMessage = "Not a ref: \(canonical.prefix(80))"
            return
        }
        select(.missionControl)
        await openRef(ref, origin: .owner)
    }

    // MARK: Owner actions

    /// The owner shares `refs` with `to` (`@handle`, `#channel`) with a note (`Store.ownerShare`).
    @discardableResult
    public func share(refs: [WorkRef], to: String, note: String?, replyTo: String? = nil) async -> Bool {
        guard let companyId = selectedCompanyId else { return false }
        let paths = self.paths, vault = self.secretVault, archives: @Sendable (Store, BrahmaPaths, String) -> any ArchiveReader = refArchives, now = clock()
        return await ownerWrite("share") { store in
            let known = try store.knownSecretValues(companyId: companyId, vault: vault)
            _ = try store.ownerShare(companyId: companyId, refs: refs.map(\.canonical), to: to, note: note, replyTo: replyTo, knownValues: known,
                                     paths: paths, now: now, archives: archives(store, paths, companyId))
            return true
        } ?? false
    }

    /// Quotes a message into a conversation: a share of `msg:<id>` (readers of the source see its text; others a locked chip).
    @discardableResult
    public func quote(messageId: String, to: String) async -> Bool {
        await share(refs: [WorkRef(kind: .message, id: messageId)], to: to, note: nil)
    }

    /// Replies in the thread of `rootId` as the owner. Returns the router's refusal when the reply carried `@here`/`@team`
    /// (a thread reply never broadcasts), for the composer to show.
    public func reply(inThread rootId: String, text: String) async -> String? {
        guard let companyId = selectedCompanyId else { return nil }
        let now = clock()
        let result: PostResult? = await ownerWrite("reply") { store in
            do { return try store.ownerThreadReply(companyId: companyId, rootId: rootId, text: text, now: now) }
            catch let e as ThreadError { throw WorkError.notFound(e.message) }
            catch let e as RouterError { throw WorkError.invalid("\(e)") }
        }
        return result?.broadcastRefusal
    }

    /// Asks `handle` for a file (a `fileAsk` DM that wakes the agent), optionally for an item.
    @discardableResult
    public func sendFileAsk(to handle: String, description: String, item: String?) async -> Bool {
        guard let companyId = selectedCompanyId else { return false }
        let now = clock()
        return await ownerWrite("ask for a file") { store in
            _ = try store.sendFileAsk(companyId: companyId, toHandle: handle, description: description, itemKey: item, now: now)
            return true
        } ?? false
    }

    /// Answers an agent's file request with `files` (ML's drop pipeline in `.inbox(askId:)`, committed through `Store.ownerDrop`).
    @discardableResult
    public func answerFileRequest(askId: String, files: [URL]) async -> Bool {
        await drop(files, on: .inbox(askId: askId))
    }

    /// Drops `urls` in `context`: ML's `ResourceDropModel` inspects them and commits them as one message through `Store.ownerDrop`.
    @discardableResult
    public func drop(_ urls: [URL], on context: DropContext) async -> Bool {
        let model = ResourceDropModel(app: self, context: context, defaults: dropDefaults)
        await model.add(urls: urls)
        guard !model.pending.isEmpty else { return false }
        return await model.commit(message: "")
    }

    /// The owner vouches for `ref`: a resource through ML's `vouch(resource:)`; an item, or a file or diff on its branch, clears its
    /// tainted commits (`vouchItem`).
    public func vouch(_ ref: WorkRef) async {
        guard let companyId = selectedCompanyId else { return }
        switch ref.kind {
        case .resource:
            await vouch(resource: "F-\(ref.id)")
        case .item, .file, .diff:
            let key = ref.kind == .item ? ref.id : (ref.itemKey ?? "")
            guard !key.isEmpty else { errorMessage = "Nothing to vouch for: \(ref.canonical.prefix(80)) is not an item's work."; return }
            let now = clock()
            await ownerWrite("vouch for \(key)") { store in
                guard let item = try store.workItem(companyId: companyId, key: key) else { throw WorkError.notFound("no work item \(key)") }
                try store.vouchItem(itemId: item.id, now: now)
            }
        default:
            errorMessage = "Nothing to vouch for: \(ref.kind.rawValue) refs carry no taint of their own."
        }
    }

    /// The owner purges `ref` for good: a resource through ML's `purge(resource:)` (its confirmation set here: the header's alert
    /// confirmed), anything else through C2b's `Store.purge`. The opened slot closes when it showed the purged ref.
    @discardableResult
    public func purge(_ ref: WorkRef) async -> RefPurgeReport? {
        guard let companyId = selectedCompanyId else { return nil }
        if ref.kind == .resource {
            confirmPurge = "F-\(ref.id)"
            _ = await purge(resource: "F-\(ref.id)")
            if previewNav.opened?.ref == ref { closeOpened() }
            return nil
        }
        let paths = self.paths, vault = self.secretVault, now = clock()
        let report: RefPurgeReport? = await ownerWrite("purge \(ref.canonical.prefix(60))") { store in
            let known = try store.knownSecretValues(companyId: companyId, vault: vault)
            return try store.purge(companyId: companyId, ref: ref, contentVault: ContentVault(paths: paths), paths: paths, knownValues: known, now: now)
        }
        if previewNav.opened?.ref == ref { closeOpened() }
        return report
    }

    /// Save As…: writes what `ref` holds to `url` (the owner's save panel; `Store.exportRef`: gated, quarantined, recorded).
    @discardableResult
    public func export(_ ref: WorkRef, to url: URL) async -> URL? {
        guard let companyId = selectedCompanyId else { return nil }
        let paths = self.paths, vault = self.secretVault, archives: @Sendable (Store, BrahmaPaths, String) -> any ArchiveReader = refArchives, now = clock()
        return await ownerWrite("save \(ref.canonical.prefix(60))") { store in
            let known = try store.knownSecretValues(companyId: companyId, vault: vault)
            return try store.exportRef(companyId: companyId, ref: ref, to: url, knownValues: known, paths: paths,
                                       archives: archives(store, paths, companyId), now: now)
        }
    }

    /// View original (owner only): the bytes of `ref` as they are, through `gatedBytes` (a vouched PDF is its flattened copy).
    public func viewOriginal(_ ref: WorkRef) async -> Data? {
        guard let companyId = selectedCompanyId else { return nil }
        let paths = self.paths, vault = self.secretVault, archives: @Sendable (Store, BrahmaPaths, String) -> any ArchiveReader = refArchives, now = clock()
        return await ownerWrite("view the original of \(ref.canonical.prefix(60))") { store in
            let known = try store.knownSecretValues(companyId: companyId, vault: vault)
            return try store.viewOriginal(companyId: companyId, ref: ref, knownValues: known, paths: paths, now: now,
                                          archives: archives(store, paths, companyId))
        }
    }

    /// The text Copy ref puts on the pasteboard: the canonical ref (an empty string when it holds a stored value).
    public func copyRef(_ ref: WorkRef) -> String {
        guard let companyId = selectedCompanyId, let known = try? store.knownSecretValues(companyId: companyId, vault: secretVault) else { return "" }
        return GlobalSearch.TextGate(knownValues: known).final(ref.canonical, max: 1024) ?? ""
    }
}

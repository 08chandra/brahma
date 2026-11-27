import Foundation
import Observation
import BrahmaCore

/// One row of the Show dropdown: a group header, the fact answer, a hit, "See all <n> message results", or the ASK row (always last).
public enum ShowRow: Equatable, Sendable {
    case header(String)
    case answer(FactAnswer)
    case hit(ShowHit)
    case seeAll(Int)
    case ask(text: String)
}

public enum ShowKey: Equatable, Sendable {
    case up, down, enter, cmdEnter, optEnter, escape, tab
}

/// What the owner asks for from the ASK row: the query as typed, show or explain, the routed target and an attached ref.
public struct ShowAskDraft: Equatable, Sendable {
    public var query: String
    public var kind: ShowKind
    public var target: RoutedTarget
    public var attachedRef: WorkRef?

    public init(query: String, kind: ShowKind, target: RoutedTarget, attachedRef: WorkRef?) {
        self.query = query; self.kind = kind; self.target = target; self.attachedRef = attachedRef
    }
}

public enum ShowAction: Equatable, Sendable {
    case open(OpenedRef)
    case openSteps([WorkRef])
    case ask(ShowAskDraft)
    case seeAll(String)
    case close
    case none
}

/// The bar atop the preview, or the ⌘K overlay palette (collab design §2.1).
public enum ShowPresentation: Equatable, Sendable {
    case bar, overlay
}

/// What the bar needs from the engine, as closures so tests can hold or can a result: the resolver (every call passes the
/// stored values loaded from the injected vault and refuses when they can't be read), the routed targets (the default first,
/// then the Tab cycle), the ASK row's text for a target (its cost estimate), and the miss log.
public struct ShowBarBackend: Sendable {
    public var resolve: @Sendable (String) async throws -> ShowResult
    public var targets: @Sendable (ShowResult, ShowKind, String?, WorkRef?) async throws -> [RoutedTarget]
    public var askLine: @Sendable (RoutedTarget) async -> String
    public var logMiss: @Sendable (String, Double) async -> Void

    public init(resolve: @escaping @Sendable (String) async throws -> ShowResult,
                targets: @escaping @Sendable (ShowResult, ShowKind, String?, WorkRef?) async throws -> [RoutedTarget],
                askLine: @escaping @Sendable (RoutedTarget) async -> String,
                logMiss: @escaping @Sendable (String, Double) async -> Void) {
        self.resolve = resolve; self.targets = targets; self.askLine = askLine; self.logMiss = logMiss
    }

    public static let concierge = RoutedTarget(target: .concierge, reason: ShowRouting.conciergeReason, busy: false)

    /// Before a company is selected: no results, Brahma at its default cost.
    public static let empty = ShowBarBackend(
        resolve: { q in ShowResult(normalized: q, stripped: q, filters: SearchFilters(), answer: nil, hits: [], topScore: 0, intent: .request, groupTotals: [:]) },
        targets: { _, _, _, _ in [concierge] },
        askLine: { ShowBarModel.askLine($0, handle: "", cost: nil) },
        logMiss: { _, _ in })

    /// The engine over `store` for the owner: `ShowResolver`, `ShowRouting`, `ShowCost` and `Store.logShowMiss`. `knownValues`
    /// loads the company's stored values from the injected vault; a loader that throws refuses the search (Ruling 53).
    public static func live(store: Store, companyId: String, files: FileIndexCache, commits: CommitIndexCache,
                            knownValues: @escaping @Sendable () throws -> [(name: String, value: String)]) -> ShowBarBackend {
        ShowBarBackend(
            resolve: { query in
                let known = try knownValues()
                return try await ShowResolver(store: store, files: files, commits: commits).resolve(query, companyId: companyId, reader: .owner,
                                                                                                   knownValues: known)
            },
            targets: { result, kind, explicit, attached in
                try await Task.detached {
                    var out: [RoutedTarget] = []
                    do {
                        out.append(try ShowRouting.target(result: result, kind: kind, explicitHandle: explicit, attachedRef: attached, store: store,
                                                          companyId: companyId))
                    } catch let e as WorkError where explicit != nil {
                        // The owner named someone who isn't available: the error is the ASK row's text; Brahma answers.
                        out.append(RoutedTarget(target: .concierge, reason: e.message, busy: false))
                    }
                    for t in try ShowRouting.alternatives(result: result, kind: kind, attachedRef: attached, store: store, companyId: companyId)
                    where !out.contains(where: { $0.target == t.target }) {
                        out.append(t)
                    }
                    if !out.contains(where: { $0.target == .concierge }) { out.append(concierge) }
                    return out
                }.value
            },
            askLine: { target in
                let estimate = await Task.detached { (try? ShowCost.estimate(target.target, store: store, companyId: companyId)) }.value
                let handle: String
                if case .agent(let id) = target.target {
                    handle = await Task.detached { (try? store.agent(id: id))?.name }.value ?? id
                } else {
                    handle = ""
                }
                return ShowBarModel.askLine(target, handle: handle, cost: estimate)
            },
            logMiss: { query, score in
                _ = await Task.detached { try? store.logShowMiss(companyId: companyId, query: query, chosen: "ask", topScore: score, now: Store.now()) }.value
            })
    }
}

/// The search-and-ask bar's model (collab design §2): debounced resolution with a generation counter (stale results are
/// dropped), rows grouped with the ASK row last, keyboard handling, the Tab cycle over routed targets, and removable filter
/// chips. It sends nothing itself: `.ask` is a draft the app submits after the owner's Enter.
@MainActor @Observable
public final class ShowBarModel {
    public nonisolated static let debounce: Duration = .milliseconds(80)

    public var query = ""
    public private(set) var rows: [ShowRow] = []
    public var selection = 0
    public private(set) var generation = 0
    public var presentation: ShowPresentation = .bar
    public private(set) var askTarget: RoutedTarget = ShowBarBackend.concierge
    /// The Tab cycle: Brahma, then the agents the routing rules name.
    public private(set) var targets: [RoutedTarget] = [ShowBarBackend.concierge]
    public private(set) var filterChips: [String] = []
    public private(set) var result: ShowResult?
    /// The refusal shown instead of results (the stored values couldn't be read, the engine failed).
    public private(set) var error: String?
    public private(set) var isOpen = false
    /// `.explain` when opened from "Ask to explain" on a ref (`attachedRef`).
    public var kind: ShowKind = .show
    public var attachedRef: WorkRef?

    @ObservationIgnored public var backend: ShowBarBackend
    @ObservationIgnored private var askLines: [String] = []
    @ObservationIgnored private var targetIndex = 0

    public init(backend: ShowBarBackend) {
        self.backend = backend
        rows = [.ask(text: Self.askLine(ShowBarBackend.concierge, handle: "", cost: nil))]
    }

    // MARK: Open and close

    public func open(presentation: ShowPresentation, kind: ShowKind = .show, attachedRef: WorkRef? = nil) {
        self.presentation = presentation
        self.kind = kind
        self.attachedRef = attachedRef
        isOpen = true
    }

    public func close() {
        isOpen = false
        attachedRef = nil
        kind = .show
    }

    // MARK: Resolution

    /// Resolves `query` after the debounce; a result of an earlier call that lands later is dropped.
    public func update(query: String) async {
        self.query = query
        generation += 1
        let gen = generation
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            result = nil
            error = nil
            filterChips = []
            setTargets([ShowBarBackend.concierge], lines: [await backend.askLine(ShowBarBackend.concierge)])
            guard gen == generation else { return }
            rows = [.ask(text: askLines[0])]
            selection = 0
            return
        }
        try? await Task.sleep(for: Self.debounce)
        guard gen == generation else { return }
        let sent = String(trimmed.prefix(ShowResolver.maxQuery))
        do {
            let r = try await backend.resolve(sent)
            guard gen == generation else { return }
            let explicit = Self.explicitHandle(in: r.stripped)
            let ts = (try? await backend.targets(r, kind, explicit, attachedRef)) ?? [ShowBarBackend.concierge]
            guard gen == generation else { return }
            var lines: [String] = []
            for t in ts { lines.append(await backend.askLine(t)) }
            guard gen == generation else { return }
            result = r
            error = nil
            filterChips = r.filters.chips
            setTargets(ts.isEmpty ? [ShowBarBackend.concierge] : ts, lines: lines.isEmpty ? [Self.askLine(ShowBarBackend.concierge, handle: "", cost: nil)] : lines)
            rows = Self.rows(for: r, askLine: askLines[0])
            selection = Self.defaultSelection(rows, intent: r.intent)
        } catch {
            guard gen == generation else { return }
            result = nil
            filterChips = []
            self.error = Self.describe(error)
            setTargets([ShowBarBackend.concierge], lines: [await backend.askLine(ShowBarBackend.concierge)])
            guard gen == generation else { return }
            rows = [.ask(text: askLines[0])]
            selection = 0
        }
    }

    /// Removes the filter `chip` (`"BY @ENG-3"`, `"THIS WEEK"`, `"BLOCKED"`, `"KIND:COMMIT"`, `"IN #ENG"`) from the query and resolves again.
    public func removeFilterChip(_ chip: String) async {
        let lower = chip.lowercased()
        var candidates: [String] = []
        if lower.hasPrefix("by @") {
            let h = String(lower.dropFirst(4))
            candidates = ["by @\(h)", "from @\(h)", "@\(h)'s"]
        } else if lower.hasPrefix("kind:") {
            candidates = [lower]
        } else if lower.hasPrefix("in #") {
            candidates = ["in:#" + lower.dropFirst(4), "in #" + lower.dropFirst(4)]
        } else {
            candidates = [lower, "is:\(lower)"]
        }
        var q = query
        for c in candidates {
            if let range = q.range(of: c, options: [.caseInsensitive]) {
                q.removeSubrange(range)
                break
            }
        }
        let cleaned = q.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        await update(query: cleaned)
    }

    private func setTargets(_ ts: [RoutedTarget], lines: [String]) {
        targets = ts
        askLines = lines
        targetIndex = 0
        askTarget = ts[0]
    }

    // MARK: Keys

    /// Tab: Brahma, then the top agents the rules name, then Brahma again; the ASK row's text follows.
    public func cycleAskTarget() {
        guard !targets.isEmpty else { return }
        targetIndex = (targetIndex + 1) % targets.count
        askTarget = targets[targetIndex]
        if let last = rows.indices.last, case .ask = rows[last] {
            rows[last] = .ask(text: askLines.indices.contains(targetIndex) ? askLines[targetIndex] : Self.askLine(askTarget, handle: "", cost: nil))
        }
    }

    public func handle(_ key: ShowKey) -> ShowAction {
        switch key {
        case .up:
            move(-1)
            return .none
        case .down:
            move(1)
            return .none
        case .tab:
            cycleAskTarget()
            return .none
        case .escape:
            close()
            return .close
        case .cmdEnter:
            return askAction()
        case .optEnter:
            let top = (result?.hits ?? []).filter { $0.group == .top && !$0.inlineOnly }
            if top.count >= 2 { return .openSteps(top.map(\.ref)) }
            if let one = top.first { return .open(Self.opened(one)) }
            return .none
        case .enter:
            guard rows.indices.contains(selection) else { return .none }
            switch rows[selection] {
            case .header: return .none
            case .hit(let h):
                // C4a: inline-only hits (activity lines without a subject) are display-only; the app never opens them.
                return h.inlineOnly ? .none : .open(Self.opened(h))
            case .answer(let a):
                let ref = WorkRef(kind: .fact, id: a.query)
                return .open(OpenedRef(ref: ref, title: a.title, kindChip: OpenedRef.kindChip(for: ref), origin: .owner))
            case .seeAll: return .seeAll(query.trimmingCharacters(in: .whitespacesAndNewlines))
            case .ask: return askAction()
            }
        }
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        var i = selection
        while true {
            i += delta
            guard rows.indices.contains(i) else { return }
            if case .header = rows[i] { continue }
            break
        }
        selection = i
    }

    /// The draft the app submits. Choosing Ask while candidates exist logs a miss (design §2.2).
    private func askAction() -> ShowAction {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = result, !r.hits.isEmpty {
            let backend = self.backend, score = r.topScore
            Task.detached { await backend.logMiss(q, score) }
        }
        return .ask(ShowAskDraft(query: q, kind: kind, target: askTarget, attachedRef: attachedRef))
    }

    // MARK: Rows

    nonisolated static func opened(_ h: ShowHit) -> OpenedRef {
        OpenedRef(ref: h.ref, title: h.title.isEmpty ? h.ref.canonical : h.title, kindChip: OpenedRef.kindChip(for: h.ref), origin: .owner)
    }

    public nonisolated static func groupTitle(_ g: ShowGroup) -> String {
        switch g {
        case .top: "TOP HIT"
        case .answer: "ANSWER"
        case .items: "ITEMS"
        case .asks: "ASKS"
        case .files: "FILES"
        case .commits: "COMMITS"
        case .artifactsResources: "ARTIFACTS & RESOURCES"
        case .handbook: "HANDBOOK"
        case .memory: "MEMORY"
        case .messages: "MESSAGES"
        case .people: "PEOPLE"
        case .releases: "RELEASES"
        case .sprints: "SPRINTS"
        case .activity: "ACTIVITY"
        case .previews: "PREVIEWS"
        }
    }

    /// TOP HIT, ANSWER, the groups in order (≤ `ShowResolver.groupLimit` each, empty ones omitted), "See all <n> message
    /// results", then ASK. With a fact intent the ANSWER comes first.
    nonisolated static func rows(for r: ShowResult, askLine: String) -> [ShowRow] {
        var rows: [ShowRow] = []
        let top = Array(r.hits.filter { $0.group == .top }.prefix(ShowResolver.groupLimit))
        func addTop() {
            guard !top.isEmpty else { return }
            rows.append(.header(groupTitle(.top)))
            rows += top.map(ShowRow.hit)
        }
        func addAnswer() {
            guard let a = r.answer else { return }
            rows.append(.header(groupTitle(.answer)))
            rows.append(.answer(a))
        }
        if r.intent == .fact { addAnswer(); addTop() } else { addTop(); addAnswer() }
        var shownMessages = 0
        for g in ShowGroup.allCases where g != .top && g != .answer {
            let hits = Array(r.hits.filter { $0.group == g }.prefix(ShowResolver.groupLimit))
            guard !hits.isEmpty else { continue }
            if g == .messages { shownMessages = hits.count }
            rows.append(.header(groupTitle(g)))
            rows += hits.map(ShowRow.hit)
        }
        if let total = r.groupTotals[.messages], total > shownMessages { rows.append(.seeAll(total)) }
        rows.append(.ask(text: askLine))
        return rows
    }

    /// TOP HIT for a lookup, the ANSWER row for a fact, else ASK.
    nonisolated static func defaultSelection(_ rows: [ShowRow], intent: ShowIntent) -> Int {
        switch intent {
        case .fact:
            if let i = rows.firstIndex(where: { if case .answer = $0 { return true } else { return false } }) { return i }
        case .lookup:
            if let i = rows.firstIndex(where: { if case .hit = $0 { return true } else { return false } }) { return i }
        case .request:
            break
        }
        return max(0, rows.count - 1)
    }

    /// `"Ask Brahma · quick · ~0.1% of 5H"`; `"Ask @frontend-lead · <reason> · ~1% of 5H · busy: answers after its current turn"`.
    public nonisolated static func askLine(_ t: RoutedTarget, handle: String, cost: Double?) -> String {
        let pct = cost ?? (t.target == .concierge ? ShowCost.defaults.concierge : ShowCost.defaults.agent)
        let shownCost = pct == pct.rounded() ? String(Int(pct)) : String(format: "%.1f", pct)
        switch t.target {
        case .concierge:
            let reason = t.reason == ShowRouting.conciergeReason ? "quick" : t.reason
            return "Ask Brahma · \(reason) · ~\(shownCost)% of 5H"
        case .agent(let id):
            var line = "Ask @\(handle.isEmpty ? id : handle) · \(t.reason) · ~\(shownCost)% of 5H"
            if t.busy { line += " · busy: answers after its current turn" }
            return line
        }
    }

    /// A bare `@handle` token (not a `by @x`/`from @x` filter, not `@x's`) names the target.
    nonisolated static func explicitHandle(in stripped: String) -> String? {
        let tokens = stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (i, t) in tokens.enumerated() where t.hasPrefix("@") && t.count > 1 {
            if i > 0, ["by", "from"].contains(tokens[i - 1].lowercased()) { continue }
            if t.hasSuffix("'s") || t.hasSuffix("\u{2019}s") { continue }
            let handle = String(t.dropFirst()).trimmingCharacters(in: .punctuationCharacters)
            guard !handle.isEmpty, handle.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { continue }
            return handle
        }
        return nil
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let e = error as? WorkError { return e.message }
        return "Search is unavailable: the stored secrets couldn't be read (\(error))"
    }
}

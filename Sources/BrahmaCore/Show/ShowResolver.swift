import Foundation
import GRDB

/// What Enter does in the Show bar.
public enum ShowIntent: Equatable, Sendable {
    case lookup, fact, request

    public static let threshold = 0.6
    static let requestOpeners = ["why", "how", "explain", "compare"]

    /// `.fact` when a fact answered; `.request` when nothing scores at least `threshold` or the query starts with `why`, `how`,
    /// `explain`, `compare` or `walk me through`; else `.lookup`.
    public static func classify(stripped: String, topScore: Double, hasFact: Bool) -> ShowIntent {
        if hasFact { return .fact }
        let words = stripped.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if let first = words.first, requestOpeners.contains(first) { return .request }
        if words.prefix(3) == ["walk", "me", "through"] { return .request }
        return topScore >= threshold ? .lookup : .request
    }
}

/// What the Show bar shows for one query.
public struct ShowResult: Equatable, Sendable {
    public var normalized: String
    public var stripped: String
    public var filters: SearchFilters
    /// Nil until C4b.
    public var answer: FactAnswer?
    /// At most `ShowResolver.groupLimit` per group, TOP first.
    public var hits: [ShowHit]
    public var topScore: Double
    public var intent: ShowIntent
    /// The owner's full candidate counts per group; empty for every other reader (never a hidden count).
    public var groupTotals: [ShowGroup: Int]
    /// Fix round 1 (I-3): groups whose source couldn't be read in full (`.files`: no repository, an index past its cap or
    /// one that failed; `.commits`: likewise). A property of the repository, so every reader sees it; it names no object.
    public var incomplete: Set<ShowGroup>
    /// Fix round 4 (Ruling 58 (1)): static notes about what was searched (`GlobalSearch.windowNote`), the same for every
    /// reader and whether or not anything matched.
    public var notes: [String]

    public init(normalized: String, stripped: String, filters: SearchFilters, answer: FactAnswer?, hits: [ShowHit], topScore: Double,
                intent: ShowIntent, groupTotals: [ShowGroup: Int], incomplete: Set<ShowGroup> = [], notes: [String] = []) {
        self.normalized = normalized; self.stripped = stripped; self.filters = filters; self.answer = answer; self.hits = hits
        self.topScore = topScore; self.intent = intent; self.groupTotals = groupTotals; self.incomplete = incomplete; self.notes = notes
    }
}

/// C4b answers factual questions with engine-composed lines (no LLM).
public protocol FactsAnswering: Sendable {
    func answer(_ stripped: String, filters: SearchFilters, companyId: String, reader: Reader, now: Date) throws -> FactAnswer?
}

/// A phrase of the design §2.2 table, before the resolver looks it up.
public struct PhraseMatch: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// The best preview: a surface name, a word of a smoke path, or nil (the first surface).
        case preview(target: String?)
        /// `KEY:run`, or (no key) the latest failing run.
        case run(key: String?, failing: Bool)
        case latestRelease
        case agentNow(handle: String)
        /// `KEY:diff@worktree` when leased and dirty, else `KEY:diff`.
        case changes(key: String)
        /// Artifacts published by designers and architects matching the subject.
        case mockup(subject: String)
    }

    public var action: Action
    /// `iphone`, `ipad` or `desktop`: a param on the preview.
    public var viewport: String?

    public init(action: Action, viewport: String? = nil) { self.action = action; self.viewport = viewport }
}

/// The phrase table (design §2.2), plain code. Matched on the stripped query (filler gone, case kept); `original` (the
/// normalized query) is read only for `the <surface>`, whose `the` stripping removed.
public enum ShowPhrases {
    static let viewports: [String: String] = ["mobile": "iphone", "iphone": "iphone", "phone": "iphone", "ipad": "ipad", "tablet": "ipad",
                                              "desktop": "desktop"]
    static let landing: Set<String> = ["landing", "home", "main", "index", "front", "root"]

    public static func match(_ stripped: String, original: String) -> PhraseMatch? {
        var words = stripped.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        guard !words.isEmpty else { return nil }
        var lower = words.map { $0.lowercased() }
        var viewport: String?
        if let i = lower.firstIndex(where: { viewports[$0] != nil }) {
            viewport = viewports[lower[i]]
            words.remove(at: i)
            lower.remove(at: i)
        }
        let set = Set(lower)
        let key = words.compactMap(itemKey).first

        // what's @x doing / @x now / @x
        if let handle = lower.first(where: { $0.hasPrefix("@") && RefGrammar.isHandle(String($0.dropFirst())) }).map({ String($0.dropFirst()) }),
           lower.count == 1 || set.contains("doing") || set.contains("now") {
            return PhraseMatch(action: .agentNow(handle: handle), viewport: viewport)
        }
        // changes/diff for KEY, what changed in KEY
        if let key, !set.isDisjoint(with: ["changes", "change", "changed", "diff"]) {
            return PhraseMatch(action: .changes(key: key), viewport: viewport)
        }
        // latest/last/failing run|tests|check (+ KEY)
        if !set.isDisjoint(with: ["latest", "last", "failing", "failed"]), !set.isDisjoint(with: ["run", "runs", "test", "tests", "check", "checks"]) {
            return PhraseMatch(action: .run(key: key, failing: !set.isDisjoint(with: ["failing", "failed"])), viewport: viewport)
        }
        // latest release / what shipped
        let text = lower.joined(separator: " ")
        if ["latest release", "last release", "newest release", "what shipped", "what's shipped", "whats shipped"].contains(where: text.contains) {
            return PhraseMatch(action: .latestRelease, viewport: viewport)
        }
        // mock/mockup/design for X
        if let i = lower.firstIndex(where: { ["mock", "mocks", "mockup", "mockups", "design", "designs"].contains($0) }) {
            var rest = lower
            rest.remove(at: i)
            return PhraseMatch(action: .mockup(subject: rest.joined(separator: " ")), viewport: viewport)
        }
        // <x> page / the <surface>
        if lower.last == "page", lower.count >= 2 {
            return PhraseMatch(action: .preview(target: lower.dropLast().joined(separator: " ")), viewport: viewport)
        }
        let originalWords = original.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if lower.count == 1, let t = originalWords.firstIndex(of: "the"), t + 1 < originalWords.count,
           originalWords[t + 1].trimmingCharacters(in: CharacterSet(charactersIn: "?")) == lower[0] {
            return PhraseMatch(action: .preview(target: lower[0]), viewport: viewport)
        }
        // A viewport word alone is a param on the best preview candidate.
        if viewport != nil {
            return PhraseMatch(action: .preview(target: lower.isEmpty ? nil : lower.joined(separator: " ")), viewport: viewport)
        }
        return nil
    }

    /// `eng-142` / `ENG-142` → `ENG-142` (any prefix shape; the resolver checks the item exists).
    static func itemKey(_ w: String) -> String? {
        let up = w.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]\"'"))
        guard let dash = up.firstIndex(of: "-") else { return nil }
        let prefix = up[..<dash], digits = up[up.index(after: dash)...]
        guard (1...10).contains(prefix.count), let first = prefix.unicodeScalars.first, (0x41...0x5A).contains(first.value),
              prefix.unicodeScalars.allSatisfy({ (0x41...0x5A).contains($0.value) || (0x30...0x39).contains($0.value) }),
              (1...9).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              !["A", "AR", "F"].contains(String(prefix)) else { return nil }
        return up
    }
}

/// Plan C Task C4a: the Show bar's engine side (design §2.2), no LLM. Order: normalize → direct refs (the whole query and
/// each token; score 1.0, TOP) → facts (C4b) → phrases (0.95, TOP) → `SearchFilters.parse` → `GlobalSearch` (fuzzy, ≤ 0.95).
/// Every hit is resolved for `reader`; the result never says what was dropped. Typing never starts a turn and writes nothing.
public struct ShowResolver: Sendable {
    public static let groupLimit = 5
    public static let maxQuery = ShowQuery.maxQuery
    static let maxDirectRefs = 6
    static let phraseScore = 0.95
    /// A ref typed inside a matched phrase ranks below the phrase (`what changed in ENG-142`: the diff first).
    static let demotedRefScore = 0.9

    let store: Store
    let files: FileIndexCache
    let commits: CommitIndexCache
    let facts: (any FactsAnswering)?
    let memory: any MemorySearching

    public init(store: Store, files: FileIndexCache, commits: CommitIndexCache, facts: (any FactsAnswering)? = nil) {
        self.init(store: store, files: files, commits: commits, facts: facts, memory: MemoryIndex(store: store))
    }

    init(store: Store, files: FileIndexCache, commits: CommitIndexCache, facts: (any FactsAnswering)?, memory: any MemorySearching) {
        self.store = store; self.files = files; self.commits = commits; self.facts = facts; self.memory = memory
    }

    /// `knownValues`: the company's stored secret values (`Store.knownSecretValues` from the injected vault); no hit carries
    /// one (Rulings 53 and 54, `GlobalSearch.TextGate`).
    public func resolve(_ query: String, companyId: String, reader: Reader, knownValues: [(name: String, value: String)]) async throws -> ShowResult {
        let me = self
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        return try await GlobalSearch.blocking.tryRun { try me.resolveNow(query, companyId: companyId, reader: reader, gate: gate) }
    }

    /// `resolve`, synchronously; `forced` filters (the `search` tool's arguments) override what the text says.
    func resolveNow(_ query: String, companyId: String, reader: Reader, gate: GlobalSearch.TextGate, forced: SearchFilters = SearchFilters(),
                    now: Date = Store.now()) throws -> ShowResult {
        let (normalized, stripped) = ShowQuery.normalize(query)
        _ = try ReaderContext.load(store: store, companyId: companyId, reader: reader)
        guard let company = try store.company(id: companyId) else {
            return ShowResult(normalized: normalized, stripped: stripped, filters: SearchFilters(), answer: nil, hits: [], topScore: 0,
                              intent: .request, groupTotals: [:])
        }
        let (context, sprintStart) = try store.writer.read { db in
            (RefContext(companyId: companyId, keyPrefixes: try GlobalSearch.keyPrefixes(db, companyId: companyId)),
             try Date.fetchOne(db, sql: """
                SELECT COALESCE(startedAt, createdAt) FROM sprint WHERE companyId = ? AND status = 'active' ORDER BY number DESC LIMIT 1
                """, arguments: [companyId]))
        }
        let parsed = SearchFilters.parse(stripped, now: now, tz: store.ownerTimeZone(), activeSprintStart: sprintStart)
        let rest = parsed.rest
        var filters = parsed.filters
        if !forced.kinds.isEmpty { filters.kinds = forced.kinds }
        if let w = forced.window { filters.window = w }
        if let a = forced.actor { filters.actor = a }
        if let s = forced.status { filters.status = s }
        if let c = forced.channel { filters.channel = c }

        let search = GlobalSearch(store: store, files: files, commits: commits, memory: memory)
        let git = search.gitState(company: company)

        // Direct refs.
        var top: [ShowHit] = []
        var seen = Set<String>()
        let whole = directRefs(stripped, context: context)
        for (ref, _) in whole {
            guard seen.count < Self.maxDirectRefs, !seen.contains(ref.canonical),
                  let hit = try directHit(ref, git: git, companyId: companyId, reader: reader).flatMap(gate.hit) else { continue }
            seen.insert(ref.canonical)
            top.append(hit)
        }
        let wholeQueryRef = whole.first(where: \.whole).map(\.ref.canonical)

        // Facts (C4b).
        let answer = try facts?.answer(stripped, filters: filters, companyId: companyId, reader: reader, now: now)

        // Phrases.
        if let phrase = ShowPhrases.match(stripped, original: normalized) {
            let phraseHits = try phraseHits(phrase, company: company, reader: reader, gate: gate).compactMap(gate.hit)
            if !phraseHits.isEmpty {
                // Refs typed inside the phrase rank below it (unless the ref is the whole query or what the phrase opens).
                let opened = Set(phraseHits.map(\.ref.canonical))
                top = top.map { hit in
                    guard hit.ref.canonical != wholeQueryRef, !opened.contains(hit.ref.canonical) else { return hit }
                    var h = hit
                    h.score = Self.demotedRefScore
                    h.group = h.kind?.group ?? .top
                    return h
                }
                for hit in phraseHits where !seen.contains(hit.ref.canonical) {
                    seen.insert(hit.ref.canonical)
                    top.append(hit)
                }
            }
        }

        // Fuzzy search over everything else.
        let found = try search.searchNow(rest, filters: filters, companyId: companyId, reader: reader, limitPerGroup: Self.groupLimit, now: now,
                                         gate: gate, git: git)
        var rows = top.sorted { $0.score > $1.score }
        let others = found.hits.filter { !seen.contains($0.ref.canonical) || $0.inlineOnly }
        var promoted: ShowHit? = nil
        if !rows.contains(where: { $0.group == .top }), let best = others.max(by: { $0.score < $1.score }) {
            promoted = best
            var b = best
            b.group = .top
            rows.insert(b, at: 0)
        }
        // TOP first, then the groups in order.
        var ordered = Array(rows.filter { $0.group == .top }.prefix(Self.groupLimit))
        let grouped = rows.filter { $0.group != .top } + others.filter { h in promoted.map { $0 != h } ?? true }
        for group in ShowGroup.allCases where group != .top {
            ordered += grouped.filter { $0.group == group }.sorted { $0.score > $1.score }.prefix(Self.groupLimit)
        }
        let topScore = ordered.map(\.score).max() ?? 0
        var totals: [ShowGroup: Int] = [:]
        if reader == .owner {
            totals = found.totals
            let topCount = ordered.filter { $0.group == .top }.count
            if topCount > 0 { totals[.top] = topCount }
        }
        return ShowResult(normalized: normalized, stripped: stripped, filters: filters, answer: answer, hits: ordered, topScore: topScore,
                          intent: ShowIntent.classify(stripped: stripped, topScore: topScore, hasFact: answer != nil), groupTotals: totals,
                          incomplete: found.incomplete, notes: GlobalSearch.notes(filters))
    }

    // MARK: Direct refs

    /// The refs the stripped query names: the whole of it, then each token (`RefScanner`; a key typed in lowercase counts).
    func directRefs(_ stripped: String, context: RefContext) -> [(ref: WorkRef, whole: Bool)] {
        guard !stripped.isEmpty else { return [] }
        var out: [(ref: WorkRef, whole: Bool)] = []
        func parse(_ s: String) -> WorkRef? {
            if let r = WorkRef.parse(s, context: context) { return r }
            if s.contains("-"), !s.contains("/"), s != s.uppercased(), let r = WorkRef.parse(s.uppercased(), context: context),
               r.kind == .item || r.kind == .ask || r.kind == .artifact || r.kind == .resource { return r }
            return nil
        }
        if let r = parse(stripped) { out.append((r, true)) }
        for found in RefScanner.scan(stripped, context: context) where !out.contains(where: { $0.ref == found.ref }) {
            out.append((found.ref, false))
        }
        for token in stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init) where token != token.uppercased() {
            if let r = parse(token), !out.contains(where: { $0.ref == r }) { out.append((r, stripped == token)) }
        }
        return out
    }

    /// A typed ref as a TOP hit. A committed file on `main` is looked up in the file index (a path that isn't there is no
    /// hit, without a git call per keystroke) and checked like the git sources; everything else is resolved for the reader.
    func directHit(_ ref: WorkRef, git: GlobalSearch.GitState?, companyId: String, reader: Reader) throws -> ShowHit? {
        if ref.kind == .file, ref.branch == nil, ref.rev == nil, !ref.id.hasPrefix(".brahma/"), let git,
           let index = try? files.indexNow(companyId: companyId, branch: "main", head: git.main, git: git.git) {
            guard index.sha(of: ref.id) != nil else { return nil }
            let decision = try store.writer.read { db in try RefAccess.canRead(reader, ref, companyId: companyId, db: db, catalog: store.catalog) }
            guard case .allowed = decision else { return nil }
            let tainted = (try? store.refTaint(ref, companyId: companyId).tainted) ?? true
            return ShowHit(ref: ref, title: ref.canonical,
                           subtitle: tainted ? GlobalSearch.taintedSubtitle : "main", snippet: nil, at: nil, group: .top, score: 1.0, kind: .file)
        }
        return try resolvedHit(ref, score: 1.0, group: .top, companyId: companyId, reader: reader)
    }

    /// `ref` as `reader` reads it, or nil (anything but `.full`).
    func resolvedHit(_ ref: WorkRef, score: Double, group: ShowGroup, companyId: String, reader: Reader, title: String? = nil) throws -> ShowHit? {
        guard let r = try? store.resolveRef(ref, for: reader, companyId: companyId), r.visibility == .full else { return nil }
        return ShowHit(ref: ref, title: r.tainted ? r.title : (title ?? r.title),
                       subtitle: r.tainted ? GlobalSearch.taintedSubtitle : r.subtitle,
                       snippet: nil, at: nil, group: group, score: score, kind: Self.searchKind(ref.kind))
    }

    static func searchKind(_ k: WorkRefKind) -> SearchKind? {
        switch k {
        case .file: .file
        case .diff, .commit: .commit
        case .item: .item
        case .ask: .ask
        case .kb: .kb
        case .memory: .memory
        case .artifact: .artifact
        case .resource: .resource
        case .preview: .preview
        case .run: .run
        case .release: .release
        case .message, .thread: .message
        case .agent: .agent
        case .sprint: .sprint
        case .channel, .fact: nil
        }
    }

    // MARK: Phrases

    private func phraseHits(_ phrase: PhraseMatch, company: Company, reader: Reader, gate: GlobalSearch.TextGate) throws -> [ShowHit] {
        let companyId = company.id
        var refs: [WorkRef] = []
        switch phrase.action {
        case .agentNow(let handle):
            refs = [WorkRef(kind: .agent, id: handle)]
        case .changes(let key):
            guard try store.writer.read({ db in try RefAccess.item(db, companyId, key) }) != nil else { return [] }
            var dirty = false
            if try store.lease(companyId: companyId, key: key) != nil {
                let git = store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: companyId)
                dirty = (try? git.isDirty(in: git.worktreePath(key: key))) == true
            }
            refs = [dirty ? WorkRef(kind: .diff, id: key, branch: "worktree:\(key)") : WorkRef(kind: .diff, id: key)]
        case .run(let key, let failing):
            if let key {
                refs = [WorkRef(kind: .run, id: "", params: ["item": key])]
            } else {
                let id = try store.writer.read { db -> String? in
                    let failed = try String.fetchOne(db, sql: """
                        SELECT id FROM verificationRun WHERE companyId = ? AND status IN ('failed', 'timedOut', 'error')
                        ORDER BY createdAt DESC, rowid DESC LIMIT 1
                        """, arguments: [companyId])
                    if failed != nil || failing { return failed }
                    return try String.fetchOne(db, sql: "SELECT id FROM verificationRun WHERE companyId = ? ORDER BY createdAt DESC, rowid DESC LIMIT 1",
                                               arguments: [companyId])
                }
                if let id, RefGrammar.isRecordId(id) { refs = [WorkRef(kind: .run, id: id)] }
            }
        case .latestRelease:
            if let n = try store.writer.read({ db in
                try Int.fetchOne(db, sql: "SELECT number FROM release WHERE companyId = ? ORDER BY number DESC LIMIT 1", arguments: [companyId])
            }) { refs = [WorkRef(kind: .release, id: String(n))] }
        case .mockup(let subject):
            let rows = try store.writer.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT ar.number, ar.title FROM artifact ar JOIN agent a ON a.id = ar.publishedById AND a.companyId = ar.companyId
                    WHERE ar.companyId = ? AND a.role IN ('designer', 'architect') ORDER BY ar.createdAt DESC LIMIT 200
                    """, arguments: [companyId])
            }
            var scored: [(n: Int, s: Double)] = []
            for row in rows {
                let n: Int = row["number"]
                let s = subject.isEmpty ? 0.5 : FuzzyScorer.words(subject, gate.matchText(row["title"] as String))
                if s > 0 { scored.append((n, s)) }
            }
            refs = scored.sorted { $0.s != $1.s ? $0.s > $1.s : $0.n > $1.n }.prefix(3).map { WorkRef(kind: .artifact, id: String($0.n)) }
        case .preview(let target):
            if let ref = try previewRef(target, viewport: phrase.viewport, companyId: companyId) { refs = [ref] }
        }
        if case .preview = phrase.action {} else if let viewport = phrase.viewport, refs.isEmpty {
            if let ref = try previewRef(nil, viewport: viewport, companyId: companyId) { refs = [ref] }
        }
        var hits: [ShowHit] = []
        for ref in refs {
            // Diffs are checked like the git sources: the class, and the item's taint.
            if ref.kind == .diff {
                let allowed = try store.writer.read { db in try RefAccess.canRead(reader, ref, companyId: companyId, db: db, catalog: store.catalog) }
                guard case .allowed = allowed else { continue }
                let tainted = (try? store.refTaint(ref, companyId: companyId).tainted) ?? true
                hits.append(ShowHit(ref: ref, title: ref.isWorktree ? "\(ref.id) uncommitted changes" : "\(ref.id) diff",
                                    subtitle: tainted ? GlobalSearch.taintedSubtitle : (ref.isWorktree ? "live worktree" : "main…item/\(ref.id)"),
                                    snippet: nil, at: nil, group: .top, score: Self.phraseScore, kind: .commit))
                continue
            }
            if let hit = try resolvedHit(ref, score: Self.phraseScore, group: .top, companyId: companyId, reader: reader) { hits.append(hit) }
        }
        return hits
    }

    /// The best preview for `target` (a surface name, a landing word, or a word of a smoke path), with the viewport.
    private func previewRef(_ target: String?, viewport: String?, companyId: String) throws -> WorkRef? {
        let surfaces = try store.writer.read { db in
            try PreviewSurface.fetchAll(db, sql: "SELECT * FROM previewSurface WHERE companyId = ? ORDER BY position, name", arguments: [companyId])
        }
        guard let first = surfaces.first else { return nil }
        func ref(_ surface: PreviewSurface, path: String?) -> WorkRef? {
            guard let params = PreviewRefParams.validate(path: path, viewport: viewport) else { return nil }
            return WorkRef(kind: .preview, id: surface.name, params: params)
        }
        let words = (target ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.isEmpty || words.allSatisfy(ShowPhrases.landing.contains) { return ref(first, path: nil) }
        let t = words.joined(separator: "-")
        if let named = surfaces.first(where: { $0.name == t }) { return ref(named, path: nil) }
        for surface in surfaces {
            for request in surface.smoke {
                let path = String(request.path.prefix { $0 != "?" && $0 != "#" })
                let segments = path.lowercased().split(separator: "/").map(String.init)
                if segments.contains(t) || segments.last.map({ $0.hasPrefix(t) }) == true { return ref(surface, path: path) }
            }
        }
        return nil
    }
}

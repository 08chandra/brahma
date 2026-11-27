import Foundation
import GRDB

/// The Show bar's result groups, in display order (C6 renders one header per non-empty group).
public enum ShowGroup: String, CaseIterable, Codable, Sendable {
    case top, answer, items, asks, files, commits, artifactsResources, handbook, memory, messages, people, releases, sprints, activity, previews
}

/// One Show bar row: a ref the reader can read in full, with engine-derived text.
public struct ShowHit: Equatable, Sendable {
    public var ref: WorkRef
    public var title: String
    public var subtitle: String
    /// At most 160 characters, flattened; nil for tainted sources.
    public var snippet: String?
    public var at: Date?
    public var group: ShowGroup
    public var score: Double
    /// C4a: the source that found it (nil for a direct ref or a phrase).
    public var kind: SearchKind?
    /// C4a: an activity line with no subject ref (the owner's only): shown, never opened. Its `ref` is a placeholder
    /// (`fact:activity:<id>`).
    public var inlineOnly: Bool

    public init(ref: WorkRef, title: String, subtitle: String, snippet: String?, at: Date?, group: ShowGroup, score: Double,
                kind: SearchKind? = nil, inlineOnly: Bool = false) {
        self.ref = ref; self.title = title; self.subtitle = subtitle; self.snippet = snippet; self.at = at; self.group = group
        self.score = score; self.kind = kind; self.inlineOnly = inlineOnly
    }
}

/// What global search asks of company memory: `MemoryIndex.search` (tests record the calls).
public protocol MemorySearching: Sendable {
    func search(companyId: String, scope: Reader, query: String, sources: Set<MemorySource>?, limit: Int, now: Date,
                match: MemoryMatch, text: MemoryText) throws -> [MemoryHit]
}

extension MemoryIndex: MemorySearching {}

/// Plan C Task C4a: everything in one company a reader can read, found by plain code (no LLM). Every source is filtered by
/// `SearchFilters` where it is read, every lookup is bound to the company, and every hit is re-checked for the reader
/// (`resolveRef`; files, diffs and commits found in git by `RefAccess.canRead` plus `refTaint`, since the index already proves
/// they exist): only `.full` hits remain, and nothing counts what was dropped. A tainted source keeps its engine title, loses
/// its snippet and reads `"tainted · open_ref to read"`. Activity lines quote every channel and DM, so they are the owner's
/// alone.
public struct GlobalSearch: Sendable {
    public static let toolLimit = 20
    public static let activityRows = 20_000
    public static let snippetMax = 160
    public static let taintedSubtitle = "tainted · open_ref to read"
    /// Fix round 4 (controller ruling, Ruling 58 (1)): the static note every search that reads item events or activity
    /// carries, for the owner and agents alike, whether or not anything matched.
    public static let windowNote = "searches the newest 20,000 events"
    /// The score of a row listed by its filters alone (no text): above the intent threshold, below every direct ref and phrase.
    static let listingScore = 0.7
    /// Rows a SQL source reads before the reader's access filters them.
    static let sqlCandidates = 200
    /// Candidates kept per group before access checks.
    static let groupCandidates = 60
    /// Fix round 4 (Ruling 58 (1)): the pages one cursor read (item events, activity) may fetch per search. The read stays
    /// inside the newest `activityRows` rows of its source, which fill at most `activityRows / sqlCandidates` full pages, so
    /// the last allowed page is the one that finds the window's end: a defensive bound, never reached by what matched.
    static let maxPagesPerSource = activityRows / sqlCandidates + 1

    /// The static notes a search with these filters carries (`ShowResult.notes`): the window note whenever it reads item
    /// events or activity (decided as for the owner, so every reader gets the same note for the same query).
    static func notes(_ filters: SearchFilters) -> [String] {
        kinds(filters, reader: .owner).isDisjoint(with: [.event, .activity]) ? [] : [windowNote]
    }

    static let blocking = Blocking(maxConcurrent: 4)

    let store: Store
    let files: FileIndexCache
    let commits: CommitIndexCache
    let memory: any MemorySearching

    public init(store: Store, files: FileIndexCache, commits: CommitIndexCache) {
        self.init(store: store, files: files, commits: commits, memory: MemoryIndex(store: store))
    }

    init(store: Store, files: FileIndexCache, commits: CommitIndexCache, memory: any MemorySearching) {
        self.store = store; self.files = files; self.commits = commits; self.memory = memory
    }

    /// At most `limitPerGroup` hits per group, best first within each group, groups in `ShowGroup` order. `knownValues`: the
    /// company's stored secret values (`Store.knownSecretValues` from the injected vault): no hit carries one (Rulings 53, 54).
    public func search(_ rest: String, filters: SearchFilters, companyId: String, reader: Reader, limitPerGroup: Int,
                       knownValues: [(name: String, value: String)]) async throws -> [ShowHit] {
        let me = self
        let gate = TextGate(knownValues: knownValues)
        return try await Self.blocking.tryRun {
            try me.searchNow(rest, filters: filters, companyId: companyId, reader: reader, limitPerGroup: limitPerGroup, now: Store.now(),
                             gate: gate).hits
        }
    }

    // MARK: The secret gate on what a hit shows

    /// Rulings 53, 54 and 55: every piece of text a hit shows (its canonical, title, subtitle and snippet; much of it
    /// agent-written: paths, subjects, titles, message text) is checked against the secret patterns and every form of every
    /// stored value, read now (a value stored after the text was written is caught too), on the exact string that is shown:
    /// `final` builds the display string first (NFKC, hidden and invisible characters dropped, white space one space, the
    /// tool's quote and bracket mapping), gates the whole of it, cuts it, and gates the cut; nothing changes it afterwards. A
    /// canonical holding a value drops the hit; a title or subtitle falls back to the engine's words; a snippet is dropped.
    /// Matching (N-1) runs only on `matchText`, the display form with every value's span blanked, so no query can find a
    /// value's characters.
    public struct TextGate: Sendable {
        let expanded: [(name: String, value: String)]
        /// Identifies the value set (memos keyed by it never hold a value).
        let fingerprint: String
        /// Every literal `ContentScan.redact` could find (each value form's `Redactor.forms`) plus a literal every secret
        /// pattern starts with: a text holding none of them, in any spelling the gate checks, holds no secret, so the regexes
        /// are skipped. Nil (always scan) if the patterns are not the ones these literals were written for.
        let needles: [String]?

        static let patternTriggers: (patterns: [String], triggers: [String]) = (
            ["AKIA[0-9A-Z]{16}", "-----BEGIN [A-Z ]*PRIVATE KEY-----", "gh[pousr]_[A-Za-z0-9]{36,}", "github_pat_[A-Za-z0-9_]{60,}",
             "xox[abprs]-[A-Za-z0-9-]{10,}", "sk-[A-Za-z0-9_-]{20,}", "sk_live_[A-Za-z0-9]{20,}", "AIza[0-9A-Za-z_-]{35}"],
            ["AKIA", "-----BEGIN ", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-",
             "sk-", "sk_live_", "AIza"])

        public init(knownValues: [(name: String, value: String)]) {
            var forms: [(name: String, value: String)] = []
            var seen = Set<String>()
            for (name, value) in knownValues {
                let nfkc = value.precomposedStringWithCompatibilityMapping
                // The value as the display pipeline would print it, so a form the pipeline produces is caught.
                for form in [value, nfkc, Self.display(value, inert: false), Self.display(value, inert: true)]
                where !form.isEmpty && seen.insert(name + "\u{0}" + form).inserted {
                    forms.append((name, form))
                }
            }
            expanded = EncodedForms.expand(forms)
            fingerprint = StableHash.fnv1a64(expanded.map { "\($0.name)\u{0}\($0.value)" }.joined(separator: "\u{1}"))
            if SecretScan.patterns.map(\.ere) == Self.patternTriggers.patterns {
                needles = Self.patternTriggers.triggers
                    + expanded.filter { $0.value.count >= Redactor.minLength }.flatMap { Redactor.forms(of: $0.value) }.filter { !$0.isEmpty }
            } else {
                needles = nil
            }
        }

        /// Whether `s` could hold a secret at all (exact UTF-16 search, as `ContentScan.redact` searches).
        private func mayHold(_ s: String) -> Bool {
            guard let needles else { return true }
            let ns = s as NSString
            return needles.contains { ns.range(of: $0, options: .literal).location != NSNotFound }
        }

        /// The display pipeline: NFKC; C0/C1 controls, bidi, zero-width, format characters, U+00AD and U+180E dropped; every
        /// run of white space one space (trimmed); with `inert`, `"` → `'`, `[` → `(`, `]` → `)` (the tool's line fields).
        public static func display(_ raw: String, inert: Bool) -> String {
            var out = String.UnicodeScalarView()
            var pendingSpace = false
            for scalar in raw.precomposedStringWithCompatibilityMapping.unicodeScalars {
                let v = scalar.value
                if scalar.properties.isWhitespace || v == 0x0A || v == 0x09 || v == 0x0D || v == 0x2028 || v == 0x2029 { pendingSpace = true; continue }
                if RefText.isHidden(v) || scalar.properties.generalCategory == .format || v == 0x00AD || v == 0x180E { continue }
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                if inert {
                    switch scalar {
                    case "\"": out.append("'")
                    case "[": out.append("(")
                    case "]": out.append(")")
                    default: out.append(scalar)
                    }
                } else {
                    out.append(scalar)
                }
            }
            return String(out)
        }

        /// The text holds a pattern or a value: as written, without the characters a display drops, or in the inert
        /// spelling (`"` ↔ `'`, brackets ↔ parentheses), so a value differing only by those is withheld everywhere.
        public func holdsSecret(_ s: String) -> Bool {
            if mayHold(s), ContentScan.redact(text: s, findings: [], knownValues: expanded) != s { return true }
            if skeletonHolds(s) { return true }
            let inert = Self.display(s, inert: true)
            return inert != s && mayHold(inert) && ContentScan.redact(text: inert, findings: [], knownValues: expanded) != inert
        }

        /// A value split by characters a display drops or turns into a space (`SecretGate.isInvisible`).
        private func skeletonHolds(_ s: String) -> Bool {
            let skeleton = String(String.UnicodeScalarView(s.unicodeScalars.filter { !SecretGate.isInvisible($0) }))
            return mayHold(skeleton) && ContentScan.redact(text: skeleton, findings: [], knownValues: expanded) != skeleton
        }

        /// The final display string of `raw` (at most `max` characters, cut with `…`), or nil when the whole text or the cut
        /// holds a value.
        public func final(_ raw: String, max: Int, inert: Bool = false) -> String? {
            let full = Self.display(raw, inert: inert)
            guard !holdsSecret(full) else { return nil }
            let cut = full.count > max ? String(full.prefix(max - 1)) + "\u{2026}" : full
            guard !holdsSecret(cut) else { return nil }
            return cut
        }

        /// What a query is matched against: the display form with every secret span blanked (a space: no query token can
        /// match it), or "" when a value can't be located (split across dropped characters).
        func matchText(_ raw: String) -> String {
            let d = Self.display(raw, inert: false)
            guard holdsSecret(d) else { return d }
            let r = ContentScan.redact(text: d, findings: [], knownValues: expanded)
            if r == d { return skeletonHolds(d) ? "" : d }
            let blanked = r.replacingOccurrences(of: #"\[redacted [^\]]*\]"#, with: " ", options: .regularExpression)
            return holdsSecret(blanked) ? "" : blanked
        }

        /// A snippet of `raw`: the whole display text is gated first (any value in it: no snippet at all, so no part of a value
        /// is ever cut out and shown), then a window of at most `max` characters starting a little before the query's first
        /// word, gated again.
        func snippet(_ raw: String, around query: String, max: Int) -> String? {
            let full = Self.display(raw, inert: false)
            guard !full.isEmpty, !holdsSecret(full) else { return nil }
            var start = full.startIndex
            if let word = query.split(whereSeparator: { $0.isWhitespace }).first.map(String.init),
               let r = full.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                start = full.index(r.lowerBound, offsetBy: -min(40, full.distance(from: full.startIndex, to: r.lowerBound)))
            }
            var window = String(full[start...])
            if start != full.startIndex { window = "\u{2026}" + window }
            let cut = window.count > max ? String(window.prefix(max - 1)) + "\u{2026}" : window
            guard !holdsSecret(cut) else { return nil }
            return cut
        }

        /// The hit as shown, every field gated as its final string; nil when its canonical holds a value.
        func hit(_ h: ShowHit) -> ShowHit? {
            // The ref itself is handed on raw (it opens), and shown through the display pipeline: both are gated.
            guard !holdsSecret(h.ref.canonical), final(h.ref.canonical, max: RefGrammar.maxLength) != nil,
                  final(h.ref.canonical, max: RefGrammar.maxLength, inert: true) != nil else { return nil }
            var out = h
            let engine = h.ref.kind == .commit ? "commit \(h.ref.id.prefix(7))" : (final(h.ref.canonical, max: SafeTitle.max) ?? h.ref.kind.rawValue)
            out.title = final(h.title, max: SafeTitle.max) ?? engine
            out.subtitle = final(h.subtitle, max: SafeTitle.max) ?? ""
            out.snippet = h.snippet.flatMap { final($0, max: GlobalSearch.snippetMax) }.flatMap { $0.isEmpty ? nil : $0 }
            return out
        }
    }

    // MARK: Candidates

    /// A hit before the reader's access check.
    struct Candidate {
        var ref: WorkRef
        var kind: SearchKind
        var score: Double
        /// Engine-composed text, used when the resolver's title is not better (commit subjects are agent text: replaced when
        /// tainted).
        var title: String? = nil
        var subtitle: String? = nil
        var snippet: String? = nil
        var at: Date? = nil
        var inlineOnly = false
        /// Found in git (file, diff, commit): checked with `RefAccess.canRead` and `refTaint` instead of a full resolve.
        var light = false
        /// The source itself is tainted (whatever the ref's own taint says).
        var tainted = false
        /// The title when tainted (engine-only).
        var taintedTitle: String? = nil
        /// An activity line's row id.
        var activityId: Int64? = nil
        /// An item hit's own key and title (as company memory indexed them), to tell a title match from a body match.
        var ownTitle: String? = nil
    }

    /// The search itself, synchronously (the `search` tool and `ShowResolver` call it on their own thread). `totals` are the
    /// owner's candidate counts per group; empty for every other reader.
    func searchNow(_ rest: String, filters: SearchFilters, companyId: String, reader: Reader, limitPerGroup: Int,
                   now: Date, gate: TextGate, git: GitState? = nil) throws -> (hits: [ShowHit], totals: [ShowGroup: Int], incomplete: Set<ShowGroup>) {
        // A reader of another company is refused like any other read.
        _ = try ReaderContext.load(store: store, companyId: companyId, reader: reader)
        guard limitPerGroup > 0, let company = try store.company(id: companyId) else { return ([], [:], []) }
        let text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = FuzzyScorer.foldQuery(text).count < FuzzyScorer.minQuery
            || text.split(whereSeparator: { $0.isWhitespace }).allSatisfy { FuzzyScorer.foldQuery(String($0)).count < FuzzyScorer.minQuery }
        if listing, filters.isEmpty { return ([], [:], []) }
        let kinds = Self.kinds(filters, reader: reader)
        guard !kinds.isEmpty else { return ([], [:], []) }
        var actorId: String? = nil
        if let actor = filters.actor {
            guard let id = try actorKey(actor, companyId: companyId) else { return ([], [:], []) }   // no such agent: nothing is by them
            actorId = id
        }

        var found: [Candidate] = []
        let q = listing ? "" : text
        // C-1: the query is never changed by what the vault holds; each hit is checked against the text the reader can see.
        if !listing {
            found += try memoryCandidates(q, kinds: kinds, filters: filters, actorId: actorId, companyId: companyId, reader: reader, now: now, gate: gate)
        }
        var incomplete = Set<ShowGroup>()
        found += try gitCandidates(q, kinds: kinds, filters: filters, company: company, reader: reader, state: git ?? gitState(company: company),
                                   gate: gate, incomplete: &incomplete)
        found += try sqlCandidates(q, kinds: kinds, filters: filters, actorId: actorId, companyId: companyId, reader: reader, gate: gate,
                                   incomplete: &incomplete)

        // Group, dedupe by canonical (best score kept), order.
        var byGroup: [ShowGroup: [Candidate]] = [:]
        for c in found { byGroup[c.kind.group, default: []].append(c) }
        var hits: [ShowHit] = []
        var totals: [ShowGroup: Int] = [:]
        for group in ShowGroup.allCases {
            guard var list = byGroup[group], !list.isEmpty else { continue }
            list.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return (a.at ?? .distantPast) > (b.at ?? .distantPast)
            }
            // An item found both as itself and through one of its events: the item when its own key and title match the
            // query, else the event (the item's memory doc holds its comments too); at the better of the two scores.
            var best: [String: Double] = [:]
            for c in list where c.kind == .item || c.kind == .event { best[c.ref.canonical] = max(best[c.ref.canonical] ?? 0, c.score) }
            let titled = Set(list.filter { $0.kind == .item && (q.isEmpty || FuzzyScorer.words(q, gate.matchText($0.ownTitle ?? "")) > 0) }.map(\.ref.canonical))
            let evented = Set(list.filter { $0.kind == .event }.map(\.ref.canonical))
            list = list.compactMap { c in
                guard c.kind == .item || c.kind == .event, evented.contains(c.ref.canonical) else { return c }
                if c.kind == .event, titled.contains(c.ref.canonical) { return nil }
                if c.kind == .item, !titled.contains(c.ref.canonical), list.contains(where: { $0.kind == .item && $0.ref == c.ref }) {
                    return nil
                }
                var raised = c
                raised.score = best[c.ref.canonical] ?? c.score
                return raised
            }
            list.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return (a.at ?? .distantPast) > (b.at ?? .distantPast)
            }
            var seen = Set<String>()
            list = list.filter { seen.insert($0.inlineOnly ? $0.ref.canonical + "\u{0}\($0.title ?? "")" : $0.ref.canonical).inserted }
            // Ruling 56: counted over what can be shown (a candidate whose ref holds a value never is).
            list = list.filter { !gate.holdsSecret($0.ref.canonical) }
            if reader == .owner { totals[group] = list.count }
            var kept = 0
            for c in list.prefix(Self.groupCandidates) where kept < limitPerGroup {
                guard let checked = try verify(c, companyId: companyId, reader: reader), let hit = gate.hit(checked) else { continue }
                hits.append(hit)
                kept += 1
            }
        }
        return (hits, totals, incomplete)
    }

    /// The kinds this query reads: the filter's (all when none), narrowed by a status (items, asks, runs, agents), a channel
    /// (messages), an actor and a window (what has one); activity only for the owner.
    static func kinds(_ f: SearchFilters, reader: Reader) -> Set<SearchKind> {
        var kinds = f.kinds.isEmpty ? Set(SearchKind.allCases) : f.kinds
        if f.status != nil { kinds.formIntersection(SearchFilters.statusKinds) }
        if f.channel != nil { kinds.formIntersection([.message]) }
        if f.actor != nil { kinds.formIntersection([.message, .commit, .activity, .event, .item, .ask, .kb, .memory, .artifact, .resource, .release]) }
        if f.window != nil { kinds.subtract([.agent, .preview]) }
        if reader != .owner { kinds.remove(.activity) }
        return kinds
    }

    /// The id an actor filter matches: `"owner"`, or the agent id of a handle of this company (nil: no such agent).
    private func actorKey(_ actor: String, companyId: String) throws -> String? {
        if actor == "owner" { return "owner" }
        return try store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM agent WHERE companyId = ? AND name = ?", arguments: [companyId, actor])
        }
    }

    // MARK: Company memory

    /// `MemoryIndex` per group of sources (messages apart, so they never crowd out the rest), with the reader's own scope.
    /// The words of a memory query as `MemoryQuery` makes its tokens (letters, digits and `-`; a hyphenated word is a phrase
    /// of its parts; a one-letter part dropped unless numeric; at most `MemoryQuery.maxTokens`), folded.
    static func memoryWords(_ q: String) -> [[String]] {
        var cleaned = String.UnicodeScalarView()
        for scalar in q.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control: cleaned.append(" ")
            case .format: continue
            default: cleaned.append(scalar)
            }
        }
        var words: [[String]] = []
        var current = ""
        func flush() {
            defer { current = "" }
            let parts = current.split(separator: "-").map { fold(String($0)) }.filter { !$0.isEmpty }
            guard !parts.isEmpty, !(parts.count == 1 && parts[0].count < MemoryQuery.minTokenLength && !parts[0].allSatisfy(\.isNumber)),
                  !words.contains(parts), words.count < MemoryQuery.maxTokens else { return }
            words.append(parts)
        }
        for ch in String(cleaned) {
            if ch.isLetter || ch.isNumber || ch == "-" { current.append(ch) } else { flush() }
        }
        flush()
        return words
    }

    static func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased() }

    /// The folded words of `text` (runs of letters and digits).
    static func textWords(_ text: String) -> [String] {
        fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Whether the query words occur as words (a phrase as consecutive words) of `text`: every one (`all`) or any one.
    static func containsWords(_ words: [[String]], in text: String, all: Bool) -> Bool {
        let tokens = textWords(text)
        let set = Set(tokens)
        func has(_ parts: [String]) -> Bool {
            if parts.count == 1 { return set.contains(parts[0]) }
            guard tokens.count >= parts.count else { return false }
            for i in 0...(tokens.count - parts.count) where Array(tokens[i..<(i + parts.count)]) == parts { return true }
            return false
        }
        return all ? words.allSatisfy(has) : words.contains(where: has)
    }

    /// A memory hit the reader can see the query in: its doc's shadow (`MemoryShadow`: the title, and the body when the reader
    /// may read it in full, as shown, every stored value blanked; `MemoryIndex` checked it is current for the gate) holds the
    /// query words. Returns the raw body ("" when not readable in full) for the snippet, which the gate cuts, or nil (dropped;
    /// so is a doc with no shadow).
    private func visibleDoc(_ hit: MemoryHit, words: [[String]], all: Bool, companyId: String) throws -> String?? {
        guard let row = try store.writer.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT d.body, s.title AS shadowTitle, s.body AS shadowBody FROM memoryDoc d JOIN memoryShadow s ON s.docId = d.id
                WHERE d.companyId = ? AND d.id = ? AND d.removedAt IS NULL
                """, arguments: [companyId, hit.docId])
        }) else { return nil }
        let title: String = row["shadowTitle"], shadowBody: String = row["shadowBody"]
        let full = hit.level == .full
        guard Self.containsWords(words, in: full ? title + "\n" + shadowBody : title, all: all) else { return nil }
        return .some(full ? row["body"] as String : nil)
    }

    private func memoryCandidates(_ q: String, kinds: Set<SearchKind>, filters: SearchFilters, actorId: String?, companyId: String,
                                  reader: Reader, now: Date, gate: TextGate) throws -> [Candidate] {
        var calls: [Set<MemorySource>] = []
        if kinds.contains(.message) { calls.append([.message]) }
        var rest = Set<MemorySource>()
        if kinds.contains(.item) || kinds.contains(.event) { rest.formUnion([.item, .handoff]) }
        if kinds.contains(.ask) { rest.formUnion([.ask, .decision]) }
        if kinds.contains(.kb) { rest.insert(.kb) }
        if kinds.contains(.memory) { rest.insert(.memory) }
        if kinds.contains(.artifact) { rest.insert(MemoryRefs.artifactSource) }
        if kinds.contains(.resource) { rest.insert(.resource) }
        if kinds.contains(.sprint) { rest.insert(.retro) }
        if !rest.isEmpty { calls.append(rest) }

        let words = Self.memoryWords(q)
        guard !words.isEmpty else { return [] }
        var out: [Candidate] = []
        for sources in calls {
            // C-1 / Ruling 56 / Ruling 57: company memory is matched and ranked on its vault-blanked shadow (`text: .visible`),
            // and every word must be a word of the doc's text as the reader sees it (title, and the body when the reader may
            // read it in full, every stored value blanked); the any-word fallback is decided on the hits kept.
            var kept: [(hit: MemoryHit, body: String?)] = []
            var seenDocs = Set<Int64>()
            for hit in try memory.search(companyId: companyId, scope: reader, query: q, sources: sources, limit: MemoryPolicy.maxHits, now: now,
                                         match: .all, text: .visible(gate)) {
                guard let checked = try visibleDoc(hit, words: words, all: true, companyId: companyId) else { continue }
                kept.append((hit, checked))
                seenDocs.insert(hit.docId)
            }
            if kept.count < MemoryPolicy.orFallbackBelow, words.count > 1 {
                for hit in try memory.search(companyId: companyId, scope: reader, query: q, sources: sources, limit: MemoryPolicy.maxHits,
                                             now: now, match: .any, text: .visible(gate)) where !seenDocs.contains(hit.docId) {
                    guard let checked = try visibleDoc(hit, words: words, all: false, companyId: companyId) else { continue }
                    kept.append((hit, checked))
                    seenDocs.insert(hit.docId)
                }
            }
            for (hit, body) in kept {
                guard let found = try memoryRef(hit, companyId: companyId), kinds.contains(found.1) else { continue }
                let (ref, kind) = found
                if let w = filters.window, !w.contains(hit.updatedAt) { continue }
                if let actorId, hit.authorId != actorId { continue }
                var c = Candidate(ref: ref, kind: kind, score: 0.9 * max(hit.score, 0) / (max(hit.score, 0) + 1))
                // I-1: the snippet is cut by the engine from the doc's whole text, after the whole text is gated; never an
                // index's own cut. Only a doc the reader may read in full, untainted, has one.
                if !hit.tainted, hit.level == .full, let body {
                    c.snippet = gate.snippet(body, around: q, max: Self.snippetMax)
                }
                c.tainted = hit.tainted
                c.at = hit.updatedAt
                if kind == .message { c.subtitle = hit.title }
                if hit.source == .item, !hit.tainted { c.ownTitle = hit.title }
                out.append(c)
            }
        }
        return try applyMemoryFilters(out, filters: filters, companyId: companyId)
    }

    /// The work ref a memory hit cites, and its kind; nil for a form no ref opens (a decision line naming no ask).
    private func memoryRef(_ hit: MemoryHit, companyId: String) throws -> (WorkRef, SearchKind)? {
        let r = hit.ref
        func number(_ prefix: String) -> String? {
            guard r.hasPrefix(prefix) else { return nil }
            return RefGrammar.number(String(r.dropFirst(prefix.count)))
        }
        switch hit.source {
        case .message:
            let id = String(r.dropFirst(4))
            return r.hasPrefix("msg:") && RefGrammar.isRecordId(id) ? (WorkRef(kind: .message, id: id), .message) : nil
        case .item:
            let key = r.hasPrefix("item:") ? String(r.dropFirst(5)) : r
            return (WorkRef(kind: .item, id: key), .item)
        case .handoff:
            guard r.hasPrefix("handoff:"), let slash = r.firstIndex(of: "/") else { return nil }
            return (WorkRef(kind: .item, id: String(r[r.index(r.startIndex, offsetBy: 8)..<slash])), .item)
        case .ask:
            return number("A-").map { (WorkRef(kind: .ask, id: $0), .ask) }
        case .decision:
            // The decision's activity line names its ask, if any.
            guard let id = Int64(r.dropFirst("decision:".count)) else { return nil }
            let line = try store.writer.read { db in
                try String.fetchOne(db, sql: "SELECT text FROM activityEvent WHERE companyId = ? AND id = ?", arguments: [companyId, id])
            }
            guard let line else { return nil }
            for token in line.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "," || $0 == "(" || $0 == ")" }) {
                if token.hasPrefix("A-"), let n = RefGrammar.number(String(token.dropFirst(2))) { return (WorkRef(kind: .ask, id: n), .ask) }
            }
            return nil
        case .kb:
            guard r.hasPrefix("kb:") else { return nil }
            let body = String(r.dropFirst(3))
            if let hash = body.firstIndex(of: "#") {
                return (WorkRef(kind: .kb, id: String(body[..<hash]), params: ["section": String(body[body.index(after: hash)...])]), .kb)
            }
            return (WorkRef(kind: .kb, id: body), .kb)
        case .memory:
            return number("mem:").map { (WorkRef(kind: .memory, id: $0), .memory) }
        case .resource:
            return number("F-").map { (WorkRef(kind: .resource, id: $0), .resource) }
        case .retro:
            return number("sprint:").map { (WorkRef(kind: .sprint, id: $0), .sprint) }
        default:
            if hit.source == MemoryRefs.artifactSource { return number("AR-").map { (WorkRef(kind: .artifact, id: $0), .artifact) } }
            return nil
        }
    }

    /// The status filter on item and ask hits, and the channel filter on messages (both read from their rows).
    private func applyMemoryFilters(_ list: [Candidate], filters: SearchFilters, companyId: String) throws -> [Candidate] {
        guard filters.status != nil || filters.channel != nil else { return list }
        return try store.writer.read { db in
            try list.filter { c in
                switch c.kind {
                case .item, .event:
                    guard let status = filters.status, let wanted = Self.itemStatuses(status) else { return filters.status == nil }
                    let s = try String.fetchOne(db, sql: "SELECT status FROM workItem WHERE companyId = ? AND key = ?", arguments: [companyId, c.ref.id])
                    return s.map(wanted.contains) ?? false
                case .ask:
                    guard let status = filters.status, let wanted = Self.askStatuses(status) else { return filters.status == nil }
                    let s = try String.fetchOne(db, sql: "SELECT status FROM ask WHERE companyId = ? AND number = ?", arguments: [companyId, Int(c.ref.id) ?? -1])
                    return s.map(wanted.contains) ?? false
                case .message:
                    guard let channel = filters.channel else { return true }
                    let name = try String.fetchOne(db, sql: """
                        SELECT c.name FROM message m JOIN channel c ON c.id = m.channelId AND c.companyId = m.companyId
                        WHERE m.companyId = ? AND m.id = ?
                        """, arguments: [companyId, c.ref.id])
                    return name == channel
                default:
                    return filters.status == nil
                }
            }
        }
    }

    // MARK: Git: files and commits

    /// The company's repository as search reads it: `main`'s head and the leased item branches' (read at most every
    /// `FileIndexCache.headsTTL` seconds per set of leases), and the version of the engine's commit-author record.
    struct GitState {
        let git: SafeGit
        let heads: [String: String]
        /// `Store.commitAuthorsVersion` when read: commit authors come only from the engine's per-turn record (C4b).
        let authorsVersion: Int64
        var main: String { heads["main"] ?? "" }
    }

    /// Nil for a company without a readable repository.
    func gitState(company: Company) -> GitState? {
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        guard let git = try? store.refGit(workspace),
              let leased = try? store.writer.read({ db in
                  try String.fetchAll(db, sql: """
                      SELECT w.key FROM workLease l JOIN workItem w ON w.id = l.itemId AND w.companyId = l.companyId
                      WHERE l.companyId = ? ORDER BY w.key
                      """, arguments: [company.id])
              }) else { return nil }
        let version = store.commitAuthorsVersion(companyId: company.id)
        let cacheKey = company.id + "\u{0}" + leased.joined(separator: ",")
        if let cached = files.heads.get(cacheKey), Date().timeIntervalSince(cached.at) < FileIndexCache.headsTTL, cached.at <= Date() {
            return GitState(git: git, heads: cached.heads, authorsVersion: version)
        }
        guard let main = try? git.head("main") else { return nil }
        var heads: [String: String] = ["main": main]
        if !leased.isEmpty, let items = try? git.branchHeads(prefix: "item/") {
            let set = Set(leased)
            for (branch, head) in items where set.contains(String(branch.dropFirst(5))) { heads[branch] = head }
        }
        files.heads.put(cacheKey, FileIndexCache.TimedHeads(at: Date(), heads: heads))
        return GitState(git: git, heads: heads, authorsVersion: version)
    }

    /// Files and commits. What can't be read (no repository, an index that failed or hit its cap) is named in `incomplete`,
    /// never dropped silently.
    private func gitCandidates(_ q: String, kinds: Set<SearchKind>, filters: SearchFilters, company: Company, reader: Reader,
                               state: GitState?, gate: TextGate, incomplete: inout Set<ShowGroup>) throws -> [Candidate] {
        let wantFiles = kinds.contains(.file) && !q.isEmpty
        let wantCommits = kinds.contains(.commit)
        guard wantFiles || wantCommits else { return [] }
        guard let state else {
            if wantFiles { incomplete.insert(.files) }
            if wantCommits { incomplete.insert(.commits) }
            return []
        }
        let git = state.git, main = state.main
        // N-5 / M-3: only item branches whose item the reader can read are indexed, so neither their hits nor their failures
        // (the incomplete flags) ever reach a reader who can't read the item.
        var heads: [String: String] = ["main": main]
        for (branch, head) in state.heads where branch != "main" {
            let readable = try store.writer.read { db in
                try RefAccess.canRead(reader, WorkRef(kind: .item, id: String(branch.dropFirst(5))), companyId: company.id, db: db,
                                      catalog: store.catalog)
            }
            if case .allowed = readable { heads[branch] = head }
        }
        var out: [Candidate] = []
        var mainIndex: FileIndex? = nil
        if wantFiles {
            mainIndex = try? files.indexNow(companyId: company.id, branch: "main", head: main, git: git)
            if mainIndex?.truncated != false { incomplete.insert(.files) }
        }
        if let mainIndex {
            // Ruling 56: a path holding a value is never shown, so it never takes part in matching or ranking either.
            for f in mainIndex.scored(q, limit: Self.groupCandidates, where: nil, excluding: { gate.holdsSecret($0) }) {
                out.append(fileCandidate(path: f.path, branch: nil, score: f.score, time: f.time, filters: filters))
            }
            for (branch, head) in heads.sorted(by: { $0.key < $1.key }) where branch != "main" {
                guard let index = try? files.indexNow(companyId: company.id, branch: branch, head: head, git: git) else {
                    incomplete.insert(.files)
                    continue
                }
                if index.truncated { incomplete.insert(.files) }
                // An item branch adds only what differs from main.
                for f in index.scored(q, limit: Self.groupCandidates, where: { index.sha(of: $0) != mainIndex.sha(of: $0) },
                                      excluding: { gate.holdsSecret($0) }) {
                    out.append(fileCandidate(path: f.path, branch: branch, score: f.score, time: f.time, filters: filters))
                }
            }
            if let w = filters.window { out.removeAll { $0.kind == .file && !($0.at.map(w.contains) ?? false) } }
        }
        var commitIndex: CommitIndex? = nil
        if wantCommits {
            let store = self.store, companyId = company.id
            commitIndex = try? commits.indexNow(companyId: companyId, heads: heads, authorsVersion: state.authorsVersion,
                                                authors: { try store.recordedCommitAuthors(companyId: companyId, shas: $0) }, git: git)
            if commitIndex == nil { incomplete.insert(.commits) }
        }
        if let index = commitIndex {
            var diffs = Set<String>()
            for (c, score) in index.scored(q, filters: filters, limit: Self.groupCandidates, listingScore: Self.listingScore, gate: gate,
                                                subjects: reader == .owner) {
                let short = String(c.sha.prefix(7))
                var cand = Candidate(ref: WorkRef(kind: .commit, id: c.sha), kind: .commit, score: score)
                // Ruling 54: the subject is agent-written; only the owner sees it (gated), an agent sees the engine's title.
                cand.title = reader == .owner ? c.subject : "commit \(short)"
                cand.taintedTitle = "commit \(short)"
                cand.subtitle = "commit \(short) · " + (c.author == CommitIndex.unverified ? "unverified author" : "@\(c.author)") + " · \(c.branch)"
                cand.at = c.at
                cand.light = true
                out.append(cand)
                // An item-branch commit also offers the item's diff.
                if c.branch.hasPrefix("item/"), diffs.insert(c.branch).inserted {
                    let key = String(c.branch.dropFirst(5))
                    var diff = Candidate(ref: WorkRef(kind: .diff, id: key), kind: .commit, score: max(0, score - 0.01))
                    diff.title = "\(key) diff"
                    diff.subtitle = "main…\(c.branch)"
                    diff.at = c.at
                    diff.light = true
                    out.append(diff)
                }
            }
        }
        return out
    }

    private func fileCandidate(path: String, branch: String?, score: Double, time: Int, filters: SearchFilters) -> Candidate {
        let key = branch.map { String($0.dropFirst(5)) }
        var c = Candidate(ref: WorkRef(kind: .file, id: path, branch: branch), kind: .file, score: score)
        c.title = path
        c.subtitle = key.map { "\($0) · item/\($0)" } ?? "main"
        c.at = time > 0 ? Date(timeIntervalSince1970: TimeInterval(time)) : nil
        c.light = true
        return c
    }

    // MARK: Rows

    private func sqlCandidates(_ q: String, kinds: Set<SearchKind>, filters: SearchFilters, actorId: String?, companyId: String,
                               reader: Reader, gate: TextGate, incomplete: inout Set<ShowGroup>) throws -> [Candidate] {
        let listing = q.isEmpty
        let tokens = q.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= FuzzyScorer.minQuery }
        let folded = tokens.map(FuzzyScorer.foldQuery)
        /// I-A: a row read through the raw prefilter is kept only if every query word is a substring of its text as the reader
        /// sees it (every stored value blanked), then scored on that text: the scorer's subsequences can't reach into a value.
        func visibleScore(_ text: String) -> Double {
            if listing { return Self.listingScore }
            let visible = gate.matchText(text)
            let lower = visible.lowercased()
            guard tokens.allSatisfy({ lower.contains($0) }) else { return 0 }
            return FuzzyScorer.words(folded, visible.split(whereSeparator: { $0.isWhitespace }).map { FuzzyScorer.Folded(String($0)) })
        }
        // N-1: a row is matched on its text with every stored value blanked, never on the raw text.
        func score(_ text: String) -> Double {
            listing ? Self.listingScore
                : FuzzyScorer.words(folded, gate.matchText(text).split(whereSeparator: { $0.isWhitespace }).map { FuzzyScorer.Folded(String($0)) })
        }
        /// `instr(lower(<column>), ?) > 0` for every token (a substring prefilter; the scorer ranks what passes).
        func contains(_ column: String) -> (String, [DatabaseValueConvertible]) {
            (tokens.map { _ in " AND instr(lower(\(column)), ?) > 0" }.joined(), tokens.map { $0 as DatabaseValueConvertible })
        }
        func window(_ column: String) -> (String, [DatabaseValueConvertible]) {
            guard let w = filters.window else { return ("", []) }
            return (" AND \(column) >= ? AND \(column) <= ?", [w.start, w.end])
        }
        let limit = Self.sqlCandidates
        var out: [Candidate] = []
        var cut = Set<ShowGroup>()
        defer { incomplete.formUnion(cut) }
        try store.writer.read { db in
            /// Fix round 3 (controller ruling 1, re-review I-A): a source read through a raw prefilter (item events, activity) is
            /// read with a cursor, newest first by `rowKey`, within a window that doesn't depend on the query: always the newest
            /// `activityRows` rows of the source, narrowed by the time window when there is one (fix round 4, Ruling 58 (1): a
            /// window never replaces the cap). A row counts only when `accept` keeps it, so rows that match only inside a stored
            /// value never take another row's place. Fix round 4 (R4-5): the read stops at exactly `limit` kept rows (the newest
            /// `limit` rows whose visible text matches, whatever page they fall on), and the group is then marked incomplete;
            /// it also stops at the window's end, or (never reached inside the window) at `maxPagesPerSource` pages, incomplete.
            func paged(_ base: String, _ args: [DatabaseValueConvertible], key: String, group: ShowGroup,
                       accept: (Row) throws -> Candidate?) throws {
                var accepted = 0, pages = 0
                var before: Int64? = nil
                while true {
                    guard pages < Self.maxPagesPerSource else { cut.insert(group); return }
                    pages += 1
                    var sql = base, a = args
                    if let before { sql += " AND \(key) < ?"; a.append(before) }
                    sql += " ORDER BY \(key) DESC LIMIT \(limit)"
                    let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(a))
                    for row in rows {
                        guard let c = try accept(row) else { continue }
                        out.append(c)
                        accepted += 1
                        if accepted == limit { cut.insert(group); return }
                    }
                    if rows.count < limit { return }
                    before = rows.last?["rowKey"]
                }
            }
            // Agents: handle, name, role, team and current item title; prefix or fuzzy. Status: the agent state.
            if kinds.contains(.agent), !listing || filters.status != nil {
                let states = filters.status.map { Self.agentStates($0) ?? [] }
                if states?.isEmpty != true {
                    for row in try Row.fetchAll(db, sql: """
                        SELECT a.name, a.role, a.team, a.state, (SELECT w.title FROM workLease l JOIN workItem w ON w.id = l.itemId
                          WHERE l.agentId = a.id AND l.companyId = a.companyId LIMIT 1) AS current
                        FROM agent a WHERE a.companyId = ? AND a.state <> 'killed'
                        """, arguments: [companyId]) {
                        let name: String = row["name"], state: String = row["state"]
                        if let states, !states.contains(state) { continue }
                        let words = [name, row["role"] as String, (row["team"] as String?) ?? "", (row["current"] as String?) ?? ""].joined(separator: " ")
                        var s = score(words)
                        if !listing, gate.matchText(name) == name, name.hasPrefix(q.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")) {
                            s = max(s, 0.9)
                        }
                        guard s > 0 else { continue }
                        out.append(Candidate(ref: WorkRef(kind: .agent, id: name), kind: .agent, score: s))
                    }
                }
            }
            // Messages listed by their filters (text search of messages is company memory's); each is checked for the reader
            // like any hit, so a DM or a channel it isn't in never shows.
            if kinds.contains(.message), listing, filters.actor != nil || filters.channel != nil || filters.window != nil {
                var sql = """
                    SELECT m.id, m.senderId, m.text, m.createdAt, c.name AS channelName, c.kind AS channelKind FROM message m
                    JOIN channel c ON c.id = m.channelId AND c.companyId = m.companyId WHERE m.companyId = ? AND m.kind <> 'system'
                    """
                var args: [DatabaseValueConvertible] = [companyId]
                // Like company memory (C3b), a message carrying a ref above normal sensitivity is listed for the owner only.
                if reader != .owner {
                    sql += " AND NOT EXISTS (SELECT 1 FROM messageRef r WHERE r.companyId = m.companyId AND r.messageId = m.id AND r.sensitivity <> 'normal')"
                }
                if let actorId { sql += " AND m.senderId = ?"; args.append(actorId) }
                if let channel = filters.channel { sql += " AND c.name = ? AND c.kind = 'channel'"; args.append(channel) }
                let (w, wa) = window("m.createdAt"); sql += w; args += wa
                sql += " ORDER BY m.createdAt DESC, m.rowid DESC LIMIT \(limit)"
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                    let id: String = row["id"], at: Date = row["createdAt"], text: String = row["text"]
                    guard RefGrammar.isRecordId(id) else { continue }
                    var c = Candidate(ref: WorkRef(kind: .message, id: id), kind: .message, score: Self.listingScore)
                    c.at = at
                    c.tainted = try Self.authorTainted(db, row["senderId"], at: at)
                    c.snippet = c.tainted ? nil : gate.snippet(text, around: q, max: Self.snippetMax)
                    out.append(c)
                }
            }
            // Items listed by their filters (text search of items is company memory's).
            if kinds.contains(.item), listing {
                var sql = "SELECT key, title, updatedAt FROM workItem WHERE companyId = ?"
                var args: [DatabaseValueConvertible] = [companyId]
                if let status = filters.status {
                    let wanted = Self.itemStatuses(status) ?? []
                    sql += wanted.isEmpty ? " AND 0" : " AND status IN (\(wanted.map { _ in "?" }.joined(separator: ", ")))"
                    args += wanted
                }
                if let actorId { sql += " AND (authorId = ? OR ownerId = ?)"; args += [actorId, actorId] }
                let (w, wa) = window("updatedAt"); sql += w; args += wa
                sql += " ORDER BY updatedAt DESC LIMIT \(limit)"
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                    var c = Candidate(ref: WorkRef(kind: .item, id: row["key"]), kind: .item, score: Self.listingScore)
                    c.at = row["updatedAt"]
                    out.append(c)
                }
            }
            // Asks listed by their filters.
            if kinds.contains(.ask), listing {
                var sql = "SELECT number, updatedAt FROM ask WHERE companyId = ? AND kind <> 'engineAlert'"
                var args: [DatabaseValueConvertible] = [companyId]
                if let status = filters.status {
                    let wanted = Self.askStatuses(status) ?? []
                    sql += wanted.isEmpty ? " AND 0" : " AND status IN (\(wanted.map { _ in "?" }.joined(separator: ", ")))"
                    args += wanted
                }
                if let actorId { sql += " AND requesterId = ?"; args.append(actorId) }
                let (w, wa) = window("updatedAt"); sql += w; args += wa
                sql += " ORDER BY updatedAt DESC LIMIT \(limit)"
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                    var c = Candidate(ref: WorkRef(kind: .ask, id: String(row["number"] as Int)), kind: .ask, score: Self.listingScore)
                    c.at = row["updatedAt"]
                    out.append(c)
                }
            }
            // Item events: their text (a hit opens the item); the event's own mark and its writer's session decide its taint.
            if kinds.contains(.event), !listing || filters.actor != nil || filters.window != nil {
                var sql = """
                    SELECT e.id AS rowKey, e.actorId, e.kind, e.text, e.createdAt, e.taintedOrigin, w.key FROM workItemEvent e
                    JOIN workItem w ON w.id = e.itemId AND w.companyId = e.companyId WHERE e.companyId = ?
                    """
                var args: [DatabaseValueConvertible] = [companyId]
                let (cs, ca) = contains("e.text"); sql += cs; args += ca
                if let actorId { sql += " AND e.actorId = ?"; args.append(actorId) }
                // Ruling 58 (1): the newest `activityRows` events always, and the time window inside them.
                sql += """
                     AND e.id >= COALESCE((SELECT id FROM workItemEvent WHERE companyId = ? ORDER BY id DESC LIMIT 1 OFFSET \(Self.activityRows - 1)), 0)
                    """
                args.append(companyId)
                let (w, wa) = window("e.createdAt"); sql += w; args += wa
                try paged(sql, args, key: "e.id", group: SearchKind.event.group) { row in
                    let text: String = row["text"], key: String = row["key"], kind: String = row["kind"], actor: String = row["actorId"]
                    let at: Date = row["createdAt"]
                    let s = visibleScore(text)
                    guard s > 0 else { return nil }
                    var c = Candidate(ref: WorkRef(kind: .item, id: key), kind: .event, score: s)
                    c.title = "\(key) · \(kind)"
                    c.taintedTitle = c.title
                    c.at = at
                    let authorTainted = try Self.authorTainted(db, actor, at: at)
                    c.tainted = (row["taintedOrigin"] as Bool) || authorTainted
                    c.snippet = c.tainted ? nil : gate.snippet(text, around: q, max: Self.snippetMax)
                    return c
                }
            }
            // Runs: by item key, item title and status.
            if kinds.contains(.run) {
                var sql = """
                    SELECT r.id, r.status, r.createdAt, w.key, w.title FROM verificationRun r
                    JOIN workItem w ON w.id = r.itemId AND w.companyId = r.companyId WHERE r.companyId = ?
                    """
                var args: [DatabaseValueConvertible] = [companyId]
                if let status = filters.status {
                    let wanted = Self.runStatuses(status) ?? []
                    sql += wanted.isEmpty ? " AND 0" : " AND r.status IN (\(wanted.map { _ in "?" }.joined(separator: ", ")))"
                    args += wanted
                }
                let (w, wa) = window("r.createdAt"); sql += w; args += wa
                sql += " ORDER BY r.createdAt DESC, r.rowid DESC LIMIT \(limit)"
                if !listing || filters.status != nil || filters.window != nil {
                    for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                        let s = score("\(row["key"] as String) \(row["title"] as String) \(row["status"] as String)")
                        guard s > 0, let id = Optional(row["id"] as String), RefGrammar.isRecordId(id) else { continue }
                        var c = Candidate(ref: WorkRef(kind: .run, id: id), kind: .run, score: s)
                        c.at = row["createdAt"]
                        out.append(c)
                    }
                }
            }
            // Releases: version and notes.
            if kinds.contains(.release), !listing || filters.actor != nil || filters.window != nil {
                var sql = "SELECT number, version, status, notes, proposedById, createdAt FROM release WHERE companyId = ?"
                var args: [DatabaseValueConvertible] = [companyId]
                if let actorId { sql += " AND proposedById = ?"; args.append(actorId) }
                let (w, wa) = window("createdAt"); sql += w; args += wa
                sql += " ORDER BY number DESC LIMIT \(limit)"
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                    let notes: String = row["notes"] ?? ""
                    let s = score("\(row["version"] as String) \(row["status"] as String) \(notes)")
                    guard s > 0 else { continue }
                    let at: Date = row["createdAt"]
                    var c = Candidate(ref: WorkRef(kind: .release, id: String(row["number"] as Int)), kind: .release, score: s)
                    c.at = at
                    c.tainted = try Self.authorTainted(db, row["proposedById"], at: at)
                    c.snippet = notes.isEmpty || c.tainted ? nil : gate.snippet(notes, around: q, max: Self.snippetMax)
                    out.append(c)
                }
            }
            // Sprints: name and goal.
            if kinds.contains(.sprint), !listing || filters.window != nil {
                var sql = "SELECT number, team, goal, leadId, createdAt FROM sprint WHERE companyId = ?"
                var args: [DatabaseValueConvertible] = [companyId]
                let (w, wa) = window("createdAt"); sql += w; args += wa
                sql += " ORDER BY number DESC LIMIT \(limit)"
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                    let number: Int = row["number"], goal: String = row["goal"]
                    let s = score("Sprint \(number) sprint:\(number) \((row["team"] as String?) ?? "") \(goal)")
                    guard s > 0 else { continue }
                    let at: Date = row["createdAt"]
                    var c = Candidate(ref: WorkRef(kind: .sprint, id: String(number)), kind: .sprint, score: s)
                    c.at = at
                    let lead: String? = row["leadId"]
                    c.tainted = try lead.map { try Self.authorTainted(db, $0, at: at) } ?? false
                    c.snippet = c.tainted ? nil : gate.snippet(goal, around: q, max: Self.snippetMax)
                    out.append(c)
                }
            }
            // Previews: surface names, and the paths of their smoke requests.
            if kinds.contains(.preview), !listing {
                for surface in try PreviewSurface.fetchAll(db, sql: "SELECT * FROM previewSurface WHERE companyId = ? ORDER BY position",
                                                          arguments: [companyId]) {
                    let s = score("\(surface.name) \(surface.kind) preview")
                    if s > 0 { out.append(Candidate(ref: WorkRef(kind: .preview, id: surface.name), kind: .preview, score: s)) }
                    var paths = Set<String>()
                    for request in surface.smoke {
                        let path = String(request.path.prefix { $0 != "?" && $0 != "#" })
                        guard paths.insert(path).inserted, let params = PreviewRefParams.validate(path: path, viewport: nil) else { continue }
                        let ps = FuzzyScorer.words(folded, gate.matchText(path).split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "_" || $0 == " " })
                            .map { FuzzyScorer.Folded(String($0)) })
                        if ps > 0 { out.append(Candidate(ref: WorkRef(kind: .preview, id: surface.name, params: params), kind: .preview, score: ps)) }
                    }
                }
            }
            // Activity (the owner's alone): the newest 20 000 lines (narrowed by the window, if any); a hit opens its subject
            // (item, agent, release).
            if kinds.contains(.activity), reader == .owner, !listing || filters.actor != nil || filters.window != nil {
                var sql = "SELECT id AS rowKey, id, agentId, text, createdAt FROM activityEvent WHERE companyId = ?"
                var args: [DatabaseValueConvertible] = [companyId]
                // Ruling 58 (1): the newest `activityRows` lines always, and the time window inside them.
                sql += """
                     AND id >= COALESCE((SELECT id FROM activityEvent WHERE companyId = ? ORDER BY id DESC LIMIT 1 OFFSET \(Self.activityRows - 1)), 0)
                    """
                args.append(companyId)
                let (w, wa) = window("createdAt"); sql += w; args += wa
                if let actorId {
                    if actorId == "owner" { sql += " AND agentId IS NULL" } else { sql += " AND agentId = ?"; args.append(actorId) }
                }
                let (cs, ca) = contains("text"); sql += cs; args += ca
                let context = try refContext(db, companyId: companyId)
                try paged(sql, args, key: "id", group: SearchKind.activity.group) { row in
                    let text: String = row["text"], id: Int64 = row["id"]
                    let s = visibleScore(text)
                    guard s > 0 else { return nil }
                    var c = Candidate(ref: WorkRef(kind: .fact, id: "activity:\(id)"), kind: .activity, score: s)
                    c.title = text
                    c.subtitle = "activity"
                    c.at = row["createdAt"]
                    c.activityId = id
                    if let subject = RefScanner.scan(text, context: context).map(\.ref).first(where: { [.item, .agent, .release].contains($0.kind) }) {
                        c.ref = WorkRef(kind: subject.kind, id: subject.id)
                    } else {
                        c.inlineOnly = true
                    }
                    return c
                }
            }
        }
        return out
    }

    /// What a ref named in company text resolves against: the company's item key prefixes.
    func refContext(_ db: Database, companyId: String) throws -> RefContext {
        RefContext(companyId: companyId, keyPrefixes: try Self.keyPrefixes(db, companyId: companyId))
    }

    static func keyPrefixes(_ db: Database, companyId: String) throws -> Set<String> {
        var prefixes = Set(try String.fetchAll(db, sql: """
            SELECT DISTINCT substr(key, 1, instr(key, '-') - 1) FROM workItem WHERE companyId = ? AND instr(key, '-') > 1
            """, arguments: [companyId]))
        if let slug = try String.fetchOne(db, sql: "SELECT slug FROM company WHERE id = ?", arguments: [companyId]) {
            prefixes.insert(Store.keyPrefix(slug: slug))
        }
        return prefixes
    }

    /// Text `author` wrote at `at` came from a tainted session (the owner and the engine never do).
    static func authorTainted(_ db: Database, _ author: String?, at: Date) throws -> Bool {
        guard let author, author != "owner", author != "system", !author.isEmpty else { return false }
        return try Store.taintAt(db: db, agentId: author, at: at) != nil
    }

    // MARK: Statuses

    static func itemStatuses(_ s: String) -> [String]? {
        switch s {
        case "blocked": ["blocked"]
        case "open": ["backlog", "ready", "inProgress", "inReview", "blocked"]
        case "done": ["done"]
        case "in review": ["inReview"]
        default: nil
        }
    }

    static func askStatuses(_ s: String) -> [String]? {
        switch s {
        case "pending", "open": ["pendingInternal", "pendingOwner"]
        case "done": ["approved", "rejected", "answered"]
        default: nil
        }
    }

    static func runStatuses(_ s: String) -> [String]? {
        switch s {
        case "failing", "failed": ["failed", "timedOut", "error"]
        case "pending", "open": ["queued", "running"]
        case "done": ["passed"]
        default: nil
        }
    }

    static func agentStates(_ s: String) -> [String]? { s == "blocked" ? ["blocked"] : nil }

    // MARK: The reader's check

    /// The hit as `reader` may see it, or nil when the reader can't read it in full (or it no longer exists).
    private func verify(_ c: Candidate, companyId: String, reader: Reader) throws -> ShowHit? {
        if c.inlineOnly {
            guard reader == .owner else { return nil }
            return ShowHit(ref: c.ref, title: c.title ?? "", subtitle: c.subtitle ?? "", snippet: nil, at: c.at, group: c.kind.group,
                           score: c.score, kind: c.kind, inlineOnly: true)
        }
        var title: String, subtitle: String, tainted = c.tainted
        if c.light {
            let decision = try store.writer.read { db in
                try RefAccess.canRead(reader, c.ref, companyId: companyId, db: db, catalog: store.catalog)
            }
            guard case .allowed = decision else { return nil }
            // A taint check that fails reads as tainted (fail closed).
            let taint = (try? store.refTaint(c.ref, companyId: companyId))?.tainted ?? true
            tainted = tainted || taint
            title = c.title ?? c.ref.canonical
            subtitle = c.subtitle ?? ""
            if tainted { title = c.taintedTitle ?? title }
        } else {
            guard let resolved = try? store.resolveRef(c.ref, for: reader, companyId: companyId), resolved.visibility == .full else {
                // An activity line whose subject doesn't resolve is still the owner's line, shown inline.
                guard c.kind == .activity, reader == .owner else { return nil }
                var inline = c
                inline.inlineOnly = true
                inline.ref = WorkRef(kind: .fact, id: "activity:\(c.activityId ?? 0)")
                return try verify(inline, companyId: companyId, reader: reader)
            }
            tainted = tainted || resolved.tainted
            title = tainted ? (c.taintedTitle ?? resolved.title) : (c.title ?? resolved.title)
            subtitle = c.subtitle ?? resolved.subtitle
        }
        // Raw fields: `TextGate.hit` builds and gates each one's final string (Ruling 55).
        var snippet = c.snippet
        if tainted {
            snippet = nil
            subtitle = Self.taintedSubtitle
        }
        return ShowHit(ref: c.ref, title: title, subtitle: subtitle, snippet: snippet, at: c.at, group: c.kind.group, score: c.score, kind: c.kind)
    }
}

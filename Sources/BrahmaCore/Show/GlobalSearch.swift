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
    func search(companyId: String, scope: Reader, query: String, sources: Set<MemorySource>?, limit: Int, now: Date) throws -> [MemoryHit]
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
    /// The score of a row listed by its filters alone (no text): above the intent threshold, below every direct ref and phrase.
    static let listingScore = 0.7
    /// Rows a SQL source reads before the reader's access filters them.
    static let sqlCandidates = 200
    /// Candidates kept per group before access checks.
    static let groupCandidates = 60

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

    /// At most `limitPerGroup` hits per group, best first within each group, groups in `ShowGroup` order.
    public func search(_ rest: String, filters: SearchFilters, companyId: String, reader: Reader, limitPerGroup: Int) async throws -> [ShowHit] {
        let me = self
        return try await Self.blocking.tryRun {
            try me.searchNow(rest, filters: filters, companyId: companyId, reader: reader, limitPerGroup: limitPerGroup, now: Store.now()).hits
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
        var matchText: String? = nil
    }

    /// The search itself, synchronously (the `search` tool and `ShowResolver` call it on their own thread). `totals` are the
    /// owner's candidate counts per group; empty for every other reader.
    func searchNow(_ rest: String, filters: SearchFilters, companyId: String, reader: Reader, limitPerGroup: Int,
                   now: Date, git: GitState? = nil) throws -> (hits: [ShowHit], totals: [ShowGroup: Int]) {
        // A reader of another company is refused like any other read.
        _ = try ReaderContext.load(store: store, companyId: companyId, reader: reader)
        guard limitPerGroup > 0, let company = try store.company(id: companyId) else { return ([], [:]) }
        let text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        let listing = FuzzyScorer.foldQuery(text).count < FuzzyScorer.minQuery
            || text.split(whereSeparator: { $0.isWhitespace }).allSatisfy { FuzzyScorer.foldQuery(String($0)).count < FuzzyScorer.minQuery }
        if listing, filters.isEmpty { return ([], [:]) }
        let kinds = Self.kinds(filters, reader: reader)
        guard !kinds.isEmpty else { return ([], [:]) }
        var actorId: String? = nil
        if let actor = filters.actor {
            guard let id = try actorKey(actor, companyId: companyId) else { return ([], [:]) }   // no such agent: nothing is by them
            actorId = id
        }

        var found: [Candidate] = []
        let q = listing ? "" : text
        if !listing { found += try memoryCandidates(q, kinds: kinds, filters: filters, actorId: actorId, companyId: companyId, reader: reader, now: now) }
        found += try gitCandidates(q, kinds: kinds, filters: filters, company: company, state: git ?? gitState(company: company))
        found += try sqlCandidates(q, kinds: kinds, filters: filters, actorId: actorId, companyId: companyId, reader: reader)

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
            let titled = Set(list.filter { $0.kind == .item && (q.isEmpty || FuzzyScorer.words(q, $0.matchText ?? "") > 0) }.map(\.ref.canonical))
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
            if reader == .owner { totals[group] = list.count }
            var kept = 0
            for c in list.prefix(Self.groupCandidates) where kept < limitPerGroup {
                guard let hit = try verify(c, companyId: companyId, reader: reader) else { continue }
                hits.append(hit)
                kept += 1
            }
        }
        return (hits, totals)
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
    private func memoryCandidates(_ q: String, kinds: Set<SearchKind>, filters: SearchFilters, actorId: String?, companyId: String,
                                  reader: Reader, now: Date) throws -> [Candidate] {
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

        var out: [Candidate] = []
        for sources in calls {
            for hit in try memory.search(companyId: companyId, scope: reader, query: q, sources: sources, limit: MemoryPolicy.maxHits, now: now) {
                guard let found = try memoryRef(hit, companyId: companyId), kinds.contains(found.1) else { continue }
                let (ref, kind) = found
                if let w = filters.window, !w.contains(hit.updatedAt) { continue }
                if let actorId, hit.authorId != actorId { continue }
                var c = Candidate(ref: ref, kind: kind, score: 0.9 * max(hit.score, 0) / (max(hit.score, 0) + 1))
                c.snippet = hit.tainted ? nil : hit.snippet
                c.tainted = hit.tainted
                c.at = hit.updatedAt
                if kind == .message { c.subtitle = Self.flatten(hit.title, max: SafeTitle.max) }
                if hit.source == .item, !hit.tainted { c.matchText = hit.title }
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
    /// `FileIndexCache.headsTTL` seconds per set of leases).
    struct GitState {
        let git: SafeGit
        let heads: [String: String]
        var main: String { heads["main"] ?? "" }
    }

    /// Nil for a company without a readable repository (it simply has no files or commits to find).
    func gitState(company: Company) -> GitState? {
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        guard let git = try? store.refGit(workspace),
              let leased = try? store.writer.read({ db in
                  try String.fetchAll(db, sql: """
                      SELECT w.key FROM workLease l JOIN workItem w ON w.id = l.itemId AND w.companyId = l.companyId WHERE l.companyId = ?
                      ORDER BY w.key
                      """, arguments: [company.id])
              }) else { return nil }
        let key = company.id + "\u{0}" + leased.joined(separator: ",")
        if let cached = files.heads.get(key), Date().timeIntervalSince(cached.at) < FileIndexCache.headsTTL, cached.at <= Date() {
            return GitState(git: git, heads: cached.heads)
        }
        guard let main = try? git.head("main") else { return nil }
        var heads: [String: String] = ["main": main]
        if !leased.isEmpty, let items = try? git.branchHeads(prefix: "item/") {
            let set = Set(leased)
            for (branch, head) in items where set.contains(String(branch.dropFirst(5))) { heads[branch] = head }
        }
        files.heads.put(key, FileIndexCache.TimedHeads(at: Date(), heads: heads))
        return GitState(git: git, heads: heads)
    }

    private func gitCandidates(_ q: String, kinds: Set<SearchKind>, filters: SearchFilters, company: Company, state: GitState?) throws -> [Candidate] {
        let wantFiles = kinds.contains(.file) && !q.isEmpty
        let wantCommits = kinds.contains(.commit)
        guard wantFiles || wantCommits, let state else { return [] }
        let git = state.git, heads = state.heads, main = state.main
        var out: [Candidate] = []
        if wantFiles, let mainIndex = try? files.indexNow(companyId: company.id, branch: "main", head: main, git: git) {
            for f in mainIndex.scored(q, limit: Self.groupCandidates, where: nil) {
                out.append(fileCandidate(path: f.path, branch: nil, score: f.score, time: f.time, filters: filters))
            }
            for (branch, head) in heads.sorted(by: { $0.key < $1.key }) where branch != "main" {
                guard let index = try? files.indexNow(companyId: company.id, branch: branch, head: head, git: git) else { continue }
                // An item branch adds only what differs from main.
                for f in index.scored(q, limit: Self.groupCandidates, where: { index.sha(of: $0) != mainIndex.sha(of: $0) }) {
                    out.append(fileCandidate(path: f.path, branch: branch, score: f.score, time: f.time, filters: filters))
                }
            }
            if let w = filters.window { out.removeAll { $0.kind == .file && !($0.at.map(w.contains) ?? false) } }
        }
        if wantCommits, let index = try? commits.indexNow(companyId: company.id, heads: heads, git: git) {
            var diffs = Set<String>()
            for (c, score) in index.scored(q, filters: filters, limit: Self.groupCandidates, listingScore: Self.listingScore) {
                let short = String(c.sha.prefix(7))
                var cand = Candidate(ref: WorkRef(kind: .commit, id: c.sha), kind: .commit, score: score)
                cand.title = Self.flatten(c.subject, max: SafeTitle.max)
                cand.taintedTitle = "commit \(short)"
                cand.subtitle = "commit \(short) · @\(c.author) · \(c.branch)"
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
                               reader: Reader) throws -> [Candidate] {
        let listing = q.isEmpty
        let tokens = q.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count >= FuzzyScorer.minQuery }
        let folded = tokens.map(FuzzyScorer.foldQuery)
        func score(_ text: String) -> Double {
            listing ? Self.listingScore : FuzzyScorer.words(folded, text.split(whereSeparator: { $0.isWhitespace }).map { FuzzyScorer.Folded(String($0)) })
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
        try store.writer.read { db in
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
                        if !listing, name.hasPrefix(q.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: "")) {
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
                    c.snippet = c.tainted ? nil : text
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
                    SELECT e.actorId, e.kind, e.text, e.createdAt, e.taintedOrigin, w.key FROM workItemEvent e
                    JOIN workItem w ON w.id = e.itemId AND w.companyId = e.companyId WHERE e.companyId = ?
                    """
                var args: [DatabaseValueConvertible] = [companyId]
                let (cs, ca) = contains("e.text"); sql += cs; args += ca
                if let actorId { sql += " AND e.actorId = ?"; args.append(actorId) }
                let (w, wa) = window("e.createdAt"); sql += w; args += wa
                sql += " ORDER BY e.id DESC LIMIT \(limit)"
                for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                    let text: String = row["text"], key: String = row["key"], kind: String = row["kind"], actor: String = row["actorId"]
                    let at: Date = row["createdAt"]
                    let s = score(text)
                    guard s > 0 else { continue }
                    var c = Candidate(ref: WorkRef(kind: .item, id: key), kind: .event, score: s)
                    c.title = "\(key) · \(kind)"
                    c.taintedTitle = c.title
                    c.at = at
                    let authorTainted = try Self.authorTainted(db, actor, at: at)
                    c.tainted = (row["taintedOrigin"] as Bool) || authorTainted
                    c.snippet = c.tainted ? nil : text
                    out.append(c)
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
                    c.snippet = notes.isEmpty || c.tainted ? nil : notes
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
                    c.snippet = c.tainted ? nil : goal
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
                        let ps = FuzzyScorer.words(folded, path.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "_" }).map { FuzzyScorer.Folded(String($0)) })
                        if ps > 0 { out.append(Candidate(ref: WorkRef(kind: .preview, id: surface.name, params: params), kind: .preview, score: ps)) }
                    }
                }
            }
            // Activity (the owner's alone): the newest 20 000 lines, or the window; a hit opens its subject (item, agent, release).
            if kinds.contains(.activity), reader == .owner, !listing || filters.actor != nil || filters.window != nil {
                var sql = "SELECT id, agentId, text, createdAt FROM activityEvent WHERE companyId = ?"
                var args: [DatabaseValueConvertible] = [companyId]
                if let w = filters.window {
                    sql += " AND createdAt >= ? AND createdAt <= ?"; args += [w.start, w.end]
                } else {
                    sql += """
                         AND id >= COALESCE((SELECT id FROM activityEvent WHERE companyId = ? ORDER BY id DESC LIMIT 1 OFFSET \(Self.activityRows - 1)), 0)
                        """
                    args.append(companyId)
                }
                if let actorId {
                    if actorId == "owner" { sql += " AND agentId IS NULL" } else { sql += " AND agentId = ?"; args.append(actorId) }
                }
                let (cs, ca) = contains("text"); sql += cs; args += ca
                sql += " ORDER BY id DESC LIMIT \(limit)"
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                let context = try refContext(db, companyId: companyId)
                for row in rows {
                    let text: String = row["text"], id: Int64 = row["id"]
                    let s = score(text)
                    guard s > 0 else { continue }
                    var c = Candidate(ref: WorkRef(kind: .fact, id: "activity:\(id)"), kind: .activity, score: s)
                    c.title = Self.flatten(text, max: SafeTitle.max)
                    c.subtitle = "activity"
                    c.at = row["createdAt"]
                    c.activityId = id
                    if let subject = RefScanner.scan(text, context: context).map(\.ref).first(where: { [.item, .agent, .release].contains($0.kind) }) {
                        c.ref = WorkRef(kind: subject.kind, id: subject.id)
                    } else {
                        c.inlineOnly = true
                    }
                    out.append(c)
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
        var snippet = c.snippet.map { Self.flatten($0, max: Self.snippetMax) }
        if snippet?.isEmpty == true { snippet = nil }
        if tainted {
            snippet = nil
            subtitle = Self.taintedSubtitle
        }
        return ShowHit(ref: c.ref, title: Self.flatten(title, max: SafeTitle.max), subtitle: Self.flatten(subtitle, max: SafeTitle.max),
                       snippet: snippet, at: c.at, group: c.kind.group, score: c.score, kind: c.kind)
    }

    /// One line: NFC, hidden characters dropped, every run of whitespace (newlines included) one space, at most `max`
    /// characters (cut with `…`).
    static func flatten(_ s: String, max: Int) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in s.precomposedStringWithCanonicalMapping.unicodeScalars {
            let v = scalar.value
            if scalar.properties.isWhitespace || v == 0x0A || v == 0x09 || v == 0x0D { pendingSpace = true; continue }
            if RefText.isHidden(v) || v == 0x00AD || v == 0x180E { continue }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
        let text = String(out)
        return text.count > max ? String(text.prefix(max - 1)) + "\u{2026}" : text
    }
}

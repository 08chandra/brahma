import Foundation

/// One commit global search found.
public struct CommitHit: Equatable, Sendable {
    public var sha: String
    /// Agent-controlled text (flattened before it is shown).
    public var subject: String
    /// The author the engine can vouch for, never the commit's own (agent-settable) email: C4b, the handle of the agent whose
    /// turn the engine recorded making it (`turnCommit`); else `CommitIndex.unverified`.
    public var author: String
    public var at: Date
    /// `main` or `item/<KEY>` (a commit on both is `main`'s).
    public var branch: String

    public init(sha: String, subject: String, author: String, at: Date, branch: String) {
        self.sha = sha; self.subject = subject; self.author = author; self.at = at; self.branch = branch
    }
}

/// Plan C Task C4a: the newest `maxCommits` commits across `main` and the leased item branches (subject, author, date), built
/// once per set of branch heads with `SafeGit.commitLog`. An item branch contributes only what `main` does not have.
public struct CommitIndex: Sendable {
    public static let maxCommits = 2000

    let commits: [CommitHit]
    let words: [[FuzzyScorer.Folded]]
    /// Ruling 56: what an agent sees of a commit (`commit <sha7>`, its verified author, its branch), the only text an agent's
    /// query is matched against.
    let shownWords: [[FuzzyScorer.Folded]]
    let id: UUID
    /// Per stored-value set (`TextGate.fingerprint`): the commits whose subject holds a value, scored on blanked text (N-1).
    let secretMemo = SearchCacheStorage<Set<Int>>(capacity: 4)

    init(commits: [CommitHit]) {
        let sorted = commits.sorted { $0.at != $1.at ? $0.at > $1.at : $0.sha < $1.sha }
        self.commits = Array(sorted.prefix(Self.maxCommits))
        words = self.commits.map { c in (c.subject + " " + c.author).split(whereSeparator: { $0.isWhitespace }).map { FuzzyScorer.Folded(String($0)) } }
        shownWords = self.commits.map { c in
            ["commit", String(c.sha.prefix(7)), c.author == Self.unverified ? "unverified" : c.author, c.branch].map { FuzzyScorer.Folded($0) }
        }
        id = UUID()
    }

    public var count: Int { commits.count }

    /// No author the engine can vouch for (it matches no `by @…` filter).
    public static let unverified = ""

    /// `branches` by name (`main` among them; every other branch is listed from its merge with `main` on). `authors`: sha →
    /// the handle the engine recorded making it (`Store.recordedCommitAuthors`, C4b); every other commit is unverified.
    public static func build(git: SafeGit, branches: [String], authors: ([String]) throws -> [String: String] = { _ in [:] }) throws -> CommitIndex {
        var heads: [String: String] = [:]
        for b in branches { heads[b] = try git.head(b) }
        return try build(git: git, heads: heads, authors: authors)
    }

    static func build(git: SafeGit, heads: [String: String], authors: ([String]) throws -> [String: String]) throws -> CommitIndex {
        var found: [(entry: SafeGit.LogEntry, branch: String)] = []
        var seen = Set<String>()
        let main = heads["main"]
        func add(_ entries: [SafeGit.LogEntry], branch: String) {
            for e in entries where seen.insert(e.sha).inserted { found.append((e, branch)) }
        }
        if let main { add(try git.commitLog(tip: main, excluding: nil, max: maxCommits), branch: "main") }
        for (branch, head) in heads.sorted(by: { $0.key < $1.key }) where branch != "main" {
            add(try git.commitLog(tip: head, excluding: main, max: maxCommits), branch: branch)
        }
        let recorded = try authors(found.map(\.entry.sha))
        return CommitIndex(commits: found.map { e, branch in
            CommitHit(sha: e.sha, subject: e.subject, author: recorded[e.sha] ?? unverified,
                      at: Date(timeIntervalSince1970: TimeInterval(e.time)), branch: branch)
        })
    }

    /// Commits whose subject or author match `q` (each token against their words), filtered by `filters.actor` and
    /// `filters.window`; an empty `q` lists the newest that pass the filters (only when there is a filter).
    public func search(_ q: String, filters: SearchFilters, limit: Int) -> [CommitHit] {
        scored(q, filters: filters, limit: limit).map(\.hit)
    }

    /// `subjects`: false for a reader who is never shown the subject (an agent): only `shownWords` are matched.
    func scored(_ q: String, filters: SearchFilters, limit: Int, listingScore: Double = 0.7,
                gate: GlobalSearch.TextGate? = nil, subjects: Bool = true) -> [(hit: CommitHit, score: Double)] {
        guard limit > 0 else { return [] }
        let tokens = q.split(whereSeparator: { $0.isWhitespace }).map { FuzzyScorer.foldQuery(String($0)) }
            .filter { $0.count >= FuzzyScorer.minQuery }
        let listing = tokens.isEmpty
        if listing, filters.actor == nil, filters.window == nil { return [] }
        // N-1: a subject holding a stored value is matched with the value blanked, so no query finds its characters.
        var holding = Set<Int>()
        if let gate, !listing, subjects {
            if let known = secretMemo.get(gate.fingerprint) {
                holding = known
            } else {
                for (i, c) in commits.enumerated() where gate.holdsSecret(GlobalSearch.TextGate.display(c.subject, inert: false)) { holding.insert(i) }
                secretMemo.put(gate.fingerprint, holding)
            }
        }
        var out: [(hit: CommitHit, score: Double)] = []
        for (i, c) in commits.enumerated() {
            if let actor = filters.actor, c.author == Self.unverified || c.author != actor { continue }
            if let window = filters.window, !window.contains(c.at) { continue }
            let score: Double
            if listing {
                score = listingScore
            } else if !subjects {
                score = FuzzyScorer.words(tokens, shownWords[i])
            } else if holding.contains(i), let gate {
                score = FuzzyScorer.words(tokens, (gate.matchText(c.subject) + " " + c.author).split(whereSeparator: { $0.isWhitespace })
                    .map { FuzzyScorer.Folded(String($0)) })
            } else {
                score = FuzzyScorer.words(tokens, words[i])
            }
            guard score > 0 else { continue }
            out.append((c, score))
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.hit.at > $1.hit.at }
        return Array(out.prefix(limit))
    }
}

/// Built commit indexes, keyed by (companyId, `StableHash` of the branch heads and the attribution record's version). A build that failed is
/// remembered for `failureTTL` seconds, so a broken repository isn't read again on every keystroke.
public actor CommitIndexCache {
    public static let maxCached = 16
    public static let failureTTL: TimeInterval = 60

    nonisolated let storage = SearchCacheStorage<CommitIndex>(capacity: CommitIndexCache.maxCached)
    nonisolated let failures = SearchCacheStorage<Date>(capacity: 64)

    public init() {}

    /// `authorsVersion` changes whenever the engine records a commit (`Store.commitAuthorsVersion`), so attribution is never
    /// older than the record.
    public func index(companyId: String, heads: [String: String], authorsVersion: Int64 = 0,
                      authors: @Sendable ([String]) throws -> [String: String] = { _ in [:] }, git: SafeGit) throws -> CommitIndex {
        try indexNow(companyId: companyId, heads: heads, authorsVersion: authorsVersion, authors: authors, git: git)
    }

    nonisolated func indexNow(companyId: String, heads: [String: String], authorsVersion: Int64,
                              authors: ([String]) throws -> [String: String], git: SafeGit) throws -> CommitIndex {
        let text = heads.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" } + ["authors=\(authorsVersion)"]
        let key = companyId + "\u{0}" + StableHash.fnv1a64(text.joined(separator: "\n"))
        if let cached = storage.get(key) { return cached }
        if let failed = failures.get(key), Date().timeIntervalSince(failed) < Self.failureTTL { throw SearchIndexError.recentlyFailed }
        do {
            let built = try CommitIndex.build(git: git, heads: heads, authors: authors)
            storage.put(key, built)
            return built
        } catch {
            failures.put(key, Date())
            throw error
        }
    }
}

/// A search index that could not be built (or failed within its cache's failure TTL).
public enum SearchIndexError: Error, Equatable, Sendable {
    case recentlyFailed
}

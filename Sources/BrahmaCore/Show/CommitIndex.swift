import Foundation

/// One commit global search found.
public struct CommitHit: Equatable, Sendable {
    public var sha: String
    /// Agent-controlled text (flattened before it is shown).
    public var subject: String
    /// Fix round 1 (I-4): the author the engine can vouch for, never the commit's own (agent-settable) email: the handle of
    /// the item's lease holder for the commits on its branch since it claimed the lease; else `CommitIndex.unverified`.
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
    let id: UUID

    init(commits: [CommitHit]) {
        let sorted = commits.sorted { $0.at != $1.at ? $0.at > $1.at : $0.sha < $1.sha }
        self.commits = Array(sorted.prefix(Self.maxCommits))
        words = self.commits.map { c in (c.subject + " " + c.author).split(whereSeparator: { $0.isWhitespace }).map { FuzzyScorer.Folded(String($0)) } }
        id = UUID()
    }

    public var count: Int { commits.count }

    /// No author the engine can vouch for (it matches no `by @…` filter).
    public static let unverified = ""

    /// Who holds an item branch's lease, and the branch head when they claimed it (`WorkLease.claimHead`).
    public struct BranchHolder: Equatable, Sendable {
        public var handle: String
        public var since: String
        public init(handle: String, since: String) { self.handle = handle; self.since = since }
    }

    /// `branches` by name (`main` among them; every other branch is listed from its merge with `main` on). `holders`:
    /// item branch → its lease holder; their commits since the claim are theirs, every other author is unverified.
    public static func build(git: SafeGit, branches: [String], holders: [String: BranchHolder] = [:]) throws -> CommitIndex {
        var heads: [String: String] = [:]
        for b in branches { heads[b] = try git.head(b) }
        return try build(git: git, heads: heads, holders: holders)
    }

    static func build(git: SafeGit, heads: [String: String], holders: [String: BranchHolder]) throws -> CommitIndex {
        var found: [CommitHit] = []
        var seen = Set<String>()
        let main = heads["main"]
        func add(_ entries: [SafeGit.LogEntry], branch: String, held: Set<String>, holder: String?) {
            for e in entries where seen.insert(e.sha).inserted {
                found.append(CommitHit(sha: e.sha, subject: e.subject, author: held.contains(e.sha) ? (holder ?? unverified) : unverified,
                                       at: Date(timeIntervalSince1970: TimeInterval(e.time)), branch: branch))
            }
        }
        if let main { add(try git.commitLog(tip: main, excluding: nil, max: maxCommits), branch: "main", held: [], holder: nil) }
        for (branch, head) in heads.sorted(by: { $0.key < $1.key }) where branch != "main" {
            var held = Set<String>()
            if let holder = holders[branch] { held = Set((try? git.revList(holder.since, head)) ?? []) }
            add(try git.commitLog(tip: head, excluding: main, max: maxCommits), branch: branch, held: held, holder: holders[branch]?.handle)
        }
        return CommitIndex(commits: found)
    }

    /// Commits whose subject or author match `q` (each token against their words), filtered by `filters.actor` and
    /// `filters.window`; an empty `q` lists the newest that pass the filters (only when there is a filter).
    public func search(_ q: String, filters: SearchFilters, limit: Int) -> [CommitHit] {
        scored(q, filters: filters, limit: limit).map(\.hit)
    }

    func scored(_ q: String, filters: SearchFilters, limit: Int, listingScore: Double = 0.7) -> [(hit: CommitHit, score: Double)] {
        guard limit > 0 else { return [] }
        let tokens = q.split(whereSeparator: { $0.isWhitespace }).map { FuzzyScorer.foldQuery(String($0)) }
            .filter { $0.count >= FuzzyScorer.minQuery }
        let listing = tokens.isEmpty
        if listing, filters.actor == nil, filters.window == nil { return [] }
        var out: [(hit: CommitHit, score: Double)] = []
        for (i, c) in commits.enumerated() {
            if let actor = filters.actor, c.author == Self.unverified || c.author != actor { continue }
            if let window = filters.window, !window.contains(c.at) { continue }
            let score = listing ? listingScore : FuzzyScorer.words(tokens, words[i])
            guard score > 0 else { continue }
            out.append((c, score))
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.hit.at > $1.hit.at }
        return Array(out.prefix(limit))
    }
}

/// Built commit indexes, keyed by (companyId, `StableHash` of the branch heads and holders). A build that failed is
/// remembered for `failureTTL` seconds, so a broken repository isn't read again on every keystroke.
public actor CommitIndexCache {
    public static let maxCached = 16
    public static let failureTTL: TimeInterval = 60

    nonisolated let storage = SearchCacheStorage<CommitIndex>(capacity: CommitIndexCache.maxCached)
    nonisolated let failures = SearchCacheStorage<Date>(capacity: 64)

    public init() {}

    public func index(companyId: String, heads: [String: String], holders: [String: CommitIndex.BranchHolder] = [:], git: SafeGit) throws -> CommitIndex {
        try indexNow(companyId: companyId, heads: heads, holders: holders, git: git)
    }

    nonisolated func indexNow(companyId: String, heads: [String: String], holders: [String: CommitIndex.BranchHolder], git: SafeGit) throws -> CommitIndex {
        let text = heads.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            + holders.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value.handle):\($0.value.since)" }
        let key = companyId + "\u{0}" + StableHash.fnv1a64(text.joined(separator: "\n"))
        if let cached = storage.get(key) { return cached }
        if let failed = failures.get(key), Date().timeIntervalSince(failed) < Self.failureTTL { throw SearchIndexError.recentlyFailed }
        do {
            let built = try CommitIndex.build(git: git, heads: heads, holders: holders)
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

import Foundation

/// One commit global search found.
public struct CommitHit: Equatable, Sendable {
    public var sha: String
    /// Agent-controlled text (flattened before it is shown).
    public var subject: String
    /// The agent handle of an engine identity `<h>@<slug>.brahma.local`, `"engine"` for `engine@brahma.local`, else `"owner"`.
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

    /// `branches` by name (`main` first is not required: `main` is found among them, and every other branch is listed from
    /// its merge with `main` on).
    public static func build(git: SafeGit, branches: [String]) throws -> CommitIndex {
        var heads: [String: String] = [:]
        for b in branches { heads[b] = try git.head(b) }
        return try build(git: git, heads: heads)
    }

    static func build(git: SafeGit, heads: [String: String]) throws -> CommitIndex {
        var found: [CommitHit] = []
        var seen = Set<String>()
        let main = heads["main"]
        func add(_ entries: [SafeGit.LogEntry], branch: String) {
            for e in entries where seen.insert(e.sha).inserted {
                found.append(CommitHit(sha: e.sha, subject: e.subject, author: author(email: e.email),
                                       at: Date(timeIntervalSince1970: TimeInterval(e.time)), branch: branch))
            }
        }
        if let main { add(try git.commitLog(tip: main, excluding: nil, max: maxCommits), branch: "main") }
        for (branch, head) in heads.sorted(by: { $0.key < $1.key }) where branch != "main" {
            add(try git.commitLog(tip: head, excluding: main, max: maxCommits), branch: branch)
        }
        return CommitIndex(commits: found)
    }

    /// The author word for an email: `<h>@<anything>.brahma.local` with a handle `h` → `h`; `engine@brahma.local` → `engine`;
    /// anything else → `owner`.
    static func author(email: String) -> String {
        let e = email.lowercased()
        if e == "engine@brahma.local" { return "engine" }
        guard e.hasSuffix(".brahma.local"), let at = e.firstIndex(of: "@") else { return "owner" }
        let handle = String(e[..<at])
        return RefGrammar.isHandle(handle) && handle != "owner" && handle != "engine" ? handle : "owner"
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
            if let actor = filters.actor, c.author != actor { continue }
            if let window = filters.window, !window.contains(c.at) { continue }
            let score = listing ? listingScore : FuzzyScorer.words(tokens, words[i])
            guard score > 0 else { continue }
            out.append((c, score))
        }
        out.sort { $0.score != $1.score ? $0.score > $1.score : $0.hit.at > $1.hit.at }
        return Array(out.prefix(limit))
    }
}

/// Built commit indexes, keyed by (companyId, `StableHash` of the branch heads).
public actor CommitIndexCache {
    public static let maxCached = 16

    nonisolated let storage = SearchCacheStorage<CommitIndex>(capacity: CommitIndexCache.maxCached)

    public init() {}

    public func index(companyId: String, heads: [String: String], git: SafeGit) throws -> CommitIndex {
        try indexNow(companyId: companyId, heads: heads, git: git)
    }

    nonisolated func indexNow(companyId: String, heads: [String: String], git: SafeGit) throws -> CommitIndex {
        let key = companyId + "\u{0}" + StableHash.fnv1a64(heads.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        if let cached = storage.get(key) { return cached }
        let built = try CommitIndex.build(git: git, heads: heads)
        storage.put(key, built)
        return built
    }
}

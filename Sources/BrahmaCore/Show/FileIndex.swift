import Foundation

/// Plan C Task C4a: the Show bar's fuzzy scorer, fzf-style over lowercase ASCII-folded text. Files score whole paths; commit
/// subjects, agent names and titles score each query token against the words of the text (`words`).
///
/// For one alignment of the query as a subsequence (the best over every start of its first character, greedy forward):
/// - +1 per matched character; +8 when the match starts the basename (the word, for `words`);
/// - +4 per match at a segment start (the start, or after `/ _ - .` or a space, or a lower→upper case change);
/// - +3 per character in a consecutive run beyond the first; +10 when the whole query is one consecutive run (an exact
///   substring outranks a scattered match: C4a's addition, so `src/checkout/old/notes.md` beats `tests/check_out.py` for
///   `checkout`);
/// - −0.1 per unmatched character before the first match (at most −3).
/// `normalized = base / (8 + 5 × len(query))`, clamped to 0…0.95 (fuzzy never beats a direct ref). Not a subsequence: 0.
public enum FuzzyScorer {
    public static let maxScore = 0.95
    /// Query tokens shorter than this are not searched (a single character matches almost everything).
    public static let minQuery = 2

    /// A string prepared once: folded bytes and segment-start flags.
    struct Folded: Sendable {
        var bytes: [UInt8]
        var segment: [Bool]
        /// Where the basename (after the last `/`) starts.
        var basename: Int

        init(_ s: String) {
            var bytes: [UInt8] = []
            var segment: [Bool] = []
            bytes.reserveCapacity(s.utf8.count)
            segment.reserveCapacity(s.utf8.count)
            var previousLower = false
            var previousByte: UInt8? = nil
            for scalar in s.unicodeScalars {
                let folded: [UInt8]
                if scalar.isASCII {
                    folded = [UInt8(scalar.value)]
                } else {
                    let f = String(scalar).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
                    let ascii = f.unicodeScalars.filter(\.isASCII).map { UInt8($0.value) }
                    folded = ascii.isEmpty ? [0xFF] : ascii
                }
                let isUpper = scalar.properties.isUppercase
                let start: Bool
                if let p = previousByte {
                    start = Self.separators.contains(p) || (isUpper && previousLower)
                } else {
                    start = true
                }
                for (i, b) in folded.enumerated() {
                    bytes.append((0x41...0x5A).contains(b) ? b + 32 : b)
                    segment.append(i == 0 && start)
                }
                previousLower = scalar.properties.isLowercase
                previousByte = folded.last
            }
            self.bytes = bytes
            self.segment = segment
            basename = (bytes.lastIndex(of: 0x2F).map { $0 + 1 }) ?? 0
        }

        static let separators: Set<UInt8> = [0x2F, 0x5F, 0x2D, 0x2E, 0x20]
    }

    /// The query folded the same way (no segment data).
    static func foldQuery(_ q: String) -> [UInt8] {
        Folded(q.trimmingCharacters(in: .whitespacesAndNewlines)).bytes
    }

    /// The raw (unnormalized) base score of `q` over `t`, or nil when `q` is not a subsequence.
    static func base(_ q: [UInt8], _ t: Folded) -> Double? {
        guard !q.isEmpty, q.count <= t.bytes.count else { return nil }
        var positions = [Int](repeating: 0, count: q.count)
        return t.bytes.withUnsafeBufferPointer { tb in
            t.segment.withUnsafeBufferPointer { sb in
                q.withUnsafeBufferPointer { qb in
                    base(qb, tb, sb, lower: 0, upper: tb.count, basename: t.basename, positions: &positions)
                }
            }
        }
    }

    /// The core, over `t[lower..<upper]` of shared buffers (`basename` an index into them); `positions` holds at least
    /// `q.count` slots (reused across calls).
    @inline(__always)
    static func base(_ qb: UnsafeBufferPointer<UInt8>, _ tb: UnsafeBufferPointer<UInt8>, _ sb: UnsafeBufferPointer<Bool>, lower: Int,
                     upper: Int, basename: Int, positions: inout [Int]) -> Double? {
        let m = qb.count
        guard m > 0, m <= upper - lower else { return nil }
        // Not a subsequence at all: no alignment to score (the common case).
        var probe = 0
        var i = lower
        while i < upper {
            if tb[i] == qb[probe] {
                probe += 1
                if probe == m { break }
            }
            i += 1
        }
        guard probe == m else { return nil }
        var best: Double? = nil
        var start = lower
        while start < upper {
            guard tb[start] == qb[0] else { start += 1; continue }
            var j = 0
            var k = start
            while k < upper, j < m {
                if tb[k] == qb[j] { positions[j] = k; j += 1 }
                k += 1
            }
            // A later start sees a suffix of this text: if this one fails, every later one does.
            guard j == m else { break }
            var score = Double(m)
            if positions[0] == basename { score += 8 }
            var consecutive = 0
            for x in 0..<m {
                if sb[positions[x]] { score += 4 }
                if x > 0, positions[x] == positions[x - 1] + 1 { consecutive += 1 }
            }
            score += 3 * Double(consecutive)
            if consecutive == m - 1, m > 1 { score += 10 }
            score -= min(3, 0.1 * Double(positions[0] - lower))
            if best == nil || score > best! { best = score }
            start += 1
        }
        return best
    }

    /// A bit per character class a folded string holds: a query whose bits are not all in a text's can't match it.
    static func mask<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var m: UInt64 = 0
        for b in bytes {
            switch b {
            case 0x61...0x7A: m |= 1 << UInt64(b - 0x61)
            case 0x30...0x39: m |= 1 << UInt64(26 + b - 0x30)
            default: m |= 1 << UInt64(36 + Int(b) % 28)
            }
        }
        return m
    }

    static func normalize(_ base: Double, queryLength: Int) -> Double {
        min(maxScore, max(0, base / (8 + 5 * Double(queryLength))))
    }

    /// `q` against a path (or any single string).
    public static func score(_ q: String, _ text: String) -> Double {
        let query = foldQuery(q)
        guard query.count >= minQuery, let b = base(query, Folded(text)) else { return 0 }
        return normalize(b, queryLength: query.count)
    }

    /// Each query token (at least `minQuery` long; shorter ones are dropped) against the best word of `text`, averaged; 0 when
    /// any token matches no word.
    public static func words(_ q: String, _ text: String) -> Double {
        let tokens = q.split(whereSeparator: { $0.isWhitespace }).map { foldQuery(String($0)) }.filter { $0.count >= minQuery }
        guard !tokens.isEmpty else { return 0 }
        let folded = text.split(whereSeparator: { $0.isWhitespace }).map { Folded(String($0)) }
        return words(tokens, folded)
    }

    static func words(_ tokens: [[UInt8]], _ words: [Folded]) -> Double {
        guard !tokens.isEmpty else { return 0 }
        var total = 0.0
        for token in tokens {
            var best = 0.0
            for word in words {
                if let b = base(token, word) { best = max(best, normalize(b, queryLength: token.count)) }
            }
            guard best > 0 else { return 0 }
            total += best
        }
        return total / Double(tokens.count)
    }
}

/// One file the index found.
public struct FileHit: Equatable, Sendable {
    public var path: String
    public var branch: String
    public var score: Double

    public init(path: String, branch: String, score: Double) { self.path = path; self.branch = branch; self.score = score }
}

/// The paths of one branch's tree (`SafeGit.lsTree`), with the newest of the last `recencyCommits` commits touching each
/// (`SafeGit.recentPaths`). Built off the caller's actor; immutable once built.
public struct FileIndex: Sendable {
    public static let maxEntries = 200_000
    public static let recencyCommits = 500

    public let treeSha: String
    public let truncated: Bool
    /// The branch the hits name (an index is shared by every branch with the same tree).
    public private(set) var branch: String
    /// This build (an index taken from the cache is the same build).
    let id: UUID
    let storage: Storage

    final class Storage: Sendable {
        let paths: [String]
        /// Every path folded, back to back (`offsets[i]..<offsets[i + 1]`), with its segment starts, basename start and mask.
        let bytes: [UInt8]
        let segment: [Bool]
        let offsets: [Int]
        let basenames: [Int]
        let masks: [UInt64]
        /// Path → blob sha (empty for test indexes).
        let shas: [String: String]
        let recency: [Int]

        init(paths: [String], shas: [String: String], recency: [String: Int]) {
            self.paths = paths
            var bytes: [UInt8] = [], segment: [Bool] = [], offsets: [Int] = [0], basenames: [Int] = [], masks: [UInt64] = []
            offsets.reserveCapacity(paths.count + 1)
            for p in paths {
                let f = FuzzyScorer.Folded(p)
                basenames.append(bytes.count + f.basename)
                masks.append(FuzzyScorer.mask(f.bytes))
                bytes += f.bytes
                segment += f.segment
                offsets.append(bytes.count)
            }
            self.bytes = bytes; self.segment = segment; self.offsets = offsets; self.basenames = basenames; self.masks = masks
            self.shas = shas
            self.recency = paths.map { recency[$0] ?? 0 }
        }
    }

    public var count: Int { storage.paths.count }

    init(treeSha: String, branch: String, paths: [String], shas: [String: String], recency: [String: Int], truncated: Bool) {
        self.treeSha = treeSha
        self.branch = branch
        self.truncated = truncated || paths.count > Self.maxEntries
        id = UUID()
        storage = Storage(paths: Array(paths.prefix(Self.maxEntries)), shas: shas, recency: recency)
    }

    /// Tests: an index of these paths (capped like a real one).
    init(testPaths: [String], recency: [String: Int] = [:], branch: String = "main") {
        self.init(treeSha: "test", branch: branch, paths: testPaths, shas: [:], recency: recency, truncated: false)
    }

    /// The tree at `branch`'s head.
    public static func build(git: SafeGit, branch: String) throws -> FileIndex {
        let head = try git.head(branch)
        return try build(git: git, branch: branch, head: head, treeSha: try git.treeSha(commit: head))
    }

    static func build(git: SafeGit, branch: String, head: String, treeSha: String, cap: Int = maxEntries) throws -> FileIndex {
        let listing = try git.lsTree(rev: head, cap: cap)
        var paths: [String] = []
        var shas: [String: String] = [:]
        paths.reserveCapacity(listing.entries.count)
        // Only paths a ref can name (`RefGrammar.isPath`): nothing else could be opened, and no control character reaches a hit.
        for entry in listing.entries where entry.mode != "160000" && RefGrammar.isPath(entry.path) {
            paths.append(entry.path)
            shas[entry.path] = entry.sha
        }
        let recency = try git.recentPaths(rev: head, commits: recencyCommits)
        return FileIndex(treeSha: treeSha, branch: branch, paths: paths, shas: shas, recency: recency, truncated: listing.truncated)
    }

    func on(branch: String) -> FileIndex {
        var copy = self
        copy.branch = branch
        return copy
    }

    /// The blob of `path` in this tree.
    func sha(of path: String) -> String? { storage.shas[path] }

    /// The best `limit` paths for `q`; ties: newer `recentPaths` time, then shorter path, then lexicographic.
    public func search(_ q: String, limit: Int) -> [FileHit] {
        scored(q, limit: limit, where: nil).map { FileHit(path: $0.path, branch: branch, score: $0.score) }
    }

    /// The best `limit` entries passing `include` (by index), with their recency.
    /// `excluding`: checked on the ranked entries only, skipped without taking a place (a path a reader is never shown
    /// neither ranks nor displaces another: Ruling 56).
    func scored(_ q: String, limit: Int, where include: ((String) -> Bool)?,
                excluding exclude: ((String) -> Bool)? = nil) -> [(path: String, score: Double, time: Int)] {
        let query = FuzzyScorer.foldQuery(q)
        guard query.count >= FuzzyScorer.minQuery, limit > 0 else { return [] }
        var found: [(i: Int, base: Double)] = []
        let s = storage
        let qmask = FuzzyScorer.mask(query)
        var positions = [Int](repeating: 0, count: query.count)
        s.bytes.withUnsafeBufferPointer { tb in
            s.segment.withUnsafeBufferPointer { sb in
                query.withUnsafeBufferPointer { qb in
                    for i in 0..<s.paths.count where s.masks[i] & qmask == qmask {
                        guard let b = FuzzyScorer.base(qb, tb, sb, lower: s.offsets[i], upper: s.offsets[i + 1], basename: s.basenames[i],
                                                       positions: &positions) else { continue }
                        if let include, !include(s.paths[i]) { continue }
                        found.append((i, b))
                    }
                }
            }
        }
        found.sort { a, b in
            if a.base != b.base { return a.base > b.base }
            let (ra, rb) = (s.recency[a.i], s.recency[b.i])
            if ra != rb { return ra > rb }
            let (pa, pb) = (s.paths[a.i], s.paths[b.i])
            if pa.utf8.count != pb.utf8.count { return pa.utf8.count < pb.utf8.count }
            return pa < pb
        }
        var out: [(path: String, score: Double, time: Int)] = []
        for f in found where out.count < limit {
            if let exclude, exclude(s.paths[f.i]) { continue }
            out.append((s.paths[f.i], FuzzyScorer.normalize(f.base, queryLength: query.count), s.recency[f.i]))
        }
        return out
    }
}

/// Built file indexes, keyed by (companyId, treeSha): one company never sees another's, and a new tree is a new build. A
/// branch head's tree is remembered per (companyId, head).
public actor FileIndexCache {
    public static let maxCached = 16

    /// Branch heads are read again after this many seconds (typing runs a query per keystroke; one git call per query is
    /// enough, none is better).
    public static let headsTTL: TimeInterval = 2

    /// A build that failed is remembered this long (a repository whose listing breaks a cap isn't listed per keystroke).
    public static let failureTTL: TimeInterval = 60

    nonisolated let storage = SearchCacheStorage<FileIndex>(capacity: FileIndexCache.maxCached)
    nonisolated let trees = SearchCacheStorage<String>(capacity: 256)
    nonisolated let heads = SearchCacheStorage<TimedHeads>(capacity: 64)
    nonisolated let failures = SearchCacheStorage<Date>(capacity: 64)
    /// `FileIndex.maxEntries`; tests lower it.
    nonisolated let entryCap: Int

    public init() { entryCap = FileIndex.maxEntries }

    init(entryCap: Int) { self.entryCap = entryCap }

    struct TimedHeads: Sendable {
        var at: Date
        var heads: [String: String]
    }

    public func index(companyId: String, branch: String, git: SafeGit) throws -> FileIndex {
        try indexNow(companyId: companyId, branch: branch, head: try git.head(branch), git: git)
    }

    /// The same, synchronously, for a head the caller already read (the search core and the `search` tool).
    nonisolated func indexNow(companyId: String, branch: String, head: String, git: SafeGit) throws -> FileIndex {
        let treeKey = companyId + "\u{0}" + head
        if let failed = failures.get(treeKey), Date().timeIntervalSince(failed) < Self.failureTTL { throw SearchIndexError.recentlyFailed }
        do {
            let tree: String
            if let known = trees.get(treeKey) {
                tree = known
            } else {
                tree = try git.treeSha(commit: head)
                trees.put(treeKey, tree)
            }
            let key = companyId + "\u{0}" + tree
            if let cached = storage.get(key) { return cached.on(branch: branch) }
            let built = try FileIndex.build(git: git, branch: branch, head: head, treeSha: tree, cap: entryCap)
            storage.put(key, built)
            return built
        } catch {
            failures.put(treeKey, Date())
            throw error
        }
    }
}

/// A small LRU map behind a lock (the search caches' storage, usable from any thread).
final class SearchCacheStorage<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]
    private var order: [String] = []
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func get(_ key: String) -> Value? {
        lock.withLock {
            guard let v = values[key] else { return nil }
            if let i = order.firstIndex(of: key) { order.remove(at: i) }
            order.append(key)
            return v
        }
    }

    func put(_ key: String, _ value: Value) {
        lock.withLock {
            if values[key] == nil, values.count >= capacity, let oldest = order.first {
                order.removeFirst()
                values[oldest] = nil
            }
            values[key] = value
            if let i = order.firstIndex(of: key) { order.remove(at: i) }
            order.append(key)
        }
    }
}

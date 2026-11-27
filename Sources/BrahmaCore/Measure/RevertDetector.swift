import Foundation

/// One landed item's change, as the revert detector reads it (ruling R17): the diff `base..merged`, where `merged` is the item's
/// merged commit and `base` its first parent (`<merged>^1`; in a batch of several items, the previous candidate), never
/// `mergeRequest.baseCommit`, which is the batch's base.
public struct LandedRange: Equatable, Sendable {
    public var itemId: String
    public var base: String
    public var merged: String
    public var landedAt: Date

    public init(itemId: String, base: String, merged: String, landedAt: Date) {
        self.itemId = itemId; self.base = base; self.merged = merged; self.landedAt = landedAt
    }

    /// `base` = `<merged>^1` (ruling R17).
    public init(itemId: String, merged: String, landedAt: Date) {
        self.init(itemId: itemId, base: "\(merged)^1", merged: merged, landedAt: landedAt)
    }
}

/// Finds landed changes that a later landing undid exactly (`docs/measure/metrics.md`, "revert"): landed item L is reverted by a
/// later landing R within the lookback when the stable patch-id of L's inverse diff (`git diff <merged> <base>`) equals the
/// patch-id of R's forward diff (`git diff <base'> <merged'>`). Partial reverts are not claimed here; only a `revertOf` link
/// finds them.
///
/// Patch-ids come from `git diff <a> <b> | git patch-id --stable`, both through `GitCommand` (the workspace's own hardened git,
/// its common dir, an absolute git), each call limited to `Limits.gitCallSeconds`. They are cached for the detector's life: one
/// detector per `measure` run. The scan is bounded: at most `Limits.maxItems` landed items (the oldest first), and it stops at
/// the first git call over its time limit; either way `Scan.basis` says `revert scan stopped at <bound>`.
public final class RevertDetector {
    public struct Limits: Equatable, Sendable {
        /// Landed items scanned per run, oldest first.
        public var maxItems: Int
        /// The most one git call may take; a call over it stops the scan.
        public var gitCallSeconds: TimeInterval
        /// How long after a landing a later landing can still be its revert.
        public var lookback: TimeInterval

        public init(maxItems: Int, gitCallSeconds: TimeInterval, lookback: TimeInterval) {
            self.maxItems = maxItems; self.gitCallSeconds = gitCallSeconds; self.lookback = lookback
        }

        /// Plan X6a's pinned bounds: 2000 landed items, 10 s per git call, 30 days (the longest revert-rate row).
        public static let standard = Limits(maxItems: 2000, gitCallSeconds: 10, lookback: 30 * 86_400)
    }

    /// `by` landed after `reverted` and undid it exactly.
    public struct Pair: Equatable, Sendable {
        public var reverted: String
        public var by: String
        public init(reverted: String, by: String) { self.reverted = reverted; self.by = by }
    }

    /// What one scan found and what it could not look at.
    public struct Scan: Equatable, Sendable {
        public var pairs: [Pair]
        /// Items whose two patch-ids are known (an empty diff has none and pairs with nothing).
        public var scanned: Set<String>
        /// Items git could not read (a commit missing from the repository, a diff over the capture limit), in landing order.
        public var unreadable: [String]
        /// Items past a bound, in landing order.
        public var notScanned: [String]
        /// The bound the scan stopped at (`2000 landed items`, `a git call over 10 s`); nil when it ran to the end.
        public var stoppedAt: String?

        /// `revert scan stopped at <bound>`, or nil.
        public var basis: String? { stoppedAt.map { "revert scan stopped at \($0)" } }
    }

    /// Why a patch-id is not known.
    public enum SourceError: Error, Equatable, CustomStringConvertible {
        /// One git call ran past `Limits.gitCallSeconds`: the scan stops.
        case timedOut
        /// This one range cannot be read (a missing commit, a diff too large to capture): the item is unreadable.
        case unreadable(String)
        /// Nothing can be read (no repository; the engine refuses the repository's config): the scan cannot run at all.
        case unavailable(String)

        public var description: String {
            switch self {
            case .timedOut: return "a git call timed out"
            case .unreadable(let why): return why
            case .unavailable(let why): return why
            }
        }
    }

    /// The stable patch-id of the diff `from..to`, nil for an empty diff. Throws `SourceError`.
    public typealias PatchIdSource = (_ from: String, _ to: String) throws -> String?

    public let limits: Limits
    private let source: PatchIdSource
    /// `from \0 to` → patch-id (nil: empty diff). Only answers are cached; a failure is asked again next run.
    private var cache: [String: String?] = [:]

    /// The detector over the company's own workspace repository.
    public convenience init(git: GitWorkspace, limits: Limits = .standard) {
        self.init(limits: limits, source: Self.gitSource(git, seconds: limits.gitCallSeconds))
    }

    /// The seam the unit tests use: patch-ids from `source`, no git.
    init(limits: Limits, source: @escaping PatchIdSource) {
        self.limits = limits
        self.source = source
    }

    /// Scans `landed` (any order; scanned oldest first) and pairs each landed item with the earliest later landing that is its
    /// exact inverse within `limits.lookback`. Throws only `SourceError.unavailable` (nothing could be read).
    public func inversePairs(_ landed: [LandedRange]) throws -> Scan {
        let ordered = Self.ordered(landed)
        var forward: [String: String] = [:], inverse: [String: String] = [:]
        var scanned: [LandedRange] = []
        var unreadable: [String] = [], notScanned: [String] = []
        var stoppedAt: String? = nil
        for (index, range) in ordered.enumerated() {
            if index >= limits.maxItems {
                stoppedAt = "\(limits.maxItems) landed items"
                notScanned = ordered[index...].map(\.itemId)
                break
            }
            do {
                let back = try patchId(from: range.merged, to: range.base)
                let ahead = try patchId(from: range.base, to: range.merged)
                if let back { inverse[range.itemId] = back }
                if let ahead { forward[range.itemId] = ahead }
                scanned.append(range)
            } catch SourceError.timedOut {
                stoppedAt = "a git call over \(MetricValue.plain(limits.gitCallSeconds)) s"
                notScanned = ordered[index...].map(\.itemId)
                break
            } catch let error as SourceError {
                if case .unavailable = error { throw error }
                unreadable.append(range.itemId)
            }
        }
        return Scan(pairs: Self.pair(scanned, forward: forward, inverse: inverse, lookback: limits.lookback),
                    scanned: Set(scanned.map(\.itemId)), unreadable: unreadable, notScanned: notScanned, stoppedAt: stoppedAt)
    }

    /// The pure pairing: for each landed item L (by landing time), the earliest later landing R with `forward[R] == inverse[L]`
    /// and `R.landedAt - L.landedAt <= lookback`. An item with no patch-id (an empty diff, or not scanned) pairs with nothing.
    static func pair(_ landed: [LandedRange], forward: [String: String], inverse: [String: String], lookback: TimeInterval) -> [Pair] {
        let ordered = ordered(landed)
        var pairs: [Pair] = []
        for (i, l) in ordered.enumerated() {
            guard let undo = inverse[l.itemId] else { continue }
            let by = ordered[(i + 1)...].first { r in
                r.itemId != l.itemId && r.landedAt.timeIntervalSince(l.landedAt) <= lookback && forward[r.itemId] == undo
            }
            if let by { pairs.append(Pair(reverted: l.itemId, by: by.itemId)) }
        }
        return pairs
    }

    /// By landing time; ties keep the order given (one batch's items land together, in `landedIds` order).
    static func ordered(_ landed: [LandedRange]) -> [LandedRange] {
        landed.enumerated().sorted { a, b in
            a.element.landedAt != b.element.landedAt ? a.element.landedAt < b.element.landedAt : a.offset < b.offset
        }.map(\.element)
    }

    private func patchId(from: String, to: String) throws -> String? {
        let key = "\(from)\u{0}\(to)"
        if let hit = cache[key] { return hit }
        let id = try source(from, to)
        cache[key] = .some(id)
        return id
    }

    // MARK: Git

    /// A commit id as the store records it, optionally with `^1` (R17's base): nothing git could read as an option or a path.
    static func isRevision(_ s: String) -> Bool {
        s.range(of: "^[0-9a-f]{7,64}(\\^1)?$", options: .regularExpression) != nil
    }

    /// `git diff --no-color --no-ext-diff --no-textconv <from> <to> --`, then that diff on the stdin of `git patch-id --stable`,
    /// through the workspace's own `GitCommand` (`main`: its git dir is the common dir) with `seconds` per call.
    static func gitSource(_ workspace: GitWorkspace, seconds: TimeInterval) -> PatchIdSource {
        var git = workspace.main
        git.timeoutSeconds = seconds
        let command = git
        let gitDir = workspace.gitDir
        return { from, to in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SourceError.unavailable("the company workspace has no repository")
            }
            guard isRevision(from), isRevision(to) else { throw SourceError.unreadable("not a commit id") }
            let diff = try run(command, ["diff", "--no-color", "--no-ext-diff", "--no-textconv", from, to, "--"], stdin: .none)
            guard !diff.isEmpty else { return nil }
            let out = try run(command, ["patch-id", "--stable"], stdin: .data(diff))
            // `<patch-id> <commit-id>`; the commit is all zeros for a diff with no commit header.
            return String(decoding: out, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
    }

    /// One git call's stdout, or the `SourceError` it amounts to.
    static func run(_ git: GitCommand, _ args: [String], stdin: GitCommand.Stdin) throws -> Data {
        let out: GitCommand.Output
        do {
            out = try git.run(args, allowFailure: true, stdin: stdin)
        } catch let error as GitError where error.isRepositoryRefusal {
            throw SourceError.unavailable("\(error)")
        } catch {
            throw SourceError.unreadable("\(error)")
        }
        if out.timedOut { throw SourceError.timedOut }
        guard out.status == 0 else { throw SourceError.unreadable("git \(args[0]) exited \(out.status)") }
        guard !out.cut else { throw SourceError.unreadable("git \(args[0]) output over the capture limit") }
        return out.stdout
    }
}

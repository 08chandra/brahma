import Foundation

/// What one push carries: filed with the `push-branch` request and shown on the owner's card (`diffstat`, `paths`).
public struct PushPayload: Codable, Equatable, Sendable {
    /// The verified commit pushed (40 hex).
    public var sha: String
    /// `refs/heads/brahma/<KEY>-<slug>`.
    public var ref: String
    /// `https://github.com/<owner>/<repo>.git`.
    public var url: String
    public var itemKey: String
    /// `git diff --shortstat` of `base..sha` (` 3 files changed, 10 insertions(+), 2 deletions(-)`).
    public var diffstat: String
    /// The changed paths, sorted, at most `PrePushScan.maxPaths` (agent-named: quote before showing).
    public var paths: [String]
    /// Some changed path, shown or not, is under `.github/workflows/`.
    public var touchesWorkflows: Bool

    public init(sha: String, ref: String, url: String, itemKey: String, diffstat: String, paths: [String], touchesWorkflows: Bool) {
        self.sha = sha; self.ref = ref; self.url = url; self.itemKey = itemKey
        self.diffstat = diffstat; self.paths = paths; self.touchesWorkflows = touchesWorkflows
    }
}

/// Where a push goes: the item, the branch's full ref and the repository URL.
public struct PushTarget: Equatable, Sendable {
    public var itemKey: String
    public var ref: String
    public var url: String

    public init(itemKey: String, ref: String, url: String) { self.itemKey = itemKey; self.ref = ref; self.url = url }
}

/// The blob-pointer check (Plan X3a's `BlobPointer.scan` conforms once it exists): the paths in the tree at `sha` that are
/// pointers to large blobs kept outside git, which must never reach GitHub as pointers.
public protocol BlobPointerScanning: Sendable {
    func pointers(inTreeAt sha: String, repo: URL) throws -> [String]
}

/// The stand-in for X3a's blob pointers, which this tree does not have: no repository holds one, so none is found.
public struct NoBlobPointers: BlobPointerScanning {
    public init() {}
    public func pointers(inTreeAt sha: String, repo: URL) throws -> [String] { [] }
}

/// The scans the engine runs immediately before every push, before any `PRActionRequest` is filed (spec §8.5.1, §9.4): the
/// secret scan over `base..head` (`SecretScan`: every commit's added lines, the endpoint diff, the messages) and the
/// blob-pointer check over the tree at `head`. Any hit refuses, listing where; a clean change becomes the push's payload.
public enum PrePushScan {
    public static let maxPaths = 500
    /// How many places a refusal names before `and N more`.
    static let maxListed = 10

    /// `base` is the remote `main` the change was rebased onto; `head` the verified commit.
    public static func run(target: PushTarget, base: String, head: String, git: GitWorkspace, blobs: any BlobPointerScanning,
                           knownValues: [(String, String)]) throws -> PRDecision<PushPayload> {
        let findings = try SecretScan.checkFindings(git: git, base: base, head: head, knownValues: knownValues)
        if !findings.isEmpty {
            return .refused("secret scan: \(findings.count) hit\(findings.count == 1 ? "" : "s") (\(listed(findings.map(\.place))))")
        }
        let pointers = try blobs.pointers(inTreeAt: head, repo: git.root)
        if !pointers.isEmpty {
            return .refused("blob pointers: \(pointers.count) (\(listed(pointers)))")
        }
        let changed = try git.changedPaths(base: base, head: head)
        let diffstat = try git.shortstat(base: base, head: head).trimmingCharacters(in: .whitespacesAndNewlines)
        return .allowed(PushPayload(sha: head, ref: target.ref, url: target.url, itemKey: target.itemKey, diffstat: diffstat,
                                    paths: Array(changed.sorted().prefix(maxPaths)), touchesWorkflows: touchesWorkflows(changed)))
    }

    /// Whether some path is under the repository's `.github/workflows/` (case and a leading `./` ignored: GitHub's check is
    /// exact, the owner's ask errs wide).
    public static func touchesWorkflows(_ paths: [String]) -> Bool {
        paths.contains { path in
            var p = path.lowercased()
            while p.hasPrefix("./") { p.removeFirst(2) }
            return p.hasPrefix(".github/workflows/")
        }
    }

    /// Unique places in order, at most `maxListed`, then `and N more`.
    static func listed(_ places: [String]) -> String {
        var seen = Set<String>()
        let unique = places.filter { seen.insert($0).inserted }
        let shown = unique.prefix(maxListed).map { Store.flat($0, max: 120) }
        return shown.joined(separator: ", ") + (unique.count > shown.count ? " and \(unique.count - shown.count) more" : "")
    }
}

extension GitWorkspace {
    /// Every path `base..head` changes (`diff --name-only -z --no-renames`, NUL-split: exact names). A list git cut short at the
    /// capture limit is refused rather than shown in part.
    func changedPaths(base: String, head: String) throws -> [String] {
        try Self.validRef(base); try Self.validRef(head)
        let out = try main.run(["diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", base, head])
        guard !out.cut else { throw GitError.failed(command: "diff --name-only", status: -1, stderr: "too many changed paths to list") }
        return String(decoding: out.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }
}

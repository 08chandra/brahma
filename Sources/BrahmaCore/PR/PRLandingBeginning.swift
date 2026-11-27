import Foundation

/// Where the merge queue hands a verified commit in PR mode (Plan X8): instead of fast-forwarding local `main`, it calls `begin`
/// once the candidate passed its checks and the leak scan (Task 3's `PRLandingMachine` conforms: it pushes through
/// `PushBranchStage`, opens the PR and watches it).
///
/// `begin` must be idempotent for the same item and SHA: a recovery after a crash between the queue's `handedToPR` journal step
/// and its `done` calls it again (the push of the same commit to the same branch, and the landing row, come out the same).
public protocol PRLandingBeginning: Sendable {
    func begin(item: WorkItem, verifiedSHA: String) async
}

/// What a fetch of the remote `main` found (Task 6's `RemoteMain` conforms to `RemoteMainFetching`).
public struct FetchResult: Equatable, Sendable {
    /// The remote `main`'s head, present in the company's engine repository after the fetch.
    public var newTip: String
    /// The commits the fetch brought (new to the engine), newest first.
    public var commits: [String]
    /// The remote `main` no longer contains the tip fetched before (a force-push upstream).
    public var rewound: Bool

    public init(newTip: String, commits: [String], rewound: Bool) {
        self.newTip = newTip; self.commits = commits; self.rewound = rewound
    }
}

/// Fetches the company's remote `main` into the engine's repository before a PR batch is prepared (spec §8.5.1 step 2: the
/// queue rebases onto the remote `main` it last fetched). The conformer owns every bound on the fetch — time, output and the
/// bytes it may write to disk — itself: nothing on the queue's side caps a fetch's size (the live git runner does not honour
/// `GitCommand.sizeWatch`).
public protocol RemoteMainFetching: Sendable {
    func fetch(companyId: String) async throws -> FetchResult
    /// Whether `ancestor` is `descendant` or in its history, in the company's engine repository after a fetch (`git merge-base
    /// --is-ancestor`, on the engine's `Blocking`). Plan X8 Task 5's completion proof asks it of the merge commit and the
    /// fetched tip, and of the pushed commit and a merge commit (Ruling 35). Throws when it cannot tell (a commit missing).
    func isAncestor(_ ancestor: String, of descendant: String, companyId: String) async throws -> Bool
    /// The parents of `sha` in the company's engine repository after a fetch (a merge commit has more than one).
    func parents(of sha: String, companyId: String) async throws -> [String]
}

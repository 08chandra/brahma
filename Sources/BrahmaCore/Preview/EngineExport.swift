import Foundation

/// The safe engine export (builder-check 1): a fresh tree of exactly one commit, with no `.git`, made only from the engine's
/// own records. A thin wrapper over 3a's `GitWorkspace.addEngineExport(runId:commit:)` (PR-2): under the engine repository's
/// lock the commit is fetched by SHA (fsck'd) into a fresh engine repository and written out with `git archive`; the
/// export directory under the data home (`<home>/run/exports/<runId>`, 0700) is emptied first and unpacked through the safe
/// walk. Git never runs with a cwd or `GIT_DIR` inside an agent-writable tree, and no worktree, index or HEAD of the
/// workspace is read, so whatever a build wrote into a previous export (a crafted `.git`, hooks, config) is just deleted.
///
/// Every preview start, release build and main smoke gets its own export (`EngineLayout.previewRunId` for previews). Blocking
/// (it runs git and tar): engine code calls it only inside a `Blocking` body (`EngineGitGuard` reports anything else).
public enum EngineExport {
    /// Exports `commit` of `company`'s workspace for run `runId` and returns its directory. Agent-planted history state found
    /// on the way is repaired and reported to the owner like a merge check's (`reportMergeTamper`). Throws
    /// `UnexportableTree` (the commit's own fault), `MergeInfrastructureError` (the engine's) or a `GitError` (a refused
    /// repository config, an invalid run id or commit).
    @discardableResult
    public static func export(store: Store, company: Company, runId: String, commit: String, now: Date = Store.now()) throws -> URL {
        try git(store, company).addEngineExport(runId: runId, commit: commit, tamper: { removed in
            store.reportMergeTamper(company: company, removed: removed, now: now)
        })
    }

    /// Where run `runId`'s export is (or would be): `<home>/run/exports/<runId>` (`BrahmaPaths.exportDir(runId:)`).
    public static func directory(store: Store, company: Company, runId: String) -> URL {
        git(store, company).exportPath(runId: runId)
    }

    /// Removes run `runId`'s export through the walked exports directory (never by a path; a link is not followed). Never throws.
    public static func remove(store: Store, company: Company, runId: String) {
        git(store, company).removeRunWorktree(runId: runId)
    }

    /// The company's workspace through the store's factory (engine lock, merge and export directories under the data home).
    private static func git(_ store: Store, _ company: Company) -> GitWorkspace {
        store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
    }
}

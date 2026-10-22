import Foundation

/// The per-item progress file an agent keeps for itself: `<ws>/.brahma/progress/<KEY>.md`. It lives outside the worktree
/// so it is never committed and survives the worktree's removal.
public enum ProgressFile {
    public static func path(workspace: URL, key: String) -> URL {
        workspace.appending(path: ".brahma/progress/\(key).md")
    }

    /// Creates the file with a short template when it does not exist yet; an existing file is never touched.
    @discardableResult
    public static func ensure(workspace: URL, item: WorkItem) throws -> URL {
        let url = path(workspace: workspace, key: item.key)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return url }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let title = item.title.components(separatedBy: .newlines).joined(separator: " ")
        let text = """
        # \(item.key): \(title)

        ## Plan

        ## Done so far

        ## Next

        ## Decisions and open questions

        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

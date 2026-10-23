import Foundation

/// The per-item progress file an agent keeps for itself: `<ws>/.brahma/progress/<KEY>.md`. It lives outside the worktree
/// so it is never committed and survives the worktree's removal.
public enum ProgressFile {
    public static func path(workspace: URL, key: String) -> URL {
        workspace.appending(path: ".brahma/progress/\(key).md")
    }

    /// Creates the file with a short template when it does not exist yet; an existing regular file is never touched. A link
    /// or odd file in its place is replaced by the template (never followed) and returned so the caller can alert.
    static func ensure(workspace: URL, item: WorkItem) throws -> UnsafeEngineFile? {
        let title = item.title.components(separatedBy: .newlines).joined(separator: " ")
        let text = """
        # \(item.key): \(title)

        ## Plan

        ## Done so far

        ## Next

        ## Decisions and open questions

        """
        let name = "\(item.key).md"
        switch try EngineFiles.entry(workspace: workspace, dir: directory, name: name) {
        case .regular:
            return nil
        case .missing:
            // Another claim may have just created it: then it is left alone too.
            _ = try EngineFiles.create(Data(text.utf8), workspace: workspace, dir: directory, name: name)
            return nil
        case .unsafe(let problem):
            try EngineFiles.replace(Data(text.utf8), workspace: workspace, dir: directory, name: name)
            return problem
        }
    }

    static let directory = ".brahma/progress"
}

extension Store {
    /// The item's progress file (see `ProgressFile.ensure`); the owner is alerted when a link or odd file was in its place or
    /// its directory is not a real one (then this throws).
    @discardableResult
    public func ensureProgressFile(workspace: URL, item: WorkItem) throws -> URL {
        do {
            if let replaced = try ProgressFile.ensure(workspace: workspace, item: item) {
                alertEngineFile(replaced, companyId: item.companyId)
            }
        } catch let refused as UnsafeEngineFile {
            alertEngineFile(refused, companyId: item.companyId)
            throw refused
        }
        return ProgressFile.path(workspace: workspace, key: item.key)
    }
}

import Foundation

public enum SafeMarkdownError: Error, Equatable, Sendable {
    case outsideWorkspace
    case tooLarge
    case notText
    case notFound
}

extension SafeMarkdownError {
    public var message: String {
        switch self {
        case .outsideWorkspace: "This document is outside the company workspace, so Brahma won't open it."
        case .tooLarge: "This document is too large to show here."
        case .notText: "This document isn't text Brahma can show."
        case .notFound: "This document can't be found."
        }
    }
}

/// Renders agent-written Markdown without letting it do anything: links become plain text, images are never fetched,
/// and HTML stays literal text. Headings, lists, emphasis and code keep their presentation attributes.
public enum SafeMarkdown {
    public static let maxBytes = 200_000
    public static let imageNote = "[image not shown]"

    public static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return AttributedString(markdown) }
        var out = AttributedString()
        var lastBlock: Int?
        var lastItem: Int?
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            // The parser leaves the blocks run together; put each on its own line, with a marker for list items.
            if let block, let previous = lastBlock, block != previous { out.append(AttributedString("\n")) }
            if let block, block != lastBlock {
                if let item = components.first(where: {
                    if case .listItem = $0.kind { return true } else { return false }
                }), item.identity != lastItem {
                    lastItem = item.identity
                    let ordered = components.contains { if case .orderedList = $0.kind { return true } else { return false } }
                    var ordinal = 1
                    if case .listItem(let n) = item.kind { ordinal = n }
                    out.append(AttributedString(ordered ? "\(ordinal). " : "• "))
                }
            }
            if block != nil { lastBlock = block }
            if run.imageURL != nil {
                let alt = String(parsed[run.range].characters)
                piece = AttributedString(alt.isEmpty ? imageNote : "\(alt) \(imageNote)")
            }
            piece.link = nil
            piece.imageURL = nil
            out.append(piece)
        }
        return out
    }

    /// Reads `documentPath` (relative to the workspace, or absolute) with symlinks followed, requires it to lie inside the
    /// workspace and to be a small regular text file, and renders it.
    public static func load(documentPath: String, workspace: String) -> Result<AttributedString, SafeMarkdownError> {
        let trimmed = documentPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return .failure(.notFound) }
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath()
        let candidate = trimmed.hasPrefix("/") ? URL(fileURLWithPath: trimmed) : URL(fileURLWithPath: workspace).appending(path: trimmed)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else { return .failure(.outsideWorkspace) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else { return .failure(.notFound) }
        guard !isDirectory.boolValue else { return .failure(.notText) }
        // Opened non-blocking and checked with fstat so a FIFO or device is never read.
        let fd = open(resolved.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.notFound) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { close(fd); return .failure(.notText) }
        guard info.st_size <= maxBytes else { close(fd); return .failure(.tooLarge) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: maxBytes + 1) else { return .failure(.notFound) }
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .failure(.notText) }
        return .success(render(text))
    }
}

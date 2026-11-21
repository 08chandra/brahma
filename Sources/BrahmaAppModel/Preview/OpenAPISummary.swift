import Foundation

/// One operation of an OpenAPI document: `GET /pets`, with its one-line summary when it has one.
public struct OpenAPIOperation: Equatable, Sendable {
    public var method: String
    public var path: String
    public var summary: String?

    public init(method: String, path: String, summary: String?) {
        self.method = method
        self.path = path
        self.summary = summary
    }
}

/// A bounded summary of an OpenAPI 3 document in JSON (Plan 4a Task 8a): its paths in sorted order, each with its
/// operations in method order, at most `maxOperations`. The input is at most `maxBytes`; larger input, YAML, or any JSON
/// that is not an object with a `paths` object gives nil. The app reads only the copy the engine wrote beside the preview
/// logs (`BackendAdapter.copyOpenAPI`, scrubbed and ≤ 2 MB), never a file in the agent's run.
public enum OpenAPISummary {
    public static let maxBytes = 2_097_152
    public static let maxOperations = 500
    static let methods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    public static func parse(_ data: Data) -> [OpenAPIOperation]? {
        guard data.count <= maxBytes,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let paths = root["paths"] as? [String: Any] else { return nil }
        var operations: [OpenAPIOperation] = []
        for path in paths.keys.sorted() {
            guard let item = paths[path] as? [String: Any] else { continue }
            for method in methods {
                guard let operation = item[method] as? [String: Any] else { continue }
                guard operations.count < maxOperations else { return operations }
                let summary = (operation["summary"] as? String).flatMap(oneLine)
                // The path key is agent-controlled too: one line, so it cannot pose as a second row.
                operations.append(OpenAPIOperation(method: method.uppercased(), path: oneLine(path) ?? "", summary: summary))
            }
        }
        return operations
    }

    /// The operations of the file at `url` (the engine's copy): nil when it is missing, a link, not a regular file, over
    /// `maxBytes` (checked before reading), or not an OpenAPI JSON document.
    /// Newlines flattened to spaces, trimmed, cut at the line cap; nil when nothing is left.
    static func oneLine(_ s: String) -> String? {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.isEmpty ? nil : RendererCaps.truncateLine(Substring(flat))
    }
}

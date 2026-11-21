import Foundation
import BrahmaCore

/// One backend smoke request's outcome, as the pane's table shows it (Plan 4a Task 8b). `method` and `path` come from the
/// surface's smoke list, which an agent sets (`set_smoke_check`): agent-controlled text, `Text(verbatim:)` in the view. `error`
/// is engine-composed; the body prefix stays out of the row.
public struct SmokeRow: Equatable, Sendable {
    public var method: String
    public var path: String
    /// The HTTP status, or "—" when none came back.
    public var statusTitle: String
    public var millis: Int
    public var ok: Bool
    public var error: String?

    public init(method: String, path: String, statusTitle: String, millis: Int, ok: Bool, error: String?) {
        self.method = method; self.path = path; self.statusTitle = statusTitle; self.millis = millis; self.ok = ok; self.error = error
    }
}

/// What the app knows about a running backend's OpenAPI copy (the engine's ≤ 2 MB file in `previewLogs`, the only one read):
/// still loading, parsed (`OpenAPISummary` through `RendererCaps.parse`), past the parse timeout, or not readable as OpenAPI
/// (missing, oversized, a link, or not a JSON document with `paths`).
public enum PreviewOpenAPI: Equatable, Sendable {
    case loading
    case operations([OpenAPIOperation])
    case timedOut
    case unreadable
}

/// Where a running backend's OpenAPI copy is: the engine's logs folder and the surface's name (`PreviewLog.openAPICopy` reads it
/// through the hardened walk). `url` only identifies it.
public struct OpenAPICopy: Equatable, Sendable {
    public var layout: EngineLayout
    public var name: String

    public init(layout: EngineLayout, name: String) { self.layout = layout; self.name = name }

    public var url: URL { layout.previewOpenAPI(name: name) }
}

extension PreviewBodies {
    /// The terminal keeps as many lines as `AnsiText` renders.
    public static let terminalLines = AnsiText.maxLines
    /// What a file renderer (Task 9b: CSV, glTF, images) shows when its parse goes past `RendererCaps.parseTimeout`: the body is
    /// the file itself there, so the status replaces it. The backend body never does (see `running`).
    public static let cantShowTitle = "CAN'T SHOW THIS FILE"
    public static let tookTooLong = "it took too long to read"
    /// The operations section's engine-written reasons for being empty.
    public static let openAPIUnreadable = "the OpenAPI file couldn't be read"
    public static let openAPITimedOut = "the OpenAPI summary timed out"

    public static func smokeRows(_ results: [SmokeResult]) -> [SmokeRow] {
        results.map { r in
            let path = URL(string: r.url)?.path ?? r.url
            return SmokeRow(method: r.method, path: path.isEmpty ? "/" : path, statusTitle: r.status.map(String.init) ?? "—",
                            millis: r.millis, ok: r.ok, error: r.error)
        }
    }

    /// An artifact's body: its stored path is relative to the workspace, so both the entry URL and the navigation root are
    /// joined with it. Stats the entry file; parses nothing.
    public static func fileBody(_ a: Artifact, workspace: URL) -> FileBody {
        FileBody.make(url: a.entryURL(workspace: workspace), kind: a.kind, root: a.directory(workspace: workspace))
    }

    /// A ran CLI demo: its sealed output (agent-controlled; the view runs it through `AnsiText`) under "exit <n> · <sha7>".
    static func terminal(state: PreviewState?, tail: (String?, Int) -> [String]) -> PreviewBody {
        let footer = [state?.message, state?.commit.map { String($0.prefix(7)) }].compactMap { $0 }.joined(separator: " · ")
        return .terminal(lines: tail(state?.outputPath, terminalLines), footer: footer)
    }

    /// The body of a `running` surface, by kind. A kind whose handle is not there yet (no URL, Simulator or pid) is STARTING.
    static func running(kind: PreviewKind, name: String, surfaceId sid: String, surface: PreviewSurface, state: PreviewState?,
                        snapshot p: PreviewSnapshot, tail: (String?, Int) -> [String]) -> PreviewBody {
        let starting = PreviewBody.status(title: "\(name) STARTING", detail: state?.message, logTail: [])
        switch kind {
        case .web, .artifact:
            guard let url = state?.resolvedURL.flatMap(URL.init(string:)) else { return starting }
            return .web(url: url, origin: url, builtBy: "@" + (p.setBy[sid] ?? surface.setById))
        case .backend:
            // The smoke rows and the log are engine-produced and never hidden by anything agent-controlled: the OpenAPI copy
            // (agent-authored) only ever empties the operations section, with the engine-written reason beside it. A copy that
            // is not readable as OpenAPI (YAML, no `paths`, oversized, a link), or a pathological one that times the parser out,
            // hides nothing.
            var operations: [OpenAPIOperation] = [], note: String?
            switch p.openAPI[sid] {
            case .timedOut?: note = openAPITimedOut
            case .unreadable?: note = openAPIUnreadable
            case .operations(let ops)?: operations = ops
            case .loading?, nil: break
            }
            return .backend(smoke: smokeRows(state?.smokeResults ?? []), logTail: tail(state?.logPath, logLines), operations: operations,
                            operationsNote: note)
        case .cli:
            // A demo never serves; it ends as `ran`.
            return starting
        case .ios:
            guard let udid = state?.simulatorId else { return starting }
            return .simulator(udid: udid)
        case .macos:
            guard let pid = state?.pid else { return starting }
            return .window(pid: pid)
        }
    }
}

extension PreviewNavigationPolicy {
    /// Where an artifact's web view may navigate: a file strictly under `root` (the artifact's copy; `..` is resolved first), or
    /// `about:blank`. Nothing remote: the content rule list blocks every scheme but `file:` and `about:` as well.
    public static func allowsArtifact(_ url: URL, root: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard url.isFileURL, root.isFileURL else { return false }
        let path = url.standardizedFileURL.path
        var rootPath = root.standardizedFileURL.path
        while rootPath.count > 1, rootPath.hasSuffix("/") { rootPath.removeLast() }
        guard rootPath.count > 1 else { return false }
        return path.hasPrefix(rootPath + "/") && path.count > rootPath.count + 1
    }
}

import Foundation
import BrahmaCore

/// A preview chip's color (Global Constraints "Color tokens"): running `success`, building/starting `running` (pulse),
/// failed `danger`, idle/stopped `text2`, unavailable `warning`; 4a's `ran` `success`.
public enum PreviewTone: Sendable {
    case good, busy, bad, idle, warn
    /// Plan C: the OPENED chip (`accent`).
    case accent

    public init(_ status: PreviewStatus) {
        switch status {
        case .running, .ran: self = .good
        case .building, .starting: self = .busy
        case .failed: self = .bad
        case .idle, .stopped: self = .idle
        case .unavailable: self = .warn
        }
    }
}

/// Namespaced preview tab ids (collab design §6.1 L-1). L emits `surface:<id>` and `live`; `artifacts` (4a) and `ref`
/// (Collab) are reserved, and an id L does not know is "no selection".
public enum PreviewTabID {
    public static let live = "live"
    public static let artifacts = "artifacts"
    public static let ref = "ref"
    /// Plan C Task C6b: the CHANGES tab (every leased worktree's live diff).
    public static let changes = "changes"
    static let surfacePrefix = "surface:"

    public static func surface(_ id: String) -> String { surfacePrefix + id }

    public static func surfaceId(_ tabId: String) -> String? {
        guard tabId.hasPrefix(surfacePrefix) else { return nil }
        let id = String(tabId.dropFirst(surfacePrefix.count))
        return id.isEmpty ? nil : id
    }
}

public struct PreviewTab: Equatable, Identifiable, Sendable {
    /// A `PreviewTabID`.
    public var id: String
    /// The surface name uppercased, or "LIVE".
    public var title: String
    public var statusTitle: String
    public var tone: PreviewTone
    public var surfaceId: String?

    public init(id: String, title: String, statusTitle: String, tone: PreviewTone, surfaceId: String?) {
        self.id = id; self.title = title; self.statusTitle = statusTitle; self.tone = tone; self.surfaceId = surfaceId
    }

    /// Only the OPENED tab closes; product tabs (surfaces, ARTIFACTS, LIVE) never do.
    public var closable: Bool { id == PreviewTabID.ref }
}

public enum PreviewTabs {
    /// The surfaces by position, then CHANGES whenever any lease has its worktree in place (Plan C C6b; its chip counts them,
    /// LIVE tone), then ARTIFACTS when any artifact exists (its chip names the newest), then LIVE when a release is deployed (4a A7).
    public static func make(_ p: PreviewSnapshot) -> [PreviewTab] {
        var tabs = p.surfaces.sorted { ($0.position, $0.name) < ($1.position, $1.name) }.map { s -> PreviewTab in
            let status = p.states[s.id]?.status ?? .idle
            return PreviewTab(id: PreviewTabID.surface(s.id), title: s.name.uppercased(), statusTitle: status.title.uppercased(),
                              tone: PreviewTone(status), surfaceId: s.id)
        }
        if !p.worktreeKeys.isEmpty {
            tabs.append(PreviewTab(id: PreviewTabID.changes, title: "CHANGES", statusTitle: "\(p.worktreeKeys.count) LIVE", tone: .busy, surfaceId: nil))
        }
        if let latest = p.artifacts.first {
            // Not a health state: the chip stays neutral.
            tabs.append(PreviewTab(id: PreviewTabID.artifacts, title: "ARTIFACTS", statusTitle: latest.ref, tone: .idle, surfaceId: nil))
        }
        if p.live != nil {
            tabs.append(PreviewTab(id: PreviewTabID.live, title: "LIVE", statusTitle: p.liveRef ?? "LIVE", tone: .good, surfaceId: nil))
        }
        return tabs
    }

    /// `make(p)` plus, when a ref is open (Plan C `PreviewNav.opened`), the OPENED tab (`PreviewTabID.ref`, chip = the ref's kind).
    public static func make(_ p: PreviewSnapshot, opened: OpenedRef?) -> [PreviewTab] {
        var tabs = make(p)
        if let opened {
            tabs.append(PreviewTab(id: PreviewTabID.ref, title: "OPENED", statusTitle: opened.kindChip, tone: .accent, surfaceId: nil))
        }
        return tabs
    }

    /// The first running surface, else ARTIFACTS, else LIVE, else the first tab: with no preview running, the latest artifact
    /// shows (R-192).
    public static func defaultSelection(_ tabs: [PreviewTab]) -> String? {
        tabs.first { $0.surfaceId != nil && $0.tone == .good }?.id
            ?? tabs.first { $0.id == PreviewTabID.artifacts }?.id
            ?? tabs.first { $0.id == PreviewTabID.live }?.id
            ?? tabs.first?.id
    }

    /// `selection` when it names one of `tabs`; otherwise (nil, reserved or unknown) the default selection.
    public static func resolve(_ selection: String?, _ tabs: [PreviewTab]) -> String? {
        if let selection, tabs.contains(where: { $0.id == selection }) { return selection }
        return defaultSelection(tabs)
    }
}

/// What the preview pane shows for one tab. An open enum (L-1): 4a and Collab add cases, so every `switch` over it in L
/// ends in `default:` (`MonoEmptyState("UNSUPPORTED PREVIEW")`).
public enum PreviewBody: Equatable, Sendable {
    case empty(String)
    /// `logTail` is agent-controlled text (`Text(verbatim:)`).
    case status(title: String, detail: String?, logTail: [String])
    /// `builtBy`: "@devops-1" for a surface, "R-3" for the live site.
    case web(url: URL, origin: URL, builtBy: String)
    /// A ran CLI demo (4a): its sealed output, agent-controlled (`AnsiText`), under "exit <n> · <sha7>".
    case terminal(lines: [String], footer: String)
    /// A running backend (4a): its smoke rows, log tail (agent-controlled) and the operations of the engine's OpenAPI copy.
    /// `operationsNote` is the engine-written reason the operations section is empty (the copy could not be read as OpenAPI, or
    /// its parse timed out); the engine-produced smoke rows and log stay whatever the agent-authored copy holds.
    case backend(smoke: [SmokeRow], logTail: [String], operations: [OpenAPIOperation], operationsNote: String? = nil)
    /// A running iOS app (4a): the Simulator's frames (`SimulatorScreenshotSource`).
    case simulator(udid: String)
    /// A running macOS app (4a): its window, captured by pid.
    case window(pid: Int32)
    /// The ARTIFACTS tab (4a): the shown artifact (rendered through `FileBody`; `AppModel.fileBody(for:)`) and the list.
    case artifact(Artifact, all: [Artifact])
    /// The OPENED tab (Plan C): a ref's body (`RefBodies`), or the chat inspector's.
    case ref(RefBody)
    /// The CHANGES tab (Plan C C6b): the view draws `AppModel.changes` (the board, the selected item's live diff, the markers).
    case changes
}

public enum PreviewBodies {
    public static let logLines = 40
    public static let noPreview = "No preview yet. When DevOps sets a preview command, the product appears here."

    /// `selectedArtifactId`: the artifact the ARTIFACTS tab shows; nil or unknown shows the newest.
    public static func body(for tabId: String?, snapshot p: PreviewSnapshot, logTail: (URL) -> [String],
                            selectedArtifactId: String? = nil) -> PreviewBody {
        let tabs = PreviewTabs.make(p)
        guard let id = PreviewTabs.resolve(tabId, tabs) else { return .empty(noPreview) }
        if id == PreviewTabID.live, let live = p.live { return .web(url: live, origin: live, builtBy: p.liveRef ?? "LIVE") }
        if id == PreviewTabID.changes { return .changes }
        if id == PreviewTabID.artifacts, let latest = p.artifacts.first {
            return .artifact(p.artifacts.first { $0.id == selectedArtifactId } ?? latest, all: p.artifacts)
        }
        guard let sid = PreviewTabID.surfaceId(id), let surface = p.surfaces.first(where: { $0.id == sid }) else {
            return .empty(noPreview)
        }
        let name = surface.name.uppercased()
        let state = p.states[sid]
        let kind = surface.previewKind ?? .web
        func tail(_ path: String?, _ lines: Int) -> [String] {
            guard let path else { return [] }
            return Array(logTail(URL(fileURLWithPath: path)).suffix(lines))
        }
        switch state?.status ?? .idle {
        case .building, .starting:
            let at = state?.commit.map { " AT " + String($0.prefix(7)) } ?? ""
            return .status(title: "BUILDING \(name)\(at)", detail: state?.message, logTail: tail(state?.logPath, logLines))
        case .failed:
            return .status(title: "\(name) FAILED", detail: state?.message, logTail: tail(state?.logPath, logLines))
        case .idle, .stopped:
            return .status(title: "\(name) STOPPED", detail: state?.message, logTail: [])
        case .unavailable:
            return .status(title: "\(name) UNAVAILABLE", detail: state?.message, logTail: [])
        case .ran:
            if kind == .cli { return terminal(state: state, tail: tail) }
            return .status(title: "\(name) RAN", detail: state?.message, logTail: tail(state?.logPath, logLines))
        case .running:
            return running(kind: kind, name: name, surfaceId: sid, surface: surface, state: state, snapshot: p, tail: tail)
        }
    }
}

/// Where an embedded preview may navigate: its own origin (same scheme, host and port) or `about:blank`.
public enum PreviewNavigationPolicy {
    public static func allowsWeb(_ url: URL, origin: URL) -> Bool {
        if url.absoluteString == "about:blank" { return true }
        guard let scheme = url.scheme?.lowercased(), scheme == origin.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty, host == origin.host?.lowercased() else { return false }
        return port(url, scheme) == port(origin, scheme)
    }

    private static func port(_ u: URL, _ scheme: String) -> Int { u.port ?? (scheme == "https" ? 443 : 80) }
}

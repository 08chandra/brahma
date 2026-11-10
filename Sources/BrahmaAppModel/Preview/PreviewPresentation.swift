import Foundation
import BrahmaCore

/// A preview chip's color (Global Constraints "Color tokens"): running `success`, building/starting `running` (pulse),
/// failed `danger`, idle/stopped `text2`, unavailable `warning`.
public enum PreviewTone: Sendable {
    case good, busy, bad, idle, warn

    public init(_ status: PreviewStatus) {
        switch status {
        case .running: self = .good
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
}

public enum PreviewTabs {
    /// The surfaces by position, then LIVE when a release is deployed.
    public static func make(_ p: PreviewSnapshot) -> [PreviewTab] {
        var tabs = p.surfaces.sorted { ($0.position, $0.name) < ($1.position, $1.name) }.map { s -> PreviewTab in
            let status = p.states[s.id]?.status ?? .idle
            return PreviewTab(id: PreviewTabID.surface(s.id), title: s.name.uppercased(), statusTitle: status.title.uppercased(),
                              tone: PreviewTone(status), surfaceId: s.id)
        }
        if p.live != nil {
            tabs.append(PreviewTab(id: PreviewTabID.live, title: "LIVE", statusTitle: p.liveRef ?? "LIVE", tone: .good, surfaceId: nil))
        }
        return tabs
    }

    /// The first running surface, else LIVE, else the first tab.
    public static func defaultSelection(_ tabs: [PreviewTab]) -> String? {
        tabs.first { $0.surfaceId != nil && $0.tone == .good }?.id ?? tabs.first { $0.id == PreviewTabID.live }?.id ?? tabs.first?.id
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
}

public enum PreviewBodies {
    public static let logLines = 40
    public static let noPreview = "No preview yet. When DevOps sets a preview command, the product appears here."

    public static func body(for tabId: String?, snapshot p: PreviewSnapshot, logTail: (URL) -> [String]) -> PreviewBody {
        let tabs = PreviewTabs.make(p)
        guard let id = PreviewTabs.resolve(tabId, tabs) else { return .empty(noPreview) }
        if id == PreviewTabID.live, let live = p.live { return .web(url: live, origin: live, builtBy: p.liveRef ?? "LIVE") }
        guard let sid = PreviewTabID.surfaceId(id), let surface = p.surfaces.first(where: { $0.id == sid }) else {
            return .empty(noPreview)
        }
        let name = surface.name.uppercased()
        let state = p.states[sid]
        func tail() -> [String] {
            guard let path = state?.logPath else { return [] }
            return Array(logTail(URL(fileURLWithPath: path)).suffix(logLines))
        }
        switch state?.status ?? .idle {
        case .building, .starting:
            let at = state?.commit.map { " AT " + String($0.prefix(7)) } ?? ""
            return .status(title: "BUILDING \(name)\(at)", detail: state?.message, logTail: tail())
        case .failed:
            return .status(title: "\(name) FAILED", detail: state?.message, logTail: tail())
        case .idle, .stopped:
            return .status(title: "\(name) STOPPED", detail: state?.message, logTail: [])
        case .unavailable:
            return .status(title: "\(name) UNAVAILABLE", detail: state?.message, logTail: [])
        case .running:
            guard let url = state?.resolvedURL.flatMap(URL.init(string:)) else {
                return .status(title: "\(name) STARTING", detail: state?.message, logTail: [])
            }
            return .web(url: url, origin: url, builtBy: "@" + (p.setBy[sid] ?? surface.setById))
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

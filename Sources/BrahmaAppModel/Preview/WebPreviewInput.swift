import Foundation
import BrahmaCore

/// The size the embedded preview renders at (collab design §4.6). `.desktop` fills the pane; the presets are device points.
public enum PreviewViewport: Equatable, Sendable, Codable {
    case desktop
    /// 820×1180.
    case ipad
    /// 390×844.
    case iphone
    case custom(width: Int, height: Int)

    public static let minSide = 200
    public static let maxSide = 4096
    static let refusal = WorkError.invalid("viewport is desktop, ipad, iphone or WxH up to 4096")

    /// `desktop|ipad|iphone|<W>x<H>` (case-insensitive, surrounding spaces ignored), each side 200…4096.
    public static func parse(_ s: String) throws -> PreviewViewport {
        let text = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch text {
        case "desktop": return .desktop
        case "ipad": return .ipad
        case "iphone": return .iphone
        default: break
        }
        let parts = text.split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
              (minSide...maxSide).contains(w), (minSide...maxSide).contains(h) else { throw refusal }
        return .custom(width: w, height: h)
    }

    /// Points, or nil for the desktop (the pane's own size).
    public var size: (width: Int, height: Int)? {
        switch self {
        case .desktop: nil
        case .ipad: (820, 1180)
        case .iphone: (390, 844)
        case .custom(let w, let h): (w, h)
        }
    }

    /// "DESKTOP", "IPAD 820×1180", "IPHONE 390×844", "CUSTOM 1280×800".
    public var title: String {
        switch self {
        case .desktop: "DESKTOP"
        case .ipad: "IPAD 820×1180"
        case .iphone: "IPHONE 390×844"
        case .custom(let w, let h): "CUSTOM \(w)×\(h)"
        }
    }
}

/// What the preview pane loads for a surface or the live site, from the owner's path. Both go through the core's path rule
/// (`LoopbackURL.withPath`): one leading `/`, no `//`, `\`, `@`, control characters or CR/LF escapes, segments percent-encoded.
public enum WebPreviewInput {
    static let pathRefusal = WorkError.invalid("preview paths start with one / and stay on the preview")

    /// `http://127.0.0.1:<port><path>` for a surface on `port`; `origin` must be that loopback preview.
    public static func url(origin: URL, path: String, port: Int) throws -> URL {
        try LoopbackURL.withPath(origin, path: path, port: port)
    }

    /// The LIVE tab: the production URL with the owner's path, under the same path rule, and only the same-origin rule applies
    /// (the result keeps `origin`'s scheme, host and port).
    public static func liveURL(origin: URL, path: String) throws -> URL {
        let probe = try LoopbackURL.withPath(URL(string: "http://127.0.0.1:47100/")!, path: path, port: 47100)
        guard var c = URLComponents(url: origin, resolvingAgainstBaseURL: false), let p = URLComponents(url: probe, resolvingAgainstBaseURL: false)
        else { throw pathRefusal }
        c.percentEncodedPath = p.percentEncodedPath
        c.percentEncodedQuery = p.percentEncodedQuery
        c.fragment = nil
        guard let url = c.url, PreviewNavigationPolicy.allowsWeb(url, origin: origin) else { throw pathRefusal }
        return url
    }
}

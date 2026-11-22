import Foundation
import BrahmaCore

/// How one file is shown (Plan 4a Task 8b; Collab §6.1 reuses it for `resource` and `file` refs). `make` stats the file and
/// parses nothing: the view's renderer (Task 9b) reads it, through the bounded parsers of Task 8a and `RendererCaps.parse`.
public struct FileBody: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// A confined web view (`PreviewNavigationPolicy.allowsArtifact`): HTML and SVG.
        case web
        case markdown
        /// Quick Look's out-of-process thumbnail: PDFs, office documents, spreadsheets and the 3D formats glTF cannot read.
        case quickLook
        /// Decoded in process (owner- and engine-made files only; see `effectiveMode(for:)`).
        case image
        case table
        /// `GLTFMesh`: geometry only, no node transforms (an accepted MVP limitation).
        case gltf
        case video
        /// Capped monospace text, never parsed (`text` and ML's `code`).
        case text
        /// Name, kind and size, with Open in Finder: CAD, and models too large to read in process.
        case fileCard
    }

    public var url: URL
    public var kind: ArtifactKind
    /// The folder the body may navigate within (the artifact's copy).
    public var root: URL
    public var mode: Mode
    /// The entry file's size (0 when it is missing or not a regular file).
    public var bytes: Int64

    public init(url: URL, kind: ArtifactKind, root: URL, mode: Mode, bytes: Int64) {
        self.url = url; self.kind = kind; self.root = root; self.mode = mode; self.bytes = bytes
    }

    public static let gltfExtensions: Set<String> = ["gltf", "glb"]
    /// What the glTF body says beside the mesh: `GLTFMesh` ignores node transforms (an accepted MVP limitation).
    public static let gltfNote = "geometry preview, no transforms"

    public static func make(url: URL, kind: ArtifactKind, root: URL) -> FileBody {
        let bytes = regularFileSize(url)
        let ext = ArtifactKind.ext(of: url.lastPathComponent)
        let mode: Mode
        switch kind {
        case .html: mode = .web
        case .markdown: mode = .markdown
        case .pdf, .spreadsheet, .document: mode = .quickLook
        case .model3d:
            if gltfExtensions.contains(ext) {
                mode = bytes <= Int64(RendererCaps.maxInProcessModelBytes) ? .gltf : .fileCard
            } else {
                mode = .quickLook
            }
        case .cad: mode = .fileCard
        case .video: mode = .video
        case .image: mode = ext == "svg" ? .web : .image
        case .table: mode = .table
        case .text, .code: mode = .text
        }
        return FileBody(url: url, kind: kind, root: root, mode: mode, bytes: bytes)
    }

    /// In-process image decoding is reserved for files the owner or the engine made: an agent's or an outside file is shown
    /// through Quick Look's thumbnail, out of process.
    public func effectiveMode(for p: Provenance) -> Mode {
        guard mode == .image else { return mode }
        switch p {
        case .owner, .engine: return .image
        case .agent, .external: return .quickLook
        }
    }

    /// The size of a regular file, without following a link; 0 for anything else.
    static func regularFileSize(_ url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return 0 }
        return Int64(st.st_size)
    }
}

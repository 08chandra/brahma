import Foundation

/// The engine-owned places Plan L keeps in a company's workspace, all under `.brahma` (engine-only: `SandboxScope`
/// write-denies `preview` and `releases` on every turn; agents may read `preview/logs` and `releases`).
///
/// Preview runs are not here: every preview start runs in a fresh `.git`-free export of the commit under the engine's data
/// home (`<home>/run/exports/<runId>`, `EngineExport`, PR-2), keyed by surface, commit and start (`previewRunId`, PR-16), so
/// no two surfaces or starts share a tree and nothing a build left carries over.
public struct EngineLayout: Equatable, Sendable {
    public let workspace: URL

    public init(workspace: URL) { self.workspace = workspace }

    /// `<ws>/.brahma`.
    public var dotBrahma: URL { workspace.appending(path: ".brahma", directoryHint: .isDirectory) }
    /// `.brahma/preview`: engine-only.
    public var previewDir: URL { dotBrahma.appending(path: "preview", directoryHint: .isDirectory) }
    /// `.brahma/preview/logs`: each surface's log (`previewLog(name:)`); readable by turns, writable by the preview servers.
    public var previewLogs: URL { previewDir.appending(path: "logs", directoryHint: .isDirectory) }
    /// `.brahma/preview/logs/<name>.log` (a surface name is one safe path component, `PreviewSurface.validate`).
    public func previewLog(name: String) -> URL { previewLogs.appending(path: "\(name).log", directoryHint: .notDirectory) }
    /// `.brahma/releases`: read-only to every turn and in no build, preview or check writable list.
    public var releasesDir: URL { dotBrahma.appending(path: "releases", directoryHint: .isDirectory) }
    /// `releasesDir/R-<n>`.
    public func releaseDir(_ number: Int) -> URL { releasesDir.appending(path: "R-\(number)", directoryHint: .isDirectory) }
    /// `releasesDir/tools/<cli>`: the engine-installed provider CLI.
    public func deployTools(cli: String) -> URL { releasesDir.appending(path: "tools/\(cli)", directoryHint: .isDirectory) }
    /// `releasesDir/placeholder`: the engine-written placeholder site.
    public var placeholderDir: URL { releasesDir.appending(path: "placeholder", directoryHint: .isDirectory) }

    /// The export run id of one start of one preview surface at one commit (PR-16): `prev-<surface8>-<sha12>-<start>`, where
    /// `surface8` is the first 8 letters and digits of the surface id, lowercased. Never shared between surfaces or starts.
    /// It is a valid 3a run id (`^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`); `EngineExport` puts it at `<home>/run/exports/<runId>`.
    public static func previewRunId(surfaceId: String, commit: String, start: Int) throws -> String {
        let surface = String(surfaceId.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
            .prefix(8).map(Character.init))
        guard !surface.isEmpty, surfaceId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            throw WorkError.invalid("invalid preview surface id")
        }
        guard commit.count >= 12, commit.count <= 64, commit.allSatisfy(\.isHexDigit) else { throw WorkError.invalid("invalid commit") }
        guard start >= 0 else { throw WorkError.invalid("invalid preview start") }
        return "prev-\(surface)-\(commit.prefix(12).lowercased())-\(start)"
    }
}

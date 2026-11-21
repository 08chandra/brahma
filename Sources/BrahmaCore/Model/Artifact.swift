import Foundation
import GRDB

/// A published artifact (Plan 4a Task 6): an engine-owned copy of a workspace file or folder under
/// `<ws>/.brahma/artifacts/<number>-<slug(title)>/`, made by `Store.publishArtifact`. Its kind, caps and sniffing rules are
/// ML's (`Model/FileKinds.swift`); its provenance type is ML's (`Model/Provenance.swift`). The engine never parses or renders
/// what it copied (A6): only the app does.
public struct Artifact: Codable, Equatable, Sendable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "artifact"

    public var id: String
    public var companyId: String
    /// Per company, from 1; never handed out again while the index still holds an earlier one (`Store.publishArtifact`).
    public var number: Int
    /// Agent-controlled: one line, at most `ArtifactPolicy.titleMax` characters, redacted.
    public var title: String
    public var kind: ArtifactKind
    /// The copy's folder, relative to the workspace (`.brahma/artifacts/<number>-<slug>`).
    public var storedPath: String
    /// The file the preview opens, relative to `storedPath` (`index.html` for a folder).
    public var entryFile: String
    /// The resolved path it was copied from.
    public var sourcePath: String
    /// `owner`, or the publishing agent's id.
    public var publishedById: String
    public var itemId: String?
    /// Bytes copied (every file of a folder or glTF set).
    public var bytes: Int64
    public var createdAt: Date

    public init(id: String, companyId: String, number: Int, title: String, kind: ArtifactKind, storedPath: String, entryFile: String,
                sourcePath: String, publishedById: String, itemId: String?, bytes: Int64, createdAt: Date) {
        self.id = id; self.companyId = companyId; self.number = number; self.title = title; self.kind = kind
        self.storedPath = storedPath; self.entryFile = entryFile; self.sourcePath = sourcePath; self.publishedById = publishedById
        self.itemId = itemId; self.bytes = bytes; self.createdAt = createdAt
    }

    /// `AR-<n>` (asks own `A-<n>`).
    public var ref: String { "AR-\(number)" }

    /// The owner's publications are owner-trusted; every other one is the publishing agent's (ML's raw form `agent:<id>`).
    public var provenance: Provenance { publishedById == "owner" ? .owner : .agent(publishedById) }

    /// What the tool and `brahma artifacts publish` answer.
    public var publishedLine: String { "Published \(ref) “\(title)” (\(kind.rawValue)); it shows in the preview pane." }

    /// The copy's folder in `workspace`.
    public func directory(workspace: URL) -> URL { workspace.appending(path: storedPath, directoryHint: .isDirectory) }

    /// The entry file's absolute path in `workspace`.
    public func entryURL(workspace: URL) -> URL {
        directory(workspace: workspace).appending(path: entryFile, directoryHint: .notDirectory)
    }

    /// The number of `AR-<n>` (any case) or a bare `<n>`, at least 1; nil for anything else, `A-<n>` (an ask) included.
    public static func parseRef(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let digits = t.uppercased().hasPrefix("AR-") ? String(t.dropFirst(3)) : t
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n >= 1 else {
            return nil
        }
        return n
    }
}

extension ArtifactKind: DatabaseValueConvertible {}

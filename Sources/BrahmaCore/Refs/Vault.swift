import Foundation

/// The vault's areas under `<home>/vault/<companyId>/`: ML's owner resources (`resources`, `ContentVault`'s), C's snapshots
/// (worktree diffs as shared), the diff cache and temp copies.
public enum VaultArea: String, Sendable, CaseIterable {
    case resources, snapshots, diffcache, tmp
}

public enum VaultError: Error, Equatable, Sendable {
    /// The bytes on disk are not the bytes recorded (or are more than the caller allows, or the name is not a plain file).
    case hashMismatch
    case missing
}

/// Scoped, tainted, private and redacted bytes (design §4.1): one company's vault, which agents' shells can't reach. It wraps
/// ML's `ContentVault` (the `resources` area: `F-<n>.<ext>`, 0444, read with its SHA-256 checked) and adds the other areas
/// beside it. Every open, write and removal goes through `EngineFiles` rooted at `BrahmaPaths.vaultDir(companyId:)` (no link
/// is followed on the way or at the end); directories are 0700 and files 0444. Names are the engine's own, one component.
public struct Vault: Sendable {
    public let paths: BrahmaPaths
    public let companyId: String
    public let content: ContentVault

    public init(paths: BrahmaPaths, companyId: String, content: ContentVault) {
        self.paths = paths; self.companyId = companyId; self.content = content
    }

    /// `<paths.home>/vault/<companyId>` (ML's `vaultDir(companyId:)`).
    public var root: URL { paths.vaultDir(companyId: companyId) }

    /// Writes `data` as `<area>/<name>` (never over anything there) and returns that path and the SHA-256 of the bytes. For
    /// `.resources` the name is `F-<n>.<ext>`, where `ContentVault` reads it.
    @discardableResult
    public func write(_ data: Data, area: VaultArea, name: String) throws -> (path: String, sha256: String) {
        try Self.checkName(name, area: area)
        let root = try companyRoot()
        do {
            try EngineFiles.directory(workspace: root, area.rawValue, mode: 0o700)
            guard try EngineFiles.create(data, workspace: root, dir: area.rawValue, name: name, mode: 0o444) else {
                throw WorkError.conflict("\(area.rawValue)/\(name) is already in the vault")
            }
        } catch let e as UnsafeEngineFile {
            throw WorkError.invalid("the vault can't be written: \(e.problem)")
        }
        return ("\(area.rawValue)/\(name)", SHA256.hex(data))
    }

    /// `write`, with the bytes `SafeFS` checked (read from the held descriptor, never the path again).
    @discardableResult
    public func write(from file: SafeFile, area: VaultArea, name: String) throws -> (path: String, sha256: String) {
        try write(try file.readAll(), area: area, name: name)
    }

    /// The bytes at `path` (`<area>/<name>`) when they hash to `sha256` and are at most `maxBytes`; `.hashMismatch` otherwise
    /// (a link, a file of another user or with another hard link counts as a mismatch), `.missing` when there is nothing.
    /// `.resources` reads go through `ContentVault.read`.
    public func read(_ path: String, sha256: String, maxBytes: Int) throws -> Data {
        let (area, name) = try Self.split(path)
        if area == .resources {
            do {
                return try content.read(companyId: companyId, relativePath: path, expectedSHA256: sha256, maxBytes: Int64(max(0, maxBytes)))
            } catch let e as ResourceError {
                if case .notFound = e { throw VaultError.missing }
                throw VaultError.hashMismatch
            }
        }
        let data: Data?
        do {
            data = try EngineFiles.read(workspace: try companyRoot(), dir: area.rawValue, name: name, limit: max(0, maxBytes) + 1)
        } catch is UnsafeEngineFile {
            throw VaultError.hashMismatch
        }
        guard let data else { throw VaultError.missing }
        guard data.count <= maxBytes, SHA256.hex(data) == sha256 else { throw VaultError.hashMismatch }
        return data
    }

    /// Removes `path` (by descriptor; a missing file is not an error).
    public func remove(_ path: String) throws {
        let (area, name) = try Self.split(path)
        if area == .resources { return try content.remove(companyId: companyId, relativePath: path) }
        try EngineFiles.remove(workspace: try companyRoot(), dir: area.rawValue, name: name)
    }

    /// A fresh 0700 directory under `<paths.home>/tmp` for one temporary copy (an archive the sandboxed unzip reads). The caller
    /// removes it.
    public func makeTempDir() throws -> URL {
        let tmp = try paths.ensureTmpDir()
        let dir = tmp.appending(path: "vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    // MARK: Names

    /// The company root, created 0700, refused for a company id that is not one path part or a vault inside the workspaces
    /// folder (`ContentVault.companyRoot`).
    private func companyRoot() throws -> URL {
        do { return try content.companyRoot(companyId) } catch let e as ResourceError { throw WorkError.invalid(e.message) }
    }

    /// One component of `[A-Za-z0-9._-]`, at most 128 bytes, not `.`/`..`; `.resources` takes only ML's `F-<n>.<ext>`.
    static func checkName(_ name: String, area: VaultArea) throws {
        guard (1...128).contains(name.utf8.count), name != ".", name != "..", !name.hasPrefix("."),
              name.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || [0x2E, 0x2D, 0x5F].contains($0) })
        else { throw WorkError.invalid("not a vault file name") }
        if area == .resources {
            do { _ = try ContentVault.fileName("\(ContentVault.dir)/\(name)") } catch { throw WorkError.invalid("not a vault resource name") }
        }
    }

    /// `<area>/<name>` split and checked.
    static func split(_ path: String) throws -> (VaultArea, String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let area = VaultArea(rawValue: parts[0]) else { throw VaultError.missing }
        do { try checkName(parts[1], area: area) } catch { throw VaultError.missing }
        return (area, parts[1])
    }
}

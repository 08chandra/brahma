import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Where owner resources' bytes live: `<home>/vault/<companyId>/resources/F-<n>.<ext>`, outside every workspace, with 0700
/// directories and 0444 files the engine names. The company root is opened through `EngineFiles` (root = that directory,
/// relative `resources`), so no link on the way is followed and nothing outside the root is written or read.
///
/// `store` defeats the drop TOCTOU: the bytes stored are the bytes `ResourceIntake.inspect` saw. The dropped file is reopened
/// below its root one component at a time without following anything, its identity must be the inspected one exactly, and the
/// bytes copied are hashed and secret-scanned as they are read; any difference refuses the copy.
public struct ContentVault: Sendable {
    public let paths: BrahmaPaths
    /// The directory below the company root that holds the files.
    static let dir = "resources"

    public init(paths: BrahmaPaths) { self.paths = paths }

    // MARK: Store

    /// Copies the inspected file into the vault as `F-<number>.<ext>` (mode 0444) and returns where it went, the SHA-256 of
    /// the bytes written and their count. `redacted` writes those bytes instead (still only once the file is proven to be the
    /// inspected one).
    ///
    /// 1. open `item.root` and require `rootIdentity` (device and inode only: a parent folder's size and time change with
    ///    unrelated files);
    /// 2. walk `relativePath` with `openat(O_NOFOLLOW)` per component;
    /// 3. `fstat` the final descriptor and require `item.identity` exactly;
    /// 4. copy from that descriptor while hashing, then run `ContentScan` over the same bytes;
    /// 5. a different identity (before or after the copy), or findings different from `item.findings` →
    ///    `ResourceError.changed("<name> changed after you added it; add it again")`;
    /// 6. write through `EngineFiles.create(…, mode: 0o444)`; a name already taken → `ResourceError.conflict`.
    public func store(companyId: String, number: Int, ext: String, item: DropItem, redacted: Data?, maxBytes: Int64,
                      knownValues: [(name: String, value: String)]) throws -> (relativePath: String, sha256: String, bytes: Int64) {
        try store(companyId: companyId, number: number, ext: ext, item: item, maxBytes: maxBytes, knownValues: knownValues) { _ in redacted }
    }

    /// `store`, with the bytes to write derived from the verified bytes (`transform` returns nil to write them as they are):
    /// a redacted copy is made from exactly the bytes that were checked.
    func store(companyId: String, number: Int, ext: String, item: DropItem, maxBytes: Int64,
               knownValues: [(name: String, value: String)],
               transform: (Data) throws -> Data?) throws -> (relativePath: String, sha256: String, bytes: Int64) {
        guard number > 0 else { throw ResourceError.invalid("a resource number starts at 1") }
        guard Self.validExt(ext) else { throw ResourceError.invalid(".\(Store.flat(ext, max: 20)) is not a file extension the vault can use") }
        let verified = try verifiedBytes(item: item, maxBytes: maxBytes, knownValues: knownValues)
        var out = verified.data, sha = verified.sha256
        if let rewritten = try transform(verified.data) { out = rewritten; sha = SHA256.hex(rewritten) }
        let name = "F-\(number).\(ext)"
        let root = try companyRoot(companyId)
        try EngineFiles.directory(workspace: root, Self.dir, mode: 0o700)
        guard try EngineFiles.create(out, workspace: root, dir: Self.dir, name: name, mode: 0o444) else {
            throw ResourceError.conflict("F-\(number) is already taken in the vault; add it again")
        }
        return ("\(Self.dir)/\(name)", sha, Int64(out.count))
    }

    /// Steps 1–5 of `store`: the dropped file's bytes, proven to be the inspected ones, with their SHA-256. Nothing is written
    /// (store-as-secret reads its one file this way).
    func verifiedBytes(item: DropItem, maxBytes: Int64,
                       knownValues: [(name: String, value: String)]) throws -> (data: Data, sha256: String) {
        let changed = ResourceError.changed("\(item.displayName) changed after you added it; add it again")
        guard item.identity.size <= maxBytes else {
            throw ResourceError.invalid("\(item.displayName) is over the \(ResourceText.size(maxBytes)) limit")
        }
        // 1. The root, by device and inode.
        let rootFd = open(item.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFd >= 0 else { throw changed }
        defer { close(rootFd) }
        var rst = stat()
        guard fstat(rootFd, &rst) == 0, item.rootIdentity.sameFile(rst) else { throw changed }
        // 2. Every component without following a link.
        let components = item.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let fd = ResourceIntake.openBeneath(rootFd, components)
        guard fd >= 0 else { throw changed }
        defer { close(fd) }
        // 3. Exactly the inspected file.
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, FileIdentity(st) == item.identity else { throw changed }
        // 4. Copy while hashing, then scan the same bytes.
        var data = Data()
        data.reserveCapacity(Int(item.identity.size))
        var hasher = SHA256.Hasher()
        var offset: off_t = 0
        while true {
            let piece = try ContentScan.read(fd, at: offset, count: ContentScan.chunkBytes)
            if piece.isEmpty { break }
            offset += off_t(piece.count)
            guard Int64(offset) <= item.identity.size else { throw changed }
            piece.withUnsafeBytes { hasher.update($0) }
            data.append(contentsOf: piece)
        }
        guard Int64(data.count) == item.identity.size else { throw changed }
        let findings = try ContentScan.scan(data: data, isText: item.isText, knownValues: knownValues)
        // 5. Still the same file, and the same findings.
        var after = stat()
        guard fstat(fd, &after) == 0, FileIdentity(after) == item.identity, findings == item.findings else { throw changed }
        return (data, SHA256.hex(digest: hasher.finalize()))
    }

    // MARK: Read and remove

    /// The stored bytes, verified against `expectedSHA256`: a mismatch (or a file over `maxBytes`) →
    /// `ResourceError.integrity("F-<n> changed on disk")` (the caller writes the activity line: `Store.readResource`). A missing
    /// file → `ResourceError.notFound`.
    public func read(companyId: String, relativePath: String, expectedSHA256: String, maxBytes: Int64) throws -> Data {
        let name = try Self.fileName(relativePath)
        let changed = ResourceError.integrity("\(Self.ref(of: name)) changed on disk")
        let root = try companyRoot(companyId)
        let limit = Int(min(maxBytes, Int64(Int.max - 1))) + 1
        let data: Data?
        do {
            data = try EngineFiles.read(workspace: root, dir: Self.dir, name: name, limit: limit)
        } catch is UnsafeEngineFile {
            throw changed      // a link, a second hard link or a file of another user where a vault file belongs
        }
        guard let data else { throw ResourceError.notFound("\(Self.ref(of: name)) is missing from the vault") }
        guard Int64(data.count) <= maxBytes, SHA256.hex(data) == expectedSHA256 else { throw changed }
        return data
    }

    /// Removes a vault file (by descriptor, `EngineFiles.remove`); a missing one is not an error.
    public func remove(companyId: String, relativePath: String) throws {
        let name = try Self.fileName(relativePath)
        try EngineFiles.remove(workspace: try companyRoot(companyId), dir: Self.dir, name: name)
    }

    /// The highest `F-<n>` already in the company's vault directory (0 when none): a number left by an add that stopped before
    /// its rows were written is never reused.
    func highestNumber(companyId: String) throws -> Int {
        let dir = try companyRoot(companyId).appending(path: Self.dir, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        // A listing that fails refuses the add (fail closed): a number in use must never be handed out again.
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).compactMap { name -> Int? in
            guard name.hasPrefix("F-"), let dot = name.firstIndex(of: ".") else { return nil }
            return Int(name[name.index(name.startIndex, offsetBy: 2)..<dot])
        }.max() ?? 0
    }

    // MARK: Helpers

    /// `<home>/vault/<companyId>`, created 0700 (and `<home>/vault`, and any missing parent, too); refused for a company id that is not one path part,
    /// or a vault that would sit inside the workspaces folder (agents can read that).
    func companyRoot(_ companyId: String) throws -> URL {
        guard !companyId.isEmpty, companyId != ".", companyId != "..", !companyId.contains("/"), !companyId.contains("\0") else {
            throw ResourceError.invalid("not a company id")
        }
        let vault = paths.vaultDir.standardizedFileURL.resolvingSymlinksInPath().path
        let workspaces = paths.workspaces.standardizedFileURL.resolvingSymlinksInPath().path
        guard vault != workspaces, !vault.hasPrefix(workspaces + "/") else {
            throw ResourceError.invalid("the vault can't be inside the workspaces folder")
        }
        try BrahmaPaths.ensurePrivateDirectory(paths.vaultDir)
        let root = paths.vaultDir(companyId: companyId)
        try BrahmaPaths.ensurePrivateDirectory(root)
        return root
    }

    /// An extension the engine may put in a vault name: 1–16 lowercase ASCII letters and digits.
    static func validExt(_ ext: String) -> Bool {
        !ext.isEmpty && ext.count <= 16 && ext.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The file name of a stored `resources/F-<n>.<ext>` path; anything else is refused.
    static func fileName(_ relativePath: String) throws -> String {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0] == dir, let dot = parts[1].firstIndex(of: "."), parts[1].hasPrefix("F-"),
              Int(parts[1][parts[1].index(parts[1].startIndex, offsetBy: 2)..<dot]) != nil,
              validExt(String(parts[1][parts[1].index(after: dot)...]))
        else { throw ResourceError.invalid("not a vault path") }
        return parts[1]
    }

    static func ref(of name: String) -> String { String(name.prefix { $0 != "." }) }
}

/// How resources are named in text the engine composes.
public enum ResourceText {
    /// `512 B`, `12 KB`, `3.4 MB`, `1.2 GB` (1024-based).
    public static func size(_ bytes: Int64) -> String {
        let b = max(bytes, 0)
        if b < 1024 { return "\(b) B" }
        if b < 1_048_576 { return "\((b + 512) / 1024) KB" }
        if b < 1_073_741_824 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        return String(format: "%.1f GB", Double(b) / 1_073_741_824)
    }
}

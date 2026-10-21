import Foundation

/// Where the SHA-256 of the owner key lives, outside the data home. The macOS implementation (Keychain) is in the
/// `BrahmaKeychain` target so BrahmaCore stays portable. There is deliberately no environment variable or flag that
/// redirects a store or skips the check.
public protocol OwnerKeyStore: Sendable {
    func hash(for paths: BrahmaPaths) -> String?
    func setHash(_ hash: String, for paths: BrahmaPaths) throws
    func removeHash(for paths: BrahmaPaths)
}

/// Process-local store for unit tests.
public final class InMemoryOwnerKeyStore: OwnerKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var hashes: [String: String] = [:]
    public init() {}
    public func hash(for paths: BrahmaPaths) -> String? { lock.withLock { hashes[paths.home.path] } }
    public func setHash(_ hash: String, for paths: BrahmaPaths) throws { lock.withLock { hashes[paths.home.path] = hash } }
    public func removeHash(for paths: BrahmaPaths) { lock.withLock { hashes[paths.home.path] = nil } }
}

/// Linux / no-Keychain fallback: a 0600 hash file outside the data home, `<directory>/owner-<fnv of home>.sha256`.
/// Weaker than the Keychain: any process of the same user can rewrite it.
public struct FileOwnerKeyStore: OwnerKeyStore {
    public var directory: URL

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: ".config/brahma", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func file(_ paths: BrahmaPaths) -> URL {
        directory.appending(path: "owner-\(StableHash.fnv1a64(paths.home.path)).sha256")
    }

    public func hash(for paths: BrahmaPaths) -> String? {
        (try? String(contentsOf: file(paths), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func setHash(_ hash: String, for paths: BrahmaPaths) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = file(paths)
        try Data((hash + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func removeHash(for paths: BrahmaPaths) { try? FileManager.default.removeItem(at: file(paths)) }
}

public enum OwnerKeyError: Error, Equatable {
    case alreadyExists
    case cannotWrite(String)
}

/// `<home>/owner.key`: 32 random bytes, hex, mode 0600, plus SHA-256(key) in an `OwnerKeyStore`.
/// Owner-write CLI commands refuse unless the file's hash matches the stored hash. Only the app and an explicit
/// `brahma owner init` (interactive terminal) create the key; no owner command ever does.
///
/// This is a deterrent, not a security boundary: until 5-lite read-denies the data home and the Keychain to agents,
/// an agent shell can still read the key, read the hash, or fake a TTY with `script`.
public enum OwnerKey {
    public static func url(paths: BrahmaPaths) -> URL { paths.home.appending(path: "owner.key") }

    static func newKey() -> String { (0..<32).map { _ in UInt8.random(in: 0...255) }.map { String(format: "%02x", $0) }.joined() }

    /// Creates the key and stores its hash. Without `rotate` an existing key file is an error.
    @discardableResult
    public static func create(paths: BrahmaPaths, store: any OwnerKeyStore, rotate: Bool = false) throws -> URL {
        let file = url(paths: paths)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let key = newKey()
        let bytes = Array((key + "\n").utf8)
        if rotate {
            let temp = paths.home.appending(path: ".owner.key.\(UUID().uuidString)")
            try write(bytes, to: temp.path, flags: O_CREAT | O_EXCL | O_WRONLY)
            guard rename(temp.path, file.path) == 0 else {
                try? FileManager.default.removeItem(at: temp)
                throw OwnerKeyError.cannotWrite("rename failed (errno \(errno))")
            }
        } else {
            do { try write(bytes, to: file.path, flags: O_CREAT | O_EXCL | O_WRONLY) } catch OwnerKeyError.alreadyExists {
                throw OwnerKeyError.alreadyExists
            }
        }
        do { try store.setHash(SHA256.hex(key), for: paths) } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return file
    }

    /// App launch: keeps a valid key; otherwise (missing, or the stored hash is missing or differs) makes a new one.
    @discardableResult
    public static func ensure(paths: BrahmaPaths, store: any OwnerKeyStore) throws -> URL {
        if verify(paths: paths, store: store) { return url(paths: paths) }
        return try create(paths: paths, store: store, rotate: true)
    }

    public static func exists(paths: BrahmaPaths) -> Bool { FileManager.default.fileExists(atPath: url(paths: paths).path) }

    /// True only when the file is readable, a stored hash exists, and SHA-256(file contents) equals it
    /// (constant-time compare).
    public static func verify(paths: BrahmaPaths, store: any OwnerKeyStore) -> Bool {
        guard let data = try? Data(contentsOf: url(paths: paths)),
              let text = String(data: data, encoding: .utf8),
              let stored = store.hash(for: paths) else { return false }
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        return constantTimeEqual(SHA256.hex(key), stored.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = UInt8(truncatingIfNeeded: x.count ^ y.count)
        for i in 0..<max(x.count, y.count) {
            diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
        }
        return diff == 0
    }

    private static func write(_ bytes: [UInt8], to path: String, flags: Int32) throws {
        let fd = open(path, flags, 0o600)
        if fd < 0 {
            if errno == EEXIST { throw OwnerKeyError.alreadyExists }
            throw OwnerKeyError.cannotWrite("open failed (errno \(errno))")
        }
        defer { close(fd) }
        guard Foundation.write(fd, bytes, bytes.count) == bytes.count else { throw OwnerKeyError.cannotWrite("short write") }
    }
}

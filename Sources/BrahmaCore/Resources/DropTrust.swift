import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The trust a dropped file gets before the owner says otherwise (§4.3): a file from inside a company workspace or the
/// Brahma data home is EXTERNAL (agents write there, so the owner dropping it is not a vouch); document types and large
/// text files are EXTERNAL (they commonly carry text from outside), and so is anything macOS marked as downloaded.
/// Everything else is the owner's.
public enum DropTrust {
    /// Text kinds that count as outside text once they pass `ResourcePolicy.largeTextBytes`.
    static let largeTextExt: Set<String> = ["md", "txt", "csv"]

    /// The reason shown for a file dropped from where agents write.
    public static let agentAreaReason = "from a company workspace or Brahma's data folder (agents write there)"

    public static func defaultProvenance(ext: String, bytes: Int64, quarantined: Bool, inAgentArea: Bool)
        -> (provenance: Provenance, tainted: Bool, reason: String?) {
        // First, whatever its type, size or quarantine flag: agent-written text needs an explicit owner vouch.
        if inAgentArea { return (.external("agent-workspace"), true, agentAreaReason) }
        let e = ext.lowercased()
        if ResourcePolicy.docTypeTainted.contains(e) {
            return (.external("doc-type"), true, "\(e.uppercased()) from outside (document type)")
        }
        if largeTextExt.contains(e), bytes > Int64(ResourcePolicy.largeTextBytes) {
            return (.external("doc-type"), true, "large text file")
        }
        if quarantined {
            return (.external("quarantine"), true, "downloaded file (macOS quarantine)")
        }
        return (.owner, false, nil)
    }
}

/// The places agents write (every company workspace, the workspaces root and the Brahma data home), as directory
/// identities. A dropped file is inside one when the directory it was opened from, or any directory above that (walked by
/// descriptor through `..`, so links and `..` in the dropped path are already resolved by the kernel), is one of them, or
/// when a folder walk passes through one.
public struct AgentAreas: Sendable, Equatable {
    struct Identity: Hashable, Sendable { let dev: UInt64; let ino: UInt64 }
    let identities: Set<Identity>

    /// No area: nothing a drop holds is treated as agent-written (used only for files the engine itself just wrote, such
    /// as a pasted image, and by tests of other rules).
    public static let none = AgentAreas(identities: [])

    init(identities: Set<Identity>) { self.identities = identities }

    /// The identities of `urls` that exist (each followed through links and standardized first); missing ones are skipped.
    public init(urls: [URL]) {
        var ids = Set<Identity>()
        for url in urls {
            let path = SandboxPath.resolve(url.standardizedFileURL.path)
            var st = stat()
            if stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { ids.insert(Self.identity(st)) }
        }
        identities = ids
    }

    public var isEmpty: Bool { identities.isEmpty }

    static func identity(_ st: stat) -> Identity {
        Identity(dev: UInt64(truncatingIfNeeded: st.st_dev), ino: UInt64(truncatingIfNeeded: st.st_ino))
    }

    func contains(_ st: stat) -> Bool { identities.contains(Self.identity(st)) }

    /// True when the directory open at `dirFd`, or any directory above it, is an area. Fails closed: an ancestor that can't
    /// be opened or read counts as inside.
    func encloses(dirFd: Int32) -> Bool {
        guard !identities.isEmpty else { return false }
        var current = dup(dirFd)
        guard current >= 0 else { return true }
        defer { close(current) }
        for _ in 0..<512 {
            var st = stat()
            guard fstat(current, &st) == 0 else { return true }
            if contains(st) { return true }
            let up = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard up >= 0 else { return true }
            var ust = stat()
            guard fstat(up, &ust) == 0 else { close(up); return true }
            close(current)
            current = up
            if Self.identity(ust) == Self.identity(st) { return false }    // the root: its `..` is itself
        }
        return true
    }
}

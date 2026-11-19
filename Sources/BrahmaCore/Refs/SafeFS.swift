import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Why `SafeFS` refused an agent-named path. Every case is a refusal, never a retry.
public enum SafeFSError: Error, Equatable, Sendable {
    /// A component is empty, `.`/`..`, or holds NUL, a control, bidi or zero-width character.
    case badPath
    /// The final entry is not a regular file (a directory, a device, a pipe).
    case notRegular
    /// A link on the way or at the end: a symbolic link, or a file with another hard link.
    case linked
    /// The file sits on another device than the workspace.
    case crossDevice
    /// The file is larger than the cap the caller gave.
    case tooLarge(Int)
    /// A place agents may not share from (`home`, `checks`, team notes, an unlisted `.brahma` child) or not this user's file.
    case notAllowed
    /// Another agent's lab or notes file (its handle, ASCII-sanitized).
    case privateTo(String)
    /// A path outside `.brahma/` named through `open(workspacePath:)`: tracked files go through git.
    case notInPlace
    /// Anything else (does not exist, cannot be opened or read, cannot be created), with the reason.
    case io(String)
}

/// Where an opened file was found, decided by inode.
public enum SafeFSPlace: Equatable, Sendable {
    case worktree(key: String)
    case ownLab
    case ownNotes
    /// `"artifacts"`, `"progress"`, `"handoffs"` or `"resources/company"`.
    case brahmaChild(String)
}

/// One opened file: its bytes come from the descriptor that was checked, never from its path again.
public final class SafeFile: @unchecked Sendable {
    public let size: Int
    public let place: SafeFSPlace
    /// The owner's execute bit (for the git mode of a worktree file: `100755`, else `100644`).
    public let executable: Bool
    private let fd: Int32

    fileprivate init(fd: Int32, size: Int, place: SafeFSPlace, executable: Bool) {
        self.fd = fd; self.size = size; self.place = place; self.executable = executable
    }
    deinit { close(fd) }

    /// The first `size` bytes (as checked when opened); a file that shrank since gives what is left.
    public func readAll() throws -> Data {
        var out = Data(capacity: size)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var offset = 0
        while offset < size {
            let want = min(buffer.count, size - offset), at = off_t(offset)
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, at) }
            if n < 0 { if errno == EINTR { continue }; throw SafeFSError.io("cannot be read (\(String(cString: strerror(errno))))") }
            if n == 0 { break }
            out.append(contentsOf: buffer[0..<n])
            offset += n
        }
        return out
    }

    public func sha256() throws -> String { SHA256.hex(try readAll()) }

    /// Writes the bytes to `toFD` (which the caller owns and closes).
    public func copy(toFD: Int32) throws {
        let data = try readAll()
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Foundation.write(toFD, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw SafeFSError.io("cannot be copied (\(String(cString: strerror(errno))))") }
                offset += n
            }
        }
    }
}

/// The one way the engine opens a file an AGENT named: a path under `.brahma/` (a share, a hand-off, a lab file) or in an
/// item worktree. The walk is 3a's `EngineFiles` (`OpenDirectory.child`: `openat(O_DIRECTORY | O_NOFOLLOW)` one component
/// at a time, never through a link; `openEntry` for the file). On top of it `SafeFS` classifies by inode, never by string:
/// the opened directory is compared by `(st_dev, st_ino)` to the descriptors held since `init` for `.brahma`, its allowlisted
/// children, `labs`, `notes`, `home` and the caller's own lab, so a case or normalization variant of a name lands exactly
/// where its inode does. The final descriptor must be a regular file with one link on the workspace's device, this user's,
/// within the caller's size cap. An `UnsafeEngineFile` on the way is a refusal (`SafeFSError`), never a retry.
public final class SafeFS: @unchecked Sendable {
    public static let brahmaAllowlist = ["artifacts", "progress", "handoffs", "resources/company"]

    /// Tests only: called with the index of each intermediate component right after it is opened.
    public var testHookAfterComponent: ((Int) -> Void)?

    let workspace: URL
    let ownHandle: String?
    private let root: EngineFiles.OpenDirectory
    private let brahma: EngineFiles.OpenDirectory
    private let device: dev_t
    private typealias Identity = (dev: dev_t, ino: ino_t)
    private let brahmaId: Identity
    /// The allowlisted children that exist, `resources`, `labs`, `notes`, `notes/agents`, `home` and the own lab (`ownLab`),
    /// by identity; the directories themselves stay open in `held` so these inodes remain the ones compared against.
    private let children: [String: Identity]
    private let held: [EngineFiles.OpenDirectory]

    /// Opens and holds the workspace, `.brahma`, each allowlisted child that exists, `labs`, `home`, `notes`, and the caller's
    /// own lab (`ownHandle`; nil for a caller with no lab, for whom every lab is private).
    public init(workspace: URL, ownHandle: String?) throws {
        self.workspace = workspace
        self.ownHandle = ownHandle
        var ids: [String: Identity] = [:]
        var open: [EngineFiles.OpenDirectory] = []
        do {
            root = try EngineFiles.openWalked(workspace: workspace, "")
            brahma = try EngineFiles.openWalked(workspace: workspace, ".brahma")
            var st = stat()
            guard fstat(root.fd, &st) == 0 else { throw SafeFSError.io("\(workspace.path) cannot be inspected") }
            device = st.st_dev
            brahmaId = try brahma.identity()
            func hold(_ parent: EngineFiles.OpenDirectory, _ name: String, as key: String) throws -> EngineFiles.OpenDirectory? {
                guard parent.kind(of: name) == .directory else { return nil }
                let dir = try parent.child(name)
                ids[key] = try dir.identity()
                open.append(dir)
                return dir
            }
            for name in ["artifacts", "progress", "handoffs", "home"] { _ = try hold(brahma, name, as: name) }
            if let resources = try hold(brahma, "resources", as: "resources") { _ = try hold(resources, "company", as: "resources/company") }
            if let notes = try hold(brahma, "notes", as: "notes") { _ = try hold(notes, "agents", as: "notes/agents") }
            if let labs = try hold(brahma, "labs", as: "labs"), let ownHandle, (try? Self.checkComponent(ownHandle)) != nil {
                _ = try hold(labs, ownHandle, as: "ownLab")
            }
        } catch let e as UnsafeEngineFile {
            throw Self.map(e)
        }
        children = ids
        held = open
    }

    private var ownLab: Identity? { children["ownLab"] }

    // MARK: Opening

    /// A file under `.brahma/` by its workspace-relative path. Any other path is `.notInPlace` (callers use git for tracked
    /// files). The place says where its inode put it; `home`, `checks`, team notes and unlisted children are `.notAllowed`.
    public func open(workspacePath: String, maxBytes: Int) throws -> SafeFile {
        let parts = try Self.components(workspacePath)
        return try walk(from: root, parts, state: .root, maxBytes: maxBytes)
    }

    /// A file in the item worktree `<ws>/.brahma/wt/<KEY>/` by its worktree-relative path.
    public func open(_ relativePath: String, inWorktree key: String, maxBytes: Int) throws -> SafeFile {
        try open(relativePath, in: try worktreeDirectory(key: key), key: key, maxBytes: maxBytes)
    }

    /// The real directory `.brahma/wt/<KEY>`, opened by the walk (`O_NOFOLLOW` at `wt` and at the key) and held by the caller
    /// for as long as one operation needs the same directory for every step (`SafeGit.worktreeDiff`: git is anchored to it,
    /// and the files are read from it).
    func worktreeDirectory(key: String) throws -> EngineFiles.OpenDirectory {
        guard (try? GitWorkspace.validKey(key)) != nil else { throw SafeFSError.badPath }
        do { return try brahma.child("wt").child(key) } catch let e as UnsafeEngineFile { throw Self.map(e) }
    }

    /// A file in the held worktree directory `tree` (from `worktreeDirectory(key:)`) by its worktree-relative path.
    func open(_ relativePath: String, in tree: EngineFiles.OpenDirectory, key: String, maxBytes: Int) throws -> SafeFile {
        let parts = try Self.components(relativePath)
        do { return try walk(from: tree, parts, state: .place(.worktree(key: key)), maxBytes: maxBytes) }
        catch let e as UnsafeEngineFile { throw Self.map(e) }
    }

    /// Creates `<own lab>/<sub>/<name>` exclusively (never over or through anything there), mode 0444, through `EngineFiles`
    /// (the subdirectory is created when missing, never through a link). Returns the lab-relative path `<sub>/<name>`.
    public func createExclusive(name: String, inOwnLabSubdir sub: String, data: Data) throws -> String {
        guard let ownHandle, ownLab != nil else { throw SafeFSError.notAllowed }
        try Self.checkComponent(name)
        let subParts = try Self.components(sub)
        let dir = ".brahma/labs/\(ownHandle)/\(subParts.joined(separator: "/"))"
        do {
            try EngineFiles.directory(workspace: workspace, dir)
            guard try EngineFiles.create(data, workspace: workspace, dir: dir, name: name, mode: 0o444) else {
                throw SafeFSError.io("\(sub)/\(name) exists")
            }
        } catch let e as UnsafeEngineFile {
            throw Self.map(e)
        }
        return "\(subParts.joined(separator: "/"))/\(name)"
    }

    // MARK: The walk

    /// Where the walk stands after opening a directory.
    private enum State: Equatable {
        /// The workspace itself: the next component must be `.brahma`'s inode.
        case root
        /// `.brahma`: the next must be an allowlisted child, `resources`, `labs` or `notes`.
        case brahma
        case resources, labs, notes, notesAgents
        /// Inside a place: anything below belongs to it.
        case place(SafeFSPlace)
    }

    private func walk(from start: EngineFiles.OpenDirectory, _ parts: [String], state: State, maxBytes: Int) throws -> SafeFile {
        var dir = start
        var state = state
        for (index, name) in parts.dropLast().enumerated() {
            let next: EngineFiles.OpenDirectory
            do { next = try dir.child(name) } catch let e as UnsafeEngineFile {
                switch dir.kind(of: name) {
                case .link: throw SafeFSError.linked
                case .other: throw SafeFSError.notRegular
                case .missing, .directory: throw Self.map(e)
                }
            }
            state = try classify(directory: next, name: name, under: state)
            dir = next
            testHookAfterComponent?(index)
        }
        let name = parts[parts.count - 1]
        let place: SafeFSPlace
        switch state {
        case .root: throw SafeFSError.notInPlace
        case .brahma, .resources, .labs, .notes: throw SafeFSError.notAllowed
        case .notesAgents:
            guard let ownHandle, name == "\(ownHandle).md" else { throw SafeFSError.privateTo(Self.sanitized(name.hasSuffix(".md") ? String(name.dropLast(3)) : name)) }
            place = .ownNotes
        case .place(let p): place = p
        }
        let opened: (fd: Int32, st: stat)
        do { opened = try dir.openEntry(name) } catch let e as UnsafeEngineFile {
            switch dir.kind(of: name) {
            case .link: throw SafeFSError.linked
            case .directory, .other: throw SafeFSError.notRegular
            case .missing: throw Self.map(e)
            }
        }
        let st = opened.st
        var keep = false
        defer { if !keep { close(opened.fd) } }
        guard st.st_mode & S_IFMT == S_IFREG else { throw SafeFSError.notRegular }
        guard st.st_nlink == 1 else { throw SafeFSError.linked }
        guard st.st_dev == device else { throw SafeFSError.crossDevice }
        guard st.st_uid == getuid() else { throw SafeFSError.notAllowed }
        guard st.st_size <= maxBytes else { throw SafeFSError.tooLarge(Int(st.st_size)) }
        keep = true
        return SafeFile(fd: opened.fd, size: Int(st.st_size), place: place, executable: st.st_mode & S_IXUSR != 0)
    }

    /// The state after entering `directory` (named `name` by the agent) from `state`: by its inode alone.
    private func classify(directory: EngineFiles.OpenDirectory, name: String, under state: State) throws -> State {
        let id = try directory.identity()
        func same(_ key: String) -> Bool { children[key].map { $0.dev == id.dev && $0.ino == id.ino } ?? false }
        switch state {
        case .root:
            guard id.dev == brahmaId.dev, id.ino == brahmaId.ino else { throw SafeFSError.notInPlace }
            return .brahma
        case .brahma:
            for child in ["artifacts", "progress", "handoffs"] where same(child) { return .place(.brahmaChild(child)) }
            if same("resources") { return .resources }
            if same("labs") { return .labs }
            if same("notes") { return .notes }
            throw SafeFSError.notAllowed
        case .resources:
            guard same("resources/company") else { throw SafeFSError.notAllowed }
            return .place(.brahmaChild("resources/company"))
        case .labs:
            guard let ownLab, ownLab.dev == id.dev, ownLab.ino == id.ino else { throw SafeFSError.privateTo(Self.sanitized(name)) }
            return .place(.ownLab)
        case .notes:
            guard same("notes/agents") else { throw SafeFSError.notAllowed }
            return .notesAgents
        case .notesAgents:
            throw SafeFSError.notAllowed
        case .place:
            return state
        }
    }

    // MARK: Names

    /// The components of an agent-named relative path, each checked (`checkComponent`); `.badPath` otherwise.
    static func components(_ path: String) throws -> [String] {
        guard !path.isEmpty else { throw SafeFSError.badPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts { try checkComponent(part) }
        return parts
    }

    /// Refuses `..`, `.`, an empty component, NUL, C0 and C1 controls, DEL, bidi and zero-width characters.
    static func checkComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != ".." else { throw SafeFSError.badPath }
        for scalar in name.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || (0x7F...0x9F).contains(v) || v == 0x2F { throw SafeFSError.badPath }
            if v == 0x061C || v == 0x200E || v == 0x200F || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
                || (0x200B...0x200D).contains(v) || v == 0x2060 || v == 0xFEFF || v == 0x00AD || v == 0x180E {
                throw SafeFSError.badPath
            }
        }
    }

    /// An entry name as an error may carry it: printable ASCII only, at most 64 characters.
    static func sanitized(_ name: String) -> String {
        String(name.unicodeScalars.prefix(64).map { (0x21...0x7E).contains($0.value) ? Character($0) : "?" })
    }

    private static func map(_ e: UnsafeEngineFile) -> SafeFSError {
        if e.problem.contains("symbolic link") { return .linked }
        if e.problem.contains("another hard link") { return .linked }
        if e.problem.contains("not a directory") || e.problem.contains("not a regular file") { return .notRegular }
        return .io(e.description)
    }
}

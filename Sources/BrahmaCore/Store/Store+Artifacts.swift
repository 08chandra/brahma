import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `close(2)` (inside `Store`, `close` names the store's own method).
private func closeFD(_ fd: Int32) { _ = close(fd) }

extension MemorySource {
    /// Plan 4a's memory source: published artifacts, cited as `AR-<n>` (ML's list is open to later plans).
    public static let artifact = MemorySource(rawValue: "artifact")
}

/// The texts `publishArtifact`, `deleteArtifact` and `brahma artifacts` refuse with.
public enum ArtifactMessages {
    public static let outsideWorkspace = "artifacts must be inside your company workspace"
    public static let engineFolder = "that folder can't be published"
    public static let notRegular = "only regular files can be published"
    public static let archive = "this archive expands too much to preview safely"
    public static let fileCap = "artifact files are limited to 50 MB"
    public static let videoCap = "videos are limited to 500 MB"
    public static let folderCap = "folders are limited to 500 files and 200 MB"
    public static let rate = "you can publish \(ArtifactPolicy.publishesPerHour) artifacts per hour"
    public static let playlist = "streaming playlists can't be published; publish the video file"
    public static let needsIndex = "a folder needs index.html"
    public static let folderSymlink = "folders with symlinks can't be published"
    public static let moved = "the file moved while it was being published; publish it again"
    public static let notYourRole = "publish_artifact is not available to your role"
    public static let ownerDeletes = "only the owner can delete artifacts"
    public static let refShape = "artifact keys look like AR-<n>"
    public static let emptyTitle = "the title is empty"
    public static let longTitle = "the title is longer than \(ArtifactPolicy.titleMax) characters"

    /// `"this company's artifacts use <n> GB of 2 GB; delete old ones first"`, `<n>` to one decimal.
    public static func quota(usedBytes: Int64) -> String {
        let gb = Double(1 << 30)
        let used = String(format: "%.1f", Double(usedBytes) / gb)
        return "this company's artifacts use \(used) GB of \(ArtifactPolicy.companyQuotaBytes / (1 << 30)) GB; delete old ones first"
    }

    public static func unsupportedGLTF(_ uri: String) -> String { "unsupported glTF resource \(ReviewDigest.flat(uri, max: 100))" }

    static func unsupported(ext: String) -> String {
        ext.isEmpty ? "files without an extension can't be published" : ".\(ReviewDigest.flat(ext, max: 20)) files can't be published"
    }

    static func missing(_ path: String) -> String { "nothing to publish at \(ReviewDigest.flat(path, max: 200))" }
}

/// Test seams of `Store.publishArtifact`: right after the source was resolved (before anything is opened), and after each
/// chunk copied (with the bytes counted so far).
struct ArtifactPublishHooks {
    var afterResolve: (() -> Void)?
    var duringCopy: ((Int64) -> Void)?

    init(afterResolve: (() -> Void)? = nil, duringCopy: ((Int64) -> Void)? = nil) {
        self.afterResolve = afterResolve; self.duringCopy = duringCopy
    }
}

extension Store {
    /// Bytes an artifact archive may claim uncompressed (zip containers: xlsx, docx, pptx, key, pages, numbers, usdz).
    static let artifactArchiveUncompressed: Int64 = 2 << 30
    /// Directory entries a folder walk visits, and how deep it goes, before the folder is refused whole.
    static let artifactWalkEntries = 10_000
    static let artifactWalkDepth = 32

    // MARK: Publish

    /// Copies a workspace file or folder to `.brahma/artifacts/<number>-<slug(title)>/` and records it as `AR-<number>`.
    ///
    /// - Who: the owner, or an agent of this company whose role has `publish_artifact` (`not in your company` otherwise), at
    ///   most `ArtifactPolicy.publishesPerHour` per agent per rolling hour. `itemKey` must name an item of this company.
    /// - Where: `sourcePath` (relative to `baseDirectory`) is resolved with `realpath`, and must lie inside the resolved
    ///   workspace, outside `.git` and outside `.brahma/` except the caller's own leased worktree.
    /// - How: every directory from the workspace down is opened relative to the one before with `O_NOFOLLOW` (so a part
    ///   swapped for a link after the check is never followed), the file itself with `O_NOFOLLOW | O_NONBLOCK`; `fstat` must
    ///   show a regular file with one link that this user owns (`EngineFiles.copyProblem`). The copy is read from that
    ///   descriptor and counted while it is copied: it stops as soon as a cap is passed. The copy's first bytes must match its
    ///   extension, and a zip container's directory must pass `ArchiveRatio.stats`. A folder needs `index.html` and may hold no
    ///   link; a glTF file brings only the bare-name siblings it names.
    /// - Then, in one transaction: the rate and the company quota, the number, the copy moved into place, the row, its
    ///   memory doc (`MemorySource.artifact`, company access) and the activity line. Any refusal leaves nothing behind.
    public func publishArtifact(companyId: String, by sender: Sender, sourcePath: String, title: String, itemKey: String?,
                                baseDirectory: URL, now: Date = Store.now()) throws -> Artifact {
        try publishArtifact(companyId: companyId, by: sender, sourcePath: sourcePath, title: title, itemKey: itemKey,
                            baseDirectory: baseDirectory, now: now, hooks: ArtifactPublishHooks())
    }

    func publishArtifact(companyId: String, by sender: Sender, sourcePath: String, title: String, itemKey: String?,
                         baseDirectory: URL, now: Date, hooks: ArtifactPublishHooks) throws -> Artifact {
        let cleanTitle = try redact(try Self.artifactTitle(title))

        // Who, for which item, and the caller's own worktree.
        struct Caller {
            var company: Company; var id: String; var handle: String; var isAgent: Bool; var worktreeKey: String?; var itemId: String?
            /// Why the publishing session counts as tainted (ML's rule for agent-written text), or nil.
            var taint: String?
        }
        let caller: Caller = try writer.read { db in
            guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            var c = Caller(company: company, id: "owner", handle: "owner", isAgent: false, worktreeKey: nil, itemId: nil, taint: nil)
            switch sender {
            case .owner: break
            case .system: throw WorkError.forbidden("only the owner or an agent can publish artifacts")
            case .agent(let id):
                let actor = try resolveActor(db, sender, companyId: companyId)
                guard let agent = try Agent.fetchOne(db, key: id),
                      catalog.template(role: agent.role, pack: company.packId).companyTools.contains("publish_artifact") else {
                    throw WorkError.forbidden(ArtifactMessages.notYourRole)
                }
                c.id = id; c.handle = actor.handle; c.isAgent = true
                c.taint = try Self.taintAt(db: db, agentId: id, at: now) ?? (agent.sessionTainted ? "outside content" : nil)
                try Self.checkArtifactRate(db, companyId: companyId, publisherId: id, now: now)
                if let lease = try WorkLease.filter(Column("agentId") == id && Column("companyId") == companyId).fetchOne(db) {
                    c.worktreeKey = try String.fetchOne(db, sql: "SELECT key FROM workItem WHERE id = ? AND companyId = ?",
                                                        arguments: [lease.itemId, companyId])
                }
            }
            if let raw = itemKey?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                guard let item = try WorkItem.filter(Column("companyId") == companyId && Column("key") == raw.uppercased()).fetchOne(db) else {
                    throw WorkError.notFound("no such work item")
                }
                c.itemId = item.id
            }
            return c
        }

        // Where: resolved, confined, then opened without following anything.
        let workspace = URL(fileURLWithPath: caller.company.workspacePath, isDirectory: true)
        let source = try Self.resolveArtifactSource(sourcePath, base: baseDirectory, workspace: workspace,
                                                    ownWorktreeKey: caller.worktreeKey)
        hooks.afterResolve?()
        let rootFd = open(source.root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFd >= 0 else { throw WorkError.invalid("the company workspace can't be opened") }
        defer { closeFD(rootFd) }
        let opened = try Self.openArtifactSource(rootFd, source.parts, shown: sourcePath)
        defer {
            closeFD(opened.fd)
            if opened.parent != rootFd { closeFD(opened.parent) }
        }
        if let here = Self.currentPath(of: opened.fd), here.lowercased() != source.resolved.lowercased() {
            throw WorkError.conflict(ArtifactMessages.moved)
        }
        var st = stat()
        guard fstat(opened.fd, &st) == 0 else { throw WorkError.invalid(ArtifactMessages.notRegular) }
        // The quota, before a byte is copied (checked again, with the bytes copied, when the artifact is recorded).
        let usedBefore = try artifactBytes(companyId: companyId)
        if st.st_mode & S_IFMT == S_IFREG, usedBefore + Int64(st.st_size) > ArtifactPolicy.companyQuotaBytes {
            throw WorkError.conflict(ArtifactMessages.quota(usedBytes: usedBefore))
        }

        // The copy, made in a fresh staging folder of the engine's artifacts folder.
        let artifactsFd: Int32
        do { artifactsFd = try EngineFiles.openDirectory(workspace: workspace, ".brahma/artifacts") } catch let e as UnsafeEngineFile {
            throw WorkError.invalid("the artifacts folder is unsafe: \(e.problem)")
        }
        defer { closeFD(artifactsFd) }
        let shownDir = workspace.appending(path: ".brahma/artifacts").path
        Self.sweepStaleStaging(artifactsFd, shownDir: shownDir, now: Date())
        let staging = "\(Self.stagingPrefix)\(UUID().uuidString)"
        guard mkdirat(artifactsFd, staging, 0o755) == 0 else { throw WorkError.invalid("the artifact could not be stored") }
        var placed: String?
        do {
            let stagingFd = openat(artifactsFd, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard stagingFd >= 0 else { throw WorkError.invalid("the artifact could not be stored") }
            defer { closeFD(stagingFd) }
            let copied: CopiedArtifact
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                copied = try Self.copyArtifactFile(fd: opened.fd, st: st, name: source.parts.last ?? "", parentFd: opened.parent,
                                                   into: stagingFd, hooks: hooks)
            case S_IFDIR:
                copied = try Self.copyArtifactFolder(fd: opened.fd, into: stagingFd, hooks: hooks)
            default:
                throw WorkError.invalid(ArtifactMessages.notRegular)
            }

            let slug = String(Store.slug(for: cleanTitle).prefix(60))
            return try writer.write { db in
                if caller.isAgent { try Self.checkArtifactRate(db, companyId: companyId, publisherId: caller.id, now: now) }
                let used = try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM artifact WHERE companyId = ?",
                                              arguments: [companyId]) ?? 0
                if used + copied.bytes > ArtifactPolicy.companyQuotaBytes {
                    throw WorkError.conflict(ArtifactMessages.quota(usedBytes: used))
                }
                let number = try Self.nextArtifactNumber(db, companyId: companyId)
                let folder = "\(number)-\(slug.isEmpty ? "artifact" : slug)"
                // A leftover of an earlier crash under the new name is the engine's own: it goes.
                var existing = stat()
                if fstatat(artifactsFd, folder, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                    try EngineFiles.removeEntry(dfd: artifactsFd, name: folder, shown: shownDir + "/" + folder)
                }
                guard renameat(artifactsFd, staging, artifactsFd, folder) == 0 else {
                    throw WorkError.invalid("the artifact could not be stored")
                }
                placed = folder
                let artifact = Artifact(id: UUID().uuidString, companyId: companyId, number: number, title: cleanTitle, kind: copied.kind,
                                        storedPath: ".brahma/artifacts/\(folder)", entryFile: copied.entryFile,
                                        sourcePath: source.resolved, publishedById: caller.id, itemId: caller.itemId,
                                        bytes: copied.bytes, createdAt: now)
                try artifact.insert(db)
                try ingest(db: db, MemoryIngestDoc(
                    companyId: companyId, source: .artifact, sourceId: artifact.id, ref: artifact.ref, title: artifact.title,
                    body: "\(artifact.kind.rawValue) artifact: \(artifact.title)", access: .company, readerSet: nil,
                    futureHolders: false, sensitivity: .normal, provenance: artifact.provenance,
                    tainted: caller.taint != nil, taintReason: caller.taint.map { "written by a session that read \($0)" },
                    authorId: artifact.publishedById,
                    itemId: artifact.itemId, createdAt: now), now: now)
                try ActivityEvent(companyId: companyId, agentId: caller.isAgent ? caller.id : nil, turnId: nil, kind: .preview,
                                  text: "\(artifact.ref) published by @\(caller.handle): \(ReviewDigest.flat(artifact.title, max: 200))",
                                  createdAt: now).insert(db)
                return artifact
            }
        } catch {
            if let placed { try? EngineFiles.removeEntry(dfd: artifactsFd, name: placed, shown: shownDir + "/" + placed) }
            try? EngineFiles.removeEntry(dfd: artifactsFd, name: staging, shown: shownDir + "/" + staging)
            throw error
        }
    }

    // MARK: Read and delete

    /// The company's artifacts, newest first.
    public func artifacts(companyId: String, limit: Int = 20) throws -> [Artifact] {
        try writer.read { db in
            try Artifact.filter(Column("companyId") == companyId).order(Column("number").desc).limit(max(0, limit)).fetchAll(db)
        }
    }

    public func latestArtifact(companyId: String) throws -> Artifact? { try artifacts(companyId: companyId, limit: 1).first }

    public func artifact(companyId: String, number: Int) throws -> Artifact? {
        try writer.read { db in
            try Artifact.filter(Column("companyId") == companyId && Column("number") == number).fetchOne(db)
        }
    }

    /// Bytes the company's artifacts hold (the quota counts these).
    public func artifactBytes(companyId: String) throws -> Int64 {
        try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(bytes), 0) FROM artifact WHERE companyId = ?", arguments: [companyId]) ?? 0
        }
    }

    /// Deletes an artifact (owner only): its row, its memory doc (`removeMemoryDoc`) and its copy, which is removed by
    /// descriptor, never through a link.
    public func deleteArtifact(id: String, by sender: Sender, now: Date = Store.now()) throws {
        guard case .owner = sender else { throw WorkError.forbidden(ArtifactMessages.ownerDeletes) }
        let artifact: Artifact = try writer.write { db in
            guard let a = try Artifact.fetchOne(db, key: id) else { throw WorkError.notFound("no such artifact") }
            try a.delete(db)
            try ActivityEvent(companyId: a.companyId, agentId: nil, turnId: nil, kind: .preview,
                              text: "\(a.ref) deleted by the owner", createdAt: now).insert(db)
            return a
        }
        try removeMemoryDoc(companyId: artifact.companyId, source: .artifact, sourceId: artifact.id, now: now)
        guard let company = try company(id: artifact.companyId) else { return }
        let name = (artifact.storedPath as NSString).lastPathComponent
        guard artifact.storedPath == ".brahma/artifacts/\(name)", !name.isEmpty, !name.hasPrefix(".") else { return }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let fd: Int32
        do { fd = try EngineFiles.openDirectory(workspace: workspace, ".brahma/artifacts") } catch let e as UnsafeEngineFile {
            throw WorkError.invalid("the artifacts folder is unsafe: \(e.problem)")
        }
        defer { closeFD(fd) }
        try EngineFiles.removeEntry(dfd: fd, name: name, shown: workspace.appending(path: artifact.storedPath).path)
    }

    // MARK: Rules

    static let stagingPrefix = ".staging-"
    /// A staging folder older than this was left by a publish that never finished (the engine stopped mid-copy).
    static let staleStaging: TimeInterval = 3600

    /// Removes, by descriptor, the staging folders a publish that never finished left behind.
    static func sweepStaleStaging(_ artifactsFd: Int32, shownDir: String, now: Date) {
        for name in DirectoryListing.names(fd: artifactsFd, limit: 10_000) ?? [] where name.hasPrefix(stagingPrefix) {
            var st = stat()
            guard fstatat(artifactsFd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            #if canImport(Darwin)
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            #else
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtim.tv_sec))
            #endif
            guard now.timeIntervalSince(modified) > staleStaging else { continue }
            try? EngineFiles.removeEntry(dfd: artifactsFd, name: name, shown: shownDir + "/" + name)
        }
    }

    /// One line, trimmed, 1…`ArtifactPolicy.titleMax` characters.
    static func artifactTitle(_ raw: String) throws -> String {
        let flat = Store.flattened(raw).trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { throw WorkError.invalid(ArtifactMessages.emptyTitle) }
        guard flat.count <= ArtifactPolicy.titleMax else { throw WorkError.invalid(ArtifactMessages.longTitle) }
        return flat
    }

    static func checkArtifactRate(_ db: Database, companyId: String, publisherId: String, now: Date) throws {
        let recent = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM artifact WHERE companyId = ? AND publishedById = ? AND createdAt > ?
            """, arguments: [companyId, publisherId, now.addingTimeInterval(-3600)]) ?? 0
        if recent >= ArtifactPolicy.publishesPerHour { throw WorkError.conflict(ArtifactMessages.rate) }
    }

    /// One past the highest number the company's artifacts or their memory docs (kept, removed, until purged) have used, so a
    /// deleted `AR-<n>` is never handed to a different artifact while a citation of it can still resolve.
    static func nextArtifactNumber(_ db: Database, companyId: String) throws -> Int {
        let rows = try Int.fetchOne(db, sql: "SELECT MAX(number) FROM artifact WHERE companyId = ?", arguments: [companyId]) ?? 0
        let refs = try String.fetchAll(db, sql: "SELECT ref FROM memoryDoc WHERE companyId = ? AND source = ?",
                                       arguments: [companyId, MemorySource.artifact.rawValue])
        return max(rows, refs.compactMap(Artifact.parseRef).max() ?? 0) + 1
    }

    /// The resolved source: the workspace's real path, the source's, and the parts between them.
    struct ArtifactSource { var root: String; var resolved: String; var parts: [String] }

    /// `realpath` of the source, which must be inside the resolved workspace, outside `.git`, and outside `.brahma/` unless it
    /// is inside the caller's own leased worktree (`.brahma/wt/<KEY>`, itself a real directory there).
    static func resolveArtifactSource(_ raw: String, base: URL, workspace: URL, ownWorktreeKey: String?) throws -> ArtifactSource {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\0") else { throw WorkError.invalid("give the path of a file or folder to publish") }
        let candidate = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appending(path: path)
        guard let root = realPath(workspace.path) else { throw WorkError.invalid("the company workspace is missing") }
        guard let resolved = realPath(candidate.path) else { throw WorkError.notFound(ArtifactMessages.missing(path)) }
        if resolved == root { throw WorkError.forbidden(ArtifactMessages.engineFolder) }
        guard resolved.hasPrefix(root + "/") else { throw WorkError.forbidden(ArtifactMessages.outsideWorkspace) }
        let parts = resolved.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        if parts.contains(where: { $0.lowercased() == ".git" }) { throw WorkError.forbidden(ArtifactMessages.engineFolder) }
        if parts.first?.lowercased() == ".brahma" {
            guard let key = ownWorktreeKey, parts.count >= 3, parts[1] == "wt", parts[2] == key,
                  let worktree = realPath(GitWorkspace(root: workspace).worktreePath(key: key).path),
                  worktree.lowercased() == (root + "/.brahma/wt/" + key).lowercased(),
                  resolved == worktree || resolved.hasPrefix(worktree + "/") else {
                throw WorkError.forbidden(ArtifactMessages.engineFolder)
            }
        }
        return ArtifactSource(root: root, resolved: resolved, parts: parts)
    }

    /// Each directory of `parts` opened relative to the one before with `O_NOFOLLOW | O_DIRECTORY`, then the last part with
    /// `O_NOFOLLOW | O_NONBLOCK` (a FIFO opens at once and is refused by its type). Returns the last part's descriptor and its
    /// directory's (which is `rootFd` for a part directly in the workspace).
    static func openArtifactSource(_ rootFd: Int32, _ parts: [String], shown: String) throws -> (parent: Int32, fd: Int32) {
        guard !parts.isEmpty else { throw WorkError.forbidden(ArtifactMessages.engineFolder) }
        var dir = rootFd
        for (i, part) in parts.enumerated() {
            let last = i == parts.count - 1
            let flags = last ? (O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) : (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let next = openat(dir, part, flags)
            if next < 0 {
                let err = errno
                if dir != rootFd { closeFD(dir) }
                if err == ENOENT { throw WorkError.notFound(ArtifactMessages.missing(shown)) }
                throw WorkError.invalid(ArtifactMessages.notRegular)
            }
            if last { return (dir, next) }
            if dir != rootFd { closeFD(dir) }
            dir = next
        }
        throw WorkError.invalid(ArtifactMessages.notRegular)
    }

    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Where the descriptor's file is now (nil where the platform can't say).
    static func currentPath(of fd: Int32) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
        #else
        return try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/\(fd)")
        #endif
    }

    // MARK: Copying

    struct CopiedArtifact { var kind: ArtifactKind; var entryFile: String; var bytes: Int64 }

    /// What is left of a folder's (or a glTF set's) caps.
    struct ArtifactBudget {
        var files = 0
        var bytes: Int64 = 0
        mutating func take(file size: Int64) throws {
            files += 1
            if files > ArtifactPolicy.maxFiles || bytes + size > Int64(ArtifactPolicy.maxFolderBytes) {
                throw WorkError.invalid(ArtifactMessages.folderCap)
            }
        }
        var remaining: Int64 { Int64(ArtifactPolicy.maxFolderBytes) - bytes }
    }

    /// One file at `fd`: its kind by extension (playlists and unknown kinds refused), the size cap, the counted copy, the
    /// content checks on the copy, and for glTF the bare-name siblings it names (from `parentFd`).
    static func copyArtifactFile(fd: Int32, st: stat, name: String, parentFd: Int32, into dir: Int32,
                                 hooks: ArtifactPublishHooks) throws -> CopiedArtifact {
        let ext = ArtifactKind.ext(of: name)
        if ArtifactKind.playlistExtensions.contains(ext) { throw WorkError.invalid(ArtifactMessages.playlist) }
        guard let kind = ArtifactKind.from(ext: ext) else { throw WorkError.invalid(ArtifactMessages.unsupported(ext: ext)) }
        if EngineFiles.copyProblem(st) != nil { throw WorkError.invalid(ArtifactMessages.notRegular) }
        let (cap, capMessage) = fileCap(kind)
        if Int64(st.st_size) > cap { throw WorkError.invalid(capMessage) }
        let entry = ResourceIntake.sanitizeName(name)
        var total = try copyCounting(from: fd, into: dir, name: entry, cap: cap, capMessage: capMessage, hooks: hooks)
        try checkContent(dir: dir, name: entry, kind: kind, ext: ext)
        if ext == "gltf" {
            var budget = ArtifactBudget()
            try budget.take(file: total)
            budget.bytes = total
            total += try copyGLTFSiblings(gltf: entry, into: dir, from: parentFd, budget: &budget, hooks: hooks)
        }
        return CopiedArtifact(kind: kind, entryFile: entry, bytes: total)
    }

    /// A folder at `fd`: `index.html` at its top, no link anywhere in it, every regular file copied under the folder caps
    /// (and its own per-file cap), its content checked when its kind is known. `.git` and `.DS_Store` are left out.
    static func copyArtifactFolder(fd: Int32, into dir: Int32, hooks: ArtifactPublishHooks) throws -> CopiedArtifact {
        var index = stat()
        guard fstatat(fd, "index.html", &index, AT_SYMLINK_NOFOLLOW) == 0, index.st_mode & S_IFMT == S_IFREG else {
            throw WorkError.invalid(ArtifactMessages.needsIndex)
        }
        var budget = ArtifactBudget()
        var visited = 0
        func walk(_ src: Int32, _ dst: Int32, depth: Int) throws {
            guard let names = DirectoryListing.names(fd: src, limit: artifactWalkEntries - visited + 1) else {
                throw WorkError.invalid("the folder can't be read")
            }
            for name in names.sorted() {
                visited += 1
                if visited > artifactWalkEntries { throw WorkError.invalid(ArtifactMessages.folderCap) }
                if name == ".DS_Store" || name == ".git" { continue }
                var est = stat()
                guard fstatat(src, name, &est, AT_SYMLINK_NOFOLLOW) == 0 else { throw WorkError.invalid(ArtifactMessages.notRegular) }
                switch est.st_mode & S_IFMT {
                case S_IFLNK:
                    throw WorkError.invalid(ArtifactMessages.folderSymlink)
                case S_IFDIR:
                    if depth + 1 > artifactWalkDepth { throw WorkError.invalid(ArtifactMessages.folderCap) }
                    let child = openat(src, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard child >= 0 else { throw WorkError.invalid(ArtifactMessages.notRegular) }
                    defer { closeFD(child) }
                    var cst = stat()
                    guard fstat(child, &cst) == 0, FileIdentity(est).sameFile(cst) else { throw WorkError.conflict(ArtifactMessages.moved) }
                    guard mkdirat(dst, name, 0o755) == 0 else { throw WorkError.invalid("the artifact could not be stored") }
                    let out = openat(dst, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard out >= 0 else { throw WorkError.invalid("the artifact could not be stored") }
                    defer { closeFD(out) }
                    try walk(child, out, depth: depth + 1)
                case S_IFREG:
                    let file = openat(src, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard file >= 0 else { throw WorkError.invalid(ArtifactMessages.notRegular) }
                    defer { closeFD(file) }
                    var fst = stat()
                    guard fstat(file, &fst) == 0, FileIdentity(est).sameFile(fst) else { throw WorkError.conflict(ArtifactMessages.moved) }
                    let copied = try copyMember(file: file, st: fst, name: name, into: dst, budget: &budget, hooks: hooks)
                    budget.bytes += copied
                default:
                    throw WorkError.invalid(ArtifactMessages.notRegular)
                }
            }
        }
        try walk(fd, dir, depth: 0)
        // What was copied is what counts: `index.html` may have gone between the first look and the walk.
        guard fstatat(dir, "index.html", &index, AT_SYMLINK_NOFOLLOW) == 0, index.st_mode & S_IFMT == S_IFREG else {
            throw WorkError.invalid(ArtifactMessages.needsIndex)
        }
        return CopiedArtifact(kind: .html, entryFile: "index.html", bytes: budget.bytes)
    }

    /// A file inside a folder or a glTF set: regular and single-linked, not a playlist or an executable type, under its own cap
    /// and what is left of the set's; counted while copied; its content checked when its kind is known (a file of no known kind,
    /// such as a web font or a glTF buffer, is copied as bytes: nothing in the engine reads it).
    static func copyMember(file: Int32, st: stat, name: String, into dir: Int32, budget: inout ArtifactBudget,
                           hooks: ArtifactPublishHooks) throws -> Int64 {
        if EngineFiles.copyProblem(st) != nil { throw WorkError.invalid(ArtifactMessages.notRegular) }
        let ext = ArtifactKind.ext(of: name)
        if ArtifactKind.playlistExtensions.contains(ext) { throw WorkError.invalid(ArtifactMessages.playlist) }
        if ResourcePolicy.refusedExt.contains(ext) { throw WorkError.invalid(ArtifactMessages.unsupported(ext: ext)) }
        let kind = ArtifactKind.from(ext: ext)
        let (fileCap, fileMessage) = fileCap(kind)
        if Int64(st.st_size) > fileCap { throw WorkError.invalid(fileMessage) }
        try budget.take(file: Int64(st.st_size))
        let folderLimited = budget.remaining < fileCap
        let copied = try copyCounting(from: file, into: dir, name: name, cap: min(fileCap, budget.remaining),
                                      capMessage: folderLimited ? ArtifactMessages.folderCap : fileMessage, hooks: hooks)
        if let kind { try checkContent(dir: dir, name: name, kind: kind, ext: ext) }
        return copied
    }

    /// The glTF's `buffers[].uri` and `images[].uri`, read from the copy: `data:` URIs stay embedded; anything else must be a
    /// bare file name next to it (letters, digits, `-`, `_`, `.` and spaces, not starting with a dot), opened from its folder
    /// without following a link. Returns the bytes copied.
    static func copyGLTFSiblings(gltf: String, into dir: Int32, from parentFd: Int32, budget: inout ArtifactBudget,
                                 hooks: ArtifactPublishHooks) throws -> Int64 {
        let copy = openat(dir, gltf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard copy >= 0 else { throw WorkError.invalid("the artifact could not be stored") }
        let data = (try? readAll(fd: copy, limit: ArtifactPolicy.maxFileBytes)) ?? Data()
        closeFD(copy)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        var uris: [String] = []
        for key in ["buffers", "images"] {
            for entry in json[key] as? [[String: Any]] ?? [] { if let uri = entry["uri"] as? String { uris.append(uri) } }
        }
        var seen: Set<String> = [gltf]
        var total: Int64 = 0
        for uri in uris {
            if uri.lowercased().hasPrefix("data:") { continue }
            guard isBareSiblingName(uri) else { throw WorkError.invalid(ArtifactMessages.unsupportedGLTF(uri)) }
            guard seen.insert(uri).inserted else { continue }
            let file = openat(parentFd, uri, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if file < 0 {
                if errno == ENOENT { throw WorkError.notFound("the glTF resource \(uri) is missing") }
                throw WorkError.invalid(ArtifactMessages.notRegular)
            }
            defer { closeFD(file) }
            var st = stat()
            guard fstat(file, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw WorkError.invalid(ArtifactMessages.notRegular) }
            let bytes = try copyMember(file: file, st: st, name: uri, into: dir, budget: &budget, hooks: hooks)
            budget.bytes += bytes
            total += bytes
        }
        return total
    }

    static func isBareSiblingName(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 200, !s.hasPrefix(".") else { return false }
        return s.unicodeScalars.allSatisfy { u in
            (u.isASCII && (CharacterSet.alphanumerics.contains(u))) || u == "-" || u == "_" || u == "." || u == " "
        }
    }

    /// The per-file cap of a kind and its refusal.
    static func fileCap(_ kind: ArtifactKind?) -> (Int64, String) {
        kind == .video ? (Int64(ArtifactPolicy.maxVideoBytes), ArtifactMessages.videoCap)
            : (Int64(ArtifactPolicy.maxFileBytes), ArtifactMessages.fileCap)
    }

    /// Copies from `fd` (read with `pread` from offset 0, never reopened by path) into a new `name` in `dir` (created with
    /// `O_EXCL | O_NOFOLLOW`), counting while it copies: past `cap` it stops and throws `capMessage`.
    static func copyCounting(from fd: Int32, into dir: Int32, name: String, cap: Int64, capMessage: String,
                             hooks: ArtifactPublishHooks) throws -> Int64 {
        let out = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard out >= 0 else { throw WorkError.invalid("the artifact could not be stored") }
        defer { closeFD(out) }
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total: Int64 = 0
        while true {
            let want = Int(min(Int64(buffer.count), max(cap - total, 0) + 1))
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(total)) }
            if n < 0 {
                if errno == EINTR { continue }
                throw WorkError.invalid("the file can't be read")
            }
            if n == 0 { break }
            total += Int64(n)
            if total > cap { throw WorkError.invalid(capMessage) }
            var written = 0
            while written < n {
                let w = buffer.withUnsafeBytes { write(out, $0.baseAddress! + written, n - written) }
                if w < 0 {
                    if errno == EINTR { continue }
                    throw WorkError.invalid("the artifact could not be stored")
                }
                written += w
            }
            hooks.duringCopy?(total)
        }
        return total
    }

    /// The copy's first bytes must match its extension (`ArtifactSniffer`); a zip container's central directory must not claim
    /// more than `ResourcePolicy.maxArchiveRatio` times its size or more than 2 GB, too many entries, a link or an unsafe name.
    static func checkContent(dir: Int32, name: String, kind: ArtifactKind, ext: String) throws {
        let fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkError.invalid("the artifact could not be stored") }
        defer { closeFD(fd) }
        var head = [UInt8](repeating: 0, count: ArtifactSniffer.headBytes)
        let n = head.withUnsafeMutableBytes { pread(fd, $0.baseAddress, ArtifactSniffer.headBytes, 0) }
        guard n >= 0 else { throw WorkError.invalid("the artifact could not be stored") }
        guard ArtifactSniffer.matches(kind: kind, ext: ext, head: Data(head.prefix(n))) else {
            throw WorkError.invalid(ArtifactSniffer.mismatch(ext: ext))
        }
        guard ArtifactKind.isZipContainer(ext: ext) else { return }
        guard let stats = try? ArchiveRatio.stats(fd: fd), stats.ratio <= Double(ResourcePolicy.maxArchiveRatio),
              stats.uncompressedBytes <= artifactArchiveUncompressed, stats.entries <= ResourcePolicy.maxArchiveEntries,
              !stats.hasSymlink, !stats.hasUnsafeName else {
            throw WorkError.invalid(ArtifactMessages.archive)
        }
    }

    /// At most `limit` bytes from offset 0 of `fd`.
    static func readAll(fd: Int32, limit: Int) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while out.count <= limit {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(out.count)) }
            if n < 0 { if errno == EINTR { continue }; throw WorkError.invalid("the file can't be read") }
            if n == 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }
}

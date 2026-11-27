import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Plan C Task C5: the name an exported file gets (Save As): the shown name made safe for a file system and honest about
/// what the bytes are.
public enum ExportName {
    public static let maxName = 120

    /// `display` with control, bidi and zero-width characters removed (ML's `ResourceIntake.sanitizeName`: NFC, white space
    /// runs one space, at most `maxName` characters keeping the extension, `file` when nothing is left), `/`, `\` and `:`
    /// turned into `-`, then `.<realExt>` appended when the visible extension is not `realExt` (`photo.png` holding HTML →
    /// `photo.png.html`). `realExt` keeps only ASCII letters and digits (at most 16); empty appends nothing.
    public static func sanitize(_ display: String, realExt: String) -> String {
        var name = component(display)
        let ext = String(String.UnicodeScalarView(realExt.unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0))
        }).prefix(16)).lowercased()
        if !ext.isEmpty, ArtifactKind.ext(of: name).lowercased() != ext { name += "." + ext }
        return name
    }

    /// One path component: `ResourceIntake.sanitizeName`, then `/`, `\` and `:` as `-`; never `.` or `..`.
    static func component(_ raw: String) -> String {
        let clean = ResourceIntake.sanitizeName(raw)
        let mapped = String(String.UnicodeScalarView(clean.unicodeScalars.map { ["/", "\\", ":"].contains($0) ? "-" : $0 }))
        return mapped == "." || mapped == ".." || mapped.isEmpty ? "file" : String(mapped.prefix(maxName))
    }
}

/// Plan C Task C5: the bounds of an export.
public enum ExportLimits {
    /// A folder export (an artifact folder, zipped): at most this many files, this many bytes in all and this deep.
    public static let maxFiles = ResourcePolicy.maxArchiveEntries
    public static let maxBytes = ArchiveLimits.maxBytes
    public static let maxDepth = ResourcePolicy.maxDepth
    /// How long `ditto` may take to zip a folder.
    public static let zipTimeout: TimeInterval = 120
}

extension Store {
    /// The owner's Save As (design §4.4): writes what `ref` holds to `destination`, a path the owner chose (the app's save
    /// panel, the CLI's argument), never one an agent named. In this order:
    /// 1. **Where.** The folder must exist and must not be (or be inside) the data home, the vault, the workspaces root, a
    ///    company's workspace, or any `.brahma` folder: an export never lands where agents read or where Brahma keeps its own
    ///    files. The file's name is the destination's, through `ExportName.sanitize` with the bytes' real extension.
    /// 2. **What.** The ref resolved for the owner (`.full`, not purged) and its bytes read whole (`readContent`: git through
    ///    `SafeGit.catFile`, the vault, a diff or commit as its `.patch`); an artifact folder of more than one file is read file
    ///    by file through `SafeFS` (no link followed) and zipped with `ditto -c -k` (Darwin; elsewhere `"folder export needs
    ///    macOS"`). A resource folder or link, and records with no content (agents, channels, previews, releases, sprints,
    ///    facts) are refused.
    /// 3. **The secret gate, again** (`Store.gatedBytes` with `knownValues` and `archives`): a stored value refuses the export;
    ///    a pattern in text exports its redacted copy (`SecretGate.redactedCopy`); a vouched PDF exports its flattened copy,
    ///    never the original; a pattern in bytes that can't be redacted refuses.
    /// 4. **Write.** Through the folder's descriptor only (`exportFolder`, `writeExport`; fix round 1): a temporary file
    ///    created exclusively, marked downloaded (`Quarantine.mark(fd:)`: a mark that can't be set removes the file and
    ///    refuses), then renamed over the name while the folder is still the one at its path (else nothing is saved).
    /// 5. **Record.** An `.export` activity line `ownerExport <canonical>` (the name gated as messages show it) and a
    ///    `refRead(via: export)` row with the saved path (`exportPath`, which a purge lists as a copy outside Brahma).
    /// Returns the file written.
    @discardableResult
    public func exportRef(companyId: String, ref: WorkRef, to destination: URL, knownValues: [(name: String, value: String)],
                          paths: BrahmaPaths, archives: any ArchiveReader = UnavailableArchiveReader(),
                          now: Date = Store.now(), owner: OwnerPrincipal) throws -> URL {
        try ProcessRole.refuseInAgentProcess()  // final wave B1 (FR I-2): an owner read, never from an agent process
        let canonical = ref.canonical
        let shown = SecretGate.shown(canonical, knownValues: knownValues)
        let folder = try exportFolder(destination, paths: paths)
        guard try company(id: companyId) != nil else { throw WorkError.notFound(Self.refUnavailable) }
        let r = try resolveDetailed(ref, reader: .owner, companyId: companyId, messageRefId: nil)
        guard r.resolved.visibility == .full, let subject = r.subject, let company = r.company else {
            throw WorkError.notFound(Self.refUnavailable)
        }
        guard r.resolved.state != .purged else { throw WorkError.invalid(Self.purgedText) }
        switch subject.record {
        case .file, .diff, .diffRange, .commit, .item, .ask, .kb, .memory, .run, .message, .artifact:
            break
        case .resource(let res):
            guard res.kind == .file else { throw WorkError.invalid("\(res.ref) is a \(res.kind.rawValue); export its files one by one") }
        case .preview, .release, .agent, .channel, .sprint, .fact:
            throw WorkError.invalid("\(shown) is a live record with no file to export")
        }

        var data: Data
        var ext: String
        var rev: String?
        do {
            if case .artifact(let a) = subject.record, let files = try artifactFolderFiles(a, company: company), files.count > 1 {
                data = try zipArtifact(a, files: files, companyId: companyId, archives: archives, knownValues: knownValues, paths: paths)
                ext = "zip"
            } else {
                let content = try readContent(r, subject: subject, company: company, paths: paths, whole: true, knownValues: knownValues)
                let gated = try gatedBytes(content.data, ext: content.ext, canonical: canonical, companyId: companyId, archives: archives,
                                           knownValues: knownValues, paths: paths)
                data = gated.data
                ext = gated.isFlattenedCopy ? "pdf" : content.ext
                rev = content.rev
                if case .pattern = gated.verdict {
                    data = try SecretGate.redactedCopy(data, ext: ext, canonical: canonical, archives: archives, knownValues: knownValues,
                                                       store: self)
                }
            }
        } catch let e as WorkError {
            throw e
        } catch {
            refTrace(companyId: companyId, "an export of \(shown) couldn't be read (\(Store.flat("\(error)", max: 200)))", now: now)
            throw WorkError.notFound(Self.refUnavailable)
        }

        let name = ExportName.sanitize(destination.lastPathComponent, realExt: ext)
        // Fix round 1 (review M1): the record is written in the transaction that renames the file into place; no record, no
        // file (a copy no purge could list).
        return try writeExport(data, folder: folder, name: name) { db, path in
            // Re-review N1: by the canonical form without its pin (`@<rev>`), as purge looks it up; the pin is in `rev`.
            try Self.recordRefRead(db: db, companyId: companyId, reader: .owner, canonical: Self.unpinned(ref).canonical,
                                   rev: rev ?? ref.rev, bytes: data.count,
                                   tainted: r.resolved.tainted, via: "export", turnId: nil, now: now, exportPath: path)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .export, text: try redact("ownerExport \(shown)"),
                              createdAt: now).insert(db)
        }
    }

    // MARK: Where

    /// The folder `destination` is in, opened once (fix round 1, ruling (3)): its real path walked from `/` one directory at a
    /// time with `O_DIRECTORY | O_NOFOLLOW` (a link anywhere on the way, or a part swapped while it is walked, refuses), then
    /// refused (`WorkError.forbidden`) when the kernel's path for the open descriptor is (inside) the data home, the vault, the
    /// workspaces root, a company's workspace or a `.brahma` folder. Every later step writes through this descriptor.
    func exportFolder(_ destination: URL, paths: BrahmaPaths) throws -> ExportFolder {
        let name = destination.lastPathComponent
        guard destination.isFileURL, !name.isEmpty, name != "/", name != ".", name != ".." else {
            throw WorkError.invalid("choose a file name to save as")
        }
        guard let real = Store.realPath(destination.deletingLastPathComponent().path) else {
            throw WorkError.invalid("the folder to save in doesn't exist")
        }
        try Self.refuseToolConfigName(name)
        let folder = try ExportFolder(walking: real)
        let refusal = WorkError.forbidden("Brahma doesn't save exports inside its own data folder or a company workspace; choose another folder")
        let lower = folder.path.lowercased()
        if lower.split(separator: "/").contains(where: { $0 == ".brahma" }) { throw refusal }
        // Fix round 1 (controller): never where other tools read config they execute, inside a workspace or not. Checked on the
        // kernel's path for the descriptor the walk opened (no link on the way), so a link can't hide one.
        try Self.refuseToolConfigFolder(folder.path)
        var roots = [paths.home, paths.workspaces, paths.vaultDir].map(\.path) + (dataHome.map { [$0.path] } ?? [])
        roots += try companies().map(\.workspacePath)
        for root in roots {
            let resolved = (Store.realPath(root) ?? URL(fileURLWithPath: root).standardizedFileURL.path).lowercased()
            guard !resolved.isEmpty, resolved != "/" else { continue }
            if lower == resolved || lower.hasPrefix(resolved + "/") { throw refusal }
        }
        return folder
    }

    /// Writes `data` as `name` in `folder`, only through its descriptor: a temporary file created exclusively (`openat`,
    /// `O_EXCL | O_NOFOLLOW`), written and synced, marked downloaded on its descriptor, then — only while the folder is still
    /// the one at its path (else the temporary file is removed and nothing is saved) — renamed over `name` (`renameat`: a
    /// link at the name is replaced, never followed). A directory at `name` refuses.
    ///
    /// Fix round 1 (review M1): `record` runs in a write transaction with the final path, and the rename is that
    /// transaction's last step: a record that fails leaves no file, and a commit that fails after the rename removes it.
    func writeExport(_ data: Data, folder: ExportFolder, name: String, record: (Database, String) throws -> Void) throws -> URL {
        try Self.refuseToolConfigName(name)          // the final name, after sanitizing (which may add an extension)
        try refHooks.afterExportFolderOpened?()
        let dfd = folder.fd
        var st = stat()
        if fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFDIR {
            throw WorkError.invalid("a folder named \(Store.flat(name, max: 120)) is already there; choose another name")
        }
        let temp = ".export-\(UUID().uuidString.lowercased()).part"
        let fd = openat(dfd, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw WorkError.invalid("the file couldn't be created there (\(String(cString: strerror(errno))))") }
        var ok = false
        defer { if !ok { unlinkat(dfd, temp, 0) } }
        do {
            defer { closeFD(fd) }
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw WorkError.invalid("the file couldn't be written (\(String(cString: strerror(errno))))")
                    }
                    offset += n
                }
            }
            guard fsync(fd) == 0 else { throw WorkError.invalid("the file couldn't be written (\(String(cString: strerror(errno))))") }
            do { try Quarantine.mark(fd: fd) } catch {
                throw WorkError.invalid("the exported file couldn't be marked as downloaded (\(error)); nothing was saved")
            }
        }
        let final = URL(fileURLWithPath: folder.path).appending(path: name)
        var renamed = false
        do {
            try writer.write { db in
                try record(db, final.path)
                guard folder.isInPlace else { throw WorkError.invalid(ExportFolder.movedRefusal) }
                guard renameat(dfd, temp, dfd, name) == 0 else {
                    throw WorkError.invalid("the file couldn't be saved as \(Store.flat(name, max: 120)) (\(String(cString: strerror(errno))))")
                }
                renamed = true
            }
        } catch {
            if renamed { unlinkat(dfd, name, 0) }
            throw error
        }
        ok = true
        return final
    }

    /// Fix round 1 (controller): what other tools execute as config. A folder component `.claude` or `.git`, or `.github`
    /// followed by `workflows`; a file named `CLAUDE.md` or `.mcp.json` (or `.claude`, `.git`). Case-insensitive (NFC, then
    /// folded: `folded`).
    static let toolConfigRefusal = "Brahma doesn't save exports where other tools read their configuration (.claude, .git, .github/workflows, CLAUDE.md, .mcp.json); choose another place"

    /// Re-review N2: NFKC, then a Unicode case fold (`ſ` → `s`), width and diacritics folded too.
    static func folded(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .precomposedStringWithCompatibilityMapping
    }

    static func refuseToolConfigFolder(_ path: String) throws {
        let parts = folded(path).split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            if part == ".claude" || part == ".git" { throw WorkError.forbidden(toolConfigRefusal) }
            if part == ".github", i + 1 < parts.count, parts[i + 1] == "workflows" { throw WorkError.forbidden(toolConfigRefusal) }
        }
    }

    static func refuseToolConfigName(_ name: String) throws {
        let n = folded(name)
        if ["claude.md", ".mcp.json", ".claude", ".git"].contains(n) { throw WorkError.forbidden(toolConfigRefusal) }
    }

    // MARK: Artifact folders

    /// The files of an artifact's folder (`.brahma/artifacts/<number>-<slug>`, paths relative to it, sorted), read through
    /// `SafeFS` (a descriptor walk: no link is followed, a link or anything not a regular file is left out), within
    /// `ExportLimits`; nil when the folder is not where 4a puts it.
    func artifactFolderFiles(_ a: Artifact, company: Company) throws -> [(path: String, data: Data)]? {
        guard RefAccess.artifactFolder(a) != nil else { return nil }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let fs = try SafeFS(workspace: workspace, ownHandle: nil)
        // The entry file first: the folder exists and is readable as 4a wrote it (nothing is created by the walk below).
        _ = try fs.open(workspacePath: "\(a.storedPath)/\(a.entryFile)", maxBytes: ExportLimits.maxBytes)
        let top = try EngineFiles.openWalked(workspace: workspace, a.storedPath)
        var files: [(path: String, data: Data)] = []
        var total = 0
        let tooLarge = WorkError.invalid("\(a.ref) is too large to export as a folder")
        func walk(_ dir: EngineFiles.OpenDirectory, _ prefix: String, depth: Int) throws {
            guard depth <= ExportLimits.maxDepth else { throw tooLarge }
            for name in try dir.names(limit: ExportLimits.maxFiles + 1, byteLimit: 4 << 20).sorted() {
                let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
                switch dir.kind(of: name) {
                case .directory:
                    try walk(try dir.child(name), rel, depth: depth + 1)
                case .other:
                    guard files.count < ExportLimits.maxFiles else { throw tooLarge }
                    let file: SafeFile
                    do {
                        file = try fs.open(workspacePath: "\(a.storedPath)/\(rel)", maxBytes: ExportLimits.maxBytes - total)
                    } catch SafeFSError.tooLarge {
                        throw tooLarge
                    } catch is SafeFSError {
                        continue        // not a regular file of this user with one link: never exported
                    }
                    let data = try file.readAll()
                    total += data.count
                    guard total <= ExportLimits.maxBytes else { throw tooLarge }
                    files.append((rel, data))
                case .link, .missing:
                    continue
                }
            }
        }
        try walk(top, "", depth: 0)
        return files
    }

    /// `files` gated one by one (`gatedBytes`, canonical `AR-<n>/<path>`: a stored value refuses, a pattern in text is
    /// redacted, a vouched PDF is its flattened copy), staged under `<data home>/tmp` (0700) with sanitized names, and
    /// zipped with `ditto -c -k` (no resource forks, extended attributes or ACLs). Darwin only.
    func zipArtifact(_ a: Artifact, files: [(path: String, data: Data)], companyId: String, archives: any ArchiveReader,
                     knownValues: [(name: String, value: String)], paths: BrahmaPaths) throws -> Data {
        #if canImport(Darwin)
        var gated: [(path: [String], data: Data)] = []
        for f in files {
            let ext = ArtifactKind.ext(of: f.path)
            let canonical = "\(a.ref)/\(f.path)"
            let g = try gatedBytes(f.data, ext: ext, canonical: canonical, companyId: companyId, archives: archives, knownValues: knownValues,
                                   paths: paths)
            var data = g.data
            if case .pattern = g.verdict {
                data = try SecretGate.redactedCopy(data, ext: ext, canonical: canonical, archives: archives, knownValues: knownValues, store: self)
            }
            gated.append((f.path.split(separator: "/").map { ExportName.component(String($0)) }, data))
        }
        let fm = FileManager.default
        // Fix round 1 (review M3): staged under the engine's own data home (`<home>/tmp`, 0700), never the per-user TMPDIR
        // agents share; no fallback.
        let tmp = paths.home.appending(path: "tmp", directoryHint: .isDirectory)
        try BrahmaPaths.ensurePrivateDirectory(tmp)
        let stage = tmp.appending(path: "export-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try BrahmaPaths.ensurePrivateDirectory(stage)
        defer { try? fm.removeItem(at: stage) }
        let root = stage.appending(path: ExportName.component((a.storedPath as NSString).lastPathComponent), directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        var taken = Set<String>()
        for (parts, data) in gated {
            var parts = parts
            // Names that only sanitizing made equal get a number, so no file overwrites another.
            var key = parts.joined(separator: "/").lowercased()
            var n = 2
            while taken.contains(key), let last = parts.last {
                let ext = ArtifactKind.ext(of: last)
                let stem = ext.isEmpty ? last : String(last.dropLast(ext.count + 1))
                parts[parts.count - 1] = "\(stem)-\(n)" + (ext.isEmpty ? "" : ".\(ext)")
                key = parts.joined(separator: "/").lowercased()
                n += 1
            }
            taken.insert(key)
            var dir = root
            for part in parts.dropLast() {
                dir = dir.appending(path: part, directoryHint: .isDirectory)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            guard fm.createFile(atPath: dir.appending(path: parts.last ?? "file").path, contents: data, attributes: [.posixPermissions: 0o644]) else {
                throw WorkError.invalid("\(a.ref) couldn't be staged for export")
            }
        }
        let zip = stage.appending(path: "export.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noacl", "--keepParent", root.path, zip.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = AwakeTime.deadline(after: .seconds(ExportLimits.zipTimeout))
        while process.isRunning, AwakeTime.now < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw WorkError.invalid("zipping \(a.ref) took too long; try again")
        }
        guard process.terminationStatus == 0 else { throw WorkError.invalid("\(a.ref) couldn't be zipped for export") }
        return try Data(contentsOf: zip)
        #else
        throw WorkError.invalid("folder export needs macOS")
        #endif
    }
}

/// `close(2)` (a `Store` method shadows the name inside its extensions).
private func closeFD(_ fd: Int32) { _ = close(fd) }

/// C5 fix round 1, ruling (3): the folder an export is saved in, held open. Opened by walking its real path from `/` with
/// `O_DIRECTORY | O_NOFOLLOW` at every step, so no link is followed on the way; `path` is the kernel's path for the
/// descriptor.
final class ExportFolder {
    static let movedRefusal = "the folder to save in was moved or replaced while saving; nothing was saved"
    static let changedRefusal = "the folder to save in changed while it was opened; choose it again"

    let fd: Int32
    let path: String

    init(walking real: String) throws {
        guard real.hasPrefix("/") else { throw WorkError.invalid("the folder to save in doesn't exist") }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw WorkError.invalid(Self.changedRefusal) }
        for part in real.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            closeFD(current)
            guard next >= 0 else { throw WorkError.invalid(Self.changedRefusal) }
            current = next
        }
        guard let kernel = Self.kernelPath(current) else {
            closeFD(current)
            throw WorkError.invalid(Self.changedRefusal)
        }
        fd = current
        path = kernel
    }

    deinit { closeFD(fd) }

    /// Still the directory at `path`: the kernel's path for the descriptor is unchanged, and `path` (its last part not
    /// followed) names this same directory by (device, inode).
    var isInPlace: Bool {
        guard Self.kernelPath(fd) == path else { return false }
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, lstat(path, &named) == 0 else { return false }
        return held.st_dev == named.st_dev && held.st_ino == named.st_ino && named.st_mode & S_IFMT == S_IFDIR
    }

    static func kernelPath(_ fd: Int32) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        return Store.realPath("/proc/self/fd/\(fd)")
        #endif
    }
}

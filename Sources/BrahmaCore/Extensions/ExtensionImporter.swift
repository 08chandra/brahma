import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The decomposing importer (Task 5a, skill-only, §3.3): every source is copied into `<home>/extensions/staging/<uuid>/`
// under the limits (no links, devices or odd names; nothing outside the package root), then decomposed: the plugin parts
// are kept, `bin/` helpers are renamed `<id>-*`, and every part Brahma does not run (MCP servers, hooks, LSP, monitors,
// settings, output styles, themes, workflows, channels, userConfig, dependencies, a root CLAUDE.md) is dropped with a
// notice, as is every top-level entry outside the allowlist. A zip is inventoried (central directory) and refused on any
// limit before `/usr/bin/unzip` runs under the sandboxed runner. Brahma copies plugin folders itself; it never asks the
// Claude CLI to install anything.

/// Where a package comes from. The installer records the publisher and source from this, never from the package.
public enum ExtensionSource: Sendable {
    case folder(URL)
    case zip(URL)
    /// `~/.claude/plugins/cache/<marketplace>/<plugin>/<newest version>/`: owner CLI or app only.
    case claudeCodeInstalled(marketplace: String, plugin: String)
    /// A folder holding a SKILL.md (plus reference files): wrapped in a generated 4-key manifest.
    case bareSkill(URL)
    /// A snapshot of an agent's lab at a commit (Task 10b).
    case lab(agentId: String, path: String, commit: String)
}

/// What the installer records about the fetch path.
public struct ExtensionSourceFacts: Codable, Equatable, Sendable {
    public var publisher: String
    public var sourceType: String
    public var sourceUrl: String?
    public var sourceSha: String?

    public init(publisher: String, sourceType: String, sourceUrl: String?, sourceSha: String?) {
        self.publisher = publisher; self.sourceType = sourceType; self.sourceUrl = sourceUrl; self.sourceSha = sourceSha
    }
}

/// A staged, decomposed package: the staging dir, the id, the import notices and the source facts.
public struct StagedExtension: Sendable {
    public var dir: URL
    public var id: String
    public var notices: [String]
    public var source: ExtensionSourceFacts
}

/// The archive limits (S10): what a zip may declare before anything is extracted.
public enum ZipLimits {
    /// Declared uncompressed bytes over compressed bytes; above this the archive is a bomb.
    public static let maxRatio = 100
}

public enum ExtensionImporter {
    /// What the extraction script prints when the archive's real bytes pass the quota.
    static let quotaMarker = "brahma-zip-quota-exceeded"
    /// What it prints when `zipinfo -1` disagrees with the inventory.
    static let listingMarker = "brahma-zip-listing-differs"

    static func mcpNotice(_ name: String) -> String { "This plugin's MCP server \(name) was not imported; connectors arrive in a later Brahma release." }
    static func hookNotice(_ event: String) -> String { "This plugin's \(event) hook will not run in Brahma." }

    /// Top-level names the decompose step turns into notices; they are copied so it can read them.
    static let noticedTopLevel: Set<String> = ["hooks", "hooks.json", ".mcp.json", ".lsp.json", "settings.json", "monitors", "output-styles",
                                               "themes", "workflows", "CLAUDE.md", "SKILL.md"]

    /// Stages `source` under the limits and decomposes it. `userHome` is the owner's home for the plugin-cache import (the
    /// account's home by default); `environment` is the process environment (an agent turn, `BRAHMA_AGENT_ID`, may never
    /// import from the owner's Claude Code); `sandbox` runs `unzip` for a zip source.
    public static func stage(source: ExtensionSource, paths: BrahmaPaths, userHome: URL? = nil,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             sandbox: any SandboxedRunner,
                             labArchive: ((_ agentId: String, _ path: String, _ commit: String, _ into: URL) throws -> Void)? = nil) async throws -> StagedExtension {
        let staging = paths.extensionsDir.staging
        try BrahmaPaths.ensurePrivateDirectory(paths.extensionsDir.root)
        try BrahmaPaths.ensurePrivateDirectory(staging)
        let dir = staging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            return try await stage(source: source, into: dir, paths: paths, userHome: userHome, environment: environment, sandbox: sandbox, labArchive: labArchive)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private static func stage(source: ExtensionSource, into dir: URL, paths: BrahmaPaths, userHome: URL?, environment: [String: String],
                              sandbox: any SandboxedRunner, labArchive: ((String, String, String, URL) throws -> Void)?) async throws -> StagedExtension {
        var notices: [String] = []
        let facts: ExtensionSourceFacts
        var bare = false
        func noticeSkipped(_ skipped: [String]) {
            for name in skipped { notices.append("\(Store.flat(name, max: 80)) was not imported (not a plugin part).") }
        }
        switch source {
        case .folder(let url):
            noticeSkipped(try copyTree(from: url, to: dir, topLevelFilter: isCopiedTopLevel))
            facts = ExtensionSourceFacts(publisher: ExtensionPublisher.local, sourceType: "folder", sourceUrl: url.path, sourceSha: nil)
        case .bareSkill(let url):
            guard FileManager.default.fileExists(atPath: url.appending(path: "SKILL.md").path) else {
                throw ExtensionError.message("\(url.path) holds no SKILL.md")
            }
            bare = true
            _ = try copyTree(from: url, to: dir.appending(path: ".skill"))
            facts = ExtensionSourceFacts(publisher: ExtensionPublisher.local, sourceType: "bareSkill", sourceUrl: url.path, sourceSha: nil)
        case .zip(let url):
            let unzipped = try await extractZip(url, under: dir, sandbox: sandbox)
            // One top-level folder (the package) or the package files themselves.
            let entries = try FileManager.default.contentsOfDirectory(atPath: unzipped.path).filter { $0 != "__MACOSX" }
            let root = entries.count == 1 && SandboxPath.kind(unzipped.appending(path: entries[0]).path) == .directory
                ? unzipped.appending(path: entries[0]) : unzipped
            noticeSkipped(try copyTree(from: root, to: dir, topLevelFilter: isCopiedTopLevel))
            try FileManager.default.removeItem(at: unzipped)
            facts = ExtensionSourceFacts(publisher: ExtensionPublisher.local, sourceType: "zip", sourceUrl: url.path,
                                         sourceSha: FileManager.default.contents(atPath: url.path).map(SHA256.hex))
        case .claudeCodeInstalled(let marketplace, let plugin):
            guard environment["BRAHMA_AGENT_ID"] == nil else {
                throw ExtensionError.message("importing from your Claude Code is an owner action; it never runs inside an agent turn")
            }
            for part in [marketplace, plugin] where !ExtensionLimits.isSafeName(part) || part.hasPrefix(".") {
                throw ExtensionError.message("'\(Store.flat(part, max: 60))' is not a marketplace or plugin name")
            }
            let home = userHome ?? ownerHome()
            let cache = home.appending(path: ".claude/plugins/cache/\(marketplace)/\(plugin)", directoryHint: .isDirectory)
            guard let version = newestVersion(in: cache) else {
                throw ExtensionError.message("no installed plugin \(marketplace)/\(plugin) in \(home.path)/.claude/plugins/cache")
            }
            noticeSkipped(try copyTree(from: cache.appending(path: version), to: dir, topLevelFilter: isCopiedTopLevel))
            facts = ExtensionSourceFacts(publisher: ExtensionPublisher.claudeCode(marketplace: marketplace), sourceType: "claudeCode",
                                         sourceUrl: "\(marketplace)/\(plugin)@\(version)", sourceSha: nil)
        case .lab(let agentId, let path, let commit):
            guard let labArchive else { throw ExtensionError.message("a lab is staged by propose_extension (stageLab), not here") }
            let archived = dir.appending(path: ".archive", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: false)
            try labArchive(agentId, path, commit, archived)
            noticeSkipped(try copyTree(from: archived, to: dir, topLevelFilter: isCopiedTopLevel))
            try FileManager.default.removeItem(at: archived)
            facts = ExtensionSourceFacts(publisher: "lab:\(agentId)", sourceType: "lab", sourceUrl: path, sourceSha: commit)
        }
        let id = try decompose(dir, bare: bare, notices: &notices)
        return StagedExtension(dir: dir, id: id, notices: notices, source: facts)
    }

    /// Stages a snapshot of an agent's lab (Task 10b, synchronous: `propose_extension`): `archive` writes the committed folder
    /// into the directory it is given (`GitWorkspace.labArchive`), which is copied under the limits as it is (every top-level
    /// entry, so the validator sees what `ext lint` sees in the lab). With `requireClean` any lint issue refuses before the
    /// decompose step could drop or fill anything. `facts` are the installer's (publisher `company:<slug>`, never the lab's).
    static func stageLab(paths: BrahmaPaths, facts: ExtensionSourceFacts, requireClean: Bool,
                                options: ValidationOptions = ValidationOptions(),
                                archive: (_ tar: URL, _ into: EngineFiles.OpenDirectory) throws -> Void) throws -> StagedExtension {
        let staging = paths.extensionsDir.staging
        try BrahmaPaths.ensurePrivateDirectory(paths.extensionsDir.root)
        try BrahmaPaths.ensurePrivateDirectory(staging)
        let dir = staging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let archived = dir.appending(path: ".archive", directoryHint: .isDirectory)
            let place = try EngineFiles.openWalked(workspace: dir, ".archive")
            do { try archive(dir.appending(path: ".archive.tar"), place) } catch let e as UnexportableTree {
                throw ExtensionError.message("the folder could not be unpacked: \(e.reason)")
            }
            try? FileManager.default.removeItem(at: dir.appending(path: ".archive.tar"))
            let package = dir.appending(path: "package", directoryHint: .isDirectory)
            try copyTree(from: archived, to: package)
            try FileManager.default.removeItem(at: archived)
            if requireClean {
                let lint = ExtensionValidator.validate(staged: package, options: options)
                guard lint.issues.isEmpty else { throw ExtensionError(issues: lint.issues) }
            }
            // The staged tree is the package itself (what was linted), moved into the staging dir's place.
            for name in try FileManager.default.contentsOfDirectory(atPath: package.path) {
                try FileManager.default.moveItem(at: package.appending(path: name), to: dir.appending(path: name))
            }
            try FileManager.default.removeItem(at: package)
            var notices: [String] = []
            let id = try decompose(dir, bare: false, notices: &notices)
            return StagedExtension(dir: dir, id: id, notices: notices, source: facts)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Which top-level entries of a plugin source are copied: the allowlisted ones and those decompose notices; `node_modules`
    /// refuses the import; everything else is skipped with a notice (I6).
    static func isCopiedTopLevel(_ name: String) throws -> Bool {
        if name == "node_modules" { throw ExtensionError.message("a top-level node_modules/ is refused; nothing is installed at runtime") }
        if noticedTopLevel.contains(name) { return true }
        switch ExtensionValidator.classify(topLevel: name) {
        case .refused: return false
        default: return true
        }
    }

    // MARK: Copy under the limits

    /// Copies `source` into `dest` (created): regular files and directories only, modes normalized (0755 under `bin/`, else
    /// 0644), every name checked, the limits enforced. A link, device or odd name refuses the import, except at the top level
    /// when `topLevelFilter` says the entry is not copied anyway (it is skipped and returned). Returns the skipped names.
    @discardableResult
    public static func copyTree(from source: URL, to dest: URL, topLevelFilter: ((String) throws -> Bool)? = nil) throws -> [String] {
        let fm = FileManager.default
        guard SandboxPath.kind(source.path) == .directory else { throw ExtensionError.message("\(source.path) is not a directory") }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var count = 0
        var total: Int64 = 0
        var skipped: [String] = []
        for f in try PackageWalk.files(root: source, includeDirectories: true) {
            let name = f.url.lastPathComponent
            let top = String(f.relative.split(separator: "/").first ?? "")
            if skipped.contains(top) { continue }
            if let topLevelFilter, !f.relative.contains("/") {
                if name == ".DS_Store" { continue }
                let wanted = try topLevelFilter(name)
                let isPart = wanted && !noticedTopLevel.contains(name)
                // A link or odd file at a plugin-part name refuses the import; at any other name it is skipped with a notice.
                if !wanted || ((f.kind == .link || f.kind == .other) && !isPart) { skipped.append(name); continue }
            }
            guard ExtensionLimits.isSafeName(name) else {
                throw ExtensionError.message("'\(Store.flat(f.relative, max: 80))' holds a control, hidden or bidi character")
            }
            if name == ".DS_Store" { continue }
            let target = dest.appending(path: f.relative)
            switch f.kind {
            case .directory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .link:
                throw ExtensionError.message("\(f.relative) is a symbolic link; links are refused")
            case .other:
                throw ExtensionError.message("\(f.relative) is not a regular file; devices and pipes are refused")
            case .regular:
                count += 1; total += f.size
                guard count <= ExtensionLimits.maxFiles else { throw ExtensionError.message("more than \(ExtensionLimits.maxFiles) files") }
                guard total <= Int64(ExtensionLimits.maxBytes) else { throw ExtensionError.message("larger than \(ExtensionLimits.maxBytes) bytes") }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Opened without following a link (the walk saw a regular file; a swap meanwhile is caught here).
                let fd = open(f.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw ExtensionError.message("cannot read \(f.relative)") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var st = stat()
                guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else {
                    throw ExtensionError.message("\(f.relative) is not a plain file (a hard link or a swap); refused")
                }
                let data = try handle.readToEnd() ?? Data()
                guard data.count <= ExtensionLimits.maxBytes else { throw ExtensionError.message("cannot read \(f.relative)") }
                let executable = f.relative.hasPrefix("bin/") || (f.mode & 0o111) != 0
                try data.write(to: target)
                try fm.setAttributes([.posixPermissions: f.relative.hasPrefix("bin/") && executable ? 0o755 : 0o644], ofItemAtPath: target.path)
            }
        }
        return skipped.sorted()
    }

    // MARK: Zip

    /// Inventories the archive (its central directory, never the entry data) and refuses more than `maxFiles` entries, more than
    /// `maxBytes` declared uncompressed, a compression ratio over `ZipLimits.maxRatio`, a symlink entry, an absolute name, a `..`
    /// component, an unsafe name or zip64. Then `/usr/bin/unzip -q -n` runs under the sandboxed runner (writable: the unzip
    /// directory only; network none; `ulimit -f` as the byte quota), and what came out is checked against the limits again.
    static func extractZip(_ zip: URL, under dir: URL, sandbox: any SandboxedRunner) async throws -> URL {
        var st = stat()
        guard stat(zip.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw ExtensionError.message("\(zip.path) is not a file") }
        guard st.st_size <= ExtensionLimits.maxBytes else { throw ExtensionError.message("the zip is larger than \(ExtensionLimits.maxBytes) bytes") }
        guard let data = FileManager.default.contents(atPath: zip.path) else { throw ExtensionError.message("cannot read \(zip.path)") }
        let entries = try ZipInventory.entries(of: data)
        var files = 0, uncompressed = 0, compressed = 0
        for e in entries {
            if e.isSymlink { throw ExtensionError.message("the zip holds a symbolic link entry (\(Store.flat(e.name, max: 80))); links are refused") }
            if e.name.hasPrefix("/") || e.name.hasPrefix("\\") || e.name.range(of: "^[A-Za-z]:", options: .regularExpression) != nil {
                throw ExtensionError.message("the zip holds an absolute entry name (\(Store.flat(e.name, max: 80)))")
            }
            // m-5: Info-ZIP turns `\` into `/` for entries made on FAT, so both separate components.
            let parts = e.name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
            if parts.contains("..") { throw ExtensionError.message("the zip holds a '..' component (\(Store.flat(e.name, max: 80)))") }
            for part in parts where !ExtensionLimits.isSafeName(part) {
                throw ExtensionError.message("'\(Store.flat(e.name, max: 80))' holds a control, hidden or bidi character")
            }
            if e.isDirectory { continue }
            files += 1
            uncompressed += e.uncompressedSize; compressed += e.compressedSize
        }
        guard files <= ExtensionLimits.maxFiles else { throw ExtensionError.message("the zip declares \(files) entries; at most \(ExtensionLimits.maxFiles)") }
        guard uncompressed <= ExtensionLimits.maxBytes else {
            throw ExtensionError.message("the zip declares \(uncompressed) uncompressed bytes; at most \(ExtensionLimits.maxBytes)")
        }
        guard uncompressed <= ZipLimits.maxRatio * max(compressed, 1) else {
            throw ExtensionError.message("the zip's compression ratio (\(uncompressed) in \(compressed) bytes) is over \(ZipLimits.maxRatio):1")
        }
        // The bytes inventoried are the bytes extracted: a private copy of the archive (the source may change under us).
        let held = dir.appending(path: ".zip", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: held, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let archive = held.appending(path: "archive.zip")
        guard FileManager.default.createFile(atPath: archive.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw ExtensionError.message("cannot hold a copy of the zip")
        }
        defer { try? FileManager.default.removeItem(at: held) }
        let unzipped = dir.appending(path: ".unzip", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: unzipped, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // The running byte quota over the whole archive: every entry's real (inflated) bytes are streamed through `head`, which
        // stops after one byte over `maxBytes`; a central directory that under-declares its sizes is caught here, before
        // anything is written. Then the extraction, with `ulimit -f` capping any one file at `maxBytes`.
        let q = ExtensionValidator.shellQuote
        let limit = ExtensionLimits.maxBytes
        let blocks = (limit + 511) / 512   // `ulimit -f` counts 512-byte blocks
        // I-2 (b): the extractor's own listing (`zipinfo -1`, Info-ZIP's reader) must equal the inventory exactly, names and
        // order, before anything is extracted.
        let expected = held.appending(path: "expected.txt")
        guard FileManager.default.createFile(atPath: expected.path, contents: Data(entries.map { $0.name + "\n" }.joined().utf8),
                                             attributes: [.posixPermissions: 0o600]) else { throw ExtensionError.message("cannot write the zip listing") }
        let command = "\(q("/usr/bin/zipinfo")) -1 \(q(archive.path)) 2>/dev/null | /usr/bin/cmp -s - \(q(expected.path)) "
            + "|| { echo \"\(listingMarker)\"; exit 4; }; "
            + "total=$(\(q("/usr/bin/unzip")) -p \(q(archive.path)) 2>/dev/null | /usr/bin/head -c \(limit + 1) | /usr/bin/wc -c | /usr/bin/tr -d ' '); "
            + "if [ \"$total\" -gt \(limit) ]; then echo \"\(quotaMarker)\"; exit 3; fi; "
            + "ulimit -f \(blocks) && " + [q("/usr/bin/unzip"), "-q", "-n", q(archive.path), "-d", q(unzipped.path)].joined(separator: " ")
        let env = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        let policy = SandboxPolicy(writable: [unzipped], readable: [held], network: .none, toolchain: false)
        let out = await sandbox.run(command: command, cwd: unzipped, environment: env, timeout: .seconds(120),
                                    outputURL: dir.appending(path: ".unzip.log"), policy: policy)
        try? FileManager.default.removeItem(at: dir.appending(path: ".unzip.log"))
        guard out.exitCode == 0 else {
            try? FileManager.default.removeItem(at: unzipped)
            if out.tail.contains(listingMarker) {
                throw ExtensionError.message("the zip's entries as unzip lists them differ from its directory; refused")
            }
            if out.tail.contains(quotaMarker) {
                throw ExtensionError.message("the zip inflates to more than \(limit) bytes (its central directory under-declares the sizes); refused")
            }
            throw ExtensionError.message("unzip failed: \(Store.flat(out.tail, max: 200))")
        }
        return unzipped
    }

    static func ownerHome() -> URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The newest version folder of a plugin cache entry: semantic versions first (highest wins), else the newest by
    /// modification time; folders marked `.orphaned_at` are skipped.
    static func newestVersion(in cache: URL) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cache.path) else { return nil }
        let candidates = names.filter { name in
            SandboxPath.kind(cache.appending(path: name).path) == .directory && !name.hasPrefix(".")
                && !fm.fileExists(atPath: cache.appending(path: "\(name)/.orphaned_at").path)
                && fm.fileExists(atPath: cache.appending(path: "\(name)/\(ExtensionManifest.path)").path)
        }
        func semver(_ s: String) -> [Int]? {
            let parts = s.split(separator: ".").map { Int($0) }
            return parts.count >= 2 && parts.allSatisfy { $0 != nil } ? parts.map { $0! } : nil
        }
        let versioned = candidates.compactMap { n in semver(n).map { (n, $0) } }
        if let best = versioned.max(by: { $0.1.lexicographicallyPrecedes($1.1) }) { return best.0 }
        return candidates.max { a, b in
            let ma = (try? fm.attributesOfItem(atPath: cache.appending(path: a).path)[.modificationDate] as? Date) ?? .distantPast
            let mb = (try? fm.attributesOfItem(atPath: cache.appending(path: b).path)[.modificationDate] as? Date) ?? .distantPast
            return ma < mb
        }
    }

    // MARK: Decompose

    /// Turns the staged copy into a skill-only package (notices for everything dropped) and returns its id.
    static func decompose(_ dir: URL, bare: Bool, notices: inout [String]) throws -> String {
        let fm = FileManager.default
        if bare {
            // `<dir>/.skill/SKILL.md` → `<dir>/skills/<id>/…`, with a generated manifest.
            let skillDir = dir.appending(path: ".skill")
            let text = try String(contentsOf: skillDir.appending(path: "SKILL.md"), encoding: .utf8)
            guard let fm_ = Frontmatter.parse(text), let name = fm_.value("name"), !name.isEmpty else {
                throw ExtensionError.message("SKILL.md has no frontmatter name to use as the id (or its frontmatter is not the strict subset)")
            }
            if let problem = ExtensionId.problem(name) { throw ExtensionError.message(problem) }
            let description = fm_.value("description") ?? "Skill \(name)."
            try fm.createDirectory(at: dir.appending(path: "skills"), withIntermediateDirectories: true)
            try fm.moveItem(at: skillDir, to: dir.appending(path: "skills/\(name)"))
            try fm.createDirectory(at: dir.appending(path: ".claude-plugin"), withIntermediateDirectories: true)
            let manifest = ExtensionManifest(name: name, version: "0.1.0", description: String(description.unicodeScalars.prefix(ExtensionLimits.maxDescription)),
                                             author: .object(["name": .string("imported")]))
            try manifest.json().write(to: dir.appending(path: ExtensionManifest.path))
            notices.append("A plugin.json was generated for the bare skill '\(name)'.")
        }
        guard fm.fileExists(atPath: dir.appending(path: "node_modules").path) == false else {
            throw ExtensionError.message("a top-level node_modules/ is refused; nothing is installed at runtime")
        }
        // A folder holding a SKILL.md at its root (no manifest) is a bare skill too.
        if !fm.fileExists(atPath: dir.appending(path: ExtensionManifest.path).path), fm.fileExists(atPath: dir.appending(path: "SKILL.md").path) {
            let hidden = dir.appending(path: ".skill")
            try fm.createDirectory(at: hidden, withIntermediateDirectories: false)
            for name in try fm.contentsOfDirectory(atPath: dir.path) where name != ".skill" {
                try fm.moveItem(at: dir.appending(path: name), to: hidden.appending(path: name))
            }
            return try decompose(dir, bare: true, notices: &notices)
        }
        guard let data = fm.contents(atPath: dir.appending(path: ExtensionManifest.path).path) else {
            throw ExtensionError.message("not a plugin: no \(ExtensionManifest.path) and no SKILL.md")
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), var object = value.objectValue else {
            throw ExtensionError.message("plugin.json is not a JSON object")
        }
        guard let id = object["name"]?.stringValue else { throw ExtensionError.message("plugin.json has no name") }

        // The manifest: the parts Brahma does not run are dropped with their notices; benign metadata is dropped quietly.
        if let hooks = object.removeValue(forKey: "hooks") { notices += hookNotices(hooks, root: dir) }
        if let servers = object.removeValue(forKey: "mcpServers") { notices += mcpNotices(servers, root: dir) }
        if object.removeValue(forKey: "lspServers") != nil { notices.append("This plugin's LSP server was not imported; LSP servers never run in Brahma.") }
        if object.removeValue(forKey: "channels") != nil { notices.append("This plugin's channels were not imported.") }
        if let config = object.removeValue(forKey: "userConfig")?.objectValue {
            for (key, spec) in config.sorted(by: { $0.key < $1.key }) {
                let shown = Store.flat(key, max: 60)
                if looksSecret(key: key, spec: spec) {
                    notices.append("This plugin's userConfig \(shown) was not imported; it looks like a credential: add it as a secret.")
                } else {
                    notices.append("This plugin's userConfig \(shown) was not imported.")
                }
            }
        }
        if let deps = object.removeValue(forKey: "dependencies") {
            let names = (deps.arrayValue ?? []).compactMap { $0.stringValue ?? $0.objectValue?["name"]?.stringValue }
                + (deps.objectValue?.keys.sorted() ?? [])
            for d in names { notices.append("This plugin depends on \(Store.flat(d, max: 60)); it was not installed (install it separately if you need it).") }
        }
        // Component paths (custom locations) and other metadata are dropped with a notice; the referenced folders fall to the
        // top-level filter, so only the standard locations are used.
        for key in ["commands", "agents", "skills", "outputStyles", "hooksPath"] where object[key] != nil {
            object.removeValue(forKey: key)
            notices.append("The manifest key \(key) (a component path) was dropped; only the standard folders are used.")
        }
        for key in ["homepage", "repository", "license", "keywords", "icon"] where object[key] != nil {
            object.removeValue(forKey: key)
            notices.append("The manifest key \(key) was dropped (not part of the 4-key manifest).")
        }
        // The four keys are filled in when missing, with a notice.
        if object["version"]?.stringValue == nil { object["version"] = .string("0.0.0"); notices.append("The manifest had no version; 0.0.0 was set.") }
        if object["description"]?.stringValue == nil { object["description"] = .string("Imported plugin \(id)."); notices.append("The manifest had no description; one was set.") }
        if object["author"] == nil { object["author"] = .object(["name": .string("unknown")]); notices.append("The manifest had no author; 'unknown' was set.") }
        try ExtensionJSON.encode(JSONValue.object(object)).write(to: dir.appending(path: ExtensionManifest.path))

        // Files and directories Brahma does not run (compared lowercased).
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appending(path: name)
            switch name.lowercased() {
            case "hooks", "hooks.json":
                let json = SandboxPath.kind(url.path) == .directory ? url.appending(path: "hooks.json") : url
                if let d = fm.contents(atPath: json.path), let v = try? JSONDecoder().decode(JSONValue.self, from: d) { notices += hookNotices(v, root: dir) }
                else { notices.append(hookNotice("every")) }
                try fm.removeItem(at: url)
            case ".mcp.json":
                if let d = fm.contents(atPath: url.path), let v = try? JSONDecoder().decode(JSONValue.self, from: d),
                   let servers = v.objectValue?["mcpServers"]?.objectValue ?? v.objectValue {
                    for s in servers.keys.sorted() { notices.append(mcpNotice(Store.flat(s, max: 60))) }
                } else { notices.append(mcpNotice("(unnamed)")) }
                try fm.removeItem(at: url)
            case ".lsp.json":
                notices.append("This plugin's LSP server (.lsp.json) was not imported; LSP servers never run in Brahma."); try fm.removeItem(at: url)
            case "settings.json", "monitors", "output-styles", "themes", "workflows", "claude.md":
                notices.append("This plugin's \(name) was not imported; it reconfigures the harness and is not a plugin part."); try fm.removeItem(at: url)
            case ".ds_store", ".git", ".orphaned_at":
                try fm.removeItem(at: url)
            default: break
            }
        }
        // `bin/` helpers are renamed `<id>-*`.
        let bin = dir.appending(path: "bin")
        if SandboxPath.kind(bin.path) == .directory, ExtensionId.isValid(id) {
            for name in try fm.contentsOfDirectory(atPath: bin.path).sorted() where !name.hasPrefix(id + "-") {
                let renamed = "\(id)-\(name)"
                guard !fm.fileExists(atPath: bin.appending(path: renamed).path) else { continue }
                try fm.moveItem(at: bin.appending(path: name), to: bin.appending(path: renamed))
                notices.append("bin/\(name) was renamed to bin/\(renamed).")
            }
        }
        return id
    }

    /// The hook events a manifest `hooks` value declares (inline, or a path to a hooks file inside the package).
    static func hookNotices(_ value: JSONValue, root: URL) -> [String] {
        var events: [String] = []
        if let o = value.objectValue {
            let map = o["hooks"]?.objectValue ?? o
            events = map.keys.sorted()
        } else if let path = value.stringValue, let file = insidePackage(path, root: root),
                  let d = FileManager.default.contents(atPath: file.path), let v = try? JSONDecoder().decode(JSONValue.self, from: d) {
            events = (v.objectValue?["hooks"]?.objectValue ?? v.objectValue ?? [:]).keys.sorted()
            try? FileManager.default.removeItem(at: file)
        }
        if events.isEmpty { return [hookNotice("every")] }
        return events.map { hookNotice(Store.flat($0, max: 40)) }
    }

    /// Notices for a manifest `mcpServers` value in every form: an inline map (one per server), a path or a list of paths (the
    /// servers of each referenced file, which is then dropped; a missing file is noticed by its path).
    static func mcpNotices(_ value: JSONValue, root: URL) -> [String] {
        if let servers = value.objectValue {
            return servers.keys.sorted().map { mcpNotice(Store.flat($0, max: 60)) }
        }
        let paths = value.stringValue.map { [$0] } ?? (value.arrayValue ?? []).compactMap(\.stringValue)
        var out: [String] = []
        for path in paths {
            if let file = insidePackage(path, root: root), let d = FileManager.default.contents(atPath: file.path),
               let v = try? JSONDecoder().decode(JSONValue.self, from: d), let servers = v.objectValue?["mcpServers"]?.objectValue ?? v.objectValue, !servers.isEmpty {
                out += servers.keys.sorted().map { mcpNotice(Store.flat($0, max: 60)) }
                try? FileManager.default.removeItem(at: file)
                let parent = file.deletingLastPathComponent()
                if parent.path != root.path, (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                    try? FileManager.default.removeItem(at: parent)
                }
            } else {
                out.append(mcpNotice("(\(Store.flat(path, max: 60)))"))
            }
        }
        return out.isEmpty ? [mcpNotice("(unnamed)")] : out
    }

    /// A manifest-relative path (`./x/y.json`) as a URL inside the package, or nil when it escapes or is unsafe.
    static func insidePackage(_ path: String, root: URL) -> URL? {
        var p = path
        if p.hasPrefix("./") { p.removeFirst(2) }
        let parts = p.split(separator: "/").map(String.init)
        guard !p.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ $0 != ".." && ExtensionLimits.isSafeName($0) }) else { return nil }
        return root.appending(path: parts.joined(separator: "/"))
    }

    static func looksSecret(key: String, spec: JSONValue) -> Bool {
        let lower = key.lowercased()
        if ["token", "secret", "password", "passwd", "apikey", "api_key", "credential", "auth"].contains(where: { lower.contains($0) }) { return true }
        if lower.hasSuffix("key") { return true }
        if spec.objectValue?["sensitive"]?.boolValue == true { return true }
        return false
    }
}

/// A reader of a zip's central directory: the entries' names, sizes and kinds, never their data.
enum ZipInventory {
    struct Entry: Equatable, Sendable {
        var name: String
        var compressedSize: Int
        var uncompressedSize: Int
        var isSymlink: Bool
        var isDirectory: Bool
        /// The central directory's compression method and general-purpose flags (bit 0: encrypted). Read by Plan C's
        /// `ArchiveMemberScan`; no other caller uses them.
        var method: Int = 0
        var flags: Int = 0
    }

    static func entries(of data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        // The end-of-central-directory record: signature 0x06054b50 within the last 64 KB + 22 bytes.
        guard bytes.count >= 22 else { throw ExtensionError.message("not a zip archive") }
        var eocd = -1
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 22 - 65535)
        while i >= floor {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ExtensionError.message("not a zip archive (no central directory)") }
        if eocd >= 20, bytes[eocd - 20] == 0x50, bytes[eocd - 19] == 0x4b, bytes[eocd - 18] == 0x06, bytes[eocd - 17] == 0x07 {
            throw ExtensionError.message("zip64 archives are refused")
        }
        // I-2: the inventory must be self-consistent, exactly as a standard archive is laid out, so no reader can see an entry
        // it does not: one disk; entries on this disk == total; no data after the EOCD but its comment; the central directory
        // ends exactly at the EOCD; the walk of exactly `count` headers consumes exactly `cdSize` bytes; every local header
        // matches its central entry; the local entries tile the archive from byte 0 up to the central directory.
        func refuse(_ why: String) -> ExtensionError { ExtensionError.message("the zip's directory is not self-consistent (\(why)); refused") }
        let disk = u16(eocd + 4), cdDisk = u16(eocd + 6), onDisk = u16(eocd + 8)
        let count = u16(eocd + 10), cdSize = u32(eocd + 12), cdOffset = u32(eocd + 16), commentLength = u16(eocd + 20)
        guard count != 0xFFFF, cdSize != 0xFFFFFFFF, cdOffset != 0xFFFFFFFF else { throw ExtensionError.message("zip64 archives are refused") }
        guard disk == 0, cdDisk == 0, onDisk == count else { throw refuse("multi-disk fields") }
        guard eocd + 22 + commentLength == bytes.count else { throw refuse("data after the end record") }
        guard cdOffset + cdSize == eocd else { throw refuse("the central directory does not end at the end record") }
        struct Local { var offset: Int; var end: Int }
        var locals: [Local] = []
        var out: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= eocd, bytes[p] == 0x50, bytes[p + 1] == 0x4b, bytes[p + 2] == 0x01, bytes[p + 3] == 0x02 else {
                throw refuse("a central header is missing")
            }
            let flags = u16(p + 8), method = u16(p + 10), crc = u32(p + 16)
            let compressed = u32(p + 20), uncompressed = u32(p + 24)
            let nameLength = u16(p + 28), extraLength = u16(p + 30), entryComment = u16(p + 32)
            let entryDisk = u16(p + 34), external = u32(p + 38), localOffset = u32(p + 42)
            guard compressed != 0xFFFFFFFF, uncompressed != 0xFFFFFFFF, localOffset != 0xFFFFFFFF else { throw ExtensionError.message("zip64 archives are refused") }
            guard entryDisk == 0 else { throw refuse("an entry on another disk") }
            let nameStart = p + 46
            guard nameStart + nameLength + extraLength + entryComment <= eocd else { throw refuse("a central header runs past the directory") }
            let nameBytes = Array(bytes[nameStart..<nameStart + nameLength])
            // The local header: same name, method, sizes and CRC (sizes and CRC may be deferred to a data descriptor, bit 3).
            let l = localOffset
            guard l + 30 <= cdOffset, bytes[l] == 0x50, bytes[l + 1] == 0x4b, bytes[l + 2] == 0x03, bytes[l + 3] == 0x04 else {
                throw refuse("an entry's local header is missing")
            }
            let localFlags = u16(l + 6), localNameLength = u16(l + 26), localExtra = u16(l + 28)
            guard l + 30 + localNameLength + localExtra <= cdOffset, Array(bytes[(l + 30)..<(l + 30 + localNameLength)]) == nameBytes,
                  u16(l + 8) == method, (localFlags & 0x08) == (flags & 0x08) else { throw refuse("a local header differs from its central entry") }
            if flags & 0x08 == 0 {
                guard u32(l + 14) == crc, u32(l + 18) == compressed, u32(l + 22) == uncompressed else { throw refuse("a local header's sizes differ") }
            }
            var dataEnd = l + 30 + localNameLength + localExtra + compressed
            if flags & 0x08 != 0 {
                let signed = dataEnd + 4 <= cdOffset && bytes[dataEnd] == 0x50 && bytes[dataEnd + 1] == 0x4b && bytes[dataEnd + 2] == 0x07 && bytes[dataEnd + 3] == 0x08
                dataEnd += signed ? 16 : 12
            }
            guard dataEnd <= cdOffset else { throw refuse("an entry's data runs into the central directory") }
            locals.append(Local(offset: l, end: dataEnd))
            let name = String(decoding: nameBytes, as: UTF8.self)
            // N-2: Info-ZIP honours Unix mode bits in the high 16 bits for several made-by hosts (Unix, VMS, Atari, BeOS,
            // AtheOS, …), so they are read whatever the host: a symlink is flagged, and any type that is neither a regular file
            // nor a directory refuses the archive.
            let unixMode = (external >> 16) & 0xFFFF
            let type = unixMode & 0o170000
            let isSymlink = type == 0o120000
            guard type == 0 || type == 0o100000 || type == 0o040000 || isSymlink else {
                throw ExtensionError.message("the zip holds an entry of an unsupported file type (\(Store.flat(name, max: 80)))")
            }
            let isDirectory = name.hasSuffix("/") || type == 0o040000 || (external & 0x10) != 0
            out.append(Entry(name: name, compressedSize: compressed, uncompressedSize: uncompressed, isSymlink: isSymlink, isDirectory: isDirectory,
                             method: method, flags: flags))
            p = nameStart + nameLength + extraLength + entryComment
        }
        guard p == cdOffset + cdSize else { throw refuse("the central directory holds more or fewer headers than the end record counts") }
        var at = 0
        for local in locals.sorted(by: { $0.offset < $1.offset }) {
            guard local.offset == at else { throw refuse(local.offset < at ? "entries overlap" : "bytes between entries") }
            at = local.end
        }
        guard at == cdOffset else { throw refuse("bytes between the last entry and the central directory") }
        return out
    }
}

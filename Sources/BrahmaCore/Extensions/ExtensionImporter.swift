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
// notice. Brahma copies plugin folders itself; it never asks the Claude CLI to install anything.

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
}

/// A staged, decomposed package: the staging dir, the id, the import notices and the source facts.
public struct StagedExtension: Sendable {
    public var dir: URL
    public var id: String
    public var notices: [String]
    public var source: ExtensionSourceFacts
}

public enum ExtensionImporter {
    static func mcpNotice(_ name: String) -> String { "This plugin's MCP server \(name) was not imported; connectors arrive in a later Brahma release." }
    static func hookNotice(_ event: String) -> String { "This plugin's \(event) hook will not run in Brahma." }

    /// Stages `source` under the limits and decomposes it. `userHome` is the owner's home for the plugin-cache import (the
    /// account's home by default); `environment` is the process environment (an agent turn, `BRAHMA_AGENT_ID`, may never
    /// import from the owner's Claude Code).
    public static func stage(source: ExtensionSource, paths: BrahmaPaths, userHome: URL? = nil,
                             environment: [String: String] = ProcessInfo.processInfo.environment,
                             labArchive: ((_ agentId: String, _ path: String, _ commit: String, _ into: URL) throws -> Void)? = nil) throws -> StagedExtension {
        let staging = paths.extensionsDir.staging
        try BrahmaPaths.ensurePrivateDirectory(paths.extensionsDir.root)
        try BrahmaPaths.ensurePrivateDirectory(staging)
        let dir = staging.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            return try stage(source: source, into: dir, paths: paths, userHome: userHome, environment: environment, labArchive: labArchive)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private static func stage(source: ExtensionSource, into dir: URL, paths: BrahmaPaths, userHome: URL?, environment: [String: String],
                              labArchive: ((String, String, String, URL) throws -> Void)?) throws -> StagedExtension {
        var notices: [String] = []
        let facts: ExtensionSourceFacts
        var bare = false
        switch source {
        case .folder(let url):
            try copyTree(from: url, to: dir)
            facts = ExtensionSourceFacts(publisher: ExtensionPublisher.local, sourceType: "folder", sourceUrl: url.path, sourceSha: nil)
        case .bareSkill(let url):
            guard FileManager.default.fileExists(atPath: url.appending(path: "SKILL.md").path) else {
                throw ExtensionError.message("\(url.path) holds no SKILL.md")
            }
            bare = true
            try copyTree(from: url, to: dir.appending(path: ".skill"))
            facts = ExtensionSourceFacts(publisher: ExtensionPublisher.local, sourceType: "bareSkill", sourceUrl: url.path, sourceSha: nil)
        case .zip(let url):
            var st = stat()
            guard stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw ExtensionError.message("\(url.path) is not a file") }
            guard st.st_size <= ExtensionLimits.maxBytes else { throw ExtensionError.message("the zip is larger than \(ExtensionLimits.maxBytes) bytes") }
            let unzipped = dir.appending(path: ".unzip", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: unzipped, withIntermediateDirectories: false)
            try unzip(url, into: unzipped)
            // One top-level folder (the package) or the package files themselves.
            let entries = try FileManager.default.contentsOfDirectory(atPath: unzipped.path).filter { $0 != "__MACOSX" }
            let root = entries.count == 1 && SandboxPath.kind(unzipped.appending(path: entries[0]).path) == .directory
                ? unzipped.appending(path: entries[0]) : unzipped
            try copyTree(from: root, to: dir)
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
            try copyTree(from: cache.appending(path: version), to: dir)
            facts = ExtensionSourceFacts(publisher: ExtensionPublisher.claudeCode(marketplace: marketplace), sourceType: "claudeCode",
                                         sourceUrl: "\(marketplace)/\(plugin)@\(version)", sourceSha: nil)
        case .lab(let agentId, let path, let commit):
            guard let labArchive else { throw ExtensionError.message("lab sources arrive with Task 10b") }
            let archived = dir.appending(path: ".archive", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: false)
            try labArchive(agentId, path, commit, archived)
            try copyTree(from: archived, to: dir)
            try FileManager.default.removeItem(at: archived)
            facts = ExtensionSourceFacts(publisher: "lab:\(agentId)", sourceType: "lab", sourceUrl: path, sourceSha: commit)
        }
        let id = try decompose(dir, bare: bare, notices: &notices)
        return StagedExtension(dir: dir, id: id, notices: notices, source: facts)
    }

    // MARK: Copy under the limits

    /// Copies `source` into `dest` (created): regular files and directories only, modes normalized (0755 under `bin/`, else
    /// 0644), every name checked, the limits enforced. A link, device or odd name refuses the import.
    public static func copyTree(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        guard SandboxPath.kind(source.path) == .directory else { throw ExtensionError.message("\(source.path) is not a directory") }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        var count = 0
        var total: Int64 = 0
        for f in try PackageWalk.files(root: source, includeDirectories: true) {
            let name = f.url.lastPathComponent
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
    }

    static func unzip(_ zip: URL, into dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["unzip", "-q", "-o", "-n", zip.path, "-d", dir.path]
        p.environment = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ExtensionError.message("unzip failed: \(Store.flat(String(decoding: stderr, as: UTF8.self), max: 200))")
        }
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
                throw ExtensionError.message("SKILL.md has no frontmatter name to use as the id")
            }
            if let problem = ExtensionId.problem(name) { throw ExtensionError.message(problem) }
            let description = fm_.value("description") ?? "Skill \(name)."
            try fm.createDirectory(at: dir.appending(path: "skills"), withIntermediateDirectories: true)
            try fm.moveItem(at: skillDir, to: dir.appending(path: "skills/\(name)"))
            try fm.createDirectory(at: dir.appending(path: ".claude-plugin"), withIntermediateDirectories: true)
            let manifest = ExtensionManifest(name: name, version: "0.1.0", description: String(description.prefix(ExtensionLimits.maxDescription)),
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
        if let servers = object.removeValue(forKey: "mcpServers")?.objectValue {
            for name in servers.keys.sorted() { notices.append(mcpNotice(Store.flat(name, max: 60))) }
        }
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
        for key in ["homepage", "repository", "license", "keywords", "commands", "agents", "skills"] where object[key] != nil {
            object.removeValue(forKey: key)
            notices.append("The manifest key \(key) was dropped (not part of the 4-key manifest).")
        }
        // The four keys are filled in when missing, with a notice.
        if object["version"]?.stringValue == nil { object["version"] = .string("0.0.0"); notices.append("The manifest had no version; 0.0.0 was set.") }
        if object["description"]?.stringValue == nil { object["description"] = .string("Imported plugin \(id)."); notices.append("The manifest had no description; one was set.") }
        if object["author"] == nil { object["author"] = .object(["name": .string("unknown")]); notices.append("The manifest had no author; 'unknown' was set.") }
        try ExtensionJSON.encode(JSONValue.object(object)).write(to: dir.appending(path: ExtensionManifest.path))

        // Files and directories Brahma does not run.
        for name in try fm.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appending(path: name)
            switch name {
            case "hooks":
                let json = url.appending(path: "hooks.json")
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
            case "settings.json", "monitors", "output-styles", "themes", "workflows", "CLAUDE.md":
                notices.append("This plugin's \(name) was not imported; it reconfigures the harness and is not a plugin part."); try fm.removeItem(at: url)
            case ".DS_Store", ".git", ".orphaned_at":
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
        } else if let path = value.stringValue, ExtensionLimits.isSafeName(path.replacingOccurrences(of: "/", with: "_")),
                  !path.contains(".."), let d = FileManager.default.contents(atPath: root.appending(path: path).path),
                  let v = try? JSONDecoder().decode(JSONValue.self, from: d) {
            events = (v.objectValue?["hooks"]?.objectValue ?? v.objectValue ?? [:]).keys.sorted()
        }
        if events.isEmpty { return [hookNotice("every")] }
        return events.map { hookNotice(Store.flat($0, max: 40)) }
    }

    static func looksSecret(key: String, spec: JSONValue) -> Bool {
        let lower = key.lowercased()
        if ["token", "secret", "password", "passwd", "apikey", "api_key", "credential", "auth"].contains(where: { lower.contains($0) }) { return true }
        if lower.hasSuffix("key") { return true }
        if spec.objectValue?["sensitive"]?.boolValue == true { return true }
        return false
    }
}

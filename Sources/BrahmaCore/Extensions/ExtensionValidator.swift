import Foundation

// The extension validator (Task 5a): an allowlist over a staged package. Hooks, MCP and LSP servers, monitors, plugin
// settings, output styles, themes, workflows, install scripts, links and binaries outside `assets/` are refused from every
// source; frontmatter is allowlisted on every `.md` under `skills/`, `commands/` and `agents/`; the hygiene scans raise
// flags that ride on the owner's card. Claude's own `plugin validate --strict` and `plugin details` run only on an
// allowlisted copy, under the sandboxed runner, with hooks off and no network.

/// Stable issue codes (`EXT001 hook-refused` ...), the names `--json` and the card show.
public enum LintCode: String, CaseIterable, Sendable {
    case hookRefused = "EXT001"
    case mcpRefused = "EXT002"
    case lspRefused = "EXT003"
    case entryRefused = "EXT004"
    case manifestKey = "EXT005"
    case linkRefused = "EXT006"
    case installScript = "EXT007"
    case binaryOutsideAssets = "EXT008"
    case badId = "EXT009"
    case frontmatterKey = "EXT010"
    case frontmatterStripped = "EXT011"
    case agentTools = "EXT012"
    case mode = "EXT013"
    case binPrefix = "EXT014"
    case binCollision = "EXT015"
    case unicode = "EXT016"
    case injection = "EXT017"
    case credentialPath = "EXT018"
    case curlSh = "EXT019"
    case base64Blob = "EXT020"
    case secret = "EXT021"
    case host = "EXT022"
    case limits = "EXT023"
    case sidecar = "EXT024"
    case lockMismatch = "EXT025"
    case claudeValidate = "EXT026"
    case claudeDetails = "EXT027"
    case namespace = "EXT028"

    public var name: String {
        switch self {
        case .hookRefused: "hook-refused"
        case .mcpRefused: "mcp-refused"
        case .lspRefused: "lsp-refused"
        case .entryRefused: "entry-refused"
        case .manifestKey: "manifest-key"
        case .linkRefused: "link-refused"
        case .installScript: "install-script"
        case .binaryOutsideAssets: "binary-outside-assets"
        case .badId: "bad-id"
        case .frontmatterKey: "frontmatter-key"
        case .frontmatterStripped: "frontmatter-stripped"
        case .agentTools: "agent-tools"
        case .mode: "mode"
        case .binPrefix: "bin-prefix"
        case .binCollision: "bin-collision"
        case .unicode: "hidden-unicode"
        case .injection: "injection-phrasing"
        case .credentialPath: "credential-path"
        case .curlSh: "curl-sh"
        case .base64Blob: "base64-blob"
        case .secret: "secret"
        case .host: "undeclared-host"
        case .limits: "limits"
        case .sidecar: "brahma-json"
        case .lockMismatch: "lock-mismatch"
        case .claudeValidate: "claude-validate"
        case .claudeDetails: "claude-details"
        case .namespace: "namespace"
        }
    }
}

/// One lint finding. `fix` says what `--fix` would do (nil: nothing automatic).
public struct LintIssue: Codable, Equatable, Comparable, Sendable {
    public enum Severity: String, Codable, Sendable { case error, warning }
    public var code: String
    public var path: String
    public var line: Int?
    public var message: String
    public var fix: String?
    public var severity: Severity

    public init(_ code: LintCode, path: String, line: Int? = nil, message: String, fix: String? = nil, severity: Severity = .error) {
        self.code = code.rawValue; self.path = path; self.line = line
        self.message = message; self.fix = fix; self.severity = severity
    }

    public static func < (a: LintIssue, b: LintIssue) -> Bool {
        if a.code != b.code { return a.code < b.code }
        if a.path != b.path { return a.path < b.path }
        if (a.line ?? 0) != (b.line ?? 0) { return (a.line ?? 0) < (b.line ?? 0) }
        return a.message < b.message
    }
}

/// What `ExtensionValidator.fix` applies.
public enum LintFix: Equatable, Sendable {
    case stripFrontmatter(path: String, key: String)
    case renameBin(from: String, to: String)
    case chmod(path: String, mode: Int)
    case regenerateLock
}

public struct ValidationOptions: Sendable {
    /// `bin/` names of the other installed extensions of the company (name → extension id): a collision is refused.
    public var installedBins: [String: String] = [:]
    /// The tools an agent frontmatter `tools:` may name (the role's tools; the sandboxed built-ins by default).
    public var roleTools: [String] = BuiltinTools.withTask + ["mcp__company"]
    public init(installedBins: [String: String] = [:], roleTools: [String]? = nil) {
        self.installedBins = installedBins
        if let roleTools { self.roleTools = roleTools }
    }
}

public struct ValidationResult: Sendable {
    public var issues: [LintIssue] = []
    public var fixes: [LintFix] = []
    public var manifest: ExtensionManifest?
    public var sidecar: BrahmaSidecar?
    public var lintFacts = LintFacts()

    public var errors: [LintIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [LintIssue] { issues.filter { $0.severity == .warning } }
    public var id: String? { manifest?.name }
}

/// Claude's own checks: the runner, the CLI and the scratch directory (the only writable place).
public struct ClaudeCheck: Sendable {
    public var runner: any SandboxedRunner
    public var claudePath: String
    public var scratch: URL
    public var timeout: Duration = .seconds(120)

    public init(runner: any SandboxedRunner, claudePath: String, scratch: URL, timeout: Duration = .seconds(120)) {
        self.runner = runner; self.claudePath = claudePath; self.scratch = scratch; self.timeout = timeout
    }
}

public struct ClaudeCheckResult: Sendable {
    public var issues: [LintIssue] = []
    public var alwaysOnTokens: Int?
}

public enum ExtensionValidator {
    /// The plugin parts that are copied into the workspace and mounted.
    public static let pluginParts: Set<String> = ["skills", "commands", "agents", "bin"]
    /// The top-level directories a package may hold besides the plugin parts.
    static let otherDirs: Set<String> = ["assets", "tests"]
    /// Built-in agent types a skill or command's `agent:` may name.
    static let builtinAgents: Set<String> = ["general-purpose", "Explore", "Plan"]
    static let skillKeys: Set<String> = ["name", "description", "when_to_use", "argument-hint", "disable-model-invocation", "user-invocable",
                                         "context", "agent", "license", "metadata", "version"]
    static let agentKeys: Set<String> = ["name", "description", "tools", "disallowedTools", "color", "skills"]
    static let strippedKeys: Set<String> = ["allowed-tools", "model"]
    static let agentRefusedKeys: Set<String> = ["permissionMode", "isolation", "background"]

    // MARK: Structure

    /// How a top-level entry is classed.
    enum TopLevel: Equatable {
        case manifestDir, part, other, readme, license, sidecar, lock
        case refused(LintCode, String)
    }

    static func classify(topLevel name: String) -> TopLevel {
        switch name {
        case ".claude-plugin": return .manifestDir
        case "hooks", "hooks.json": return .refused(.hookRefused, "hooks never run in Brahma")
        case ".mcp.json": return .refused(.mcpRefused, "an MCP server never runs from a package; connectors arrive in a later Brahma")
        case ".lsp.json": return .refused(.lspRefused, "an LSP server never runs from a package")
        case "monitors", "settings.json", "output-styles", "themes", "workflows":
            return .refused(.entryRefused, "\(name) reconfigures the harness and is not a plugin part")
        case "CLAUDE.md": return .refused(.entryRefused, "a root CLAUDE.md is not a plugin part")
        case "node_modules": return .refused(.entryRefused, "node_modules is an install footprint, not a plugin part")
        case BrahmaSidecar.path: return .sidecar
        case ExtensionLock.path: return .lock
        default:
            if pluginParts.contains(name) { return .part }
            if otherDirs.contains(name) { return .other }
            if name.hasPrefix("README") { return .readme }
            if name.hasPrefix("LICENSE") || name.hasPrefix("LICENCE") { return .license }
            return .refused(.entryRefused, "'\(Store.flat(name, max: 60))' is not a plugin part")
        }
    }

    /// Whether a top-level name is allowed into the allowlisted copy Claude's own checks see.
    static func isAllowlistedForClaude(_ name: String) -> Bool {
        switch classify(topLevel: name) {
        case .manifestDir, .part, .readme, .license: return true
        case .other: return name == "assets"
        default: return false
        }
    }

    public static func validate(staged root: URL, options: ValidationOptions = ValidationOptions()) -> ValidationResult {
        var r = ValidationResult()
        func issue(_ code: LintCode, _ path: String, line: Int? = nil, _ message: String, fix: String? = nil, severity: LintIssue.Severity = .error) {
            r.issues.append(LintIssue(code, path: path, line: line, message: message, fix: fix, severity: severity))
        }

        // 1. The tree: no links, devices or odd names; the limits.
        let files: [PackageFile]
        do { files = try PackageWalk.files(root: root, includeDirectories: true) } catch {
            issue(.entryRefused, ".", "\(error)")
            r.issues.sort(); return r
        }
        var regular: [PackageFile] = []
        var total: Int64 = 0
        for f in files {
            let name = f.url.lastPathComponent
            if !ExtensionLimits.isSafeName(name) {
                issue(.unicode, f.relative, "the name holds a control, hidden or bidi character")
            }
            switch f.kind {
            case .link: issue(.linkRefused, f.relative, "symbolic links are refused")
            case .other: issue(.linkRefused, f.relative, "devices, sockets and pipes are refused")
            case .directory: break
            case .regular:
                if f.nlink > 1 { issue(.linkRefused, f.relative, "hard links are refused") }
                regular.append(f); total += f.size
            }
        }
        if regular.count > ExtensionLimits.maxFiles { issue(.limits, ".", "\(regular.count) files; at most \(ExtensionLimits.maxFiles)") }
        if total > ExtensionLimits.maxBytes { issue(.limits, ".", "\(total) bytes; at most \(ExtensionLimits.maxBytes)") }

        // 2. The manifest.
        var id = ""
        if let data = FileManager.default.contents(atPath: root.appending(path: ExtensionManifest.path).path) {
            let p = ExtensionManifest.parse(data)
            for problem in p.problems { issue(.manifestKey, ExtensionManifest.path, problem) }
            for key in p.extraKeys {
                switch key {
                case "hooks": issue(.hookRefused, ExtensionManifest.path, "plugin.json hooks: hooks never run in Brahma")
                case "mcpServers": issue(.mcpRefused, ExtensionManifest.path, "plugin.json mcpServers: an MCP server never runs from a package")
                case "lspServers": issue(.lspRefused, ExtensionManifest.path, "plugin.json lspServers: an LSP server never runs from a package")
                default:
                    issue(.manifestKey, ExtensionManifest.path, "plugin.json key '\(Store.flat(key, max: 40))' is not one of name, version, description, author")
                }
            }
            if let m = p.manifest {
                r.manifest = m
                id = m.name
                if let problem = ExtensionId.problem(m.name) { issue(.badId, ExtensionManifest.path, problem) }
                if m.description.count > ExtensionLimits.maxDescription {
                    issue(.limits, ExtensionManifest.path, "description is \(m.description.count) characters; at most \(ExtensionLimits.maxDescription)")
                }
                if hiddenLine(in: String(decoding: data, as: UTF8.self)) != nil {
                    issue(.unicode, ExtensionManifest.path, "plugin.json holds a hidden, zero-width or bidi character")
                }
            }
        } else {
            issue(.manifestKey, ExtensionManifest.path, "no .claude-plugin/plugin.json (exactly name, version, description and author)")
        }

        // 3. The entries: top level by the allowlist, then what each part may hold.
        var skills: [String] = [], commands: [String] = [], agents: [String] = []
        var binNames: [String] = []
        var agentNames: Set<String> = []
        for f in files {
            let parts = f.relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let top = parts.first else { continue }
            if parts.count == 1 {
                switch classify(topLevel: top) {
                case .refused(let code, let message): issue(code, f.relative, message)
                case .manifestDir, .part, .other:
                    if f.kind != .directory { issue(.entryRefused, f.relative, "\(top) must be a directory") }
                case .readme, .license, .sidecar, .lock:
                    if f.kind == .directory { issue(.entryRefused, f.relative, "\(top) must be a file") }
                }
                continue
            }
            // Refused names anywhere below the top level (a refused top-level entry was already reported once).
            if case .refused = classify(topLevel: top) { continue }
            for (i, component) in parts.enumerated() where i > 0 {
                switch component {
                case "hooks", "hooks.json": issue(.hookRefused, f.relative, "hooks never run in Brahma")
                case ".mcp.json": issue(.mcpRefused, f.relative, "an MCP server never runs from a package")
                case ".lsp.json": issue(.lspRefused, f.relative, "an LSP server never runs from a package")
                case "node_modules": issue(.entryRefused, f.relative, "node_modules is an install footprint, not a plugin part")
                default: break
                }
            }
            switch top {
            case ".claude-plugin":
                if f.relative != ExtensionManifest.path { issue(.entryRefused, f.relative, "only plugin.json belongs in .claude-plugin") }
            case "skills":
                if parts.count == 2, f.kind == .directory {
                    skills.append(parts[1])
                    if !FileManager.default.fileExists(atPath: f.url.appending(path: "SKILL.md").path) {
                        issue(.entryRefused, f.relative, "a skill directory needs a SKILL.md")
                    }
                } else if parts.count == 2 {
                    issue(.entryRefused, f.relative, "skills/ holds skill directories, each with a SKILL.md")
                }
            case "commands":
                if f.kind == .regular {
                    if f.relative.hasSuffix(".md") { commands.append(String(parts.last!.dropLast(3))) }
                    else { issue(.entryRefused, f.relative, "commands/ holds only .md files") }
                }
            case "agents":
                if f.kind == .regular {
                    if f.relative.hasSuffix(".md") { agents.append(String(parts.last!.dropLast(3))) }
                    else { issue(.entryRefused, f.relative, "agents/ holds only .md files") }
                }
            case "bin":
                if f.kind == .directory { issue(.entryRefused, f.relative, "bin/ holds helper files, not directories") }
                else if parts.count == 2 { binNames.append(parts[1]) }
            default: break
            }
        }

        // 4. Install scripts, binaries outside assets/, modes, bin names.
        for f in regular {
            let name = f.url.lastPathComponent, lower = name.lowercased()
            let inBin = f.relative.hasPrefix("bin/"), inAssets = f.relative.hasPrefix("assets/")
            if lower == "package.json", let text = text(of: f), let scripts = installScripts(in: text) {
                issue(.installScript, f.relative, "package.json runs \(scripts.joined(separator: ", ")) on install; nothing is installed at runtime")
            }
            if ["setup.py", "install.sh", "makefile", "gnumakefile", "binding.gyp"].contains(lower) || lower.hasSuffix(".pkg") || lower.hasSuffix(".dmg") {
                issue(.installScript, f.relative, "\(name) is an install script; nothing is installed at runtime")
            }
            if !inAssets, isBinary(f) { issue(.binaryOutsideAssets, f.relative, "a binary outside assets/ is refused") }
            let bits = Int(f.mode & 0o777)
            if inBin {
                if bits & 0o111 == 0 {
                    issue(.mode, f.relative, "bin/ helpers must be executable (0755)", fix: "chmod 0755 \(f.relative)")
                    r.fixes.append(.chmod(path: f.relative, mode: 0o755))
                } else if bits != 0o755 {
                    issue(.mode, f.relative, "mode \(String(format: "%04o", bits)); bin/ helpers are 0755", fix: "chmod 0755 \(f.relative)", severity: .warning)
                    r.fixes.append(.chmod(path: f.relative, mode: 0o755))
                }
                if !id.isEmpty, !name.hasPrefix(id + "-") {
                    issue(.binPrefix, f.relative, "bin/ names are prefixed with the extension id", fix: "rename to bin/\(id)-\(name)")
                    r.fixes.append(.renameBin(from: f.relative, to: "bin/\(id)-\(name)"))
                }
                if let owner = options.installedBins[name], owner != id {
                    issue(.binCollision, f.relative, "bin/\(name) collides with the installed extension '\(owner)'")
                }
            } else if bits & 0o111 != 0 {
                issue(.mode, f.relative, "only bin/ helpers may be executable; text is 0644", fix: "chmod 0644 \(f.relative)")
                r.fixes.append(.chmod(path: f.relative, mode: 0o644))
            } else if bits != 0o644 {
                issue(.mode, f.relative, "mode \(String(format: "%04o", bits)); text is 0644", fix: "chmod 0644 \(f.relative)", severity: .warning)
                r.fixes.append(.chmod(path: f.relative, mode: 0o644))
            }
            if f.relative.hasPrefix("skills/"), f.relative.contains("/scripts/") { r.lintFacts.executes.scripts = true }
        }
        r.lintFacts.executes.bin = !binNames.isEmpty

        // 5. Agent names first (a skill's `agent:` may name one), then every .md under skills/, commands/ and agents/.
        for f in regular where f.relative.hasPrefix("agents/") && f.relative.hasSuffix(".md") {
            if let text = text(of: f), let fm = Frontmatter.parse(text), let name = fm.value("name") { agentNames.insert(name) }
            agentNames.insert(String(f.url.lastPathComponent.dropLast(3)))
        }
        for f in regular where f.relative.hasSuffix(".md") {
            let isAgent = f.relative.hasPrefix("agents/")
            let isSkillOrCommand = f.relative.hasPrefix("skills/") || f.relative.hasPrefix("commands/")
            guard isAgent || isSkillOrCommand, let text = text(of: f) else { continue }
            if text.contains("!`") { r.lintFacts.executes.bangInjection = true }
            guard let fm = Frontmatter.parse(text) else { continue }
            for entry in fm.entries {
                let key = entry.key
                switch key {
                case "hooks": issue(.hookRefused, f.relative, line: entry.line, "frontmatter hooks: hooks never run in Brahma")
                case "mcpServers": issue(.mcpRefused, f.relative, line: entry.line, "frontmatter mcpServers: an MCP server never runs from a package")
                case "lspServers": issue(.lspRefused, f.relative, line: entry.line, "frontmatter lspServers: an LSP server never runs from a package")
                case _ where strippedKeys.contains(key):
                    issue(.frontmatterStripped, f.relative, line: entry.line,
                          "'\(key)' pre-approves tools or pins a model and is stripped", fix: "remove '\(key)' from the frontmatter", severity: .warning)
                    r.fixes.append(.stripFrontmatter(path: f.relative, key: key))
                    r.lintFacts.stripped.append("\(f.relative): \(key)")
                case _ where isAgent && agentRefusedKeys.contains(key):
                    issue(.frontmatterKey, f.relative, line: entry.line, "agent frontmatter '\(key)' is refused (it widens what the agent may do)")
                case _ where isAgent && !agentKeys.contains(key):
                    issue(.frontmatterKey, f.relative, line: entry.line, "agent frontmatter '\(Store.flat(key, max: 40))' is not allowed")
                case _ where !isAgent && !skillKeys.contains(key):
                    issue(.frontmatterKey, f.relative, line: entry.line, "frontmatter '\(Store.flat(key, max: 40))' is not allowed")
                case "context" where !isAgent:
                    if entry.value != "fork" { issue(.frontmatterKey, f.relative, line: entry.line, "context may only be 'fork'") }
                case "agent" where !isAgent:
                    if !agentNames.contains(entry.value), !builtinAgents.contains(entry.value) {
                        issue(.frontmatterKey, f.relative, line: entry.line, "agent '\(Store.flat(entry.value, max: 40))' is neither in this extension nor built in")
                    }
                case "tools" where isAgent:
                    let allowed = Set(options.roleTools)
                    let extra = fm.list("tools").filter { !allowed.contains($0) }
                    if !extra.isEmpty {
                        issue(.agentTools, f.relative, line: entry.line, "agent tools must be a subset of the role's: \(extra.map { Store.flat($0, max: 40) }.joined(separator: ", "))")
                    }
                default: break
                }
            }
        }

        // 6. The scans, over every text file (fixtures included).
        var hosts: Set<String> = []
        for f in regular where f.size <= Int64(ExtensionLimits.maxScannedBytes) {
            guard let text = text(of: f) else { continue }
            let isConfig = f.relative == ExtensionManifest.path || f.relative == BrahmaSidecar.path
            if let line = hiddenLine(in: text), !isConfig {
                issue(.unicode, f.relative, line: line, "a hidden, zero-width or bidi character", severity: .warning)
                r.lintFacts.hiddenUnicode.append(f.relative)
            }
            for (code, regex, message) in Scans.flags {
                if let line = Scans.firstLine(regex, in: text) { issue(code, f.relative, line: line, message, severity: .warning) }
            }
            for (label, regex) in Scans.secrets {
                if let line = Scans.firstLine(regex, in: text) { issue(.secret, f.relative, line: line, "a value that looks like a secret (\(label))") }
            }
            for h in Scans.hosts(in: text) { hosts.insert(h) }
        }
        r.lintFacts.hosts = hosts.sorted()

        // 7. The sidecar, then undeclared hosts.
        if let s = BrahmaSidecar.read(root) {
            for problem in s.problems { issue(.sidecar, BrahmaSidecar.path, problem) }
            r.sidecar = s.sidecar
        }
        let declared = Set(r.sidecar?.agentNetwork ?? [])
        for h in r.lintFacts.hosts where !declared.contains(h) {
            issue(.host, ".", "host \(h) is referenced but not declared in brahma.json agentNetwork", severity: .warning)
        }

        // 8. Namespace: a skill's frontmatter name should be its directory name.
        for s in skills {
            if let text = try? String(contentsOf: root.appending(path: "skills/\(s)/SKILL.md"), encoding: .utf8),
               let name = Frontmatter.parse(text)?.value("name"), name != s {
                issue(.namespace, "skills/\(s)/SKILL.md", "skill name '\(Store.flat(name, max: 40))' differs from its directory '\(s)'", severity: .warning)
            }
        }

        r.lintFacts.skills = skills.sorted(); r.lintFacts.commands = commands.sorted(); r.lintFacts.agents = agents.sorted()
        r.lintFacts.parts = pluginParts.filter { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }.sorted()

        // 9. The lock: it must be exactly what lint would generate.
        if FileManager.default.fileExists(atPath: root.appending(path: ExtensionLock.path).path), let m = r.manifest {
            if let have = ExtensionLock.read(root: root), let want = try? ExtensionLock.generate(root: root, id: m.name, version: m.version, lint: r.lintFacts),
               have.matches(want) {
            } else {
                issue(.lockMismatch, ExtensionLock.path, "ext.lock.json differs from what lint generates (it is never hand-edited)",
                      fix: "regenerate with brahma ext lint --lock")
                r.fixes.append(.regenerateLock)
            }
        }
        r.issues.sort()
        return r
    }

    // MARK: Fix

    /// Applies the result's fixes to the package in place; returns what was done. The lock is regenerated last, from a fresh
    /// validation, so it describes the fixed tree.
    @discardableResult
    public static func fix(staged root: URL, result: ValidationResult) throws -> [String] {
        var done: [String] = []
        for f in result.fixes {
            switch f {
            case .stripFrontmatter(let path, let key):
                let url = root.appending(path: path)
                let text = try String(contentsOf: url, encoding: .utf8)
                if let stripped = Frontmatter.strip(key: key, from: text) {
                    try Data(stripped.utf8).write(to: url)
                    done.append("stripped '\(key)' from \(path)")
                }
            case .renameBin(let from, let to):
                let dest = root.appending(path: to)
                guard !FileManager.default.fileExists(atPath: dest.path) else { throw ExtensionError.message("\(to) already exists") }
                try FileManager.default.moveItem(at: root.appending(path: from), to: dest)
                done.append("renamed \(from) to \(to)")
            case .chmod(let path, let mode):
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: root.appending(path: path).path)
                done.append("chmod \(String(format: "%04o", mode)) \(path)")
            case .regenerateLock:
                break
            }
        }
        if result.fixes.contains(.regenerateLock) || FileManager.default.fileExists(atPath: root.appending(path: ExtensionLock.path).path) {
            try writeLock(root: root)
            done.append("regenerated \(ExtensionLock.path)")
        }
        return done
    }

    /// Writes the lock lint would generate for the tree as it is now (the package must have a valid manifest).
    public static func writeLock(root: URL, alwaysOnTokens: Int? = nil) throws {
        let again = validate(staged: root)
        guard let m = again.manifest else { throw ExtensionError.message("cannot write a lock without a valid plugin.json") }
        var facts = again.lintFacts
        if let alwaysOnTokens { facts.alwaysOnTokens = alwaysOnTokens }
        try ExtensionLock.generate(root: root, id: m.name, version: m.version, lint: facts).write(to: root)
    }

    // MARK: Claude's own checks

    /// `claude plugin validate --strict` and `claude plugin details`, on an allowlisted copy at `<scratch>/plugin` only, under the
    /// sandboxed runner: no network, writable = the scratch dir, `--setting-sources ""`, `--strict-mcp-config`,
    /// `--settings '{"disableAllHooks":true}'`, `HOME` and `CLAUDE_CONFIG_DIR` inside the scratch. A failing `validate` is an
    /// error; a `details` that cannot run or report is recorded as unavailable (a warning).
    public static func claudeChecks(staged root: URL, check: ClaudeCheck) async -> ClaudeCheckResult {
        var out = ClaudeCheckResult()
        let fm = FileManager.default
        let copy = check.scratch.appending(path: "plugin", directoryHint: .isDirectory)
        let config = check.scratch.appending(path: "cc", directoryHint: .isDirectory)
        let home = check.scratch.appending(path: "home", directoryHint: .isDirectory)
        do {
            try fm.createDirectory(at: check.scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }
            try allowlistedCopy(of: root, to: copy)
            try fm.createDirectory(at: config, withIntermediateDirectories: true)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
        } catch {
            out.issues.append(LintIssue(.claudeDetails, path: ".", message: "claude checks unavailable: \(error)", severity: .warning))
            return out
        }
        var env = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        env["HOME"] = home.path
        env["CLAUDE_CONFIG_DIR"] = config.path
        env.removeValue(forKey: "TMPDIR")
        var readable: [URL] = []
        let resolved = URL(fileURLWithPath: check.claudePath).resolvedForSandbox.deletingLastPathComponent()
        if resolved.path != "/" { readable.append(resolved) }
        let policy = SandboxPolicy(writable: [check.scratch], readable: readable, network: .none, toolchain: false)
        func command(_ sub: [String]) -> String { claudeCommand(check.claudePath, sub, plugin: copy.path) }
        let validateOut = await check.runner.run(command: command(["validate", "--strict"]), cwd: check.scratch, environment: env,
                                                 timeout: check.timeout, outputURL: check.scratch.appending(path: "validate.log"), policy: policy)
        switch validateOut.exitCode {
        case 0?: break
        case nil:
            out.issues.append(LintIssue(.claudeDetails, path: ".", message: "claude plugin validate unavailable: \(Store.flat(validateOut.tail, max: 200))", severity: .warning))
        case let code?:
            out.issues.append(LintIssue(.claudeValidate, path: ".", message: "claude plugin validate --strict failed (\(code)): \(Store.flat(validateOut.tail, max: 400))"))
        }
        let detailsOut = await check.runner.run(command: command(["details"]), cwd: check.scratch, environment: env,
                                                timeout: check.timeout, outputURL: check.scratch.appending(path: "details.log"), policy: policy)
        if detailsOut.exitCode == 0, let tokens = alwaysOnTokens(in: detailsOut.tail) {
            out.alwaysOnTokens = tokens
        } else {
            out.issues.append(LintIssue(.claudeDetails, path: ".", message: "always-on tokens unavailable (claude plugin details: \(Store.flat(detailsOut.tail, max: 200)))",
                                        severity: .warning))
        }
        return out
    }

    /// Copies only the allowlisted parts (regular files, modes normalized): what Claude's checks and the workspace mount see.
    static func allowlistedCopy(of root: URL, to dest: URL, parts: ((String) -> Bool) = isAllowlistedForClaude) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for f in try PackageWalk.files(root: root) where f.kind == .regular {
            guard let top = f.relative.split(separator: "/").first.map(String.init), parts(top) else { continue }
            if f.relative.split(separator: "/").dropFirst().contains(where: { ["hooks", "hooks.json", ".mcp.json", ".lsp.json", "node_modules"].contains(String($0)) }) { continue }
            let target = dest.appending(path: f.relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = fm.contents(atPath: f.url.path) else { throw ExtensionError.message("cannot read \(f.relative)") }
            let mode = f.relative.hasPrefix("bin/") ? 0o755 : 0o644
            try data.write(to: target)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
    }

    static func alwaysOnTokens(in text: String) -> Int? {
        for pattern in [#"(?i)always[- ]on[^0-9\n]{0,60}?([0-9][0-9,]*)"#, #""alwaysOnTokens"\s*:\s*([0-9]+)"#, #"(?i)([0-9][0-9,]*)\s+tokens\b"#] {
            if let m = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text), let n = Int(text[r].replacingOccurrences(of: ",", with: "")) {
                return n
            }
        }
        return nil
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// `'<claude>' plugin <sub…> '<plugin>' --setting-sources '' --strict-mcp-config --settings '{"disableAllHooks":true}'`.
    static func claudeCommand(_ claude: String, _ sub: [String], plugin: String) -> String {
        ([shellQuote(claude), "plugin"] + sub + [shellQuote(plugin), "--setting-sources", "''", "--strict-mcp-config", "--settings",
                                                 shellQuote("{\"disableAllHooks\":true}")]).joined(separator: " ")
    }

    // MARK: Helpers

    static func text(of f: PackageFile) -> String? {
        guard f.size <= Int64(ExtensionLimits.maxScannedBytes), let data = FileManager.default.contents(atPath: f.url.path) else { return nil }
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The first line (1-based) holding a hidden, zero-width or bidi scalar.
    static func hiddenLine(in text: String) -> Int? {
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.unicodeScalars.contains(where: ExtensionLimits.isHiddenOrBidi) {
            return i + 1
        }
        return nil
    }

    static func isBinary(_ f: PackageFile) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: f.url.path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        if head.isEmpty { return false }
        let magic = [UInt8](head.prefix(4))
        if magic == [0x7F, 0x45, 0x4C, 0x46] { return true }
        if magic.count == 4, [[0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF], [0xCE, 0xFA, 0xED, 0xFE], [0xCF, 0xFA, 0xED, 0xFE],
                              [0xCA, 0xFE, 0xBA, 0xBE], [0xBE, 0xBA, 0xFE, 0xCA]].contains(magic) { return true }
        return head.contains(0)
    }

    static func installScripts(in packageJSON: String) -> [String]? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(packageJSON.utf8)),
              let scripts = v.objectValue?["scripts"]?.objectValue else { return nil }
        let found = ["preinstall", "install", "postinstall", "prepare"].filter { scripts[$0] != nil }
        return found.isEmpty ? nil : found
    }
}

/// The YAML subset a plugin's frontmatter uses: top-level `key: value` lines between the `---` fences; indented lines belong
/// to the key above them (a map or a list).
struct Frontmatter {
    struct Entry { var key: String; var value: String; var line: Int; var continuation: [String] }
    var entries: [Entry]
    /// The line of the closing fence.
    var end: Int

    static func parse(_ text: String) -> Frontmatter? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        var entries: [Entry] = []
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { return Frontmatter(entries: entries, end: i + 1) }
            if line.first == " " || line.first == "\t" || line.isEmpty || line.hasPrefix("#") {
                if !entries.isEmpty, !line.isEmpty, !line.hasPrefix("#") { entries[entries.count - 1].continuation.append(line) }
                i += 1; continue
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                entries.append(Entry(key: key, value: value, line: i + 1, continuation: []))
            }
            i += 1
        }
        return nil
    }

    func value(_ key: String) -> String? {
        guard let e = entries.first(where: { $0.key == key }) else { return nil }
        let v = e.value
        if (v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2) || (v.hasPrefix("'") && v.hasSuffix("'") && v.count >= 2) {
            return String(v.dropFirst().dropLast())
        }
        return v
    }

    /// A comma list (`a, b`), a flow list (`[a, b]`) or a block list (`- a`).
    func list(_ key: String) -> [String] {
        guard let e = entries.first(where: { $0.key == key }) else { return [] }
        var items: [String] = []
        var inline = e.value
        if inline.hasPrefix("["), inline.hasSuffix("]") { inline = String(inline.dropFirst().dropLast()) }
        items += inline.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        for c in e.continuation {
            let t = c.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") { items.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
        }
        return items.filter { !$0.isEmpty }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    }

    /// The text without `key` (and its indented continuation lines); nil when the key is not there.
    static func strip(key: String, from text: String) -> String? {
        guard let fm = parse(text), let e = fm.entries.first(where: { $0.key == key }) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = e.line - 1
        var endIndex = start + 1
        while endIndex < lines.count, lines[endIndex].first == " " || lines[endIndex].first == "\t" { endIndex += 1 }
        lines.removeSubrange(start..<endIndex)
        return lines.joined(separator: "\n")
    }
}

/// The hygiene scans: flags (warnings) and the secret patterns (errors). A finding names the rule, never the match.
enum Scans {
    static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    static let flags: [(LintCode, NSRegularExpression, String)] = [
        (.injection, regex(#"(?i)\b(ignore|disregard|forget)\b.{0,40}\b(previous|prior|above|earlier|system)\b.{0,20}\b(instructions?|prompts?|rules?)\b|(?i)\byou are now\b|(?i)\bdo not (tell|inform) the (user|owner)\b"#),
         "injection-like phrasing"),
        (.credentialPath, regex(#"(~|\$HOME|/Users/[^/\s]+|/home/[^/\s]+)/\.(aws|ssh|netrc|claude|npmrc|config/gh|docker/config\.json)\b|\b(id_rsa|id_ed25519|credentials\.json|\.netrc|Keychain)\b|\.aws/credentials"#),
         "a reference to a credential path"),
        (.curlSh, regex(#"\b(curl|wget)\b[^|\n]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#), "a pipe-to-shell install"),
        (.base64Blob, regex(#"[A-Za-z0-9+/]{200,}={0,2}"#), "a base64 blob"),
    ]

    static let secrets: [(String, NSRegularExpression)] = SecretScan.patterns.compactMap { p in
        (try? NSRegularExpression(pattern: p.ere)).map { (p.label, $0) }
    }

    static let url = regex(#"https?://([A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,})(?::\d+)?(?:[/?#]|\b)"#)

    static func firstLine(_ r: NSRegularExpression, in text: String) -> Int? {
        guard let m = r.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(m.range, in: text) else { return nil }
        return text[..<range.lowerBound].filter { $0 == "\n" }.count + 1
    }

    static func hosts(in text: String) -> [String] {
        url.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range(at: 1), in: text).map { String(text[$0]).lowercased() }
        }.filter { !$0.hasSuffix(".") && $0 != "example.invalid" }
    }
}

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The extension validator (Task 5a): an allowlist over a staged package. Hooks, MCP and LSP servers, monitors, plugin
// settings, output styles, themes, workflows, install scripts, links and binaries outside `assets/` are refused from every
// source; frontmatter is allowlisted on every `.md` under `skills/`, `commands/` and `agents/` under a strict YAML subset
// (anything that does not parse cleanly is refused, never passed through); the hygiene scans raise flags that ride on the
// owner's card. Claude's own `plugin validate --strict` and `plugin details` run only on an allowlisted copy, under the
// sandboxed runner, with hooks off and no network.

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
    /// A part that reads `${CLAUDE_PLUGIN_ROOT}/assets`: `assets/` is not mounted in this release (10b, B-M14).
    case assetsUnmounted = "EXT029"

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
        case .assetsUnmounted: "assets-unmounted"
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

/// Claude's own checks: the runner, the CLI and the scratch directory (the only writable place). `userHome` is the owner's
/// home (the account's by default): the CLI's own directory is made readable only when it is not the home, an ancestor of
/// it, or a protected path.
public struct ClaudeCheck: Sendable {
    public var runner: any SandboxedRunner
    public var claudePath: String
    public var scratch: URL
    public var timeout: Duration = .seconds(120)
    public var userHome: URL

    public init(runner: any SandboxedRunner, claudePath: String, scratch: URL, timeout: Duration = .seconds(120), userHome: URL? = nil) {
        self.runner = runner; self.claudePath = claudePath; self.scratch = scratch; self.timeout = timeout
        self.userHome = userHome ?? ExtensionImporter.ownerHome()
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
    /// Names refused anywhere below the top level (compared lowercased).
    static let refusedNested: Set<String> = ["hooks", "hooks.json", ".mcp.json", ".lsp.json", "node_modules"]

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

    /// `brahma ext lint --json`: the issues as a sorted array of `{code, path, line, message, fix}` (pretty, keys sorted), `[]`
    /// when clean. `propose_extension` returns the same list (10b).
    public static func lintJSON(_ issues: [LintIssue]) -> String {
        guard !issues.isEmpty else { return "[]" }
        let rows: [[String: Any]] = issues.sorted().map {
            ["code": $0.code, "path": $0.path, "line": $0.line as Any? ?? NSNull(), "message": $0.message, "fix": $0.fix as Any? ?? NSNull()]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether a relative path is a plugin-part Markdown file (skills, commands, agents; `.md` matched case-insensitively).
    static func isPluginPartMarkdown(_ relative: String) -> Bool {
        let lower = relative.lowercased()
        return lower.hasSuffix(".md") && (lower.hasPrefix("skills/") || lower.hasPrefix("commands/") || lower.hasPrefix("agents/"))
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
                if m.description.unicodeScalars.count > ExtensionLimits.maxDescription {
                    issue(.limits, ExtensionManifest.path, "description is \(m.description.unicodeScalars.count) characters; at most \(ExtensionLimits.maxDescription)")
                }
            }
            // Hidden characters in the decoded strings (escapes included) or the raw bytes.
            if ExtensionLimits.hasHidden(.object(p.object)) || ExtensionLimits.hiddenLine(in: String(decoding: data, as: UTF8.self)) != nil {
                issue(.unicode, ExtensionManifest.path, "plugin.json holds a hidden, zero-width or bidi character")
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
            // Refused names anywhere below the top level, whatever their case (a refused top-level entry was already reported once).
            if case .refused = classify(topLevel: top) { continue }
            for (i, component) in parts.enumerated() where i > 0 {
                switch component.lowercased() {
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
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: f.url.path)) ?? []
                    if !names.contains("SKILL.md") { issue(.entryRefused, f.relative, "a skill directory needs a SKILL.md (named exactly so)") }
                    for n in names where n.lowercased() == "skill.md" && n != "SKILL.md" {
                        issue(.entryRefused, "\(f.relative)/\(n)", "the skill file is named exactly SKILL.md; '\(n)' is refused")
                    }
                } else if parts.count == 2 {
                    issue(.entryRefused, f.relative, "skills/ holds skill directories, each with a SKILL.md")
                }
            case "commands":
                if f.kind == .regular {
                    if f.relative.lowercased().hasSuffix(".md") { commands.append(String(parts.last!.dropLast(3))) }
                    else { issue(.entryRefused, f.relative, "commands/ holds only .md files") }
                }
            case "agents":
                if f.kind == .regular {
                    if f.relative.lowercased().hasSuffix(".md") { agents.append(String(parts.last!.dropLast(3))) }
                    else { issue(.entryRefused, f.relative, "agents/ holds only .md files") }
                }
            case "bin":
                if f.kind == .directory { issue(.entryRefused, f.relative, "bin/ holds helper files, not directories") }
                else if parts.count == 2 { binNames.append(parts[1]) }
            default: break
            }
        }

        // 4. Install scripts, binaries outside assets/, modes (setuid/setgid/sticky included), bin names.
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
            let bits = Int(f.mode & 0o7777)
            if bits & 0o7000 != 0 {
                issue(.mode, f.relative, "setuid, setgid and sticky bits are refused", fix: "chmod \(inBin ? "0755" : "0644") \(f.relative)")
                r.fixes.append(.chmod(path: f.relative, mode: inBin ? 0o755 : 0o644))
            } else if inBin {
                if bits & 0o111 == 0 {
                    issue(.mode, f.relative, "bin/ helpers must be executable (0755)", fix: "chmod 0755 \(f.relative)")
                    r.fixes.append(.chmod(path: f.relative, mode: 0o755))
                } else if bits != 0o755 {
                    issue(.mode, f.relative, "mode \(String(format: "%04o", bits)); bin/ helpers are 0755", fix: "chmod 0755 \(f.relative)", severity: .warning)
                    r.fixes.append(.chmod(path: f.relative, mode: 0o755))
                }
            } else if bits & 0o111 != 0 {
                issue(.mode, f.relative, "only bin/ helpers may be executable; text is 0644", fix: "chmod 0644 \(f.relative)")
                r.fixes.append(.chmod(path: f.relative, mode: 0o644))
            } else if bits != 0o644 {
                issue(.mode, f.relative, "mode \(String(format: "%04o", bits)); text is 0644", fix: "chmod 0644 \(f.relative)", severity: .warning)
                r.fixes.append(.chmod(path: f.relative, mode: 0o644))
            }
            if inBin {
                if !id.isEmpty, !name.hasPrefix(id + "-") {
                    issue(.binPrefix, f.relative, "bin/ names are prefixed with the extension id", fix: "rename to bin/\(id)-\(name)")
                    r.fixes.append(.renameBin(from: f.relative, to: "bin/\(id)-\(name)"))
                }
                if let owner = options.installedBins[name], owner != id {
                    issue(.binCollision, f.relative, "bin/\(name) collides with the installed extension '\(owner)'")
                }
            }
            if f.relative.hasPrefix("skills/"), f.relative.contains("/scripts/") { r.lintFacts.executes.scripts = true }
        }
        r.lintFacts.executes.bin = !binNames.isEmpty

        // 5. Plugin-part Markdown: every file is read whole (oversized, undecodable or malformed frontmatter is an error, never
        // skipped); agent names first (a skill's `agent:` may name one).
        var parsed: [String: Frontmatter] = [:]
        for f in regular where isPluginPartMarkdown(f.relative) {
            if f.size > Int64(ExtensionLimits.maxScannedBytes) {
                issue(.limits, f.relative, "a plugin-part Markdown file over \(ExtensionLimits.maxScannedBytes) bytes is refused"); continue
            }
            guard let data = FileManager.default.contents(atPath: f.url.path) else { issue(.frontmatterKey, f.relative, "cannot be read"); continue }
            guard let raw = String(data: data, encoding: .utf8) else { issue(.frontmatterKey, f.relative, "is not valid UTF-8"); continue }
            let text = Frontmatter.normalize(raw)
            if text.contains("!`") { r.lintFacts.executes.bangInjection = true }
            if let line = ExtensionLimits.hiddenLine(in: text) {
                issue(.unicode, f.relative, line: line, "a hidden, zero-width, bidi or tag character in a plugin-part file")
                r.lintFacts.hiddenUnicode.append(f.relative)
            }
            switch Frontmatter.strictParse(text) {
            case .none: break
            case .invalid(let why, let line): issue(.frontmatterKey, f.relative, line: line, "frontmatter is not the strict subset Brahma accepts: \(why)")
            case .ok(let fm):
                parsed[f.relative] = fm
                // A hidden character spelled as a YAML escape (`"‮"`) in a frontmatter value is an error too (I3).
                for e in fm.entries where ([e.value] + e.continuation).contains(where: { Frontmatter.escapedScalars(in: $0).contains(where: ExtensionLimits.isHiddenOrBidi) })
                    || e.parsed.strings.contains(where: { $0.unicodeScalars.contains(where: ExtensionLimits.isHiddenOrBidi) }) {
                    issue(.unicode, f.relative, line: e.line, "frontmatter '\(e.key)' holds an escaped hidden, zero-width, bidi or tag character")
                    r.lintFacts.hiddenUnicode.append(f.relative)
                }
            }
        }
        for (path, fm) in parsed where path.hasPrefix("agents/") {
            if let name = fm.value("name") { agentNames.insert(name) }
            agentNames.insert(String(URL(fileURLWithPath: path).lastPathComponent.dropLast(3)))
        }
        for (path, fm) in parsed.sorted(by: { $0.key < $1.key }) {
            let isAgent = path.hasPrefix("agents/")
            for entry in fm.entries {
                let key = entry.key
                switch key {
                case "hooks": issue(.hookRefused, path, line: entry.line, "frontmatter hooks: hooks never run in Brahma")
                case "mcpServers": issue(.mcpRefused, path, line: entry.line, "frontmatter mcpServers: an MCP server never runs from a package")
                case "lspServers": issue(.lspRefused, path, line: entry.line, "frontmatter lspServers: an LSP server never runs from a package")
                case _ where strippedKeys.contains(key):
                    issue(.frontmatterStripped, path, line: entry.line,
                          "'\(key)' pre-approves tools or pins a model and is stripped", fix: "remove '\(key)' from the frontmatter", severity: .warning)
                    r.fixes.append(.stripFrontmatter(path: path, key: key))
                    r.lintFacts.stripped.append("\(path): \(key)")
                case _ where isAgent && agentRefusedKeys.contains(key):
                    issue(.frontmatterKey, path, line: entry.line, "agent frontmatter '\(key)' is refused (it widens what the agent may do)")
                case _ where isAgent && !agentKeys.contains(key):
                    issue(.frontmatterKey, path, line: entry.line, "agent frontmatter '\(Store.flat(key, max: 40))' is not allowed")
                case _ where !isAgent && !skillKeys.contains(key):
                    issue(.frontmatterKey, path, line: entry.line, "frontmatter '\(Store.flat(key, max: 40))' is not allowed")
                case "context" where !isAgent:
                    if fm.value("context") != "fork" { issue(.frontmatterKey, path, line: entry.line, "context may only be 'fork'") }
                case "agent" where !isAgent:
                    let agent = fm.value("agent") ?? ""
                    if !agentNames.contains(agent), !builtinAgents.contains(agent) {
                        issue(.frontmatterKey, path, line: entry.line, "agent '\(Store.flat(agent, max: 40))' is neither in this extension nor built in")
                    }
                case "tools" where isAgent:
                    let allowed = Set(options.roleTools)
                    let extra = fm.list("tools").filter { !allowed.contains($0) }
                    if !extra.isEmpty {
                        issue(.agentTools, path, line: entry.line, "agent tools must be a subset of the role's: \(extra.map { Store.flat($0, max: 40) }.joined(separator: ", "))")
                    }
                case "description", "when_to_use":
                    let count = (fm.value(key) ?? "").unicodeScalars.count
                    if count > ExtensionLimits.maxDescription {
                        issue(.limits, path, line: entry.line, "\(key) is \(count) characters; at most \(ExtensionLimits.maxDescription)")
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
            if !isConfig, !isPluginPartMarkdown(f.relative), let line = ExtensionLimits.hiddenLine(in: text) {
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
            // B-M14 (10b): only the plugin parts are mounted, never `assets/`; a part that reads it would break at run time.
            if isPluginPartMarkdown(f.relative) || f.relative.hasPrefix("bin/"), let line = Scans.firstLine(Scans.assetsReference, in: text) {
                issue(.assetsUnmounted, f.relative, line: line,
                      "reads ${CLAUDE_PLUGIN_ROOT}/assets, which is not mounted in this release; put what the skill reads under skills/<name>/",
                      severity: .warning)
            }
        }
        r.lintFacts.hosts = hosts.sorted()

        // 7. The sidecar (hidden characters in it are an error), then undeclared hosts.
        if let data = FileManager.default.contents(atPath: root.appending(path: BrahmaSidecar.path).path) {
            let s = BrahmaSidecar.parse(data)
            for problem in s.problems { issue(.sidecar, BrahmaSidecar.path, problem) }
            r.sidecar = s.sidecar
            if let tree = try? JSONDecoder().decode(JSONValue.self, from: data), ExtensionLimits.hasHidden(tree) {
                issue(.unicode, BrahmaSidecar.path, "brahma.json holds a hidden, zero-width or bidi character")
            } else if ExtensionLimits.hiddenLine(in: String(decoding: data, as: UTF8.self)) != nil {
                issue(.unicode, BrahmaSidecar.path, "brahma.json holds a hidden, zero-width or bidi character")
            }
        }
        let declared = Set(r.sidecar?.agentNetwork ?? [])
        for h in r.lintFacts.hosts where !declared.contains(h) {
            issue(.host, ".", "host \(h) is referenced but not declared in brahma.json agentNetwork", severity: .warning)
        }

        // 8. Namespace: a skill's frontmatter name should be its directory name.
        for s in skills {
            if let fm = parsed["skills/\(s)/SKILL.md"], let name = fm.value("name"), name != s {
                issue(.namespace, "skills/\(s)/SKILL.md", "skill name '\(Store.flat(name, max: 40))' differs from its directory '\(s)'", severity: .warning)
            }
        }

        r.lintFacts.skills = skills.sorted(); r.lintFacts.commands = commands.sorted(); r.lintFacts.agents = agents.sorted()
        r.lintFacts.parts = pluginParts.filter { FileManager.default.fileExists(atPath: root.appending(path: $0).path) }.sorted()

        // 9. The lock: byte for byte what lint would generate (canonical JSON, no unknown keys).
        if FileManager.default.fileExists(atPath: root.appending(path: ExtensionLock.path).path), let m = r.manifest {
            if let want = try? ExtensionLock.generate(root: root, id: m.name, version: m.version, lint: r.lintFacts), ExtensionLock.verify(root: root, generated: want) {
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

    /// Applies the result's fixes to the package in place; returns what was done. Refused while the result holds a link issue
    /// (EXT006): nothing is ever written through a shared inode. Every file is opened `O_NOFOLLOW`, must be a regular file
    /// with one link, and is changed through that descriptor. The lock is regenerated last, from a fresh validation.
    @discardableResult
    public static func fix(staged root: URL, result: ValidationResult) throws -> [String] {
        if let link = result.issues.first(where: { $0.code == LintCode.linkRefused.rawValue }) {
            throw ExtensionError.message("refusing to fix a package that holds a link (\(link.path)); remove it first")
        }
        var done: [String] = []
        for f in result.fixes {
            switch f {
            case .stripFrontmatter(let path, let key):
                let url = root.appending(path: path)
                let fd = try openOwnRegular(url)
                defer { close(fd) }
                var data = Data()
                while true {
                    var buffer = [UInt8](repeating: 0, count: 65536)
                    let n = read(fd, &buffer, buffer.count)
                    if n <= 0 { break }
                    data.append(buffer, count: n)
                }
                guard let text = String(data: data, encoding: .utf8) else { throw ExtensionError.message("\(path) is not UTF-8") }
                if let stripped = Frontmatter.strip(key: key, from: text) {
                    guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else { throw ExtensionError.message("cannot rewrite \(path)") }
                    let bytes = Array(stripped.utf8)
                    var written = 0
                    while written < bytes.count {
                        let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + written, bytes.count - written) }
                        guard n > 0 else { throw ExtensionError.message("cannot rewrite \(path)") }
                        written += n
                    }
                    done.append("stripped '\(key)' from \(path)")
                }
            case .renameBin(let from, let to):
                let dest = root.appending(path: to)
                guard !FileManager.default.fileExists(atPath: dest.path) else { throw ExtensionError.message("\(to) already exists") }
                try FileManager.default.moveItem(at: root.appending(path: from), to: dest)
                done.append("renamed \(from) to \(to)")
            case .chmod(let path, let mode):
                let fd = try openOwnRegular(root.appending(path: path))
                defer { close(fd) }
                guard fchmod(fd, mode_t(mode)) == 0 else { throw ExtensionError.message("cannot chmod \(path)") }
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

    /// A descriptor on `url` opened without following a link, checked to be this user's regular file with one link.
    static func openOwnRegular(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ExtensionError.message("cannot open \(url.lastPathComponent) (\(String(cString: strerror(errno))))") }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_uid == getuid() else {
            close(fd)
            throw ExtensionError.message("\(url.lastPathComponent) is not a plain file of this user with one link; refused")
        }
        return fd
    }

    /// Writes the lock lint would generate for the tree as it is now (the package must have a valid manifest).
    public static func writeLock(root: URL, alwaysOnTokens: Int? = nil) throws {
        let again = validate(staged: root)
        if let link = again.issues.first(where: { $0.code == LintCode.linkRefused.rawValue }) {
            throw ExtensionError.message("refusing to write a lock for a package that holds a link (\(link.path))")
        }
        guard let m = again.manifest else { throw ExtensionError.message("cannot write a lock without a valid plugin.json") }
        var facts = again.lintFacts
        if let alwaysOnTokens { facts.alwaysOnTokens = alwaysOnTokens }
        try ExtensionLock.generate(root: root, id: m.name, version: m.version, lint: facts).write(to: root)
    }

    /// Rewrites every plugin-part Markdown file in canonical form: LF line endings, no BOM, and a frontmatter holding only the
    /// allowlisted keys (`skillKeys` for skills and commands, `agentKeys` for agents), serialized by the engine. Claude Code then
    /// reads exactly what the engine wrote. The tree must have passed `validate` (every file parses under the strict subset).
    @discardableResult
    public static func canonicalize(staged root: URL) throws -> Bool {
        var changed = false
        for f in try PackageWalk.files(root: root) where f.kind == .regular && isPluginPartMarkdown(f.relative) {
            guard let data = FileManager.default.contents(atPath: f.url.path), let raw = String(data: data, encoding: .utf8) else {
                throw ExtensionError.message("\(f.relative) is not UTF-8")
            }
            let allowed = f.relative.hasPrefix("agents/") ? agentKeys : skillKeys
            guard let canonical = Frontmatter.canonical(raw, allowed: allowed) else {
                throw ExtensionError.message("\(f.relative): the frontmatter does not parse under the strict subset")
            }
            if Data(canonical.utf8) != data { try Data(canonical.utf8).write(to: f.url); changed = true }
        }
        return changed
    }

    /// Whether every plugin-part Markdown file under `root` is already in canonical form (a store copy written by an older
    /// engine may not be).
    public static func isCanonical(root: URL) throws -> Bool {
        for f in try PackageWalk.files(root: root) where f.kind == .regular && isPluginPartMarkdown(f.relative) {
            guard let data = FileManager.default.contents(atPath: f.url.path), let raw = String(data: data, encoding: .utf8),
                  let canonical = Frontmatter.canonical(raw, allowed: f.relative.hasPrefix("agents/") ? agentKeys : skillKeys),
                  Data(canonical.utf8) == data else { return false }
        }
        return true
    }

    // MARK: Claude's own checks

    /// `claude plugin validate --strict` and `claude plugin details`, on an allowlisted copy at `<scratch>/plugin` only, under the
    /// sandboxed runner: no network, writable = the scratch dir, the global options `--setting-sources ""`,
    /// `--strict-mcp-config`, `--settings '{"disableAllHooks":true}'` BEFORE `plugin`, `--plugin-dir <copy>` for `details <id>`;
    /// `HOME` and `CLAUDE_CONFIG_DIR` inside the scratch. A failing `validate` is an error; a CLI that cannot run, refuses the
    /// options or cannot report is recorded as unavailable (a warning).
    public static func claudeChecks(staged root: URL, check: ClaudeCheck) async -> ClaudeCheckResult {
        var out = ClaudeCheckResult()
        let fm = FileManager.default
        let copy = check.scratch.appending(path: "plugin", directoryHint: .isDirectory)
        let config = check.scratch.appending(path: "cc", directoryHint: .isDirectory)
        let home = check.scratch.appending(path: "home", directoryHint: .isDirectory)
        func unavailable(_ why: String) -> ClaudeCheckResult {
            var o = out
            o.issues.append(LintIssue(.claudeDetails, path: ".", message: "claude checks unavailable: \(Store.flat(why, max: 300))", severity: .warning))
            return o
        }
        let id: String
        do {
            id = try ExtensionManifest.read(root).name
            try fm.createDirectory(at: check.scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }
            try allowlistedCopy(of: root, to: copy)
            try fm.createDirectory(at: config, withIntermediateDirectories: true)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
        } catch { return unavailable("\(error)") }
        var env = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        env["HOME"] = home.path
        env["CLAUDE_CONFIG_DIR"] = config.path
        env.removeValue(forKey: "TMPDIR")
        // The CLI's own directory is readable, unless that would widen the policy to the owner's home or a protected path (M8).
        guard let readable = readableClaudeDirectory(check.claudePath, userHome: check.userHome) else {
            return unavailable("the claude binary at \(check.claudePath) sits in a directory the sandbox may not read whole")
        }
        let policy = SandboxPolicy(writable: [check.scratch], readable: readable, network: .none, toolchain: false)
        let validateOut = await check.runner.run(command: claudeCommand(check.claudePath, ["plugin", "validate", "--strict", copy.path]),
                                                 cwd: check.scratch, environment: env, timeout: check.timeout,
                                                 outputURL: check.scratch.appending(path: "validate.log"), policy: policy)
        switch validateOut.exitCode {
        case 0?: break
        case nil:
            out.issues.append(LintIssue(.claudeDetails, path: ".", message: "claude plugin validate unavailable: \(Store.flat(validateOut.tail, max: 200))", severity: .warning))
        case let code?:
            if isUsageError(validateOut.tail) {
                out.issues.append(LintIssue(.claudeDetails, path: ".", message: "claude plugin validate unavailable (this CLI refuses the options): \(Store.flat(validateOut.tail, max: 200))",
                                            severity: .warning))
            } else {
                out.issues.append(LintIssue(.claudeValidate, path: ".", message: "claude plugin validate --strict failed (\(code)): \(Store.flat(validateOut.tail, max: 400))"))
            }
        }
        let detailsOut = await check.runner.run(command: claudeCommand(check.claudePath, ["--plugin-dir", copy.path, "plugin", "details", id]),
                                                cwd: check.scratch, environment: env, timeout: check.timeout,
                                                outputURL: check.scratch.appending(path: "details.log"), policy: policy)
        if detailsOut.exitCode == 0, let tokens = alwaysOnTokens(in: detailsOut.tail) {
            out.alwaysOnTokens = tokens
        } else {
            out.issues.append(LintIssue(.claudeDetails, path: ".", message: "always-on tokens unavailable (claude plugin details: \(Store.flat(detailsOut.tail, max: 200)))",
                                        severity: .warning))
        }
        return out
    }

    /// The directory of the resolved `claude` binary as the one readable policy entry, `[]` when it is `/`, or nil when reading it
    /// whole would reach the owner's home, an ancestor of it, or a protected path, or when `claudePath` is not absolute (N2: a
    /// bare or relative name would be judged against the current directory).
    static func readableClaudeDirectory(_ claudePath: String, userHome: URL) -> [URL]? {
        guard claudePath.hasPrefix("/") else { return nil }
        let dir = URL(fileURLWithPath: claudePath).resolvedForSandbox.deletingLastPathComponent()
        if dir.path == "/" { return [] }
        let home = userHome.resolvedForSandbox.path
        if dir.path == home || home.hasPrefix(dir.path + "/") { return nil }
        for protected in ProtectedPaths.defaults(userHome: userHome) where SandboxPath.overlaps(dir.path, protected.resolvedForSandbox.path) { return nil }
        return [dir]
    }

    static func isUsageError(_ tail: String) -> Bool {
        let lower = tail.lowercased()
        return lower.contains("unknown option") || lower.contains("unknown command") || lower.contains("too many arguments") || lower.contains("usage:")
    }

    /// Copies only the allowlisted parts (regular files, modes normalized): what Claude's checks see. Nested refused names are
    /// left out whatever their case.
    static func allowlistedCopy(of root: URL, to dest: URL, parts: ((String) -> Bool) = isAllowlistedForClaude) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for f in try PackageWalk.files(root: root) where f.kind == .regular {
            guard let top = f.relative.split(separator: "/").first.map(String.init), parts(top) else { continue }
            if f.relative.split(separator: "/").dropFirst().contains(where: { refusedNested.contains(String($0).lowercased()) }) { continue }
            let target = dest.appending(path: f.relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = fm.contents(atPath: f.url.path) else { throw ExtensionError.message("cannot read \(f.relative)") }
            let mode = f.relative.hasPrefix("bin/") ? 0o755 : 0o644
            try data.write(to: target)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
        }
    }

    static func alwaysOnTokens(in text: String) -> Int? {
        for pattern in [#"(?i)always[- ]on[^0-9\n]{0,60}?([0-9][0-9,]*)"#, #""alwaysOnTokens"\s*:\s*([0-9]+)"#, #"(?i)([0-9][0-9,]*)\s+tok(ens)?\b"#] {
            if let m = try? NSRegularExpression(pattern: pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text), let n = Int(text[r].replacingOccurrences(of: ",", with: "")) {
                return n
            }
        }
        return nil
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// `'<claude>' --setting-sources '' --strict-mcp-config --settings '{"disableAllHooks":true}' <rest…>`: the global hardening
    /// options come first (the `plugin` subcommands refuse them); paths and names are quoted, flags are not.
    static func claudeCommand(_ claude: String, _ rest: [String]) -> String {
        let hardening = ["--setting-sources", "''", "--strict-mcp-config", "--settings", shellQuote("{\"disableAllHooks\":true}")]
        let tail = rest.map { $0.hasPrefix("--") || ["plugin", "validate", "details"].contains($0) ? $0 : shellQuote($0) }
        return ([shellQuote(claude)] + hardening + tail).joined(separator: " ")
    }

    // MARK: Helpers

    static func text(of f: PackageFile) -> String? {
        guard f.size <= Int64(ExtensionLimits.maxScannedBytes), let data = FileManager.default.contents(atPath: f.url.path) else { return nil }
        if data.prefix(8192).contains(0) { return nil }
        return String(data: data, encoding: .utf8)
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

/// The strict YAML subset a plugin's frontmatter may use, between `---` fences at the very start of the file:
/// - every non-blank line at column 0 is `key: value` or `key:` with `key` matching `^[A-Za-z_][A-Za-z0-9_-]*$`;
/// - indented lines (spaces only) belong to the key above them (a map or a list) and never come before the first key;
/// - no tabs, no `? ` explicit keys, no flow mappings or sequences at the top (`{`, `[`), no anchors, aliases or tags
///   (`&`, `*`, `!`) at the start of a value, no `<<` merge keys, no `...`/`%` document markers, no duplicate keys;
/// - the input is normalized first (BOM stripped, CRLF/CR → LF), and the closing fence must appear within 64 KB.
/// Byte-wise (UTF-8) prefix, suffix and containment tests for the frontmatter parser: a `Character` comparison would let a
/// combining mark or emoji modifier merge into the ASCII it follows (`---\u{301}` is not `hasPrefix("---")`), while Claude Code
/// and YAML parsers read code units (N-1b).
extension StringProtocol {
    func bytePrefix(_ p: String) -> Bool { utf8.starts(with: p.utf8) }
    func byteSuffix(_ p: String) -> Bool { utf8.reversed().starts(with: p.utf8.reversed()) }
    func byteContains(_ p: String) -> Bool {
        let hay = Array(utf8), needle = Array(p.utf8)
        guard !needle.isEmpty, hay.count >= needle.count else { return needle.isEmpty }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return true }
        return false
    }
}

struct Frontmatter {
    struct Entry {
        var key: String
        var value: String
        var line: Int
        var continuation: [String]
        /// The full value as the engine parsed it (allowlisted keys only; `.raw` for keys that are refused or stripped, whose
        /// value is never written back).
        var parsed: Value = .raw
    }

    /// A parsed frontmatter value: what the validator checks and the only thing the canonical rewrite writes.
    indirect enum Value {
        case raw
        /// `plain`: written without quotes in the source (so YAML may read it as a bool or a number, and so does the rewrite).
        case scalar(String, plain: Bool)
        case list([String])
        case map([(key: String, value: Value)])

        var strings: [String] {
            switch self {
            case .raw: return []
            case .scalar(let s, _): return [s]
            case .list(let l): return l
            case .map(let m): return m.flatMap { [$0.key] + $0.value.strings }
            }
        }
    }

    struct Refusal: Error { var why: String; init(_ why: String) { self.why = why } }

    /// Keys whose value is a list (`a, b`, `[a, b]` or `- a` lines) and the one key that may hold a map.
    static let listKeys: Set<String> = ["tools", "disallowedTools", "skills"]
    static let mapKeys: Set<String> = ["metadata"]
    /// Keys parsed in full (everything the rewrite can write back).
    static var strictKeys: Set<String> { ExtensionValidator.skillKeys.union(ExtensionValidator.agentKeys) }
    var entries: [Entry]
    /// The line of the closing fence.
    var end: Int

    enum ParseResult {
        /// Not a frontmatter file (the first line is not a fence).
        case none
        case ok(Frontmatter)
        case invalid(String, line: Int?)
    }

    static let fenceLimit = 64 * 1024
    /// What ends a frontmatter for Claude Code wherever it appears.
    static let fenceMark = "---"

    /// Whether `s` holds `---` anywhere, by UTF-8 bytes (0x2D 0x2D 0x2D), whatever follows the dashes.
    static func hasFenceMark<S: StringProtocol>(_ s: S) -> Bool { s.byteContains(fenceMark) }
    static let keyPattern = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_-]*$")

    /// BOM stripped, CRLF and CR turned into LF.
    static func normalize(_ text: String) -> String {
        var t = text
        if t.bytePrefix("\u{FEFF}") { t.removeFirst() }
        return t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Whether the (normalized) text starts like a fence: `---` after optional blank space.
    static func looksFenced(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespaces) == "---" } ?? false
    }

    static func strictParse(_ normalized: String) -> ParseResult {
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return .none }
        guard first == "---" else {
            // A fence after leading blank space or blank lines is "fence-like" and refused; anything else is plain Markdown.
            if let fenceLike = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               lines[fenceLike].trimmingCharacters(in: .whitespaces).bytePrefix("---") {
                return .invalid("the opening fence must be exactly --- on the first line", line: fenceLike + 1)
            }
            return .none
        }
        var entries: [Entry] = []
        var seen: Set<String> = []
        var bytes = first.utf8.count + 1
        var i = 1
        while i < lines.count {
            let line = lines[i]
            let number = i + 1
            bytes += line.utf8.count + 1
            if bytes > fenceLimit { return .invalid("the frontmatter does not close within \(fenceLimit) bytes", line: number) }
            if line == "---" {
                for k in entries.indices where strictKeys.contains(entries[k].key) {
                    do {
                        entries[k].parsed = try parseValue(key: entries[k].key, inline: entries[k].value, continuation: entries[k].continuation)
                        if entries[k].parsed.strings.contains(where: { hasFenceMark($0) }) {
                            throw Refusal("'---' inside a value (Claude Code would end the frontmatter there)")
                        }
                    }
                    catch let r as Refusal { return .invalid("'\(entries[k].key)': \(r.why)", line: entries[k].line) }
                    catch { return .invalid("'\(entries[k].key)': \(error)", line: entries[k].line) }
                }
                return .ok(Frontmatter(entries: entries, end: number))
            }
            if line.trimmingCharacters(in: .whitespaces) == "---" { return .invalid("the closing fence must be exactly ---", line: number) }
            // N-1: Claude Code ends the frontmatter at the first `---` anywhere (mid-line, in quotes, in a comment), so the keys
            // after it would be checked here and never applied there.
            if hasFenceMark(line) { return .invalid("'---' inside the frontmatter (Claude Code would end it there)", line: number) }
            if line.byteContains("\t") { return .invalid("tabs are not allowed", line: number) }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !entries.isEmpty { entries[entries.count - 1].continuation.append("") }
                i += 1; continue
            }
            if line.bytePrefix("#") { i += 1; continue }
            if line.bytePrefix(" ") {
                guard let last = entries.last else { return .invalid("an indented line before the first key", line: number) }
                // A block scalar's (`|`, `>`) indented lines are literal text; anything else is checked like a value.
                let isBlockScalar = last.value.bytePrefix("|") || last.value.bytePrefix(">")
                if !isBlockScalar, let bad = badValueStart(line.trimmingCharacters(in: .whitespaces)) { return .invalid(bad, line: number) }
                entries[entries.count - 1].continuation.append(line)
                i += 1; continue
            }
            if line == "..." || line.bytePrefix("... ") || line.bytePrefix("%") { return .invalid("a YAML document marker inside the frontmatter", line: number) }
            if line.bytePrefix("?") || line.bytePrefix("{") || line.bytePrefix("[") || line.bytePrefix("-") || line.bytePrefix("<<") {
                return .invalid("explicit keys, flow collections, top-level lists and merge keys are not allowed", line: number)
            }
            guard let colon = line.firstIndex(of: ":") else { return .invalid("a line that is not `key: value`", line: number) }
            let key = String(line[..<colon])
            let after = line.index(after: colon)
            guard after == line.endIndex || line[after] == " " else { return .invalid("a line that is not `key: value`", line: number) }
            guard keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil else {
                return .invalid("key '\(Store.flat(key, max: 40))' is not a plain identifier", line: number)
            }
            guard seen.insert(key).inserted else { return .invalid("duplicate key '\(key)'", line: number) }
            let value = String(line[after...]).trimmingCharacters(in: .whitespaces)
            if let bad = badValueStart(value) { return .invalid(bad, line: number) }
            entries.append(Entry(key: key, value: value, line: number, continuation: []))
            i += 1
        }
        return .invalid("the frontmatter never closes", line: nil)
    }

    /// Anchors, aliases, tags and flow collections at the start of a value (or a list item) are refused.
    static func badValueStart(_ value: String) -> String? {
        var v = value
        if v.bytePrefix("- ") { v = String(v.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        else if let colon = v.firstIndex(of: ":"), !v.bytePrefix("\""), !v.bytePrefix("'"), !v.bytePrefix("["), !v.bytePrefix("{") {
            // a nested `key: value` line: check its value
            v = String(v[v.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        if v.bytePrefix("&") || v.bytePrefix("*") || v.bytePrefix("!") { return "anchors, aliases and tags are not allowed" }
        if v.bytePrefix("{") || v.bytePrefix("[") { return flowProblem(v) }
        return nil
    }

    /// A flow value (`[a, b]`, `{}`) is accepted only when it closes on its own line, nests no further flow collection, and
    /// holds no anchor, alias or tag at the start of any item (quoted text is skipped). Nil when it is clean.
    static func flowProblem(_ v: String) -> String? {
        var depth = 0, quote: Unicode.Scalar? = nil, tokenStart = true, closed = false
        for c in v.unicodeScalars {
            if closed { if c == " " { continue }; if c == "#" { break }; return "text after a flow collection is not allowed" }
            if let q = quote { if c == q { quote = nil }; continue }
            switch c {
            case "\"", "'": quote = c; tokenStart = false
            case "[", "{":
                depth += 1
                if depth > 1 { return "nested flow collections are not allowed" }
                tokenStart = true
            case "]", "}":
                depth -= 1
                if depth == 0 { closed = true }
            case ",", ":": tokenStart = true
            case " ": break
            case "&", "*", "!":
                if tokenStart { return "anchors, aliases and tags are not allowed" }
                tokenStart = false
            default: tokenStart = false
            }
        }
        if quote != nil || depth != 0 || !closed { return "a flow collection must close on its own line" }
        return nil
    }

    /// The scalars YAML double-quoted escapes would produce (`\uXXXX`, `\UXXXXXXXX`, `\xXX`, `\N`, `\_`, `\L`, `\P`), so a
    /// hidden character spelled as an escape is found too.
    static func escapedScalars(in line: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        let chars = Array(line.unicodeScalars)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\", i + 1 < chars.count else { i += 1; continue }
            let kind = chars[i + 1]
            let width: Int? = kind == "x" ? 2 : kind == "u" ? 4 : kind == "U" ? 8 : nil
            if let width {
                let hex = scalarString(chars[(i + 2)..<min(chars.count, i + 2 + width)])
                if hex.unicodeScalars.count == width, let n = UInt32(hex, radix: 16), let s = Unicode.Scalar(n) { out.append(s) }
                i += 2 + width
                continue
            }
            switch kind {
            case "N": out.append("\u{85}")
            case "_": out.append("\u{A0}")
            case "L": out.append("\u{2028}")
            case "P": out.append("\u{2029}")
            default: break
            }
            i += 2
        }
        return out
    }

    /// The parsed frontmatter when the (raw) text is a clean fence; nil otherwise (both "no fence" and "malformed").
    static func parse(_ text: String) -> Frontmatter? {
        if case .ok(let fm) = strictParse(normalize(text)) { return fm }
        return nil
    }

    /// The full (folded, unquoted, unescaped) scalar value of `key`; nil when absent or not a scalar.
    func value(_ key: String) -> String? {
        guard let e = entries.first(where: { $0.key == key }) else { return nil }
        switch e.parsed {
        case .scalar(let s, _): return s
        case .list, .map: return nil
        case .raw:
            let v = e.value
            if (v.bytePrefix("\"") && v.byteSuffix("\"") && v.count >= 2) || (v.bytePrefix("'") && v.byteSuffix("'") && v.count >= 2) {
                return String(v.dropFirst().dropLast())
            }
            return v
        }
    }

    /// Every element of a list key, in full (a comma string is split the way Claude Code splits it).
    func list(_ key: String) -> [String] {
        guard let e = entries.first(where: { $0.key == key }) else { return [] }
        switch e.parsed {
        case .list(let l): return l
        case .scalar(let s, _): return Frontmatter.commaList(s)
        case .map: return []
        case .raw:
            var items: [String] = []
            var inline = e.value
            if inline.bytePrefix("["), inline.byteSuffix("]") { inline = String(inline.dropFirst().dropLast()) }
            items += inline.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            for c in e.continuation {
                let t = c.trimmingCharacters(in: .whitespaces)
                if t.bytePrefix("- ") { items.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)) }
            }
            return items.filter { !$0.isEmpty }.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        }
    }

    static func commaList(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Values (the supported subset)

    /// The full value of an allowlisted key, as YAML would read it, within a small subset: one-line plain or quoted scalars, a
    /// plain scalar folded over indented lines, block scalars `|` `|-` `>` `>-`, lists (`a, b`, a one-line `[a, b]`, or `- a`
    /// lines under an empty value) for `listKeys`, and one level of `name: value` (values scalar or list) for `metadata`.
    /// Anything else throws.
    static func parseValue(key: String, inline v: String, continuation raw: [String]) throws -> Value {
        var cont = raw
        while let last = cont.last, last.trimmingCharacters(in: .whitespaces).isEmpty { cont.removeLast() }
        while let first = cont.first, first.trimmingCharacters(in: .whitespaces).isEmpty { cont.removeFirst() }
        let isBlock = v.bytePrefix("|") || v.bytePrefix(">")
        if mapKeys.contains(key) {
            if v.isEmpty { return .map(try nestedMap(cont)) }
            guard cont.isEmpty, v == "{}" else { throw Refusal("a map of names to text or lists, written as indented `name: value` lines") }
            return .map([])
        }
        if listKeys.contains(key) {
            guard !isBlock else { throw Refusal("a list, not a block scalar") }
            if v.isEmpty { return .list(try blockList(cont)) }
            guard cont.isEmpty else { throw Refusal("a list continues on the next line; write it on one line or as `- item` lines") }
            return .list(try inlineList(v))
        }
        if isBlock { return .scalar(try blockScalar(header: v, lines: raw), plain: false) }
        if cont.isEmpty { return try singleScalar(v) }
        // A plain scalar folded over indented lines (YAML joins them with spaces; a blank line is a newline).
        guard !v.isEmpty, case .scalar(let head, true) = try singleScalar(v) else {
            throw Refusal("a multi-line value is supported only as plain text or a block scalar (| or >)")
        }
        var lines: [String] = []
        for c in cont {
            let t = c.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { lines.append(""); continue }
            if let first = t.unicodeScalars.first, "-?:,[]{}#&*!|>'\"%@`".unicodeScalars.contains(first) {
                throw Refusal("a continuation line starts with '\(Character(first))'")
            }
            if t.byteContains(": ") || t.byteSuffix(":") || t.byteContains(" #") { throw Refusal("a continuation line looks like a key or a comment") }
            lines.append(t)
        }
        return .scalar(fold([head] + lines), plain: false)
    }

    /// YAML line folding: lines joined by a space; each blank line becomes a newline.
    static func fold(_ lines: [String]) -> String {
        var out = "", pending = 0, started = false
        for l in lines {
            if l.isEmpty { pending += 1; continue }
            if started { out += pending > 0 ? String(repeating: "\n", count: pending) : " " }
            out += l; started = true; pending = 0
        }
        return out
    }

    /// One-line scalar: empty, plain (a ` #` comment dropped), single-quoted or double-quoted (escapes decoded).
    static func singleScalar(_ v: String) throws -> Value {
        if v.isEmpty { return .scalar("", plain: true) }
        if v.bytePrefix("\"") { return .scalar(try doubleQuoted(v), plain: false) }
        if v.bytePrefix("'") { return .scalar(try singleQuoted(v), plain: false) }
        if v.bytePrefix("[") || v.bytePrefix("{") { throw Refusal("a list or map is not allowed here") }
        if let first = v.unicodeScalars.first, "@`%|>".unicodeScalars.contains(first) { throw Refusal("a value may not start with '\(Character(first))'") }
        var text = v
        if let r = text.range(of: " #") { text = String(text[..<r.lowerBound]) }
        return .scalar(text.trimmingCharacters(in: .whitespaces), plain: true)
    }

    static func singleQuoted(_ v: String) throws -> String {
        let chars = Array(v.unicodeScalars)
        var out = "", i = 1
        while i < chars.count {
            if chars[i] == "'" {
                if i + 1 < chars.count, chars[i + 1] == "'" { out.append("'"); i += 2; continue }
                try requireOnlyComment(chars[(i + 1)...])
                return out
            }
            out.unicodeScalars.append(chars[i]); i += 1
        }
        throw Refusal("a single-quoted value must close on its line")
    }

    static func doubleQuoted(_ v: String) throws -> String {
        let chars = Array(v.unicodeScalars)
        var out = "", i = 1
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { try requireOnlyComment(chars[(i + 1)...]); return out }
            if c != "\\" { out.unicodeScalars.append(c); i += 1; continue }
            guard i + 1 < chars.count else { break }
            let k = chars[i + 1]
            let simple: [Unicode.Scalar: String] = ["\\": "\\", "\"": "\"", "/": "/", "n": "\n", "t": "\t", "r": "\r", "0": "\0", "a": "\u{07}",
                                               "b": "\u{08}", "e": "\u{1B}", "f": "\u{0C}", "v": "\u{0B}", " ": " ", "N": "\u{85}",
                                               "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}"]
            if let s = simple[k] { out += s; i += 2; continue }
            let width: Int? = k == "x" ? 2 : k == "u" ? 4 : k == "U" ? 8 : nil
            guard let width, i + 2 + width <= chars.count, let n = UInt32(scalarString(chars[(i + 2)..<(i + 2 + width)]), radix: 16),
                  let scalar = Unicode.Scalar(n) else { throw Refusal("an unsupported escape in a double-quoted value") }
            out.unicodeScalars.append(scalar); i += 2 + width
        }
        throw Refusal("a double-quoted value must close on its line")
    }

    static func scalarString(_ s: ArraySlice<Unicode.Scalar>) -> String {
        var out = ""
        out.unicodeScalars.append(contentsOf: s)
        return out
    }

    static func requireOnlyComment(_ rest: ArraySlice<Unicode.Scalar>) throws {
        let t = scalarString(rest).trimmingCharacters(in: .whitespaces)
        guard t.isEmpty || t.bytePrefix("#") else { throw Refusal("text after a quoted value") }
    }

    /// `|`, `|-`, `>`, `>-`: the indented lines, the indentation of the first one removed (no line may have less); `>` folds.
    static func blockScalar(header: String, lines raw: [String]) throws -> String {
        let h = header.split(separator: " ", maxSplits: 1).first.map(String.init) ?? header
        guard ["|", "|-", ">", ">-"].contains(h) else { throw Refusal("block scalar header '\(Store.flat(h, max: 8))' is not supported (|, |-, > or >-)") }
        if header.count > h.count, !header.dropFirst(h.count).trimmingCharacters(in: .whitespaces).bytePrefix("#") { throw Refusal("text after a block scalar header") }
        var lines = raw
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let firstText = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return "" }
        let indent = firstText.prefix { $0 == " " }.count
        var content: [String] = []
        for l in lines {
            if l.trimmingCharacters(in: .whitespaces).isEmpty { content.append(""); continue }
            guard l.prefix(while: { $0 == " " }).count >= indent else { throw Refusal("a block scalar line is less indented than its first line") }
            content.append(String(l.dropFirst(indent)))
        }
        while content.first == "" { content.removeFirst() }
        var text: String
        if h.bytePrefix("|") {
            text = content.joined(separator: "\n")
        } else {
            guard !content.contains(where: { $0.bytePrefix(" ") }) else { throw Refusal("a folded (>) block with more-indented lines is not supported") }
            text = fold(content)
        }
        if !h.byteSuffix("-") { text += "\n" }
        return text
    }

    /// `- item` lines, all at one indentation, each a one-line plain or quoted scalar.
    static func blockList(_ lines: [String]) throws -> [String] {
        guard let first = lines.first else { return [] }
        let indent = first.prefix { $0 == " " }.count
        var out: [String] = []
        for l in lines {
            guard l.prefix(while: { $0 == " " }).count == indent else { throw Refusal("list items must share one indentation") }
            let t = String(l.dropFirst(indent))
            guard t.bytePrefix("- ") else { throw Refusal("a list holds only `- item` lines") }
            out.append(try listItem(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
        }
        return out
    }

    static func listItem(_ t: String) throws -> String {
        guard case .scalar(let s, let plain) = try singleScalar(t) else { throw Refusal("a list item must be text") }
        if plain, s.byteContains(": ") || s.byteSuffix(":") { throw Refusal("a list item may not be a map") }
        return s
    }

    /// `a, b`, `"a, b"` or a one-line `[a, "b"]`.
    static func inlineList(_ v: String) throws -> [String] {
        if v.bytePrefix("{") { throw Refusal("a list, not a map") }
        guard v.bytePrefix("[") else {
            guard case .scalar(let s, _) = try singleScalar(v) else { throw Refusal("a list") }
            return commaList(s)
        }
        let scalars = Array(v.unicodeScalars)
        guard let close = scalars.lastIndex(of: "]") else { throw Refusal("a flow list must close on its line") }
        try requireOnlyComment(scalars[(close + 1)...])
        var items: [String] = [], current = "", quote: Unicode.Scalar? = nil
        for c in scalars[1..<close] {
            if let q = quote { current.unicodeScalars.append(c); if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" { quote = c; current.unicodeScalars.append(c); continue }
            if c == "[" || c == "{" || c == "]" || c == "}" { throw Refusal("nested flow collections are not allowed") }
            if c == "," { items.append(current); current = ""; continue }
            current.unicodeScalars.append(c)
        }
        guard quote == nil else { throw Refusal("a quoted list item must close") }
        items.append(current)
        let trimmed = items.map { $0.trimmingCharacters(in: .whitespaces) }
        if trimmed == [""] { return [] }
        guard !trimmed.contains("") else { throw Refusal("an empty list item") }
        return try trimmed.map(listItem)
    }

    /// `metadata`: indented `name: value` lines at one indentation; a value is a one-line scalar or list, or `- item` lines
    /// indented under an empty value.
    static func nestedMap(_ lines: [String]) throws -> [(key: String, value: Value)] {
        guard let first = lines.first else { return [] }
        let indent = first.prefix { $0 == " " }.count
        var out: [(key: String, value: Value)] = []
        var seen: Set<String> = []
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if l.trimmingCharacters(in: .whitespaces).isEmpty { i += 1; continue }
            guard l.prefix(while: { $0 == " " }).count == indent else { throw Refusal("metadata holds one level of `name: value` lines") }
            let t = String(l.dropFirst(indent))
            guard let colon = t.firstIndex(of: ":") else { throw Refusal("a metadata line that is not `name: value`") }
            let k = String(t[..<colon])
            let after = t.index(after: colon)
            guard after == t.endIndex || t[after] == " ", keyPattern.firstMatch(in: k, range: NSRange(k.startIndex..., in: k)) != nil else {
                throw Refusal("a metadata line that is not `name: value`")
            }
            guard seen.insert(k).inserted else { throw Refusal("duplicate metadata key '\(k)'") }
            let v = String(t[after...]).trimmingCharacters(in: .whitespaces)
            var deeper: [String] = []
            i += 1
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty || lines[i].prefix(while: { $0 == " " }).count > indent {
                if !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { deeper.append(lines[i]) }
                i += 1
            }
            if v.isEmpty, !deeper.isEmpty { out.append((k, .list(try blockList(deeper)))); continue }
            guard deeper.isEmpty else { throw Refusal("metadata values are one line, or `- item` lines under an empty value") }
            out.append((k, v.bytePrefix("[") ? .list(try inlineList(v)) : try singleScalar(v)))
        }
        return out
    }

    // MARK: Canonical serialization

    /// Plain text the rewrite may leave unquoted (it reads back identically, typed as the source typed it).
    static let safePlain = try! NSRegularExpression(pattern: "^[A-Za-z0-9][A-Za-z0-9 _./@()+,'!?&*%=;-]*$")

    static func quoted(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if u.value < 0x20 || u.value == 0x7F { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func emitScalar(_ s: String, plain: Bool) -> String {
        if plain, s.isEmpty { return "" }
        if plain, !s.byteSuffix(" "), safePlain.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { return s }
        return quoted(s)
    }

    /// The engine's serialization of one entry: a one-line scalar, a one-line flow list, or (metadata) one level of such lines.
    static func emit(_ key: String, _ value: Value, indent: String = "") -> [String]? {
        switch value {
        case .raw: return nil
        case .scalar(let s, let plain):
            let v = emitScalar(s, plain: plain)
            return [v.isEmpty ? "\(indent)\(key):" : "\(indent)\(key): \(v)"]
        case .list(let items): return ["\(indent)\(key): [" + items.map(quoted).joined(separator: ", ") + "]"]
        case .map(let entries):
            if entries.isEmpty { return ["\(indent)\(key): {}"] }
            var out = ["\(indent)\(key):"]
            for e in entries { guard let lines = emit(e.key, e.value, indent: indent + "  ") else { return nil }; out += lines }
            return out
        }
    }

    /// The text without `key` (and its indented continuation lines); nil when the key is not there.
    static func strip(key: String, from text: String) -> String? {
        let normalized = normalize(text)
        guard let fm = parse(normalized), let e = fm.entries.first(where: { $0.key == key }) else { return nil }
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = e.line - 1
        var endIndex = start + 1
        while endIndex < lines.count, lines[endIndex].first == " " { endIndex += 1 }
        lines.removeSubrange(start..<endIndex)
        return lines.joined(separator: "\n")
    }

    /// The canonical form of a plugin-part file: normalized text; when it is fenced, a frontmatter holding only the `allowed`
    /// keys in the order written, each serialized by the engine from its parsed value (`emit`), the engine's fences, then the
    /// body with a final newline.
    /// Nil when the fence does not parse under the strict subset.
    static func canonical(_ text: String, allowed: Set<String>) -> String? {
        let normalized = normalize(text)
        var out: String
        switch strictParse(normalized) {
        case .invalid: return nil
        case .none: out = normalized
        case .ok(let fm):
            let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            out = "---\n"
            // Emitted from the parsed values only: no source line is ever copied into the frontmatter.
            for e in fm.entries where allowed.contains(e.key) {
                guard let emitted = emit(e.key, e.parsed) else { return nil }
                // The writer never emits a fence mark inside the body (N-1); a value that would need one is never written.
                guard !emitted.contains(where: { hasFenceMark($0) }) else {
                    assertionFailure("canonical frontmatter would hold '---'"); return nil
                }
                for l in emitted { out += l + "\n" }
            }
            out += "---\n"
            out += lines.dropFirst(fm.end).joined(separator: "\n")
        }
        if !out.byteSuffix("\n") { out += "\n" }
        return out
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

    static let assetsReference = regex(#"\$\{?CLAUDE_PLUGIN_ROOT\}?/assets(/|\b)"#)

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

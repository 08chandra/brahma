import ArgumentParser
import Foundation
import BrahmaCore

// `brahma ext` (Task 5a): the SDK part agents may run in their lab (`new`, `lint`) and the owner's lifecycle commands, every one
// of which files a PENDING `extension` ask the owner confirms in the app (`brahma approve` refuses extension asks). There is
// no `brahma plugin` alias.

struct ExtGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ext",
        abstract: "Extensions: skill-only Claude Code plugin folders, validated and mounted per role.",
        discussion: "Mutating commands file a pending ask; approve it in the app. `new` and `lint` need no owner key (agents run them in their lab).",
        subcommands: [ExtNew.self, ExtLint.self, ExtAdd.self, ExtImportClaude.self, ExtAddSkill.self, ExtList.self, ExtShow.self,
                      ExtBind.self, ExtUnbind.self, ExtRemove.self, ExtRollback.self])
}

/// `brahma ext new skill <id> [--dir <path>] [--bin]`: the embedded template, written straight to the directory.
struct ExtNew: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "new", abstract: "Write a new extension from the embedded template.")

    @Argument(help: "Template: skill.") var template: String
    @Argument(help: "The extension id (^[a-z][a-z0-9-]{0,39}$, never containing anthropic or claude).") var id: String
    @Option(help: "Where to write it (default: ./<id>).") var dir: String?
    @Flag(help: "Include an optional bin/<id>-tool helper.") var bin = false

    func run() throws {
        guard template == "skill" else { throw fail("the only template in this release is 'skill'") }
        let target = URL(fileURLWithPath: dir ?? FileManager.default.currentDirectoryPath + "/" + id, isDirectory: true)
        do { try ExtensionTemplates.write(id: id, to: target, withBin: bin) } catch let e as ExtensionError { throw fail(e.message) }
        print("wrote \(safe(target.path)) (lint it with: brahma ext lint \(safe(target.path)))")
    }
}

/// `brahma ext lint [path] [--fix] [--json] [--lock]`: the full validator on a staged copy; exit 0 clean, 1 errors, 2 warnings only.
struct ExtLint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lint", abstract: "Validate an extension folder (exit 0 clean, 1 errors, 2 warnings).")

    @Argument(help: "The extension folder (default: the current directory).") var path: String?
    @Flag(help: "Strip allowed-tools/model, prefix bin/ names, fix modes and regenerate ext.lock.json.") var fix = false
    @Flag(help: "Print the issues as JSON.") var json = false
    @Flag(help: "Regenerate ext.lock.json only.") var lock = false
    @Flag(name: .customLong("no-claude"), help: "Skip Claude's own plugin validate/details run.") var noClaude = false

    func run() async throws {
        let source = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir), isDir.boolValue else { throw fail("\(source.path) is not a directory") }
        let paths = BrahmaPaths.fromEnvironment()
        if lock || fix {
            // Nothing is written into a folder that holds a link (I5): the walk's EXT006 issues refuse both.
            let links = ExtensionValidator.validate(staged: source).issues.filter { $0.code == LintCode.linkRefused.rawValue }
            if !links.isEmpty {
                for i in links { FileHandle.standardError.write(Data("\(safe("ERROR  \(i.code)  \(i.path)  \(i.message)"))\n".utf8)) }
                throw fail("refusing to write into a folder that holds a link; remove it first")
            }
        }
        if lock {
            do { try ExtensionValidator.writeLock(root: source) } catch let e as ExtensionError { throw fail(e.message) }
            print("wrote \(safe(source.appending(path: ExtensionLock.path).path))")
            return
        }
        if fix {
            // Fixes apply to the folder itself; the lock is written last from the fixed tree.
            let before = ExtensionValidator.validate(staged: source)
            let done: [String]
            do { done = try ExtensionValidator.fix(staged: source, result: before) } catch let e as ExtensionError { throw fail(e.message) }
            if !ExtensionValidator.validate(staged: source).errors.isEmpty || !FileManager.default.fileExists(atPath: source.appending(path: ExtensionLock.path).path) {
                try? ExtensionValidator.writeLock(root: source)
            }
            for d in done { FileHandle.standardError.write(Data("fixed: \(safe(d))\n".utf8)) }
        }
        // A staged copy (never the folder itself) is what the validator and Claude's checks see.
        let scratchRoot: URL
        if let home = try? paths.ensureTmpDir() { scratchRoot = home } else { scratchRoot = FileManager.default.temporaryDirectory }
        let scratch = scratchRoot.appending(path: "ext-lint-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let staged = scratch.appending(path: "staged", directoryHint: .isDirectory)
        do { try ExtensionImporter.copyTree(from: source, to: staged) } catch let e as ExtensionError { throw fail(e.message) }
        var result = ExtensionValidator.validate(staged: staged)
        // I1: Claude's own checks run only on a package the validator passed.
        if !noClaude, let claude = Self.claudePath(), result.errors.isEmpty, result.manifest != nil {
            let runner: any SandboxedRunner
            if let (store, p) = try? openStore(lazySecrets: true) { runner = Orchestrator.ownerSandboxRunner(store: store, paths: p) }
            else { runner = UnavailableSandboxRunner() }
            let checks = await ExtensionValidator.claudeChecks(staged: staged, check: ClaudeCheck(runner: runner, claudePath: claude,
                                                                                                  scratch: scratch.appending(path: "claude")))
            result.issues += checks.issues
            result.issues.sort()
        } else if !noClaude, !json {
            FileHandle.standardError.write(Data("note: claude not found on PATH; Claude's own plugin checks were skipped\n".utf8))
        }
        if json {
            let rows: [[String: Any]] = result.issues.map {
                ["code": $0.code, "path": $0.path, "line": $0.line as Any? ?? NSNull(), "message": $0.message, "fix": $0.fix as Any? ?? NSNull()]
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(rows.isEmpty ? "[]" : String(decoding: data, as: UTF8.self))
        } else {
            for i in result.issues {
                let where_ = i.path + (i.line.map { ":\($0)" } ?? "")
                print(safe("\(i.severity == .error ? "ERROR" : "WARN ")  \(i.code)  \(where_)  \(i.message)" + (i.fix.map { "  (fix: \($0))" } ?? "")))
            }
            if result.issues.isEmpty { print("clean: \(safe(result.manifest?.name ?? "?")) \(safe(result.manifest?.version ?? ""))") }
        }
        if !result.errors.isEmpty { throw ExitCode(1) }
        if !result.warnings.isEmpty { throw ExitCode(2) }
    }

    /// `claude` as the owner's shell would find it (`BRAHMA_CLAUDE` overrides, for tests and unusual installs).
    static func claudePath() -> String? {
        if let p = ProcessInfo.processInfo.environment["BRAHMA_CLAUDE"] { return FileManager.default.isExecutableFile(atPath: p) ? p : nil }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/claude"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

// MARK: Owner lifecycle commands (each files a pending ask)

/// Stages, validates and files the install ask; prints `A-<n> pending`.
private func proposeInstall(source: ExtensionSource, company: String, roles: [String]) async throws {
    try requireOwnerShell()
    let (store, paths) = try openStore()
    let c = try resolveCompany(store, company)
    let staged: StagedExtension
    do {
        staged = try await ExtensionImporter.stage(source: source, paths: paths, sandbox: Orchestrator.ownerSandboxRunner(store: store, paths: paths))
    } catch let e as ExtensionError { throw fail(e.message) }
    for n in staged.notices { FileHandle.standardError.write(Data("note: \(safe(n))\n".utf8)) }
    var claude: ClaudeCheck?
    if let path = ExtLint.claudePath() {
        claude = ClaudeCheck(runner: Orchestrator.ownerSandboxRunner(store: store, paths: paths), claudePath: path,
                             scratch: try paths.ensureTmpDir().appending(path: "ext-check-\(UUID().uuidString)", directoryHint: .isDirectory))
    } else {
        FileHandle.standardError.write(Data("note: claude not found on PATH; Claude's own plugin checks were skipped\n".utf8))
    }
    defer { if let s = claude?.scratch { try? FileManager.default.removeItem(at: s) } }
    do {
        let ask = try await ExtensionLibrary.propose(staged: staged, store: store, paths: paths, companyId: c.id, requester: .system, roles: roles, claude: claude)
        print(safe("\(ask.ref) pending: install \(staged.id) for \(roles.isEmpty ? "no role yet" : roles.joined(separator: ", ")); approve it in the app"))
    } catch let e as ExtensionError {
        try? FileManager.default.removeItem(at: staged.dir)
        throw fail("refused:\n" + e.message)
    } catch let e as WorkError {
        try? FileManager.default.removeItem(at: staged.dir)
        throw fail(e.message)
    }
}

/// Files a non-install extension ask (remove, rollback, bind, unbind) for the owner to confirm in the app.
private func proposeAction(_ action: String, company: String, id: String, role: String? = nil) throws {
    try requireOwnerShell()
    let (store, _) = try openStore()
    let c = try resolveCompany(store, company)
    guard let installed = try store.installedExtensions(companyId: c.id).first(where: { $0.id == id }) else { throw fail("no extension '\(id)' in \(c.name)") }
    guard let package = try store.extensionPackage(hash: installed.hash) else { throw fail("no package record for \(id)") }
    if let role, role.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) == nil { throw fail("'\(role)' is not a role id") }
    let payload = ExtensionAskPayload(action: action, extId: id, hash: installed.hash, publisher: package.publisher, roles: role.map { [$0] } ?? [],
                                      notices: [], lintSummary: [], executes: package.lintFacts?.executes ?? .init(), alwaysOnTokens: nil,
                                      stagedPath: nil, role: role)
    let encoded = try JSONEncoder().encode(payload)
    let title = "\(action.capitalized) extension \(id)" + (role.map { " for \($0)" } ?? "")
    let ask: Ask
    do {
        ask = try store.propose(companyId: c.id, by: .system, kind: .extension, risk: .high, category: "prompt-change", title: title,
                                summary: "Owner CLI: brahma ext \(action) \(c.slug) \(id)" + (role.map { " --role \($0)" } ?? ""),
                                payload: AskPayload(details: String(decoding: encoded, as: UTF8.self), proposal: "\(action) \(id)"),
                                subjectId: "ext:\(id)", decisionClass: .goalChanging, viaOwner: true)
    } catch let e as WorkError { throw fail(e.message) }
    print(safe("\(ask.ref) pending: \(action) \(id); approve it in the app"))
}

struct ExtAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Install an extension from a folder or .zip (a pending ask).")
    @Argument(help: "A plugin folder or a .zip of one.") var source: String
    @Argument(help: "Company name or slug.") var company: String
    @Option(help: "Roles to bind it to, comma-separated (ticked on the card).") var roles: String = ""

    func run() async throws {
        let url = URL(fileURLWithPath: source)
        let src: ExtensionSource = source.lowercased().hasSuffix(".zip") ? .zip(url) : .folder(url)
        try await proposeInstall(source: src, company: company, roles: roles.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

struct ExtImportClaude: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import-claude", abstract: "Import a plugin from your Claude Code's plugin cache (a pending ask).")
    @Argument(help: "<marketplace>/<plugin>, as ~/.claude/plugins/cache names it.") var plugin: String
    @Argument(help: "Company name or slug.") var company: String
    @Option(help: "Roles to bind it to, comma-separated.") var roles: String = ""

    func run() async throws {
        let parts = plugin.split(separator: "/").map(String.init)
        guard parts.count == 2 else { throw fail("name the plugin as <marketplace>/<plugin>") }
        try await proposeInstall(source: .claudeCodeInstalled(marketplace: parts[0], plugin: parts[1]), company: company,
                                 roles: roles.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

struct ExtAddSkill: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-skill", abstract: "Install a bare SKILL.md folder as an extension (a pending ask).")
    @Argument(help: "A folder holding SKILL.md.") var folder: String
    @Argument(help: "Company name or slug.") var company: String
    @Option(help: "Roles to bind it to, comma-separated.") var roles: String = ""

    func run() async throws {
        try await proposeInstall(source: .bareSkill(URL(fileURLWithPath: folder, isDirectory: true)), company: company,
                                 roles: roles.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

struct ExtList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The company's installed extensions and pending extension asks.")
    @Argument(help: "Company name or slug.") var company: String

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let installed = try store.installedExtensions(companyId: c.id)
        let bindings = try store.extensionBindings(companyId: c.id)
        if installed.isEmpty { print(safe("\(c.name): no extensions installed")) }
        for e in installed {
            let p = try store.extensionPackage(hash: e.hash)
            let roles = bindings.filter { $0.id == e.id && $0.op == "add" && $0.scope == "role" }.map(\.target)
            let removed = bindings.filter { $0.id == e.id && $0.op == "remove" }.map { "\($0.scope) \($0.target)" }
            print(safe("\(e.id)  \(p?.version ?? "?")  \(p?.publisher ?? "?")  \(e.hash.prefix(12))  \(e.enabled ? "enabled" : "disabled")  "
                       + "roles: \(roles.isEmpty ? "(none)" : roles.joined(separator: ", "))" + (removed.isEmpty ? "" : "  removed for: \(removed.joined(separator: ", "))")))
        }
        let pending = try store.asks(companyId: c.id, statuses: [.pendingInternal, .pendingOwner]).filter { $0.kind == .extension }
        for a in pending {
            let p = ExtensionAskPayload.read(a)
            print(safe("\(a.ref)  pending  \(p?.action ?? "?") \(p?.extId ?? "?")  (approve in the app)"))
        }
    }
}

struct ExtShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "One installed extension: its package facts, bindings and events.")
    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "Extension id.") var id: String

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        guard let e = try store.installedExtensions(companyId: c.id).first(where: { $0.id == id }) else { throw fail("no extension '\(id)' in \(c.name)") }
        let p = try store.extensionPackage(hash: e.hash)
        print(safe("\(e.id) \(p?.version ?? "?")"))
        print(safe("  publisher: \(p?.publisher ?? "?")  source: \(p?.sourceType ?? "?") \(p?.sourceUrl ?? "")"))
        print(safe("  tree: \(e.hash)"))
        if let f = p?.lintFacts {
            print(safe("  parts: \(f.parts.joined(separator: ", "))  skills: \(f.skills.joined(separator: ", "))  commands: \(f.commands.joined(separator: ", "))  agents: \(f.agents.joined(separator: ", "))"))
            print(safe("  executes: bin \(f.executes.bin), scripts \(f.executes.scripts), ! injection \(f.executes.bangInjection); always-on tokens \(f.alwaysOnTokens)"))
            if !f.hosts.isEmpty { print(safe("  hosts: \(f.hosts.joined(separator: ", "))")) }
        }
        for n in p?.notices ?? [] { print(safe("  note: \(n)")) }
        for b in try store.extensionBindings(companyId: c.id).filter({ $0.id == id }) { print(safe("  binding: \(b.op) \(b.scope) \(b.target)")) }
        for ev in try store.extensionEvents(companyId: c.id, extId: id).suffix(20) { print(safe("  \(ev.kind)  \(ev.detail ?? "")")) }
    }
}

struct ExtBind: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bind", abstract: "Bind an installed extension to a role (a pending ask).")
    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "Extension id.") var id: String
    @Option(help: "The role.") var role: String
    func run() throws { try proposeAction("bind", company: company, id: id, role: role) }
}

struct ExtUnbind: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "unbind", abstract: "Unbind an extension from a role (a pending ask).")
    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "Extension id.") var id: String
    @Option(help: "The role.") var role: String
    func run() throws { try proposeAction("unbind", company: company, id: id, role: role) }
}

struct ExtRemove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove an installed extension (a pending ask).")
    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "Extension id.") var id: String
    func run() throws { try proposeAction("remove", company: company, id: id) }
}

struct ExtRollback: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rollback", abstract: "Roll an extension back to its previous approved version (a pending ask).")
    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "Extension id.") var id: String
    func run() throws { try proposeAction("rollback", company: company, id: id) }
}

import Foundation
import GRDB

// The install pipeline and the per-role mounts (Task 5a): validate → one pending `extension` ask (owner-only under every
// preset) → materialize read-only (the whole tree in the data home, the plugin parts in the workspace) → bind. Mounts come
// from `RoleBundle.effective`, every mounted tree is rehashed, and the mount set is frozen per Claude session.

/// The ask's `payload.details`: the exact action the owner approves.
public struct ExtensionAskPayload: Codable, Equatable, Sendable {
    public var action: String
    public var extId: String
    public var hash: String
    public var publisher: String
    public var roles: [String]
    public var notices: [String]
    public var lintSummary: [String]
    public var executes: LintFacts.Executes
    public var alwaysOnTokens: Int?
    /// Where the staged tree waits for the owner's decision (install only).
    public var stagedPath: String?
    /// `bind`/`unbind`: the role.
    public var role: String?
    /// The fetch path (install only): copied onto the company's row at approve (B-I1).
    public var sourceType: String? = nil
    public var sourceUrl: String? = nil
    public var sourceSha: String? = nil
    /// A lab proposal (10b): the lab commits that touched the folder and are recorded tainted, or not recorded at all. Any
    /// makes the installed extension third-party for taint and profile purposes (`sourceType` `lab-tainted`).
    public var taintedCommits: [String]? = nil
    /// A lab proposal from a lab with the sticky mark (10b, I2): the mark's first source and date, as shown on the card.
    public var labMark: String? = nil

    public init(action: String, extId: String, hash: String, publisher: String, roles: [String], notices: [String], lintSummary: [String],
                executes: LintFacts.Executes, alwaysOnTokens: Int?, stagedPath: String?, role: String? = nil,
                sourceType: String? = nil, sourceUrl: String? = nil, sourceSha: String? = nil, taintedCommits: [String]? = nil,
                labMark: String? = nil) {
        self.action = action; self.extId = extId; self.hash = hash; self.publisher = publisher; self.roles = roles; self.notices = notices
        self.lintSummary = lintSummary; self.executes = executes; self.alwaysOnTokens = alwaysOnTokens; self.stagedPath = stagedPath; self.role = role
        self.sourceType = sourceType; self.sourceUrl = sourceUrl; self.sourceSha = sourceSha; self.taintedCommits = taintedCommits
        self.labMark = labMark
    }

    public static func read(_ ask: Ask) -> ExtensionAskPayload? {
        guard ask.kind == .extension, let text = ask.payload?.details else { return nil }
        return try? JSONDecoder().decode(ExtensionAskPayload.self, from: Data(text.utf8))
    }

    func json() -> String { String(decoding: ExtensionJSON.encode(self), as: UTF8.self) }
}

/// One mounted extension: the plugin dir the compiler emits as `--plugin-dir`, and the egress its sidecar asks for.
public struct ExtensionMount: Equatable, Sendable {
    public var id: String
    public var hash: String
    public var url: URL
    public var publisher: String
    public var agentNetwork: [String]
}

public enum ExtensionLibrary {
    public static let cliApproveRefusal = "approve extensions in the app"
    /// The top-level entries copied into the workspace and mounted.
    static let workspaceParts: Set<String> = [".claude-plugin", "skills", "commands", "agents", "bin"]
    static let reviewDir = ".brahma/ext-review"

    // MARK: Propose

    /// How a proposal is filed (10b): the owner's CLI files straight to the owner; an agent's lab proposal goes to the pack's
    /// internal reviewer first, carries the agent's summary and item, lists its tainted commits, and needs a clean lint.
    public struct ProposalOptions: Sendable {
        /// Skip the internal step (the owner's own CLI and the app).
        public var viaOwner: Bool
        /// The ask's summary (nil: the manifest description).
        public var summary: String?
        public var itemId: String?
        public var taintedCommits: [String]?
        /// The lab's sticky mark, when it has one (I2).
        public var labMark: String?
        /// Any lint issue refuses, warnings included (an agent's proposal: `ext lint` must print `[]`).
        public var requireClean: Bool

        public init(viaOwner: Bool = true, summary: String? = nil, itemId: String? = nil, taintedCommits: [String]? = nil,
                    labMark: String? = nil, requireClean: Bool = false) {
            self.viaOwner = viaOwner; self.summary = summary; self.itemId = itemId; self.taintedCommits = taintedCommits
            self.labMark = labMark; self.requireClean = requireClean
        }
    }

    /// Validates the staged package (Claude's own checks included when `claude` is given) and files ONE pending ask the owner
    /// decides in the app. Errors refuse with the lint list; nothing is installed or mounted before approval.
    @discardableResult
    public static func propose(staged: StagedExtension, store: Store, paths: BrahmaPaths, companyId: String, requester: Sender,
                               roles: [String], claude: ClaudeCheck? = nil, options: ProposalOptions = ProposalOptions(),
                               now: Date = Store.now()) async throws -> Ask {
        var prepared = try prepare(staged: staged, store: store, paths: paths, companyId: companyId, options: options)
        if let claude {
            // I1: Claude's own checks run only on a package the validator passed.
            let checks = await ExtensionValidator.claudeChecks(staged: staged.dir, check: claude)
            prepared.result.issues += checks.issues
            prepared.result.issues.sort()
            prepared.alwaysOn = checks.alwaysOnTokens
            guard prepared.result.errors.isEmpty else { throw ExtensionError(issues: prepared.result.errors) }
            if options.requireClean, !prepared.result.issues.isEmpty { throw ExtensionError(issues: prepared.result.issues) }
        }
        return try file(prepared, staged: staged, store: store, companyId: companyId, requester: requester, roles: roles,
                        options: options, now: now)
    }

    /// The same without Claude's own checks, synchronously: an agent's `propose_extension` (its MCP server is synchronous).
    @discardableResult
    public static func proposeSync(staged: StagedExtension, store: Store, paths: BrahmaPaths, companyId: String, requester: Sender,
                                   roles: [String], options: ProposalOptions, now: Date = Store.now()) throws -> Ask {
        let prepared = try prepare(staged: staged, store: store, paths: paths, companyId: companyId, options: options)
        return try file(prepared, staged: staged, store: store, companyId: companyId, requester: requester, roles: roles,
                        options: options, now: now)
    }

    struct Prepared {
        var company: Company
        var result: ValidationResult
        var manifest: ExtensionManifest
        var alwaysOn: Int?
    }

    /// Validation, the canonical rewrite (S9) and validation again.
    static func prepare(staged: StagedExtension, store: Store, paths: BrahmaPaths, companyId: String,
                        options: ProposalOptions) throws -> Prepared {
        guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
        let validation = ValidationOptions(installedBins: try store.installedBins(companyId: companyId, paths: paths))
        let first = ExtensionValidator.validate(staged: staged.dir, options: validation)
        guard first.errors.isEmpty, first.manifest != nil else { throw ExtensionError(issues: first.errors) }
        if options.requireClean, !first.issues.isEmpty { throw ExtensionError(issues: first.issues) }
        // Brahma's own ids are never anyone else's (10b).
        if let id = first.manifest?.name, BuiltinExtensions.ids.contains(id) {
            throw ExtensionError.message("'\(id)' is Brahma's own extension id; choose another")
        }
        // S9: every plugin-part Markdown file is rewritten in canonical form (allowlisted keys only, LF, no BOM) BEFORE hashing,
        // so the lock, the hash, the review page and the mounted copy all describe exactly what Claude Code will read.
        // A lock the first validation verified describes the source bytes; after the engine's own rewrite it is regenerated so
        // it describes the canonical tree (the second validation checks it again).
        if try ExtensionValidator.canonicalize(staged: staged.dir),
           FileManager.default.fileExists(atPath: staged.dir.appending(path: ExtensionLock.path).path) {
            try ExtensionValidator.writeLock(root: staged.dir)
        }
        let result = ExtensionValidator.validate(staged: staged.dir, options: validation)
        guard result.errors.isEmpty, let manifest = result.manifest else { throw ExtensionError(issues: result.errors) }
        return Prepared(company: company, result: result, manifest: manifest, alwaysOn: nil)
    }

    /// Records the package, writes the review page and files the ask (one write).
    static func file(_ prepared: Prepared, staged: StagedExtension, store: Store, companyId: String, requester: Sender, roles: [String],
                     options: ProposalOptions, now: Date) throws -> Ask {
        let (company, result, manifest, alwaysOn) = (prepared.company, prepared.result, prepared.manifest, prepared.alwaysOn)
        let id = manifest.name
        for role in roles where role.range(of: "^[a-z][a-z0-9-]{0,31}$", options: .regularExpression) == nil {
            throw ExtensionError.message("'\(Store.flat(role, max: 40))' is not a role id")
        }
        // One open install per id; the same tree is never installed twice.
        let openAsks: [Ask] = try store.asks(companyId: companyId, statuses: [.pendingInternal, .pendingOwner]).filter { $0.kind == .extension }
        for ask in openAsks {
            guard let p = ExtensionAskPayload.read(ask), p.extId == id, p.action == "install" else { continue }
            throw ExtensionError.message("an install of '\(id)' is already pending (\(ask.ref)); decide it in the app first")
        }
        try ExtensionValidator.writeLock(root: staged.dir, alwaysOnTokens: alwaysOn)
        let treeHash = try ExtensionLock.treeHash(root: staged.dir)
        let pluginHash = try pluginTreeHash(root: staged.dir)
        if let have = try store.installedExtensions(companyId: companyId).first(where: { $0.id == id }), have.hash == treeHash {
            throw ExtensionError.message("'\(id)' is already installed at this exact version")
        }
        var facts = result.lintFacts
        if let alwaysOn { facts.alwaysOnTokens = alwaysOn }
        let package = ExtensionPackage(hash: treeHash, id: id, version: manifest.version, publisher: staged.source.publisher,
                                       sourceType: staged.source.sourceType, sourceUrl: staged.source.sourceUrl, sourceSha: staged.source.sourceSha,
                                       treeSha256: treeHash, pluginTreeSha256: pluginHash, fetchedAt: now,
                                       lintFactsJSON: String(decoding: ExtensionJSON.encode(facts), as: UTF8.self),
                                       noticesJSON: String(decoding: ExtensionJSON.encode(staged.notices), as: UTF8.self),
                                       sidecarJSON: result.sidecar.map { String(decoding: ExtensionJSON.encode($0), as: UTF8.self) })
        let payload = ExtensionAskPayload(action: "install", extId: id, hash: treeHash, publisher: staged.source.publisher, roles: roles,
                                          notices: staged.notices, lintSummary: result.warnings.map { "\($0.code) \($0.path): \($0.message)" },
                                          executes: facts.executes, alwaysOnTokens: alwaysOn, stagedPath: staged.dir.path,
                                          sourceType: staged.source.sourceType, sourceUrl: staged.source.sourceUrl, sourceSha: staged.source.sourceSha,
                                          taintedCommits: options.taintedCommits, labMark: options.labMark)
        let page = try reviewPage(staged: staged, manifest: manifest, result: result, payload: payload)
        let sender: Sender = { if case .owner = requester { return .system } else { return requester } }()
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        // A synchronous closure, so the write is GRDB's blocking one (this function is async).
        let file: () throws -> Ask = { try store.writer.write { db in
            // Insert-only (B-I1): the shared row keeps its first fetch facts; each company's view lives on its own row at approve.
            if try ExtensionPackage.fetchOne(db, key: treeHash) == nil { try package.insert(db) }
            // The review page is named after the ask it belongs to, so the number is taken inside the write.
            // (Ruling 50: the number `propose` takes from the ask counter below, previewed; checked equal after it.)
            let number = try Store.peekAskNumber(db: db, companyId: companyId)
            _ = try EngineFiles.directory(workspace: workspace, reviewDir)
            _ = try EngineFiles.replace(Data(page.utf8), workspace: workspace, dir: reviewDir, name: "A-\(number).md")
            let document = try Store.readDocument("\(reviewDir)/A-\(number).md", workspace: company.workspacePath)
            let ask = try store.propose(db: db, companyId: companyId, by: sender, kind: .extension, risk: .high, category: "prompt-change",
                                        title: "Install extension \(id) \(manifest.version)",
                                        summary: Store.flat(options.summary ?? manifest.description, max: Store.maxAskText),
                                        payload: AskPayload(documentPath: "\(reviewDir)/A-\(number).md", details: payload.json(),
                                                            proposal: "install \(id)@\(treeHash.prefix(12)) for \(roles.isEmpty ? "no role yet" : roles.joined(separator: ", "))"),
                                        document: document, itemId: options.itemId, subjectId: "ext:\(id)", supersedes: nil, requestId: nil,
                                        decisionClass: .goalChanging, viaOwner: options.viaOwner, now: now)
            guard ask.number == number else { throw WorkError.conflict("another ask was filed meanwhile; try again") }
            try Store.recordExtensionEvent(db, companyId: companyId, extId: id, kind: "staged", detail: "\(ask.ref) \(treeHash.prefix(12)) from \(staged.source.sourceType)", now: now)
            return ask
        } }
        return try file()
    }

    /// The tree hash of the plugin parts alone (what the workspace copy holds).
    static func pluginTreeHash(root: URL) throws -> String {
        let entries = try ExtensionLock.entries(root: root).filter { e in
            guard let top = e.path.split(separator: "/").first.map(String.init) else { return false }
            return workspaceParts.contains(top)
        }
        return ExtensionLock.treeHash(entries: entries)
    }

    /// The owner's review page: the facts, the notices, the lint flags, and every skill, command and agent verbatim (quoted).
    static func reviewPage(staged: StagedExtension, manifest: ExtensionManifest, result: ValidationResult, payload: ExtensionAskPayload) throws -> String {
        var out = "# Extension install: \(manifest.name) \(manifest.version)\n\n"
        out += "- publisher: \(staged.source.publisher) (set by Brahma from the source, never by the package)\n"
        out += "- source: \(staged.source.sourceType) \(staged.source.sourceUrl ?? "")\n"
        out += "- tree hash: \(payload.hash)\n"
        if let tainted = payload.taintedCommits {
            // 10b: a lab proposal says exactly what was checked (I2): the lab's sticky mark, then the commits that introduced its
            // files or touched its folder.
            if let mark = payload.labMark {
                out += "- lab provenance: a session that read outside content has worked in this lab (\(Store.flat(mark, max: 200))); until "
                    + "the owner clears the mark, everything proposed from it is treated as third-party (Sandboxed only; its skills taint)\n"
            } else if tainted.isEmpty {
                out += "- lab provenance: no tainted session has worked in this lab since the owner last cleared it, and no tainted or "
                    + "unrecorded commit introduced its files or touched its folder (commit content is not traced beyond object ids)\n"
            }
            if !tainted.isEmpty {
                out += "- tainted commits: \(tainted.map { Store.flat($0, max: 64) }.joined(separator: ", ")) (tainted or unrecorded commits "
                    + "that introduced its files or touched its folder): if approved it is treated as third-party (Sandboxed only; its "
                    + "skills taint)\n"
            }
        }
        out += "- roles: \(payload.roles.isEmpty ? "(none)" : payload.roles.joined(separator: ", "))\n"
        out += "- description: \(Store.flat(manifest.description, max: ExtensionLimits.maxDescription))\n"
        out += "- executes: bin \(payload.executes.bin), scripts \(payload.executes.scripts), ! injection \(payload.executes.bangInjection)\n"
        out += "- always-on tokens: \(payload.alwaysOnTokens.map(String.init) ?? "unavailable")\n"
        out += "- hosts referenced: \(result.lintFacts.hosts.isEmpty ? "(none)" : result.lintFacts.hosts.joined(separator: ", "))\n"
        if let s = result.sidecar {
            if !s.agentNetwork.isEmpty { out += "- agent egress asked for: \(s.agentNetwork.joined(separator: ", ")) (roles that mount it only)\n" }
            if !s.hostTools.isEmpty { out += "- host tools required: \(s.hostTools.joined(separator: ", "))\n" }
        }
        if !payload.notices.isEmpty {
            out += "\n## Import notices\n\n" + payload.notices.map { "- \(Store.flat($0, max: 400))" }.joined(separator: "\n") + "\n"
        }
        if !payload.lintSummary.isEmpty {
            out += "\n## Lint flags\n\n" + payload.lintSummary.map { "- \(Store.flat($0, max: 400))" }.joined(separator: "\n") + "\n"
        }
        for part in ["skills", "commands", "agents"] {
            let files = try PackageWalk.files(root: staged.dir).filter { $0.relative.hasPrefix(part + "/") && $0.relative.hasSuffix(".md") && $0.kind == .regular }
            guard !files.isEmpty else { continue }
            out += "\n## \(part)\n"
            for f in files {
                let text = (try? String(contentsOf: f.url, encoding: .utf8)) ?? "(not UTF-8)"
                out += "\n### \(f.relative)\n\n"
                out += text.split(separator: "\n", omittingEmptySubsequences: false).map { "    | " + Store.stripControls(String($0)) }.joined(separator: "\n") + "\n"
            }
        }
        return out
    }

    // MARK: Approve and decline

    /// The owner approves in the app: the action in the ask's payload is carried out, then the ask is approved (one write). For
    /// an install: the verified tree goes read-only into `<home>/extensions/store/<id>/<hash12>/`, the plugin parts into
    /// `<ws>/.brahma/ext/<id>/<hash12>/plugin/` (not in any turn's allowWrite), the rows are written, the staging dir removed.
    /// `roles` replaces the roles ticked on the card (nil: the proposal's).
    public static func approve(askId: String, roles: [String]?, store: Store, paths: BrahmaPaths, now: Date = Store.now()) throws {
        guard let ask = try store.ask(id: askId) else { throw WorkError.notFound("no such ask") }
        guard ask.kind == .extension, let payload = ExtensionAskPayload.read(ask) else { throw WorkError.invalid("\(ask.ref) is not an extension ask") }
        guard ask.status.isPending else { throw WorkError.conflict("\(ask.ref) is already \(ask.status.rawValue)") }
        guard let company = try store.company(id: ask.companyId) else { throw WorkError.notFound("no such company") }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let id = payload.extId
        switch payload.action {
        case "install":
            guard let stagedPath = payload.stagedPath, SandboxPath.kind(stagedPath) == .directory else {
                throw WorkError.conflict("\(ask.ref): the staged package is gone; propose it again")
            }
            let staged = URL(fileURLWithPath: stagedPath, isDirectory: true)
            guard staged.standardizedFileURL.path.hasPrefix(paths.extensionsDir.staging.standardizedFileURL.path + "/") else {
                throw WorkError.invalid("\(ask.ref): the staged path is not under the staging area")
            }
            let hash = try ExtensionLock.treeHash(root: staged)
            guard hash == payload.hash else {
                try store.recordExtensionEvent(companyId: company.id, extId: id, kind: "tamper", detail: "staged tree changed before approval", now: now)
                throw WorkError.conflict("\(ask.ref): the staged package changed since it was proposed; it was not installed")
            }
            guard let package = try store.extensionPackage(hash: hash) else { throw WorkError.conflict("\(ask.ref): no package record for \(hash.prefix(12))") }
            try materialize(staged: staged, id: id, hash: hash, pluginHash: package.pluginTreeSha256, workspace: workspace, paths: paths)
            let chosen = roles ?? payload.roles
            try store.writer.write { db in
                var row = try CompanyExtension.fetchOne(db, key: ["companyId": company.id, "id": id])
                    ?? CompanyExtension(companyId: company.id, id: id, hash: hash, installedAskId: ask.id, installedAt: now)
                row.hash = hash; row.enabled = true; row.installedAskId = ask.id; row.installedAt = now
                // The publisher and source the owner approved on the card, for this company (B-I1).
                row.publisher = payload.publisher; row.sourceType = payload.sourceType ?? package.sourceType
                row.sourceUrl = payload.sourceUrl ?? package.sourceUrl; row.sourceSha = payload.sourceSha ?? package.sourceSha
                try row.save(db)
                // A re-install lifts the "removed by owner" override; the ticked roles get add bindings.
                try db.execute(sql: "DELETE FROM extensionBinding WHERE companyId = ? AND id = ? AND op = 'remove'", arguments: [company.id, id])
                for role in chosen {
                    let exists = try ExtensionBinding.filter(Column("companyId") == company.id && Column("id") == id && Column("scope") == "role"
                                                             && Column("target") == role && Column("op") == "add").fetchCount(db)
                    if exists == 0 { try ExtensionBinding(companyId: company.id, id: id, scope: "role", target: role, op: "add", createdAt: now).insert(db) }
                }
                _ = try store.ownerDecide(db: db, askId: ask.id, approve: true, note: "", acknowledgeChange: true, currentHash: nil, grant: nil,
                                          extensionApproved: true, now: now)
                try Store.recordExtensionEvent(db, companyId: company.id, extId: id, kind: "installed",
                                               detail: "\(hash) for \(chosen.isEmpty ? "no role" : chosen.joined(separator: ", "))", now: now)
            }
            try? FileManager.default.removeItem(at: staged)
        case "remove":
            try remove(companyId: company.id, id: id, store: store, paths: paths, now: now, deciding: ask)
        case "rollback":
            try rollback(companyId: company.id, id: id, store: store, paths: paths, now: now, deciding: ask)
        case "bind", "unbind":
            guard let role = payload.role else { throw WorkError.invalid("\(ask.ref) names no role") }
            try store.writer.write { db in
                try db.execute(sql: "DELETE FROM extensionBinding WHERE companyId = ? AND id = ? AND scope = 'role' AND target = ?",
                               arguments: [company.id, id, role])
                try ExtensionBinding(companyId: company.id, id: id, scope: "role", target: role, op: payload.action == "bind" ? "add" : "remove",
                                     createdAt: now).insert(db)
                try Store.recordExtensionEvent(db, companyId: company.id, extId: id, kind: payload.action, detail: role, now: now)
            }
            try decide(store, ask)
        default:
            throw WorkError.invalid("\(ask.ref): unknown extension action '\(Store.flat(payload.action, max: 40))'")
        }
    }

    private static func decide(_ store: Store, _ ask: Ask) throws {
        try store.writer.write { db in
            _ = try store.ownerDecide(db: db, askId: ask.id, approve: true, note: "", acknowledgeChange: true, currentHash: nil, grant: nil,
                                      extensionApproved: true, now: Store.now())
        }
    }

    /// A rejected install (plain `ownerDecide(approve: false)`): the staged tree is removed and the event written. Called inside
    /// the owner's decision transaction.
    static func declined(_ db: Database, ask: Ask, now: Date) throws {
        guard let payload = ExtensionAskPayload.read(ask) else { return }
        // Only `<…>/extensions/staging/<one component>` is ever removed (M8): the staging root is known exactly from the path's shape.
        if let path = payload.stagedPath, let staging = path.range(of: "/extensions/staging/"),
           !path[staging.upperBound...].isEmpty, !path[staging.upperBound...].contains("/"),
           SandboxPath.kind(path) == .directory, SandboxPath.linkedComponent(path, under: String(path[..<staging.lowerBound]) + "/extensions") == nil {
            try? FileManager.default.removeItem(atPath: path)
        }
        try Store.recordExtensionEvent(db, companyId: ask.companyId, extId: payload.extId, kind: "declined", detail: "\(ask.ref) \(payload.action)", now: now)
    }

    /// Copies the verified tree into the store (read-only) and the plugin parts into the workspace (read-only, through
    /// `EngineFiles`), then checks the workspace copy hashes as recorded.
    static func materialize(staged: URL, id: String, hash: String, pluginHash: String, workspace: URL, paths: BrahmaPaths) throws {
        let fm = FileManager.default
        let hash12 = String(hash.prefix(12))
        try BrahmaPaths.ensurePrivateDirectory(paths.extensionsDir.store)
        let storeDir = paths.extensionsDir.store.appending(path: "\(id)/\(hash12)", directoryHint: .isDirectory)
        if staged.standardizedFileURL.path != storeDir.standardizedFileURL.path {
            if fm.fileExists(atPath: storeDir.path) { makeWritable(storeDir); try fm.removeItem(at: storeDir) }
            try ExtensionImporter.copyTree(from: staged, to: storeDir)
            makeReadOnly(storeDir)
        }
        // The workspace copy: every write under `.brahma` goes through EngineFiles (no link is ever followed).
        let relative = ".brahma/ext/\(id)/\(hash12)/plugin"
        let pluginDir = workspace.appending(path: relative, directoryHint: .isDirectory)
        if SandboxPath.kind(pluginDir.path) != .missing {
            makeWritable(pluginDir)
            _ = try EngineFiles.removeNoFollow(pluginDir, under: workspace)
        }
        try writePluginParts(from: staged, workspace: workspace, relative: relative)
        guard try ExtensionLock.treeHash(root: pluginDir) == pluginHash else {
            makeWritable(pluginDir)
            _ = try? EngineFiles.removeNoFollow(pluginDir, under: workspace)
            throw ExtensionError.message("the materialized plugin parts do not hash as recorded; nothing was installed")
        }
    }

    /// Copies the plugin parts of `staged` (`workspaceParts`) to `<workspace>/<relative>` read-only (0444, `bin/` 0555), every
    /// write through `EngineFiles` (no link is ever followed). Also the owner's `ext try` copy (10b).
    static func writePluginParts(from staged: URL, workspace: URL, relative: String) throws {
        _ = try EngineFiles.directory(workspace: workspace, relative)
        for f in try PackageWalk.files(root: staged) where f.kind == .regular {
            let parts = f.relative.split(separator: "/").map(String.init)
            guard let top = parts.first, workspaceParts.contains(top) else { continue }
            let dir = relative + (parts.count > 1 ? "/" + parts.dropLast().joined(separator: "/") : "")
            _ = try EngineFiles.directory(workspace: workspace, dir)
            guard let data = FileManager.default.contents(atPath: f.url.path) else { throw ExtensionError.message("cannot read \(f.relative)") }
            _ = try EngineFiles.replace(data, workspace: workspace, dir: dir, name: parts.last!, mode: top == "bin" ? 0o555 : 0o444)
        }
    }

    static func makeReadOnly(_ root: URL) {
        for f in (try? PackageWalk.files(root: root)) ?? [] where f.kind == .regular {
            chmodNoFollow(f.url.path, (f.mode & 0o111) != 0 ? 0o555 : 0o444)
        }
    }

    static func makeWritable(_ root: URL) {
        for f in (try? PackageWalk.files(root: root, includeDirectories: true)) ?? [] where f.kind == .directory || f.kind == .regular {
            chmodNoFollow(f.url.path, f.kind == .directory ? 0o755 : ((f.mode & 0o111) != 0 ? 0o755 : 0o644))
        }
    }

    /// `chmod` that never follows a symbolic link (M2): a link planted where a file was is left alone.
    static func chmodNoFollow(_ path: String, _ mode: mode_t) {
        #if canImport(Darwin)
        _ = fchmodat(AT_FDCWD, path, mode, AT_SYMLINK_NOFOLLOW)
        #else
        if SandboxPath.kind(path) != .link { _ = chmod(path, mode) }
        #endif
    }

    // MARK: Remove and roll back

    /// Unmounts from the next session (the mount set changes), removes the bindings and the extension grants, and keeps a
    /// "removed by owner" override when the pack still suggests the extension. The store copies stay for a later rollback.
    public static func remove(companyId: String, id: String, store: Store, paths: BrahmaPaths, now: Date = Store.now(), deciding ask: Ask? = nil) throws {
        guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
        guard try store.installedExtensions(companyId: companyId).contains(where: { $0.id == id }) else { throw WorkError.notFound("no extension '\(id)'") }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let extDir = workspace.appending(path: ".brahma/ext/\(id)", directoryHint: .isDirectory)
        if SandboxPath.kind(extDir.path) != .missing {
            makeWritable(extDir)
            _ = try EngineFiles.removeNoFollow(extDir, under: workspace)
        }
        let suggested = (store.catalog.pack(company.packId)?.roles ?? []).contains { $0.extensions.contains { $0.id == id } }
        try store.writer.write { db in
            try db.execute(sql: "DELETE FROM companyExtension WHERE companyId = ? AND id = ?", arguments: [companyId, id])
            try db.execute(sql: "DELETE FROM extensionBinding WHERE companyId = ? AND id = ?", arguments: [companyId, id])
            let grants = try Grant.filter(Column("companyId") == companyId && Column("kind") == GrantKind.extension.rawValue && Column("revokedAt") == nil)
                .fetchAll(db).filter { ExtensionRef.parse($0.value)?.id == id }
            try Store.revoke(db, grants, by: "owner", why: "extension \(id) removed", now: now)
            if suggested { try ExtensionBinding(companyId: companyId, id: id, scope: "role", target: "*", op: "remove", createdAt: now).insert(db) }
            try Store.recordExtensionEvent(db, companyId: companyId, extId: id, kind: "removed", detail: suggested ? "pack suggestion overridden" : nil, now: now)
            if let ask {
                _ = try store.ownerDecide(db: db, askId: ask.id, approve: true, note: "", acknowledgeChange: true, currentHash: nil, grant: nil,
                                          extensionApproved: true, now: now)
            }
        }
    }

    /// Back to the previous approved hash (its store copy is still there); the workspace plugin parts are materialized again
    /// when missing. Immediate: it was already approved once.
    public static func rollback(companyId: String, id: String, store: Store, paths: BrahmaPaths, now: Date = Store.now(), deciding ask: Ask? = nil) throws {
        guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
        guard let current = try store.installedExtensions(companyId: companyId).first(where: { $0.id == id }) else { throw WorkError.notFound("no extension '\(id)'") }
        // The install history (rollbacks excluded): the version approved right before the current one (M10: idempotent).
        let hashes = try store.extensionEvents(companyId: companyId, extId: id).filter { $0.kind == "installed" }
            .compactMap { $0.detail?.split(separator: " ").first.map(String.init) }.filter { $0.count == 64 }
        guard let at = hashes.lastIndex(of: current.hash), at > 0, let previous = hashes[..<at].last(where: { $0 != current.hash }),
              let package = try store.extensionPackage(hash: previous) else {
            throw WorkError.invalid("no earlier approved version of '\(id)' to roll back to")
        }
        let storeDir = paths.extensionsDir.store.appending(path: "\(id)/\(previous.prefix(12))", directoryHint: .isDirectory)
        guard SandboxPath.kind(storeDir.path) == .directory else { throw WorkError.invalid("the earlier version of '\(id)' is no longer in the store") }
        // m-3: the store copy must still pass today's validator and already be in canonical form (a copy an older engine wrote
        // may not be); otherwise it is installed again through propose, never mounted as it is.
        let recheck = ExtensionValidator.validate(staged: storeDir)
        guard recheck.errors.isEmpty, try ExtensionValidator.isCanonical(root: storeDir) else {
            throw WorkError.invalid("the earlier version of '\(id)' does not pass the current checks; install it again instead of rolling back")
        }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        try materialize(staged: storeDir, id: id, hash: previous, pluginHash: package.pluginTreeSha256, workspace: workspace, paths: paths)
        // The earlier version's own source facts (10b): those of the approved install of that hash. Without one, an extension
        // from a lab is rolled back as tainted provenance (fail closed).
        let origin = try store.asks(companyId: companyId, statuses: [.approved]).compactMap(ExtensionAskPayload.read)
            .last { $0.action == "install" && $0.extId == id && $0.hash == previous }
        var sourceType = origin?.sourceType ?? current.sourceType
        if origin == nil, sourceType == ExtensionSourceKind.lab { sourceType = ExtensionSourceKind.labTainted }
        try store.writer.write { db in
            try db.execute(sql: "UPDATE companyExtension SET hash = ?, installedAt = ?, publisher = ?, sourceType = ?, sourceUrl = ?, sourceSha = ? "
                           + "WHERE companyId = ? AND id = ?",
                           arguments: [previous, now, origin?.publisher ?? current.publisher, sourceType, origin?.sourceUrl ?? current.sourceUrl,
                                       origin?.sourceSha ?? current.sourceSha, companyId, id])
            try Store.recordExtensionEvent(db, companyId: companyId, extId: id, kind: "rollback", detail: "\(previous) from \(current.hash.prefix(12))", now: now)
            if let ask {
                _ = try store.ownerDecide(db: db, askId: ask.id, approve: true, note: "", acknowledgeChange: true, currentHash: nil, grant: nil,
                                          extensionApproved: true, now: now)
            }
        }
    }

    // MARK: Mounts

    /// The plugin dirs one turn mounts, sorted by id: `RoleBundle.effective` over the pack, the company's overrides and the
    /// grants, kept to what is installed, enabled, allowed on the profile and present with its recorded hash. Review and
    /// audit turns mount none. A tree that does not hash as recorded is blocked (`extensionEvent tamper`, an engine alert);
    /// a missing host tool leaves the extension out with an owner notice "<id> needs <tool>". Brahma's built-in
    /// `extension-authoring` joins on itemless turns (`BuiltinExtensions.mounts`). `itemScoped` nil: as the turn's session scope
    /// is chosen (`TurnContext`): a notice turn is itemless; a work turn is item-scoped when the agent holds a lease or has a
    /// current item. Blocking (it hashes files).
    public static func mounts(company: Company, role: String, agent: Agent, grants: GrantInputs, profile: PermissionProfile, kind: TurnKind,
                              itemScoped: Bool? = nil, store: Store, paths: BrahmaPaths, now: Date = Store.now()) throws -> [ExtensionMount] {
        if kind == .review || kind == .audit { return [] }
        let scoped = try itemScoped ?? (kind == .plan || kind == .work
            && (try store.lease(agentId: agent.id) != nil || store.currentItemWithoutLease(agentId: agent.id) != nil))
        let builtins = BuiltinExtensions.mounts(company: company, role: role, kind: kind, itemScoped: scoped, store: store)
        return (builtins + (try installedMounts(company: company, role: role, agent: agent, grants: grants, profile: profile, store: store,
                                                now: now))).sorted { $0.id < $1.id }
    }

    static func installedMounts(company: Company, role: String, agent: Agent, grants: GrantInputs, profile: PermissionProfile,
                                store: Store, now: Date) throws -> [ExtensionMount] {
        // A built-in's id is never mounted from a company row (none can be filed; a stale one is ignored).
        let installed = try store.installedExtensions(companyId: company.id).filter { !BuiltinExtensions.ids.contains($0.id) }
        guard !installed.isEmpty else { return [] }
        var packages: [String: ExtensionPackage] = [:]
        for e in installed { if let p = try store.extensionPackage(hash: e.hash) { packages[e.id] = p } }
        // The publisher is the company's own (set at approve), never the shared package row's (B-I1).
        let have = installed.filter { packages[$0.id] != nil && !$0.publisher.isEmpty }
            .map { RoleBundle.Installed(id: $0.id, publisher: $0.publisher, hash: $0.hash, enabled: $0.enabled,
                                        provenanceTainted: $0.provenanceTainted) }
        let template = store.catalog.pack(company.packId)?.role(role)
        let chosen = RoleBundle.effective(packRefs: template?.extensions ?? [], bindings: try store.extensionBindings(companyId: company.id),
                                          grants: grants.extensions, installed: have, role: role, agentId: agent.id, profile: profile)
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let resolvedWorkspace = workspace.resolvedForSandbox.path
        var out: [ExtensionMount] = []
        for ext in chosen {
            guard let package = packages[ext.id] else { continue }
            let hash12 = String(ext.hash.prefix(12))
            let pluginDir = workspace.appending(path: ".brahma/ext/\(ext.id)/\(hash12)/plugin", directoryHint: .notDirectory)
            // The plugin dir and every component down from the workspace must be real (M4), and the tree must hash as recorded
            // (a full rehash, cached on the files' inode, size and ctime within this engine run).
            let realDir = URL(fileURLWithPath: resolvedWorkspace).appending(path: ".brahma/ext/\(ext.id)/\(hash12)/plugin", directoryHint: .notDirectory)
            guard SandboxPath.linkedComponent(realDir.path, under: resolvedWorkspace) == nil, RehashCache.verify(realDir, expected: package.pluginTreeSha256) else {
                try blocked(store: store, company: company, id: ext.id, hash: ext.hash, missing: SandboxPath.kind(realDir.path) == .missing, now: now)
                continue
            }
            var network: [String] = []
            // The sidecar as recorded at propose (M3), never the store copy on disk.
            if let side = package.sidecar {
                network = side.agentNetwork
                if let missing = side.hostTools.first(where: { !HostTools.isAvailable($0) }) {
                    HostTools.notice(store: store, companyId: company.id, id: ext.id, tool: missing, now: now)
                    continue
                }
            }
            out.append(ExtensionMount(id: ext.id, hash: ext.hash, url: pluginDir, publisher: ext.publisher, agentNetwork: network))
        }
        return out
    }

    /// `StableHash` of the sorted `<id>@<hash>` lines: the session's frozen mount set.
    public static func mountSetHash(_ mounts: [ExtensionMount]) -> String {
        StableHash.fnv1a64(mounts.map { "\($0.id)@\($0.hash)" }.sorted().joined(separator: "\n"))
    }

    /// The egress the mounted extensions ask for (their `agentNetwork`), for the roles that mount them.
    public static func agentNetwork(_ mounts: [ExtensionMount]) -> [String] {
        Array(Set(mounts.flatMap(\.agentNetwork))).sorted()
    }

    /// A blocked mount: one `tamper` event per (company, extension, hash) per engine run (M13), one open alert; a missing tree is
    /// told apart from a changed one.
    static func blocked(store: Store, company: Company, id: String, hash: String, missing: Bool, now: Date) throws {
        let reason = "ext-tamper:\(company.id):\(id)"
        let detail = missing ? "the mounted tree is missing on disk; not mounted" : "the mounted tree does not hash as recorded; not mounted"
        let firstTime = TamperLog.lock.withLock { TamperLog.seen.insert("\(company.id)|\(id)|\(hash)|\(missing)").inserted }
        guard firstTime else { return }
        try store.writer.write { db in
            try Store.recordExtensionEvent(db, companyId: company.id, extId: id, kind: "tamper", detail: detail, now: now)
            let open = try Ask.filter(Column("companyId") == company.id && Column("kind") == AskKind.engineAlert
                                      && Column("status") == AskStatus.pendingOwner.rawValue
                                      && Column("subjectId") == Store.engineAlertKey(reason)).fetchCount(db)
            if open == 0 {
                let text = missing
                    ? "Extension \(id) in \(company.name) is missing from the workspace (\(hash.prefix(12))); Brahma stopped mounting it. "
                      + "Roll it back or install it again."
                    : "Extension \(id) in \(company.name) was changed on disk after it was approved; Brahma stopped mounting it. "
                      + "Remove it and install it again from a trusted source."
                try EngineAlerts.raise(store: store, db: db, text: text, now: now, reason: reason, companyId: company.id)
            }
        }
    }
}

/// Which tampers this engine run has already recorded.
enum TamperLog {
    static let lock = NSLock()
    nonisolated(unsafe) static var seen: Set<String> = []
}

/// Within one engine run, a tree whose files have the same inode, size and ctime hashes the same; otherwise it is rehashed whole.
enum RehashCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (stamp: String, hash: String)] = [:]

    static func verify(_ root: URL, expected: String) -> Bool {
        guard SandboxPath.kind(root.path) == .directory, let files = try? PackageWalk.files(root: root) else { return false }
        var stamp = ""
        for f in files {
            var st = stat()
            guard lstat(f.url.path, &st) == 0, st.st_nlink == 1 || f.kind == .directory else { return false }
            stamp += "\(f.relative)|\(st.st_ino)|\(st.st_size)|\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec)\n"
        }
        if let known = lock.withLock({ cache[root.path] }), known.stamp == stamp { return known.hash == expected }
        guard let hash = try? ExtensionLock.treeHash(root: root) else { return false }
        lock.withLock {
            if cache.count > 1024 { cache.removeAll() }
            cache[root.path] = (stamp, hash)
        }
        return hash == expected
    }
}

/// `requires.hostTools`: a tool is available when an executable of that name is on the owner's PATH (or the usual places).
enum HostTools {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var noticed: Set<String> = []

    static func isAvailable(_ spec: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let name = String(spec.prefix { $0 != ">" })
        guard !name.isEmpty, !name.contains("/") else { return false }
        var dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/usr/bin", "/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        return dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(name)") }
    }

    /// One owner notice per (company, extension, tool) per engine run.
    static func notice(store: Store, companyId: String, id: String, tool: String, now: Date) {
        let key = "\(companyId)|\(id)|\(tool)"
        let first = lock.withLock { noticed.insert(key).inserted }
        guard first else { return }
        try? store.notifyOwner(companyId: companyId, title: "\(id) needs \(tool)",
                               body: "The extension \(id) requires the host tool \(tool), which is not installed on this Mac; it is not mounted until it is.", now: now)
    }
}

extension Orchestrator {
    /// The sandboxed runner the owner's CLI and the doctor run Claude's own plugin checks under: the check baseline (the owner's
    /// home, data home, every workspace and the backup folders protected), Seatbelt where available.
    public static func ownerSandboxRunner(store: Store, paths: BrahmaPaths) -> any SandboxedRunner {
        SandboxRunners.platformDefault(baseline: ownerSandboxBaseline(store: store, paths: paths), proxies: EgressProxyPool())
    }

    /// That runner's baseline, taken at each run: the sandbox canary's model-free layer starts from it (`SandboxCanary.baseline`).
    public static func ownerSandboxBaseline(store: Store, paths: BrahmaPaths) -> @Sendable () -> SandboxBaseline {
        { checkBaseline(store: store, paths: paths) }
    }
}

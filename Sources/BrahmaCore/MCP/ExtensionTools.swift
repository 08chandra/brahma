import Foundation

/// `propose_extension` (Task 10b): an agent hands an extension it built in its lab to the company. High risk (refused while
/// tainted, `TaintPolicy.reviewedHighRisk`) and counted by `AskQuota`. Only a folder in the caller's own lab, only as committed
/// (`HEAD`), only with a clean lint; the provenance of every lab commit that touched it rides on the ask. It files one reserved
/// `extension` ask that the pack's internal reviewer pre-checks and the owner decides. A draft is never mounted on any turn
/// before the owner approves it.
extension CompanyTools {
    static let proposeOutsideLab = "propose_extension takes a folder in your lab"

    static func extensionToolSpecs() -> [ToolSpec] {
        [
            ToolSpec(name: "propose_extension", description: """
                Propose an extension you built in your lab (a skill-only Claude Code plugin folder) for the company. Commit the \
                folder first: Brahma snapshots it at your lab's last commit and lints it, and the lint must be clean (`brahma ext \
                lint --json <folder>` prints []). Your technical lead pre-checks it, then the owner decides. Nothing you propose is \
                mounted on any turn before the owner approves it.
                """, inputSchema: schema([
                    "path": prop("string", "The extension folder in your lab, relative to the lab (for example brand-voice)"),
                    "summary": prop("string", "One line: what it does and why the team needs it"),
                    "roles": .object(["type": .string("array"), "items": .object(["type": .string("string")]),
                                      "description": .string("The role ids it suits, for example engineer")]),
                    "item": prop("string", "The work item key it came from, if any"),
                ], required: ["path", "summary", "roles"])),
        ]
    }

    /// Runs an extension tool, or returns nil when `name` is not one.
    func dispatchExtension(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        guard name == "propose_extension" else { return nil }
        do { return try proposeExtension(args) } catch let e as ExtensionError {
            throw ToolError(message: e.issues.isEmpty ? e.message : Self.lintRefusal(e.issues))
        } catch let e as WorkError {
            throw ToolError(message: e.message)
        }
    }

    /// The refusal of a package whose lint is not clean: the `--json` list, quoted line by line (agent-written paths and text).
    static func lintRefusal(_ issues: [LintIssue]) -> String {
        "lint is not clean, so nothing was proposed. Fix every entry (run `brahma ext lint --json <folder>` in your lab until it "
            + "prints []), commit, and propose again:\n"
            + ExtensionValidator.lintJSON(issues).split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    | " + Store.stripControls(String($0)) }.joined(separator: "\n")
    }

    /// `path` as a folder of the lab, relative to it: a relative path, or an absolute one inside one of `labs` (the lab as the
    /// workspace path spells it and as it resolves). Anything else is refused.
    static func labRelative(_ raw: String, labs: [String]) throws -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("/") {
            guard let lab = labs.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { throw ToolError(message: proposeOutsideLab) }
            path = String(path.dropFirst(lab.count))
            while path.hasPrefix("/") { path.removeFirst() }
        }
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasSuffix("/") { path.removeLast() }
        guard GitWorkspace.isLabFolderPath(path) else { throw ToolError(message: proposeOutsideLab) }
        return path
    }

    private func proposeExtension(_ args: [String: JSONValue]) throws -> String {
        let raw = try string(args, "path")
        let summary = try string(args, "summary")
        let roles = try stringArray(args, "roles").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var itemId: String?
        if let key = try optionalString(args, "item") {
            guard let item = try store.workItem(companyId: companyId, key: key.trimmingCharacters(in: .whitespaces).uppercased()) else {
                throw ToolError(message: "no work item \(Store.flat(key, max: 40).uppercased())")
            }
            itemId = item.id
        }
        // AskQuota before any work (the store applies it again in the write that files the ask).
        try AskQuota.check(store: store, agentId: agentId)
        guard let me = try store.agent(id: agentId), let company = try store.company(id: companyId) else {
            throw ToolError(message: "this agent is not active in the company")
        }
        guard let paths = paths ?? store.dataHome.map({ BrahmaPaths(home: $0, workspaces: $0) }) else {
            throw ToolError(message: "extensions need Brahma's data home; nothing was proposed")
        }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let resolved = workspace.resolvedForSandbox
        let relative = try Self.labRelative(raw, labs: [workspace, resolved].map { $0.appending(path: ".brahma/labs/\(me.name)").path })
        let lab = resolved.appending(path: ".brahma/labs/\(me.name)", directoryHint: .isDirectory)

        // Provenance: the lab's commits not recorded yet are recorded first, with this session's taint state, exactly as the
        // turn's end would (it is clean here: the taint gate refused the call otherwise). A commit an earlier tainted session
        // made was recorded tainted at that turn's end, before its taint could be cleared; a commit with no record counts as
        // tainted. A lab that cannot be read is refused (and the session tainted, the owner alerted).
        let tainted = me.sessionTainted || (taintFlag.map(TaintFlag.exists) ?? false)
        switch LabProvenance.record(store: store, workspace: workspace, handle: me.name, companyId: companyId, agentId: agentId,
                                    turnId: quotaTurnId, tainted: tainted, now: Store.now()) {
        case .none: throw ToolError(message: "your lab has no repository yet; nothing was proposed")
        case .refused(let why): throw ToolError(message: "your lab could not be read for provenance (\(Store.flat(why, max: 200))); nothing was proposed")
        case .recorded: break
        }
        let git = store.gitWorkspace(root: lab, companyId: companyId)
        guard let head = try git.labHead() else { throw ToolError(message: "your lab has no commit yet: commit the folder first") }
        let touching = try git.labPathCommits(commit: head, path: relative)
        guard !touching.isEmpty else { throw ToolError(message: "\(relative) is not in your lab's last commit: commit it first") }
        let taintedCommits = try touching.filter { try store.labCommitTainted(agentId: agentId, sha: $0) }

        // The snapshot of HEAD:<path>, staged under the data home; the company is its publisher (never the lab or the package).
        let facts = ExtensionSourceFacts(publisher: ExtensionPublisher.company(company.slug),
                                         sourceType: taintedCommits.isEmpty ? ExtensionSourceKind.lab : ExtensionSourceKind.labTainted,
                                         sourceUrl: "labs/\(me.name)/\(relative)", sourceSha: head)
        let validation = ValidationOptions(installedBins: try store.installedBins(companyId: companyId, paths: paths))
        let staged = try ExtensionImporter.stageLab(paths: paths, facts: facts, requireClean: true, options: validation) { tar, place in
            try git.labArchive(commit: head, path: relative, tar: tar, into: place)
        }
        let ask: Ask
        do {
            ask = try ExtensionLibrary.proposeSync(staged: staged, store: store, paths: paths, companyId: companyId, requester: .agent(agentId),
                                                   roles: roles, options: ExtensionLibrary.ProposalOptions(
                                                       viaOwner: false, summary: summary, itemId: itemId, taintedCommits: taintedCommits,
                                                       requireClean: true))
        } catch {
            try? FileManager.default.removeItem(at: staged.dir)
            throw error
        }
        let reviewer = try ask.internalApproverId.flatMap { try store.agent(id: $0) }?.name
        let who = reviewer.map { "@\($0) reviews it, then the owner decides." } ?? "No internal reviewer is available, so the owner decides."
        return "Proposed \(ask.ref) (\(staged.id)). \(who) Drafts are never mounted before approval."
    }
}

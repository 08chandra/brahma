import Foundation

/// `propose_extension` (Task 10b): an agent hands an extension it built in its lab to the company. High risk (refused while
/// tainted, `TaintPolicy.reviewedHighRisk`) and counted by `AskQuota`. Only a folder in the caller's own lab, only as committed
/// (`HEAD`), only with a clean lint. Its provenance is decided by content (S25): the tainted or unrecorded lab commits that
/// introduced any of its trees or blobs, or touched its path, ride on the ask. A clean one files a reserved `extension` ask the
/// pack's internal reviewer pre-checks and the owner decides; a tainted one, or any from a lab with the sticky mark (I2: a
/// tainted session has worked in it since the owner last cleared it), goes straight to the owner (I1), so no teammate reads it. A draft is never mounted on any turn before the owner approves it.
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

        // Provenance (S25). Nothing is recorded here: the turn's end records the lab as always. The order: the lab's `.git`
        // checks, HEAD resolved once to a sha, the records read and the lab's commits listed (every commit with no record is
        // unrecorded, so tainted, for this proposal), then the verdict by CONTENT: the folder is tainted when any of its trees or
        // blobs (object ids) was introduced by a tainted or unrecorded commit, wherever it was then (a rename or copy keeps the
        // id), or such a commit touched the folder's path. The checks run again right before the archive.
        let now = Store.now()
        let refused: (String) -> ToolError = { why in
            LabProvenance.refused(store: store, companyId: companyId, agentId: agentId, handle: me.name, why: why, now: now)
            return ToolError(message: "your lab could not be read for provenance (\(Store.flat(why, max: 200))); nothing was proposed")
        }
        switch LabProvenance.inspect(workspace: workspace, handle: me.name) {
        case .missing: throw ToolError(message: "your lab has no repository yet; nothing was proposed")
        case .refused(let why): throw refused(why)
        case .ok: break
        }
        let git = store.gitWorkspace(root: lab, companyId: companyId)
        guard let head = try git.labHead() else { throw ToolError(message: "your lab has no commit yet: commit the folder first") }
        let states = try store.labCommitStates(agentId: agentId)
        let all: [String]
        do { all = try git.labCommits() } catch { throw refused("\(error)") }
        let suspect = Set(all.filter { states[$0] != false } + (states[head] == false ? [] : [head]))
        let touching = try git.labPathCommits(commit: head, path: relative)
        guard !touching.isEmpty else { throw ToolError(message: "\(relative) is not in your lab's last commit: commit it first") }
        let folder = try git.labFolderObjects(commit: head, path: relative)
        let introduced = try git.labIntroducedObjects(commits: suspect.sorted())
        let byContent = introduced.filter { !$0.value.isDisjoint(with: folder) }.map(\.key)
        let taintedCommits = Array(Set(byContent + touching.filter(suspect.contains))).sorted()
        // I2: the sticky lab mark (a tainted session has worked in this lab since the owner last cleared it) decides on its own;
        // the commits above stay as attribution.
        let mark = try store.labTaint(agentId: agentId).map { m -> String in
            let iso = ISO8601DateFormatter()
            return "first: \(m.source), \(iso.string(from: m.markedAt))"
        }
        let tainted = mark != nil || !taintedCommits.isEmpty

        // The snapshot of HEAD:<path>, staged under the data home; the company is its publisher (never the lab or the package).
        let facts = ExtensionSourceFacts(publisher: ExtensionPublisher.company(company.slug),
                                         sourceType: tainted ? ExtensionSourceKind.labTainted : ExtensionSourceKind.lab,
                                         sourceUrl: "labs/\(me.name)/\(relative)", sourceSha: head)
        let validation = ValidationOptions(installedBins: try store.installedBins(companyId: companyId, paths: paths))
        let handle = me.name
        let staged = try ExtensionImporter.stageLab(paths: paths, facts: facts, requireClean: true, options: validation) { tar, place in
            if case .refused(let why) = LabProvenance.inspect(workspace: workspace, handle: handle) { throw refused(why) }
            try git.labArchive(commit: head, path: relative, tar: tar, into: place)
        }
        // I1: tainted (or unrecorded) content goes straight to the owner: no teammate's turn reads its review page.
        let ask: Ask
        do {
            ask = try ExtensionLibrary.proposeSync(staged: staged, store: store, paths: paths, companyId: companyId, requester: .agent(agentId),
                                                   roles: roles, options: ExtensionLibrary.ProposalOptions(
                                                       viaOwner: tainted, summary: summary, itemId: itemId,
                                                       taintedCommits: taintedCommits, labMark: mark, requireClean: true))
        } catch {
            try? FileManager.default.removeItem(at: staged.dir)
            throw error
        }
        if mark != nil {
            return "Proposed \(ask.ref) (\(staged.id)). A session that read outside content has worked in your lab, so everything "
                + "proposed from it goes straight to the owner until the owner clears that. Drafts are never mounted before approval."
        }
        if !taintedCommits.isEmpty {
            return "Proposed \(ask.ref) (\(staged.id)). Its content comes in part from lab commits made by a session that read outside "
                + "content, or not yet recorded (a commit is recorded when the turn that made it ends), so it goes straight to the owner. "
                + "Drafts are never mounted before approval."
        }
        let reviewer = try ask.internalApproverId.flatMap { try store.agent(id: $0) }?.name
        let who = reviewer.map { "@\($0) reviews it, then the owner decides." } ?? "No internal reviewer is available, so the owner decides."
        return "Proposed \(ask.ref) (\(staged.id)). \(who) Drafts are never mounted before approval."
    }
}

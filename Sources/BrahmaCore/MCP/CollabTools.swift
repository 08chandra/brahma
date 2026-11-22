import Foundation

/// Plan C Task C3b's agent tools: `share` (refs to a teammate or channel, pinned and gated) and `open_ref` (the one read path
/// for shared content), plus the `attachments` argument of `post_message` and `send_dm`. Every secret-gate read point here
/// gets the injected vault's stored values (`Store.knownSecretValues`) and the archive reader (`archives`: the sandboxed
/// unzip reader with the PDF helper in `brahma mcp`; none refuses archives and PDFs). Owner-only paths (`purge`,
/// `viewOriginal`) have no tool.
extension CompanyTools {
    static func refsProp(_ description: String) -> JSONValue {
        .object(["type": .string("array"), "items": .object(["type": .string("string")]), "description": .string(description)])
    }

    static func collabToolSpecs() -> [ToolSpec] {
        let s = Self.self
        return [
            ToolSpec(name: "share", description: "Share refs (files, diffs, items, F-/AR- refs, msg:<id> quotes) with @handle or #channel. Pinned as they are now; nothing is pasted.",
                     inputSchema: s.schema(["refs": s.refsProp("1-6 refs, e.g. ENG-12:src/a.ts:40-88"),
                                            "to": s.prop("string", "@handle, @owner or #channel"),
                                            "note": s.prop("string", "Short note (max 600 chars)"),
                                            "reply_to": s.prop("string", "Reply in this message's thread (msg:<id>)")],
                                           required: ["refs", "to"])),
            ToolSpec(name: "open_ref", description: "Read a ref you can access (bounded; lines a-b). copy: true copies it into your lab's in/ folder.",
                     inputSchema: s.schema(["ref": s.prop("string", "The ref, e.g. ENG-12:src/a.ts@a1b2c3d or F-3"),
                                            "lines": s.prop("string", "Line window, e.g. 40-120"),
                                            "copy": s.prop("boolean", "Copy the whole content into your lab")],
                                           required: ["ref"])),
        ]
    }

    func dispatchCollab(_ name: String, _ args: [String: JSONValue]) throws -> String? {
        switch name {
        case "share":
            let refs = try stringArray(args, "refs")
            let env = try collabEnvironment()
            return try store.share(companyId: companyId, by: agentId, refs: refs, to: try string(args, "to"), note: try optionalString(args, "note"),
                                   replyTo: try optionalString(args, "reply_to"), context: try refContext(), knownValues: env.known,
                                   paths: env.paths, now: Store.now(), archives: env.archives)
        case "open_ref":
            let ref = try string(args, "ref")
            var copy = false
            if let v = args["copy"], v != .null {
                guard case .bool(let b) = v else { throw ToolError(message: "argument copy must be true or false") }
                copy = b
            }
            let env = try collabEnvironment()
            return try store.openRef(companyId: companyId, reader: .agent(agentId), ref: ref, lines: try optionalString(args, "lines"),
                                     copy: copy, turnId: try runningTurnId(), context: try refContext(), knownValues: env.known,
                                     paths: env.paths, now: Store.now(), archives: env.archives).text
        default:
            return nil
        }
    }

    /// `post_message` / `send_dm` with `attachments` (`Store.postWithAttachments`); `to` is `#channel` or `@handle`.
    func postAttachments(to: String, text: String, attachments: [String], replyTo: String?) throws -> PostResult {
        let env = try collabEnvironment()
        return try store.postWithAttachmentsDetailed(companyId: companyId, by: agentId, to: to, text: text, attachments: attachments,
                                                     replyTo: replyTo, context: try refContext(), knownValues: env.known, paths: env.paths,
                                                     now: Store.now(), archives: env.archives)
    }

    /// The `attachments` argument: nil when absent, null or empty; at most `ShareLimits.maxRefs`.
    func attachmentList(_ args: [String: JSONValue]) throws -> [String]? {
        guard let v = args["attachments"], v != .null else { return nil }
        let list = try stringArray(args, "attachments")
        guard !list.isEmpty else { return nil }
        guard list.count <= ShareLimits.maxRefs else { throw ToolError(message: "attachments takes at most \(ShareLimits.maxRefs) refs") }
        return list
    }

    static func attachedSuffix(_ n: Int?) -> String {
        guard let n else { return "" }
        return " with \(n) attachment" + (n == 1 ? "" : "s")
    }

    /// The data home's places, the stored secrets' values (from the injected vault; one that can't be read refuses: fail
    /// closed) and the archive reader.
    func collabEnvironment() throws -> (paths: BrahmaPaths, known: [(name: String, value: String)], archives: any ArchiveReader) {
        guard let paths = paths ?? store.dataHome.map({ BrahmaPaths(home: $0, workspaces: BrahmaPaths.fromEnvironment().workspaces) }) else {
            throw ToolError(message: "shared content can't be read here")
        }
        let known: [(name: String, value: String)]
        do { known = try store.knownSecretValues(companyId: companyId, vault: vault ?? UnavailableVault()) } catch {
            diagnostics("brahma mcp: could not read the stored secrets to check shared content: \(error)")
            throw ToolError(message: "the content could not be checked for secrets right now, so nothing was shared or shown; try again next turn")
        }
        return (paths, known, archives ?? UnavailableArchiveReader())
    }

    /// What an agent's refs resolve against: the company's item key prefix, the agent as the actor.
    func refContext() throws -> RefContext {
        guard let company = try store.company(id: companyId) else { throw ToolError(message: "this agent is not active in the company") }
        return RefContext(companyId: companyId, keyPrefixes: [Store.keyPrefix(slug: company.slug)], actingAgentId: agentId)
    }

    /// `brahma mcp`'s archive reader: `unzip` and the PDF helper (`brahma-pdf` beside `executable`) under the owner's sandbox
    /// runner, each read in a fresh private vault temp directory. Where no sandbox or helper exists it refuses what it can't
    /// read (fail closed).
    public static func liveArchives(store: Store, paths: BrahmaPaths, companyId: String, executable: URL) -> any ArchiveReader {
        let vault = Vault(paths: paths, companyId: companyId, content: ContentVault(paths: paths))
        return SandboxedUnzipReader(runner: Orchestrator.ownerSandboxRunner(store: store, paths: paths), scratch: { try vault.makeTempDir() },
                                    pdfHelper: SandboxedPDFReader.locate(executable: executable))
    }
}

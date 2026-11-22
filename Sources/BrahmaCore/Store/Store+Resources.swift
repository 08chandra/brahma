import Foundation
import GRDB

/// Owner resources (Plan ML Task 6b): files and links the owner drops, stored in the vault and indexed under a scope. Every
/// operation here is the owner's (the CLI and the app); none is reachable from `CompanyTools`, which only reads (`recall`).
/// Every `resource` query is bound to one company (`companyId = ?`): another company's `F-<n>` answers like a missing one.
extension Store {
    /// Where company-scope, untainted files are mirrored read-only for agents' Bash and Read.
    public static let resourceMirrorDir = ".brahma/resources/company"
    /// File lines in one announcement before the rest are counted.
    static let maxAnnouncedFiles = 20

    // MARK: Scopes

    /// The scope and reader set a drop gets by default (collab §3.5): a DM → the agent, fixed; a channel → the channel, its
    /// agent members at drop time; an item card → the item, its holder, lease holder, reviewer, author and the holder's
    /// manager at drop time; a question in the Inbox → its requester, fixed; the library and the CLI → the company (dynamic).
    public func defaultScope(for context: DropContext, companyId: String) throws -> (AccessClass, Set<String>?) {
        try writer.read { db in try Self.defaultScope(db: db, for: context, companyId: companyId) }
    }

    static func defaultScope(db: Database, for context: DropContext, companyId: String) throws -> (AccessClass, Set<String>?) {
        switch context {
        case .dm(let handle):
            let agent = try resourceAgent(db, companyId: companyId, handle: handle)
            return (.agent(agent.id), [agent.id])
        case .channel(let name):
            let channel = try resourceChannel(db, companyId: companyId, name: name)
            return (.channel(channel.id), try channelAgentIds(db, channelId: channel.id, companyId: companyId))
        case .item(let id):
            let item = try resourceItem(db, companyId: companyId, id: id)
            return (.item(item.id), try itemReaderIds(db, item: item))
        case .inbox(let askId):
            guard let ask = try Ask.fetchOne(db, key: askId), ask.companyId == companyId,
                  let requester = try Agent.fetchOne(db, key: ask.requesterId), requester.companyId == companyId
            else { throw ResourceError.invalid(inboxRefusal) }
            return (.agent(requester.id), [requester.id])
        case .library, .cli:
            return (.company, nil)
        }
    }

    /// The fixed reader set a scope gets, whatever chose it (the app's chooser or the CLI): agent(a) → [a]; item(i) → its
    /// holder, lease holder, reviewer, author and the holder's manager now; a channel or DM → its agent members now. Team,
    /// role and company scopes stay dynamic (nil), and so does owner-only (no agent reads it). The scope's object must be the
    /// company's, else `ResourceError.notFound`.
    public func readerSet(for scope: AccessClass, companyId: String) throws -> Set<String>? {
        try writer.read { db in try Self.readerSet(db: db, for: scope, companyId: companyId) }
    }

    static func readerSet(db: Database, for scope: AccessClass, companyId: String) throws -> Set<String>? {
        switch scope {
        case .agent(let id):
            guard let agent = try Agent.fetchOne(db, key: id), agent.companyId == companyId else {
                throw ResourceError.notFound("no such agent")
            }
            return [agent.id]
        case .item(let id):
            return try itemReaderIds(db, item: try resourceItem(db, companyId: companyId, id: id))
        case .channel(let id), .dm(let id):
            guard let channel = try Channel.fetchOne(db, key: id), channel.companyId == companyId else {
                throw ResourceError.notFound("no such channel")
            }
            return try channelAgentIds(db, channelId: channel.id, companyId: companyId)
        case .company, .team, .role, .ownerOnly:
            return nil
        }
    }

    // MARK: Add files

    /// Adds an inspected drop (owner callers only: the CLI and the app). In this order:
    /// 1. **Secret choice.** A known-value finding with `.uploadAnyway` → `.forbidden`; any finding with `.none` → `.conflict`.
    /// 2. **Store as secret.** `.storeAsSecret(name)` stores the one text file (≤ `ResourcePolicy.secretFileBytes`) through
    ///    `setSecret`; no resource is created and `[]` is returned.
    /// 3. **Context and scope** are checked before anything is copied (an Inbox drop must be on a pending question whose
    ///    requester can read the scope).
    /// 4. **Recipients, on the announcement itself.** The rows are planned (a folder gets a `folder` row number plus one per
    ///    file) and the announcement they make is built; everyone that exact text reaches (the context's recipients and every
    ///    `@handle` in it) must read the drop in full. Names carry no `@` (`announcedName`), so only the owner's words mention.
    /// 5. **Vault copies, before any row** (`ContentVault.store`). On any failure every vault file this call wrote is removed
    ///    and nothing is inserted.
    /// 6. **Rows, in one transaction**: the rows, their memory docs (text kinds ≤ `ResourcePolicy.indexBytes`, never flagged;
    ///    other kinds by title only) and an activity line. If it fails, the vault files are removed.
    /// 7. **Mirror, after commit**: company-scope, untainted, unflagged files are copied read-only under
    ///    `.brahma/resources/company` (`EngineFiles.replace`); an `UnsafeEngineFile` skips the mirror with an alert.
    /// 8. **Announcement, after commit**, composed by the engine, its recipients checked again on the exact text delivered,
    ///    and delivered by the context (a DM, a channel post, the question's answer, an item comment; nothing for the library
    ///    and the CLI). Steps 7 and 8 are not fatal: a failure leaves an activity line.
    ///
    /// `paths` is the data home the vault must belong to (`contentVault.paths`).
    @discardableResult
    public func addResources(companyId: String, plan: DropPlan, drop: ResourceDrop, contentVault: ContentVault,
                             secretVault: any SecretVault, knownValues: [(name: String, value: String)], paths: BrahmaPaths,
                             now: Date = Store.now()) throws -> [Resource] {
        guard !plan.items.isEmpty else { throw ResourceError.invalid("there is nothing to add") }
        guard contentVault.paths == paths else { throw ResourceError.invalid("the vault belongs to another data home") }
        guard let company = try company(id: companyId) else { throw ResourceError.notFound("no such company") }

        // 1. Secret choice.
        let anyFinding = plan.items.contains { !$0.findings.isEmpty }
        let knownValueFinding = plan.items.contains { $0.findings.contains(where: \.isKnownValue) }
        switch drop.secretChoice {
        case .uploadAnyway where knownValueFinding:
            throw ResourceError.forbidden("this file contains a secret stored in your Keychain; upload a redacted copy or store it as a secret")
        case .none where anyFinding:
            throw ResourceError.conflict("this drop has secret findings; choose what to do")
        default:
            break
        }
        // 2. Store as secret.
        if case .storeAsSecret(let name) = drop.secretChoice {
            try storeDropAsSecret(company: company, plan: plan, name: name, contentVault: contentVault, secretVault: secretVault,
                                  knownValues: knownValues, now: now)
            return []
        }
        // 3. Context and scope.
        let resolved = try writer.read { db in try resolveDrop(db: db, companyId: companyId, drop: drop) }
        if drop.secretChoice == .uploadRedacted, let binary = plan.items.first(where: { !$0.findings.isEmpty && !$0.isText }) {
            throw ResourceError.invalid("\(binary.displayName) isn't a text file, so a redacted copy can't be made; remove the secret from it and add it again")
        }
        try refuseVaultInWorkspace(company: company, paths: paths)

        // 4. The rows as planned (numbers, trust, kinds), and the announcement they make: everyone that exact text reaches
        //    (the context's recipients and every @handle in it) must read the drop in full, checked before anything is copied.
        let dbMax = try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(number) FROM resource WHERE companyId = ?", arguments: [companyId]) ?? 0
        }
        var next = max(dbMax, try contentVault.highestNumber(companyId: companyId)) + 1
        func trust(_ provenance: Provenance, _ tainted: Bool, _ reason: String?) -> (String, Bool, String?, Date?) {
            switch drop.trust {
            case .vouched: (Provenance.owner.raw, false, nil, now)
            case .untrusted: (Provenance.external("owner-marked").raw, true, "marked untrusted by you", nil)
            case .asDetected: (provenance.raw, tainted, tainted ? reason ?? "outside content" : nil, nil)
            }
        }
        func row(number: Int, kind: ResourceKind, parentId: String?, name: String, trusted: (String, Bool, String?, Date?)) -> Resource {
            Resource(companyId: companyId, number: number, kind: kind, parentId: parentId, displayName: name,
                     scopeKind: resolved.scope.kind, scopeId: resolved.scope.id, readerSet: resolved.readerSet,
                     futureHolders: resolved.futureHolders, provenance: trusted.0, sourceDetail: name, tainted: trusted.1,
                     taintReason: trusted.2, vouchedAt: trusted.3, addedVia: drop.context.via, channelId: resolved.channelId,
                     askId: resolved.askId, itemId: resolved.itemId, createdAt: now, updatedAt: now)
        }
        func scanState(_ item: DropItem) -> SecretScanState {
            item.findings.isEmpty ? .none : drop.secretChoice == .uploadRedacted ? .redacted : .flagged
        }
        var rows: [Resource] = []
        var folder: Resource?
        if let folderName = plan.folderName {
            let firstTainted = plan.items.first { $0.tainted }
            var f = row(number: next, kind: .folder, parentId: nil, name: folderName,
                        trusted: trust(firstTainted?.provenance ?? .owner, firstTainted != nil, firstTainted?.taintReason))
            next += 1
            f.bytes = plan.items.reduce(0) { $0 + $1.bytes }
            f.quarantined = plan.items.contains { $0.quarantined }
            let scans = plan.items.map(scanState)
            f.secretScan = scans.contains(.flagged) ? .flagged : scans.contains(.redacted) ? .redacted : .none
            folder = f
            rows.append(f)
        }
        var fileRows: [(index: Int, item: DropItem)] = []
        for item in plan.items {
            var r = row(number: next, kind: .file, parentId: folder?.id, name: item.displayName,
                        trusted: trust(item.provenance, item.tainted, item.taintReason))
            next += 1
            r.ext = item.ext; r.fileKind = item.fileKind; r.bytes = item.bytes; r.quarantined = item.quarantined
            r.secretScan = scanState(item)
            fileRows.append((rows.count, item))
            rows.append(r)
        }
        let refsOnly = Self.refsOnly(drop)
        let planned = rows.map { r -> Resource in
            var r = r
            if Self.mirrors(r), let ext = r.ext { r.mirrorPath = "\(Self.resourceMirrorDir)/\(r.ref).\(ext)" }
            return r
        }
        let preview = Self.announcement(rows: planned, folder: planned.first { $0.kind == .folder }, message: drop.message,
                                        refsOnly: refsOnly)
        try writer.read { db in
            try checkRecipients(db: db, companyId: companyId, drop: drop, resolved: resolved, announcement: preview)
        }

        // 5. Vault copies, before any row is written.
        struct Stored { var item: DropItem; var number: Int; var path: String; var sha256: String; var bytes: Int64; var scan: SecretScanState }
        var written: [String] = []
        func removeWritten() {
            for path in written {
                do { try contentVault.remove(companyId: companyId, relativePath: path) } catch {
                    FileHandle.standardError.write(Data("brahma: could not remove the vault copy \(path) of a failed add: \(error)\n".utf8))
                }
            }
        }
        var stored: [Stored] = []
        var texts: [Int: String] = [:]
        do {
            for (index, item) in fileRows {
                let number = rows[index].number
                let scan = rows[index].secretScan
                let maxBytes = Int64(item.fileKind == ArtifactKind.video.rawValue ? ArtifactPolicy.maxVideoBytes : ArtifactPolicy.maxFileBytes)
                let result = try contentVault.store(companyId: companyId, number: number, ext: item.ext, item: item, maxBytes: maxBytes,
                                                    knownValues: knownValues) { verified in
                    guard scan == .redacted else { return nil }
                    let text = String(decoding: verified, as: UTF8.self)
                    return Data(ContentScan.redact(text: text, findings: item.findings, knownValues: knownValues).utf8)
                }
                written.append(result.relativePath)
                stored.append(Stored(item: item, number: number, path: result.relativePath, sha256: result.sha256, bytes: result.bytes, scan: scan))
            }
            // The index text comes from the vault copy (verified), so it is exactly what was stored.
            for s in stored where s.item.isText && s.scan != .flagged && s.bytes <= Int64(ResourcePolicy.indexBytes) {
                let data = try contentVault.read(companyId: companyId, relativePath: s.path, expectedSHA256: s.sha256, maxBytes: s.bytes)
                texts[s.number] = String(String(decoding: data, as: UTF8.self).prefix(MemoryPolicy.maxBodyChars))
            }
        } catch {
            removeWritten()
            throw error
        }

        // 6. Rows, in one transaction.
        let byNumber = Dictionary(uniqueKeysWithValues: stored.map { ($0.number, $0) })
        for i in rows.indices {
            guard let s = byNumber[rows[i].number] else { continue }
            rows[i].bytes = s.bytes; rows[i].sha256 = s.sha256; rows[i].vaultPath = s.path
            rows[i].textIndexed = texts[s.number] != nil
        }
        if let f = rows.firstIndex(where: { $0.kind == .folder }) {
            rows[f].bytes = stored.reduce(0) { $0 + $1.bytes }
            folder = rows[f]
        }
        do {
            try writer.write { db in
                for r in rows { try r.insert(db) }
                for r in rows { try ingestResource(db: db, r, text: texts[r.number], now: now) }
                let label = try Self.scopeLabel(db: db, resolved.scope, companyId: companyId)
                for r in rows where r.parentId == nil {
                    try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .resource,
                                      text: try redact("You added \(r.ref) \"\(Store.flat(r.displayName, max: 120))\" (\(label))"),
                                      createdAt: now).insert(db)
                }
            }
        } catch {
            removeWritten()
            throw error
        }

        // 7. Mirror, after commit.
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        var mirrored: [String: String] = [:]
        for r in rows where Self.mirrors(r) {
            guard let path = r.vaultPath, let sha = r.sha256, let ext = r.ext else { continue }
            let name = "\(r.ref).\(ext)"
            do {
                let bytes = try readResourceBytes(r, contentVault: contentVault, now: now, expected: (path, sha))
                if let replaced = try EngineFiles.replace(bytes, workspace: workspace, dir: Self.resourceMirrorDir, name: name, mode: 0o444) {
                    // Something planted at the name was replaced, never followed.
                    alertResourceMirror(replaced, companyId: companyId, now: now)
                }
                mirrored[r.id] = "\(Self.resourceMirrorDir)/\(name)"
            } catch let problem as UnsafeEngineFile {
                alertResourceMirror(problem, companyId: companyId, now: now)
                break       // the mirror directory itself is unsafe: no file of this drop goes there
            } catch {
                resourceTrace(companyId: companyId, "Could not mirror \(r.ref) into \(Self.resourceMirrorDir): \(error)", now: now)
            }
        }
        for i in rows.indices {
            if let path = mirrored[rows[i].id] { rows[i].mirrorPath = path; rows[i].mirrorSha256 = rows[i].sha256 }
        }

        // 8. Announcement, after commit.
        let text = Self.announcement(rows: rows, folder: folder, message: drop.message, refsOnly: refsOnly)
        let posted = announce(text, drop: drop, resolved: resolved, companyId: companyId, refs: rows.map(\.ref), now: now)
        if let posted { for i in rows.indices { rows[i].messageId = posted.id; rows[i].channelId = posted.channelId } }
        recordAfterCommit(companyId: companyId, rows: rows, mirrored: mirrored, posted: posted, now: now)
        do {
            return try writer.read { db in
                try Resource.fetchAll(db, sql: "SELECT * FROM resource WHERE companyId = ? AND id IN (\(rows.map { _ in "?" }.joined(separator: ", "))) ORDER BY number",
                                      arguments: StatementArguments([companyId]) + StatementArguments(rows.map(\.id)))
            }
        } catch {
            // The resources are added and announced: the caller gets them as built rather than an error it would retry.
            resourceTrace(companyId: companyId, "Added \(rows.first?.ref ?? "")… but could not read the rows back: \(error)", now: now)
            return rows
        }
    }

    // MARK: Add a link

    /// Adds a link (owner callers only). It is never fetched: only its URL (user and password removed: `ResourceIntake.link`)
    /// is stored, and its host and path are indexed as the title. Trust: owner, unless marked untrusted. Announced like files.
    @discardableResult
    public func addLink(companyId: String, url raw: String, drop: ResourceDrop, contentVault: ContentVault,
                        now: Date = Store.now()) throws -> Resource {
        let url = try ResourceIntake.link(raw)
        guard try company(id: companyId) != nil else { throw ResourceError.notFound("no such company") }
        let shown = Self.linkShown(url)
        let resolved = try writer.read { db in try resolveDrop(db: db, companyId: companyId, drop: drop) }
        // Never a number an orphaned vault file holds (the same allocation as file adds; final inside the write).
        let vaultHighest = try contentVault.highestNumber(companyId: companyId)
        func highest(_ db: Database) throws -> Int {
            max(try Int.fetchOne(db, sql: "SELECT MAX(number) FROM resource WHERE companyId = ?", arguments: [companyId]) ?? 0, vaultHighest)
        }
        let untrusted = drop.trust == .untrusted
        var link = Resource(companyId: companyId, number: 0, kind: .link, displayName: ResourceIntake.sanitizeName(shown), url: url,
                            scopeKind: resolved.scope.kind, scopeId: resolved.scope.id, readerSet: resolved.readerSet,
                            futureHolders: resolved.futureHolders,
                            provenance: untrusted ? Provenance.external("owner-marked").raw : Provenance.owner.raw,
                            sourceDetail: URLComponents(string: url)?.host, tainted: untrusted,
                            taintReason: untrusted ? "marked untrusted by you" : nil, vouchedAt: drop.trust == .vouched ? now : nil,
                            addedVia: drop.context.via, channelId: resolved.channelId, askId: resolved.askId,
                            itemId: resolved.itemId, createdAt: now, updatedAt: now)
        let refsOnly = Self.refsOnly(drop)
        // Everyone the announcement reaches must read the link: checked on that exact text before anything is written.
        try writer.read { db in
            link.number = try highest(db) + 1
            let preview = Self.announcement(rows: [link], folder: nil, message: drop.message, refsOnly: refsOnly)
            try checkRecipients(db: db, companyId: companyId, drop: drop, resolved: resolved, announcement: preview)
        }
        try writer.write { db in
            link.number = try highest(db) + 1
            try link.insert(db)
            try ingestResource(db: db, link, text: nil, now: now)
            let label = try Self.scopeLabel(db: db, resolved.scope, companyId: companyId)
            // A link's address is its content: the activity names it by its ref only (a purge can't leave it behind).
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .resource,
                              text: try redact("You added \(Self.linkTag(link.ref)) (\(label))"), createdAt: now).insert(db)
        }
        let text = Self.announcement(rows: [link], folder: nil, message: drop.message, refsOnly: refsOnly)
        let posted = announce(text, drop: drop, resolved: resolved, companyId: companyId, refs: [link.ref], now: now)
        if let posted { link.messageId = posted.id; link.channelId = posted.channelId }
        recordAfterCommit(companyId: companyId, rows: [link], mirrored: [:], posted: posted, now: now)
        do { return try resource(companyId: companyId, number: link.number) ?? link } catch {
            resourceTrace(companyId: companyId, "Added \(link.ref) but could not read it back: \(error)", now: now)
            return link
        }
    }

    // MARK: Queries

    /// The company's resources by number. An agent reader gets only those it can read at `full` (`MemoryAccess`); an agent of
    /// another company is refused (`WorkError.forbidden`). Removed rows are left out; purged ones only with `includePurged`.
    public func resources(companyId: String, reader: Reader, includePurged: Bool) throws -> [Resource] {
        try writer.read { db in
            let ctx = try ReaderContext.load(db: db, catalog: catalog, companyId: companyId, reader: reader)
            var sql = "SELECT * FROM resource WHERE companyId = ? AND removedAt IS NULL"
            if !includePurged { sql += " AND purgedAt IS NULL" }
            sql += " ORDER BY number"
            let rows = try Resource.fetchAll(db, sql: sql, arguments: [companyId])
            guard case .agent = reader else { return rows }
            return rows.filter { Self.level(ctx, $0) == .full }
        }
    }

    /// `F-<number>` of this company, or nil (another company's is nil too).
    public func resource(companyId: String, number: Int) throws -> Resource? {
        try writer.read { db in try Self.resource(db: db, companyId: companyId, number: number) }
    }

    static func resource(db: Database, companyId: String, number: Int) throws -> Resource? {
        try Resource.fetchOne(db, sql: "SELECT * FROM resource WHERE companyId = ? AND number = ?", arguments: [companyId, number])
    }

    /// The vault bytes of a file resource (the owner's read), verified against its hash. A mismatch →
    /// `ResourceError.integrity("F-<n> changed on disk")` plus an activity line.
    public func readResource(companyId: String, number: Int, contentVault: ContentVault) throws -> Data {
        guard let r = try resource(companyId: companyId, number: number), r.removedAt == nil else {
            throw ResourceError.notFound("no resource F-\(number)")
        }
        guard r.purgedAt == nil else { throw ResourceError.notFound("F-\(number) was purged") }
        guard r.kind == .file, let path = r.vaultPath, let sha = r.sha256 else {
            throw ResourceError.invalid("F-\(number) is a \(r.kind.rawValue); it has no file")
        }
        return try readResourceBytes(r, contentVault: contentVault, now: Store.now(), expected: (path, sha))
    }

    /// One resource as a reader sees it, with the level it reads it at; nil when this company has no such number.
    func resourceForReader(companyId: String, number: Int, reader: Reader) throws -> (resource: Resource, level: AccessLevel)? {
        try writer.read { db in
            let ctx = try ReaderContext.load(db: db, catalog: catalog, companyId: companyId, reader: reader)
            guard let r = try Self.resource(db: db, companyId: companyId, number: number) else { return nil }
            return (r, Self.level(ctx, r))
        }
    }

    /// The orientation's `## New resources` lines for `agent`: resources added after its previous orientation-building turn
    /// (work, notice or plan; review and audit turns build none) STARTED (else after it was hired) that it can read at
    /// `full`, oldest first; purged, removed and flagged ones are left out. The previous turn's orientation was built when
    /// it started, so a drop made while that turn ran is listed now; one made between its
    /// start and its orientation may be listed twice (a repeat is safer than a silent miss). The running turn, whose
    /// orientation this is, has no `endedAt` yet and is not the previous one. A tainted row (or a
    /// file of a tainted folder) shows no name: `- F-<n> · (untrusted) · <kind> — recall(ref: "F-<n>")`; a link never shows
    /// its address: `- F-<n> · link — recall(ref: "F-<n>")`. A copy an agent's share made (`addedVia = share`: a private
    /// snapshot, a redacted copy) is never listed: it is not the owner's, and its share message delivers it (C3b fix round 1).
    func newResourceLines(agent: Agent) throws -> [String] {
        try writer.read { db in
            // Review and audit turns build no orientation, so they never start the window.
            let since = try Date.fetchOne(db, sql: """
                SELECT MAX(startedAt) FROM turn WHERE agentId = ? AND endedAt IS NOT NULL AND kind NOT IN ('review', 'audit')
                """, arguments: [agent.id]) ?? agent.createdAt
            let rows = try Resource.fetchAll(db, sql: """
                SELECT * FROM resource WHERE companyId = ? AND createdAt > ? AND purgedAt IS NULL AND removedAt IS NULL
                  AND secretScan != 'flagged' AND addedVia != 'share' ORDER BY number
                """, arguments: [agent.companyId, since])
            guard !rows.isEmpty else { return [] }
            let ctx = try ReaderContext.load(db: db, catalog: catalog, companyId: agent.companyId, reader: .agent(agent.id))
            // A folder owns its files' trust: a file in a tainted folder shows no name either.
            let parents = Set(rows.compactMap(\.parentId))
            let taintedFolders = parents.isEmpty ? [] : Set(try String.fetchAll(db, sql: """
                SELECT id FROM resource WHERE companyId = ? AND tainted = 1 AND id IN (\(parents.map { _ in "?" }.joined(separator: ", ")))
                """, arguments: StatementArguments([agent.companyId]) + StatementArguments(parents.sorted())))
            return rows.filter { Self.level(ctx, $0) == .full }.map { r in
                let kind = r.kind == .file ? Store.flat(r.fileKind ?? "file", max: 20) : r.kind.rawValue
                var line: String
                if r.tainted || r.parentId.map(taintedFolders.contains) == true {
                    // A name is text an agent or an outside source chose: only the ref and engine-built fields.
                    line = "- \(r.ref) · (untrusted) · \(kind)"
                } else if r.kind == .link {
                    // A link's address is its content: by its ref only.
                    line = "- \(r.ref) · link"
                } else {
                    line = "- \(r.ref) · \"\(Store.flat(r.displayName, max: 60))\" · \(kind) · from the owner"
                }
                line += " — recall(ref: \"\(r.ref)\")"
                if let mirror = r.mirrorPath { line += " · \(Store.flat(mirror, max: 200))" }
                return line
            }
        }
    }

    // MARK: Index

    /// Indexes one resource as a `resource` doc: ref `F-<n>`, title `F-<n> <name>` (a link: its host and path), the stored
    /// text when there is one (never for a flagged file), and the row's access, reader set, future holders, provenance and
    /// taint. A purged or removed row (as stored now) is never indexed again: returns false.
    @discardableResult
    func ingestResource(db: Database, _ r: Resource, text: String?, now: Date) throws -> Bool {
        guard let live = try Resource.fetchOne(db, sql: "SELECT * FROM resource WHERE companyId = ? AND id = ?",
                                               arguments: [r.companyId, r.id]),
              live.purgedAt == nil, live.removedAt == nil else { return false }
        let title = live.kind == .link ? "\(live.ref) \(Self.linkShown(live.url ?? ""))" : "\(live.ref) \(live.displayName)"
        let body = live.secretScan == .flagged ? "" : text.map { String($0.prefix(MemoryPolicy.maxBodyChars)) } ?? ""
        var itemId: String?
        if case .item(let id) = live.scope { itemId = id }
        try ingest(db: db, MemoryIngestDoc(
            companyId: live.companyId, source: .resource, sourceId: live.id, ref: live.ref, title: title, body: body,
            access: live.scope, readerSet: live.readerSet, futureHolders: live.futureHolders,
            provenance: Provenance(raw: live.provenance) ?? .external("unknown"), tainted: live.tainted,
            taintReason: live.taintReason, authorId: "owner", itemId: itemId, createdAt: live.createdAt), now: now)
        return true
    }

    // MARK: Helpers

    static let inboxRefusal = "drop files on a question from an agent"

    /// A drop's scope, reader set and context, checked against the company.
    struct ResolvedDrop {
        var scope: AccessClass
        var readerSet: Set<String>?
        var futureHolders: Bool
        var channelId: String?
        var askId: String?
        var itemId: String?
    }

    /// The drop's scope, reader set and context, checked against the company (who the announcement reaches is checked
    /// separately, on the announcement's exact text: `checkRecipients`).
    func resolveDrop(db: Database, companyId: String, drop: ResourceDrop) throws -> ResolvedDrop {
        if let id = drop.scope.id, id.isEmpty { throw ResourceError.invalid("the scope names nothing") }
        let known = Set(try String.fetchAll(db, sql: "SELECT id FROM agent WHERE companyId = ?", arguments: [companyId]))
        if let given = drop.readerSet, !given.isSubset(of: known) {
            throw ResourceError.invalid("the reader set names an agent outside this company")
        }
        // A caller's reader set never widens the scope: agent and item scopes take the computed set; a channel or DM keeps at
        // most its members now; team, role and company stay dynamic.
        var readers: Set<String>?
        switch drop.scope {
        case .company, .team, .role, .ownerOnly:
            readers = nil
        case .agent, .item:
            readers = try Self.readerSet(db: db, for: drop.scope, companyId: companyId)        // also checks the scope's object
        case .channel, .dm:
            let members = try Self.readerSet(db: db, for: drop.scope, companyId: companyId) ?? []
            readers = drop.readerSet.map { $0.intersection(members) } ?? members
        }
        var futureHolders = false
        if case .item = drop.scope { futureHolders = drop.futureHolders }
        var resolved = ResolvedDrop(scope: drop.scope, readerSet: readers, futureHolders: futureHolders)
        switch drop.context {
        case .library, .cli:
            break
        case .dm(let handle):
            _ = try Self.resourceAgent(db, companyId: companyId, handle: handle)
        case .channel(let name):
            resolved.channelId = try Self.resourceChannel(db, companyId: companyId, name: name).id
        case .item(let id):
            resolved.itemId = try Self.resourceItem(db, companyId: companyId, id: id).id
        case .inbox(let askId):
            resolved.askId = try Self.dropAsk(db, companyId: companyId, askId: askId).ask.id
        }
        return resolved
    }

    /// Everyone `announcement` reaches when it is delivered in the drop's context must read the drop in full: the engine
    /// never sends a resource's name to a non-reader. The recipients are the context's (the DM partner; the channel's agent
    /// members now; what an owner comment notifies: holder, lease holder, reviewer, author and the computed readers; the
    /// question's requester) plus every agent an `@handle` in that exact text names. Engine-inserted names carry no `@`
    /// (`announcedName`), so only the owner's own words can mention. Library and CLI drops are not announced.
    func checkRecipients(db: Database, companyId: String, drop: ResourceDrop, resolved: ResolvedDrop, announcement: String) throws {
        var recipients: Set<String> = []
        let refusal: String
        switch drop.context {
        case .library, .cli:
            return
        case .dm(let handle):
            let agent = try Self.resourceAgent(db, companyId: companyId, handle: handle)
            recipients.insert(agent.id)
            refusal = "@\(agent.name)"
        case .channel(let name):
            let channel = try Self.resourceChannel(db, companyId: companyId, name: name)
            recipients.formUnion(try Self.channelAgentIds(db, channelId: channel.id, companyId: companyId))
            refusal = "#\(channel.name)"
        case .item(let id):
            let item = try Self.resourceItem(db, companyId: companyId, id: id)
            recipients.formUnion(try Self.itemReaderIds(db, item: item))
            refusal = item.key
        case .inbox(let askId):
            recipients.insert(try Self.dropAsk(db, companyId: companyId, askId: askId).requester.id)
            refusal = ""
        }
        for handle in MessageRouter.mentions(in: announcement) where handle != "owner" {
            if let id = try String.fetchOne(db, sql: "SELECT id FROM agent WHERE companyId = ? AND name = ?", arguments: [companyId, handle]) {
                recipients.insert(id)
            }
        }
        for id in recipients.sorted() {
            let ctx = try ReaderContext.load(db: db, catalog: catalog, companyId: companyId, reader: .agent(id))
            let level = MemoryAccess.level(ctx, access: resolved.scope, sensitivity: .normal, readerSet: resolved.readerSet,
                                           restrictions: [], futureHolders: resolved.futureHolders)
            guard level == .full else {
                if case .inbox = drop.context { throw ResourceError.invalid(Self.inboxRefusal) }
                throw ResourceError.invalid("\(refusal) can't all read this; change the scope or drop it in a DM")
            }
        }
    }

    /// A pending `info` question from an agent of this company (the only thing an Inbox drop may answer), and its requester.
    private static func dropAsk(_ db: Database, companyId: String, askId: String) throws -> (ask: Ask, requester: Agent) {
        guard let ask = try Ask.fetchOne(db, key: askId), ask.companyId == companyId, ask.kind == .info,
              ask.status == .pendingOwner, let requester = try Agent.fetchOne(db, key: ask.requesterId),
              requester.companyId == companyId
        else { throw ResourceError.invalid(inboxRefusal) }
        return (ask, requester)
    }

    /// Where agents write, for `ResourceIntake.inspect`: every company's workspace, the workspaces root and the data home
    /// (and the database's folder, when that is elsewhere).
    /// A file dropped from inside one is EXTERNAL until the owner vouches for it (`DropTrust`).
    public func agentAreas(paths: BrahmaPaths) throws -> AgentAreas {
        let workspaces = try companies().map { URL(fileURLWithPath: $0.workspacePath, isDirectory: true) }
        return AgentAreas(urls: workspaces + [paths.workspaces, paths.home] + (dataHome.map { [$0] } ?? []))
    }

    /// The vault must not sit inside this company's workspace (agents can read that).
    private func refuseVaultInWorkspace(company: Company, paths: BrahmaPaths) throws {
        let vault = paths.vaultDir.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        let ws = URL(fileURLWithPath: company.workspacePath).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        if vault == ws || vault.hasPrefix(ws + "/") { throw ResourceError.invalid("the vault can't be inside the company workspace") }
    }

    /// The access level of a resource row for a reader.
    static func level(_ ctx: ReaderContext, _ r: Resource) -> AccessLevel {
        MemoryAccess.level(ctx, access: r.scope, sensitivity: .normal, readerSet: r.readerSet, restrictions: [],
                           futureHolders: r.futureHolders)
    }

    /// Mirrored for agents' Bash and Read: a company-scope, untainted, unflagged file.
    static func mirrors(_ r: Resource) -> Bool {
        r.kind == .file && r.scope == .company && !r.tainted && r.secretScan != .flagged
    }

    /// Reads the vault copy; an integrity failure leaves an activity line before it is rethrown.
    func readResourceBytes(_ r: Resource, contentVault: ContentVault, now: Date,
                                   expected: (path: String, sha: String)) throws -> Data {
        do {
            return try contentVault.read(companyId: r.companyId, relativePath: expected.path, expectedSHA256: expected.sha,
                                         maxBytes: r.bytes)
        } catch let error as ResourceError {
            if case .integrity(let message) = error {
                resourceTrace(companyId: r.companyId, "\(message): its vault copy no longer matches the hash recorded when it was added", now: now)
            }
            throw error
        }
    }

    /// The mirror's engine-file alert (an activity line, the owner's DM and the alert ask); a failure to raise it goes to stderr.
    func alertResourceMirror(_ problem: UnsafeEngineFile, companyId: String, now: Date) {
        do { try writer.write { db in try alertEngineFile(db: db, problem, companyId: companyId, now: now) } } catch {
            FileHandle.standardError.write(Data("brahma: could not raise the resource mirror alert (\(problem)): \(error)\n".utf8))
        }
    }

    /// A non-fatal step that failed: an `error` activity line (and stderr when even that fails).
    func resourceTrace(companyId: String, _ text: String, now: Date) {
        FileHandle.standardError.write(Data("brahma: \(text)\n".utf8))
        do {
            try writer.write { db in
                try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .error, text: try redact(text), createdAt: now)
                    .insert(db)
            }
        } catch {
            FileHandle.standardError.write(Data("brahma: could not record that in the activity log: \(error)\n".utf8))
        }
    }

    /// Delivers the announcement by context, each through its own transaction (after the rows committed). Returns the posted
    /// message for a DM or a channel. A failure is traced, never thrown: the resources are already added.
    private func announce(_ text: String, drop: ResourceDrop, resolved: ResolvedDrop, companyId: String, refs: [String],
                          now: Date) -> Message? {
        let router = MessageRouter(store: self)
        do {
            // The recipients again, on exactly the text delivered (its sizes and mirror paths are final only now).
            try writer.read { db in
                try checkRecipients(db: db, companyId: companyId, drop: drop, resolved: resolved, announcement: text)
            }
            switch drop.context {
            case .dm(let handle):
                return try router.sendDM(companyId: companyId, from: .owner, to: handle, text: text, now: now)
            case .channel(let name):
                return try router.post(companyId: companyId, channel: name, from: .owner, text: text, now: now)
            case .inbox(let askId):
                _ = try ownerAnswer(askId: askId, text: text, now: now)
            case .item(let id):
                _ = try commentWorkItem(id: id, by: .owner, text: text, now: now)
            case .library, .cli:
                break
            }
        } catch {
            let shown = refs.count > 1 ? "\(refs[0])…\(refs[refs.count - 1])" : refs.first ?? ""
            resourceTrace(companyId: companyId, "Added \(shown) but could not announce it in the \(drop.context.via): \(error)", now: now)
        }
        return nil
    }

    /// Records the mirror paths and the announcement's message on the rows. Not fatal (the rows are committed and the
    /// announcement delivered; a retry would duplicate both): a failure is traced.
    private func recordAfterCommit(companyId: String, rows: [Resource], mirrored: [String: String], posted: Message?, now: Date) {
        guard !mirrored.isEmpty || posted != nil else { return }
        do { try writer.write { db in
            for r in rows {
                if let path = mirrored[r.id] {
                    try db.execute(sql: "UPDATE resource SET mirrorPath = ?, mirrorSha256 = sha256, updatedAt = ? WHERE companyId = ? AND id = ?",
                                   arguments: [path, now, companyId, r.id])
                }
                if let posted {
                    try db.execute(sql: "UPDATE resource SET messageId = ?, channelId = ?, updatedAt = ? WHERE companyId = ? AND id = ?",
                                   arguments: [posted.id, posted.channelId, now, companyId, r.id])
                }
            }
        } } catch {
            resourceTrace(companyId: companyId, "Added \(rows.first?.ref ?? "") but could not record its mirror or announcement: \(error)", now: now)
        }
    }

    /// An item comment is readable by every agent of the company (`show_work_item` shows recent events), so an item-context
    /// drop whose scope is not the company is announced by refs only.
    static func refsOnly(_ drop: ResourceDrop) -> Bool {
        if case .item = drop.context { return drop.scope != .company }
        return false
    }

    /// The engine's announcement: the owner's words (if any), then one line per file (at most `maxAnnouncedFiles`), or one line
    /// for a folder, or one for a link. A link is always just `[link F-<n>]`: its address is its content (Task 6c fix round
    /// 2), so a purge never has to find it in old messages. `refsOnly`: no display name, size, kind or mirror path, only
    /// `[file F-<n>]`, `[folder F-<n>, k files]` and `[link F-<n>]` (readers open them with recall).
    ///
    /// A name is text an agent or an outside source chose: a tainted row (a folder: any of its files) shows none, only its ref
    /// and engine-built fields (`(untrusted)`, kind, size, the engine's taint reason). Every name shown goes through
    /// `announcedName` (one line, no `@`), so nothing but the owner's own words can @mention anyone.
    static func announcement(rows: [Resource], folder: Resource?, message: String?, refsOnly: Bool = false) -> String {
        var lines: [String] = []
        if let words = message?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty { lines.append(words) }
        if let folder {
            let files = rows.filter { $0.parentId == folder.id }.sorted { $0.number < $1.number }
            var line: String
            if refsOnly {
                line = "[folder \(folder.ref), \(files.count) files]"
            } else if folder.tainted {
                line = "[folder \(folder.ref) · (untrusted) · \(files.count) files · \(ResourceText.size(folder.bytes))]"
            } else {
                line = "[folder \(folder.ref) · \"\(announcedName(folder.displayName, max: 120))\" · \(files.count) files · \(ResourceText.size(folder.bytes))]"
            }
            if let a = files.first, let b = files.last { line += " files \(a.ref)…\(b.ref)" }
            lines.append(line)
            return lines.joined(separator: "\n")
        }
        let shown = rows.prefix(maxAnnouncedFiles)
        for r in shown {
            if refsOnly {
                switch r.kind {
                case .link: lines.append("[link \(r.ref)]")
                case .folder: lines.append("[folder \(r.ref)]")
                case .file: lines.append("[file \(r.ref)] read it: recall(ref: \"\(r.ref)\")")
                }
                continue
            }
            switch r.kind {
            case .link:
                lines.append(linkTag(r.ref))         // its address is its content: readers open it with recall
            case .folder:
                lines.append(r.tainted ? "[folder \(r.ref) · (untrusted) · \(ResourceText.size(r.bytes))]"
                             : "[folder \(r.ref) · \"\(announcedName(r.displayName, max: 120))\" · \(ResourceText.size(r.bytes))]")
            case .file:
                let kind = announcedName(r.fileKind ?? "file", max: 20)
                let size = ResourceText.size(r.bytes)
                var line: String
                if r.tainted {
                    let reason = announcedName(r.taintReason ?? "outside content", max: 120)
                    line = "[file \(r.ref) · \(kind) · \(size) · EXTERNAL: \(reason)] read it: recall(ref: \"\(r.ref)\")"
                } else {
                    line = "[file \(r.ref) · \"\(announcedName(r.displayName, max: 120))\" · \(kind) · \(size) · FROM YOU] read it: recall(ref: \"\(r.ref)\")"
                }
                if let mirror = r.mirrorPath { line += " · also at \(announcedName(mirror, max: 200))" }
                lines.append(line)
            }
        }
        if rows.count > shown.count, let a = rows.dropFirst(shown.count).first, let b = rows.last {
            lines.append("… and \(rows.count - shown.count) more: \(a.ref)…\(b.ref) (search_memory)")
        }
        return lines.joined(separator: "\n")
    }

    /// A name (or other engine-inserted text) as an announcement carries it: one line, cut, with every `@` removed, so a
    /// file, folder or link name can never @mention (wake, or show the drop to) anyone.
    static func announcedName(_ text: String, max: Int) -> String {
        Store.flat(String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "@" && $0 != "\u{FF20}" && $0 != "\u{FE6B}" })),
                   max: max)
    }

    /// How engine-written text (activity, announcements, orientation) names a link: by its ref only, never its address.
    static func linkTag(_ ref: String) -> String { "[link \(ref)]" }

    /// A link as shown: host and path (no scheme, query or fragment).
    static func linkShown(_ url: String) -> String {
        guard let c = URLComponents(string: url), let host = c.host else { return url }
        return host + c.path
    }

    static func cut(_ s: String, _ max: Int) -> String { s.count > max ? String(s.prefix(max)) + "…" : s }

    /// How a scope reads in the owner's activity line.
    static func scopeLabel(db: Database, _ scope: AccessClass, companyId: String) throws -> String {
        switch scope {
        case .company: return "company"
        case .ownerOnly: return "owner only"
        case .team(let t): return "team \(Store.flat(t, max: 60))"
        case .role(let r): return "role \(Store.flat(r, max: 60))"
        case .agent(let id):
            let name = try String.fetchOne(db, sql: "SELECT name FROM agent WHERE id = ? AND companyId = ?", arguments: [id, companyId])
            return "agent @\(name ?? id)"
        case .item(let id):
            let key = try String.fetchOne(db, sql: "SELECT key FROM workItem WHERE id = ? AND companyId = ?", arguments: [id, companyId])
            return "item \(key ?? id)"
        case .channel(let id), .dm(let id):
            let name = try String.fetchOne(db, sql: "SELECT name FROM channel WHERE id = ? AND companyId = ?", arguments: [id, companyId])
            return scope.kind == "dm" ? "dm \(name ?? id)" : "channel #\(name ?? id)"
        }
    }

    private static func resourceAgent(_ db: Database, companyId: String, handle: String) throws -> Agent {
        let name = (handle.hasPrefix("@") ? String(handle.dropFirst()) : handle).lowercased()
        guard let agent = try Agent.filter(Column("companyId") == companyId && Column("name") == name).fetchOne(db) else {
            throw ResourceError.notFound("no agent @\(Store.flat(name, max: 64))")
        }
        return agent
    }

    private static func resourceChannel(_ db: Database, companyId: String, name: String) throws -> Channel {
        let normalized = Store.normalizeChannelName(name)
        guard let channel = try Channel.filter(Column("companyId") == companyId && Column("name") == normalized).fetchOne(db) else {
            throw ResourceError.notFound("no channel #\(Store.flat(normalized, max: 64))")
        }
        return channel
    }

    private static func resourceItem(_ db: Database, companyId: String, id: String) throws -> WorkItem {
        guard let item = try WorkItem.fetchOne(db, key: id), item.companyId == companyId else {
            throw ResourceError.notFound("no such work item")
        }
        return item
    }

    /// A channel's agent members now (never the owner or the engine).
    private static func channelAgentIds(_ db: Database, channelId: String, companyId: String) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: """
            SELECT m.member FROM channelMember m JOIN agent a ON a.id = m.member WHERE m.channelId = ? AND a.companyId = ?
            """, arguments: [channelId, companyId]))
    }

    /// An item's readers now: its holder (owner), its lease holder, its reviewer, its author (an owner comment on the item
    /// notifies the author too) and the holder's manager.
    private static func itemReaderIds(_ db: Database, item: WorkItem) throws -> Set<String> {
        var ids: [String?] = [item.ownerId, item.reviewerId, item.authorId]
        ids += try String.fetchAll(db, sql: "SELECT agentId FROM workLease WHERE itemId = ? AND companyId = ?",
                                   arguments: [item.id, item.companyId]).map(Optional.some)
        if let owner = item.ownerId {
            ids.append(try String.fetchOne(db, sql: "SELECT managerId FROM agent WHERE id = ? AND companyId = ?",
                                           arguments: [owner, item.companyId]))
        }
        let candidates = Set(ids.compactMap { $0 })
        guard !candidates.isEmpty else { return [] }
        return Set(try String.fetchAll(db, sql: """
            SELECT id FROM agent WHERE companyId = ? AND id IN (\(candidates.map { _ in "?" }.joined(separator: ", ")))
            """, arguments: StatementArguments([item.companyId]) + StatementArguments(candidates.sorted())))
    }

    // MARK: Store as secret

    /// `.storeAsSecret(name)`: the one text file of the drop (≤ `ResourcePolicy.secretFileBytes`, read through the vault's
    /// TOCTOU-safe path, valid UTF-8) becomes the secret `name` (`setSecret`, not a test key). No resource is created.
    private func storeDropAsSecret(company: Company, plan: DropPlan, name: String, contentVault: ContentVault,
                                   secretVault: any SecretVault, knownValues: [(name: String, value: String)], now: Date) throws {
        guard plan.items.count == 1, plan.folderName == nil, let item = plan.items.first, item.isText,
              item.bytes <= Int64(ResourcePolicy.secretFileBytes) else {
            throw ResourceError.invalid("only one text file of up to 64 KB can be stored as a secret")
        }
        guard SecretName.isValid(name) else {
            throw ResourceError.invalid("\(Store.flat(name, max: 64)) is not a valid secret name (A–Z, 0–9 and _, starting with a letter)")
        }
        let verified = try contentVault.verifiedBytes(item: item, maxBytes: Int64(ResourcePolicy.secretFileBytes), knownValues: knownValues)
        guard let value = String(data: verified.data, encoding: .utf8) else {
            throw ResourceError.invalid("\(item.displayName) isn't UTF-8 text, so it can't be stored as a secret")
        }
        try setSecret(companyId: company.id, name: name, value: value, isTest: false, vault: secretVault, now: now)
        try writer.write { db in
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .resource,
                              text: try redact("You stored \"\(Store.flat(item.displayName, max: 120))\" as the secret \(name); no resource was added"),
                              createdAt: now).insert(db)
        }
    }
}

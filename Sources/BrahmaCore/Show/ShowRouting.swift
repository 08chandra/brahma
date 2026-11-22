import Foundation
import GRDB

/// What the owner asked for: something shown, or something explained ("Ask to explain" on a ref; design §2.4).
public enum ShowKind: String, Codable, Sendable, DatabaseValueConvertible {
    case show, explain
}

/// Who answers an owner's show request: the concierge (Brahma), or one agent.
public enum ShowTarget: Equatable, Sendable {
    case concierge
    case agent(String)
}

/// A target with the reason the owner sees on the ASK row, and whether the agent is busy (its answer waits for its turn).
public struct RoutedTarget: Equatable, Sendable {
    public var target: ShowTarget
    /// Engine-composed: `"reviewer of ENG-142; @eng-3 is busy"`, `"quick answer"`.
    public var reason: String
    public var busy: Bool

    public init(target: ShowTarget, reason: String, busy: Bool) { self.target = target; self.reason = reason; self.busy = busy }
}

/// Plan C Task C4c: who answers an Ask (design §2.3), by plain code. The first rule that applies:
/// 1. an `@handle` the owner named (`explicitHandle`);
/// 2. the top item hit: its lease holder only if sleeping or ready, else its reviewer, else the last agent to commit on it, else
///    the holder (busy);
/// 3. the top file hit: the same rule through the open item whose `touchPaths` cover the file, else the most recent recorded
///    (engine) commit author on the path;
/// 4. the top artifact or resource hit: its publisher;
/// 5. the top KB hit: its page owner;
/// 6. otherwise the concierge (never an executive by default).
/// Rules 2–5 apply only to an explanation: `kind == .explain` (an attached ref is then the subject) or a stripped query that
/// starts with `why`, `how` or `explain`; every other Ask without a handle goes to the concierge. Paused and killed agents are
/// skipped; within each rule, sleeping and ready agents rank above running (or blocked) ones. Every lookup is bound to the
/// company. No reason echoes agent-written text: refs and handles only.
public enum ShowRouting {
    static let explainOpeners: Set<String> = ["why", "how", "explain"]
    public static let conciergeReason = "quick answer"
    static let explicitPrefix = "you asked @"

    public static func target(result: ShowResult, kind: ShowKind, explicitHandle: String?, attachedRef: WorkRef?, store: Store,
                              companyId: String) throws -> RoutedTarget {
        if let explicitHandle { return try explicit(explicitHandle, store: store, companyId: companyId) }
        guard explains(result: result, kind: kind) else { return concierge }
        return try ruleTargets(result: result, attachedRef: attachedRef, store: store, companyId: companyId, firstOnly: true).first ?? concierge
    }

    /// The Tab cycle: Brahma, then the top two agents the rules name (each rule's choice, distinct), whatever the query says.
    public static func alternatives(result: ShowResult, kind: ShowKind, attachedRef: WorkRef?, store: Store,
                                    companyId: String) throws -> [RoutedTarget] {
        var out = [concierge]
        var seen = Set<String>()
        for t in try ruleTargets(result: result, attachedRef: attachedRef, store: store, companyId: companyId, firstOnly: false) {
            guard case .agent(let id) = t.target, seen.insert(id).inserted else { continue }
            out.append(t)
            if out.count == 3 { break }
        }
        return out
    }

    static var concierge: RoutedTarget { RoutedTarget(target: .concierge, reason: conciergeReason, busy: false) }

    /// Whether the owner chose this target (`routedBy = owner`): the explicit-handle reason.
    static func isOwnerRouted(_ t: RoutedTarget) -> Bool { t.reason.hasPrefix(explicitPrefix) }

    static func explains(result: ShowResult, kind: ShowKind) -> Bool {
        if kind == .explain { return true }
        let first = result.stripped.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }).first.map(String.init)
        return first.map(explainOpeners.contains) ?? false
    }

    static func idle(_ a: Agent) -> Bool { a.state == .sleeping || a.state == .ready }
    static func usable(_ a: Agent?) -> Agent? { a.flatMap { !$0.paused && $0.state != .killed ? $0 : nil } }

    private static func explicit(_ raw: String, store: Store, companyId: String) throws -> RoutedTarget {
        let h = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let handle = h.hasPrefix("@") ? String(h.dropFirst()) : h
        guard RefGrammar.isHandle(handle),
              let agent = try store.writer.read({ db in
                  try Agent.fetchOne(db, sql: "SELECT * FROM agent WHERE companyId = ? AND name = ?", arguments: [companyId, handle])
              }) else { throw WorkError.notFound("there is no @\(RefGrammar.isHandle(handle) ? handle : "agent") in this company") }
        guard usable(agent) != nil else {
            throw WorkError.invalid("@\(agent.name) is \(agent.state == .killed ? "no longer in the company" : "paused"); ask someone else")
        }
        return RoutedTarget(target: .agent(agent.id), reason: explicitPrefix + agent.name, busy: !idle(agent))
    }

    /// Each rule's choice, in rule order (only the first when `firstOnly`).
    private static func ruleTargets(result: ShowResult, attachedRef: WorkRef?, store: Store, companyId: String,
                                    firstOnly: Bool) throws -> [RoutedTarget] {
        let subjects: [WorkRef] = attachedRef.map { [$0] } ?? result.hits.filter { !$0.inlineOnly }.map(\.ref)
        func first(_ kinds: Set<WorkRefKind>) -> WorkRef? { subjects.first { kinds.contains($0.kind) } }
        // Fix round 1 (M2): the file's newest commits on `main` are read from git before (never inside) the read transaction.
        let fileShas = try first([.file]).map { try recentCommits(store: store, companyId: companyId, path: $0.id) } ?? []
        return try store.writer.read { db in
            var out: [RoutedTarget] = []
            func agent(_ id: String?) throws -> Agent? {
                guard let id, id != "owner" else { return nil }
                return usable(try Agent.fetchOne(db, sql: "SELECT * FROM agent WHERE companyId = ? AND id = ?", arguments: [companyId, id]))
            }
            // 2. Items (a diff names its item).
            if let ref = first([.item, .diff]), let item = try RefAccess.item(db, companyId, ref.id),
               let t = try itemRule(db, item: item, agent: agent) {
                out.append(t)
                if firstOnly { return out }
            }
            // 3. Files.
            if let ref = first([.file]) {
                var picked: RoutedTarget?
                let covering = try WorkItem.fetchAll(db, sql: """
                    SELECT * FROM workItem WHERE companyId = ? AND status != 'done' ORDER BY updatedAt DESC, number DESC
                    """, arguments: [companyId]).filter { i in
                        !i.touchPaths.isEmpty && i.touchPaths.contains { PathOverlap.overlaps(path: $0, ref.id) }
                    }
                for item in covering {
                    if let t = try itemRule(db, item: item, agent: agent) { picked = t; break }
                }
                if picked == nil, let author = try lastCommitAuthor(db, companyId: companyId, shas: fileShas),
                   let a = try agent(author) {
                    picked = RoutedTarget(target: .agent(a.id), reason: "made the last commit on this file", busy: !idle(a))
                }
                if let picked {
                    out.append(picked)
                    if firstOnly { return out }
                }
            }
            // 4. Artifacts and resources: the publisher.
            if let ref = first([.artifact, .resource]), let n = Int(ref.id) {
                var publisher: String?
                if ref.kind == .artifact {
                    publisher = try String.fetchOne(db, sql: "SELECT publishedById FROM artifact WHERE companyId = ? AND number = ?",
                                                    arguments: [companyId, n])
                } else if let raw = try String.fetchOne(db, sql: "SELECT provenance FROM resource WHERE companyId = ? AND number = ?",
                                                        arguments: [companyId, n]),
                          case .agent(let id)? = Provenance(raw: raw) {
                    publisher = id
                }
                if let a = try agent(publisher) {
                    out.append(RoutedTarget(target: .agent(a.id), reason: "published \(ref.canonical)", busy: !idle(a)))
                    if firstOnly { return out }
                }
            }
            // 5. Handbook pages: the page owner.
            if let ref = first([.kb]),
               let owner = try String.fetchOne(db, sql: "SELECT ownerId FROM kbPage WHERE companyId = ? AND path = ?",
                                               arguments: [companyId, ref.id]),
               let a = try agent(owner) {
                out.append(RoutedTarget(target: .agent(a.id), reason: "owns this handbook page", busy: !idle(a)))
            }
            return out
        }
    }

    /// Rule 2 for one item: the holder only when idle; else the reviewer or the last committer (idle ones first); else the
    /// busy holder. Nil when nobody usable is left.
    private static func itemRule(_ db: Database, item: WorkItem, agent: (String?) throws -> Agent?) throws -> RoutedTarget? {
        let holder = try agent(try Store.leaseHolderId(db: db, itemId: item.id))
        if let holder, idle(holder) {
            return RoutedTarget(target: .agent(holder.id), reason: "holds \(item.key)", busy: false)
        }
        let busyNote = holder.map { "; @\($0.name) is busy" } ?? ""
        let committerId = try String.fetchOne(db, sql: """
            SELECT agentId FROM turnCommit WHERE companyId = ? AND itemId = ? ORDER BY createdAt DESC, rowid DESC LIMIT 1
            """, arguments: [item.companyId, item.id])
        var others: [(Agent, String)] = []
        if let r = try agent(item.reviewerId), r.id != holder?.id { others.append((r, "reviewer of \(item.key)")) }
        if let c = try agent(committerId), c.id != holder?.id, !others.contains(where: { $0.0.id == c.id }) {
            others.append((c, "last committed on \(item.key)"))
        }
        if let pick = others.first(where: { idle($0.0) }) ?? others.first {
            return RoutedTarget(target: .agent(pick.0.id), reason: pick.1 + busyNote, busy: !idle(pick.0))
        }
        if let holder { return RoutedTarget(target: .agent(holder.id), reason: "holds \(item.key); busy", busy: true) }
        return nil
    }

    /// The newest 20 commits on `main` that touched `path` (none when git can't be read). Git, outside any transaction.
    private static func recentCommits(store: Store, companyId: String, path: String) throws -> [String] {
        guard RefGrammar.isPath(path), let company = try store.company(id: companyId),
              let git = try? store.refGit(URL(fileURLWithPath: company.workspacePath, isDirectory: true)),
              let main = try? git.head("main"), let shas = try? git.logShas(range: main, path: path, max: 20) else { return [] }
        return shas
    }

    /// The agent the engine recorded (C4b's `turnCommit`) for the newest of `shas` that has a record; nil when none has.
    private static func lastCommitAuthor(_ db: Database, companyId: String, shas: [String]) throws -> String? {
        for sha in shas {
            if let id = try String.fetchOne(db, sql: "SELECT agentId FROM turnCommit WHERE companyId = ? AND sha = ?", arguments: [companyId, sha]) {
                return id
            }
        }
        return nil
    }
}

/// The engine's candidates for a show request, re-resolved for its target (design §2.3): what the target can't read in full
/// is dropped and only counted (`"<n> more the owner can see"`). Each line is `<canonical> "<title>"`, built as shown (the
/// display pipeline with the inert mapping) and then gated as that final string against the stored values (Rulings 53–55);
/// a line holding a value is left out (not counted: the count is of access alone); a tainted source shows no title.
/// Beyond the brief's signature: `companyId` (hits carry no company) and `gate` (the stored values are required).
public enum ShowCandidates {
    public static func moreLine(_ n: Int) -> String { "\(n) more the owner can see" }

    public static func lines(result: ShowResult, for reader: Reader, store: Store, companyId: String, gate: GlobalSearch.TextGate,
                             limit: Int = ConciergeCaps.maxCandidates) throws -> (lines: [String], hiddenCount: Int) {
        var lines: [String] = []
        var hidden = 0
        var seen = Set<String>()
        for hit in result.hits where !hit.inlineOnly && seen.insert(hit.ref.canonical).inserted {
            let resolved: ResolvedRef
            do { resolved = try store.resolveRef(hit.ref, for: reader, companyId: companyId) } catch { hidden += 1; continue }
            guard resolved.visibility == .full else { hidden += 1; continue }
            guard lines.count < limit else { continue }
            let raw = hit.ref.canonical
            guard !gate.holdsSecret(raw), let canonical = gate.final(raw, max: RefGrammar.maxLength, inert: true) else { continue }
            let shownRef = canonical.contains(where: { $0.isWhitespace }) ? "\"\(canonical)\"" : canonical
            var line = shownRef
            // A tainted source shows its ref only (no title a session that read outside content may have written).
            if !resolved.tainted, let title = gate.final(resolved.title, max: SafeTitle.max, inert: true), !title.isEmpty, title != canonical {
                line += " \"\(title)\""
            }
            if gate.holdsSecret(line) { line = shownRef }
            guard !gate.holdsSecret(line) else { continue }
            lines.append(line)
        }
        if hidden > 0 { lines.append(moreLine(hidden)) }
        return (lines, hidden)
    }
}

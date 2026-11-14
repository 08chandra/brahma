import Foundation
import GRDB

/// Episodic memory (Plan ML): engine-recorded `memoryEntry` rows, never an LLM turn. At the end of each successful work,
/// notice or review turn, the turn's summary becomes an `episode` private to its agent; when an item is done, its owner gets
/// one more. Each is indexed at once as a `memory` doc whose title is engine text only (`Episode <time> <KEY|no item>`), the
/// only part a manager's summary-level read matches. Recording never fails the turn end or the completion it rides on, but a
/// failure is never silent: it leaves an `error` activity line (`nonFatal`).
public enum EpisodeRecorder {
    /// The longest episode fact, in characters.
    public static let maxChars = 600

    /// At a turn's end, in the transaction that records it and before any fresh-session reset: `taint` is `currentTaint`
    /// read before that reset. Only `work`, `notice` and `review` turns that succeeded, were not infra failures and left a
    /// non-empty summary are recorded.
    static func turnEnded(db: Database, turn: Turn, agent: Agent, itemKey: String?, taint: String?, now: Date) throws {
        guard [.work, .notice, .review].contains(turn.kind), turn.outcome == .succeeded, !turn.infra else { return }
        let summary = Store.flattened(turn.summary ?? "")
        guard !summary.isEmpty else { return }
        let subject = itemKey ?? "no item"
        try record(db: db, companyId: agent.companyId, agentId: agent.id, prefix: "\(subject) · \(turn.kind.rawValue): ",
                   text: summary, subject: subject, itemId: turn.itemId, turnId: turn.id, taint: taint, now: now)
    }

    /// Runs an episode step that must not fail the transaction around it (the turn end, the item completion), inside a
    /// savepoint: a failure leaves nothing of the step behind, and leaves the `error` activity line
    /// `could not record <what>: <error>` in the company's feed, as other non-fatal steps inside a store transaction do. If even
    /// that line cannot be written, the failure goes to the engine's standard error.
    static func nonFatal(db: Database, companyId: String, agentId: String?, what: String, now: Date, _ body: () throws -> Void) {
        do {
            try db.inSavepoint {
                try body()
                return .commit
            }
        } catch {
            let text = String("could not record \(what): \(error)".prefix(500))
            do {
                try ActivityEvent(companyId: companyId, agentId: agentId, turnId: nil, kind: .error, text: text, createdAt: now).insert(db)
            } catch let second {
                FileHandle.standardError.write(Data("brahma: \(text) (and the activity line failed: \(second))\n".utf8))
            }
        }
    }

    /// Writes one episode and indexes it, inside a savepoint (nothing is left behind when it throws). `text` is stored text
    /// the store already redacted (the turn summary `endTurn` wrote, the item title), so the doc goes through
    /// `Store.ingestRedacted`. Callers run it under `nonFatal`.
    static func record(db: Database, companyId: String, agentId: String, prefix: String, text: String, subject: String,
                       itemId: String?, turnId: String?, taint: String?, now: Date) throws {
        var room = maxChars - prefix.count
        var body = text
        if body.count > room {
            room = max(room - 1, 0)
            body = String(body.prefix(room)) + "…"
        }
        let fact = prefix + body
        let reason = taint.map { "written by a session that read \($0)" }
        try db.inSavepoint {
            let number = try MemoryEntry.nextNumber(db: db, companyId: companyId)
            let entry = MemoryEntry(
                id: UUID().uuidString, companyId: companyId, number: number, kind: .episodic, type: .episode, key: nil,
                fact: fact, factHash: MemoryEntry.factHash(fact), accessKind: "agent",
                accessId: agentId, confidence: 1, confirmations: 0, authorId: "system", itemId: itemId, turnId: turnId,
                provenance: Provenance.engine.raw, tainted: taint != nil, taintReason: reason, contradictsId: nil,
                contradictedById: nil, inheritedFromId: nil, expiresActive: nil, createdAt: now, confirmedAt: nil,
                removedAt: nil, purgedAt: nil)
            try entry.insert(db)
            let zone = MemoryIngest.ownerZone(db: db)
            try Store.ingestRedacted(db: db, MemoryIngestDoc(
                companyId: companyId, source: .memory, sourceId: entry.id, ref: entry.ref,
                title: "Episode \(MemoryIngest.stamp(now, zone: zone)) \(subject)", body: entry.fact,
                access: .agent(agentId), provenance: .engine, tainted: entry.tainted, taintReason: reason,
                weight: MemoryPolicy.entryWeight(confidence: 1, confirmations: 0, contradicted: false),
                authorId: "system", itemId: itemId, createdAt: now), now: now)
            return .commit
        }
    }
}

/// At item completion (in the completing transaction): the item's owner gets the episode `Finished <KEY> <title…80>`, plus
/// ` (merged <sha7>)` when the item has a merged commit. Containers (epics, stories) did no work of their own and are skipped,
/// as `OutcomeFactsObserver` does. Never throws: a failed record leaves the completion alone and an `error` activity line.
public struct EpisodeObserver: WorkItemObserver {
    let catalog: PackCatalog

    public init(catalog: PackCatalog = .builtin) { self.catalog = catalog }

    public func itemCompleted(_ item: WorkItem, db: Database) throws {
        guard let ownerId = item.ownerId else { return }
        let now = item.doneAt ?? Store.now()
        EpisodeRecorder.nonFatal(db: db, companyId: item.companyId, agentId: ownerId, what: "the completion episode of \(item.key)",
                                 now: now) {
            guard let company = try Company.fetchOne(db, key: item.companyId) else { return }
            if catalog.pack(company.packId)?.itemType(item.type.rawValue)?.container ?? false { return }
            guard let owner = try Agent.fetchOne(db, key: ownerId), owner.companyId == item.companyId else { return }
            var title = Store.flattened(item.title)
            if title.count > 80 { title = String(title.prefix(79)) + "…" }
            var text = "\(item.key) \(title)"
            if let sha = item.mergedCommit, !sha.isEmpty { text += " (merged \(sha.prefix(7)))" }
            // Engine text about the item; a title written by a session that read outside content keeps that mark.
            let taint: String? = item.taintedOrigin ? "outside content" : nil
            try EpisodeRecorder.record(db: db, companyId: item.companyId, agentId: owner.id, prefix: "Finished ", text: text,
                                       subject: item.key, itemId: item.id, turnId: nil, taint: taint, now: now)
        }
    }
}

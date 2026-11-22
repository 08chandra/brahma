import Foundation
import GRDB

/// Plan C Task C4a fix round 4 (Ruling 57): the vault-blanked shadow of company memory (`memoryShadow`, indexed by
/// `memoryShadowFts`; migration `vC-memory-shadow`). Each doc's shadow is its title and body as a reader sees them, with
/// every stored value blanked (`GlobalSearch.TextGate.matchText`). Agent-facing search matches, ranks, counts and checks
/// only against it (`MemoryText.visible`), so no stored value, whenever it was stored, ever decides what a search answers.
///
/// The values live in the vault, which only the searching side reads, so the shadow is kept current there, with the exact
/// values the search gates with, before every read (`sync`):
/// - a doc whose text changed (or a new one) is queued in `memoryShadowPending` by a trigger, which also drops its old shadow
///   row at once, and is blanked on the next search;
/// - when the company's set of stored values changed (a secret added, rotated or removed: `memoryShadowState.valueKey`, made
///   of the secrets' ids, names and change times, never a value or a hash of one), or the gate holds a different set than the
///   one this process last blanked for, every doc of the company is blanked again (only rows whose shadow changes are
///   written);
/// - a gate that lacks a stored secret's value blanks for what it has and records a key that is never current, so the next
///   complete search blanks everything again.
enum MemoryShadow {
    /// A shadow that no longer matches the doc's text as the gate blanks it now (a vault changed behind the engine's back).
    struct Stale: Error {}

    /// The shadow text of `raw`: its display form with every stored value blanked ("" when a value can't be located).
    static func blanked(_ raw: String, gate: GlobalSearch.TextGate) -> String { gate.matchText(raw) }

    /// The key of the value set the shadow is blanked for: the company's stored secrets (ids, names, change times) and the
    /// names the gate holds values for; prefixed `partial:` (never written by a complete gate) when the gate lacks one.
    static func valueKey(db: Database, companyId: String, gate: GlobalSearch.TextGate) throws -> String {
        let metas = try Row.fetchAll(db, sql: "SELECT id, name, updatedAt FROM secret WHERE companyId = ? ORDER BY name, id",
                                     arguments: [companyId])
        let stored = metas.map { row -> String in
            let at: Date = row["updatedAt"]
            return "\(row["id"] as String)\u{0}\(row["name"] as String)\u{0}\(Int64((at.timeIntervalSince1970 * 1000).rounded()))"
        }
        let held = Set(gate.expanded.map(\.name))
        let complete = metas.allSatisfy { held.contains($0["name"] as String) }
        return (complete ? "v1:" : "partial:") + StableHash.fnv1a64(stored.joined(separator: "\u{1}"))
            + ":" + StableHash.fnv1a64(held.sorted().joined(separator: "\u{1}"))
    }

    /// Brings the company's shadow up to date with `gate` (see the type). `force` blanks every doc again.
    static func sync(store: Store, companyId: String, gate: GlobalSearch.TextGate, force: Bool = false) throws {
        let memo = store.memoryShadowMemo
        if !force {
            let upToDate = try store.writer.read { db -> Bool in
                let key = try valueKey(db: db, companyId: companyId, gate: gate)
                guard try String.fetchOne(db, sql: "SELECT valueKey FROM memoryShadowState WHERE companyId = ?", arguments: [companyId]) == key,
                      memo.matches(companyId, key: key, fingerprint: gate.fingerprint) else { return false }
                return try Int.fetchOne(db, sql: "SELECT 1 FROM memoryShadowPending WHERE companyId = ? LIMIT 1", arguments: [companyId]) == nil
            }
            if upToDate { return }
        }
        let key = try store.writer.write { db -> String in
            let key = try valueKey(db: db, companyId: companyId, gate: gate)
            let stored = try String.fetchOne(db, sql: "SELECT valueKey FROM memoryShadowState WHERE companyId = ?", arguments: [companyId])
            if force || stored != key || !memo.matches(companyId, key: key, fingerprint: gate.fingerprint) {
                var after: Int64 = 0
                while true {
                    let rows = try Row.fetchAll(db, sql: """
                        SELECT d.id, d.title, d.body, s.title AS shadowTitle, s.body AS shadowBody FROM memoryDoc d
                        LEFT JOIN memoryShadow s ON s.docId = d.id
                        WHERE d.companyId = ? AND d.id > ? ORDER BY d.id LIMIT 500
                        """, arguments: [companyId, after])
                    for row in rows { try write(db, row, companyId: companyId, gate: gate) }
                    guard let last = rows.last else { break }
                    after = last["id"]
                }
                try db.execute(sql: "DELETE FROM memoryShadowPending WHERE companyId = ?", arguments: [companyId])
            } else {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT p.docId, d.id, d.title, d.body, s.title AS shadowTitle, s.body AS shadowBody FROM memoryShadowPending p
                    LEFT JOIN memoryDoc d ON d.id = p.docId AND d.companyId = p.companyId
                    LEFT JOIN memoryShadow s ON s.docId = p.docId
                    WHERE p.companyId = ?
                    """, arguments: [companyId])
                for row in rows {
                    if row["id"] as Int64? != nil { try write(db, row, companyId: companyId, gate: gate) }
                    try db.execute(sql: "DELETE FROM memoryShadowPending WHERE docId = ?", arguments: [row["docId"] as Int64])
                }
            }
            try db.execute(sql: """
                INSERT INTO memoryShadowState (companyId, valueKey) VALUES (?, ?)
                ON CONFLICT(companyId) DO UPDATE SET valueKey = excluded.valueKey
                """, arguments: [companyId, key])
            return key
        }
        memo.record(companyId, key: key, fingerprint: gate.fingerprint)
    }

    /// One doc's shadow from its row (`id`, `title`, `body`, and its current `shadowTitle`/`shadowBody`, nil when it has none):
    /// written only when it changes. Never `INSERT OR REPLACE` (a replace skips `memoryShadow_ad`, orphaning FTS terms).
    private static func write(_ db: Database, _ row: Row, companyId: String, gate: GlobalSearch.TextGate) throws {
        let id: Int64 = row["id"]
        let title = blanked(row["title"], gate: gate), body = blanked(row["body"], gate: gate)
        let oldTitle: String? = row["shadowTitle"], oldBody: String? = row["shadowBody"]
        if oldTitle == nil || oldBody == nil {
            try db.execute(sql: "DELETE FROM memoryShadow WHERE docId = ?", arguments: [id])
            try db.execute(sql: "INSERT INTO memoryShadow (docId, companyId, title, body) VALUES (?, ?, ?, ?)",
                           arguments: [id, companyId, title, body])
        } else if oldTitle != title || oldBody != body {
            try db.execute(sql: "UPDATE memoryShadow SET title = ?, body = ? WHERE docId = ?", arguments: [title, body, id])
        }
    }
}

/// What this process last blanked each company's shadow for: the value key and the gate's own fingerprint (in memory only),
/// so a gate holding different values under the same stored secrets (a vault changed outside the engine) blanks again.
final class MemoryShadowMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var synced: [String: (key: String, fingerprint: String)] = [:]

    /// True when nothing is remembered for the company (another process blanked it: its stored key decides).
    func matches(_ companyId: String, key: String, fingerprint: String) -> Bool {
        lock.withLock { synced[companyId].map { $0.key == key && $0.fingerprint == fingerprint } ?? true }
    }

    func record(_ companyId: String, key: String, fingerprint: String) {
        lock.withLock { synced[companyId] = (key, fingerprint) }
    }
}

import Foundation
import GRDB

extension Store {
    // MARK: Ingest

    /// Indexes one doc: the upsert every memory source goes through (ML's own ingest, M's analytics and 7's mail). Returns the
    /// doc's id. See `ingest(db:_:now:)`.
    @discardableResult
    public func ingest(_ doc: MemoryIngestDoc, now: Date) throws -> Int64 {
        try writer.write { db in try ingest(db: db, doc, now: now) }
    }

    /// In-transaction `ingest`. The title and body go through the redactor (fail closed: `secretsNotLoaded` until it has
    /// loaded); the title is flattened to one line of at most `MemoryPolicy.maxTitleChars`, the body capped at
    /// `MemoryPolicy.maxBodyChars`. The write is `INSERT … ON CONFLICT(companyId, source, sourceId) DO UPDATE`, never
    /// `INSERT OR REPLACE` (a replace deletes without firing `memoryDoc_ad`, orphaning the old text in `memoryFts`). When every
    /// stored column is already equal nothing is written at all. A live re-ingest clears `removedAt`: an upsert means the
    /// source object exists again (a kb section deleted and later restored is searchable again). Sources that must stay gone
    /// (owner-deleted memory entries, purged resources) are gated by their own source rows and never re-ingested;
    /// `removeMemoryDoc` is the one removal path.
    @discardableResult
    func ingest(db: Database, _ doc: MemoryIngestDoc, now: Date) throws -> Int64 {
        var redacted = doc
        redacted.title = try redact(doc.title)
        redacted.body = try redact(doc.body)
        return try Self.ingestRedacted(db: db, redacted, now: now)
    }

    /// `ingest(db:_:now:)` for a doc whose title and body are already redacted text (an episode built from a stored turn
    /// summary, which `endTurn` redacted): the same flattening, caps and upsert, without the store's redactor.
    @discardableResult
    static func ingestRedacted(db: Database, _ doc: MemoryIngestDoc, now: Date) throws -> Int64 {
        let title = String(Self.flattened(doc.title).prefix(MemoryPolicy.maxTitleChars))
        let body = String(doc.body.prefix(MemoryPolicy.maxBodyChars))
        let readerSet = try doc.readerSet.map { try Self.json($0.sorted()) }
        let restrictions = try Self.json(doc.restrictions.map { $0.sorted() })
        let values: [String: (any DatabaseValueConvertible)?] = [
            "ref": doc.ref, "title": title, "body": body, "accessKind": doc.access.kind, "accessId": doc.access.id,
            "readerSet": readerSet, "futureHolders": doc.futureHolders, "sensitivity": doc.sensitivity.rawValue,
            "restrictions": restrictions, "provenance": doc.provenance.raw, "tainted": doc.tainted, "taintReason": doc.taintReason,
            "weight": doc.weight, "authorId": doc.authorId, "itemId": doc.itemId, "expiresActive": doc.expiresActive,
            // A removed doc is never "unchanged": the re-ingest brings it back.
            "removedAt": nil,
        ]
        let columns = values.keys.sorted()

        if let existing = try Row.fetchOne(db, sql: """
            SELECT id, \(columns.joined(separator: ", ")) FROM memoryDoc WHERE companyId = ? AND source = ? AND sourceId = ?
            """, arguments: [doc.companyId, doc.source.rawValue, doc.sourceId]) {
            let unchanged = columns.allSatisfy { column in
                existing[column] as DatabaseValue == (values[column] ?? nil)?.databaseValue ?? .null
            }
            if unchanged { return existing["id"] }
        }

        let insertColumns = ["companyId", "source", "sourceId"] + columns + ["createdAt", "updatedAt"]
        var list: [(any DatabaseValueConvertible)?] = [doc.companyId, doc.source.rawValue, doc.sourceId]
        list += columns.map { values[$0] ?? nil }
        list += [doc.createdAt, now]
        let arguments = StatementArguments(list)
        try db.execute(sql: """
            INSERT INTO memoryDoc (\(insertColumns.joined(separator: ", ")))
            VALUES (\(Array(repeating: "?", count: insertColumns.count).joined(separator: ", ")))
            ON CONFLICT(companyId, source, sourceId) DO UPDATE SET
            \((columns + ["updatedAt"]).map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
            """, arguments: arguments)
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM memoryDoc WHERE companyId = ? AND source = ? AND sourceId = ?",
                                          arguments: [doc.companyId, doc.source.rawValue, doc.sourceId])
        else { throw StoreError.notFound }
        return id
    }

    /// Marks a doc removed: it is no longer searched or read. Its text stays until a purge (Task 6c,
    /// `Store.purgeMemoryDocs`). Returns whether a live doc was removed.
    @discardableResult
    public func removeMemoryDoc(companyId: String, source: MemorySource, sourceId: String, now: Date) throws -> Bool {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE memoryDoc SET removedAt = ? WHERE companyId = ? AND source = ? AND sourceId = ? AND removedAt IS NULL
                """, arguments: [now, companyId, source.rawValue, sourceId])
            return db.changesCount > 0
        }
    }

    /// A recall refreshes the doc's ranking age (`MemoryPolicy.recency` reads `max(updatedAt, lastRecalledAt)`).
    public func markRecalled(companyId: String, docId: Int64, now: Date) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE memoryDoc SET lastRecalledAt = ? WHERE companyId = ? AND id = ?",
                           arguments: [now, companyId, docId])
        }
    }

    /// Records that an agent read these docs (purge reports who saw what).
    public func recordRead(companyId: String, docIds: [Int64], agentId: String, turnId: String?, via: MemoryReadVia,
                           now: Date) throws {
        guard !docIds.isEmpty else { return }
        try writer.write { db in
            for docId in docIds {
                try db.execute(sql: """
                    INSERT INTO memoryRead (companyId, docId, agentId, turnId, via, readAt) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [companyId, docId, agentId, turnId, via.rawValue, now])
            }
        }
    }

    // MARK: Helpers

    /// One line: every run of whitespace or control characters becomes a single space.
    static func flattened(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control {
                pendingSpace = true
            } else {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

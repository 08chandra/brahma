import Foundation
import GRDB

extension Store {
    /// Keeps only the latest doctor report.
    public func saveProbe(_ report: DoctorReport) throws {
        let json = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO engineProbe(id, report, checkedAt) VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET report = excluded.report, checkedAt = excluded.checkedAt
                """, arguments: [json, report.checkedAt])
        }
    }

    public func latestProbe() throws -> DoctorReport? {
        try writer.read { db in
            guard let json = try String.fetchOne(db, sql: "SELECT report FROM engineProbe WHERE id = 1") else { return nil }
            return try? JSONDecoder().decode(DoctorReport.self, from: Data(json.utf8))
        }
    }
}

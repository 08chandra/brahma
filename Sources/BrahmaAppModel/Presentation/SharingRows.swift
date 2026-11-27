import Foundation
import BrahmaCore

/// One row of the ACTIVITY panel's SHARING filter (collab design §4.7): WHEN, FROM, TO, REF, RESULT and SESSION (tainted?).
public struct SharingRow: Equatable, Sendable, Identifiable {
    public var when: String
    public var from: String
    public var to: String
    public var ref: String
    public var result: String
    public var session: String
    /// For ordering (newest first).
    public var at: Date
    public var id: String

    public init(when: String, from: String, to: String, ref: String, result: String, session: String, at: Date, id: String) {
        self.when = when; self.from = from; self.to = to; self.ref = ref; self.result = result; self.session = session; self.at = at; self.id = id
    }
}

public enum SharingRows {
    static let share = try! NSRegularExpression(pattern: "^(@[A-Za-z0-9_-]+|owner) (shared|attached) (.+) with (\\S+)$")
    static let show = try! NSRegularExpression(pattern: "^show request (\\d+) to (\\S+)")

    /// The sharing rows of `events` (only `.share`, `.access`, `.export` and `.show` kinds; every text is the engine's) plus, when
    /// `reads` is given (the READS toggle), one row per `refRead`. Newest first. `handles` maps agent ids to handles.
    /// `knownValues` are the stored values (from the injected vault; the caller refuses the view when they can't be read): every
    /// string is gated as the final display string (`TextGate.final`, inert), `"(withheld)"` when it holds a value.
    public static func make(events: [ActivityEvent], reads: [RefRead]?, handles: [String: String] = [:], timeZone: TimeZone = .current,
                            knownValues: [(name: String, value: String)]) -> [SharingRow] {
        let gate = GlobalSearch.TextGate(knownValues: knownValues)
        func shown(_ s: String) -> String { s.isEmpty ? "" : (gate.final(s, max: 400, inert: true) ?? "(withheld)") }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var rows: [SharingRow] = []
        for e in events where ActivityFilter.sharing.includes(e.kind) {
            let actor = e.agentId.map { "@" + (handles[$0] ?? $0) } ?? "owner"
            var row = SharingRow(when: f.string(from: e.createdAt), from: actor, to: "", ref: e.text, result: e.kind.rawValue, session: "",
                                 at: e.createdAt, id: "event:\(e.id ?? 0):\(e.createdAt.timeIntervalSince1970)")
            let ns = e.text as NSString
            let range = NSRange(location: 0, length: ns.length)
            switch e.kind {
            case .share:
                if let m = share.firstMatch(in: e.text, range: range) {
                    row.from = ns.substring(with: m.range(at: 1))
                    row.result = ns.substring(with: m.range(at: 2))
                    row.ref = ns.substring(with: m.range(at: 3))
                    row.to = ns.substring(with: m.range(at: 4))
                } else {
                    row.result = "shared"
                }
            case .export:
                row.from = "owner"
                row.to = "disk"
                row.result = "exported"
                if e.text.hasPrefix("ownerExport ") { row.ref = String(e.text.dropFirst("ownerExport ".count)) }
            case .show:
                row.from = "owner"
                row.result = "show request"
                if let m = show.firstMatch(in: e.text, range: range) { row.to = ns.substring(with: m.range(at: 2)) }
                row.ref = ""
            case .access:
                row.result = "access"
            default:
                break
            }
            rows.append(row)
        }
        for r in reads ?? [] {
            let from: String
            switch r.readerKind {
            case "owner": from = "owner"
            case "concierge": from = "Brahma"
            default: from = "@" + (r.readerId.map { handles[$0] ?? $0 } ?? "unknown")
            }
            let ref = r.canonical + (r.rev.map { " @\($0.prefix(7))" } ?? "")
            rows.append(SharingRow(when: f.string(from: r.createdAt), from: from, to: "", ref: ref, result: "read · \(r.via)",
                                   session: r.tainted ? "tainted" : "clean", at: r.createdAt, id: "read:\(r.id)"))
        }
        return rows.map { row in
            var r = row
            r.from = shown(row.from); r.to = shown(row.to); r.ref = shown(row.ref); r.result = shown(row.result); r.session = shown(row.session)
            return r
        }.sorted { $0.at > $1.at }
    }
}

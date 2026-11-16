import Foundation
import BrahmaCore

/// One row of Work › Resources (the owner's library). This is the owner's own view: it shows every name, tainted ones
/// included, and a link's host and path from the live row (engine text names links only by ref). Every value here is text an
/// outside source or an agent may have chosen and is rendered verbatim.
public struct ResourceRow: Equatable, Identifiable, Sendable {
    public var id: String
    /// `F-<n>`.
    public var ref: String
    public var number: Int
    public var kind: ResourceKind
    /// The display name; a link's host and path; `[purged]` once purged.
    public var name: String
    /// `MD`, `PDF` … for a file; `FOLDER`; `LINK`.
    public var kindLabel: String
    /// `8 B`; `<k> files · <size>` for a folder; `—` for a link.
    public var sizeText: String
    /// How the scope reads to the owner (`Store.resourceScopeLabel`): `company`, `team payments`, `agent @eng-1` …
    public var scopeLabel: String
    /// `@a, @b` for a fixed reader set; who it follows otherwise.
    public var readersText: String
    public var trustChip: TrustChip
    /// `REDACTED`, `FLAGGED` or nil.
    public var scanChip: String?
    /// The first 12 hex digits of the stored bytes' SHA-256, or `—`.
    public var sha12: String
    public var mirrorPath: String?
    /// `yyyy-MM-dd HH:mm` in the owner's time zone.
    public var addedText: String
    public var isPurged: Bool
    /// A file of a dropped folder (the folder owns its trust and scope).
    public var parentRef: String?
    /// From the purge report.
    public var purgedBackups = 0
    public var purgedTranscripts = 0

    public var isChild: Bool { parentRef != nil }
    /// Vouch and scope apply to a folder and its files together: never to one file of a folder.
    public var canVouch: Bool { !isPurged && !isChild && trustChip.isExternal }
    public var canChangeScope: Bool { !isPurged && !isChild }
    /// Purge is the owner's leak remedy: one file of a folder can be purged on its own.
    public var canPurge: Bool { !isPurged }
}

public enum ResourcesPresentation {
    /// The library's purge dialog, exactly.
    public static func purgeConfirmText(_ ref: String) -> String {
        "Purge \(ref)? This deletes the file and its search text. Backups and transcripts made since it was added still contain it."
    }

    /// What a purged row still lives in, or nil (not purged, or nothing holds it).
    public static func purgeNote(_ row: ResourceRow) -> String? {
        guard row.isPurged, row.purgedBackups + row.purgedTranscripts > 0 else { return nil }
        return "\(row.purgedBackups) backups and \(row.purgedTranscripts) transcripts contain purged content · delete or re-create"
    }

    /// The scope chip on a pending drop: `SCOPE · @<h> ONLY`, `SCOPE · #<channel> MEMBERS (<n>)`, `SCOPE · <KEY> PEOPLE (<n>)`
    /// (+ ` + FUTURE HOLDERS`), `SCOPE · TEAM <t>`, `SCOPE · COMPANY`. `name` is the handle, channel name, item key or team.
    public static func scopeChip(_ access: AccessClass, name: String, readers: Int, futureHolders: Bool) -> String {
        switch access {
        case .company: return "SCOPE · COMPANY"
        case .team: return "SCOPE · TEAM \(name)"
        case .role: return "SCOPE · ROLE \(name)"
        case .agent: return "SCOPE · @\(name) ONLY"
        case .channel, .dm: return "SCOPE · #\(name) MEMBERS (\(readers))"
        case .item: return "SCOPE · \(name) PEOPLE (\(readers))" + (futureHolders ? " + FUTURE HOLDERS" : "")
        case .ownerOnly: return "SCOPE · OWNER ONLY"
        }
    }

    /// A link as the owner's own view shows it: host and path (no scheme, user, query or fragment), sanitized.
    public static func linkShown(_ url: String) -> String {
        guard let c = URLComponents(string: url), let host = c.host else { return ResourceIntake.sanitizeName(url) }
        return ResourceIntake.sanitizeName(host + c.path)
    }

    static func row(_ r: Resource, scopeLabel: String, handles: [String: String], liveFiles: Int, parentRef: String?,
                    formatter: DateFormatter) -> ResourceRow {
        let purged = r.purgedAt != nil
        let kindLabel: String
        let sizeText: String
        switch r.kind {
        case .link:
            kindLabel = "LINK"; sizeText = "—"
        case .folder:
            kindLabel = "FOLDER"; sizeText = "\(liveFiles) files · \(ResourceText.size(r.bytes))"
        case .file:
            kindLabel = (r.ext.flatMap { $0.isEmpty ? nil : $0 } ?? r.fileKind ?? "file").uppercased()
            sizeText = ResourceText.size(r.bytes)
        }
        var report = PurgeReport()
        if let raw = r.purgeReport, let decoded = try? JSONDecoder().decode(PurgeReport.self, from: Data(raw.utf8)) { report = decoded }
        return ResourceRow(
            id: r.id, ref: r.ref, number: r.number, kind: r.kind, name: purged ? "[purged]" : r.displayName, kindLabel: kindLabel,
            sizeText: sizeText, scopeLabel: scopeLabel, readersText: readers(r, handles: handles),
            trustChip: r.tainted ? .external(reason: r.taintReason ?? "outside content") : .fromYou,
            scanChip: r.secretScan == .redacted ? "REDACTED" : r.secretScan == .flagged ? "FLAGGED" : nil,
            sha12: r.sha256.map { String($0.prefix(12)) } ?? "—", mirrorPath: r.mirrorPath,
            addedText: formatter.string(from: r.createdAt), isPurged: purged, parentRef: parentRef,
            purgedBackups: report.backups.count, purgedTranscripts: report.transcripts.count)
    }

    /// A fixed reader set by handle; otherwise who the scope follows as it changes.
    static func readers(_ r: Resource, handles: [String: String]) -> String {
        var text: String
        if let set = r.readerSet {
            text = set.isEmpty ? "nobody" : set.map { "@" + (handles[$0] ?? $0) }.sorted().joined(separator: ", ")
        } else {
            switch r.scope {
            case .company: text = "everyone in the company"
            case .team(let t): text = "team \(t), as it changes"
            case .role(let role): text = "role \(role), as it changes"
            case .ownerOnly: text = "only you"
            case .agent, .item, .channel, .dm: text = "nobody"
            }
        }
        if r.futureHolders { text += " + future holders" }
        return text
    }
}

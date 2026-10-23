import Foundation
import BrahmaCore

public enum InboxSection: String, Sendable { case pending, fyi, recent }

/// One card in the owner's Inbox. Every string that came from an agent is shown with `Text(verbatim:)` or `SafeMarkdown`.
public struct InboxRow: Equatable, Identifiable, Sendable {
    public var id: String
    /// "A-12".
    public var ref: String
    public var kind: AskKind
    public var section: InboxSection
    /// "Idea / PRD", "Brief & architecture", "Mode boost", ...
    public var kindTitle: String
    public var categoryLabel: String
    /// A reserved category or kind: no autonomy setting ever approves it.
    public var isReserved: Bool
    /// "Low risk", "Medium risk", "High risk".
    public var riskLabel: String
    public var title: String
    public var summary: String
    /// "@eng-1", or "Brahma" for an engine-filed ask.
    public var requester: String
    /// What the internal approver said ("@cto approved: looks fine"), or empty.
    public var internalLine: String
    public var question: String?
    public var documentPath: String?
    /// The document differs from the bytes proposed: approving needs an explicit acknowledgement.
    public var documentChanged: Bool
    public var details: String?
    public var options: [AskOption]
    public var recommendation: String?
    public var stakes: String?
    /// "Can be undone", "One way: can't be undone" or nil when the proposer did not say.
    public var reversibleLabel: String?
    public var proposal: String?
    public var isFYI: Bool
    public var canRescind: Bool
    public var canDecide: Bool
    public var canAnswer: Bool
    public var canAcknowledge: Bool
    /// "Approved by owner", "Approved by policy: Auto", ... for FYIs and recent decisions.
    public var decidedLine: String
    /// The approve button's title: "Merge into main" on Brahma's quarantine ask, whose approval is the owner's accept of
    /// exactly the recorded commit (`Store.ownerDecide`, A2).
    public var approveLabel: String = "Approve"
}

public enum InboxRows {
    public static func riskLabel(_ r: AskRisk) -> String { "\(r.rawValue.capitalized) risk" }

    public static func make(_ work: WorkSnapshot, handles: [String: String]) -> [InboxRow] {
        func handle(_ id: String) -> String {
            if id == "system" { return "Brahma" }
            if id == "owner" { return "you" }
            return "@" + (handles[id] ?? "?")
        }
        func row(_ a: Ask, _ section: InboxSection) -> InboxRow {
            let reserved = a.kind.isReservedKind || ReservedMatters.isReserved(a.category, extra: work.reservedCategories)
            var internalLine = ""
            if let approver = a.internalApproverId, a.internalDecidedAt != nil {
                let note = (a.internalNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                internalLine = "Approved by \(handle(approver))" + (note.isEmpty ? "" : ": \(note)")
            } else if let approver = a.internalApproverId, a.status == .pendingInternal {
                internalLine = "Waiting for \(handle(approver))"
            }
            var decided = ""
            if section != .pending {
                var by = a.decidedBy ?? "owner"
                if by.hasPrefix("@") { by = "@" + (handles[String(by.dropFirst())] ?? String(by.dropFirst())) }
                decided = a.fyi ? "Approved by \(by) (FYI)" : "Approved by \(by)"
            }
            let pending = section == .pending
            let quarantine = Store.quarantineRef(of: a) != nil
            return InboxRow(
                id: a.id, ref: a.ref, kind: a.kind, section: section,
                kindTitle: work.displayTitles[a.id] ?? a.kind.title,
                categoryLabel: (a.category ?? "").capitalized, isReserved: reserved, riskLabel: riskLabel(a.risk),
                title: a.title, summary: a.summary, requester: handle(a.requesterId), internalLine: internalLine,
                question: a.payload?.question, documentPath: a.payload?.documentPath,
                documentChanged: pending && work.changedDocuments.contains(a.id),
                details: a.payload?.details, options: a.payload?.options ?? [], recommendation: a.payload?.recommendation,
                stakes: a.payload?.stakes,
                reversibleLabel: a.payload?.reversible.map { $0 == .oneWay ? "One way: can't be undone" : "Can be undone" },
                proposal: a.payload?.proposal, isFYI: section == .fyi,
                // A merged quarantine is not taken back by rescinding its ask: main has moved.
                canRescind: a.status == .approved && !quarantine,
                canDecide: pending && a.kind.isDecision,
                canAnswer: pending && a.kind == .info,
                canAcknowledge: (pending && a.kind == .engineAlert) || section == .fyi,
                decidedLine: decided,
                approveLabel: quarantine ? "Merge into main" : "Approve")
        }
        return work.inbox.map { row($0, .pending) } + work.fyi.map { row($0, .fyi) } + work.recentDecided.map { row($0, .recent) }
    }
}

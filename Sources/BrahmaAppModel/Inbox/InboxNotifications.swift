import Foundation
import BrahmaCore

/// A banner to show for an ask that has been waiting for the owner without one.
public struct InboxNotification: Equatable, Sendable {
    public var askId: String
    public var companyId: String
    /// Unique per ask and reminder, so a reminder replaces nothing and a repeat tick posts nothing new.
    public var identifier: String
    public var title: String
    public var body: String
}

public enum InboxNotifications {
    public static let maxBody = 140

    /// Asks waiting for the owner that were not notified yet. A reminder clears `notifiedAt`, so it is due again.
    public static func due(_ asks: [Ask]) -> [Ask] {
        asks.filter { $0.status == .pendingOwner && $0.notifiedAt == nil }
    }

    /// One line, no control characters, trimmed to a banner's size. Agent text never keeps its newlines or its markup lines.
    static func flatten(_ text: String, max: Int) -> String {
        let spaced = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        let collapsed = spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= max ? collapsed : String(collapsed.prefix(max - 1)) + "…"
    }

    public static func content(for ask: Ask, companyName: String) -> InboxNotification {
        let kind = ask.kind == .info ? "Question" : ask.kind == .engineAlert ? "Engine alert" : "Needs your decision"
        let title = flatten("\(companyName): \(kind)", max: 80)
        let body = flatten("\(ask.ref) \(ask.title)", max: maxBody)
        return InboxNotification(askId: ask.id, companyId: ask.companyId, identifier: "ask-\(ask.id)-\(ask.remindCount)",
                                 title: title, body: body)
    }
}

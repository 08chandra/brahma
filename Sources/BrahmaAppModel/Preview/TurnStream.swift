import Foundation
import BrahmaCore

/// One line of an agent's turn, embeddable beside a preview or in the agent inspector (L-3). `text` is verbatim agent data.
public struct TurnStreamLine: Equatable, Identifiable, Sendable {
    public var id: Int64
    /// HH:mm:ss.
    public var time: String
    public var kind: ActivityKind
    public var text: String
}

public enum TurnStream {
    public static let maxLines = 200
    static let kinds: Set<ActivityKind> = [.toolUse, .message, .turnStarted, .turnFinished, .error, .usage]

    /// That agent's events of that turn (the stream kinds only), oldest first, the last 200.
    public static func lines(events: [ActivityEvent], agentId: String, turnId: String?, timeZone: TimeZone = .current) -> [TurnStreamLine] {
        guard let turnId else { return [] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm:ss"
        let mine = events.filter { $0.agentId == agentId && $0.turnId == turnId && kinds.contains($0.kind) && $0.id != nil }
            .sorted { $0.id! < $1.id! }
            .suffix(maxLines)
        return mine.map { TurnStreamLine(id: $0.id!, time: f.string(from: $0.createdAt), kind: $0.kind, text: $0.text) }
    }
}

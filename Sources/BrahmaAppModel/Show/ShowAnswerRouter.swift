import Foundation
import BrahmaCore

/// What the app does with a `show` answer (collab design §2.4): open it in the OPENED slot and select it, open it in the
/// background (a badge, plus a notification through 5-lite's batching), or nothing beyond the card in chat. No case asks for
/// keyboard focus: auto-open never takes it from a composer or the Inbox.
public enum AutoOpenDecision: Equatable, Sendable {
    case openAndSelect
    case openInBackground
    case cardOnly

    /// Always false: the decision never requests focus.
    public var requestsFocus: Bool { false }
}

/// The owner's waiting chip for an open request (`AppModel.waitingChips`).
public struct WaitingChip: Equatable, Sendable, Identifiable {
    public var text: String
    public var requestId: String
    public var id: String { requestId }

    public init(text: String, requestId: String) { self.text = text; self.requestId = requestId }
}

public enum ShowAnswerRouter {
    /// No `AutoOpen` (an unsolicited `show`, or an answer with no refs) → `.cardOnly`; the request's waiting chip still showing →
    /// `.openAndSelect`; else `.openInBackground`.
    public static func decide(auto: AutoOpen?, waitingChipVisible: Bool) -> AutoOpenDecision {
        guard auto != nil else { return .cardOnly }
        return waitingChipVisible ? .openAndSelect : .openInBackground
    }
}

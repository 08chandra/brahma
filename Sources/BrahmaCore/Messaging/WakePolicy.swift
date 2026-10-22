import Foundation

/// How a recipient relates to the item an event is about. `owner` is the item's assignee; `holder` its lease holder.
public enum NoticeRecipientRole: Hashable, Sendable { case owner, reviewer, author, holder, waiter, mentioned, other }

/// Who a message wakes. Channel membership is not attention: only direct address (DM, @mention), a reply to someone
/// they wait on, or a permitted `@here`/`@team` broadcast wakes an agent.
public enum WakePolicy {
    public enum Broadcast: Equatable, Sendable { case here, team }

    public static let broadcastsPerHour = 2
    /// Active seconds a manager or executive waits between wakes caused by work notices.
    public static let leadDebounce: TimeInterval = 600

    /// `@here` wins over `@team` when a message carries both.
    public static func broadcast(in text: String) -> Broadcast? {
        let handles = MessageRouter.mentions(in: text)
        if handles.contains("here") { return .here }
        if handles.contains("team") { return .team }
        return nil
    }

    public static func wakes(channel: Channel, sender: Sender, recipient: Agent, mentioned: Bool, broadcast: Broadcast?,
                             senderTeam: String?, blockedOnSender: Bool) -> Bool {
        if sender == .system, channel.kind == .channel { return false }
        if channel.kind == .dm, channel.name.split(separator: ":").dropFirst().contains(where: { $0 == recipient.name }) { return true }
        if mentioned { return true }
        if blockedOnSender { return true }
        switch broadcast {
        case .here?: return true
        case .team?: return recipient.team != nil && recipient.team == senderTeam
        case nil: return false
        }
    }

    /// Whether a work-item event must wake its recipient. Only actionable events do: a review requested
    /// (`verificationPassed` to the reviewer), returned work (`changesRequested`, `verificationFailed`, `mergeConflict` to
    /// the assignee or lease holder), a finished dependency (`dependencyDone` to the one waiting) and a comment that
    /// @mentions the recipient. Everything else (claimed, submitted, passed for non-reviewers, merged, other comments) is
    /// delivered with the next turn and never wakes. Later plans extend the table by kind name.
    public static func noticeWakes(kind: WorkEventKind, recipientRole: NoticeRecipientRole) -> Bool {
        switch kind {
        case .verificationPassed: recipientRole == .reviewer
        case .changesRequested, .verificationFailed, .mergeConflict, .mergeFailed: recipientRole == .owner || recipientRole == .holder
        case .dependencyDone: recipientRole == .waiter
        case .commented: recipientRole == .mentioned
        default: false
        }
    }
}

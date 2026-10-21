import Foundation

/// Who a message wakes. Channel membership is not attention: only direct address (DM, @mention), a reply to someone
/// they wait on, or a permitted `@here`/`@team` broadcast wakes an agent.
public enum WakePolicy {
    public enum Broadcast: Equatable, Sendable { case here, team }

    public static let broadcastsPerHour = 2
    /// Active seconds a manager or executive waits between wakes caused by notices (used from Task 6).
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
}

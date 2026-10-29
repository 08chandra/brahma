import Foundation
import BrahmaCore

public enum SidebarItem: Hashable, Sendable {
    case missionControl, activity, agents
    case backlog, board, inbox
    /// Inbox › Grants (the ledger and presets) and Inbox › Digest.
    case inboxGrants, inboxDigest
    case settingsBackups
    /// Company › Settings: permissions, network, secrets, notifications.
    case companySettings
    case channel(id: String)
    case dm(handle: String)
}

public struct SidebarRow: Equatable, Identifiable, Sendable {
    public var item: SidebarItem
    public var title: String
    public var unread: Int
    public var id: SidebarItem { item }

    public init(item: SidebarItem, title: String, unread: Int) {
        self.item = item
        self.title = title
        self.unread = unread
    }
}

public struct SidebarSections: Equatable, Sendable {
    public var channels: [SidebarRow] = []
    public var directMessages: [SidebarRow] = []
    public var agentConversations: [SidebarRow] = []

    public init() {}

    public init(channels: [Channel], unread: [String: Int]) {
        for c in channels {
            let title = ChannelTitle.title(c)
            let count = unread[c.id] ?? 0
            switch c.kind {
            case .channel:
                self.channels.append(SidebarRow(item: .channel(id: c.id), title: title, unread: count))
            case .dm:
                let handles = c.name.split(separator: ":").dropFirst().map(String.init)
                if handles.contains("owner"), let other = handles.first(where: { $0 != "owner" }) {
                    directMessages.append(SidebarRow(item: .dm(handle: other), title: title, unread: count))
                } else {
                    agentConversations.append(SidebarRow(item: .channel(id: c.id), title: title, unread: count))
                }
            }
        }
    }
}

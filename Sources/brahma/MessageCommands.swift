import ArgumentParser
import Foundation
import BrahmaCore

/// Sender id -> handle for a company, plus the owner.
private func handles(_ store: Store, _ company: Company) throws -> [String: String] {
    var map = ["owner": "owner", "system": "system"]
    for a in try store.agents(companyId: company.id) { map[a.id] = a.name }
    return map
}

private func line(_ m: Message, handles: [String: String]) -> String {
    safe("\(clock(m.createdAt, seconds: true)) @\(handles[m.senderId] ?? m.senderId): \(m.text)")
}

struct Say: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Post as the owner to a #channel or DM an @agent.")

    @Argument var company: String
    @Argument(help: "#channel or @handle.") var target: String
    @Argument(help: "Message text.") var text: String

    func run() throws {
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let router = MessageRouter(store: store)
        do {
            if target.hasPrefix("@") {
                _ = try router.sendDM(companyId: c.id, from: .owner, to: target, text: text)
            } else {
                _ = try router.post(companyId: c.id, channel: target, from: .owner, text: text)
            }
        } catch RouterError.unknownChannel(let name) {
            throw fail("no channel #\(name) in \(c.name)")
        } catch RouterError.unknownAgent(let name) {
            throw fail("no agent @\(name) in \(c.name)")
        }
        print("sent to \(target)")
    }
}

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show recent messages in a #channel or owner DM.")

    @Argument var company: String
    @Argument(help: "#channel or @handle.") var target: String
    @Option(help: "Number of messages (1-1000).") var limit: Int = 30

    func validate() throws {
        guard (1...1000).contains(limit) else { throw ValidationError("--limit must be between 1 and 1000") }
    }

    func run() throws {
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let name: String
        if target.hasPrefix("@") {
            name = "dm:" + ["owner", String(target.dropFirst()).lowercased()].sorted().joined(separator: ":")
        } else {
            name = target
        }
        guard let channel = try store.channel(companyId: c.id, name: name) else {
            throw fail("no such channel or conversation '\(target)' in \(c.name)")
        }
        let map = try handles(store, c)
        for m in try store.messages(channelId: channel.id, limit: limit) { print(line(m, handles: map)) }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Full-text search a company's messages.")

    @Argument var company: String
    @Argument var query: String

    func run() throws {
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let map = try handles(store, c)
        let channels = Dictionary(uniqueKeysWithValues: try store.channels(companyId: c.id).map { ($0.id, $0.name) })
        for m in try store.searchMessages(companyId: c.id, query: query) {
            print(safe("#\(channels[m.channelId] ?? "?") ") + line(m, handles: map))
        }
    }
}

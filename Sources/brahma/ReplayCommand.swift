import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma replay <company> @handle [--day yyyy-MM-dd]` and `brahma replay <company> <KEY>`: an agent's day or an item's
/// history as one timeline (owner only, read-only; Plan ML Task 9). Everything an agent wrote reaches the terminal through
/// `safe()`.
struct ReplayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "replay",
        abstract: "Replay an agent's day or an item's history (owner only).",
        discussion: "With @handle, the agent's turns, tool calls, messages, item events, asks, handbook and memory writes, "
            + "resources announced to it and captured transcripts for one day in your time zone (default today). With an item "
            + "key, the item's events, turns, check runs, asks, handbook revisions, hand-offs and messages naming it. Times are "
            + "in your time zone; at most \(Replay.maxEntries) lines, the newest.")

    @Argument(help: "The company (name or slug).") var company: String
    @Argument(help: "An agent as @handle, or an item key.") var target: String
    @Option(help: "The day to replay for an agent, yyyy-MM-dd in your time zone (default today).") var day: String?

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let tz = store.ownerTimeZone()
        let subject: ReplaySubject
        if target.hasPrefix("@") {
            let agent = try resolveAgent(store, company: c, handle: target)
            let day = self.day ?? Replay.dayString(Date(), tz: tz)
            guard Replay.dayInterval(day, tz: tz) != nil else { throw fail("--day wants a date as yyyy-MM-dd") }
            subject = .agentDay(agentId: agent.id, day: day)
        } else {
            if day != nil { throw fail("--day applies to an agent (@handle), not an item") }
            guard let item = try store.workItem(companyId: c.id, key: target.uppercased()) else {
                throw fail("no work item \(target.uppercased()) in \(c.name)")
            }
            subject = .item(itemId: item.id)
        }
        let entries: [ReplayEntry]
        do { entries = try Replay.timeline(store: store, companyId: c.id, subject: subject, tz: tz) } catch let e as WorkError {
            throw fail(e.message)
        }
        if entries.isEmpty {
            print("nothing to replay")
            return
        }
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.timeZone = tz
        dayFormat.dateFormat = "yyyy-MM-dd"
        var shownDay: String?
        if entries.count == Replay.maxEntries { print("(the newest \(Replay.maxEntries) lines)") }
        for e in entries {
            // An item's history spans days: each new day gets a heading.
            if case .item = subject {
                let d = dayFormat.string(from: e.at)
                if d != shownDay { print("== \(d) =="); shownDay = d }
            }
            var line = "\(clock(e.at, seconds: true))  \(e.kind.label)  @\(e.actor)  \(e.text)"
            if e.kind == .transcript, let turnId = e.turnId { line += " (brahma transcript \(c.slug) \(turnId))" }
            print(safe(line))
        }
    }
}

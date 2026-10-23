import ArgumentParser
import Foundation
import BrahmaCore

/// Runs a store call, turning a refused operation into a plain CLI error.
private func refusing<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let e as WorkError { throw fail(e.message) }
}

private func resolveAsk(_ store: Store, _ company: Company, _ ref: String) throws -> Ask {
    guard let ask = try store.ask(companyId: company.id, ref: ref) else {
        throw fail("no ask \(ref.uppercased().hasPrefix("A-") ? ref.uppercased() : "A-" + ref) in \(company.name)")
    }
    return ask
}

private func block(_ label: String, _ text: String?) {
    guard let text, !text.isEmpty else { return }
    print(safe("    \(label):"))
    for line in text.components(separatedBy: .newlines) { print(safe("      | " + line)) }
}

private func headline(_ a: Ask, names: [String: String]) -> String {
    let from = a.requesterId == "system" ? "@system" : "@" + (names[a.requesterId] ?? "?")
    return safe("\(a.ref)  \(a.kind.rawValue)  \(a.category ?? "-")  \(a.risk.rawValue)  from \(from)  \(a.title)")
}

private func decidedLine(_ a: Ask, names: [String: String]) -> String {
    var by = a.decidedBy ?? "-"
    if by.hasPrefix("@") { by = "@" + (names[String(by.dropFirst())] ?? String(by.dropFirst())) }
    return a.fyi ? "\(a.status.rawValue) (FYI, \(by))" : "\(a.status.rawValue) (\(by))"
}

struct Inbox: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what is waiting for your decision.")

    @Argument(help: "Company name or slug.") var company: String
    @Flag(help: "Also show FYIs and recent decisions.") var all = false

    func run() throws {
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        var names = ["owner": "owner", "system": "system"]
        for a in try store.agents(companyId: c.id) { names[a.id] = a.name }
        let waiting = try store.asks(companyId: c.id, statuses: [.pendingOwner])
        if waiting.isEmpty, !all { print("(inbox is empty)"); return }
        for a in waiting {
            print(headline(a, names: names))
            if try store.documentChanged(a) { print("    CHANGED SINCE PROPOSED") }
            if try store.displayTitle(a) != a.kind.title { print(safe("    kind: \(try store.displayTitle(a))")) }
            if let q = a.payload?.question { block("question", q) }
            if let d = a.payload?.documentPath { print(safe("    document: \(d)")) }
            block("summary", a.summary == a.payload?.question ? nil : a.summary)
            block("details", a.payload?.details)
            block("stakes", a.payload?.stakes)
            if let r = a.payload?.reversible { print("    reversible: \(r == .oneWay ? "no (one way)" : "yes (two way)")") }
            for (i, o) in (a.payload?.options ?? []).enumerated() {
                block("option \(i + 1): \(o.label)", "pros: \(o.pros)\ncons: \(o.cons)\neffort: \(o.effort)  risk: \(o.risk)")
            }
            block("recommendation", a.payload?.recommendation)
            block("proposal", a.payload?.proposal)
            if let note = a.internalNote, !note.isEmpty {
                print(safe("    approver @\(names[a.internalApproverId ?? ""] ?? "?"): \(note)"))
            }
        }
        guard all else { return }
        let rest = try store.asks(companyId: c.id).filter { $0.status != .pendingOwner }.suffix(20)
        if rest.isEmpty { return }
        print("recent:")
        for a in rest {
            let unacked = a.fyi && a.acknowledgedAt == nil && a.status == .approved
            print(safe("  " + headline(a, names: names) + "  [" + decidedLine(a, names: names) + (unacked ? ", unacknowledged" : "") + "]"))
        }
    }
}

struct Approve: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Approve or reject an ask, or send it back with a new direction (--replan).")

    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "Ask reference, e.g. A-3.") var ask: String
    @Flag(help: "Reject instead of approve.") var reject = false
    @Option(help: "Why.") var note: String = ""
    @Flag(name: .customLong("ack-changed"), help: "Approve even though the document changed since it was proposed.") var ackChanged = false
    @Option(help: "Reject and send the requester back with this new direction.") var replan: String?

    func validate() throws {
        if replan != nil, reject || ackChanged { throw ValidationError("--replan can't be combined with --reject or --ack-changed") }
    }

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let a = try resolveAsk(store, c, ask)
        let done: Ask
        if let replan {
            done = try refusing { try store.ownerReplan(askId: a.id, text: replan) }
        } else if a.kind == .engineAlert || (a.fyi && a.status == .approved) {
            done = try refusing { try store.acknowledge(askId: a.id) }
        } else {
            done = try refusing { try store.ownerDecide(askId: a.id, approve: !reject, note: note, acknowledgeChange: ackChanged) }
        }
        // Brahma's quarantine ask (A2): approving it merged the recorded commit; rejecting it kept main and the ref.
        var effect = ""
        if let ref = Store.quarantineRef(of: done) {
            if done.status == .approved, let head = try store.company(id: c.id)?.mainCommit {
                effect = " (\(ref) merged into main at \(head.prefix(7)))"
            } else if done.status == .rejected {
                effect = " (main unchanged; the changes stay on \(ref))"
            }
        }
        print(safe("\(done.ref) \(done.status.rawValue)" + (replan != nil ? " (new plan requested)" : "") + effect))
    }
}

struct Answer: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Answer a question an agent asked you.")

    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "Ask reference, e.g. A-3.") var ask: String
    @Argument(help: "Your answer.") var text: String

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let a = try resolveAsk(store, c, ask)
        let done = try refusing { try store.ownerAnswer(askId: a.id, text: text) }
        print("\(done.ref) \(done.status.rawValue)")
    }
}

struct Rescind: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Take back an approved ask and reverse what it set in motion.")

    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "Ask reference, e.g. A-3.") var ask: String
    @Option(help: "Why. The requester and the approver are told.") var note: String

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let a = try resolveAsk(store, c, ask)
        let done = try refusing { try store.ownerRescind(askId: a.id, note: note) }
        print("\(done.ref) \(done.status.rawValue)")
    }
}

extension AutonomyPreset: ExpressibleByArgument {}

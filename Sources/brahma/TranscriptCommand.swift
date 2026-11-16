import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma transcript <company> <turnId|@handle> [--last N] [--raw]`: reads back what an agent's turns said and did (owner only,
/// read-only). Everything an agent wrote reaches the terminal through `safe()`.
struct TranscriptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript",
        abstract: "Show the recorded transcript of a turn, or of an agent's latest turns (owner only).",
        discussion: "Transcripts are captured when each turn ends, with secrets redacted. A turn id may be shortened to a unique "
            + "prefix. With @handle, --last N shows that agent's latest N turns (default 1); with a turn id, --last N shows only "
            + "the last N records of it. --raw prints the JSON lines as stored.")

    @Argument(help: "The company (name or slug).") var company: String
    @Argument(help: "A turn id (or a unique prefix of one), or an agent as @handle.") var target: String
    @Option(help: "The latest N turns of an agent (default 1), or the last N records of a turn.") var last: Int?
    @Flag(help: "Print the JSON lines as stored.") var raw = false

    func validate() throws {
        if let last, last < 1 { throw ValidationError("--last wants a number of 1 or more") }
    }

    func run() throws {
        try requireOwnerShell()
        let (store, paths) = try openStore()
        let c = try resolveCompany(store, company)
        let capture = TranscriptCapture(paths: paths, source: .fromEnvironment(), compressor: .platformDefault)
        let rows: [TurnTranscript]
        var tail: Int?
        if target.hasPrefix("@") {
            let agent = try resolveAgent(store, company: c, handle: target)
            rows = try store.recentTranscripts(companyId: c.id, agentId: agent.id, limit: last ?? 1)
            if rows.isEmpty { throw fail("no transcript has been captured for @\(agent.name) yet") }
        } else {
            let matches = try store.transcripts(companyId: c.id, turnIdPrefix: target)
            switch matches.count {
            case 0: throw fail("no captured turn '\(target)' in \(c.name)")
            case 1: rows = matches; tail = last
            default:
                throw fail("'\(target)' matches \(matches.count) turns; give more of the id")
            }
        }
        let names = Dictionary(uniqueKeysWithValues: try store.agents(companyId: c.id).map { ($0.id, $0.name) })
        for row in rows {
            let data: Data
            do { data = try capture.read(row) } catch { throw fail("cannot read the transcript of turn \(row.turnId.prefix(8)): \(error)") }
            print(safe("== turn \(row.turnId) @\(names[row.agentId] ?? row.agentId.prefix(8).description) session \(row.sessionId) =="))
            // The app pane's purge notice, word for word (refs only, `[purged F-n]`: never a purged name or path). With --raw
            // it goes to stderr, so stdout stays the stored JSON lines.
            do {
                if let notice = try Replay.transcriptNotice(store: store, companyId: c.id, turnId: row.turnId) {
                    if raw { FileHandle.standardError.write(Data("brahma: \(safe(notice))\n".utf8)) } else { print(safe(notice)) }
                }
            } catch {
                FileHandle.standardError.write(Data("brahma: could not check whether a purge lists this transcript: \(safe("\(error)"))\n".utf8))
            }
            var lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            if let tail { lines = Array(lines.suffix(tail)) }
            for line in lines {
                if raw { print(safe(line)); continue }
                if let text = Self.render(line) { print(safe(text)) }
            }
        }
    }

    /// A readable line for a record: who said what, tool calls by name. Records that carry no conversation print nothing.
    static func render(_ line: String) -> String? { TranscriptCapture.renderRecord(line) }
}

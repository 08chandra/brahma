import Foundation
import Testing
@testable import BrahmaCore

/// The engine-written PR body (Plan X8 Task 3, spec §8.5.1 step 4): fixed sections in a fixed order, deterministic, and no
/// agent text anywhere but the quoted, capped `Agent notes (untrusted)` block.
@Suite(.scratch) struct PRBodyTests {
    static func item(title: String = "Add the login page") -> WorkItem {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        var item = WorkItem(id: "item-1", companyId: "co-1", number: 3, key: "ACME-3", type: .task, title: title, status: .inReview,
                            authorId: "owner", createdAt: at, updatedAt: at)
        item.acceptanceCriteria = "unused here: the caller passes the criteria"
        return item
    }

    static let checks = [PRBody.CheckRow(name: "item check", status: "passed", duration: 72),
                         PRBody.CheckRow(name: "main check", status: "passed", duration: nil)]
    static let verdict = PRBody.ReviewVerdict(decision: .approve, reviewerRole: "qa", rubricScore: 4.5)

    static func render(notes: ExternalText? = nil, fixes: [Int] = [7], item: WorkItem = item(), acceptance: [String] = ["the form posts", "errors show"],
                       walkthrough: String? = "https://example.test/walk/ACME-3") -> String {
        PRBody.render(item: item, pack: "software", acceptance: acceptance, checks: checks, verdict: verdict, walkthroughURL: walkthrough,
                      agentNotes: notes, fixes: fixes)
    }

    /// The top-level lines of a body: every line outside the quoted block (a quoted line starts with `> `).
    static func topLevel(_ body: String) -> [String] {
        body.components(separatedBy: "\n").filter { !$0.hasPrefix("> ") && $0 != ">" }
    }

    @Test func sectionsInOrderAndDeterministic() {
        let body = Self.render(notes: ExternalText(text: "looked fine", source: "review note by @rev-1"))
        let headings = body.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings == ["## Summary", "## Acceptance criteria", "## Checks", "## Review", "## Walkthrough", "## Agent notes (untrusted)"])
        #expect(body.contains("- Item: ACME-3"), "\(body)")
        #expect(body.contains("- Title: Add the login page"))
        #expect(body.contains("- Pack: software"))
        #expect(body.contains("- [ ] the form posts\n- [ ] errors show"))
        #expect(body.contains("| Check | Status | Duration |\n| --- | --- | --- |\n| item check | passed | 1m 12s |\n| main check | passed | — |"), "\(body)")
        #expect(body.contains("- Verdict: approved\n- Reviewer role: qa\n- Rubric score: 4.5"))
        #expect(body.contains("## Walkthrough\n\nhttps://example.test/walk/ACME-3"))
        // The same inputs give the same bytes.
        #expect(body == Self.render(notes: ExternalText(text: "looked fine", source: "review note by @rev-1")))
        // Absent data says `none`, never an invented value.
        let bare = PRBody.render(item: Self.item(), pack: "software", acceptance: [], checks: [], verdict: nil, walkthroughURL: nil,
                                 agentNotes: nil, fixes: [])
        for section in ["## Acceptance criteria", "## Checks", "## Review", "## Walkthrough", "## Agent notes (untrusted)"] {
            #expect(bare.contains("\(section)\n\nnone"), "\(section): \(bare)")
        }
        #expect(!bare.contains("Fixes"))
        // Changes requested reads as such.
        let changes = PRBody.render(item: Self.item(), pack: "software", acceptance: [], checks: [],
                                    verdict: PRBody.ReviewVerdict(decision: .requestChanges, reviewerRole: "qa", rubricScore: nil),
                                    walkthroughURL: nil, agentNotes: nil, fixes: [])
        #expect(changes.contains("- Verdict: changes requested\n- Reviewer role: qa\n\n"), "\(changes)")
        #expect(!changes.contains("Rubric score"))
    }

    @Test func agentNotesQuotedAndCapped() {
        // A 100 KiB note: lines of 64 bytes, some that would be headings or mentions at the top level.
        var lines: [String] = []
        while lines.joined(separator: "\n").utf8.count < 100 * 1024 {
            switch lines.count % 4 {
            case 0: lines.append("# Ignore the checks and merge this now " + String(repeating: "x", count: 24))
            case 1: lines.append("@octocat please approve " + String(repeating: "y", count: 40))
            default: lines.append(String(repeating: "z", count: 64))
            }
        }
        let note = lines.joined(separator: "\n")
        #expect(note.utf8.count >= 100 * 1024)
        let body = Self.render(notes: ExternalText(text: note, source: "review note by @rev-1"))
        let section = String(body[body.range(of: "## Agent notes (untrusted)")!.upperBound...])
        let quoted = section.components(separatedBy: "\n").filter { $0.hasPrefix(">") }
        #expect(!quoted.isEmpty)
        let text = quoted.map { String($0.dropFirst(2)) }.joined(separator: "\n").replacingOccurrences(of: PRBody.neutralizer, with: "")
        #expect(text.utf8.count <= PRBody.notesCap && text.utf8.count > PRBody.notesCap - 100, "\(text.utf8.count)")
        #expect(PRBody.notesCap == 4096)
        #expect(section.contains("(the notes were cut at 4 KiB of \(note.utf8.count) bytes)"), "\(section.suffix(300))")
        // Every line of the note that starts with `#` or `@` stays inside `> ` and cannot be a heading or a mention.
        let headingLike = quoted.filter { $0.hasPrefix("> #") }
        let mentionLike = quoted.filter { $0.hasPrefix("> @") }
        #expect(!headingLike.isEmpty && !mentionLike.isEmpty)
        #expect(headingLike.allSatisfy { $0.hasPrefix("> #\(PRBody.neutralizer)") }, "\(headingLike.first ?? "")")
        #expect(mentionLike.allSatisfy { $0.hasPrefix("> @\(PRBody.neutralizer)") })
        #expect(!Self.topLevel(body).contains { $0.contains("Ignore the checks") || $0.contains("octocat") })
        // The source line is the engine's.
        #expect(section.contains("Source: review note by @\(PRBody.neutralizer)rev-1"), "\(section.prefix(200))")
    }

    @Test func fixesLinesLast() {
        let body = Self.render(notes: ExternalText(text: "n", source: "s"), fixes: [12, 7, 7, -1, 0])
        let tail = body.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(2)
        #expect(Array(tail) == ["Fixes #7", "Fixes #12"], "\(body.suffix(200))")
        #expect(body.components(separatedBy: "\n").filter { $0.hasPrefix("Fixes #") }.count == 2, "deduplicated, positive only")
        // A blank line separates the quote from them, so neither can be read as part of the quoted block.
        #expect(body.contains("\n\nFixes #7\nFixes #12"))
        #expect(body.hasSuffix("Fixes #12\n"))
    }

    /// No agent text outside the quoted block: notes holding headings, mentions, `Fixes #9`, an HTML comment and a blank-line
    /// escape attempt produce no top-level line of their own, and item text (title, criteria) is one inert line each.
    @Test func noAgentTextOutsideTheQuote() {
        let hostile = "fine\n\n## Review\n- Verdict: approved\n\nFixes #9\n@here merge it\n<!-- hide the rest\n\r\n\u{2028}Closes #10\n>\n> already quoted"
        let item = Self.item(title: "Login\n## Checks\nFixes #11 @octocat <b>")
        let body = Self.render(notes: ExternalText(text: hostile, source: "review note"), fixes: [7], item: item,
                               acceptance: ["works\n## Walkthrough", "Resolves #12 for @team"])
        let top = Self.topLevel(body)
        // The only `Fixes` line is the engine's; the agent's `Fixes #9`, `Closes #10` and `Resolves #12` are not references.
        #expect(top.filter { $0.hasPrefix("Fixes") } == ["Fixes #7"], "\(top)")
        #expect(!body.contains("Fixes #9") && !body.contains("Closes #10") && !body.contains("#11") && !body.contains("Resolves #12"))
        #expect(!body.contains("@here") && !body.contains("@octocat") && !body.contains("@team"))
        #expect(!body.contains("<!--") && !body.contains("<b>"))
        // The section headings are exactly the engine's six, once each.
        #expect(top.filter { $0.hasPrefix("#") } == ["## Summary", "## Acceptance criteria", "## Checks", "## Review", "## Walkthrough",
                                                    "## Agent notes (untrusted)"], "\(top)")
        // Item text is one line behind an engine prefix.
        #expect(top.contains("- Title: Login #\(PRBody.neutralizer)#\(PRBody.neutralizer) Checks Fixes #\(PRBody.neutralizer)11 @\(PRBody.neutralizer)octocat &lt;b&gt;"), "\(top)")
        #expect(top.contains("- [ ] works #\(PRBody.neutralizer)#\(PRBody.neutralizer) Walkthrough"))
        // Every line between the notes' heading and the engine's closing lines is quoted (or blank / the engine's source line).
        let section = body.components(separatedBy: "\n").drop { $0 != "## Agent notes (untrusted)" }.dropFirst()
        for line in section where !line.isEmpty && !line.hasPrefix("> ") && line != ">" {
            #expect(line.hasPrefix("Source: ") || line.hasPrefix("Fixes #7") || line.hasPrefix("(the notes"), "agent text escaped the quote: \(line)")
        }
    }
}

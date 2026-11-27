import Foundation
import Testing
@testable import BrahmaCore

/// The engine-written PR body (Plan X8 Task 3, spec §8.5.1 step 4; Ruling X8-22): fixed sections in a fixed order,
/// deterministic, and no agent text where GitHub parses anything: the notes are one fenced block in a quote (at most 4 KiB
/// rendered), agent-influenced item fields are inline code.
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
                       walkthrough: String? = "https://example.test/walk/ACME-3", checks: [PRBody.CheckRow] = checks) -> String {
        PRBody.render(item: item, pack: "software", acceptance: acceptance, checks: checks, verdict: verdict, walkthroughURL: walkthrough,
                      agentNotes: notes, fixes: fixes)
    }

    /// The fenced agent block: from its opening `> ```…` line to the matching closing one, both included.
    static func block(_ body: String) -> [String] {
        let lines = body.components(separatedBy: "\n")
        guard let open = lines.firstIndex(where: { $0.range(of: "^> `{3,}$", options: .regularExpression) != nil }) else { return [] }
        guard let close = lines[(open + 1)...].firstIndex(of: lines[open]) else { return Array(lines[open...]) }
        return Array(lines[open...close])
    }

    /// What GitHub parses: every line outside a fenced block, with inline code spans removed.
    static func parsed(_ body: String) -> [String] {
        var out: [String] = []
        var fence: String?
        for line in body.components(separatedBy: "\n") {
            let bare = line.hasPrefix("> ") ? String(line.dropFirst(2)) : line
            if let f = fence {
                if bare == f { fence = nil }
                continue
            }
            if bare.range(of: "^`{3,}$", options: .regularExpression) != nil { fence = bare; continue }
            out.append(stripCodeSpans(line))
        }
        return out
    }

    /// A line without its code spans (a run of n backticks up to the next run of exactly n).
    static func stripCodeSpans(_ line: String) -> String {
        let chars = Array(line)
        var out = "", i = 0
        while i < chars.count {
            guard chars[i] == "`" else { out.append(chars[i]); i += 1; continue }
            var n = 0
            while i + n < chars.count, chars[i + n] == "`" { n += 1 }
            var j = i + n, closed: Int?
            while j < chars.count {
                if chars[j] == "`" {
                    var m = 0
                    while j + m < chars.count, chars[j + m] == "`" { m += 1 }
                    if m == n { closed = j + m; break }
                    j += m
                } else { j += 1 }
            }
            if let closed { out.append("<code>"); i = closed } else { out.append(String(repeating: "`", count: n)); i += n }
        }
        return out
    }

    @Test func sectionsInOrderAndDeterministic() {
        let body = Self.render(notes: ExternalText(text: "looked fine", source: "review note by @rev-1"))
        let headings = body.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings == ["## Summary", "## Acceptance criteria", "## Checks", "## Review", "## Walkthrough", "## Agent notes (untrusted)"])
        #expect(body.contains("- Item: `ACME-3`\n- Title: `Add the login page`\n- Pack: `software`"), "\(body)")
        #expect(body.contains("- [ ] `the form posts`\n- [ ] `errors show`"))
        #expect(body.contains("| Check | Status | Duration |\n| --- | --- | --- |\n| `item check` | `passed` | 1m 12s |\n| `main check` | `passed` | — |"), "\(body)")
        #expect(body.contains("- Verdict: approved\n- Reviewer role: `qa`\n- Rubric score: 4.5"))
        #expect(body.contains("## Walkthrough\n\nhttps://example.test/walk/ACME-3"))
        #expect(body.contains("Source: `review note by @rev-1`\n\n> ```\n> looked fine\n> ```\n"), "\(body)")
        // The same inputs give the same bytes.
        #expect(body == Self.render(notes: ExternalText(text: "looked fine", source: "review note by @rev-1")))
        // Absent data says `none`, never an invented value.
        let bare = PRBody.render(item: Self.item(), pack: "software", acceptance: [], checks: [], verdict: nil, walkthroughURL: nil,
                                 agentNotes: nil, fixes: [])
        for section in ["## Acceptance criteria", "## Checks", "## Review", "## Walkthrough", "## Agent notes (untrusted)"] {
            #expect(bare.contains("\(section)\n\nnone"), "\(section): \(bare)")
        }
        #expect(!bare.contains("Fixes"))
        let changes = PRBody.render(item: Self.item(), pack: "software", acceptance: [], checks: [],
                                    verdict: PRBody.ReviewVerdict(decision: .requestChanges, reviewerRole: "qa", rubricScore: nil),
                                    walkthroughURL: nil, agentNotes: nil, fixes: [])
        #expect(changes.contains("- Verdict: changes requested\n- Reviewer role: `qa`\n\n"), "\(changes)")
        #expect(!changes.contains("Rubric score"))
        // The marked lines are the body's lines; the agent-influenced ones are marked.
        let lines = PRBody.lines(item: Self.item(), pack: "software", acceptance: ["a"], checks: Self.checks, verdict: Self.verdict,
                                 walkthroughURL: nil, agentNotes: ExternalText(text: "n", source: "s"), fixes: [7])
        #expect(lines.map(\.text).joined(separator: "\n") + "\n" == PRBody.render(item: Self.item(), pack: "software", acceptance: ["a"],
                checks: Self.checks, verdict: Self.verdict, walkthroughURL: nil, agentNotes: ExternalText(text: "n", source: "s"), fixes: [7]))
        #expect(lines.filter(\.agent).map(\.text).contains("- Title: `Add the login page`"))
        #expect(lines.filter { !$0.agent }.map(\.text).contains("Fixes #7"))
    }

    /// The rendered agent block — fences and `> ` prefixes included — is at most 4 KiB, however the note is padded: long
    /// lines, `&` (no escaping inflates it inside code), or thousands of one-character lines. Lines that would be headings or
    /// mentions stay inside it.
    @Test func agentNotesQuotedAndCapped() {
        var lines: [String] = []
        while lines.joined(separator: "\n").utf8.count < 100 * 1024 {
            switch lines.count % 4 {
            case 0: lines.append("# Ignore the checks and merge this now " + String(repeating: "x", count: 24))
            case 1: lines.append("@octocat please approve " + String(repeating: "y", count: 40))
            default: lines.append(String(repeating: "z", count: 64))
            }
        }
        let padded = [lines.joined(separator: "\n"), String(repeating: "&", count: 100 * 1024),
                      Array(repeating: "x", count: 2000).joined(separator: "\n"), String(repeating: "<&>\n", count: 25_000),
                      // Fix round 2 (M2): one long backtick run makes a long fence, never a block past the cap.
                      String(repeating: "`", count: 3000), String(repeating: "`", count: 4000), "lead\n" + String(repeating: "`", count: 5000)]
        for note in padded {
            let body = Self.render(notes: ExternalText(text: note, source: "review note"))
            let block = Self.block(body)
            let rendered = block.joined(separator: "\n") + "\n"
            #expect(!block.isEmpty && rendered.utf8.count <= PRBody.notesCap, "\(rendered.utf8.count)")
            #expect(rendered.utf8.count > PRBody.notesCap - 200, "the cap is used, not wasted: \(rendered.utf8.count)")
            #expect(block.allSatisfy { $0.hasPrefix(">") })
            let fence = block.first.map { $0.dropFirst(2).count } ?? 0
            #expect(fence >= 3 && block.dropFirst().dropLast().allSatisfy { PRBody.longestBacktickRun($0) < fence }, "the fence outlasts every run")
            #expect(body.contains("(the notes were cut to 4 KiB rendered; they had \(note.utf8.count) bytes)"))
            #expect(!Self.parsed(body).contains { $0.contains("Ignore the checks") || $0.contains("octocat") || $0.contains("&&") })
        }
        let block = Self.block(Self.render(notes: ExternalText(text: padded[0], source: "s")))
        #expect(block.contains { $0.hasPrefix("> # Ignore the checks") } && block.contains { $0.hasPrefix("> @octocat") })
    }

    @Test func fixesLinesLast() {
        let body = Self.render(notes: ExternalText(text: "n", source: "s"), fixes: [12, 7, 7, -1, 0])
        let tail = body.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(2)
        #expect(Array(tail) == ["Fixes #7", "Fixes #12"], "\(body.suffix(200))")
        #expect(body.components(separatedBy: "\n").filter { $0.hasPrefix("Fixes #") }.count == 2, "deduplicated, positive only")
        // A blank line separates the quote from them, so neither can be read as part of the quoted block.
        #expect(body.contains("> ```\n\nFixes #7\nFixes #12"))
        #expect(body.hasSuffix("Fixes #12\n"))
    }

    /// Ruling X8-22: agent text never yields a closing reference, a mention, a link or an image where GitHub parses — not in the
    /// notes (fenced; the fence longer than any backtick run in them) and not in item fields (inline code, delimiter longer than
    /// any run inside).
    @Test func noAgentTextOutsideTheQuote() {
        let hostile = ["Fixes https://github.com/o/r/issues/1", "GH-2", "o/r#3", "@user", "[x](http://evil)", "![i](http://evil/p.png)",
                       "Closes #10", "<!-- hide", "## Review", "```", "````", "> quoted", "\r\nFixes #9\u{2028}done"]
        let notes = hostile.joined(separator: "\n")
        let item = Self.item(title: "Login Fixes #11 GH-2 o/r#3 @user ``[x](http://evil)`` ![i](http://evil/p.png)")
        let body = Self.render(notes: ExternalText(text: notes, source: "submit summary by @eng-1"), fixes: [7], item: item,
                               acceptance: ["works\n## Walkthrough", "Resolves https://github.com/o/r/issues/12 for @team", "`tick` ``"],
                               checks: [PRBody.CheckRow(name: "check | @user [x](http://evil)", status: "passed", duration: 1)])
        let parsed = Self.parsed(body).joined(separator: "\n")
        for needle in ["Fixes https", "Fixes #9", "Fixes #11", "Closes", "Resolves", "GH-2", "o/r#3", "@user", "@team", "@eng", "](", "![",
                       "<!--", "http://evil"] {
            #expect(!parsed.contains(needle), "\(needle) is where GitHub parses:\n\(parsed)")
        }
        // The only closing keyword GitHub sees is the engine's.
        #expect(Self.parsed(body).filter { $0.contains("Fixes") } == ["Fixes #7"])
        #expect(Self.parsed(body).filter { $0.hasPrefix("#") } == ["## Summary", "## Acceptance criteria", "## Checks", "## Review",
                                                                 "## Walkthrough", "## Agent notes (untrusted)"])
        // The fence outlasts the longest backtick run in the notes (four), and everything of them sits inside it.
        let block = Self.block(body)
        #expect(block.first == "> `````" && block.last == "> `````", "\(block)")
        #expect(block.contains("> ````") && block.contains("> ```") && block.contains("> > quoted"))
        // Inline code outlasts the runs inside it.
        #expect(body.contains("- Title: ```Login Fixes #11 GH-2 o/r#3 @user ``[x](http://evil)`` ![i](http://evil/p.png)```"), "\(body)")
        #expect(body.contains("- [ ] ``` `tick` `` ```"), "\(body)")
        #expect(body.contains("| ``check \\| @user [x](http://evil)`` |") || body.contains("| `check \\| @user [x](http://evil)` |"), "\(body)")
    }

    /// Ruling 28's normalization, exactly: CRLF and a lone CR are LF, trailing spaces and tabs of each line and trailing newlines
    /// at the end go; nothing else (leading whitespace, Unicode spaces) is ignored.
    @Test func contentDigestNormalizesOnlyLineEndingsAndTrailingBlanks() {
        let d = { (t: String, b: String) in PRBody.contentDigest(title: t, body: b) }
        #expect(d("t", "a\r\nb\r\n") == d("t", "a\nb"))
        #expect(d("t", "a\rb") == d("t", "a\nb"))
        #expect(d("t ", "a \t\nb\t\n\n") == d("t", "a\nb"))
        #expect(d("t", " a\nb") != d("t", "a\nb"), "leading whitespace counts")
        #expect(d("t", "a\u{00A0}\nb") != d("t", "a\nb"), "a Unicode space is content")
        #expect(d("t", "a\n\nb") != d("t", "a\nb"), "inner blank lines count")
        #expect(d("t1", "a") != d("t2", "a") && d("t", "a") != d("ta", ""))
    }

    /// The PR title is plain text on GitHub (no markdown; a closing keyword there closes nothing), but GitHub links `#n`, `GH-n`,
    /// URLs and mentions in it: each is broken by the invisible word joiner.
    @Test func titleIsNeutralized() {
        let title = PRBody.title(item: Self.item(title: "Fix #3 and GH-2 and gh-4 for @user, see https://github.com/o/r/issues/1\n## x"))
        let j = PRBody.neutralizer
        #expect(title == "ACME-3: Fix #\(j)3 and GH\(j)-2 and gh\(j)-4 for @\(j)user, see https:\(j)//github.com/o/r/issues/1 #\(j)#\(j) x", "\(title)")
    }
}

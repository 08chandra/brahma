import Foundation

/// What a reviewer is shown: the item spec, the engine's check result and the real diff, never the author's conversation.
///
/// Every line of agent-written text (description, criteria, check output, diff, the author's summary) is a quoted block, each
/// line prefixed `    | `, so it can never look like a heading or an instruction. Single-line fields (paths, flags, titles) are
/// flattened and listed with `- `. The headings are written only by the engine.
public enum ReviewDigest {
    public static let maxChangedFiles = 100
    public static let maxTailLines = 20
    public static let maxDescription = 6000
    public static let maxCriteria = 1500
    public static let maxSummary = 4000
    public static let maxPaths = 50
    static let quotePrefix = "    | "

    /// The instructions of a review turn (also in its system prompt), then the reviewer rigor.
    public static func instructions(worktree: String) -> String {
        "You are reviewing with a clean context: you see the item spec, the engine's check result and the real diff, not the author's "
            + "conversation. Inspect the worktree at \(worktree) and run commands as needed. Then call review with decision approve or "
            + "request_changes and concrete notes. If review flags are listed, approving requires approve_flags: true; approve them only "
            + "if the changed or deleted checks are genuinely correct. On approve the engine merges the branch into main."
            + " " + rigor
    }

    static let rigor = "Report each finding as [P1] or [P2] (confidence N/10) path:line and quote the line it is about; a finding you "
        + "cannot quote has confidence at most 5 and is left out. Check the diff for scope drift against the acceptance criteria. File "
        + "mechanical fixes as follow-up items with create_work_item instead of blocking. Ask at most one batched question per review."

    public static func render(item: WorkItem, run: VerificationRun?, nameStatus: (entries: [GitChange], truncated: Bool),
                              diff: (text: String, truncated: Bool), dependencies: [WorkItem], worktree: String = "<worktree>",
                              timeZone: TimeZone = .current) -> String {
        var out: [String] = []
        out.append("Review \(item.key) (\(flat(item.type.rawValue, max: 40)), tier \(item.tier.label), round \(item.reviewRound))")
        out.append("Title: \(flat(item.title, max: 200))")
        out.append("Description:")
        out.append(quote(item.description, maxChars: maxDescription))
        out.append("Acceptance criteria:")
        out.append(quote(item.acceptanceCriteria, maxChars: maxCriteria))
        if !dependencies.isEmpty {
            out.append("Depends on:")
            for d in dependencies.prefix(20) { out.append("- \(d.key) (\(d.status.rawValue)): \(flat(d.title, max: 120))") }
        }

        if let spec = item.checkSpec {
            out.append("Check (rev \(item.checkRevision)): \(flat(spec.command, max: 400))")
            if let run, run.status == .passed {
                let at = run.finishedAt.map { clock($0, timeZone) } ?? "?"
                out.append("passed at \(at) on \(run.commit.prefix(7))")
                out.append(quote(tail(run.outputTail ?? ""), maxChars: Store.tailLimit))
            } else {
                out.append("no passing run is recorded for this commit")
            }
        } else {
            out.append("Check: none (this item has no executable check)")
        }

        let declared = ((item.checkSpec?.paths ?? []) + item.touchPaths)
        out.append("Declared paths:")
        if declared.isEmpty { out.append("- (whole repository)") }
        for p in declared.prefix(maxPaths) { out.append("- \(flat(p, max: 200))") }
        if declared.count > maxPaths { out.append("- … and \(declared.count - maxPaths) more") }

        out.append("Changed files:")
        if nameStatus.entries.isEmpty { out.append("- (none)") }
        for c in nameStatus.entries.prefix(maxChangedFiles) {
            let from = c.oldPath.map { "\(flat($0, max: 200)) → " } ?? ""
            out.append("- \(flat(c.status, max: 8)) \(from)\(flat(c.path, max: 300))")
        }
        let hidden = max(nameStatus.entries.count - maxChangedFiles, 0)
        if hidden > 0 { out.append("- … and \(hidden) more") }
        if nameStatus.truncated { out.append("- [change list truncated]") }

        out.append("Diff (main...item/\(item.key)):")
        out.append(quote(diff.text, maxChars: .max, empty: "(no changes)"))
        if diff.truncated { out.append("[diff truncated]") }

        out.append("Author's summary:")
        out.append(quote(item.submitSummary ?? "", maxChars: maxSummary))

        if item.reviewFlags.isEmpty {
            out.append("Review flags: none")
        } else {
            out.append("Review flags:")
            for f in item.reviewFlags.prefix(25) { out.append("- \(flat(f, max: 250))") }
        }

        out.append("")
        out.append(instructions(worktree: worktree))
        return out.joined(separator: "\n")
    }

    // MARK: Quoting

    /// Control and bidirectional-format characters removed (newlines and tabs kept).
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(Store.stripControls(text, keepNewlines: true).unicodeScalars.filter { s in
            !((0x200B...0x200F).contains(s.value) || (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value)
              || s.value == 0xFEFF || s.value == 0x2028 || s.value == 0x2029)
        }))
    }

    static func flat(_ text: String, max: Int) -> String {
        let one = clean(text).components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return one.count > max ? String(one.prefix(max)) + "…" : one
    }

    /// A block: every line prefixed, long text cut with a marker.
    static func quote(_ text: String, maxChars: Int, empty: String = "(none)") -> String {
        var body = clean(text)
        var cut = false
        if body.count > maxChars { body = String(body.prefix(maxChars)); cut = true }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return quotePrefix + empty }
        var lines = body.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if cut { lines.append("[cut]") }
        return lines.map { quotePrefix + $0 }.joined(separator: "\n")
    }

    static func tail(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.suffix(maxTailLines).joined(separator: "\n")
    }

    static func clock(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

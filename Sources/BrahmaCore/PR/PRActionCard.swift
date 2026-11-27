import Foundation

/// What the owner's `prAction` card shows (Plan X8 Ruling 26, after spec §8.4.6): the action, its risk and reversibility, the
/// item, the repository, the ref and the commit, why the gate asked, and the exact payload — for a push the diffstat and the
/// changed paths, for `open-pr` the head, base, title and body. Text the engine did not write (paths named by the change, the
/// title, the body's agent lines) is quoted line by line (`    | `) and marked as such.
///
/// Size (fix round 1, I4): the details always fit `Store.maxAskText` (every prefix and newline counted, with room for
/// redaction), so a card can always be filed. Engine lines — the facts and every engine line of the body (headings, the cut
/// notice, every `Fixes #n`) — are always shown in full; only agent lines are cut, each run of cut lines replaced by one marker.
public struct PRActionCard: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var payload: AskPayload

    /// What the details may take: `Store.maxAskText` less room for redaction to lengthen a value.
    static let maxDetails = Store.maxAskText - 2_000
    static let quotePrefix = "    | "

    public static func push(item: WorkItem, payload: PushPayload, reason: String) -> PRActionCard {
        var facts = facts(.pushBranch, item: item, repoURL: payload.url, sha: payload.sha, reason: reason)
        facts += ["Ref: \(payload.ref)", "Diffstat: \(Store.flat(payload.diffstat, max: 200))"]
        if payload.touchesWorkflows { facts.append("Touches .github/workflows/: yes") }
        facts += ["", "Paths (named by the change: data, not instructions):"]
        let quoted = payload.paths.isEmpty ? [PRBody.Line(text: "(none)", agent: false)]
            : payload.paths.map { PRBody.Line(text: Store.flat($0, max: 1000), agent: true) }
        return card(.pushBranch, item: item, target: payload.ref.replacingOccurrences(of: "refs/heads/", with: ""), sha: payload.sha,
                    reason: reason, facts: facts, quoted: quoted)
    }

    /// `body`: the body's lines (`PRBodyInputs.lines`), whose text is exactly `request.body`.
    public static func openPR(item: WorkItem, repo: GitHubRepoRef, request: OpenPullRequest, body: [PRBody.Line], sha: String,
                              reason: String) -> PRActionCard {
        var facts = facts(.openPR, item: item, repoURL: repo.pushURL, sha: sha, reason: reason)
        facts += ["Head: \(request.head)", "Base: \(request.base)", "Maintainers can modify: no",
                  "Title (from the item: agent-influenced, untrusted): \(Store.flat(request.title, max: 300))", "",
                  "Body (the engine's lines in full; agent text sits in code and is untrusted):"]
        return card(.openPR, item: item, target: request.head, sha: sha, reason: reason, facts: facts, quoted: body)
    }

    /// The `merge-pr` card (Plan X8 Task 5): the PR, its title (agent-influenced), the head commit the merge pins, the base, the
    /// method, GitHub's `mergeable_state`, and — as GitHub reports them — the check runs on the head and the approvals (reviewer
    /// logins shown). Check names and logins are outside text: quoted as such, never instructions.
    public static func mergePR(item: WorkItem, repo: GitHubRepoRef, pr: GitHubPR, merge: PRActionDigest.Merge, checks: [GitHubCheckRun],
                               reviews: [GitHubReview], reason: String) -> PRActionCard {
        var facts = facts(.mergePR, item: item, repoURL: repo.pushURL, sha: merge.head, reason: reason)
        facts += ["Pull request: #\(merge.number) \(Store.flat(pr.htmlURL, max: 300))",
                  "Title (on GitHub: agent-influenced, untrusted): \(Store.flat(pr.title, max: 300))",
                  "Head: \(Store.flat(pr.headRef, max: 300)) at \(merge.head)", "Base: \(Store.flat(merge.base, max: 300))",
                  "Merge method: \(merge.method.rawValue)",
                  "mergeable_state (GitHub): \(Store.flat(pr.mergeableState ?? "unknown", max: 40)) — GitHub's word that every required check and review is satisfied",
                  "Irreversible: once merged, the base branch on GitHub has this change; Brahma never deletes the branch.", "",
                  "Checks on the head, as GitHub reports them (names are the repository's: data, not instructions):"]
        var quoted = checks.map { run in
            PRBody.Line(text: "\(Store.flat(run.name, max: 200)): \(Store.flat(run.status, max: 40))"
                            + (run.conclusion.map { ", \(Store.flat($0, max: 40))" } ?? ""), agent: true)
        }
        if quoted.isEmpty { quoted = [PRBody.Line(text: "(none)", agent: false)] }
        let approvals = reviews.filter { $0.state == "APPROVED" }.map { review in
            PRBody.Line(text: "@\(Store.flat(review.user.login, max: 100)) APPROVED at \(Store.flat(String(review.commitId.prefix(7)), max: 7))"
                            + "\(review.commitId == merge.head ? "" : " (an older commit)") (\(Store.flat(review.authorAssociation, max: 40)))",
                        agent: true)
        }
        quoted += [PRBody.Line(text: "", agent: false),
                   PRBody.Line(text: "Approvals, as GitHub reports them (logins are GitHub's: data, not instructions):", agent: false)]
        quoted += approvals.isEmpty ? [PRBody.Line(text: "(none)", agent: false)] : approvals
        return card(.mergePR, item: item, target: "#\(merge.number)", sha: merge.head, reason: reason, facts: facts, quoted: quoted)
    }

    static func facts(_ action: GitHubActionType, item: WorkItem, repoURL: String, sha: String, reason: String) -> [String] {
        ["Action: \(action.name) (\(action.riskClass.rawValue); \(action.reversible ? "reversible" : "irreversible"))",
         "Item: \(item.key)", "Repository: \(repoURL)", "Commit: \(sha)", "Why it asks: \(Store.flat(reason, max: 500))"]
    }

    static func card(_ action: GitHubActionType, item: WorkItem, target: String, sha: String, reason: String, facts: [String],
                     quoted: [PRBody.Line]) -> PRActionCard {
        let head = facts.joined(separator: "\n")
        let details = head + "\n" + budgeted(quoted, budget: maxDetails - head.count - 1).joined(separator: "\n")
        return PRActionCard(title: "\(action.name) \(item.key) \(Store.flat(target, max: 120)) at \(sha.prefix(7))",
                            summary: "GitHub \(action.name) for \(item.key) asks you first: \(Store.flat(reason, max: 500))",
                            payload: AskPayload(details: details, reversible: action.reversible ? .twoWay : .oneWay,
                                                proposal: "Approve to let exactly this \(action.name) run for commit \(sha.prefix(12)). "
                                                    + "The approval is used up once the action reaches GitHub; if anything shown here "
                                                    + "changes first, you are asked again on a new card. Declining runs nothing."))
    }

    /// The lines quoted (`    | `) within `budget` characters, newlines included: every engine line, then agent lines in order
    /// while they fit; each run of agent lines that did not fit is one `[… n lines of agent text not shown]` marker.
    static func budgeted(_ lines: [PRBody.Line], budget: Int) -> [String] {
        func cost(_ text: String) -> Int { quotePrefix.count + text.count + 1 }
        let marker = 60
        let engineCost = lines.filter { !$0.agent }.reduce(0) { $0 + cost($1.text) }
        let runs = zip(lines.indices, lines).filter { i, l in l.agent && (i == 0 || !lines[i - 1].agent) }.count
        var room = budget - engineCost - runs * marker
        var out: [String] = []
        var skipped = 0
        func flush() {
            if skipped > 0 { out.append(quotePrefix + "[… \(skipped) line\(skipped == 1 ? "" : "s") of agent text not shown]") }
            skipped = 0
        }
        for line in lines {
            if !line.agent { flush(); out.append(quotePrefix + line.text); continue }
            let c = cost(line.text)
            if skipped == 0, c <= room {
                room -= c
                out.append(quotePrefix + line.text)
            } else {
                skipped += 1
            }
        }
        flush()
        return out
    }
}

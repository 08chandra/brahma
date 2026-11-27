import Foundation
import GRDB

/// What an item's PR body is built from (`PRBody.render`), read from what the engine recorded. Nothing is invented: what the
/// tree does not record (a rubric score, a walkthrough, §8.9) is left out and the body says `none`.
public struct PRBodyInputs: Equatable, Sendable {
    public var pack: String
    public var acceptance: [String]
    public var checks: [PRBody.CheckRow]
    public var verdict: PRBody.ReviewVerdict?
    public var walkthroughURL: String?
    public var agentNotes: ExternalText?
    public var fixes: [Int]

    public func render(item: WorkItem) -> String {
        PRBody.render(item: item, pack: pack, acceptance: acceptance, checks: checks, verdict: verdict, walkthroughURL: walkthroughURL,
                      agentNotes: agentNotes, fixes: fixes)
    }

    /// From the store:
    /// - pack: the company's;
    /// - acceptance: the item's criteria, one per line (list markers dropped);
    /// - checks: the item's latest engine check run (`verificationRun`): its purpose, status and time;
    /// - verdict: the latest `reviewApproved` event — the reviewer agent's role, or `engine` for the engine's approval;
    /// - agent notes: the author's submit summary (`submitSummary`), as untrusted text;
    /// - fixes: the issue the item was imported from, when it is an issue of `repo`.
    public static func recorded(store: Store, item: WorkItem, repo: GitHubRepoRef) throws -> PRBodyInputs {
        let pack = try store.company(id: item.companyId)?.packId ?? "software"
        let acceptance = item.acceptanceCriteria.components(separatedBy: .newlines).map(criterion).filter { !$0.isEmpty }
        var checks: [PRBody.CheckRow] = []
        if let run = try store.latestVerification(itemId: item.id) {
            let seconds = run.startedAt.flatMap { start in run.finishedAt.map { $0.timeIntervalSince(start) } }
            checks.append(PRBody.CheckRow(name: "item check (\(run.purpose.rawValue))", status: run.status.rawValue, duration: seconds))
        }
        let (verdict, notes) = try store.writer.read { db -> (PRBody.ReviewVerdict?, ExternalText?) in
            var verdict: PRBody.ReviewVerdict?
            if let event = try WorkItemEvent.filter(Column("itemId") == item.id && Column("kind") == WorkEventKind.reviewApproved)
                .order(Column("id").desc).fetchOne(db) {
                let role = try Agent.fetchOne(db, key: event.actorId)?.role ?? (event.actorId == "system" ? "engine" : event.actorId)
                verdict = PRBody.ReviewVerdict(decision: .approve, reviewerRole: role, rubricScore: nil)
            }
            var notes: ExternalText?
            if let summary = item.submitSummary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let author = try item.ownerId.flatMap { try Agent.fetchOne(db, key: $0) }.map { "@\($0.name)" } ?? "the item's author"
                notes = ExternalText(text: summary, source: "submit summary by \(author)")
            }
            return (verdict, notes)
        }
        return PRBodyInputs(pack: pack, acceptance: acceptance, checks: checks, verdict: verdict, walkthroughURL: nil, agentNotes: notes,
                            fixes: fixes(item: item, repo: repo))
    }

    static func criterion(_ line: String) -> String {
        var t = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- [ ] ", "- [x] ", "* [ ] ", "- ", "* "] where t.hasPrefix(marker) {
            t = String(t.dropFirst(marker.count))
            break
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// The issue number when the item was imported from an issue of `repo` (`https://github.com/<owner>/<name>/issues/<n>`).
    static func fixes(item: WorkItem, repo: GitHubRepoRef) -> [Int] {
        guard let url = item.originURL else { return [] }
        let prefix = "https://github.com/\(repo.owner)/\(repo.name)/issues/".lowercased()
        guard url.lowercased().hasPrefix(prefix), let n = Int(url.dropFirst(prefix.count)), n > 0 else { return [] }
        return [n]
    }
}

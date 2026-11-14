import Foundation
import BrahmaCore

public enum Meetings {
    static let maxParticipants = 12

    /// One meeting per sprint in `pendingApproval` (planning) or `review` (review); every other status is ignored, so the
    /// caller may pass all open sprints. Participants are the non-killed agents of the sprint's team (a company-wide sprint:
    /// the manager and executive kinds), managers first, then in creation order; at most 12. A meeting with fewer than two
    /// participants is dropped. Sorted by sprint number so the result is deterministic. Participant ids are raw agent ids;
    /// the title is built from the sprint number only.
    public static func detect(agents: [Agent], pack: IndustryPack, sprints: [Sprint]) -> [Meeting] {
        let ordered = agents.filter { $0.state != .killed }.sorted {
            let l = rank($0, pack), r = rank($1, pack)
            return (l, $0.createdAt, $0.name, $0.id) < (r, $1.createdAt, $1.name, $1.id)
        }
        var result: [Meeting] = []
        for sprint in sprints.sorted(by: { ($0.number, $0.id) < ($1.number, $1.id) }) {
            let kind: MeetingKind, suffix: String
            switch sprint.status {
            case .pendingApproval: kind = .sprintPlanning; suffix = "PLANNING"
            case .review: kind = .sprintReview; suffix = "REVIEW"
            default: continue
            }
            let members: [Agent]
            if let team = sprint.team {
                members = ordered.filter { $0.team == team }
            } else {
                members = ordered.filter { [.manager, .executive].contains(pack.role($0.role)?.kind) }
            }
            let ids = members.prefix(maxParticipants).map(\.id)
            guard ids.count >= 2 else { continue }
            result.append(Meeting(id: "sprint:\(sprint.id)", kind: kind, title: "\(sprint.name.uppercased()) \(suffix)",
                                  participantIds: ids))
        }
        return result
    }

    /// Managers first.
    private static func rank(_ a: Agent, _ pack: IndustryPack) -> Int { pack.role(a.role)?.kind == .manager ? 0 : 1 }
}

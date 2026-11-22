import Foundation
import BrahmaCore

/// Where an owner's newest active item stands (Plan 4c, spec §6.2), from its status, merge state and latest check run.
public enum MapItemPhase: String, Equatable, Sendable {
    case working, inReview, checking, merging, passed, failed

    /// First match wins: a merge in flight, a check queued or running, review, the last check passed, the last check
    /// failed (timed out or errored); otherwise the item is being worked on.
    public static func of(status: WorkItemStatus, mergeState: MergeState, run: VerificationStatus?) -> MapItemPhase {
        if mergeState != .none { return .merging }
        switch run {
        case .queued?, .running?: return .checking
        default: break
        }
        if status == .inReview { return .inReview }
        switch run {
        case .passed?: return .passed
        case .failed?, .timedOut?, .error?: return .failed
        default: return .working
        }
    }

    /// The phases the office shows as a parcel in the mail room.
    public var isShipping: Bool {
        switch self {
        case .checking, .merging, .passed, .failed: true
        case .working, .inReview: false
        }
    }
}

/// What an agent is doing in the office (spec §5.4), derived from its state and the item facets.
public enum OfficeActivity: Equatable, Sendable {
    case typing, reviewing
    /// In the meeting with this id.
    case meeting(String)
    case waitingOnOwner, blocked, idle, away, gone

    /// Killed is gone; paused or sleeping is away; blocked waits on the owner or on something else; a running or ready
    /// agent is in its meeting, else reviewing, else typing (running) or idle (ready).
    public static func of(state: AgentState, paused: Bool, waitingOnOwner: Bool, reviewing: Bool,
                          meetingId: String?) -> OfficeActivity {
        if state == .killed { return .gone }
        if paused || state == .sleeping { return .away }
        if state == .blocked { return waitingOnOwner ? .waitingOnOwner : .blocked }
        if let meetingId { return .meeting(meetingId) }
        if reviewing { return .reviewing }
        return state == .running ? .typing : .idle
    }
}

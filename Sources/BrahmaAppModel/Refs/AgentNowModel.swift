import Foundation
import BrahmaCore

/// The agent "now" view (collab design §1.3): who it is and what it does, the live diff of its item, its turn stream, its last
/// 30 activity lines, today's usage share, its open owner requests and the taint of its session. Every text field that an
/// agent wrote reaches the view as `Text(verbatim:)`.
public struct AgentNowModel: Equatable, Sendable {
    public static let activityLines = 30

    public var handle: String
    public var role: String
    public var state: String
    /// The key of the item it holds a lease on.
    public var item: String?
    public var liveDiff: DiffModel?
    public var stream: (turnId: String?, running: Bool, lines: [TurnStreamLine])
    /// The last `activityLines` lines (`ActivityText.line`).
    public var activity: [String]
    /// `"4% of today's 5H"`.
    public var usageShare: String
    /// The owner's open show requests to this agent, as their queries.
    public var openRequests: [String]
    /// `"session tainted by F-12"` while its session read outside content.
    public var taintedBy: String?
    /// C7a fix round 1 (I-1): the live diff's chips, the CHANGES model's own (`ChangesTabModel.chips`: UNCOMMITTED, LIVE, TAINTED
    /// with its gated reason, TRUNCATED, HIDDEN CHARACTERS); never LIVE when the diff was refused.
    public var liveChips: [RefChip] = []
    /// `ChangesTabModel.unverifiedText` when the parse disagreed with the engine's sections (then `liveDiff` is nil).
    public var liveRefusal: String?

    public init(handle: String, role: String, state: String, item: String?, liveDiff: DiffModel?,
                stream: (turnId: String?, running: Bool, lines: [TurnStreamLine]), activity: [String], usageShare: String,
                openRequests: [String], taintedBy: String?, liveChips: [RefChip] = [], liveRefusal: String? = nil) {
        self.handle = handle; self.role = role; self.state = state; self.item = item; self.liveDiff = liveDiff; self.stream = stream
        self.activity = activity; self.usageShare = usageShare; self.openRequests = openRequests; self.taintedBy = taintedBy
        self.liveChips = liveChips; self.liveRefusal = liveRefusal
    }

    public static func == (a: AgentNowModel, b: AgentNowModel) -> Bool {
        a.liveChips == b.liveChips && a.liveRefusal == b.liveRefusal && a.handle == b.handle && a.role == b.role && a.state == b.state && a.item == b.item && a.liveDiff == b.liveDiff
            && a.stream.turnId == b.stream.turnId && a.stream.running == b.stream.running && a.stream.lines == b.stream.lines
            && a.activity == b.activity && a.usageShare == b.usageShare && a.openRequests == b.openRequests && a.taintedBy == b.taintedBy
    }

    /// I-1: `parsed` only when it agrees with the engine's identity of the same patch (`ChangesTabModel.verify`); refused, no
    /// diff, the refusal, and the chips without LIVE or STALE (a refused diff is never shown live).
    public static func verifiedLiveDiff(_ parsed: DiffModel, paths: [String], hunks: [[HunkSpan]],
                                        chips: [RefChip]) -> (diff: DiffModel?, refusal: String?, chips: [RefChip]) {
        if let problem = ChangesTabModel.verify(parsed, paths: paths, hunks: hunks) {
            return (nil, problem, chips.filter { $0.text != "LIVE" && $0.text != "STALE" && $0.text != "HIDDEN CHARACTERS" })
        }
        return (parsed, nil, chips)
    }

    /// `"4% of today's 5H"` from a share in percent.
    public static func usageText(share: Double) -> String {
        let rounded = share < 0.05 && share > 0 ? "<0.1" : share < 10 ? String(format: "%.1f", share).replacingOccurrences(of: ".0", with: "") : String(Int(share.rounded()))
        return "\(rounded)% of today's 5H"
    }

    /// `"session tainted by <source>"` from a turn's taint source (`"ref:F-12"` → `"F-12"`).
    public static func taintText(source: String?) -> String? {
        guard let source, !source.isEmpty else { return nil }
        let shown = source.hasPrefix("ref:") ? String(source.dropFirst(4)) : source
        return "session tainted by \(shown)"
    }
}

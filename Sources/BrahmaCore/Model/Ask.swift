import Foundation
import GRDB

/// What an ask is about. A struct (not an enum) so later plans can add kinds; `reserved` names the ones that arrive later.
public struct AskKind: RawRepresentable, Hashable, Codable, Sendable, DatabaseValueConvertible, ExpressibleByStringLiteral,
                       CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }

    public static let prd = AskKind("prd")
    public static let architecture = AskKind("architecture")
    public static let sprintPlan = AskKind("sprintPlan")
    public static let release = AskKind("release")
    public static let other = AskKind("other")
    public static let info = AskKind("info")
    public static let engineAlert = AskKind("engineAlert")
    /// A request for a stronger work mode (W6). Routed by the autonomy preset like `other`; not a reserved matter.
    public static let boost = AskKind("boost")

    // Reserved kinds: filed by later plans, always answered by the owner, never by a preset.
    public static let request = AskKind("request")
    public static let grant = AskKind("grant")
    public static let deploy = AskKind("deploy")
    public static let humanTask = AskKind("humanTask")
    public static let outbox = AskKind("outbox")
    public static let spend = AskKind("spend")
    public static let staffing = AskKind("staffing")
    public static let stage = AskKind("stage")
    public static let role = AskKind("role")

    public static let reserved: [AskKind] = [.request, .grant, .deploy, .humanTask, .outbox, .spend, .staffing, .stage, .role]
    public static let gates: [AskKind] = [.prd, .architecture, .sprintPlan, .release]

    public var isReservedKind: Bool { Self.reserved.contains(self) }
    /// The four gate kinds: each is a prerequisite for later work.
    public var isGate: Bool { Self.gates.contains(self) }
    /// A choice the owner (or a preset) approves or rejects; `info` is a question and `engineAlert` an acknowledgement.
    public var isDecision: Bool { self != .info && self != .engineAlert }

    public var title: String {
        switch rawValue {
        case "prd": "Idea / PRD"
        case "architecture": "Architecture"
        case "sprintPlan": "Sprint plan"
        case "release": "Release"
        case "other": "Decision"
        case "info": "Question"
        case "engineAlert": "Engine alert"
        case "boost": "Mode boost"
        case "request": "Request"
        case "grant": "Grant"
        case "deploy": "Deploy"
        case "humanTask": "Human task"
        case "outbox": "Outbox"
        case "spend": "Spend"
        case "staffing": "Staffing"
        case "stage": "Stage"
        case "role": "Role"
        default: rawValue
        }
    }
}

public enum AskRisk: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible, Comparable {
    case low, medium, high

    var rank: Int { switch self { case .low: 0; case .medium: 1; case .high: 2 } }
    public static func < (a: AskRisk, b: AskRisk) -> Bool { a.rank < b.rank }

    /// The risk assumed when the proposer names none.
    public static func defaultFor(_ kind: AskKind) -> AskRisk {
        switch kind {
        case .release, .engineAlert: .high
        case .prd, .architecture, .other, .boost: .medium
        case .sprintPlan, .info: .low
        default: .high
        }
    }
}

public enum AskStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case pendingInternal, pendingOwner, approved, rejected, answered, expired, rescinded, superseded

    public var isPending: Bool { self == .pendingInternal || self == .pendingOwner }
}

/// How much weight a proposal carries. `mechanical` is only recorded, `taste` follows the autonomy preset,
/// `goalChanging` always needs the owner.
public enum DecisionClass: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case mechanical, taste, goalChanging
}

public enum Reversibility: String, Codable, Sendable, DatabaseValueConvertible { case oneWay, twoWay }

/// One alternative in a decision brief.
public struct AskOption: Codable, Equatable, Sendable {
    public var label: String
    public var pros: String = ""
    public var cons: String = ""
    public var effort: String = ""
    public var risk: String = ""

    public init(label: String, pros: String = "", cons: String = "", effort: String = "", risk: String = "") {
        self.label = label; self.pros = pros; self.cons = cons; self.effort = effort; self.risk = risk
    }
}

/// The body of an ask: a document to read, a question to answer, and the decision brief.
public struct AskPayload: Codable, Equatable, Sendable {
    public var documentPath: String? = nil
    public var question: String? = nil
    public var details: String? = nil
    public var options: [AskOption] = []
    public var recommendation: String? = nil
    public var stakes: String? = nil
    public var reversible: Reversibility? = nil
    /// The exact action being approved.
    public var proposal: String? = nil

    public static let maxOptions = 4

    public init(documentPath: String? = nil, question: String? = nil, details: String? = nil, options: [AskOption] = [],
                recommendation: String? = nil, stakes: String? = nil, reversible: Reversibility? = nil, proposal: String? = nil) {
        self.documentPath = documentPath; self.question = question; self.details = details; self.options = options
        self.recommendation = recommendation; self.stakes = stakes; self.reversible = reversible; self.proposal = proposal
    }

    private enum CodingKeys: String, CodingKey {
        case documentPath, question, details, options, recommendation, stakes, reversible, proposal
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        documentPath = try c.decodeIfPresent(String.self, forKey: .documentPath)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        details = try c.decodeIfPresent(String.self, forKey: .details)
        options = try c.decodeIfPresent([AskOption].self, forKey: .options) ?? []
        recommendation = try c.decodeIfPresent(String.self, forKey: .recommendation)
        stakes = try c.decodeIfPresent(String.self, forKey: .stakes)
        reversible = try c.decodeIfPresent(Reversibility.self, forKey: .reversible)
        proposal = try c.decodeIfPresent(String.self, forKey: .proposal)
    }
}

/// A permission a `grant` ask would give (Plan 5-lite).
public struct ProposedGrant: Codable, Equatable, Sendable {
    public var scope: String
    public var durationSeconds: Int?

    public init(scope: String, durationSeconds: Int? = nil) { self.scope = scope; self.durationSeconds = durationSeconds }
}

/// An item in the owner's Inbox. Gate asks (`prd`, `architecture`, `sprintPlan`, `release`) are prerequisites for later
/// work; `other` asks carry a category; `info` asks are questions. Only `Store.ownerDecide`, `ownerAnswer`,
/// `ownerReplan` and `acknowledge` give an owner answer.
public struct Ask: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ask"

    public var id: String
    public var companyId: String
    public var number: Int
    public var kind: AskKind
    public var category: String?
    public var risk: AskRisk
    /// An agent id, or "system" for an engine-filed ask.
    public var requesterId: String
    public var itemId: String?
    public var title: String
    public var summary: String
    public var payload: AskPayload?
    /// FNV of the document's bytes when it was proposed; `Store.ownerDecide` compares it on approval.
    public var detailsHash: String?
    public var proposedGrant: ProposedGrant?
    public var status: AskStatus
    public var internalApproverId: String?
    public var internalNote: String?
    public var internalDecidedAt: Date?
    public var ownerNote: String?
    public var ownerAnswer: String?
    public var ownerDecidedAt: Date?
    /// "owner", "@<handle>" or "policy:<preset>".
    public var decidedBy: String?
    /// Approved by policy: the owner is only told.
    public var fyi: Bool = false
    public var acknowledgedAt: Date?
    public var subjectId: String?
    public var supersedesId: String?
    public var escalatedAt: Date?
    public var rescindedAt: Date?
    public var createdActive: Double
    public var statusSinceActive: Double
    public var expiresActive: Double?
    public var remindCount: Int = 0
    public var notifiedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var requestId: String? = nil
    public var decisionClass: DecisionClass = .taste

    /// "A-<number>".
    public var ref: String { "A-\(number)" }
}

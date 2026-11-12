import Foundation
import BrahmaCore

/// Optional people data (Plan 3b's trust, perks, meters, dotted lines, staffing). Nothing in the map depends on 3b: a
/// provider fills these in when one exists; synthetic mode and a company without a provider use `MapPeople.empty`.

public struct MapTrust: Equatable, Sendable {
    /// e.g. "T2".
    public var label: String
    public var title: String
    /// 0…3.
    public var tier: Int

    public init(label: String, title: String, tier: Int) { self.label = label; self.title = title; self.tier = tier }
}

public struct MapMeter: Equatable, Sendable {
    /// e.g. "4 ITEMS · 75% · 0.9×".
    public var line: String
    public var fraction: Double?

    public init(line: String, fraction: Double?) { self.line = line; self.fraction = fraction }
}

public enum DottedKind: String, Equatable, Sendable {
    case reviewer, navigator, other
}

/// A dotted (non-reporting) line between two agents, e.g. a reviewer on an item.
public struct DottedLink: Hashable, Sendable {
    public var from: String
    public var to: String
    public var kind: DottedKind
    public var itemKey: String

    public init(from: String, to: String, kind: DottedKind, itemKey: String) {
        self.from = from; self.to = to; self.kind = kind; self.itemKey = itemKey
    }
}

public struct MapPeople: Equatable, Sendable {
    public var trust: [String: MapTrust] = [:]
    /// Agent id → at most 2 emoji.
    public var perks: [String: [String]] = [:]
    public var meters: [String: MapMeter] = [:]
    public var dotted: [DottedLink] = []
    /// The controller forces `source = .provider` on these.
    public var vacancies: [Vacancy] = []

    public static let empty = MapPeople()

    public init(trust: [String: MapTrust] = [:], perks: [String: [String]] = [:], meters: [String: MapMeter] = [:],
                dotted: [DottedLink] = [], vacancies: [Vacancy] = []) {
        self.trust = trust; self.perks = perks; self.meters = meters; self.dotted = dotted; self.vacancies = vacancies
    }
}

/// Loads people data for a live company. Called only for live sources.
public protocol MapPeopleProviding: Sendable {
    func load(store: Store, companyId: String, now: Date) throws -> MapPeople
}

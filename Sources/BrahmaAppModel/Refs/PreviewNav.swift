import Foundation
import BrahmaCore

/// How a ref came to be in the OPENED slot (collab design §1.5): the owner opened it, a `show` answer to an owner request
/// opened it (`requestId`, and who answered: `"@eng-1"` or `"Brahma"`), or the owner opened a card in chat.
public enum OpenOrigin: Equatable, Sendable, Codable {
    case owner
    case showAnswer(requestId: String, by: String)
    case card(messageId: String)
}

/// The ref in the OPENED slot: its engine title (gated before it is stored here), a kind chip (`ITEM`, `FILE`, …) and, for a
/// multi-ref show answer, the steps it is one of.
public struct OpenedRef: Equatable, Sendable, Codable {
    public var ref: WorkRef
    public var title: String
    public var kindChip: String
    public var origin: OpenOrigin
    public var steps: [WorkRef]?
    public var stepIndex: Int?

    public init(ref: WorkRef, title: String, kindChip: String, origin: OpenOrigin, steps: [WorkRef]? = nil, stepIndex: Int? = nil) {
        self.ref = ref; self.title = title; self.kindChip = kindChip; self.origin = origin; self.steps = steps; self.stepIndex = stepIndex
    }

    // C6 fix round 1 (M12): what UserDefaults keeps is canonicals only (no agent-written notes, no titles); the app re-resolves and
    // re-gates the title on restore (`AppModel.refreshOpenedTitle`).
    enum CodingKeys: String, CodingKey { case ref, origin, steps, stepIndex }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ref = Self.stripped(try c.decode(WorkRef.self, forKey: .ref))
        self.ref = ref
        title = ""
        kindChip = Self.kindChip(for: ref)
        origin = try c.decode(OpenOrigin.self, forKey: .origin)
        steps = try c.decodeIfPresent([WorkRef].self, forKey: .steps)?.map(Self.stripped)
        stepIndex = try c.decodeIfPresent(Int.self, forKey: .stepIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.stripped(ref), forKey: .ref)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(steps?.map(Self.stripped), forKey: .steps)
        try c.encodeIfPresent(stepIndex, forKey: .stepIndex)
    }

    /// The ref without agent-written parameters (`note`).
    public static func stripped(_ ref: WorkRef) -> WorkRef {
        var r = ref
        r.params["note"] = nil
        return r
    }

    /// The step chips (`"1 PREVIEW"`, `"2 ARTIFACT"`, …), nil without steps.
    public var stepChips: [String]? {
        steps.map { $0.enumerated().map { "\($0.offset + 1) \(Self.kindChip(for: $0.element))" } }
    }

    /// The chip of a ref's kind: its kind uppercased.
    public static func kindChip(for ref: WorkRef) -> String { ref.kind.rawValue.uppercased() }
}

/// The preview's OPENED slot and its history (design §1.5): one opened ref, the selected tab and ≤ `maxHistory` back and
/// forward entries. Saved per company in `UserDefaults` (`PreviewNavStore`).
public struct PreviewNav: Equatable, Sendable, Codable {
    public static let maxHistory = 50

    public var opened: OpenedRef?
    /// A `PreviewTabID`; `""` leaves the pane on its default tab.
    public var selection: String = ""
    public var back: [OpenedRef] = []
    public var forward: [OpenedRef] = []

    public init() {}

    /// Puts `r` in the slot: what was there goes to `back` (capped), `forward` is cleared, and with `select` the OPENED tab is selected.
    public mutating func open(_ r: OpenedRef, select: Bool) {
        if let current = opened {
            back.append(current)
            if back.count > Self.maxHistory { back.removeFirst(back.count - Self.maxHistory) }
        }
        forward = []
        opened = r
        if select { selection = PreviewTabID.ref }
    }

    @discardableResult
    public mutating func goBack() -> Bool {
        guard let previous = back.popLast() else { return false }
        if let current = opened {
            forward.append(current)
            if forward.count > Self.maxHistory { forward.removeFirst(forward.count - Self.maxHistory) }
        }
        opened = previous
        selection = PreviewTabID.ref
        return true
    }

    @discardableResult
    public mutating func goForward() -> Bool {
        guard let next = forward.popLast() else { return false }
        if let current = opened {
            back.append(current)
            if back.count > Self.maxHistory { back.removeFirst(back.count - Self.maxHistory) }
        }
        opened = next
        selection = PreviewTabID.ref
        return true
    }

    /// Shows step `i` of a multi-ref answer in the slot (not a history move); out of range leaves it as it is.
    public mutating func step(to i: Int) {
        guard var r = opened, let steps = r.steps, steps.indices.contains(i) else { return }
        r.ref = steps[i]
        r.stepIndex = i
        r.kindChip = OpenedRef.kindChip(for: steps[i])
        opened = r
    }

    /// Closes the slot (the OPENED tab goes away); history is kept so Back brings it back.
    public mutating func close() {
        if let current = opened {
            back.append(current)
            if back.count > Self.maxHistory { back.removeFirst(back.count - Self.maxHistory) }
        }
        opened = nil
        if selection == PreviewTabID.ref { selection = "" }
    }
}

/// Where `PreviewNav` is kept: `UserDefaults` under `brahma.previewNav.<companyId>` (UI state, per company). Every access is
/// `try?`: a value that doesn't decode is an empty state.
public enum PreviewNavStore {
    public static func key(_ companyId: String) -> String { "brahma.previewNav.\(companyId)" }

    public static func load(companyId: String, defaults: UserDefaults = .standard) -> PreviewNav {
        guard let data = defaults.data(forKey: key(companyId)) else { return PreviewNav() }
        return (try? JSONDecoder().decode(PreviewNav.self, from: data)) ?? PreviewNav()
    }

    public static func save(_ n: PreviewNav, companyId: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(n) else { return }
        defaults.set(data, forKey: key(companyId))
    }
}

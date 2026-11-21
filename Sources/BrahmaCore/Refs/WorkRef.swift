import Foundation

/// What a work ref names (collab design §1.1). `sprint` and `fact` are C's additions: `fact` is internal (the app and deep
/// links only, `RefContext.allowInternal`).
public enum WorkRefKind: String, Codable, CaseIterable, Sendable {
    case file, diff, commit, item, ask, kb, memory, artifact, resource, preview, run, release, message, thread, agent, channel
    case sprint, fact
}

/// Lines `start...end`, 1-based, `end ≥ start`, at most `maxSpan` lines.
public struct LineRange: Codable, Hashable, Sendable {
    public static let maxSpan = 2000

    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) { self.start = start; self.end = end }

    /// Nil unless `1 ≤ start ≤ end` and the span is at most `maxSpan` lines.
    public static func checked(start: Int, end: Int) -> LineRange? {
        guard start >= 1, end >= start, end - start + 1 <= maxSpan else { return nil }
        return LineRange(start: start, end: end)
    }
}

/// A reference to a piece of company work, in the text grammar of design §1.2 (`RefGrammar`).
public struct WorkRef: Codable, Hashable, Sendable {
    public var kind: WorkRefKind
    /// Item key, number, path, handle, message id, kb page path or surface name, by kind.
    public var id: String
    /// file/diff: nil (main), `item/<KEY>` or `worktree:<KEY>` (uncommitted, live).
    public var branch: String?
    /// Set by the engine (pinning) or a verified hex sha from the grammar.
    public var rev: String?
    /// file only.
    public var range: LineRange?
    /// preview: `path`, `viewport`; diff: `file`; kb: `section`; run: `item` (its latest run); pins: `was`, `main`.
    public var params: [String: String]

    public init(kind: WorkRefKind, id: String, branch: String? = nil, rev: String? = nil, range: LineRange? = nil,
                params: [String: String] = [:]) {
        self.kind = kind; self.id = id; self.branch = branch; self.rev = rev; self.range = range; self.params = params
    }

    /// The text form; `parse(canonical)` gives this ref back (pin-only params, `was` and `main`, are not part of it).
    public var canonical: String { RefGrammar.canonical(self) }

    /// The ref `s` names, or nil. The text is NFC-normalized and refused whole when it holds a control, bidi or zero-width
    /// character (`RefText.normalize`).
    public static func parse(_ s: String, context: RefContext) -> WorkRef? { RefGrammar.parse(s, context: context) }

    /// The item key of a file or diff on an item branch or worktree.
    var itemKey: String? {
        guard let branch else { return nil }
        if branch.hasPrefix("item/") { return String(branch.dropFirst(5)) }
        if branch.hasPrefix("worktree:") { return String(branch.dropFirst(9)) }
        return nil
    }

    var isWorktree: Bool { branch?.hasPrefix("worktree:") == true }
}

/// C's flat access word for a ref (what `RefDecision` carries), derived from ML's class and sensitivity.
public enum RefAccessLabel: String, Codable, Sendable {
    case company, channel, dm, team, item, agent, restricted, hrPerf, secret, privateToAgent, owner

    public static func label(access: AccessClass, sensitivity: Sensitivity, restrictions: [Restriction],
                             readerSet: Set<String>?) -> RefAccessLabel {
        if sensitivity == .secret { return .secret }
        if sensitivity == .hrPerf { return .hrPerf }
        if sensitivity == .restricted || !restrictions.isEmpty { return .restricted }
        switch access {
        case .role: return .restricted
        case .ownerOnly: return .owner
        case .agent(let id): return readerSet == [id] ? .privateToAgent : .agent
        case .company: return .company
        case .team: return .team
        case .item: return .item
        case .channel: return .channel
        case .dm: return .dm
        }
    }
}

/// What a reader may see of a resolved ref (design §4.2).
public enum Visibility: Equatable, Sendable {
    case full
    case locked(approverRole: String)
    case refused
    case missing
}

public enum RefState: String, Codable, Sendable {
    case ok, tooLarge, redacted, purged
}

/// What relative and internal forms resolve against.
public struct RefContext: Sendable {
    public var companyId: String
    /// The company's item key prefixes.
    public var keyPrefixes: Set<String>
    public var currentItemKey: String?
    public var currentChannelId: String?
    public var actingAgentId: String?
    /// Only the app and deep links set it: enables `fact:`.
    public var allowInternal: Bool

    public init(companyId: String, keyPrefixes: Set<String>, currentItemKey: String? = nil, currentChannelId: String? = nil,
                actingAgentId: String? = nil, allowInternal: Bool = false) {
        self.companyId = companyId; self.keyPrefixes = keyPrefixes; self.currentItemKey = currentItemKey
        self.currentChannelId = currentChannelId; self.actingAgentId = actingAgentId; self.allowInternal = allowInternal
    }
}

/// A ref as one reader may see it. For `.locked`, `.refused` and `.missing` everything but the kind and `opaqueId` is
/// blanked before it leaves the resolver.
public struct ResolvedRef: Equatable, Sendable {
    public var ref: WorkRef
    public var reader: Reader
    public var visibility: Visibility
    /// Engine-derived; agent-chosen text in it is flattened, stripped of hidden characters and capped (`SafeTitle`).
    public var title: String
    public var subtitle: String
    public var bytes: Int?
    public var provenance: Provenance
    public var tainted: Bool
    public var taintReason: String?
    public var accessClass: AccessClass
    /// A newer revision exists.
    public var newer: WorkRef?
    public var state: RefState
    /// A fresh handle (`StableHash` of the company and the message ref, or a random nonce): never an existence oracle.
    public var opaqueId: String

    public init(ref: WorkRef, reader: Reader, visibility: Visibility, title: String, subtitle: String, bytes: Int?,
                provenance: Provenance, tainted: Bool, taintReason: String?, accessClass: AccessClass, newer: WorkRef?,
                state: RefState, opaqueId: String) {
        self.ref = ref; self.reader = reader; self.visibility = visibility; self.title = title; self.subtitle = subtitle
        self.bytes = bytes; self.provenance = provenance; self.tainted = tainted; self.taintReason = taintReason
        self.accessClass = accessClass; self.newer = newer; self.state = state; self.opaqueId = opaqueId
    }
}

/// Text safety for refs (design §1.2, §4.6).
public enum RefText {
    /// NFC; nil when the text holds a C0/C1 control (other than `\n` and `\t`), a bidi control or a zero-width character.
    public static func normalize(_ s: String) -> String? {
        for scalar in s.unicodeScalars {
            let v = scalar.value
            if v == 0x0A || v == 0x09 { continue }
            if isHidden(v) { return nil }
        }
        return s.precomposedStringWithCanonicalMapping
    }

    /// C0/C1 controls, DEL, bidi controls and zero-width characters.
    static func isHidden(_ v: UInt32) -> Bool {
        v < 0x20 || (0x7F...0x9F).contains(v) || isBidiOrZeroWidth(v)
    }

    static func isBidiOrZeroWidth(_ v: UInt32) -> Bool {
        (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200E || v == 0x200F || v == 0x061C
            || (0x200B...0x200D).contains(v) || v == 0x2060 || v == 0xFEFF
    }
}

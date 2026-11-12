import Foundation
import BrahmaCore

/// The Inbox card of a `deploy` ask: the exact engine-composed commands the owner approves (agent text inside is shown with
/// `Text(verbatim:)`). Approval goes through `ownerDecide` only.
public struct DeployCard: Equatable, Sendable {
    public var askId: String
    public var ref: String
    public var title: String
    /// "release <version>".
    public var version: String
    /// sha7.
    public var commit: String
    public var provider: String
    /// "@handle".
    public var proposer: String
    /// The ask's proposal, verbatim (else the plan's display).
    public var commands: String
    public var smokeLine: String
    public var mainHealth: MainHealth

    public static func make(ask: Ask, release: Release?, health: MainHealth, handles: [String: String]) -> DeployCard? {
        guard ask.kind == .deploy, let release else { return nil }
        return DeployCard(askId: ask.id, ref: ask.ref, title: ask.title, version: "release \(release.version)", commit: release.sha7,
                          provider: release.provider.title, proposer: "@" + (handles[release.proposedById] ?? release.proposedById),
                          commands: ask.payload?.proposal ?? release.plan.display, smokeLine: health.title, mainHealth: health)
    }
}

/// The Inbox card of a `humanTask` ask. Titles, steps, link titles, the reason and the post text are agent-controlled
/// (`Text(verbatim:)`); links render as their host plus an Open button.
public struct HumanTaskCard: Equatable, Sendable {
    public var askId: String
    public var ref: String
    public var title: String
    /// "@handle", or "system" for an engine-filed task.
    public var requester: String
    public var itemKey: String?
    public var reason: String
    public var steps: [String]
    public var links: [HumanTaskLink]
    public var fields: [HumanTaskField]
    public var postText: String?
    /// `HumanTaskPolicy.customFieldCaption` for a custom (agent-written) task.
    public var caption: String?

    public static func make(ask: Ask, handles: [String: String], itemKeys: [String: String]) -> HumanTaskCard? {
        guard let task = HumanTask.from(ask) else { return nil }
        let requester = ask.requesterId == "system" ? "system" : "@" + (handles[ask.requesterId] ?? ask.requesterId)
        return HumanTaskCard(askId: ask.id, ref: ask.ref, title: task.title, requester: requester,
                             itemKey: ask.itemId.flatMap { itemKeys[$0] }, reason: ask.summary, steps: task.steps, links: task.links,
                             fields: task.fields, postText: task.postText, caption: task.template == nil ? HumanTaskPolicy.customFieldCaption : nil)
    }
}

/// The owner's paste-back values. Validation is the Store's own (`Store.checkedValues`, PR-39).
public struct HumanTaskForm: Equatable, Sendable {
    public var values: [String: String]
    /// The launch post as the owner edited it (posted from the owner's own account; never sent by the engine).
    public var editedPost: String?

    public init(values: [String: String] = [:], editedPost: String? = nil) {
        self.values = values; self.editedPost = editedPost
    }

    /// The form for `card` from the card's field values (empty ones left out; the post only when the card has one). Every
    /// secret field's entry is removed from `values` each time, whether the form later validates or not, so a pasted key is
    /// not kept in view state longer than the submit (constraint: secrets are not held in view state).
    public static func make(_ card: HumanTaskCard, values: inout [String: String], editedPost: String?) -> HumanTaskForm {
        let form = HumanTaskForm(values: values.filter { !$0.value.isEmpty }, editedPost: card.postText == nil ? nil : editedPost)
        for field in card.fields where field.isSecret { values[field.name] = nil }
        return form
    }

    public func validate(_ card: HumanTaskCard) -> String? {
        let task = HumanTask(template: nil, title: card.title, steps: card.steps, links: card.links, fields: card.fields)
        do { _ = try Store.checkedValues(task, values) } catch let e as WorkError { return e.message } catch { return "\(error)" }
        return nil
    }
}

/// What the Inbox shows for a pending `deploy` or `humanTask` ask whose live card can't be built (I3): never the generic card,
/// whose Approve would skip the exact commands and the main-health gate.
public enum LiveCardFallback: Equatable, Sendable {
    /// A deploy ask without its release record: read-only, Reject only.
    case deployUnavailable
    /// A human task whose payload doesn't parse: Can't do… only (the core decline does not read the payload).
    case humanTaskUnreadable

    /// nil when the row has its card, isn't pending, or is another kind (the generic card applies).
    public static func `for`(row: InboxRow, deployCard: DeployCard?, humanTaskCard: HumanTaskCard?) -> LiveCardFallback? {
        guard row.section == .pending else { return nil }
        switch row.kind {
        case .deploy: return deployCard == nil ? .deployUnavailable : nil
        case .humanTask: return humanTaskCard == nil ? .humanTaskUnreadable : nil
        default: return nil
        }
    }

    public func title(ref: String) -> String {
        switch self {
        case .deployUnavailable: "DEPLOY · \(ref): release record unavailable"
        case .humanTaskUnreadable: "HUMAN TASK · \(ref): task details unreadable"
        }
    }

    public var canApprove: Bool { false }
    public var canReject: Bool { self == .deployUnavailable }
    public var canDecline: Bool { self == .humanTaskUnreadable }
}

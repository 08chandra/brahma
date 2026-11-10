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

    public func validate(_ card: HumanTaskCard) -> String? {
        let task = HumanTask(template: nil, title: card.title, steps: card.steps, links: card.links, fields: card.fields)
        do { _ = try Store.checkedValues(task, values) } catch let e as WorkError { return e.message } catch { return "\(error)" }
        return nil
    }
}

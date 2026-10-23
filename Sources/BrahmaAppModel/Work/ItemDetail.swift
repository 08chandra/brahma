import Foundation
import BrahmaCore

/// What the backlog inspector shows besides the item's own fields: its newest events, what it waits for, and where its work lives.
public struct ItemDetail: Equatable, Sendable {
    public struct EventLine: Equatable, Sendable, Identifiable {
        public var id: Int64
        public var time: Date
        public var actor: String
        public var kind: String
        public var text: String
    }

    public struct Dependency: Equatable, Sendable, Identifiable {
        public var key: String
        public var title: String
        public var status: WorkItemStatus
        public var id: String { key }
    }

    /// The inspector shows this many events, newest first.
    public static let eventLimit = 20

    public var key: String
    public var events: [EventLine] = []
    public var dependencies: [Dependency] = []
    /// The mono tail of the newest check run's output, nil when there is none.
    public var checkTail: String?
    /// "item/<KEY>" while the item has a branch or a lease.
    public var branch: String?
    public var worktree: String?
    public var parentKey: String?

    public static func load(store: Store, item: WorkItem, handles: [String: String], workspace: String) throws -> ItemDetail {
        var d = ItemDetail(key: item.key)
        let events = try store.itemEvents(itemId: item.id, limit: eventLimit)
        d.events = events.reversed().compactMap { e in
            e.id.map {
                EventLine(id: $0, time: e.createdAt,
                          actor: e.actorId == "owner" ? "you" : (handles[e.actorId].map { "@" + $0 } ?? "Brahma"),
                          kind: e.kind.rawValue, text: e.text)
            }
        }
        d.dependencies = try store.dependencies(itemId: item.id).map { Dependency(key: $0.key, title: $0.title, status: $0.status) }
        if let run = try store.latestVerifications(companyId: item.companyId)[item.id], let tail = run.outputTail, !tail.isEmpty {
            d.checkTail = tail
        }
        let hasLease = try store.lease(itemId: item.id) != nil
        if hasLease || item.linkedBranch != nil || item.status == .inProgress || item.status == .inReview {
            d.branch = item.linkedBranch ?? "item/\(item.key)"
            if !workspace.isEmpty {
                d.worktree = GitWorkspace(root: URL(fileURLWithPath: workspace, isDirectory: true)).worktreePath(key: item.key).path
            }
        }
        if let parent = item.parentId { d.parentKey = try store.workItem(id: parent)?.key }
        return d
    }
}

extension AppModel {
    /// The inspector's extra detail for an item, read off the main actor.
    public func itemDetail(key: String) async -> ItemDetail? {
        guard let item = item(key: key) else { return nil }
        let store = self.store, handles = self.handles, workspace = work.workspace
        return try? await Task.detached { try ItemDetail.load(store: store, item: item, handles: handles, workspace: workspace) }.value
    }

    /// The company's own auto-merge toggle (off by default; turning it off revokes). Never goes through `updateCompany`.
    public func setAutoMergeSmall(_ on: Bool) async {
        guard let companyId = selectedCompanyId else { return }
        let store = self.store
        do {
            try await Task.detached { try store.setAutoMergeSmall(companyId: companyId, on) }.value
            await tick(forceSnapshot: true)
        } catch {
            errorMessage = "Couldn't change auto-merge: \(error)"
        }
    }

    public var autoMergeSmall: Bool { selectedCompany?.company.autoMergeSmall ?? false }

    /// Takes the plan tier the CLI reported as the configured one (the owner confirmed the alert).
    public func confirmReportedPlan() async {
        let store = self.store
        do {
            try await Task.detached {
                guard let reported = try store.latestProbe()?.reportedSubscription,
                      let tier = PlanTier(reportedSubscription: reported) else { return }
                try store.setPlanTier(tier)
            }.value
            await tick(forceSnapshot: true)
        } catch {
            errorMessage = "Couldn't save the plan: \(error)"
        }
    }
}

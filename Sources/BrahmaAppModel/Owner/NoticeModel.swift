import Foundation
import BrahmaCore

/// Shows a banner to the owner. `post` returns true once the system accepted it; false (a failure) means the asks and
/// notices behind that banner are not marked delivered and are planned again later. `canPost` false (not authorized)
/// skips planning altogether.
@MainActor
public protocol NotificationPosting: AnyObject {
    var canPost: Bool { get }
    func post(_ notice: PostedNotice) async -> Bool
}

extension AppModel {
    /// Plans owner notifications over the asks waiting without a banner and the undelivered notices (quiet hours, urgency
    /// and batching are `NoticeDelivery.plan`), posts them, then marks delivered what is behind each banner that posted.
    /// A failed banner keeps its asks and notices due (a failed summary keeps all of its members); banner ids are stable,
    /// so a retry replaces a copy instead of adding one. Nothing is planned while the poster cannot post.
    public func deliverNotices() async {
        guard let poster, poster.canPost, !delivering else { return }
        delivering = true
        defer { delivering = false }
        let store = self.store, now = Date()
        do {
            let plan: DeliveryPlan = try await Task.detached {
                NoticeDelivery.plan(dueAsks: try store.dueAskNotices(), notices: try store.undeliveredNotices(),
                                    prefs: try store.ownerPrefs(), now: now, tz: store.ownerTimeZone())
            }.value
            var failed: [PostedNotice] = []
            for notice in plan.post where !(await poster.post(notice)) { failed.append(notice) }
            let marks = plan.marks(failed: failed)
            guard !(marks.asks.isEmpty && marks.notices.isEmpty) else { return }
            try await Task.detached {
                try store.markAskNotified(planned: marks.asks, now: now)
                try store.markNoticesDelivered(ids: marks.notices, now: now)
            }.value
        } catch {
            report(error)
        }
    }
}

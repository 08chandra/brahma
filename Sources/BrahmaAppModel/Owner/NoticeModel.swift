import Foundation
import BrahmaCore

/// Shows a banner to the owner. `post` returns true once the system accepted it; false (not authorized, a failure) means
/// the notice is not marked delivered and is planned again later.
@MainActor
public protocol NotificationPosting: AnyObject {
    func post(_ notice: PostedNotice) async -> Bool
}

extension AppModel {
    /// Plans owner notifications over the asks waiting without a banner and the undelivered notices (quiet hours, urgency
    /// and batching are `NoticeDelivery.plan`), posts them, then marks them delivered. When any post fails nothing is
    /// marked: the same banner ids replace each other, so a retry never shows a second copy.
    public func deliverNotices() async {
        guard let poster, !delivering else { return }
        delivering = true
        defer { delivering = false }
        let store = self.store, now = Date()
        do {
            let plan: DeliveryPlan = try await Task.detached {
                NoticeDelivery.plan(dueAsks: try store.dueAskNotices(), notices: try store.undeliveredNotices(),
                                    prefs: try store.ownerPrefs(), now: now, tz: store.ownerTimeZone())
            }.value
            var allPosted = true
            for notice in plan.post where !(await poster.post(notice)) { allPosted = false }
            guard allPosted, !(plan.markAsks.isEmpty && plan.markNotices.isEmpty) else { return }
            try await Task.detached {
                try store.markAskNotified(ids: plan.markAsks, now: now)
                try store.markNoticesDelivered(ids: plan.markNotices, now: now)
            }.value
        } catch {
            report(error)
        }
    }
}

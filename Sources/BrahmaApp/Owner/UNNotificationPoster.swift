import Foundation
import UserNotifications
import BrahmaCore
import BrahmaAppModel

/// Banners through the system notification center. Banners are grouped per company (`threadIdentifier`); a click opens
/// the main window and applies the banner's target (`ask:<id>` selects the Inbox and that ask, `inbox` the Inbox).
/// If notifications are not authorized, `post` returns false, so nothing is marked and a later grant still announces
/// what is waiting.
@MainActor
final class UNNotificationPoster: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    private let model: AppModel
    private var center: UNUserNotificationCenter?
    private var authorized = false
    var openMainWindow: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Does nothing outside a real app bundle (a bare `swift run` binary has no notification center) or when `prompt`
    /// is false (smoke and snapshot runs must not raise a system dialog).
    func start(prompt: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        self.center = center
        center.delegate = self
        guard prompt else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor [weak self] in self?.authorized = granted }
        }
        model.poster = self
    }

    func post(_ notice: PostedNotice) async -> Bool {
        guard authorized, let center else { return false }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = notice.companyId ?? "brahma"
        content.userInfo = ["target": notice.target, "companyId": notice.companyId ?? ""]
        do {
            try await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A banner is shown even while Brahma is frontmost: the Inbox may not be on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let target = info["target"] as? String ?? "inbox"
        let companyId = (info["companyId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        await MainActor.run {
            openMainWindow()
            Task { @MainActor in
                if let companyId { await model.selectCompany(companyId) }
                model.apply(SelectTarget(target) ?? .inbox)
            }
        }
    }
}

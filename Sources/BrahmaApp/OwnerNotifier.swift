import Foundation
import UserNotifications
import BrahmaAppModel

/// Banners for asks waiting on the owner. After each model tick the app posts `dueNotifications()` (identifier
/// `ask-<id>-<remindCount>`) and then calls `markNotified`; a click opens that company's Inbox. If notifications are
/// not authorized nothing is shown and nothing is marked, so a later grant still announces what is waiting.
@MainActor
final class OwnerNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel
    private var center: UNUserNotificationCenter?
    private var authorized = false
    private var pumping = false
    var openMainWindow: () -> Void = {}

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    /// Asks for authorization at launch. Does nothing outside a real app bundle (a bare `swift run` binary has no
    /// notification center) or when `prompt` is false (smoke and snapshot runs must not raise a system dialog).
    func start(prompt: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        self.center = center
        center.delegate = self
        guard prompt else { return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor [weak self] in self?.authorized = granted }
        }
        model.afterTick = { [weak self] in await self?.pump() }
    }

    /// Posts what is due, then marks it notified.
    func pump() async {
        guard authorized, let center, !pumping else { return }
        pumping = true
        defer { pumping = false }
        let due = await model.dueNotifications()
        guard !due.isEmpty else { return }
        var posted: [String] = []
        for n in due {
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            content.sound = .default
            content.userInfo = ["companyId": n.companyId, "askId": n.askId]
            let request = UNNotificationRequest(identifier: n.identifier, content: content, trigger: nil)
            do {
                try await center.add(request)
                posted.append(n.askId)
            } catch {
                continue
            }
        }
        await model.markNotified(posted)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A banner for an ask is shown even while Brahma is frontmost: the Inbox may not be on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A click selects the ask's company and the Inbox.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let companyId = response.notification.request.content.userInfo["companyId"] as? String else { return }
        await MainActor.run {
            openMainWindow()
            Task { @MainActor in
                await model.selectCompany(companyId)
                model.select(.inbox)
            }
        }
    }
}

import AppKit
import UserNotifications

/// Mac notifications for things that happen while Nokcandu is in the background (a store game was added,
/// a game didn't start, a game is low on memory). Clicking one opens that game's page. While Nokcandu is in
/// front, its own banner and Recent Activity are enough, so nothing is posted.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Called with a game's id when its notification is clicked.
    var open: ((String) -> Void)?
    private var asked = false

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "macNotifications") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "macNotifications") }
    }

    func start(open: @escaping (String) -> Void) {
        self.open = open
        UNUserNotificationCenter.current().delegate = self
    }

    static func post(title: String, body: String, gameID: String?) {
        guard enabled, NSApp?.isActive != true else { return }
        shared.post(title: title, body: body, gameID: gameID)
    }

    private func post(title: String, body: String, gameID: String?) {
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body
            if let gameID { content.userInfo = ["game": gameID] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if asked { send(); return }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { send() } }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["game"] as? String
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let id { Notifier.shared.open?(id) }
            completionHandler()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

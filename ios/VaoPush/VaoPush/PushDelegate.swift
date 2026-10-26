import UIKit
import UserNotifications
import VaoPushCore

final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        do {
            let token = deviceToken.map { String(format: "%02x", $0) }.joined()
            try CredentialVault.save(Data(token.utf8), id: "installation-apns")
            UserDefaults.standard.set("已连接", forKey: "apns-registration-status")
            NotificationCenter.default.post(name: .vaoPushRegistrationChanged, object: nil)
        } catch { UserDefaults.standard.set("凭证保存失败", forKey: "apns-registration-status") }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        UserDefaults.standard.set("推送暂未连接，请检查网络后重试", forKey: "apns-registration-status")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        NotificationCenter.default.post(name: .vaoPushContentReceived, object: nil)
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler()
            return
        }
        let content = response.notification.request.content
        let payload = (try? JSONSerialization.data(withJSONObject: content.userInfo)) ?? Data()
        let title = content.title
        let body = content.body
        Task { @MainActor in
            AppNavigation.shared.openMessage(payload: payload, title: title, body: body)
            NotificationCenter.default.post(name: .vaoPushContentReceived, object: nil)
            completionHandler()
        }
    }
}

extension Notification.Name {
    static let vaoPushRegistrationChanged = Notification.Name("VaoPushRegistrationChanged")
    static let vaoPushContentReceived = Notification.Name("VaoPushContentReceived")
}

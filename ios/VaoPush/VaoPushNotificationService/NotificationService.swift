import Foundation
import UserNotifications
import WidgetKit
import VaoPushCore
import os

final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var pending: UNNotificationContent?
    private let logger = Logger(subsystem: "app.vaovao.push", category: "NotificationService")

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock { handler = contentHandler; pending = request.content }
        defer { finish() }
        do {
            let store = try PrototypeStorage.open()
            let payload = try JSONSerialization.data(withJSONObject: request.content.userInfo)
            let result = try PushReceiver.receive(payload: payload, title: request.content.title,
                body: request.content.body, store: store)
            // Both message templates and data cards read the shared store.
            WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
            if case .state = result {
                if let content = request.content.mutableCopy() as? UNMutableNotificationContent {
                    content.interruptionLevel = .passive
                    content.sound = nil
                    lock.withLock { pending = content }
                }
            }
        } catch {
            logger.error("Push payload rejected or local storage unavailable.")
        }
    }

    override func serviceExtensionTimeWillExpire() { finish() }

    private func finish() {
        let completion = lock.withLock {
            let value = (handler, pending)
            handler = nil; pending = nil
            return value
        }
        if let handler = completion.0, let content = completion.1 { handler(content) }
    }
}

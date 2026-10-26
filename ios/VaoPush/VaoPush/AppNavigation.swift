import Foundation
import Observation

/// Retains a notification tap until the root view is ready, including a cold launch.
@MainActor @Observable
final class AppNavigation {
    static let shared = AppNavigation()
    struct Request {
        let payload: Data
        let title: String
        let body: String
    }
    private(set) var pendingMessage: Request?

    func openMessage(payload: Data, title: String, body: String) {
        pendingMessage = Request(payload: payload, title: title, body: body)
    }
    func consumeMessage() -> Request? {
        defer { pendingMessage = nil }
        return pendingMessage
    }
}

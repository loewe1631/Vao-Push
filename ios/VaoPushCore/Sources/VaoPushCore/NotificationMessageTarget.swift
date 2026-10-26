import Foundation

/// Notification taps only navigate within an already registered local source.
public struct NotificationMessageTarget: Equatable, Sendable {
    public let messageID: String
    private let serverID: String
    private let accountID: String
    private let bindingID: String

    public init(payload: Data) throws {
        struct Content: Decodable {
            let version: Int
            let kind: String
            let server_id: String
            let account_id: String
            let binding_id: String
            let message_id: String
        }
        struct Envelope: Decodable { let vao_push: Content }
        guard payload.count <= 4096 else { throw CoreError.invalid("APNs 载荷超过 4 KiB") }
        let content = try JSONDecoder().decode(Envelope.self, from: payload).vao_push
        guard content.version == 1, content.kind == "message",
              [content.server_id, content.account_id, content.binding_id, content.message_id]
                .allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw CoreError.invalid("消息通知身份无效")
        }
        serverID = content.server_id
        accountID = content.account_id
        bindingID = content.binding_id
        messageID = content.message_id
    }

    public func owner(in connections: [ServerConnection]) -> String? {
        let matches = connections.filter {
            $0.isEnabled && !$0.isDemo && $0.serverID == serverID &&
                $0.accountID == accountID && $0.bindingID == bindingID
        }
        return matches.count == 1 ? matches[0].owner : nil
    }
}

import Foundation

/// Shared parsing for the notification extension and foreground notification delivery.
/// The account comes from the local binding, never from an untrusted payload.
public enum PushReceiver {
    public enum Result: Equatable, Sendable { case message, state(SnapshotWriteResult) }

    @discardableResult
    public static func receive(payload: Data, boundAccount: String, title: String, body: String,
                               store: SharedStore, owner: String? = nil) throws -> Result {
        guard payload.count <= 4096 else { throw CoreError.invalid("APNs 载荷超过 4 KiB") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: payload)
        let push = envelope.push
        guard push.version == 1, !boundAccount.isEmpty, push.accountID == boundAccount else {
            throw CoreError.invalid("推送版本或账号不匹配")
        }
        switch push.kind {
        case "message":
            guard let id = push.messageID, let received = push.receivedAt else {
                throw CoreError.invalid("消息缺少身份或时间")
            }
            try store.archive(ArchivedMessage(id: id, title: title, body: body, receivedAt: received), owner: owner ?? boundAccount)
            return .message
        case "widget_state":
            guard let snapshot = push.snapshot else { throw CoreError.invalid("推送缺少快照") }
            return .state(try store.apply(snapshot, owner: owner ?? boundAccount))
        default: throw CoreError.invalid("不支持的推送类型")
        }
    }

    /// Route only through a locally registered binding. Payload identifiers never create a source.
    @discardableResult
    public static func receive(payload: Data, title: String, body: String, store: SharedStore,
                               allowDemo: Bool = false) throws -> Result {
        guard payload.count <= 4096 else { throw CoreError.invalid("APNs 载荷超过 4 KiB") }
        let push = try JSONDecoder().decode(Envelope.self, from: payload).push
        guard let serverID = push.serverID, let bindingID = push.bindingID else {
            throw CoreError.invalid("推送缺少服务器或设备绑定身份")
        }
        let matches = try store.connections().filter {
            $0.isEnabled && (!$0.isDemo || allowDemo) && $0.serverID == serverID &&
            $0.bindingID == bindingID && $0.accountID == push.accountID
        }
        guard matches.count == 1, let connection = matches.first, let owner = connection.owner else {
            throw CoreError.invalid("推送来源未绑定或已停用")
        }
        return try receive(payload: payload, boundAccount: push.accountID, title: title, body: body,
                           store: store, owner: owner)
    }

    private struct Envelope: Decodable {
        var push: Content
        enum CodingKeys: String, CodingKey { case push = "vao_push" }
    }
    private struct Content: Decodable {
        var version: Int
        var kind: String
        var accountID: String
        var serverID: String?
        var bindingID: String?
        var messageID: String?
        var receivedAt: String?
        var snapshot: StateSnapshot?
        enum CodingKeys: String, CodingKey {
            case version, kind, snapshot
            case accountID = "account_id", messageID = "message_id", receivedAt = "received_at"
            case serverID = "server_id", bindingID = "binding_id"
        }
    }
}

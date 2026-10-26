import Foundation

public struct DeviceCredentials: Codable, Sendable {
    public var serverID: String
    public var accountID: String
    public var bindingID: String
    public var deviceToken: String
    public var readToken: String
    public var sendKey: String?
    public var expiresAt: String
    enum CodingKeys: String, CodingKey {
        case serverID = "server_id", accountID = "account_id", bindingID = "binding_id"
        case deviceToken = "device_token", readToken = "read_token", expiresAt = "expires_at", sendKey = "send_key"
    }
}

public struct SyncedMessage: Codable, Sendable {
    public var messageID: String
    public var title: String
    public var body: String
    public var receivedAt: String
    public var archived: ArchivedMessage { ArchivedMessage(id: messageID, title: title, body: body, receivedAt: receivedAt) }
    enum CodingKeys: String, CodingKey { case messageID = "message_id", receivedAt = "received_at"; case title, body }
}

public struct DeviceSyncPage: Codable, Sendable {
    public var serverID: String
    public var accountID: String
    public var bindingID: String
    public var snapshots: [StateSnapshot]
    public var messages: [SyncedMessage]
    public var cursor: String
    public var hasMore: Bool
    public var deviceName: String?
    enum CodingKeys: String, CodingKey {
        case serverID = "server_id", accountID = "account_id", bindingID = "binding_id", hasMore = "has_more"
        case snapshots, messages, cursor
        case deviceName = "device_name"
    }
}

public enum DeviceClientError: Error, Sendable, LocalizedError {
    case rejected(Int, String)
    case invalidResponse
    public var errorDescription: String? {
        switch self {
        case .rejected(let status, let message): return "\(VaoL10n.text(message)) (\(status))"
        case .invalidResponse: return VaoL10n.text("服务器响应无效，请检查服务版本。")
        }
    }
}

/// Each call uses its explicit server and binding; no global current-account or cookie session.
public final class DeviceClient: Sendable {
    private let session: URLSession
    private let ownsSession: Bool
    public init(session: URLSession? = nil) {
        ownsSession = session == nil
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 15
        self.session = session ?? URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }

    public func connect(baseURL: URL, registrationToken: String, deviceName: String) async throws -> DeviceCredentials {
        let name = try ServerConnection.normalizedDeviceName(deviceName)
        let result: Envelope<DeviceCredentials> = try await request(baseURL, "v1/register", method: "POST",
            body: ["registration_token": registrationToken, "device_name": name, "platform": "ios"])
        let data = result.data
        guard !data.serverID.isEmpty, !data.accountID.isEmpty, !data.bindingID.isEmpty,
              data.deviceToken.count >= 32, data.readToken.count >= 32,
              let key = data.sendKey, key.count == 64, key.allSatisfy({ $0.isHexDigit }),
              ProtocolRules.date(data.expiresAt) != nil else { throw DeviceClientError.invalidResponse }
        return data
    }

    public func sendingKey(baseURL: URL, token: String) async throws -> String {
        let result: Envelope<SendingAccess> = try await request(baseURL, "v1/device/access", token: token)
        guard result.data.sendKey.count == 64, result.data.sendKey.allSatisfy({ $0.isHexDigit }) else { throw DeviceClientError.invalidResponse }
        return result.data.sendKey
    }

    private struct SendingAccess: Decodable {
        var sendKey: String
        enum CodingKeys: String, CodingKey { case sendKey = "send_key" }
    }

    public func pair(baseURL: URL, code: String, deviceName: String) async throws -> DeviceCredentials {
        let result: Envelope<DeviceCredentials> = try await request(baseURL, "v1/pairings/claim", method: "POST",
            body: ["code": code.uppercased().replacingOccurrences(of: " ", with: ""), "device_name": deviceName, "platform": "ios"])
        let data = result.data
        guard !data.serverID.isEmpty, !data.accountID.isEmpty, !data.bindingID.isEmpty,
              data.deviceToken.count >= 32, data.readToken.count >= 32, ProtocolRules.date(data.expiresAt) != nil else {
            throw DeviceClientError.invalidResponse
        }
        return data
    }

    public func sync(baseURL: URL, token: String, cursor: String?) async throws -> DeviceSyncPage {
        guard cursor == nil || cursor!.range(of: "^[0-9]{1,19}$", options: .regularExpression) != nil else {
            throw DeviceClientError.invalidResponse
        }
        let result: Envelope<DeviceSyncPage> = try await request(baseURL, "v1/device/sync", token: token,
            query: [URLQueryItem(name: "cursor", value: cursor ?? "0")])
        guard result.data.cursor.range(of: "^[0-9]{1,19}$", options: .regularExpression) != nil else { throw DeviceClientError.invalidResponse }
        return result.data
    }

    public func register(baseURL: URL, token: String, apns: String?, widget: String?, environment: String) async throws {
        var body: [String: Any] = ["environment": environment]
        if let apns { body["apns_token"] = apns }
        if let widget { body["widget_token"] = widget }
        let _: Envelope<OK> = try await request(baseURL, "v1/device/registration", method: "PUT", token: token, body: body)
    }

    public func subscriptions(baseURL: URL, token: String, dataIDs: [String]) async throws {
        let _: Envelope<OK> = try await request(baseURL, "v1/device/subscriptions", method: "PUT", token: token,
            body: ["data_ids": Array(Set(dataIDs)).sorted()])
    }

    public func setEnabled(baseURL: URL, token: String, enabled: Bool) async throws {
        let _: Envelope<OK> = try await request(baseURL, "v1/device/status", method: "PUT", token: token, body: ["enabled": enabled])
    }

    public func rename(baseURL: URL, token: String, name: String) async throws {
        let name = try ServerConnection.normalizedDeviceName(name)
        let _: Envelope<OK> = try await request(baseURL, "v1/device/name", method: "PUT", token: token,
            body: ["device_name": name])
    }

    public func revoke(baseURL: URL, token: String) async throws {
        let _: Envelope<OK> = try await request(baseURL, "v1/device", method: "DELETE", token: token)
    }

    private struct Envelope<T: Decodable>: Decodable { var data: T }
    private struct OK: Decodable { var ok: Bool }
    private struct ErrorEnvelope: Decodable { struct Detail: Decodable { var message: String }; var error: Detail }

    private func request<T: Decodable>(_ base: URL, _ path: String, method: String = "GET", token: String? = nil,
                                      body: [String: Any]? = nil, query: [URLQueryItem] = []) async throws -> T {
        let normalized = try ServerConnection.endpoint(base.absoluteString)
        var parts = URLComponents(url: normalized.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var req = URLRequest(url: parts.url!)
        req.httpMethod = method; req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            guard !token.isEmpty, token.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }) else { throw DeviceClientError.invalidResponse }
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, bytes.count <= 3 * 1024 * 1024 else {
            throw DeviceClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: bytes).error.message) ?? VaoL10n.text("请求未完成")
            throw DeviceClientError.rejected(http.statusCode, String(message.prefix(200)))
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().split(separator: ";").first == "application/json" else {
            throw DeviceClientError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: bytes)
    }
}

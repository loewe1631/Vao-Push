import Foundation

public struct ServerConnection: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var baseURL: URL
    public var isEnabled: Bool
    public var isDemo: Bool
    public var serverID: String?
    public var accountID: String?
    public var bindingID: String?
    public var checkedAt: String?
    public var syncedAt: String?
    public var messageCursor: String?
    public var deviceName: String?

    public init(id: String = UUID().uuidString, name: String, baseURL: URL, isDemo: Bool = false,
                serverID: String? = nil, accountID: String? = nil, bindingID: String? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.isEnabled = true
        self.isDemo = isDemo; self.serverID = serverID; self.accountID = accountID; self.bindingID = bindingID
    }

    /// Local connection identity, not a payload-provided server name, namespaces all cached objects.
    public var owner: String? {
        guard let accountID, !accountID.isEmpty else { return nil }
        return Self.scope(connectionID: id, accountID: accountID)
    }

    public static func scope(connectionID: String, accountID: String) -> String {
        let data = try! JSONEncoder().encode([connectionID, accountID])
        return "server:" + data.base64EncodedString()
    }

    public static func normalizedDeviceName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, name.utf8.count <= 120,
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CoreError.invalid("请填写便于辨认的设备名称，最多40字，不含换行或控制字符。")
        }
        return name
    }

    public static func endpoint(_ input: String) throws -> URL {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              !parts.percentEncodedPath.lowercased().contains("%2f"),
              !parts.percentEncodedPath.lowercased().contains("%5c"),
              !parts.path.contains("\\"),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CoreError.invalid("请输入 HTTP 或 HTTPS 服务器地址，可包含端口和路径；不含账号、密码、查询参数或片段。")
        }
        parts.scheme = scheme; parts.host = host.lowercased()
        if parts.port == (scheme == "https" ? 443 : 80) { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw CoreError.invalid("服务器地址无效") }
        return url
    }

    public func validate() throws {
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 60, try Self.endpoint(baseURL.absoluteString) == baseURL else {
            throw CoreError.invalid("服务器名称或地址无效")
        }
    }
}

public struct ServerInfo: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var serverID: String
    public var name: String
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version", serverID = "server_id", name
    }
}

/// Discovery carries no credentials. A compatible response is not an authenticated device binding.
public final class ServerInfoClient: Sendable {
    private let session: URLSession
    private let ownsSession: Bool
    public init(session: URLSession? = nil) {
        ownsSession = session == nil
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 10
        self.session = session ?? URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }
    deinit { if ownsSession { session.invalidateAndCancel() } }

    public func inspect(baseURL: URL) async throws -> ServerInfo {
        let endpoint = try ServerConnection.endpoint(baseURL.absoluteString)
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/info"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SnapshotClientError.invalidResponse }
        guard response.statusCode == 200 else { throw SnapshotClientError.unexpectedStatus(response.statusCode) }
        guard bytes.count <= 8 * 1024 else { throw SnapshotClientError.responseTooLarge }
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type"),
              contentType.lowercased().hasPrefix("application/json") else { throw SnapshotClientError.invalidResponse }
        let result = try JSONDecoder().decode(InfoEnvelope.self, from: bytes).data
        guard result.protocolVersion == 1, !result.serverID.isEmpty, result.serverID.count <= 128,
              !result.name.isEmpty, result.name.count <= 120 else { throw CoreError.invalid("服务器协议不兼容") }
        return result
    }

    private struct InfoEnvelope: Decodable { var data: ServerInfo }
}

/// Widget entity identifiers contain both scope and card ID. Legacy single-ID widget selections still resolve.
public enum ScopedCardID {
    public static func encode(owner: String, cardID: String) -> String {
        "scoped:" + (try! JSONEncoder().encode([owner, cardID])).base64EncodedString()
    }
    public static func decode(_ value: String) throws -> (owner: String, cardID: String) {
        guard value.hasPrefix("scoped:") else { return (PrototypeData.owner, value) }
        guard let bytes = Data(base64Encoded: String(value.dropFirst(7))),
              let values = try? JSONDecoder().decode([String].self, from: bytes),
              values.count == 2, values.allSatisfy({ !$0.isEmpty }) else { throw CoreError.invalid("卡片选择无效") }
        return (values[0], values[1])
    }
}

public struct ContentSource: Identifiable, Equatable, Sendable {
    public var id: String { owner }
    public var owner: String
    public var name: String
    public var isEnabled: Bool
    public var isDemo: Bool
}

extension SharedStore {
    public func sources() throws -> [ContentSource] {
        [ContentSource(owner: PrototypeData.owner, name: VaoL10n.text("示例"), isEnabled: true, isDemo: true)] +
        (try connections()).compactMap { connection in
            connection.owner.map { ContentSource(owner: $0, name: connection.name,
                isEnabled: connection.isEnabled, isDemo: connection.isDemo) }
        }
    }
}

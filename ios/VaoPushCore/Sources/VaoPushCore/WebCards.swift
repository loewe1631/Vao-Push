import Foundation

public struct CardDesign: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var name: String
    public var family: String
    public var theme: String?
    public var layout: CardNode
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version"; case name, family, theme, layout }

    public var nodes: [CardNode] {
        func flatten(_ n: CardNode) -> [CardNode] { [n] + (n.children ?? []).flatMap(flatten) + (n.row.map { flatten($0.node) } ?? []) }
        return flatten(layout)
    }
    public func validate() throws {
        guard schemaVersion == 1, !name.isEmpty, name.utf8.count <= 120,
              ["small", "medium", "large", "extraLarge"].contains(family),
              ["system", "light", "dark"].contains(theme ?? "system"),
              try JSONEncoder().encode(self).count <= 24576 else { throw CoreError.invalid("不支持的卡片版本、尺寸或内容大小") }
        var ids = Set<String>(), count = 0
        func visit(_ n: CardNode, depth: Int) throws {
            count += 1
            guard depth <= 6, count <= 64, n.id.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil,
                  ids.insert(n.id).inserted,
                  ["row","column","grid","list","text","number","badge","divider","spacer","chart"].contains(n.type),
                  (n.fontSize == nil || n.fontSize == 0 || (10...32).contains(n.fontSize!)),
                  (0...24).contains(n.padding ?? 0), (0...24).contains(n.spacing ?? 0), (0...24).contains(n.radius ?? 0),
                  (n.decimals == nil || (0...18).contains(n.decimals!)),
                  ["", "regular", "medium", "semibold", "bold"].contains(n.weight ?? ""),
                  ["", "leading", "center", "trailing"].contains(n.alignment ?? "") else { throw CoreError.invalid("组件身份、层级或样式无效") }
            if let bind = n.bind { guard bind.range(of: "^(fields|series)\\.[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil else { throw CoreError.invalid("字段绑定无效") } }
            if n.type == "list" { guard n.source == "items", n.row != nil, (1...20).contains(n.limit ?? 0) else { throw CoreError.invalid("列表配置无效") } }
            if n.type == "grid" { guard (1...4).contains(n.columns ?? 0) else { throw CoreError.invalid("网格配置无效") } }
            for child in n.children ?? [] { try visit(child, depth: depth + 1) }
            if let row = n.row { try visit(row.node, depth: depth + 1) }
        }
        try visit(layout, depth: 1)
    }
}
public indirect enum CardRow: Codable, Equatable, Sendable {
    case value(CardNode)
    public var node: CardNode { switch self { case .value(let node): return node } }
    public init(from decoder: any Decoder) throws { self = .value(try decoder.singleValueContainer().decode(CardNode.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(node) }
}
public struct CardNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var text: String?
    public var label: String?
    public var bind: String?
    public var format: String?
    public var decimals: Int?
    public var colorRule: String?
    public var color: String?
    public var background: String?
    public var fontSize: Int?
    public var weight: String?
    public var alignment: String?
    public var spacing: Int?
    public var padding: Int?
    public var radius: Int?
    public var flex: Int?
    public var columns: Int?
    public var limit: Int?
    public var source: String?
    public var children: [CardNode]?
    public var row: CardRow?
    enum CodingKeys: String, CodingKey {
        case id,type,text,label,bind,format,decimals,color,background,weight,alignment,spacing,padding,radius,flex,columns,limit,source,children,row
        case colorRule = "color_rule", fontSize = "font_size"
    }
}
public struct NodeAdjustment: Codable, Equatable, Sendable {
    public var label: String?
    public var hidden: Bool?
    public var decimals: Int?
    public var fontSize: Int?
    public var showUnits: Bool?
    public init() {}
}
public struct CardAdjustments: Codable, Equatable, Sendable {
    public var name: String?
    public var theme: String?
    public var nodes: [String: NodeAdjustment] = [:]
    public init() {}
}
public struct RemoteCard: Codable, Equatable, Sendable {
    public var id: String
    public var revision: String
    public var design: CardDesign
    public var adjustments: CardAdjustments
    public var available: Bool
    public var issue: String?
    public init(id: String, revision: String, design: CardDesign) {
        self.id = id; self.revision = revision; self.design = design; adjustments = CardAdjustments(); available = true
    }
}
public struct SubscribedCard: Codable, Equatable, Sendable {
    public var cardID: String
    public var revision: String
    public var design: CardDesign
    public var snapshot: StateSnapshot
    enum CodingKeys: String, CodingKey { case cardID = "card_id"; case revision, design, snapshot }
    public func configuration(previous: CardConfiguration? = nil) throws -> CardConfiguration {
        try design.validate(); try ProtocolRules.validate(snapshot); _ = try ProtocolRules.revision(revision)
        var card = previous ?? CardConfiguration(id: "web_" + cardID, name: design.name, streamID: snapshot.streamID, fields: [])
        if let previous = card.remote {
            guard previous.id == cardID, card.streamID == snapshot.streamID else { throw CoreError.streamIdentityChanged }
            let incoming = try ProtocolRules.revision(revision), current = try ProtocolRules.revision(previous.revision)
            guard incoming >= current else { return card }
            if incoming == current && previous.design != design { throw CoreError.conflictingRevision }
            let old = Dictionary(uniqueKeysWithValues: previous.design.nodes.map { ($0.id, $0.type) })
            let next = Dictionary(uniqueKeysWithValues: design.nodes.map { ($0.id, $0.type) })
            for id in previous.adjustments.nodes.keys where old[id] != next[id] {
                throw CoreError.invalid("新版结构改变了已微调的组件；保留原设计，可恢复跟随Web后更新。")
            }
            card.remote?.revision = revision; card.remote?.design = design; card.remote?.available = true; card.remote?.issue = nil
        } else { card.remote = RemoteCard(id: cardID, revision: revision, design: design) }
        card.name = card.remote?.adjustments.name ?? design.name
        card.theme = CardConfiguration.Theme(rawValue: card.remote?.adjustments.theme ?? design.theme ?? "system")
        return card
    }
}

public final class CardClient: Sendable {
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.urlCache = nil; config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    private struct Envelope<T: Decodable>: Decodable { var data: T }
    private struct CardIdentity: Decodable { var card_id: String }
    private struct SubscriptionList: Decodable { struct Item: Decodable { var card_id: String }; var cards: [Item] }
    private struct OK: Decodable { var ok: Bool }
    private struct Failure: Decodable { struct Detail: Decodable { var message: String }; var error: Detail }
    public func redeem(base: URL, token: String, code: String) async throws -> String {
        var value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if let components = URLComponents(string: value), let scheme = components.scheme {
            let normalized = try ServerConnection.endpoint(base.absoluteString)
            let defaultPort = scheme.lowercased() == "https" ? 443 : 80
            guard scheme.lowercased() == normalized.scheme, let host = components.host,
                  host.lowercased() == normalized.host?.lowercased(),
                  (components.port ?? defaultPort) == (normalized.port ?? defaultPort),
                  components.path == normalized.path || components.path == normalized.path + "/",
                  components.user == nil, components.password == nil, components.fragment == nil,
                  let code = components.queryItems?.first(where: { $0.name == "card_code" })?.value else { throw CoreError.invalid("导入链接不属于所选服务器") }
            value = code
        }
        guard value.uppercased().range(of: "^VP-[0-9A-F]{24}$", options: .regularExpression) != nil else { throw CoreError.invalid("请输入有效卡片订阅码或链接") }
        let result: CardIdentity = try await request(base, "v1/cards/redeem", token, method: "POST", body: ["code": value.uppercased()])
        return result.card_id
    }
    public func list(base: URL, token: String) async throws -> [String] {
        let result: SubscriptionList = try await request(base, "v1/card-subscriptions", token)
        return result.cards.map(\.card_id)
    }
    public func fetch(base: URL, token: String, id: String) async throws -> SubscribedCard {
        guard id.range(of: "^card_[a-f0-9]{32}$", options: .regularExpression) != nil else { throw CoreError.invalid("卡片标识无效") }
        let result: SubscribedCard = try await request(base, "v1/card-subscriptions/" + id, token)
        guard result.cardID == id else { throw DeviceClientError.invalidResponse }; return result
    }
    public func unsubscribe(base: URL, token: String, id: String) async throws {
        guard id.range(of: "^card_[a-f0-9]{32}$", options: .regularExpression) != nil else { throw CoreError.invalid("卡片标识无效") }
        let _: OK = try await request(base, "v1/card-subscriptions/" + id, token, method: "DELETE")
    }
    private func request<T: Decodable>(_ base: URL, _ path: String, _ token: String, method: String = "GET", body: [String: String]? = nil) async throws -> T {
        let base = try ServerConnection.endpoint(base.absoluteString)
        guard token.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { throw DeviceClientError.invalidResponse }
        var r = URLRequest(url: base.appendingPathComponent(path)); r.httpMethod = method
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { r.httpBody = try JSONEncoder().encode(body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: r)
        guard let http = response as? HTTPURLResponse, data.count <= 128 * 1024,
              http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true else { throw DeviceClientError.invalidResponse }
        if !(200...299).contains(http.statusCode) {
            throw DeviceClientError.rejected(http.statusCode, (try? JSONDecoder().decode(Failure.self, from: data).error.message) ?? VaoL10n.text("卡片订阅请求未完成"))
        }
        return try JSONDecoder().decode(Envelope<T>.self, from: data).data
    }
}

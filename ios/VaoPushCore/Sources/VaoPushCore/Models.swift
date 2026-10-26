import Foundation

public enum CoreError: Error, Equatable, Sendable {
    case invalid(String)
    case conflictingRevision
    case streamIdentityChanged
    case unsupportedDatabaseVersion(Int)
    case database(String)
}

public enum FieldValue: Codable, Equatable, Sendable {
    case text(String)
    case boolean(Bool)
    case unavailable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .unavailable }
        else if let value = try? container.decode(String.self) { self = .text(value) }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else { throw CoreError.invalid("字段值须为字符串、布尔值或 null") }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .unavailable: try container.encodeNil()
        }
    }
}

public enum FieldType: String, Codable, Sendable {
    case text, decimal, integer, percent, boolean, datetime
}

public struct DataField: Codable, Equatable, Sendable {
    public var type: FieldType
    public var label: String?
    public var value: FieldValue
    public var unit: String?

    public init(type: FieldType, label: String? = nil, value: FieldValue, unit: String? = nil) {
        self.type = type; self.label = label; self.value = value; self.unit = unit
    }
}

public struct SeriesPoint: Codable, Equatable, Sendable {
    public var t: String
    public var value: String?
    public var o: String?
    public var h: String?
    public var l: String?
    public var c: String?
    public var v: String?
    public var isClosed: Bool?

    public init(t: String, value: String? = nil, o: String? = nil, h: String? = nil,
                l: String? = nil, c: String? = nil, v: String? = nil, isClosed: Bool? = nil) {
        self.t = t; self.value = value; self.o = o; self.h = h; self.l = l
        self.c = c; self.v = v; self.isClosed = isClosed
    }

    enum CodingKeys: String, CodingKey { case t, value, o, h, l, c, v; case isClosed = "is_closed" }
}

public struct DataSeries: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case line, ohlc }
    public var type: Kind
    public var label: String?
    public var intervalSeconds: Int
    public var unit: String?
    public var points: [SeriesPoint]

    public init(type: Kind, label: String? = nil, intervalSeconds: Int, unit: String? = nil, points: [SeriesPoint]) {
        self.type = type; self.label = label; self.intervalSeconds = intervalSeconds
        self.unit = unit; self.points = points
    }

    enum CodingKeys: String, CodingKey { case type, label, unit, points; case intervalSeconds = "interval_seconds" }
}

public struct DataItem: Codable, Equatable, Sendable {
    public var itemID: String
    public var fields: [String: DataField]
    public var series: [String: DataSeries]?

    enum CodingKeys: String, CodingKey { case itemID = "item_id"; case fields, series }
}

public struct WidgetState: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sourceUpdatedAt: String
    public var validForSeconds: Int?
    public var title: String?
    public var sequence: String?
    public var fields: [String: DataField]?
    public var items: [DataItem]?
    public var series: [String: DataSeries]?

    public init(sourceUpdatedAt: String, fields: [String: DataField], title: String? = nil,
                validForSeconds: Int? = nil) {
        self.schemaVersion = 1; self.sourceUpdatedAt = sourceUpdatedAt
        self.fields = fields; self.title = title; self.validForSeconds = validForSeconds
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", sourceUpdatedAt = "source_updated_at"
        case validForSeconds = "valid_for_seconds"
        case title, sequence, fields, items, series
    }
}

public struct StateSnapshot: Codable, Equatable, Sendable {
    public var streamID: String
    public var dataID: String
    public var revision: String
    public var receivedAt: String
    public var state: WidgetState

    public init(streamID: String, dataID: String, revision: String, receivedAt: String, state: WidgetState) {
        self.streamID = streamID; self.dataID = dataID; self.revision = revision
        self.receivedAt = receivedAt; self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id", dataID = "data_id", receivedAt = "received_at"
        case revision, state
    }

    public func isExpired(at date: Date) -> Bool {
        guard let ttl = state.validForSeconds, let source = ProtocolRules.date(state.sourceUpdatedAt) else { return false }
        return date >= source.addingTimeInterval(TimeInterval(ttl))
    }
}

public struct SnapshotEnvelope: Codable, Sendable {
    public var data: StateSnapshot
}

public struct FieldBinding: Codable, Equatable, Identifiable, Sendable {
    public var key: String
    public var alias: String?
    public var visible: Bool
    public var decimals: Int?
    public var id: String { key }

    public init(key: String, alias: String? = nil, visible: Bool = true, decimals: Int? = nil) {
        self.key = key; self.alias = alias; self.visible = visible; self.decimals = decimals
    }
}

public struct CardConfiguration: Codable, Equatable, Identifiable, Sendable {
    public enum Template: String, Codable, CaseIterable, Sendable { case metric, list, chart }
    public var id: String
    public var name: String
    public var streamID: String
    public var fields: [FieldBinding]
    public var template: Template
    public var seriesKey: String?
    public enum Theme: String, Codable, CaseIterable, Sendable { case system, light, dark }
    public var itemID: String?
    public var theme: Theme?
    public var showUnits: Bool?
    public var remote: RemoteCard?
    public var message: MessageCardOptions?

    public func selectedFields(in state: WidgetState) -> [String: DataField] {
        if let itemID { return state.items?.first(where: { $0.itemID == itemID })?.fields ?? [:] }
        return state.fields ?? [:]
    }
    public func selectedSeries(in state: WidgetState) -> [String: DataSeries] {
        if let itemID { return state.items?.first(where: { $0.itemID == itemID })?.series ?? [:] }
        return state.series ?? [:]
    }

    public init(id: String = UUID().uuidString, name: String, streamID: String,
                fields: [FieldBinding], template: Template = .list, seriesKey: String? = nil) {
        self.id = id; self.name = name; self.streamID = streamID
        self.fields = fields; self.template = template; self.seriesKey = seriesKey
        self.itemID = nil; self.theme = nil; self.showUnits = nil
    }
}

public enum CardDisplayMode: String, Codable, Sendable { case summary, chart }

public struct ArchivedMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var receivedAt: String

    public init(id: String, title: String, body: String, receivedAt: String) {
        self.id = id; self.title = title; self.body = body; self.receivedAt = receivedAt
    }
}

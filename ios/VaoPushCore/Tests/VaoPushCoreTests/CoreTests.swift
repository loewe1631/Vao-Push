import Foundation
import Testing
@testable import VaoPushCore

private let businessTime = "2026-10-24T10:00:00Z"
private let laterTime = "2026-10-24T10:01:00Z"

private func fixture(revision: Int = 1, price: String = "123.45", stream: String = "stream_quote") -> StateSnapshot {
    StateSnapshot(streamID: stream, dataID: "demo_quote", revision: String(revision), receivedAt: laterTime,
                  state: WidgetState(sourceUpdatedAt: businessTime,
                                     fields: ["price": DataField(type: .decimal, label: "价格", value: .text(price), unit: "USD")],
                                     validForSeconds: 180))
}

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("VaoPushCoreTests-" + UUID().uuidString).appendingPathComponent("shared.sqlite")
}

@Suite("内容与显示协议")
struct ProtocolTests {
    @Test("零、空文本、缺失与 null 不混淆；百分比不再乘 100")
    func missingAndZero() throws {
        let zero = DataField(type: .decimal, value: .text("0"))
        let unavailable = DataField(type: .decimal, value: .unavailable)
        let empty = DataField(type: .text, value: .text(""))
        let percent = DataField(type: .percent, value: .text("1.25"))
        let locale = Locale(identifier: "en_US_POSIX")
        #expect(FieldFormatter.display(zero, locale: locale) == "0")
        #expect(FieldFormatter.display(unavailable) == "不可用")
        #expect(FieldFormatter.display(nil) == "不可用")
        #expect(FieldFormatter.display(empty) == "")
        #expect(FieldFormatter.display(percent, locale: locale) == "1.25%")
    }

    @Test("别名优先于上游 label")
    func customAlias() {
        let binding = FieldBinding(key: "price", alias: "当前报价")
        #expect(FieldFormatter.label(for: binding, field: DataField(type: .decimal, label: "新价格", value: .text("1"))) == "当前报价")
        #expect(FieldFormatter.label(for: binding, field: nil) == "当前报价")
        #expect(FieldFormatter.label(for: FieldBinding(key: "missing"), field: nil) == "missing")
    }

    @Test("快照、null 与高精度数值正确编解码")
    func roundTrip() throws {
        var snapshot = fixture(price: "12345678901234567890.123456789012345678")
        snapshot.state.fields?["funding"] = DataField(type: .percent, value: .unavailable)
        try ProtocolRules.validate(snapshot)
        let encoded = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(StateSnapshot.self, from: encoded) == snapshot)
        #expect(String(data: encoded, encoding: .utf8)?.contains("12345678901234567890.123456789012345678") == true)
    }

    @Test("错误数值、未知版本与非 UTC 时间拒绝")
    func invalidProtocol() throws {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DataField.self, from: Data(#"{"type":"decimal","value":1.25}"#.utf8)) }
        #expect(throws: (any Error).self) { try ProtocolRules.decimal("NaN") }
        #expect(throws: (any Error).self) { try ProtocolRules.decimal("1e10") }
        #expect(throws: (any Error).self) { try ProtocolRules.revision("9223372036854775808") }
        var snapshot = fixture()
        snapshot.state.schemaVersion = 2
        #expect(throws: (any Error).self) { try ProtocolRules.validate(snapshot) }
        #expect(ProtocolRules.date("2026-10-24T18:00:00+08:00") == nil)
        #expect(ProtocolRules.date("2026-10-24T10:00:00.123Z") != nil)
    }

    @Test("真实 OHLC 关系与重复时间点校验")
    func invalidSeries() throws {
        let raw = #"{"schema_version":1,"source_updated_at":"2026-10-24T10:00:00Z","fields":{},"series":{"price_1m":{"type":"ohlc","interval_seconds":60,"points":[{"t":"2026-10-24T09:59:00Z","o":"100","h":"90","l":"80","c":"95"}]}}}"#
        let state = try JSONDecoder().decode(WidgetState.self, from: Data(raw.utf8))
        #expect(throws: (any Error).self) { try ProtocolRules.validate(state) }
        var valid = state
        valid.series?["price_1m"]?.points[0].h = "101"
        try ProtocolRules.validate(valid)
        let point = try #require(valid.series?["price_1m"]?.points.first)
        valid.series?["price_1m"]?.points.append(point)
        #expect(throws: (any Error).self) { try ProtocolRules.validate(valid) }
    }

    @Test("过期时间使用来源时间，不用刚接收时间")
    func expiry() throws {
        let value = fixture()
        #expect(value.isExpired(at: try #require(ProtocolRules.date("2026-10-24T10:02:59Z"))) == false)
        #expect(value.isExpired(at: try #require(ProtocolRules.date("2026-10-24T10:03:00Z"))))
    }
}

@Suite("共享 SQLite 状态")
struct StorageTests {
    @Test("持久存储防回退、识别重复与同版本冲突")
    func monotonicState() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SharedStore(url: url)
        #expect(try store.apply(fixture(revision: 10), owner: "alice") == .inserted)
        #expect(try store.apply(fixture(revision: 9), owner: "alice") == .ignoredOlder)
        #expect(try store.apply(fixture(revision: 10), owner: "alice") == .unchanged)
        #expect(throws: CoreError.conflictingRevision) { try store.apply(fixture(revision: 10, price: "999"), owner: "alice") }
        let reopened = try SharedStore(url: url)
        #expect(try reopened.snapshot(streamID: "stream_quote", owner: "alice")?.revision == "10")
    }

    @Test("连续数据更新不覆盖两张卡片的设置与交互状态")
    func cardsSurviveUpdates() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SharedStore(url: url)
        let first = CardConfiguration(id: "card_a", name: "我的概览", streamID: "stream_quote", fields: [.init(key: "price", alias: "当前报价", decimals: 2)])
        let second = CardConfiguration(id: "card_b", name: "第二张卡片", streamID: "stream_quote", fields: [.init(key: "price", alias: "参考值", decimals: 4)])
        try store.save(first, owner: "alice")
        try store.save(second, owner: "alice")
        try store.setMode(.chart, cardID: first.id, family: "medium", owner: "alice")
        for revision in 1...10 { try store.apply(fixture(revision: revision, price: String(revision)), owner: "alice") }
        #expect(try store.card(id: first.id, owner: "alice") == first)
        #expect(try store.card(id: second.id, owner: "alice") == second)
        #expect(try store.mode(cardID: first.id, family: "medium", owner: "alice") == .chart)
        #expect(try store.mode(cardID: first.id, family: "small", owner: "alice") == .summary)
        #expect(try store.mode(cardID: second.id, family: "medium", owner: "alice") == .summary)
    }

    @Test("消息、卡片和快照独立删除，账号作用域隔离")
    func separateResources() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SharedStore(url: url)
        try store.apply(fixture(), owner: "alice")
        try store.apply(fixture(price: "200"), owner: "bob")
        let card = CardConfiguration(id: "shared_name", name: "我的卡片", streamID: "stream_quote", fields: [.init(key: "price")])
        try store.save(card, owner: "alice")
        let message = ArchivedMessage(id: "message_1", title: "完成", body: "示例", receivedAt: businessTime)
        try store.archive(message, owner: "alice")
        try store.archive(message, owner: "alice")
        #expect(try store.messages(owner: "alice").count == 1)
        #expect(try store.cards(owner: "bob").isEmpty)
        try store.deleteMessage(id: message.id, owner: "alice")
        #expect(try store.snapshot(streamID: "stream_quote", owner: "alice") != nil)
        #expect(try store.card(id: card.id, owner: "alice") != nil)
        try store.deleteCard(id: card.id, owner: "alice")
        #expect(try store.snapshot(streamID: "stream_quote", owner: "alice") != nil)
        try store.removeAccount("alice")
        #expect(try store.snapshots(owner: "alice").isEmpty)
        #expect(try store.snapshot(streamID: "stream_quote", owner: "bob")?.state.fields?["price"]?.value == .text("200"))
        #expect(throws: (any Error).self) { try store.snapshots(owner: "bob\0other") }
    }

    @Test("多个连接并发乱序提交仍保留最高版本")
    func concurrentConnections() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try SharedStore(url: url)
        let second = try SharedStore(url: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in 1...30 {
                let connection = revision.isMultiple(of: 2) ? first : second
                group.addTask { try connection.apply(fixture(revision: revision), owner: "alice") }
            }
            try await group.waitForAll()
        }
        #expect(try first.snapshot(streamID: "stream_quote", owner: "alice")?.revision == "30")
    }
}

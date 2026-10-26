import Foundation
import Testing
@testable import VaoPushCore

@Suite("推送接收与原型持久化")
struct PushReceiverTests {
    private func database() throws -> (SharedStore, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (try SharedStore(url: url.appendingPathComponent("store.sqlite")), url)
    }

    private func payload(kind: String = "message", account: String = "account_demo", snapshot: StateSnapshot? = nil) throws -> Data {
        var content: [String: Any] = ["version": 1, "kind": kind, "account_id": account,
            "message_id": "event_1", "received_at": "2026-10-24T10:00:00Z"]
        if let snapshot { content["snapshot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) }
        return try JSONSerialization.data(withJSONObject: ["vao_push": content])
    }

    @Test("普通消息去重；错误账号与未知类型不能写入")
    func routing() throws {
        let (store, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try payload()
        for _ in 0..<2 {
            #expect(try PushReceiver.receive(payload: data, boundAccount: PrototypeData.owner,
                title: "示例消息", body: "完成", store: store) == .message)
        }
        #expect(try store.messages(owner: PrototypeData.owner).count == 1)
        #expect(try store.snapshots(owner: PrototypeData.owner).isEmpty)
        #expect(throws: CoreError.self) {
            try PushReceiver.receive(payload: payload(account: "other"), boundAccount: PrototypeData.owner,
                title: "", body: "", store: store)
        }
        #expect(throws: CoreError.self) {
            try PushReceiver.receive(payload: payload(kind: "unknown"), boundAccount: PrototypeData.owner,
                title: "", body: "", store: store)
        }
        #expect(try store.messages(owner: "other").isEmpty)
    }

    @Test("状态推送保留排版与交互；旧版本不回退且不产生消息历史")
    func stateRouting() throws {
        let (store, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        var card = PrototypeData.cards[0]
        card.fields[0].alias = "当前报价"
        try store.save(card, owner: PrototypeData.owner)
        try store.setMode(.chart, cardID: card.id, family: "0", owner: PrototypeData.owner)
        for revision in [Int64(2), 1] {
            try PushReceiver.receive(payload: payload(kind: "widget_state", snapshot: PrototypeData.snapshots(revision: revision)[0]),
                boundAccount: PrototypeData.owner, title: "", body: "", store: store)
        }
        #expect(try store.snapshot(streamID: card.streamID, owner: PrototypeData.owner)?.revision == "2")
        #expect(try store.card(id: card.id, owner: PrototypeData.owner) == card)
        #expect(try store.mode(cardID: card.id, family: "0", owner: PrototypeData.owner) == .chart)
        #expect(try store.messages(owner: PrototypeData.owner).isEmpty)
    }

    @Test("启动播种不覆盖修改、不复活删除的卡片")
    func seeding() throws {
        let (store, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        try PrototypeData.seed(store)
        var card = PrototypeData.cards[0]
        card.name = "我的看板"
        card.fields[0].alias = "当前报价"
        try store.save(card, owner: PrototypeData.owner)
        try store.deleteCard(id: PrototypeData.cards[1].id, owner: PrototypeData.owner)
        try store.deleteMessage(id: "prototype_welcome", owner: PrototypeData.owner)
        let reopened = try SharedStore(url: directory.appendingPathComponent("store.sqlite"))
        try PrototypeData.seed(reopened)
        #expect(try reopened.cards(owner: PrototypeData.owner) == [card])
        #expect(try reopened.messages(owner: PrototypeData.owner).isEmpty)
        #expect(try reopened.snapshots(owner: PrototypeData.owner).count == 2)
    }

    @Test("超限载荷与损坏的 JSON 被拒绝")
    func badPayload() throws {
        let (store, directory) = try database()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: CoreError.self) {
            try PushReceiver.receive(payload: Data(repeating: 32, count: 4097), boundAccount: PrototypeData.owner,
                title: "", body: "", store: store)
        }
        #expect(throws: (any Error).self) {
            try PushReceiver.receive(payload: Data("{".utf8), boundAccount: PrototypeData.owner,
                title: "", body: "", store: store)
        }
        #expect(try store.messages(owner: PrototypeData.owner).isEmpty)
    }
}

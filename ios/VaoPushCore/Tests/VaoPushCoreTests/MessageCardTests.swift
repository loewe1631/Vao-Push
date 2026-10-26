import Foundation
import Testing
@testable import VaoPushCore

@Suite("本机消息卡片")
struct MessageCardTests {
    @Test("消息卡片无需业务快照，保存及接收消息保持来源隔离与设置")
    func persistenceAndIsolation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("messages.sqlite")
        let store = try SharedStore(url: url)
        var card = CardConfiguration.messageCard(name: "工作通知", style: .list)
        card.message?.showBody = false
        try store.save(card, owner: "server_A")
        try store.archive(ArchivedMessage(id: "new", title: "较新消息", body: "内容A", receivedAt: "2026-10-25T05:02:00Z"), owner: "server_A")
        // A delayed notification must not displace the newer received message.
        try store.archive(ArchivedMessage(id: "late", title: "晚到的旧消息", body: "内容B", receivedAt: "2026-10-25T05:00:00Z"), owner: "server_A")
        try store.archive(ArchivedMessage(id: "other", title: "其他服务器", body: "不可串用", receivedAt: "2026-10-25T05:05:00Z"), owner: "server_B")
        let reopened = try SharedStore(url: url)
        let saved = try reopened.card(id: card.id, owner: "server_A")
        let restored = try #require(saved)
        #expect(restored == card)
        #expect(try reopened.snapshots(owner: "server_A").isEmpty)
        let own = try reopened.messages(owner: "server_A")
        #expect(restored.message?.recentMessages(in: own).map(\.id) == ["new", "late"])
        try reopened.clearMessages(owner: "server_A")
        #expect(try reopened.messages(owner: "server_A").isEmpty)
        #expect(try reopened.messages(owner: "server_B").count == 1)
        #expect(try reopened.card(id: card.id, owner: "server_A") == card)
    }

    @Test("模板只选最近消息，尺寸限制不会改变保存的历史")
    func presentationLimits() {
        let messages = (0..<5).map { index in
            ArchivedMessage(id: String(index), title: "消息", body: "内容", receivedAt: "2026-10-25T05:0\(index):00Z")
        }
        #expect(MessageCardOptions(style: .latest).recentMessages(in: messages).map(\.id) == ["4"])
        #expect(MessageCardOptions(style: .summary).recentMessages(in: messages).map(\.id) == ["4"])
        #expect(MessageCardOptions(style: .list).recentMessages(in: messages).map(\.id) == ["4", "3", "2"])
        #expect(MessageCardOptions(style: .list).recentMessages(in: messages, limit: 1).map(\.id) == ["4"])
        #expect(messages.count == 5)
    }

    @Test("旧卡片兼容，消息模板拒绝混入业务字段绑定")
    func compatibility() throws {
        let old = Data(#"{"id":"old","name":"旧卡片","streamID":"stream_old","fields":[],"template":"list"}"#.utf8)
        #expect(try JSONDecoder().decode(CardConfiguration.self, from: old).message == nil)
        var card = CardConfiguration.messageCard(name: "最新消息")
        try ProtocolRules.validate(card)
        #expect(try JSONDecoder().decode(CardConfiguration.self, from: JSONEncoder().encode(card)) == card)
        card.fields = [FieldBinding(key: "price")]
        #expect(throws: CoreError.self) { try ProtocolRules.validate(card) }
    }

    @Test("示例资产更新只影响旧本机示例，并保留用户设置")
    func exampleUpgrade() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SharedStore(url: folder.appendingPathComponent("examples.sqlite"))
        #expect(try !PrototypeData.upgradeStockExample(store))
        #expect(try store.snapshots(owner: PrototypeData.owner).isEmpty)
        var old = PrototypeData.snapshots()[0]
        old.state.fields?["name"]?.value = .text("VAO / USD · 虚构")
        try store.apply(old, owner: PrototypeData.owner)
        try store.apply(old, owner: "real_server")
        var saved = PrototypeData.cards[0]
        saved.name = "我的示例收藏"
        saved.fields[0].alias = "自定义名称"
        try store.save(saved, owner: PrototypeData.owner)
        #expect(try PrototypeData.upgradeStockExample(store))
        #expect(try store.snapshot(streamID: old.streamID, owner: PrototypeData.owner)?.state.fields?["name"]?.value == .text("AAPL · 苹果公司"))
        #expect(try store.snapshot(streamID: old.streamID, owner: "real_server") == old)
        #expect(try store.card(id: saved.id, owner: PrototypeData.owner) == saved)
        #expect(try !PrototypeData.upgradeStockExample(store))
    }
}

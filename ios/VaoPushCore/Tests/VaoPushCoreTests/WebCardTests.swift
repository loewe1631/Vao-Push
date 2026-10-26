import Foundation
import Dispatch
import Testing
@testable import VaoPushCore

@Suite("Web卡片设计与独立微调")
struct WebCardTests {
    private func info() throws -> SubscribedCard {
        let raw = #"{"card_id":"card_11111111111111111111111111111111","revision":"1","design":{"schema_version":1,"name":"Web行情","family":"medium","layout":{"id":"root","type":"row","spacing":0,"children":[{"id":"symbol","type":"text","bind":"fields.symbol"},{"id":"price","type":"number","bind":"fields.price","decimals":2}]}},"snapshot":{"stream_id":"stream_shared","data_id":"card_shared","revision":"1","received_at":"2026-10-25T01:00:00Z","state":{"schema_version":1,"source_updated_at":"2026-10-25T01:00:00Z","fields":{"symbol":{"type":"text","value":"BTC/USDT"},"price":{"type":"decimal","value":"80970.01"}}}}}"#
        return try JSONDecoder().decode(SubscribedCard.self, from: Data(raw.utf8))
    }
    @Test("Web更新未微调样式，本机名称和精度保持，另一台设备不受影响")
    func independentAdjustments() throws {
        var published = try info()
        var phoneA = try published.configuration()
        let phoneB = try published.configuration()
        phoneA.remote?.adjustments.name = "我的行情"
        var price = NodeAdjustment(); price.decimals = 1
        phoneA.remote?.adjustments.nodes["price"] = price
        published.revision = "2"; published.design.name = "Web新版"
        published.design.layout.spacing = 12; published.snapshot.revision = "2"
        let updatedA = try published.configuration(previous: phoneA)
        let updatedB = try published.configuration(previous: phoneB)
        #expect(updatedA.name == "我的行情")
        #expect(updatedB.name == "Web新版")
        #expect(updatedA.remote?.adjustments.nodes["price"]?.decimals == 1)
        #expect(updatedB.remote?.adjustments.nodes.isEmpty == true)
        #expect(updatedA.remote?.design.layout.spacing == 12)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = try SharedStore(url: file)
        try store.save(updatedA, owner: "source-A"); try store.apply(published.snapshot, owner: "source-A")
        let reopened = try SharedStore(url: file)
        #expect(try reopened.card(id: updatedA.id, owner: "source-A") == updatedA)
        #expect(try reopened.cards(owner: "source-B").isEmpty == true)
        var reset = updatedA; reset.remote?.adjustments = CardAdjustments()
        #expect(try published.configuration(previous: reset).name == "Web新版")
    }
    @Test("并发数据写入与微调保存不丢失设置，旧草稿不回退发布版本")
    func concurrentCacheMerge() throws {
        var published = try info()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let app = try SharedStore(url: file), widget = try SharedStore(url: file)
        try app.acceptCard(published, owner: "owner")
        var draft = try #require(app.cards(owner: "owner").first)
        draft.remote?.adjustments.name = "手机保存的名称"
        published.revision = "2"; published.design.name = "Web第二版"; published.snapshot.revision = "2"
        let incoming = published, editing = draft
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                if index.isMultiple(of: 2) { try widget.acceptCard(incoming, owner: "owner") }
                else { try app.save(editing, owner: "owner") }
            } catch { Issue.record("并发缓存写入失败：\(error)") }
        }
        let stored = try #require(app.cards(owner: "owner").first)
        #expect(stored.name == "手机保存的名称")
        #expect(stored.remote?.revision == "2")
        #expect(stored.remote?.design.name == "Web第二版")
        #expect(try app.snapshot(streamID: published.snapshot.streamID, owner: "owner")?.revision == "2")
    }

    @Test("不兼容或旧发布版本不能覆盖已保存微调")
    func incompatibleUpdate() throws {
        var published = try info(); var card = try published.configuration()
        card.remote?.adjustments.nodes["price"] = NodeAdjustment()
        published.revision = "2"; published.design.layout.children?[1].type = "text"
        #expect(throws: CoreError.self) { try published.configuration(previous: card) }
        #expect(card.remote?.revision == "1")
        published = try info(); published.revision = "1"; published.design.name = "偷换同版本内容"
        #expect(throws: CoreError.self) { try published.configuration(previous: card) }
    }
    @Test("不支持的代码、重复标识和跨服务器导入链接被拒绝")
    func rejectInvalidLayouts() async throws {
        var published = try info(); published.design.layout.children?[0].type = "webview"
        #expect(throws: CoreError.self) { try published.design.validate() }
        published = try info(); published.design.layout.children?[1].id = "symbol"
        #expect(throws: CoreError.self) { try published.design.validate() }
        await #expect(throws: CoreError.self) {
            try await CardClient().redeem(base: URL(string:"https://one.example")!, token:String(repeating:"a",count:64), code:"https://two.example/?card_code=VP-111111111111111111111111")
        }
    }
}

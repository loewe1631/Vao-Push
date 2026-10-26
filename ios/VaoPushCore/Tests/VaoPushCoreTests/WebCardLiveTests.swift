import Foundation
import Testing
@testable import VaoPushCore

@Suite("Web卡片真实HTTPS订阅", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VAO_CARD_LIVE_FIXTURE"] != nil))
struct WebCardLiveTests {
    @Test("命名接入、重复导入、Widget只读获取和数据更新保留微调")
    func roundtrip() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VAO_CARD_LIVE_FIXTURE"])
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: String]
        let base = URL(string: fixture["url"]!)!, devices = DeviceClient(), cards = CardClient()
        let registration = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let credentials = try await devices.connect(baseURL: base, registrationToken: registration, deviceName: "P2卡片网络验收")
        do {
            #expect(try await cards.list(base: base, token: credentials.deviceToken).isEmpty)
            let id = try await cards.redeem(base: base, token: credentials.deviceToken, code: fixture["code"]!)
            #expect(id == fixture["card_id"])
            #expect(try await cards.redeem(base: base, token: credentials.deviceToken, code: fixture["code"]!) == id)
            let first = try await cards.fetch(base: base, token: credentials.readToken, id: id)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
            defer { try? FileManager.default.removeItem(at: file) }
            let store = try SharedStore(url: file)
            try store.acceptCard(first, owner: "network")
            var local = try #require(store.cards(owner: "network").first)
            local.remote?.adjustments.name = "我的网络任务"
            var adjustment = NodeAdjustment(); adjustment.decimals = 1; adjustment.fontSize = 24
            local.remote?.adjustments.nodes["progress"] = adjustment
            try store.save(local, owner: "network")
            var request = URLRequest(url: URL(string: fixture["state_url"]!)!); request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["fields": ["progress": ["type":"percent","value":"79"],"status":["type":"text","value":"更新中"]]])
            let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (_, response) = try await session.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 202)
            let latest = try await cards.fetch(base: base, token: credentials.readToken, id: id)
            try store.acceptCard(latest, owner: "network")
            let merged = try #require(store.cards(owner: "network").first)
            #expect(merged.name == "我的网络任务")
            #expect(merged.remote?.adjustments.nodes["progress"]?.fontSize == 24)
            #expect(latest.snapshot.state.fields?["progress"]?.value == .text("79"))
            #expect(try ProtocolRules.revision(latest.snapshot.revision) > ProtocolRules.revision(first.snapshot.revision))
            try await cards.unsubscribe(base: base, token: credentials.deviceToken, id: id)
            await #expect(throws: DeviceClientError.self) { try await cards.fetch(base: base, token: credentials.readToken, id: id) }
            try await devices.revoke(baseURL: base, token: credentials.deviceToken)
        } catch { try? await devices.revoke(baseURL: base, token: credentials.deviceToken); throw error }
    }
}

import Foundation
import Testing
@testable import VaoPushCore

@Suite("自动接入真实网络", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VAO_SIMPLE_LIVE_FIXTURE"] != nil))
struct AutomaticLiveTests {
    @Test("自动注册、两路最简请求、覆盖与卡片设置保持")
    func roundtrip() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VAO_SIMPLE_LIVE_FIXTURE"])
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String:String]
        let base = URL(string: fixture["url"]!)!, client = DeviceClient()
        let registration = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
        let credentials = try await client.connect(baseURL: base, registrationToken: registration, deviceName: "Swift 自动接入验收")
        do {
            let resumed = try await client.connect(baseURL: base, registrationToken: registration, deviceName: "Swift 自动接入验收")
            #expect(resumed.bindingID == credentials.bindingID)
            try await client.rename(baseURL: base, token: credentials.deviceToken, name: "Swift 自定义设备名验收")
            let renamed = try await client.sync(baseURL: base, token: credentials.deviceToken, cursor: nil)
            #expect(renamed.deviceName == "Swift 自定义设备名验收")
            #expect(renamed.bindingID == credentials.bindingID)
            let key = try #require(credentials.sendKey)
            let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            func submit(_ path: String, _ method: String, _ body: [String:Any]) async throws {
                var request = URLRequest(url: base.appendingPathComponent(path))
                request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (_, response) = try await session.data(for: request)
                let status = try #require((response as? HTTPURLResponse)?.statusCode)
                #expect(status == 202)
            }
            try await submit("v1/push/" + key, "POST", ["title":"最简接入", "body":"无需配对或配置权限"])
            func state(_ value: String) -> [String:Any] { ["fields":["progress":["type":"percent", "value":value]]] }
            try await submit("v1/state/" + key + "/task_progress", "PUT", state("68"))
            let page = try await client.sync(baseURL: base, token: credentials.deviceToken, cursor: nil)
            #expect(page.messages.count == 1)
            let snapshot = try #require(page.snapshots.first)
            try ProtocolRules.validate(snapshot)
            let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".sqlite")
            defer { try? FileManager.default.removeItem(at: file) }
            let store = try SharedStore(url: file)
            try store.apply(snapshot, owner: "automatic-live")
            try store.save(CardConfiguration(id: "card", name: "我的任务", streamID: snapshot.streamID,
                fields: [FieldBinding(key: "progress", alias: "我的完成率")]), owner: "automatic-live")
            try await client.subscriptions(baseURL: base, token: credentials.deviceToken, dataIDs: ["task_progress"])
            try await submit("v1/state/" + key + "/task_progress", "PUT", state("79"))
            let latest = try await client.sync(baseURL: base, token: credentials.deviceToken, cursor: page.cursor)
            #expect(latest.messages.isEmpty)
            let changed = try #require(latest.snapshots.first)
            try store.apply(changed, owner: "automatic-live")
            #expect(changed.revision == "2")
            #expect(changed.state.fields?["progress"]?.value == .text("79"))
            #expect(try store.card(id: "card", owner: "automatic-live")?.fields.first?.alias == "我的完成率")
            let fetched = try await SnapshotClient().fetch(baseURL: base, dataID: "task_progress", bearer: credentials.readToken)
            guard case .snapshot(let read, _) = fetched else { Issue.record("缺少快照"); return }
            #expect(read.revision == "2")
            try await client.revoke(baseURL: base, token: credentials.deviceToken)
        } catch {
            try? await client.revoke(baseURL: base, token: credentials.deviceToken)
            throw error
        }
    }
}

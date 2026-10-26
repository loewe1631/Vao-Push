import Foundation
import Testing
import VaoPushCore
import UserNotifications
@testable import VaoPush

@Suite("iOS 凭证与共享缓存", .serialized)
struct VaoPushTests {
    @Test("通知交付诊断不输出消息正文或凭据", .enabled(if: ProcessInfo.processInfo.environment["VAO_NOTIFICATION_DIAGNOSTICS"] != nil))
    func notificationDiagnostics() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let notifications = await center.deliveredNotifications()
        let connections = try PrototypeStorage.open().connections()
        print("VAO_NOTIFICATION_STATUS authorization=\(settings.authorizationStatus.rawValue) alert=\(settings.alertSetting.rawValue) center=\(settings.notificationCenterSetting.rawValue) delivered=\(notifications.count) ownTests=\(notifications.filter { $0.request.content.title.hasPrefix("通知直达详情验收") }.count) boundSources=\(connections.filter { $0.bindingID != nil && !$0.isDemo }.count)")
    }

    @Test("通知跳转可在界面准备前保存，并且只消费一次")
    @MainActor func pendingNotificationNavigation() {
        let navigation = AppNavigation()
        let payload = Data("test-message-target".utf8)
        navigation.openMessage(payload: payload, title: "Target", body: "Long body")
        #expect(navigation.pendingMessage != nil)
        let request = navigation.consumeMessage()
        #expect(request?.payload == payload)
        #expect(request?.title == "Target")
        #expect(navigation.consumeMessage() == nil)
    }

    @Test("iPad通过真实HTTP接口注册与订阅，读取路径与Widget共用", .enabled(if: ProcessInfo.processInfo.environment["VAO_IOS_HTTP_URL"] != nil))
    func physicalHTTPConnection() async throws {
        let env = ProcessInfo.processInfo.environment
        let base = URL(string: try #require(env["VAO_IOS_HTTP_URL"]))!
        let code = try #require(env["VAO_IOS_HTTP_CODE"])
        let expectedID = try #require(env["VAO_IOS_HTTP_CARD_ID"])
        let devices = DeviceClient(), cards = CardClient()
        let registration = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        let device = try await devices.connect(baseURL: base, registrationToken: registration, deviceName: "iPad Native HTTP Acceptance")
        do {
            let info = try await ServerInfoClient().inspect(baseURL: base)
            #expect(info.serverID == device.serverID)
            let link = base.absoluteString + "/?card_code=" + code
            let id = try await cards.redeem(base: base, token: device.deviceToken, code: link)
            #expect(id == expectedID)
            let card = try await cards.fetch(base: base, token: device.readToken, id: id)
            #expect(card.snapshot.state.fields?["progress"]?.value == .text("79"))
            let page = try await devices.sync(baseURL: base, token: device.deviceToken, cursor: nil)
            #expect(page.bindingID == device.bindingID)
            try await cards.unsubscribe(base: base, token: device.deviceToken, id: id)
            try await devices.revoke(baseURL: base, token: device.deviceToken)
        } catch {
            try? await devices.revoke(baseURL: base, token: device.deviceToken)
            throw error
        }
    }

    @Test("App 会话与 Widget 只读凭证分别保存并可撤销")
    func keychainRoundtrip() throws {
        let key = "test-" + UUID().uuidString
        defer { try? CredentialVault.remove(id: key); try? CredentialVault.remove(id: key, shared: true) }
        try CredentialVault.save(Data("device-test-value".utf8), id: key)
        try CredentialVault.save(Data("read-test-value".utf8), id: key, shared: true)
        #expect(try CredentialVault.load(id: key) == Data("device-test-value".utf8))
        #expect(try CredentialVault.load(id: key, shared: true) == Data("read-test-value".utf8))
        try CredentialVault.remove(id: key)
        #expect(try CredentialVault.load(id: key) == nil)
        #expect(try CredentialVault.load(id: key, shared: true) == Data("read-test-value".utf8))
    }

    @Test("App Group 存储可读写并保持卡片设置")
    func sharedStore() throws {
        let store = try PrototypeStorage.open()
        let owner = "integration-test-" + UUID().uuidString
        let state = WidgetState(sourceUpdatedAt: "2026-10-24T10:00:00Z", fields: ["progress": DataField(type: .percent, value: .text("68"))])
        let snapshot = StateSnapshot(streamID: "test-stream", dataID: "test_progress", revision: "1", receivedAt: "2026-10-24T10:00:01Z", state: state)
        try store.apply(snapshot, owner: owner)
        let card = CardConfiguration(name: "Test", streamID: snapshot.streamID, fields: [FieldBinding(key: "progress", alias: "我的进度")])
        try store.save(card, owner: owner)
        var newer = snapshot; newer.revision = "2"
        newer.state.fields?["progress"]?.value = .text("79")
        try store.apply(newer, owner: owner)
        #expect(try store.card(id: card.id, owner: owner)?.fields.first?.alias == "我的进度")
        #expect(try store.snapshot(streamID: snapshot.streamID, owner: owner)?.revision == "2")
        try store.deleteCard(id: card.id, owner: owner)
    }
}

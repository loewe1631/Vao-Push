import Foundation
import Testing
@testable import VaoPushCore
import UserNotifications
import SwiftUI
import UIKit
@testable import VaoPush

@Suite("iOS 凭证与共享缓存", .serialized)
struct VaoPushTests {
    @MainActor private func pixels<V: View>(_ view: V) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.uiImage?.cgImage)
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    @Test("高优先级名称不能把状态徽标文字挤成零宽")
    @MainActor func signedBadgeKeepsText() throws {
        let design = try JSONDecoder().decode(CardDesign.self, from: Data(#"{"schema_version":1,"name":"Synthetic status","family":"large","theme":"dark","layout":{"id":"row","type":"row","children":[{"id":"name","type":"text","text":"NODE A","flex":4},{"id":"status","type":"badge","bind":"fields.status","color_rule":"signed"}]}}"#.utf8))
        var card = CardConfiguration(id: "render-test", name: design.name, streamID: "render-test", fields: [])
        card.remote = RemoteCard(id: "card_11111111111111111111111111111111", revision: "1", design: design)
        card.theme = .dark
        let state = WidgetState(sourceUpdatedAt: "2026-11-09T00:00:00Z", fields: ["status": DataField(type: .integer, value: .text("1"), unit: "正常")])
        let snapshot = StateSnapshot(streamID: "render-test", dataID: "render-test", revision: "1", receivedAt: state.sourceUpdatedAt, state: state)
        let image = try pixels(PrototypeCardView(card: card, snapshot: snapshot, isDemo: false)
            .frame(width: 280, height: 120).background(Color.black))
        var minX = image.width, maxX = -1, minY = image.height, maxY = -1
        for y in 0..<image.height { for x in 0..<image.width {
            let i = (y * image.width + x) * 4
            if image.bytes[i] < 80, image.bytes[i+1] > 100, image.bytes[i+2] < 180 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        } }
        #expect(maxX - minX > 35)
        var whiteText = 0
        if maxX >= minX && maxY >= minY {
            for y in minY...maxY { for x in minX...maxX {
                let i = (y * image.width + x) * 4
                if image.bytes[i] > 220, image.bytes[i+1] > 220, image.bytes[i+2] > 220 { whiteText += 1 }
            } }
        }
        #expect(whiteText > 10, "The green badge must contain visible light text")
    }

    @Test("卡片预览底板遵循卡片主题而不是外层 App 外观")
    @MainActor func previewSurfaceMatchesTheme() throws {
        for (theme, outer, expectsDark) in [(CardConfiguration.Theme.dark, ColorScheme.light, true),
            (.light, .dark, false), (.system, .dark, true), (.system, .light, false)] {
            let image = try pixels(Text("Preview").modifier(CardPreviewSurface(theme: theme, minimumHeight: 120))
                .frame(width: 280).environment(\.colorScheme, outer))
            let i = ((image.height / 2) * image.width + image.width / 2) * 4
            #expect(expectsDark ? image.bytes[i] < 80 : image.bytes[i] > 220)
        }
    }

    @Test("卡片图标真实下载链路不带凭据，拒绝损坏与超限图片")
    @MainActor func boundedCardIcons() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8), format: format).pngData { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CardIconTestProtocol.self]
        let cache = CardIconCache(configuration: config, resolver: { _ in true })
        CardIconTestProtocol.body = png
        let url = "https://icons.example.com/" + UUID().uuidString + ".png"
        CardIconTestProtocol.requestCount = 0
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await cache.load(url) }; group.addTask { await cache.load(url) }
        }
        #expect(CardIconTestProtocol.requestCount == 1)
        #expect(CardIconCache.cached(url) != nil)
        let offline = CardIconCache(configuration: config, resolver: { _ in false })
        CardIconTestProtocol.lastRequest = nil
        await offline.load(url)
        #expect(CardIconCache.cached(url) != nil)
        #expect(CardIconTestProtocol.lastRequest == nil)
        let blocked = "https://icons.example.com/" + UUID().uuidString + ".png"
        await offline.load(blocked); #expect(CardIconTestProtocol.lastRequest == nil)
        await cache.load("https://icons.example.com/" + UUID().uuidString + ".png")
        #expect(CardIconTestProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(CardIconTestProtocol.lastRequest?.value(forHTTPHeaderField: "Cookie") == nil)
        CardIconTestProtocol.body = Data("not an image".utf8)
        let corrupt = "https://icons.example.com/" + UUID().uuidString + ".png"
        await cache.load(corrupt); #expect(CardIconCache.cached(corrupt) == nil)
        CardIconTestProtocol.body = Data(repeating: 0, count: 512 * 1024 + 1)
        let huge = "https://icons.example.com/" + UUID().uuidString + ".png"
        await cache.load(huge); #expect(CardIconCache.cached(huge) == nil)
        CardIconTestProtocol.body = png
    }

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

private final class CardIconTestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "icons.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"image/png", "Content-Length":String(Self.body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

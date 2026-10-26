import Foundation
import Testing
@testable import VaoPushCore

private final class DeviceProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url else { return }
        var status = 200
        var json: [String: Any] = ["data": ["ok": true]]
        if !url.path.hasPrefix("/prefix/v1/") { status = 404 }
        else if url.path.hasSuffix("register") {
            json = ["data": ["server_id":"srv_test","account_id":"acct_test","binding_id":"dev_test","device_token":String(repeating:"a",count:64),"read_token":String(repeating:"b",count:64),"send_key":String(repeating:"c",count:64),"expires_at":"2036-10-24T10:00:00Z"]]
        }
        else if url.path.hasSuffix("pairings/claim") {
            let body = request.httpBody ?? request.httpBodyStream.flatMap { stream -> Data? in
                stream.open(); defer { stream.close() }; var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 2048)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }; return bytes
            } ?? Data()
            let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
            if parsed?["code"] != "ABC123" || parsed?["platform"] != "ios" { status = 422 }
            json = ["data": ["server_id":"srv_test","account_id":"acct_test","binding_id":"dev_test","device_token":String(repeating:"a",count:64),"read_token":String(repeating:"b",count:64),"expires_at":"2027-10-24T10:00:00Z"]]
        } else if request.value(forHTTPHeaderField: "Authorization") != "Bearer device-test-token" { status = 401 }
        else if url.path.hasSuffix("device/access") {
            json = ["data": ["send_key":String(repeating:"c",count:64)]]
        }
        else if url.path.hasSuffix("device/sync") {
            if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value != "123" { status = 422 }
            json = ["data":["server_id":"srv_test","account_id":"acct_test","binding_id":"dev_test","snapshots":[],"messages":[],"cursor":"123","has_more":false]]
        }
        if status != 200 { json = ["error":["message":"凭证或请求无效"]] }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json)); client?.urlProtocolDidFinishLoading(self)
    }
}
private func deviceClient() -> DeviceClient {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DeviceProtocol.self]
    return DeviceClient(session: URLSession(configuration: configuration))
}
@Suite("设备协议客户端")
struct DeviceClientTests {
    @Test("前缀路径、配对输入规范化和游标")
    func pairingAndSync() async throws {
        let client = deviceClient(), url = URL(string:"https://example.com/prefix")!
        let credentials = try await client.pair(baseURL: url, code:"ab c123", deviceName:"Test")
        #expect(credentials.bindingID == "dev_test")
        let page = try await client.sync(baseURL:url, token:"device-test-token", cursor:"123")
        #expect(page.cursor == "123" && !page.hasMore)
        try await client.register(baseURL:url, token:"device-test-token", apns:nil, widget:nil, environment:"sandbox")
        try await client.subscriptions(baseURL:url, token:"device-test-token", dataIDs:[])
        try await client.setEnabled(baseURL:url, token:"device-test-token", enabled:false)
        try await client.revoke(baseURL:url, token:"device-test-token")
    }
    @Test("自动注册返回发送 Key，旧凭证仍可解码和补齐")
    func automaticRegistration() async throws {
        let client = deviceClient(), url = URL(string:"https://example.com/prefix")!
        let credentials = try await client.connect(baseURL:url, registrationToken:String(repeating:"d",count:64),deviceName:"Test")
        #expect(credentials.sendKey?.count == 64)
        let old = try await client.pair(baseURL:url,code:"ABC123",deviceName:"Test")
        #expect(old.sendKey == nil)
        let key = try await client.sendingKey(baseURL:url,token:"device-test-token")
        #expect(key == credentials.sendKey)
    }

    @Test("错误身份和不安全端点不得继续")
    func rejectedIdentity() async throws {
        await #expect(throws: DeviceClientError.self) { try await deviceClient().sync(baseURL:URL(string:"https://example.com/prefix")!,token:"wrong",cursor:"123") }
        await #expect(throws: (any Error).self) { try await deviceClient().sync(baseURL:URL(string:"ftp://example.com")!,token:"x",cursor:nil) }
        await #expect(throws: DeviceClientError.self) { try await deviceClient().sync(baseURL:URL(string:"https://example.com/prefix")!,token:"bad\ntoken",cursor:"123") }
    }
    @Test("新卡片字段选择和旧配置解码")
    func cardCompatibility() throws {
        let old = Data(#"{"id":"card","name":"Test","streamID":"stream","fields":[],"template":"list"}"#.utf8)
        let card = try JSONDecoder().decode(CardConfiguration.self,from:old)
        #expect(card.theme == nil && card.itemID == nil && card.showUnits == nil)
        let raw = Data(#"{"schema_version":1,"source_updated_at":"2026-10-24T10:00:00Z","items":[{"item_id":"a","fields":{"price":{"type":"decimal","value":"10","unit":"USD"}}},{"item_id":"b","fields":{"price":{"type":"decimal","value":"20"}}}]}"#.utf8)
        var state = try JSONDecoder().decode(WidgetState.self,from:raw)
        var bound = card; bound.itemID = "a"
        state.items?.reverse()
        #expect(bound.selectedFields(in:state)["price"]?.value == .text("10"))
        #expect(FieldFormatter.display(bound.selectedFields(in:state)["price"],showUnit:false,locale:Locale(identifier:"en_US")) == "10")
        state.items?.removeAll(where:{$0.itemID == "a"})
        #expect(bound.selectedFields(in:state).isEmpty)
    }
}

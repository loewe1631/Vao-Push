import Foundation
import Testing
@testable import VaoPushCore

private final class CardNegotiationProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!, host = url.host!, requested = request.value(forHTTPHeaderField: "X-Vao-Card-Schema")
        var version = 1
        if host == "old.example.com" || host == "stale.example.com" { version = requested == "2" ? 2 : 1 }
        if host == "new.example.com" { version = 3 }
        var design: [String: Any] = ["schema_version":version,"name":"Test","family":"medium","layout":["id":"title","type":"text","text":"default"]]
        if version >= 2 { design["layouts"] = ["small":["id":"title","type":"text","text":"small-v2"]] }
        if version == 3 { design["fallback"] = ["layout":design["layout"]!,"layouts":design["layouts"]!] }
        let time="2026-11-09T00:00:00Z"
        let revision = host == "stale.example.com" && requested == "2" ? "1" : "2"
        let body: [String:Any] = ["data":["card_id":url.lastPathComponent,"revision":revision,"design":design,"snapshot":["stream_id":"stream_test","data_id":"data_test","revision":"2","received_at":time,"state":["schema_version":1,"source_updated_at":time,"fields":["value":["type":"integer","value":"0"]]]]]]
        let response = HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:body))
        client?.urlProtocolDidFinishLoading(self)
    }
}
@Suite("新 App 与旧服务端尺寸协商") struct CardSchemaNegotiationTests {
    private func fetch(_ host:String) async throws -> SubscribedCard {
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[CardNegotiationProtocol.self]
        let client=CardClient(session:URLSession(configuration:config))
        return try await client.fetch(base:URL(string:"https://"+host)!,token:String(repeating:"f",count:64),id:"card_"+String(repeating:"a",count:32))
    }
    @Test func old11KeepsSizeLayouts() async throws {
        let card=try await fetch("old.example.com")
        #expect(card.design.schemaVersion==2);#expect(card.design.layout(for:"small").text=="small-v2")
    }
    @Test func old10StillUsesDefault() async throws { #expect(try await fetch("oldest.example.com").design.schemaVersion==1) }
    @Test func currentServerKeepsV3() async throws { #expect(try await fetch("new.example.com").design.schemaVersion==3) }
    @Test func legacyRetryCannotRollBackPublication() async throws {
        let card=try await fetch("stale.example.com");#expect(card.design.schemaVersion==1);#expect(card.revision=="2")
    }
}

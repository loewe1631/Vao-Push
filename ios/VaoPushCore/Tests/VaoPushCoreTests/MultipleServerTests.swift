import CSQLite
import Foundation
import Testing
@testable import VaoPushCore

@Suite("多服务器隔离与迁移")
struct MultipleServerTests {
    private func database() throws -> (SharedStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try SharedStore(url: directory.appendingPathComponent("store.sqlite")), directory)
    }
    private func connection(_ id: String) -> ServerConnection {
        ServerConnection(id:id,name:id,baseURL:URL(string:"https://\(id).example.com")!,
            serverID:id,accountID:"same_account",bindingID:"binding_\(id)")
    }
    private func payload(_ c: ServerConnection, state: StateSnapshot? = nil, binding: String? = nil) throws -> Data {
        var content: [String:Any] = ["version":1,"kind":state == nil ? "message":"widget_state", "server_id":c.serverID!,
            "binding_id":binding ?? c.bindingID!,"account_id":c.accountID!,"message_id":"same_message","received_at":"2026-10-24T12:00:00Z"]
        if let state { content["snapshot"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) }
        return try JSONSerialization.data(withJSONObject:["vao_push":content])
    }
    @Test("相同账号及各类 ID 分开保存，推送不覆盖别名和交互")
    func independentNamespaces() throws {
        let (store,dir) = try database(); defer { try? FileManager.default.removeItem(at:dir) }
        for (index,id) in ["one","two"].enumerated() {
            let c = connection(id); try store.saveConnection(c)
            var snapshot = PrototypeData.snapshots()[0]; snapshot.revision = "\(index+1)"
            var card = PrototypeData.cards[0]; card.fields[0].alias = "\(id)的名称"
            try store.save(card,owner:c.owner!)
            try store.setMode(index == 0 ? .chart:.summary,cardID:card.id,family:"0",owner:c.owner!)
            try PushReceiver.receive(payload:payload(c,state:snapshot),title:"",body:"",store:store)
            try PushReceiver.receive(payload:payload(c),title:id,body:id,store:store)
        }
        let a = connection("one").owner!, b = connection("two").owner!
        #expect(a != b)
        #expect(try store.messages(owner:a).first?.title == "one")
        #expect(try store.messages(owner:b).first?.title == "two")
        #expect(try store.snapshots(owner:a).first?.revision == "1")
        #expect(try store.snapshots(owner:b).first?.revision == "2")
        #expect(try store.cards(owner:a).first?.fields[0].alias == "one的名称")
        #expect(try store.cards(owner:b).first?.fields[0].alias == "two的名称")
        #expect(try store.mode(cardID:PrototypeData.cards[0].id,family:"0",owner:a) == .chart)
        #expect(try store.mode(cardID:PrototypeData.cards[0].id,family:"0",owner:b) == .summary)
        let reopened = try SharedStore(url:dir.appendingPathComponent("store.sqlite"))
        #expect(try reopened.connections().count == 2)
        #expect(try reopened.messages(owner:b).count == 1)
    }
    @Test("停用拒收但保留卡片；移除仅删除对应来源")
    func disablingAndRemoval() throws {
        let (store,dir) = try database(); defer { try? FileManager.default.removeItem(at:dir) }
        var a = connection("one"); let b = connection("two")
        for c in [a,b] {
            try store.saveConnection(c); try store.save(PrototypeData.cards[0],owner:c.owner!)
            try PushReceiver.receive(payload:payload(c),title:c.id,body:"",store:store)
        }
        a.isEnabled = false; try store.saveConnection(a)
        #expect(throws:CoreError.self) { try PushReceiver.receive(payload:payload(a),title:"",body:"",store:store) }
        #expect(try store.cards(owner:a.owner!).count == 1)
        try PushReceiver.receive(payload:payload(b),title:"two",body:"",store:store)
        try store.deleteConnection(id:a.id)
        #expect(try store.cards(owner:a.owner!).isEmpty)
        #expect(try store.messages(owner:a.owner!).isEmpty)
        #expect(try store.cards(owner:b.owner!).count == 1)
        #expect(try store.messages(owner:b.owner!).count == 1)
        #expect(throws:CoreError.self) { try PushReceiver.receive(payload:payload(a),title:"",body:"",store:store) }
    }
    @Test("未知、伪造和歧义绑定拒绝入库；真实接收不接受演示绑定")
    func rejectedRouting() throws {
        let (store,dir) = try database(); defer { try? FileManager.default.removeItem(at:dir) }
        var a = connection("one")
        #expect(throws:CoreError.self) { try PushReceiver.receive(payload:payload(a),title:"",body:"",store:store) }
        try store.saveConnection(a)
        #expect(throws:CoreError.self) { try PushReceiver.receive(payload:payload(a,binding:"forged"),title:"",body:"",store:store) }
        var b = connection("two"); b.serverID = a.serverID; b.bindingID = a.bindingID
        try store.saveConnection(b)
        #expect(throws:CoreError.self) { try PushReceiver.receive(payload:payload(a),title:"",body:"",store:store) }
        try store.deleteConnection(id:b.id)
        a.isDemo = true; try store.saveConnection(a)
        #expect(throws:CoreError.self) { try PushReceiver.receive(payload:payload(a),title:"",body:"",store:store) }
        #expect(try store.messages(owner:a.owner!).isEmpty)
    }
    @Test("地址规范化、阻止重复及带绑定改址；账号分隔符不碰撞")
    func endpointsAndIdentity() throws {
        #expect(try ServerConnection.endpoint(" HTTPS://EXAMPLE.COM:443/vao/ ").absoluteString == "https://example.com/vao")
        #expect(try ServerConnection.endpoint("HTTP://192.0.2.20:8188/").absoluteString == "http://192.0.2.20:8188")
        #expect(try ServerConnection.endpoint("http://example.com:80").absoluteString == "http://example.com")
        #expect(try ServerConnection.endpoint("http://[2001:db8::1]:8188").port == 8188)
        for url in ["ftp://example.com","https://u:p@example.com","http://u:p@example.com","https://example.com?key=x","https://example.com#x",
                    "https://example.com/a/../b","https://example.com/%2e%2e/b","https://example.com/%2fsecret","https://example.com:0"] {
            #expect(throws:CoreError.self) { try ServerConnection.endpoint(url) }
        }
        #expect(ServerConnection.scope(connectionID:"a:b",accountID:"c") != ServerConnection.scope(connectionID:"a",accountID:"b:c"))
        let (store,dir) = try database(); defer { try? FileManager.default.removeItem(at:dir) }
        var a = connection("one"); try store.saveConnection(a)
        var duplicate = a; duplicate.id = "another"
        #expect(throws:CoreError.self) { try store.saveConnection(duplicate) }
        a.baseURL = URL(string:"https://new.example.com")!
        #expect(throws:CoreError.self) { try store.saveConnection(a) }
        #expect(try store.connections().first?.baseURL == connection("one").baseURL)
    }
    @Test("v1 数据库迁移保留迁移前卡片别名和交互")
    func migration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url = dir.appendingPathComponent("store.sqlite"); var db: OpaquePointer?
        #expect(sqlite3_open(url.path,&db) == SQLITE_OK)
        var card = PrototypeData.cards[0]; card.fields[0].alias = "迁移前别名"
        let blob = try JSONEncoder().encode(card).map { String(format:"%02x",$0) }.joined()
        for sql in ["CREATE TABLE snapshots (owner TEXT,stream_id TEXT,payload BLOB,PRIMARY KEY(owner,stream_id))",
                    "CREATE TABLE cards (owner TEXT,card_id TEXT,payload BLOB,PRIMARY KEY(owner,card_id))",
                    "CREATE TABLE interactions (owner TEXT,card_id TEXT,family TEXT,mode TEXT,PRIMARY KEY(owner,card_id,family))",
                    "CREATE TABLE messages (owner TEXT,message_id TEXT,payload BLOB,PRIMARY KEY(owner,message_id))",
                    "INSERT INTO cards VALUES ('account_demo','card_demo_quote',X'\(blob)')",
                    "INSERT INTO interactions VALUES ('account_demo','card_demo_quote','0','chart')","PRAGMA user_version=1"] {
            #expect(sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK)
        }
        sqlite3_close(db)
        let store = try SharedStore(url:url); try store.saveConnection(connection("one"))
        let reopened = try SharedStore(url:url)
        #expect(try reopened.cards(owner:PrototypeData.owner).first?.fields[0].alias == "迁移前别名")
        #expect(try reopened.mode(cardID:card.id,family:"0",owner:PrototypeData.owner) == .chart)
        #expect(try reopened.connections().count == 1)
    }
    @Test("组件实体按来源寻址并兼容旧选择")
    func widgetIdentity() throws {
        let a = ScopedCardID.encode(owner:connection("one").owner!,cardID:"same")
        let b = ScopedCardID.encode(owner:connection("two").owner!,cardID:"same")
        #expect(a != b)
        #expect(try ScopedCardID.decode(a).owner == connection("one").owner)
        #expect(try ScopedCardID.decode(b).cardID == "same")
        #expect(try ScopedCardID.decode("card_demo_quote").owner == PrototypeData.owner)
        #expect(throws:CoreError.self) { try ScopedCardID.decode("scoped:bad") }
    }
}

private final class DiscoveryStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let isHTML = url.path.contains("html"), future = url.path.contains("future")
        let validPrefix = url.path == "/vao/v1/info" || isHTML || future
        let body = isHTML ? "<html>OK</html>" : "{\"data\":{\"protocol_version\":\(future ? 2:1),\"server_id\":\"one\",\"name\":\"Test\"}}"
        let status = request.value(forHTTPHeaderField:"Authorization") == nil && validPrefix ? 200:403
        let response = HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,
            headerFields:["Content-Type":isHTML ? "text/html":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("服务发现兼容性")
struct DiscoveryTests {
    @Test("发现不带凭证且保留前缀；网页及未知协议不能通过")
    func inspect() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DiscoveryStub.self]
        let session = URLSession(configuration:config); defer { session.invalidateAndCancel() }
        let client = ServerInfoClient(session:session)
        #expect(try await client.inspect(baseURL:URL(string:"https://example.com/vao")!).serverID == "one")
        await #expect(throws:SnapshotClientError.invalidResponse) { try await client.inspect(baseURL:URL(string:"https://example.com/html")!) }
        await #expect(throws:CoreError.self) { try await client.inspect(baseURL:URL(string:"https://example.com/future")!) }
    }
}

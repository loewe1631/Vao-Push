import Foundation
import Testing
@testable import VaoPushCore

/// Opt-in network acceptance. Input lives outside the repository; credentials never enter logs.
@Suite("真实服务网络接入", .serialized, .enabled(if: ProcessInfo.processInfo.environment["VAO_LIVE_FIXTURE"] != nil))
struct LiveServerTests {
    @Test("配对、同步、状态读取和重启后恢复")
    func liveRoundtrip() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["VAO_LIVE_FIXTURE"])
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:path))) as! [String:String]
        let endpoint = URL(string: fixture["url"]!)!, client = DeviceClient()
        let credentialsPath = path + ".credentials"
        let credentials: DeviceCredentials
        if FileManager.default.fileExists(atPath:credentialsPath) {
            credentials = try JSONDecoder().decode(DeviceCredentials.self,from:Data(contentsOf:URL(fileURLWithPath:credentialsPath)))
        } else {
            credentials = try await client.pair(baseURL:endpoint,code:fixture["code"]!,deviceName:"Swift 网络验证")
            try JSONEncoder().encode(credentials).write(to:URL(fileURLWithPath:credentialsPath),options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:credentialsPath)
        }
        let page = try await client.sync(baseURL:endpoint,token:credentials.deviceToken,cursor:nil)
        #expect(page.serverID == credentials.serverID && page.accountID == credentials.accountID && page.bindingID == credentials.bindingID)
        let snapshot = try #require(page.snapshots.first(where:{$0.dataID == "task_progress"}))
        try ProtocolRules.validate(snapshot)
        try await client.subscriptions(baseURL:endpoint,token:credentials.deviceToken,dataIDs:[snapshot.dataID])
        let result = try await SnapshotClient().fetch(baseURL:endpoint,dataID:snapshot.dataID,bearer:credentials.readToken)
        guard case .snapshot(let fetched,_) = result else { Issue.record("缺少真实服务快照"); return }
        #expect(fetched == snapshot)
        if let expected = fixture["expected_message"] { #expect(page.messages.contains(where:{$0.body == expected})) }
        if let expected = fixture["expected_progress"] { #expect(snapshot.state.fields?["progress"]?.value == .text(expected)) }
        let storeURL = URL(fileURLWithPath:path+".sqlite")
        let store = try SharedStore(url:storeURL)
        let owner = "live-server-test"
        if try store.card(id:"live-card",owner:owner) == nil {
            try store.save(CardConfiguration(id:"live-card",name:"工作进度",streamID:snapshot.streamID,fields:[FieldBinding(key:"progress",alias:"我的完成率")]),owner:owner)
        }
        try store.apply(snapshot,owner:owner)
        #expect(try store.card(id:"live-card",owner:owner)?.fields.first?.alias == "我的完成率")
        #expect(try store.snapshot(streamID:snapshot.streamID,owner:owner)?.revision == snapshot.revision)
        if !page.messages.isEmpty {
            let next = try await client.sync(baseURL:endpoint,token:credentials.deviceToken,cursor:page.cursor)
            #expect(next.messages.isEmpty)
        }
    }
}

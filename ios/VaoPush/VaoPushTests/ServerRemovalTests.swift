import Foundation
import Testing
import VaoPushCore
@testable import VaoPush

private final class RemovalProbe: @unchecked Sendable {
    static let shared = RemovalProbe()
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    func record(_ host: String) { lock.withLock { calls[host, default: 0] += 1 } }
    func count(_ host: String) -> Int { lock.withLock { calls[host, default: 0] } }
}
private final class RemovalProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let host = request.url!.host!
        RemovalProbe.shared.record(host)
        if host.hasPrefix("timeout") {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let unavailable = host.hasPrefix("unavailable")
        let body = Data((unavailable ? "Cloudflare tunnel unavailable" : "{\"data\":{\"ok\":true}}").utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: unavailable ? 530 : 200, httpVersion: nil,
            headerFields: ["Content-Type": unavailable ? "text/html" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("服务器移除失败与强制本地确认", .serialized)
struct ServerRemovalTests {
    @MainActor private func exercise(_ prefix: String, remoteSucceeds: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SharedStore(url: directory.appendingPathComponent("test.sqlite"))
        let host = prefix + "-" + UUID().uuidString.lowercased() + ".example"
        let removed = ServerConnection(id: "remove-" + UUID().uuidString, name: "Target", baseURL: URL(string: "https://" + host)!,
            serverID: "server-target", accountID: "account-target", bindingID: "binding-target")
        let kept = ServerConnection(id: "keep-" + UUID().uuidString, name: "Other", baseURL: URL(string: "https://kept.example")!,
            serverID: "server-keep", accountID: "account-keep", bindingID: "binding-keep")
        defer {
            for connection in [removed, kept] {
                try? CredentialVault.remove(id: connection.id)
                try? CredentialVault.remove(id: connection.id, shared: true)
                try? CredentialVault.remove(id: "registration-" + connection.id)
            }
        }
        for connection in [removed, kept] {
            try store.saveConnection(connection)
            let values: [String: Any] = ["server_id": connection.serverID!, "account_id": connection.accountID!,
                "binding_id": connection.bindingID!, "device_token": String(repeating: "a", count: 64),
                "read_token": String(repeating: "b", count: 64), "send_key": String(repeating: "c", count: 64),
                "expires_at": "2030-01-01T00:00:00Z"]
            try CredentialVault.save(JSONSerialization.data(withJSONObject: values), id: connection.id)
            try CredentialVault.save(Data(String(repeating: "b", count: 64).utf8), id: connection.id, shared: true)
            try CredentialVault.save(Data("pending-test".utf8), id: "registration-" + connection.id)
            let owner = connection.owner!
            let snapshot = StateSnapshot(streamID: "same-stream", dataID: "progress", revision: "1", receivedAt: "2026-10-26T00:00:00Z",
                state: WidgetState(sourceUpdatedAt: "2026-10-26T00:00:00Z", fields: ["progress": DataField(type: .percent, value: .text("68"))]))
            try store.apply(snapshot, owner: owner)
            try store.save(CardConfiguration(id: "same-card", name: "My Card", streamID: "same-stream", fields: []), owner: owner)
            try store.archive(ArchivedMessage(id: "same-message", title: "Kept text", body: "Body", receivedAt: "2026-10-26T00:00:00Z"), owner: owner)
            try store.setMode(.chart, cardID: "same-card", family: "1", owner: owner)
        }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [RemovalProtocol.self]
        let model = PrototypeModel(store: store, deviceClient: DeviceClient(session: URLSession(configuration: sessionConfig)))
        let first = await model.removeServer(removed)
        if !remoteSucceeds {
            guard case .remoteUnconfirmed(let reason) = first else { Issue.record("Remote failure did not request confirmation"); return }
            if prefix == "unavailable" { #expect(reason.contains("530")) }
            #expect(try store.connections().contains { $0.id == removed.id })
            #expect(try store.cards(owner: removed.owner!).count == 1)
            #expect(try store.messages(owner: removed.owner!).count == 1)
            #expect(try CredentialVault.load(id: removed.id) != nil)
            let requests = RemovalProbe.shared.count(host)
            guard case .removed = await model.removeServer(removed, localOnly: true) else { Issue.record("Forced local removal failed"); return }
            #expect(RemovalProbe.shared.count(host) == requests)
        } else {
            guard case .removed = first else { Issue.record("Online removal failed"); return }
        }
        #expect(try !store.connections().contains { $0.id == removed.id })
        #expect(try store.cards(owner: removed.owner!).isEmpty)
        #expect(try store.messages(owner: removed.owner!).isEmpty)
        #expect(try store.snapshots(owner: removed.owner!).isEmpty)
        #expect(try CredentialVault.load(id: removed.id) == nil)
        #expect(try CredentialVault.load(id: removed.id, shared: true) == nil)
        #expect(try CredentialVault.load(id: "registration-" + removed.id) == nil)
        #expect(try store.connections().contains { $0.id == kept.id })
        #expect(try store.cards(owner: kept.owner!).count == 1)
        #expect(try store.messages(owner: kept.owner!).count == 1)
        #expect(try store.snapshots(owner: kept.owner!).count == 1)
        #expect(try CredentialVault.load(id: kept.id) != nil)
        #expect(model.connections.count == 1)
    }

    @Test("530保留本机，明确强删后清理所选来源和凭据，另一来源不变")
    @MainActor func unavailable() async throws { try await exercise("unavailable", remoteSucceeds: false) }
    @Test("超时保留资料与强制删除选择")
    @MainActor func timeout() async throws { try await exercise("timeout", remoteSucceeds: false) }
    @Test("在线解绑成功后正常移除")
    @MainActor func online() async throws { try await exercise("online", remoteSucceeds: true) }
}

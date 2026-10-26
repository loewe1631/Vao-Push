import Foundation
import Testing
@testable import VaoPushCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        let dataID = url.deletingLastPathComponent().lastPathComponent
        var status = 200
        var data = Data()
        if request.value(forHTTPHeaderField: "Authorization") != "Bearer test-placeholder" {
            status = 401
        } else if dataID == "unchanged" {
            status = request.value(forHTTPHeaderField: "If-None-Match") == "\"test-etag\"" ? 304 : 400
        } else if dataID == "unauthorized" {
            status = 403
        } else if dataID == "redirect" {
            status = 302
        } else if dataID == "large" {
            data = Data(repeating: 32, count: 74 * 1024)
        } else {
            let snapshot = StateSnapshot(streamID: "stream_demo", dataID: "ok", revision: "9",
                                         receivedAt: "2026-10-24T10:00:01Z",
                                         state: WidgetState(sourceUpdatedAt: "2026-10-24T10:00:00Z", fields: ["progress": .init(type: .percent, value: .text("25"))]))
            data = try! JSONEncoder().encode(SnapshotEnvelope(data: snapshot))
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["ETag": "\"test-etag\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func client() -> SnapshotClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return SnapshotClient(session: URLSession(configuration: configuration))
}

@Suite("服务端快照读取")
struct SnapshotClientTests {
    @Test("请求头身份验证与 ETag 响应，不访问真实网络")
    func successfulFetch() async throws {
        let result = try await client().fetch(baseURL: URL(string: "https://example.com")!, dataID: "ok", bearer: "test-placeholder")
        guard case .snapshot(let snapshot, let etag) = result else { Issue.record("应返回快照"); return }
        #expect(snapshot.revision == "9")
        #expect(snapshot.state.fields?["progress"]?.value == .text("25"))
        #expect(etag == "\"test-etag\"")
    }

    @Test("304 只在发送条件读取时有效")
    func notModified() async throws {
        let result = try await client().fetch(baseURL: URL(string: "https://example.com")!, dataID: "unchanged", bearer: "test-placeholder", etag: "\"test-etag\"")
        #expect(result == .notModified)
    }

    @Test("HTTP快照读取保留校验，拒绝其他协议和请求头注入")
    func requestValidation() async throws {
        let http = try await client().fetch(baseURL: URL(string: "http://192.0.2.20:8188")!, dataID: "ok", bearer: "test-placeholder")
        guard case .snapshot(let snapshot, _) = http else { Issue.record("HTTP snapshot missing"); return }
        #expect(snapshot.revision == "9")
        await #expect(throws: SnapshotClientError.insecureEndpoint) {
            try await client().fetch(baseURL: URL(string: "ftp://example.com")!, dataID: "ok", bearer: "test-placeholder")
        }
        await #expect(throws: SnapshotClientError.insecureEndpoint) {
            try await client().fetch(baseURL: URL(string: "https://example.com?token=test")!, dataID: "ok", bearer: "test-placeholder")
        }
        await #expect(throws: SnapshotClientError.invalidRequest) {
            try await client().fetch(baseURL: URL(string: "https://example.com")!, dataID: "ok", bearer: "test\nplaceholder")
        }
    }

    @Test("错误状态、其他数据源和超限响应不进入缓存")
    func responseValidation() async throws {
        let endpoint = URL(string: "https://example.com")!
        await #expect(throws: SnapshotClientError.unexpectedStatus(403)) {
            try await client().fetch(baseURL: endpoint, dataID: "unauthorized", bearer: "test-placeholder")
        }
        await #expect(throws: SnapshotClientError.unexpectedStatus(302)) {
            try await client().fetch(baseURL: endpoint, dataID: "redirect", bearer: "test-placeholder")
        }
        await #expect(throws: SnapshotClientError.wrongDataID) {
            try await client().fetch(baseURL: endpoint, dataID: "different", bearer: "test-placeholder")
        }
        await #expect(throws: SnapshotClientError.responseTooLarge) {
            try await client().fetch(baseURL: endpoint, dataID: "large", bearer: "test-placeholder")
        }
    }
}

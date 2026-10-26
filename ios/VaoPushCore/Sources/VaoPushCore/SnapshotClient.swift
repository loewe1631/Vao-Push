import Foundation

public enum SnapshotClientError: Error, Equatable, Sendable {
    case insecureEndpoint
    case invalidRequest
    case unexpectedStatus(Int)
    case invalidResponse
    case responseTooLarge
    case wrongDataID
}

public enum SnapshotFetchResult: Equatable, Sendable {
    case notModified
    case snapshot(StateSnapshot, etag: String?)
}

/// Reads only an explicitly configured Vao Push server. Credentials are never persisted here.
public final class SnapshotClient: Sendable {
    private let session: URLSession
    private let ownsSession: Bool

    public init(session: URLSession? = nil) {
        ownsSession = session == nil
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        }
    }

    deinit { if ownsSession { session.invalidateAndCancel() } }

    public func fetch(baseURL: URL, dataID: String, bearer: String, etag: String? = nil) async throws -> SnapshotFetchResult {
        guard let baseURL = try? ServerConnection.endpoint(baseURL.absoluteString) else {
            throw SnapshotClientError.insecureEndpoint
        }
        guard dataID.range(of: "^[a-z0-9_-]{1,64}$", options: .regularExpression) != nil,
              !bearer.isEmpty, bearer.unicodeScalars.allSatisfy({ (33...126).contains(Int($0.value)) }) else {
            throw SnapshotClientError.invalidRequest
        }
        if let etag, etag.contains("\n") || etag.contains("\r") { throw SnapshotClientError.invalidRequest }
        let url = baseURL.appendingPathComponent("v1").appendingPathComponent("widgets")
            .appendingPathComponent(dataID).appendingPathComponent("state")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SnapshotClientError.invalidResponse }
        if response.statusCode == 304 {
            guard etag != nil else { throw SnapshotClientError.invalidResponse }
            return .notModified
        }
        guard response.statusCode == 200 else { throw SnapshotClientError.unexpectedStatus(response.statusCode) }
        guard data.count <= 72 * 1024 else { throw SnapshotClientError.responseTooLarge }
        let snapshot = try JSONDecoder().decode(SnapshotEnvelope.self, from: data).data
        guard snapshot.dataID == dataID else { throw SnapshotClientError.wrongDataID }
        try ProtocolRules.validate(snapshot)
        return .snapshot(snapshot, etag: response.value(forHTTPHeaderField: "ETag"))
    }
}

final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

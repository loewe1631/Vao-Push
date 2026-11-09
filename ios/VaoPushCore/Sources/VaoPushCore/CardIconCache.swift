import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(iOS)
import UIKit
import ImageIO
import CryptoKit
import Darwin
#endif

public enum CardIconPolicy {
    public static func validURL(_ raw: String) -> Bool {
        guard raw.utf8.count <= 1024, let u = URLComponents(string: raw), u.scheme == "https", let host = u.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), host.contains("."), u.user == nil, u.password == nil, u.fragment == nil, u.port == nil || u.port == 443 else { return false }
        guard host != "localhost", !host.hasSuffix(".local"), !host.contains(":"), !host.hasPrefix("127."), !host.hasPrefix("10."), !host.hasPrefix("192.168."), !host.hasPrefix("169.254."), !host.hasPrefix("0.") else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 { return false } // DNS host names only; reject ambiguous numeric addresses too.
        return true
    }
}
public actor CardIconCache {
    public static let shared = CardIconCache()
    #if os(iOS)
    private var failed: [String: Date] = [:]
    private var activeDownloads = 0
    private var inFlight: [String: Task<Void, Never>] = [:]
    private let configurationOverride: URLSessionConfiguration?
    private let resolverOverride: (@Sendable (String) async -> Bool)?
    init(configuration: URLSessionConfiguration? = nil, resolver: (@Sendable (String) async -> Bool)? = nil) {
        configurationOverride = configuration; resolverOverride = resolver
    }
    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PrototypeStorage.groupID)?.appendingPathComponent("Library/Caches/CardIcons", isDirectory: true)
    }
    private static func file(_ raw: String) -> URL? { directory?.appendingPathComponent(SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()) }
    public nonisolated static func cached(_ raw: String) -> UIImage? {
        guard CardIconPolicy.validURL(raw), let file = file(raw), let attrs = try? FileManager.default.attributesOfItem(atPath: file.path), let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < 7*86400, let data = try? Data(contentsOf: file), validImage(data) else { return nil }
        return UIImage(data: data)
    }
    private nonisolated static func validImage(_ data: Data) -> Bool {
        guard data.count <= 512*1024, let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0, w <= 2048, h <= 2048 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
    private nonisolated static func publicDNS(_ host: String) -> Bool {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &addresses) == 0, let first = addresses else { return false }
        defer { freeaddrinfo(first) }
        var next: UnsafeMutablePointer<addrinfo>? = first
        while let info = next {
            if info.pointee.ai_family == AF_INET6 {
                let addr = UnsafeRawPointer(info.pointee.ai_addr).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                let bytes = withUnsafeBytes(of: addr) { Array($0) }
                // Permit only global unicast, excluding documentation and transition ranges.
                if bytes[0] & 0xE0 != 0x20 || (bytes[0] == 0x20 && bytes[1] == 0x01 && (bytes[2] < 2 || bytes[2] == 0x0D && bytes[3] == 0xB8)) { return false }
                next = info.pointee.ai_next; continue
            }
            guard info.pointee.ai_family == AF_INET else { return false }
            let addr = UnsafeRawPointer(info.pointee.ai_addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            let a = addr >> 24, b = (addr >> 16) & 255
            if a == 0 || a == 10 || a == 127 || a >= 224 || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && [0,168].contains(b)) || (a == 100 && (64...127).contains(b)) || (a == 198 && [18,19,51].contains(b)) || (a == 203 && b == 0) { return false }
            next = info.pointee.ai_next
        }
        return true
    }
    private nonisolated static func resolvePublicHost(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let result = CardDNSResult(continuation)
            DispatchQueue.global(qos: .utility).async { result.finish(publicDNS(host)) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { result.finish(false) }
        }
    }
    public func load(_ raw: String) async {
        if Self.cached(raw) != nil { return }
        if let pending = inFlight[raw] { await pending.value; return }
        guard inFlight.count < 4 else { return }
        let pending = Task { await self.performLoad(raw) }
        inFlight[raw] = pending
        await pending.value
        inFlight.removeValue(forKey: raw)
    }
    private func performLoad(_ raw: String) async {
        if Self.cached(raw) != nil || failed[raw].map({ Date().timeIntervalSince($0) < 300 }) == true { return }
        guard activeDownloads < 4 else { return }
        activeDownloads += 1
        defer { activeDownloads -= 1 }
        if failed.count >= 128, let oldest = failed.min(by: { $0.value < $1.value })?.key { failed.removeValue(forKey: oldest) }
        failed[raw] = Date()
        guard CardIconPolicy.validURL(raw), let url = URL(string: raw), let host = url.host else { return }
        // Resolve on a utility thread, never on the UI thread. Redirects are rejected.
        let allowed: Bool
        if let resolverOverride { allowed = await resolverOverride(host) }
        else { allowed = await Self.resolvePublicHost(host) }
        guard allowed else { return }
        let config = configurationOverride?.copy() as? URLSessionConfiguration ?? URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url); request.setValue("image/png,image/jpeg,image/webp", forHTTPHeaderField: "Accept")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.mimeType?.hasPrefix("image/") == true, http.expectedContentLength <= 512*1024 else { return }
            var data = Data()
            for try await byte in bytes { if data.count >= 512*1024 { return }; data.append(byte) }
            guard Self.validImage(data), let dir = Self.directory, let file = Self.file(raw) else { return }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let ordered = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for stale in ordered.dropFirst(20) { try? FileManager.default.removeItem(at: stale) }
            failed.removeValue(forKey: raw)
        } catch { /* An unavailable image uses the symbol fallback. */ }
        if failed.count > 128 { failed = failed.filter { Date().timeIntervalSince($0.value) < 300 } }
    }
    #endif
    public func prefetch(_ design: CardDesign) async {
        #if os(iOS)
        let urls = Set(([design.layout] + Array((design.layouts ?? [:]).values)).flatMap(CardDesign.flatten).compactMap(\.imageURL))
        await withTaskGroup(of: Void.self) { group in
            for url in urls.sorted().prefix(4) { group.addTask { await self.load(url) } }
        }
        #endif
    }
}

#if os(iOS)
private final class CardDNSResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: value)
    }
}
#endif

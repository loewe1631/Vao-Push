import CryptoKit
import Foundation
import ImageIO
@preconcurrency import Intents
@preconcurrency import UserNotifications
import VaoPushCore
import WidgetKit
import os

private final class NoIconRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
  private let lock = NSLock()
  private var handler: ((UNNotificationContent) -> Void)?
  private var pending: UNNotificationContent?
  private var work: Task<Void, Never>?
  private var generation = UUID()
  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    let requestGeneration = UUID()
    lock.withLock {
      generation = requestGeneration
      handler = contentHandler
      pending = request.content
    }
    do {
      let store = try PrototypeStorage.open()
      let payload = try JSONSerialization.data(withJSONObject: request.content.userInfo)
      let result = try PushReceiver.receive(
        payload: payload, title: request.content.title, body: request.content.body, store: store)
      WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
      if case .state = result {
        if let content = request.content.mutableCopy() as? UNMutableNotificationContent {
          content.interruptionLevel = .passive
          content.sound = nil
          lock.withLock { pending = content }
        }
        finish()
        return
      }
      guard let push = request.content.userInfo["vao_push"] as? [String: Any],
        let raw = push["icon"] as? String, !raw.isEmpty,
        let target = try? NotificationMessageTarget(payload: payload),
        let owner = target.owner(in: try store.connections())
      else {
        finish()
        return
      }
      let original = request.content
      let task = Task { [weak self] in
        guard let self else { return }
        do {
          if let data = try await self.icon(raw, owner: owner, target: target, store: store),
            !Task.isCancelled
          {
            let image = INImage(imageData: data)
            let identity = self.digest(owner + "/" + raw)
            let sender = INPerson(
              personHandle: INPersonHandle(value: identity, type: .unknown), nameComponents: nil,
              displayName: original.title, image: image, contactIdentifier: nil,
              customIdentifier: identity, isMe: false, suggestionType: .none)
            let intent = INSendMessageIntent(
              recipients: nil, outgoingMessageType: .outgoingMessageText, content: original.body,
              speakableGroupName: nil,
              conversationIdentifier: self.digest(owner + "/" + target.messageID), serviceName: nil,
              sender: sender, attachments: nil)
            let interaction = INInteraction(intent: intent, response: nil)
            interaction.direction = .incoming
            try await interaction.donate()
            let updated = try original.updating(from: intent)
            if target.owner(in: try store.connections()) == owner {
              self.lock.withLock {
                if self.handler != nil && self.generation == requestGeneration {
                  self.pending = updated
                }
              }
            }
          }
        } catch { /* An optional image never suppresses the original message. */  }
        self.finish(generation: requestGeneration)
      }
      lock.withLock { work = task }
      DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
        self?.finish(generation: requestGeneration)
      }
    } catch { finish() }
  }
  private func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func validImage(_ data: Data) -> Bool {
    guard data.count <= 512 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let width = props[kCGImagePropertyPixelWidth as String] as? Int,
      let height = props[kCGImagePropertyPixelHeight as String] as? Int
    else { return false }
    return width > 0 && height > 0 && width <= 2048 && height <= 2048
  }
  private func icon(
    _ raw: String, owner: String, target: NotificationMessageTarget, store: SharedStore
  ) async throws -> Data? {
    guard raw.utf8.count <= 1024, let url = URL(string: raw),
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme?.lowercased() == "https", parts.user == nil, parts.password == nil,
      parts.fragment == nil, parts.host != nil
    else { return nil }
    guard
      let group = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: PrototypeStorage.groupID)
    else { return nil }
    let directory = group.appendingPathComponent(
      "Library/Caches/NotificationIcons/" + digest(owner), isDirectory: true)
    let file = directory.appendingPathComponent(digest(raw))
    if let data = try? Data(contentsOf: file), validImage(data) { return data }
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.timeoutIntervalForRequest = 2
    config.timeoutIntervalForResource = 2
    let session = URLSession(configuration: config, delegate: NoIconRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue("image/png,image/jpeg,image/webp", forHTTPHeaderField: "Accept")
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      response.expectedContentLength <= 512 * 1024, response.mimeType?.hasPrefix("image/") == true
    else { return nil }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      data.append(byte)
      if data.count > 512 * 1024 { return nil }
    }
    guard validImage(data), !Task.isCancelled, target.owner(in: try store.connections()) == owner
    else { return nil }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    try data.write(to: file, options: .atomic)
    let cached =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    if cached.count > 32 {
      let sorted = cached.sorted {
        ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          ?? .distantPast)
          < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast)
      }
      for old in sorted.prefix(cached.count - 32) { try? FileManager.default.removeItem(at: old) }
    }
    return data
  }
  override func serviceExtensionTimeWillExpire() { finish() }
  private func finish(generation expected: UUID? = nil) {
    let value = lock.withLock {
      if let expected, expected != generation {
        return (
          nil as ((UNNotificationContent) -> Void)?, nil as UNNotificationContent?,
          nil as Task<Void, Never>?
        )
      }
      let value = (handler, pending, work)
      handler = nil
      pending = nil
      work = nil
      return value
    }
    value.2?.cancel()
    if let handler = value.0, let content = value.1 { handler(content) }
  }
}

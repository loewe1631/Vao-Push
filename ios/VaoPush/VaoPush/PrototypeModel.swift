import Foundation
import UIKit
import Observation
import UserNotifications
import WidgetKit
import VaoPushCore
import os

struct SavedCard: Identifiable, Sendable {
    var card: CardConfiguration
    var source: ContentSource
    var id: String { ScopedCardID.encode(owner: source.owner, cardID: card.id) }
}

struct ReceivedState: Identifiable, Sendable {
    var snapshot: StateSnapshot
    var source: ContentSource
    var id: String { ScopedCardID.encode(owner: source.owner, cardID: snapshot.streamID) }
}

struct ReceivedMessage: Identifiable, Sendable {
    var message: ArchivedMessage
    var source: ContentSource
    var id: String { ScopedCardID.encode(owner: source.owner, cardID: message.id) }
}

enum ServerRemovalResult {
    case removed
    case remoteUnconfirmed(String)
    case localFailure(String)
}

@MainActor @Observable
final class PrototypeModel {
    var cards: [SavedCard] = []
    var snapshots: [ReceivedState] = []
    var messages: [ReceivedMessage] = []
    var connections: [ServerConnection] = []
    var sources: [ContentSource] = []
    var inspecting: Set<String> = []
    var syncing: Set<String> = []
    var registering: Set<String> = []
    var sendKeys: [String: String] = [:]
    var connectionErrors: [String: String] = [:]
    var notificationStatus = VaoL10n.text("读取中")
    var error: String?
    var isReady = false
    var startupError: String?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var store: SharedStore?
    @ObservationIgnored private lazy var infoClient = ServerInfoClient()
    @ObservationIgnored private lazy var deviceClient = DeviceClient()
    @ObservationIgnored private lazy var cardClient = CardClient()

    private struct LocalCache: Sendable {
        var connections: [ServerConnection]
        var keys: [String: String]
        var sources: [ContentSource]
        var cards: [SavedCard]
        var snapshots: [ReceivedState]
        var messages: [ReceivedMessage]
    }

    init(store: SharedStore? = nil, deviceClient: DeviceClient? = nil) {
        self.store = store
        if let deviceClient { self.deviceClient = deviceClient }
        if let store, let cache = try? Self.readCache(store) { install(cache); isReady = true }
    }

    func start() async {
        guard !isReady, !starting else { return }
        starting = true; startupError = nil
        defer { starting = false }
        #if DEBUG
        let start = ProcessInfo.processInfo.systemUptime
        #endif
        do {
            let (database, cache, examplesChanged) = try await Task.detached(priority: .userInitiated) {
                let database = try PrototypeStorage.open()
                let examplesChanged = try PrototypeData.upgradeStockExample(database)
                return (database, try Self.readCache(database), examplesChanged)
            }.value
            store = database; install(cache); isReady = true
            if examplesChanged { WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind) }
            #if DEBUG
            Logger(subsystem: "app.vaovao.push", category: "Startup").notice("background_cache_ms=\((ProcessInfo.processInfo.systemUptime - start) * 1000, privacy: .public)")
            #endif
        } catch { startupError = VaoL10n.text("本地资料暂时无法读取，请解锁设备后重试。\n") + error.localizedDescription }
    }

    private nonisolated static func readCache(_ database: SharedStore) throws -> LocalCache {
        let connections = try database.connections()
        let keys = Dictionary(uniqueKeysWithValues: connections.compactMap { connection -> (String, String)? in
            guard let data = try? CredentialVault.load(id: connection.id),
                  let credentials = try? JSONDecoder().decode(DeviceCredentials.self, from: data),
                  let key = credentials.sendKey else { return nil }
            return (connection.id, key)
        })
        let sources = try database.sources().filter { source in
            if !source.isDemo { return true }
            return try !database.cards(owner: source.owner).isEmpty
        }
        return LocalCache(connections: connections, keys: keys, sources: sources,
            cards: try sources.flatMap { source in try database.cards(owner: source.owner).map { SavedCard(card: $0, source: source) } },
            snapshots: try sources.flatMap { source in try database.snapshots(owner: source.owner).map { ReceivedState(snapshot: $0, source: source) } },
            messages: try sources.flatMap { source in try database.messages(owner: source.owner).map { ReceivedMessage(message: $0, source: source) } }
                .sorted { $0.message.receivedAt > $1.message.receivedAt })
    }

    private func install(_ cache: LocalCache) {
        connections = cache.connections; sendKeys = cache.keys; sources = cache.sources
        cards = cache.cards; snapshots = cache.snapshots; messages = cache.messages
    }

    func reload() throws {
        guard let store else { return }
        install(try Self.readCache(store))
    }

    func snapshot(for entry: SavedCard) -> StateSnapshot? {
        snapshots.first { $0.source.owner == entry.source.owner && $0.snapshot.streamID == entry.card.streamID }?.snapshot
    }

    func save(_ card: CardConfiguration, source: ContentSource) throws {
        guard let store else { throw CoreError.invalid("共享数据库未就绪") }
        guard card.remote != nil || card.message != nil || cards.contains(where: { $0.source.owner == source.owner && $0.card.id == card.id }) else {
            throw CoreError.invalid("数据卡片请在Web设计并通过订阅码导入。")
        }
        try store.save(card, owner: source.owner)
        try reload()
        WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
        if let connection = connections.first(where: { $0.owner == source.owner && !$0.isDemo }) { Task { await syncServer(id: connection.id) } }
    }

    func messageHistory(owner: String) -> [ArchivedMessage] {
        messages.filter { $0.source.owner == owner }.map(\.message)
    }

    func receiveNotificationTap(payload: Data, title: String, body: String) -> String? {
        guard let store,
              let target = try? NotificationMessageTarget(payload: payload),
              let owner = target.owner(in: connections) else { return nil }
        do {
            // The service extension may not have completed before the user taps.
            // Archive through the same binding checks and idempotent message store.
            try PushReceiver.receive(payload: payload, title: title, body: body, store: store)
            try reload()
            WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
            return messages.first { $0.source.owner == owner && $0.message.id == target.messageID }?.id
        } catch { return nil }
    }

    func displayName(for state: ReceivedState) -> String {
        if let card = cards.first(where: { $0.source.owner == state.source.owner && $0.card.streamID == state.snapshot.streamID && $0.card.remote != nil }) { return card.card.name }
        if let title = state.snapshot.state.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        return VaoL10n.text("{0}的数据", String(describing: state.source.name))
    }

    func duplicate(_ entry: SavedCard) {
        guard entry.card.message != nil else { return }
        var copy = entry.card
        copy.id = UUID().uuidString; copy.name = String(copy.name.prefix(20)) + VaoL10n.text(" 副本")
        if copy.remote != nil { copy.remote?.adjustments.name = copy.name }
        do { try save(copy, source: entry.source) } catch { self.error = String(describing: error) }
    }

    func remove(_ entry: SavedCard) {
        if let remote = entry.card.remote,
           !cards.contains(where: { $0.id != entry.id && $0.source.owner == entry.source.owner && $0.card.remote?.id == remote.id }),
           let connection = connections.first(where: { $0.owner == entry.source.owner }) {
            Task {
                do {
                    guard let data = try CredentialVault.load(id: connection.id) else { throw CoreError.invalid("设备凭证缺失") }
                    let credentials = try JSONDecoder().decode(DeviceCredentials.self, from: data)
                    try await cardClient.unsubscribe(base: connection.baseURL, token: credentials.deviceToken, id: remote.id)
                    try store?.deleteCard(id: entry.card.id, owner: entry.source.owner)
                    try reload(); WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
                } catch { self.error = VaoL10n.text("卡片未移除：") + error.localizedDescription }
            }
            return
        }
        do {
            try store?.deleteCard(id: entry.card.id, owner: entry.source.owner)
            try reload()
            if let connection = connections.first(where: { $0.owner == entry.source.owner && !$0.isDemo }) { Task { await syncServer(id: connection.id) } }
            WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
        } catch { self.error = String(describing: error) }
    }

    @discardableResult func addServer(name: String, address: String, deviceName: String) throws -> String {
        guard let store else { throw CoreError.invalid("共享数据库未就绪") }
        let url = try ServerConnection.endpoint(address)
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var connection = ServerConnection(name: label.isEmpty ? String((url.host ?? VaoL10n.text("我的服务器")).prefix(60)) : label, baseURL: url)
        connection.deviceName = try ServerConnection.normalizedDeviceName(deviceName)
        try store.saveConnection(connection)
        try reload()
        return connection.id
    }

    func updateServer(_ connection: ServerConnection) throws {
        guard let store else { throw CoreError.invalid("共享数据库未就绪") }
        try store.saveConnection(connection)
        try reload()
        WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
    }

    func removeServer(_ connection: ServerConnection, localOnly: Bool = false) async -> ServerRemovalResult {
        if !localOnly, !connection.isDemo, connection.bindingID != nil {
            do {
                guard let data = try CredentialVault.load(id: connection.id) else {
                    throw CoreError.invalid("凭证缺失。请在 Web 解绑设备，或选择仅清除此手机配置。")
                }
                let credentials = try JSONDecoder().decode(DeviceCredentials.self, from: data)
                try await deviceClient.revoke(baseURL: connection.baseURL, token: credentials.deviceToken)
            } catch {
                // Keep all local data and credentials until the user explicitly
                // confirms local removal after an unsuccessful remote revoke.
                return .remoteUnconfirmed(error.localizedDescription)
            }
        }
        do {
            guard let store else { throw CoreError.invalid("共享数据库未就绪") }
            try CredentialVault.remove(id: "registration-" + connection.id)
            try CredentialVault.remove(id: connection.id)
            try CredentialVault.remove(id: connection.id, shared: true)
            try store.deleteConnection(id: connection.id)
            connectionErrors.removeValue(forKey: connection.id)
            try reload()
            WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
            return .removed
        } catch {
            return .localFailure(error.localizedDescription)
        }
    }

    func inspectServer(id: String) async {
        guard let connection = connections.first(where: { $0.id == id }), connection.isEnabled,
              !connection.isDemo, !inspecting.contains(id) else { return }
        inspecting.insert(id); connectionErrors[id] = nil
        defer { inspecting.remove(id) }
        do {
            let info = try await infoClient.inspect(baseURL: connection.baseURL)
            guard var current = connections.first(where: { $0.id == id }), current.isEnabled else { return }
            guard current.serverID == nil || current.serverID == info.serverID else {
                throw CoreError.invalid("此地址的服务器身份已变化，请重新添加并绑定。")
            }
            current.serverID = info.serverID
            current.checkedAt = ISO8601DateFormatter().string(from: .now)
            try updateServer(current)
        } catch {
            guard connections.contains(where: { $0.id == id }) else { return }
            connectionErrors[id] = VaoL10n.text("检测未通过：请检查网络、地址及 Vao Push 协议。")
        }
    }

    func connectServer(id: String) async {
        guard let store, let connection = connections.first(where: { $0.id == id }), !connection.isDemo,
              connection.isEnabled, connection.bindingID == nil, !registering.contains(id) else { return }
        registering.insert(id); connectionErrors[id] = nil
        defer { registering.remove(id) }
        do {
            let deviceName = try ServerConnection.normalizedDeviceName(connection.deviceName ?? "")
            let info = try await infoClient.inspect(baseURL: connection.baseURL)
            guard connection.serverID == nil || connection.serverID == info.serverID else { throw CoreError.invalid("服务器身份变化，请重新添加。") }
            guard var verified = connections.first(where: { $0.id == id && $0.isEnabled && $0.bindingID == nil }) else { return }
            verified.serverID = info.serverID
            if verified.name == verified.baseURL.host.map({ String($0.prefix(60)) }) { verified.name = String(info.name.prefix(60)) }
            verified.checkedAt = ISO8601DateFormatter().string(from: .now)
            try store.saveConnection(verified)
            let pendingID = "registration-" + id
            let registrationToken: String
            if let pending = try CredentialVault.load(id: pendingID), let value = String(data: pending, encoding: .utf8) {
                registrationToken = value
            } else {
                registrationToken = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
                try CredentialVault.save(Data(registrationToken.utf8), id: pendingID)
            }
            let credentials = try await deviceClient.connect(baseURL: connection.baseURL, registrationToken: registrationToken, deviceName: deviceName)
            guard credentials.serverID == info.serverID else { throw DeviceClientError.invalidResponse }
            guard connections.contains(where: { $0.id == id && $0.isEnabled }) else {
                try? await deviceClient.revoke(baseURL: connection.baseURL, token: credentials.deviceToken)
                return
            }
            // Keep the pending registration secret until all local writes succeed. A lost
            // response or Keychain failure retries the same registration without a new device.
            try CredentialVault.save(JSONEncoder().encode(credentials), id: id)
            try CredentialVault.save(Data(credentials.readToken.utf8), id: id, shared: true)
            try store.bindConnection(id: id, credentials: credentials)
            try? CredentialVault.remove(id: pendingID)
            try reload()
            await syncServer(id: id)
        } catch { connectionErrors[id] = error.localizedDescription }
    }

    func syncAll() async {
        let ids = connections.filter { $0.isEnabled && !$0.isDemo && $0.bindingID != nil }.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.syncServer(id: id) } }
        }
    }

    func syncServer(id: String) async {
        guard let store, let connection = connections.first(where: { $0.id == id }), connection.isEnabled,
              !connection.isDemo, let owner = connection.owner, !syncing.contains(id) else { return }
        syncing.insert(id); defer { syncing.remove(id) }
        do {
            guard let data = try CredentialVault.load(id: id) else { throw CoreError.invalid("设备凭证缺失，请重新添加服务器。") }
            var credentials = try JSONDecoder().decode(DeviceCredentials.self, from: data)
            guard credentials.serverID == connection.serverID, credentials.bindingID == connection.bindingID,
                  credentials.accountID == connection.accountID else { throw DeviceClientError.invalidResponse }
            if credentials.sendKey == nil {
                credentials.sendKey = try await deviceClient.sendingKey(baseURL: connection.baseURL, token: credentials.deviceToken)
                try CredentialVault.save(JSONEncoder().encode(credentials), id: id)
            }
            var changed = false
            var cursor = connection.messageCursor
            for _ in 0..<20 {
                let page = try await deviceClient.sync(baseURL: connection.baseURL, token: credentials.deviceToken, cursor: cursor)
                guard page.serverID == credentials.serverID, page.accountID == credentials.accountID,
                      page.bindingID == credentials.bindingID,
                      connections.contains(where: { $0.id == id && $0.isEnabled && $0.bindingID == credentials.bindingID }) else {
                    throw DeviceClientError.invalidResponse
                }
                for snapshot in page.snapshots { try ProtocolRules.validate(snapshot) }
                if let deviceName = page.deviceName,
                   var current = connections.first(where: { $0.id == id && $0.bindingID == credentials.bindingID }) {
                    current.deviceName = deviceName
                    try store.saveConnection(current)
                }
                for message in page.messages { guard ProtocolRules.date(message.receivedAt) != nil else { throw DeviceClientError.invalidResponse } }
                for snapshot in page.snapshots {
                    let old = try store.snapshot(streamID: snapshot.streamID, owner: owner)
                    try store.apply(snapshot, owner: owner)
                    if old?.revision != snapshot.revision { changed = true }
                }
                for message in page.messages { try store.archive(message.archived, owner: owner) }
                if !page.messages.isEmpty { changed = true }
                try store.saveSyncCursor(connectionID: id, bindingID: credentials.bindingID, cursor: page.cursor)
                if !page.hasMore { break }
                guard page.cursor != cursor else { throw DeviceClientError.invalidResponse }
                cursor = page.cursor
            }
            try reload()
            try await syncWebCards(connection: connection, credentials: credentials)
            let ownIDs = Set(cards.filter { $0.source.owner == owner && $0.card.remote == nil && $0.card.message == nil }.compactMap { snapshot(for: $0)?.dataID })
            try await deviceClient.subscriptions(baseURL: connection.baseURL, token: credentials.deviceToken, dataIDs: Array(ownIDs))
            let apns = try CredentialVault.load(id: "installation-apns").flatMap { String(data: $0, encoding: .utf8) }
            let widget = try CredentialVault.load(id: "installation-widget", shared: true).flatMap { String(data: $0, encoding: .utf8) }
            try await deviceClient.register(baseURL: connection.baseURL, token: credentials.deviceToken,
                apns: apns, widget: widget, environment: PushEnvironment.current)
            connectionErrors[id] = nil
            if changed { WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind) }
        } catch { connectionErrors[id] = error.localizedDescription }
    }

    func importCard(connectionID: String, code: String) async throws {
        guard let store, let connection = connections.first(where: { $0.id == connectionID && $0.isEnabled && !$0.isDemo }),
              let owner = connection.owner, let secret = try CredentialVault.load(id: connectionID) else { throw CoreError.invalid("请先连接这张卡片所属的服务器") }
        let credentials = try JSONDecoder().decode(DeviceCredentials.self, from: secret)
        let id = try await cardClient.redeem(base: connection.baseURL, token: credentials.deviceToken, code: code)
        let info = try await cardClient.fetch(base: connection.baseURL, token: credentials.deviceToken, id: id)
        guard connections.contains(where: { $0.id == connectionID && $0.isEnabled && $0.bindingID == credentials.bindingID }) else { throw CoreError.invalid("服务器连接已移除或停用") }
        try store.acceptCard(info, owner: owner)
        try reload(); WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
    }

    private func syncWebCards(connection: ServerConnection, credentials: DeviceCredentials) async throws {
        guard let store, let owner = connection.owner else { return }
        let ids: [String]
        do { ids = try await cardClient.list(base: connection.baseURL, token: credentials.deviceToken) }
        catch DeviceClientError.rejected(404, _) { return }
        guard connections.contains(where: { $0.id == connection.id && $0.isEnabled && $0.bindingID == credentials.bindingID }) else { return }
        var changed = false
        for id in ids {
            do {
                let info = try await cardClient.fetch(base: connection.baseURL, token: credentials.deviceToken, id: id)
                guard connections.contains(where: { $0.id == connection.id && $0.isEnabled && $0.bindingID == credentials.bindingID }) else { return }
                if try store.acceptCard(info, owner: owner) { changed = true }
            } catch {
                let unavailable: Bool
                if case DeviceClientError.rejected(let status, _) = error { unavailable = status == 403 || status == 404 } else { unavailable = false }
                if try store.markCard(id, owner: owner, unavailable: unavailable, issue: unavailable ? "订阅已撤销或来源不可用，请重新导入。" : "暂未更新，保留上次设计；可恢复跟随Web后重试。") { changed = true }
            }
        }
        for card in try store.cards(owner: owner) where card.remote != nil && !ids.contains(card.remote!.id) {
            if try store.markCard(card.remote!.id, owner: owner, unavailable: true, issue: "订阅已撤销，请重新导入或移除本机卡片。") { changed = true }
        }
        try reload()
        if changed { WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind) }
    }

    func renameDevice(id: String, name: String) async {
        do {
            guard let store, let connection = connections.first(where: { $0.id == id && !$0.isDemo }),
                  !registering.contains(id) else { return }
            let name = try ServerConnection.normalizedDeviceName(name)
            if connection.bindingID != nil {
                guard let data = try CredentialVault.load(id: id) else { throw CoreError.invalid("设备凭证缺失，请重新添加服务器。") }
                let credentials = try JSONDecoder().decode(DeviceCredentials.self, from: data)
                guard credentials.bindingID == connection.bindingID, credentials.serverID == connection.serverID else {
                    throw DeviceClientError.invalidResponse
                }
                try await deviceClient.rename(baseURL: connection.baseURL, token: credentials.deviceToken, name: name)
            }
            guard var current = connections.first(where: { $0.id == id && $0.bindingID == connection.bindingID }) else { return }
            current.deviceName = name
            try store.saveConnection(current)
            try reload()
        } catch { self.error = VaoL10n.text("设备名称未保存：") + error.localizedDescription }
    }

    func setServerEnabled(_ connection: ServerConnection, enabled: Bool) async {
        do {
            if !connection.isDemo, connection.bindingID != nil {
                guard let data = try CredentialVault.load(id: connection.id) else { throw CoreError.invalid("设备凭证缺失，请重新添加服务器。") }
                let credentials = try JSONDecoder().decode(DeviceCredentials.self, from: data)
                try await deviceClient.setEnabled(baseURL: connection.baseURL, token: credentials.deviceToken, enabled: enabled)
            }
            var changed = connection; changed.isEnabled = enabled
            try updateServer(changed)
            if enabled { await syncServer(id: connection.id) }
        } catch { self.error = VaoL10n.text("服务器状态未改变：") + error.localizedDescription }
    }

    func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: notificationStatus = VaoL10n.text("已允许")
        case .provisional: notificationStatus = VaoL10n.text("安静通知")
        case .ephemeral: notificationStatus = VaoL10n.text("临时允许")
        case .denied: notificationStatus = VaoL10n.text("未允许")
        case .notDetermined: notificationStatus = VaoL10n.text("尚未请求")
        @unknown default: notificationStatus = VaoL10n.text("未知")
        }
    }

    func requestNotifications() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            UIApplication.shared.registerForRemoteNotifications()
            await refreshNotificationStatus()
        } catch { self.error = VaoL10n.text("无法请求通知权限，请前往系统设置检查。") }
    }

    func clearMessages(owner: String) {
        do { try store?.clearMessages(owner: owner); try reload(); WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind) }
        catch { self.error = String(describing: error) }
    }

}

import WidgetKit
import AppIntents
import SwiftUI
import VaoPushCore
import os

struct CardEntry: TimelineEntry {
    let date: Date
    let card: CardConfiguration?
    let snapshot: StateSnapshot?
    let mode: CardDisplayMode
    let error: String?
    var sourceName: String = VaoL10n.text("示例")
    var isDemo: Bool = true
    var owner: String = PrototypeData.owner
    var messages: [ArchivedMessage] = []
    var isPreview: Bool = false
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CardEntry {
        CardEntry(date: .now, card: .messageCard(name: VaoL10n.text("最新消息")), snapshot: nil, mode: .summary, error: nil, isDemo: false, isPreview: true)
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> CardEntry {
        if context.isPreview { return placeholder(in: context) }
        return load(configuration, family: context.family)
    }

    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<CardEntry> {
        // The token callback is synchronous. Retry its upload while WidgetKit awaits this timeline.
        async let registration: Void = registerPushToken(configuration)
        await refresh(configuration)
        await registration
        let entry = load(configuration, family: context.family)
        // Refresh at expiry to update the stale indicator; this is a request to iOS, not a deadline.
        let expiry = entry.snapshot.flatMap { snapshot -> Date? in
            guard let ttl = snapshot.state.validForSeconds,
                  let source = ProtocolRules.date(snapshot.state.sourceUpdatedAt) else { return nil }
            return source.addingTimeInterval(TimeInterval(ttl))
        }
        let refresh = max(expiry ?? .now.addingTimeInterval(900), .now.addingTimeInterval(60))
        return Timeline(entries: [entry], policy: .after(refresh))
    }

    private func registerPushToken(_ configuration: ConfigurationAppIntent) async {
        do {
            guard let selected = configuration.card else { return }
            let identity = try ScopedCardID.decode(selected.id)
            let store = try PrototypeStorage.open()
            guard let connection = try store.connections().first(where: {
                $0.owner == identity.owner && $0.isEnabled && !$0.isDemo && $0.bindingID != nil
            }),
                let tokenData = try CredentialVault.load(id: "installation-widget", shared: true),
                let widgetToken = String(data: tokenData, encoding: .utf8),
                let credential = try CredentialVault.load(id: connection.id, shared: true),
                let readToken = String(data: credential, encoding: .utf8) else { return }
            try await DeviceClient().register(baseURL: connection.baseURL, token: readToken,
                apns: nil, widget: widgetToken, environment: PushEnvironment.current)
        } catch {
            Logger(subsystem: "app.vaovao.push", category: "WidgetRegistration")
                .notice("Widget registration deferred until the next timeline or App sync.")
        }
    }

    private func refresh(_ configuration: ConfigurationAppIntent) async {
        do {
            guard let selected = configuration.card else { return }
            let identity = try ScopedCardID.decode(selected.id)
            let store = try PrototypeStorage.open()
            guard let connection = try store.connections().first(where: { $0.owner == identity.owner && $0.isEnabled && !$0.isDemo }),
                  let card = try store.card(id: identity.cardID, owner: identity.owner),
                  card.message == nil,
                  let previous = try store.snapshot(streamID: card.streamID, owner: identity.owner),
                  let secret = try CredentialVault.load(id: connection.id, shared: true),
                  let token = String(data: secret, encoding: .utf8) else { return }
            if let remote = card.remote {
                do {
                    let info = try await CardClient().fetch(base: connection.baseURL, token: token, id: remote.id)
                    guard try store.connections().contains(where: { $0.id == connection.id && $0.isEnabled && $0.bindingID == connection.bindingID }),
                          try store.card(id: card.id, owner: identity.owner) != nil else { return }
                    try store.acceptCard(info, owner: identity.owner)
                } catch DeviceClientError.rejected(let status, _) where status == 403 || status == 404 {
                    try store.markCard(remote.id, owner: identity.owner, unavailable: true, issue: VaoL10n.text("订阅已撤销或来源不可用。"))
                }
                return
            }
            let result = try await SnapshotClient().fetch(baseURL: connection.baseURL, dataID: previous.dataID, bearer: token)
            // Recheck the connection after the network await; a removed source must not be recreated.
            guard try store.connections().contains(where: { $0.id == connection.id && $0.isEnabled && $0.bindingID == connection.bindingID }) else { return }
            if case .snapshot(let snapshot, _) = result {
                guard snapshot.streamID == card.streamID else { return }
                try store.apply(snapshot, owner: identity.owner)
            }
        } catch { /* Keep the last validated content and its original source time. */ }
    }

    private func load(_ configuration: ConfigurationAppIntent, family: WidgetFamily) -> CardEntry {
        do {
            let store = try PrototypeStorage.open()
            guard let selected = configuration.card else {
                return CardEntry(date: .now, card: nil, snapshot: nil, mode: .summary, error: VaoL10n.text("请选择已保存的卡片"))
            }
            let identity = try ScopedCardID.decode(selected.id)
            guard let source = try store.sources().first(where: { $0.owner == identity.owner }), source.isEnabled else {
                return CardEntry(date: .now, card: nil, snapshot: nil, mode: .summary, error: VaoL10n.text("来源已停用或移除"))
            }
            guard let card = try store.card(id: identity.cardID, owner: identity.owner) else {
                return CardEntry(date: .now, card: nil, snapshot: nil, mode: .summary, error: VaoL10n.text("卡片已移除，请重新选择"))
            }
            if card.message != nil {
                return CardEntry(date: .now, card: card, snapshot: nil, mode: .summary, error: nil,
                    sourceName: source.name, isDemo: false, owner: identity.owner,
                    messages: try store.messages(owner: identity.owner))
            }
            let mode = try store.mode(cardID: card.id, family: String(family.rawValue), owner: identity.owner)
            Logger(subsystem: "app.vaovao.push", category: "WidgetTimeline")
                .notice("Loaded family \(family.rawValue) mode \(mode.rawValue, privacy: .public)")
            return CardEntry(date: .now, card: card,
                snapshot: try store.snapshot(streamID: card.streamID, owner: identity.owner),
                mode: mode, error: nil, sourceName: source.name, isDemo: source.isDemo, owner: identity.owner)
        } catch {
            return CardEntry(date: .now, card: nil, snapshot: nil, mode: .summary, error: VaoL10n.text("暂时无法读取共享数据"))
        }
    }
}

struct VaoPushWidgetEntryView: View {
    var entry: CardEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let card = entry.card, card.message != nil {
            MessageCardView(card: card, messages: entry.messages, sourceName: entry.sourceName,
                compact: family == .systemSmall || family == .systemMedium,
                rowLimit: family == .systemSmall ? 1 : family == .systemMedium ? 2 : 3, preview: entry.isPreview)
        } else if let card = entry.card, let snapshot = entry.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                PrototypeCardView(card: card, snapshot: snapshot, mode: entry.mode,
                    compact: family == .systemSmall || family == .systemMedium,
                    expanded: family == .systemLarge || family == .systemExtraLarge,
                    sourceName: entry.sourceName, isDemo: entry.isDemo,
                    fieldLimit: family == .systemSmall ? 2 : family == .systemMedium ? 4 : family == .systemLarge ? 12 : 20)
                if card.remote == nil, card.template != .chart, let key = card.seriesKey,
                   let series = card.selectedSeries(in: snapshot.state)[key], !series.points.isEmpty {
                    Button(intent: SetCardModeIntent(cardID: ScopedCardID.encode(owner: entry.owner, cardID: card.id), family: String(family.rawValue),
                        showChart: entry.mode != .chart)) {
                        Label(entry.mode == .chart ? VaoL10n.text("返回概览") : VaoL10n.text("查看图表"),
                              systemImage: entry.mode == .chart ? "list.bullet" : "chart.xyaxis.line")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(VaoTheme.accent)
                }
            }
            .id(entry.mode.rawValue)
            .transaction { $0.animation = nil }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "square.grid.2x2").foregroundStyle(VaoTheme.accent)
                Text(entry.error ?? VaoL10n.text("等待数据")).font(.headline)
                Text(VaoL10n.text("在 App 中保存卡片，再编辑此小组件。")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct VaoPushWidget: Widget {
    let kind = PrototypeStorage.widgetKind
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            VaoPushWidgetEntryView(entry: entry).containerBackground(
                entry.card?.theme == .dark ? Color(red: 30/255, green: 37/255, blue: 48/255) :
                    entry.card?.theme == .light ? Color.white : VaoTheme.surface, for: .widget)
        }
        .configurationDisplayName(VaoL10n.text("Vao Push 卡片"))
        .description(VaoL10n.text("显示最近消息，或选择从Web导入的数据卡片。"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .pushHandler(VaoWidgetPushHandler.self)
    }
}

struct VaoWidgetPushHandler: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let token = pushInfo.token.map { String(format: "%02x", $0) }.joined()
        do { try CredentialVault.save(Data(token.utf8), id: "installation-widget", shared: true) }
        catch {
            Logger(subsystem: "app.vaovao.push", category: "WidgetRegistration")
                .error("Widget push registration could not be saved securely.")
        }
        Task {
            guard let store = try? PrototypeStorage.open(), let connections = try? store.connections() else { return }
            await withTaskGroup(of: Void.self) { group in
                for connection in connections where connection.isEnabled && !connection.isDemo && connection.bindingID != nil {
                    group.addTask {
                        do {
                            guard let secret = try CredentialVault.load(id: connection.id, shared: true),
                                  let readToken = String(data: secret, encoding: .utf8) else { return }
                            try await DeviceClient().register(baseURL: connection.baseURL, token: readToken,
                                apns: nil, widget: token, environment: PushEnvironment.current)
                        } catch {
                            Logger(subsystem: "app.vaovao.push", category: "WidgetRegistration")
                                .notice("Widget registration will retry during its timeline or App sync.")
                        }
                    }
                }
            }
        }
    }
}

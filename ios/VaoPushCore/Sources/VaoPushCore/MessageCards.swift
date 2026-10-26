import Foundation

public enum MessageCardStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    case latest, summary, list
    public var id: String { rawValue }
    public var title: String {
        switch self { case .latest: VaoL10n.text("最新消息"); case .summary: VaoL10n.text("消息摘要"); case .list: VaoL10n.text("最近消息列表") }
    }
    public var detail: String {
        switch self {
        case .latest: VaoL10n.text("突出显示最近一条消息的标题和正文")
        case .summary: VaoL10n.text("紧凑显示标题、简短内容和接收时间")
        case .list: VaoL10n.text("按时间排列最近几条消息")
        }
    }
    public var symbol: String {
        switch self { case .latest: "text.bubble"; case .summary: "text.alignleft"; case .list: "list.bullet.rectangle" }
    }
}

public struct MessageCardOptions: Codable, Equatable, Sendable {
    public static let streamID = "local-recent-messages"
    public var style: MessageCardStyle
    public var showBody: Bool
    public var showTime: Bool
    public init(style: MessageCardStyle = .latest, showBody: Bool = true, showTime: Bool = true) {
        self.style = style; self.showBody = showBody; self.showTime = showTime
    }

    /// Delivery and cursor sync may insert older messages after newer notifications.
    public func recentMessages(in messages: [ArchivedMessage], limit: Int? = nil) -> [ArchivedMessage] {
        let maximum = min(style == .list ? 3 : 1, max(0, limit ?? 3))
        return Array(messages.sorted {
            let first = ProtocolRules.date($0.receivedAt) ?? .distantPast
            let second = ProtocolRules.date($1.receivedAt) ?? .distantPast
            return first == second ? $0.id > $1.id : first > second
        }.prefix(maximum))
    }
}

extension CardConfiguration {
    public static func messageCard(name: String, style: MessageCardStyle = .latest) -> CardConfiguration {
        var card = CardConfiguration(name: name, streamID: MessageCardOptions.streamID, fields: [])
        card.message = MessageCardOptions(style: style)
        return card
    }
}

#if os(iOS)
import SwiftUI

public struct MessageCardView: View {
    let card: CardConfiguration
    let messages: [ArchivedMessage]
    let sourceName: String
    let compact: Bool
    let rowLimit: Int
    let preview: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(card: CardConfiguration, messages: [ArchivedMessage], sourceName: String,
                compact: Bool = false, rowLimit: Int = 3, preview: Bool = false) {
        self.card = card; self.messages = messages; self.sourceName = sourceName
        self.compact = compact; self.rowLimit = rowLimit; self.preview = preview
    }
    private var options: MessageCardOptions { card.message ?? MessageCardOptions() }
    private var recent: [ArchivedMessage] { options.recentMessages(in: messages, limit: rowLimit) }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack {
                Text(card.name).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: options.style.symbol).foregroundStyle(VaoTheme.accent).accessibilityHidden(true)
            }
            if preview {
                placeholder
            } else if recent.isEmpty {
                Text(VaoL10n.text("等待新消息")).font(.subheadline.weight(.medium))
                Text(VaoL10n.text("收到这个来源的消息后，会显示在这里。"))
                    .font(.caption).foregroundStyle(.secondary)
            } else if options.style == .list {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, message in
                    if index > 0 { Divider() }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(message.title.isEmpty ? VaoL10n.text("新消息") : message.title)
                                .font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 6)
                            if options.showTime, let date = ProtocolRules.date(message.receivedAt) {
                                Text(date, style: .time).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        if options.showBody { Text(message.body).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            } else if let message = recent.first {
                if options.style == .summary {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "bell.fill").foregroundStyle(VaoTheme.accent).padding(.top, 2)
                        messageText(message)
                    }
                } else { messageText(message) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(preview ? VaoL10n.text("消息来源") : sourceName).lineLimit(1)
                Spacer(minLength: 4)
                if preview, options.showTime { Text(VaoL10n.text("时间")) }
                else if options.style != .list, options.showTime,
                        let message = recent.first, let date = ProtocolRules.date(message.receivedAt) {
                    Text(date, style: .time)
                }
            }.font(.caption2).foregroundStyle(.secondary)
        }
        .environment(\.colorScheme, card.theme == .dark ? .dark : card.theme == .light ? .light : colorScheme)
        .privacySensitive()
        .accessibilityElement(children: .contain)
    }

    private func messageText(_ message: ArchivedMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.title.isEmpty ? VaoL10n.text("新消息") : message.title)
                .font(options.style == .latest && !compact ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                .lineLimit(2)
            if options.showBody {
                Text(message.body).font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary).lineLimit(compact || options.style == .summary ? 2 : 4)
            }
        }
    }
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            if options.style == .list {
                ForEach(0..<min(3, rowLimit), id: \.self) { index in
                    if index > 0 { Divider() }
                    HStack { Text(VaoL10n.text("消息标题")).font(.subheadline); Spacer(); Text(VaoL10n.text("时间")).font(.caption2) }
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    if options.style == .summary { Image(systemName: "bell.fill").foregroundStyle(VaoTheme.accent) }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(VaoL10n.text("消息标题")).font(options.style == .latest ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                        if options.showBody { Text(VaoL10n.text("消息内容会显示在这里")).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }.foregroundStyle(.secondary)
    }
}
#endif

#if os(iOS)
import SwiftUI

struct PublishedCardView: View {
    let remote: RemoteCard
    let state: StateSnapshot
    let rowLimit: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if remote.available {
                CardNodeView(node: remote.design.layout, state: state.state, item: nil, adjustments: remote.adjustments.nodes, rowLimit: rowLimit)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text(state.isExpired(at: .now) ? VaoL10n.text("已过期 ·") : VaoL10n.text("更新"))
                    if let date = ProtocolRules.date(state.state.sourceUpdatedAt) { Text(date, style: .time) }
                }.font(.system(size: 10)).foregroundStyle(state.isExpired(at: .now) ? Color.orange : Color.secondary)
                if let issue = remote.issue { Text(VaoL10n.text(issue)).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
            } else {
                Label(VaoL10n.text("卡片订阅不可用"), systemImage: "link.badge.plus").font(.headline)
                Text(VaoL10n.text(remote.issue ?? "请在App检查订阅或重新导入。")).font(.caption).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .contain)
    }
}
private struct CardNodeView: View {
    let node: CardNode
    let state: WidgetState
    let item: DataItem?
    let adjustments: [String: NodeAdjustment]
    let rowLimit: Int
    private var adjustment: NodeAdjustment { adjustments[node.id] ?? NodeAdjustment() }
    private var alignment: Alignment { node.alignment == "trailing" ? .trailing : node.alignment == "center" ? .center : .leading }
    private var horizontal: HorizontalAlignment { node.alignment == "trailing" ? .trailing : node.alignment == "center" ? .center : .leading }
    private var key: String { node.bind?.split(separator: ".").last.map(String.init) ?? "" }
    private var field: DataField? { (item?.fields ?? state.fields ?? [:])[key] }
    private func color(_ value: String?) -> Color {
        switch value {
        case "accent": return VaoTheme.accent
        case "secondary": return .secondary
        case "primary", nil: return .primary
        default:
            guard let value, value.hasPrefix("#"), let hex = UInt32(value.dropFirst(), radix: 16) else { return .primary }
            return Color(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255)
        }
    }
    private var signedColor: Color {
        guard case .text(let raw) = field?.value, let value = try? ProtocolRules.decimal(raw) else { return .secondary }
        return color(value < 0 ? "#F6465D" : "#16A667")
    }
    private var value: String {
        if let text = node.text { return text }
        var display = field
        if node.format == "percent" { display?.type = .percent }
        if node.format == "decimal" { display?.type = .decimal }
        return FieldFormatter.display(display, decimals: adjustment.decimals ?? node.decimals, showUnit: adjustment.showUnits ?? true)
    }
    var body: some View {
        if adjustment.hidden != true {
            content.font(.system(size: CGFloat(adjustment.fontSize ?? node.fontSize ?? (node.type == "text" ? 13 : 16)), weight: node.weight == "bold" ? .bold : node.weight == "semibold" ? .semibold : node.weight == "medium" ? .medium : .regular))
                .foregroundStyle(node.colorRule == "signed" && node.type != "badge" ? signedColor : color(node.color))
                .padding(CGFloat(node.padding ?? 0))
                .background(node.background.map(color) ?? .clear, in: RoundedRectangle(cornerRadius: CGFloat(node.radius ?? 0)))
                .fixedSize(horizontal: node.flex == 0, vertical: false)
                .frame(maxWidth: node.flex == 0 ? nil : .infinity, alignment: alignment).layoutPriority(Double(node.flex ?? 1))
        }
    }
    private func child(_ child: CardNode, item: DataItem? = nil) -> CardNodeView { CardNodeView(node: child, state: state, item: item ?? self.item, adjustments: adjustments, rowLimit: rowLimit) }
    private var content: AnyView {
        switch node.type {
        case "row": return AnyView(HStack(alignment: .center, spacing: CGFloat(node.spacing ?? 8)) { ForEach(node.children ?? []) { child($0) } })
        case "column": return AnyView(VStack(alignment: horizontal, spacing: CGFloat(node.spacing ?? 5)) { ForEach(node.children ?? []) { child($0) } })
        case "grid":
            let children = node.children ?? [], columns = max(1, min(node.columns ?? 2, 4))
            let rows = (children.count + columns - 1) / columns
            return AnyView(VStack(spacing: CGFloat(node.spacing ?? 8)) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: CGFloat(node.spacing ?? 8)) {
                        ForEach(Array(children.dropFirst(row * columns).prefix(columns))) { child($0) }
                        if children.count - row * columns < columns {
                            ForEach(0..<(columns - (children.count - row * columns)), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                        }
                    }
                }
            })
        case "list":
            guard let row = node.row?.node else { return AnyView(Text(VaoL10n.text("列表配置不可用"))) }
            let items = Array((state.items ?? []).prefix(min(node.limit ?? 3, rowLimit)))
            return AnyView(VStack(alignment: .leading, spacing: CGFloat(node.spacing ?? 8)) {
                if items.isEmpty { Text(VaoL10n.text("暂无列表数据")).foregroundStyle(.secondary) }
                ForEach(Array(items.enumerated()), id: \.element.itemID) { index, item in child(row, item: item); if index < items.count - 1 { Divider() } }
            })
        case "divider": return AnyView(Divider())
        case "spacer": return AnyView(Spacer(minLength: CGFloat(node.spacing ?? 4)))
        case "chart":
            if let series = (item?.series ?? state.series ?? [:])[key] { return AnyView(PrototypeSeriesView(series: series).frame(minHeight: 40, maxHeight: 140)) }
            return AnyView(Text(VaoL10n.text("暂无历史数据")).foregroundStyle(.secondary))
        default:
            let label = adjustment.label ?? node.label
            return AnyView(VStack(alignment: horizontal, spacing: 2) {
                if let label, !label.isEmpty { Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                if node.type == "badge" {
                    Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 7).padding(.vertical, 5)
                        .foregroundStyle(node.colorRule == "signed" ? Color.white : color(node.color))
                        .background(node.colorRule == "signed" ? signedColor : VaoTheme.soft, in: RoundedRectangle(cornerRadius: 5))
                } else { Text(value).monospacedDigit().lineLimit(2).minimumScaleFactor(0.6) }
            })
        }
    }
}
#endif

#if os(iOS)
import SwiftUI

struct PublishedCardView: View {
    let remote: RemoteCard
    let state: StateSnapshot
    let rowLimit: Int
    let family: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if remote.available {
                CardNodeView(node: remote.design.layout(for: family), state: state.state, item: nil, adjustments: remote.adjustments.nodes(for: family, design: remote.design), rowLimit: rowLimit)
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
    @Environment(\.colorScheme) private var scheme
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
        case "surface": return scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.05)
        case "primary", nil: return .primary
        default:
            guard let value, value.hasPrefix("#"), let hex = UInt32(value.dropFirst(), radix: 16) else { return .primary }
            return Color(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255)
        }
    }
    private var signedColor: Color {
        if node.type == "sparkline" {
            guard let series = node.series(in: state, item: item), let sign = CardTrend.changeSign(series) else { return .secondary }
            return color(sign < 0 ? "#F6465D" : "#16A667")
        }
        guard case .text(let raw) = field?.value, let value = try? ProtocolRules.decimal(raw) else { return .secondary }
        return color(value < 0 ? "#F6465D" : "#16A667")
    }
    private var mapped: CardStateStyle? { node.stateStyle(field: field) }
    private var foreground: Color {
        if let mapped { return color(mapped.colors?.value(dark: scheme == .dark) ?? mapped.color ?? "secondary") }
        if node.colorRule == "signed" { return node.type == "badge" ? .white : signedColor }
        return color(node.colors?.value(dark: scheme == .dark) ?? node.color)
    }
    private var background: Color {
        if let mapped { return color(mapped.backgroundColors?.value(dark: scheme == .dark) ?? mapped.background ?? "surface") }
        if node.type == "badge", node.colorRule == "signed" { return signedColor }
        if let bg = node.backgroundColors?.value(dark: scheme == .dark) ?? node.background { return color(bg) }
        return node.type == "badge" ? VaoTheme.soft : .clear
    }
    private var value: String {
        if let text = mapped?.text { return text }
        if let text = node.text { return text }
        var display = field
        if node.format == "percent" { display?.type = .percent }
        if node.format == "decimal" { display?.type = .decimal }
        let formatted = FieldFormatter.display(display, decimals: adjustment.decimals ?? node.decimals, showUnit: adjustment.showUnits ?? true)
        guard CardNode.nonempty(field?.value) else { return formatted }
        return (node.prefix ?? "") + formatted + (node.suffix ?? "")
    }
    var body: some View {
        if node.visible(in: state, item: item, adjustments: adjustments) {
            content.font(.system(size: CGFloat(adjustment.fontSize ?? node.fontSize ?? (node.type == "text" ? 13 : 16)), weight: node.weight == "bold" ? .bold : node.weight == "semibold" ? .semibold : node.weight == "medium" ? .medium : .regular))
                .foregroundStyle(foreground)
                .padding(CGFloat(node.padding ?? 0))
                .background(node.type == "badge" ? .clear : background, in: RoundedRectangle(cornerRadius: CGFloat(node.radius ?? 0)))
                .overlay { if let border = node.border { RoundedRectangle(cornerRadius: CGFloat(node.radius ?? 0)).strokeBorder(color(border.colors?.value(dark: scheme == .dark) ?? border.color ?? "secondary"), lineWidth: CGFloat(border.width)) } }
                .fixedSize(horizontal: node.flex == 0 || node.type == "badge", vertical: false)
                .frame(maxWidth: node.flex == 0 || node.type == "badge" ? nil : .infinity, alignment: alignment).layoutPriority(Double(node.flex ?? 1))
        }
    }
    private func child(_ child: CardNode, item: DataItem? = nil) -> CardNodeView { CardNodeView(node: child, state: state, item: item ?? self.item, adjustments: adjustments, rowLimit: rowLimit) }
    private var content: AnyView {
        switch node.type {
        case "row": return AnyView(HStack(alignment: .center, spacing: CGFloat(node.spacing ?? 8)) { ForEach(node.visibleChildren(in: state, item: item, adjustments: adjustments)) { child($0) } })
        case "column": return AnyView(VStack(alignment: horizontal, spacing: CGFloat(node.spacing ?? 5)) { ForEach(node.visibleChildren(in: state, item: item, adjustments: adjustments)) { child($0) } })
        case "grid":
            let children = node.visibleChildren(in: state, item: item, adjustments: adjustments), columns = max(1, min(node.columns ?? 2, 4))
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
            let items = Array(node.visibleItems(in: state, adjustments: adjustments).prefix(min(node.limit ?? 3, rowLimit)))
            return AnyView(VStack(alignment: .leading, spacing: CGFloat(node.spacing ?? 8)) {
                if items.isEmpty { Text(VaoL10n.text("暂无列表数据")).foregroundStyle(.secondary) }
                ForEach(Array(items.enumerated()), id: \.element.itemID) { index, item in child(row, item: item); if index < items.count - 1 { Divider() } }
            })
        case "divider": return AnyView(Divider())
        case "spacer": return AnyView(Spacer(minLength: CGFloat(node.spacing ?? 4)))
        case "icon": return AnyView(CardSymbolView(node: node).frame(width: CGFloat(node.iconSize ?? 20), height: CGFloat(node.iconSize ?? 20)))
        case "sparkline":
            if let series = node.series(in: state, item: item) { return AnyView(CardSparklineView(series: series, node: node, tint: foreground).frame(height: CGFloat(node.height ?? 32))) }
            return AnyView(EmptyView())
        case "chart":
            if let series = (item?.series ?? state.series ?? [:])[key] { return AnyView(PrototypeSeriesView(series: series).frame(minHeight: 40, maxHeight: 140)) }
            return AnyView(Text(VaoL10n.text("暂无历史数据")).foregroundStyle(.secondary))
        default:
            let label = adjustment.label ?? node.label
            return AnyView(VStack(alignment: horizontal, spacing: 2) {
                if let label, !label.isEmpty { Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                if node.type == "badge" {
                    Text(value).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).padding(.horizontal, 7).padding(.vertical, 5)
                        .foregroundStyle(foreground)
                        .background(background, in: RoundedRectangle(cornerRadius: CGFloat(node.radius ?? 5)))
                } else { Text(value).monospacedDigit().lineLimit(2).minimumScaleFactor(0.6) }
            })
        }
    }
}
private struct CardSymbolView: View {
    let node: CardNode
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: validSymbol).resizable().scaledToFit() }
        }.accessibilityLabel(node.label ?? "Icon")
        .task(id: node.imageURL) {
            guard let url = node.imageURL else { return }
            image = CardIconCache.cached(url)
            if image == nil { await CardIconCache.shared.load(url); image = CardIconCache.cached(url) }
        }
    }
    private var validSymbol: String {
        let name = (node.symbol ?? "questionmark.square").replacingOccurrences(of: "sf:", with: "")
        return UIImage(systemName: name) == nil ? "questionmark.square" : name
    }
}
private struct CardSparklineView: View {
    let series: DataSeries
    let node: CardNode
    let tint: Color
    var body: some View {
        let trend = CardTrend(series: series, gapSeconds: node.gapSeconds, includeZero: node.chartStyle == "bar")
        Canvas { context, size in
            let h = max(1, size.height - 4), w = max(1, size.width - 4)
            for segment in trend.segments {
                if node.chartStyle == "bar" {
                    let width = min(12, w / CGFloat(max(1, series.points.count)) * 0.65)
                    for p in segment {
                        let y = CGFloat(p.y)*h+2, base = CGFloat(trend.baseline)*h+2
                        let rect = CGRect(x: CGFloat(p.x)*w+2-width/2, y: min(y,base), width: width, height: max(1,abs(base-y)))
                        context.fill(Path(rect), with: .color(node.colorRule == "signed" ? (p.positive ? .green : .red) : tint))
                    }
                } else {
                    var path = Path()
                    for (i,p) in segment.enumerated() { let pt = CGPoint(x: CGFloat(p.x)*w+2, y: CGFloat(p.y)*h+2); if i==0 {path.move(to:pt)} else {path.addLine(to:pt)} }
                    context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    if segment.count == 1, let p = segment.first { context.fill(Path(ellipseIn: CGRect(x: CGFloat(p.x)*w, y: CGFloat(p.y)*h, width: 4, height: 4)), with: .color(tint)) }
                }
            }
        }.clipped().accessibilityLabel((series.label ?? node.label ?? "Trend") + ": " + String(series.points.count))
    }
}
#endif

#if os(iOS)
import Foundation
import SwiftUI

public enum VaoTheme {
    public static let brand = Color(red: 22/255, green: 119/255, blue: 242/255)
    public static var background: Color { adaptive(0xF7F8FA, 0x141820) }
    public static var surface: Color { adaptive(0xFFFFFF, 0x1E2530) }
    public static var line: Color { adaptive(0xE5E8EE, 0x303846) }
    public static var soft: Color { adaptive(0xEAF3FF, 0x213650) }
    public static var text: Color { adaptive(0x1B2434, 0xE6EBF5) }
    public static var secondary: Color { adaptive(0x657184, 0xA6AFBF) }
    public static var accent: Color { adaptive(0x1677F2, 0x8FBEFF) }
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255)/255, green: CGFloat((value >> 8) & 255)/255,
                           blue: CGFloat(value & 255)/255, alpha: 1)
        })
    }
}

/// Shared container registered for the app and both extensions.
public enum PrototypeStorage {
    public static let groupID = "group.app.vaovao.push"
    public static let widgetKind = "VaoPushWidget"

    public static func open() throws -> SharedStore {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw CoreError.invalid("共享容器不可用，请检查 App Group")
        }
        let directory = container.appendingPathComponent("Library/Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return try SharedStore(url: directory.appendingPathComponent("vao-push.sqlite"))
    }
}

public struct PrototypeCardView: View {
    let card: CardConfiguration
    let snapshot: StateSnapshot
    let mode: CardDisplayMode
    let compact: Bool
    let expanded: Bool
    let sourceName: String
    let isDemo: Bool
    let fieldLimit: Int?
    @Environment(\.colorScheme) private var colorScheme

    public init(card: CardConfiguration, snapshot: StateSnapshot, mode: CardDisplayMode = .summary,
                compact: Bool = false, expanded: Bool = false, sourceName: String = VaoL10n.text("示例"), isDemo: Bool = true, fieldLimit: Int? = nil) {
        self.card = card; self.snapshot = snapshot; self.mode = mode
        self.compact = compact; self.expanded = expanded
        self.sourceName = sourceName; self.isDemo = isDemo; self.fieldLimit = fieldLimit
    }

    public var body: some View {
        if let remote = card.remote {
            PublishedCardView(remote: remote, state: snapshot, rowLimit: fieldLimit == 2 ? 1 : compact ? 3 : expanded ? 12 : 6)
                .environment(\.colorScheme, card.theme == .dark ? .dark : card.theme == .light ? .light : colorScheme)
        } else {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack {
                Text(card.name).font(.headline).lineLimit(1)
                Spacer(minLength: 2)
                Text(isDemo ? VaoL10n.text("示例") : sourceName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if mode == .chart || card.template == .chart {
                if let key = card.seriesKey, let series = card.selectedSeries(in: snapshot.state)[key], !series.points.isEmpty {
                    Text(series.label ?? VaoL10n.text("历史数据")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    PrototypeSeriesView(series: series)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .frame(minHeight: compact ? 38 : 60)
                } else { Text(VaoL10n.text("暂无历史数据")).foregroundStyle(.secondary) }
            } else {
                let fields = Array(card.fields.filter(\.visible).prefix(fieldLimit ?? (compact ? 2 : expanded ? 12 : 5)))
                ForEach(Array(fields.enumerated()), id: \.element.id) { index, binding in
                    let field = card.selectedFields(in: snapshot.state)[binding.key]
                    if card.template == .metric && index == 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(FieldFormatter.label(for: binding, field: field)).font(.caption2).foregroundStyle(.secondary)
                            Text(FieldFormatter.display(field, decimals: binding.decimals, showUnit: card.showUnits ?? true))
                                .font(compact ? .title3.bold() : .title2.bold()).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.55)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(FieldFormatter.label(for: binding, field: field))
                                .foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(FieldFormatter.display(field, decimals: binding.decimals, showUnit: card.showUnits ?? true))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        }.font(compact ? .caption : .subheadline)
                    }
                }
                Spacer(minLength: 0)
            }
            Group {
                if isDemo {
                    Text(VaoL10n.text("示例数值 · 非实时数据"))
                } else {
                    HStack(spacing: 4) {
                        Text(snapshot.isExpired(at: .now) ? VaoL10n.text("已过期 · 来源") : VaoL10n.text("来源"))
                        if let date = ProtocolRules.date(snapshot.state.sourceUpdatedAt) { Text(date, style: .time) }
                    }
                }
            }.font(.caption2).foregroundStyle(!isDemo && snapshot.isExpired(at: .now) ? Color.orange : Color.secondary)
        }
        .environment(\.colorScheme, card.theme == .dark ? .dark : card.theme == .light ? .light : colorScheme)
        .accessibilityElement(children: .contain)
        }
    }
}

struct PrototypeSeriesView: View {
    let series: DataSeries
    var body: some View {
        Canvas { context, size in
            let samples = series.points.compactMap { point -> (Date, Double, Double, Double, Double)? in
                guard let time = ProtocolRules.date(point.t) else { return nil }
                if series.type == .ohlc, let o = Double(point.o ?? ""), let h = Double(point.h ?? ""),
                   let l = Double(point.l ?? ""), let c = Double(point.c ?? "") { return (time, o, h, l, c) }
                guard let value = Double(point.value ?? "") else { return nil }
                return (time, value, value, value, value)
            }
            guard let first = samples.first, let last = samples.last,
                  let low = samples.map({ $0.3 }).min(), let high = samples.map({ $0.2 }).max() else { return }
            let span = max(high - low, abs(high) * 0.001, 0.001)
            let duration = max(last.0.timeIntervalSince(first.0), 1)
            let slot = size.width / CGFloat(max(samples.count, 1))
            let inset = max(slot / 2, 3)
            func x(_ time: Date) -> CGFloat {
                if samples.count == 1 { return size.width / 2 }
                return inset + CGFloat(time.timeIntervalSince(first.0) / duration) * max(size.width - inset * 2, 1)
            }
            func y(_ value: Double) -> CGFloat { 3 + CGFloat((high - value) / span) * max(size.height - 6, 1) }
            if series.type == .ohlc {
                for sample in samples {
                    let color: Color = sample.4 >= sample.1 ? .teal : .orange
                    let center = x(sample.0)
                    var wick = Path()
                    wick.move(to: CGPoint(x: center, y: y(sample.2)))
                    wick.addLine(to: CGPoint(x: center, y: y(sample.3)))
                    context.stroke(wick, with: .color(color), lineWidth: 1)
                    let width = max(min(slot * 0.55, 18), 2)
                    let rect = CGRect(x: center - width / 2, y: min(y(sample.1), y(sample.4)),
                                      width: width, height: max(abs(y(sample.1) - y(sample.4)), 1))
                    context.fill(Path(rect), with: .color(color))
                }
            } else {
                var path = Path()
                for (index, sample) in samples.enumerated() {
                    let point = CGPoint(x: x(sample.0), y: y(sample.4))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(VaoTheme.accent), lineWidth: 2)
            }
        }
        .accessibilityLabel(series.type == .ohlc ? VaoL10n.text("发送方提供的 OHLC 历史图表") : VaoL10n.text("发送方提供的历史折线图"))
    }
}
#endif

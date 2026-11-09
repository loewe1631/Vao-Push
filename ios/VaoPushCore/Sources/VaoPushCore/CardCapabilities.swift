import Foundation

public struct CardFallback: Codable, Equatable, Sendable {
    public var layout: CardNode
    public var layouts: [String: CardNode]?
}
public struct CardColorPair: Codable, Equatable, Sendable {
    public var light: String
    public var dark: String
    public func value(dark: Bool) -> String { dark ? self.dark : light }
}
public struct CardStateStyle: Codable, Equatable, Sendable {
    public var text: String? = nil
    public var color: String? = nil
    public var colors: CardColorPair? = nil
    public var background: String? = nil
    public var backgroundColors: CardColorPair? = nil
    enum CodingKeys: String, CodingKey { case text, color, colors, background; case backgroundColors = "background_colors" }
}
public struct CardBorder: Codable, Equatable, Sendable {
    public var color: String?
    public var colors: CardColorPair?
    public var width: Int
}
extension CardDesign {
    static func flatten(_ n: CardNode) -> [CardNode] { [n] + (n.children ?? []).flatMap(flatten) + (n.row.map { flatten($0.node) } ?? []) }
    public func projected(schema: Int) -> CardDesign {
        var d = self
        if schema < 3, d.schemaVersion == 3, let fallback { d.schemaVersion = 2; d.layout = fallback.layout; d.layouts = fallback.layouts; d.fallback = nil }
        if schema < 2 { d.schemaVersion = 1; d.layouts = nil }
        return d
    }
    func representsSamePublication(as other: CardDesign) -> Bool {
        self == other || (schemaVersion > other.schemaVersion && projected(schema: other.schemaVersion) == other) || (other.schemaVersion > schemaVersion && other.projected(schema: schemaVersion) == self)
    }
    func validateV3() throws {
        func require(_ valid: Bool) throws { if !valid { throw CoreError.invalid("卡片新能力参数无效") } }
        try require(fallback != nil && (try JSONEncoder().encode(self).count) <= 65536)
        try projected(schema: 2).validate()
        var base = self; base.schemaVersion = 2; base.fallback = nil; base.layout = layout.stripped
        base.layouts = layouts?.mapValues { $0.stripped }; try base.validate()
        func color(_ s: String?) -> Bool { s == nil || ["", "surface", "primary", "secondary", "accent"].contains(s!) || s!.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil }
        func pair(_ p: CardColorPair?) -> Bool { p == nil || (!p!.light.isEmpty && !p!.dark.isEmpty && color(p!.light) && color(p!.dark)) }
        func style(_ s: CardStateStyle) -> Bool { (s.text?.utf8.count ?? 0) <= 120 && color(s.color) && pair(s.colors) && color(s.background) && pair(s.backgroundColors) }
        for tree in [layout] + Array((layouts ?? [:]).values) {
            try require(try JSONEncoder().encode(tree).count <= 24576)
            for n in Self.flatten(tree) {
                try require(color(n.color) && color(n.background) && pair(n.colors) && pair(n.backgroundColors))
                if let v = n.visibleWhen { try require(v.range(of: "^fields\\.[A-Za-z][A-Za-z0-9_]{0,63}$", options: .regularExpression) != nil) }
                try require((n.states?.count ?? 0) <= 16 && ((n.states == nil && n.unknownState == nil) || n.type == "badge"))
                for (key, s) in n.states ?? [:] { try require(!key.isEmpty && key.utf8.count <= 120 && style(s)) }
                if let s = n.unknownState { try require(style(s)) }
                if let b = n.border { try require((1...3).contains(b.width) && color(b.color) && pair(b.colors)) }
                try require((n.prefix?.utf8.count ?? 0) <= 32 && (n.suffix?.utf8.count ?? 0) <= 32 && ((n.prefix == nil && n.suffix == nil) || ["number", "badge"].contains(n.type)))
                if n.type == "icon" {
                    try require(n.bind == nil && (n.symbol != nil || n.imageURL != nil))
                    if let s = n.symbol { try require(s.replacingOccurrences(of: "sf:", with: "").range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$", options: .regularExpression) != nil) }
                    if let u = n.imageURL { try require(CardIconPolicy.validURL(u)) }
                    try require(n.iconSize == nil || (10...48).contains(n.iconSize!))
                } else { try require(n.symbol == nil && n.imageURL == nil && n.iconSize == nil) }
                if n.type == "sparkline" {
                    try require(n.bind?.hasPrefix("series.") == true && ["", "line", "bar"].contains(n.chartStyle ?? "") && (n.height == nil || (16...80).contains(n.height!)) && (n.minPoints == nil || (2...60).contains(n.minPoints!)) && (0...604800).contains(n.gapSeconds ?? 0))
                } else { try require(n.chartStyle == nil && n.height == nil && n.minPoints == nil && n.gapSeconds == nil) }
            }
        }
    }
}
extension CardNode {
    var stripped: CardNode {
        var n = self
        n.visibleWhen = nil; n.hideIfEmpty = nil; n.colors = nil; n.backgroundColors = nil; n.states = nil; n.unknownState = nil; n.border = nil
        n.prefix = nil; n.suffix = nil; n.symbol = nil; n.imageURL = nil; n.iconSize = nil; n.chartStyle = nil; n.height = nil; n.minPoints = nil; n.gapSeconds = nil
        if n.color == "surface" { n.color = "secondary" }; if n.background == "surface" { n.background = "secondary" }
        if n.type == "icon" { n.type = "text" }; if n.type == "sparkline" { n.type = "chart" }
        n.children = children?.map { $0.stripped }; n.row = row.map { .value($0.node.stripped) }; return n
    }
    var hasV3: Bool { self != stripped }
    public func field(in state: WidgetState, item: DataItem?) -> DataField? { (item?.fields ?? state.fields ?? [:])[bind?.split(separator: ".").last.map(String.init) ?? ""] }
    public func series(in state: WidgetState, item: DataItem?) -> DataSeries? { (item?.series ?? state.series ?? [:])[bind?.split(separator: ".").last.map(String.init) ?? ""] }
    public static func nonempty(_ value: FieldValue?) -> Bool {
        switch value { case .text(let s): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .boolean: return true
        default: return false }
    }
    public func visible(in state: WidgetState, item: DataItem?, adjustments: [String: NodeAdjustment] = [:]) -> Bool {
        if adjustments[id]?.hidden == true { return false }
        if let condition = visibleWhen, !Self.nonempty((item?.fields ?? state.fields ?? [:])[String(condition.dropFirst(7))]?.value) { return false }
        if hideIfEmpty == true {
            if let text { if !Self.nonempty(.text(text)) { return false } }
            else if bind?.hasPrefix("fields.") == true && !Self.nonempty(field(in: state, item: item)?.value) { return false }
        }
        if type == "sparkline" { return (series(in: state, item: item)?.points.count ?? 0) >= max(2, minPoints ?? 2) }
        if let children { return children.contains { !["divider", "spacer"].contains($0.type) && $0.visible(in: state, item: item, adjustments: adjustments) } }
        if type == "list", hideIfEmpty == true { return !(visibleItems(in: state, adjustments: adjustments).isEmpty) }
        return true
    }
    public func visibleChildren(in state: WidgetState, item: DataItem?, adjustments: [String: NodeAdjustment]) -> [CardNode] {
        let active = (children ?? []).filter { $0.visible(in: state, item: item, adjustments: adjustments) }
        var result: [CardNode] = []
        for n in active {
            if ["divider", "spacer"].contains(n.type), result.isEmpty || result.last.map({ ["divider", "spacer"].contains($0.type) }) == true { continue }
            result.append(n)
        }
        while result.last.map({ ["divider", "spacer"].contains($0.type) }) == true { result.removeLast() }
        return result
    }
    public func visibleItems(in state: WidgetState, adjustments: [String: NodeAdjustment]) -> [DataItem] {
        guard let row else { return [] }; return (state.items ?? []).filter { row.node.visible(in: state, item: $0, adjustments: adjustments) }
    }
    public func stateStyle(field: DataField?) -> CardStateStyle? {
        guard states != nil || unknownState != nil else { return nil }
        let key: String
        switch field?.value { case .text(let s): key = s; case .boolean(let b): key = b ? "true" : "false"; default: key = "" }
        return states?[key] ?? unknownState ?? CardStateStyle(color: "secondary", background: "surface")
    }
}

public struct CardTrend: Sendable {
    public static func changeSign(_ series: DataSeries) -> Int? {
        guard series.points.count >= 2, let first = series.points.first, let last = series.points.last,
              let firstRaw = first.value ?? first.c, let lastRaw = last.value ?? last.c,
              let a = try? ProtocolRules.decimal(firstRaw), let b = try? ProtocolRules.decimal(lastRaw) else { return nil }
        return b < a ? -1 : 1
    }
    public struct Point: Sendable { public var x: Double; public var y: Double; public var positive: Bool }
    public var segments: [[Point]]
    public var baseline: Double
    public init(series: DataSeries, gapSeconds: Int?, includeZero: Bool = false) {
        let values = series.points.compactMap { p -> (Date, Decimal)? in
            guard let date = ProtocolRules.date(p.t), let raw = p.value ?? p.c, let number = try? ProtocolRules.decimal(raw) else { return nil }
            return (date, number)
        }
        guard let first = values.first, let last = values.last else { segments = []; baseline = 1; return }
        let minimum = values.map(\.1).min() ?? 0, maximum = values.map(\.1).max() ?? 1
        let low = includeZero ? min(0, minimum) : minimum, high = includeZero ? max(0, maximum) : maximum
        let span = high == low ? Decimal(1) : high - low
        let duration = max(last.0.timeIntervalSince(first.0), 1)
        func y(_ value: Decimal) -> Double { high == low ? 0.5 : NSDecimalNumber(decimal: (high - value) / span).doubleValue }
        baseline = y(0)
        var groups: [[Point]] = [[]], previous = first.0
        let gap = Double((gapSeconds ?? 0) > 0 ? gapSeconds! : series.intervalSeconds * 3)
        for (date, value) in values {
            if date.timeIntervalSince(previous) > gap { groups.append([]) }
            groups[groups.count-1].append(Point(x: date.timeIntervalSince(first.0) / duration, y: y(value), positive: value >= 0)); previous = date
        }
        segments = groups
    }
}

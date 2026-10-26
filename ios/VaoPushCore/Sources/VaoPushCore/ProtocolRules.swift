import Foundation

public enum ProtocolRules {
    public static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text), text.hasSuffix("Z") { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return text.hasSuffix("Z") ? formatter.date(from: text) : nil
    }

    public static func revision(_ text: String) throws -> Int64 {
        guard matches(text, "^[1-9][0-9]{0,18}$"), let value = Int64(text), value > 0 else {
            throw CoreError.invalid("revision 须为正整数字符串")
        }
        return value
    }

    public static func decimal(_ text: String, integerOnly: Bool = false) throws -> Decimal {
        let pattern = integerOnly ? "^-?[0-9]+$" : "^-?[0-9]+(\\.[0-9]+)?$"
        let digitCount = text.filter(\.isNumber).count
        let fractionCount = text.split(separator: ".").dropFirst().first?.count ?? 0
        guard matches(text, pattern), digitCount <= 38, fractionCount <= 18,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
            throw CoreError.invalid("不支持的十进制值或精度")
        }
        return value
    }

    public static func validate(_ snapshot: StateSnapshot) throws {
        _ = try revision(snapshot.revision)
        guard !snapshot.streamID.isEmpty, matches(snapshot.dataID, "^[a-z0-9_-]{1,64}$"),
              date(snapshot.receivedAt) != nil else { throw CoreError.invalid("无效的快照身份或时间") }
        try validate(snapshot.state)
    }

    public static func validate(_ state: WidgetState) throws {
        guard state.schemaVersion == 1 else { throw CoreError.invalid("不支持的 schema_version") }
        guard date(state.sourceUpdatedAt) != nil else { throw CoreError.invalid("来源时间须为 UTC RFC 3339") }
        guard state.fields != nil || state.items != nil else { throw CoreError.invalid("至少提供 fields 或 items 容器") }
        guard try JSONEncoder().encode(state).count <= 64 * 1024 else { throw CoreError.invalid("状态超过 64 KiB") }
        if let ttl = state.validForSeconds, ttl <= 0 { throw CoreError.invalid("有效期须为正整数") }
        if let sequence = state.sequence { _ = try revision(sequence) }
        try validateFields(state.fields ?? [:])
        let items = state.items ?? []
        guard items.count <= 20, Set(items.map(\.itemID)).count == items.count,
              items.allSatisfy({ !$0.itemID.isEmpty }) else { throw CoreError.invalid("项目过多或身份重复") }
        var seriesCount = state.series?.count ?? 0
        try validateSeries(state.series ?? [:])
        for item in items {
            try validateFields(item.fields)
            try validateSeries(item.series ?? [:])
            seriesCount += item.series?.count ?? 0
        }
        guard seriesCount <= 4 else { throw CoreError.invalid("序列过多") }
    }

    public static func validate(_ card: CardConfiguration) throws {
        if card.message != nil {
            guard card.remote == nil, card.streamID == MessageCardOptions.streamID,
                  card.fields.isEmpty, card.itemID == nil, card.seriesKey == nil else {
                throw CoreError.invalid("消息卡片不能绑定业务字段或Web设计")
            }
        }
        if let remote = card.remote {
            try remote.design.validate()
            guard remote.adjustments.nodes.count <= 64, remote.adjustments.name?.utf8.count ?? 0 <= 128,
                  ["system", "light", "dark"].contains(remote.adjustments.theme ?? "system") else { throw CoreError.invalid("本机微调配置无效") }
            for adjustment in remote.adjustments.nodes.values {
                guard (adjustment.label?.utf8.count ?? 0) <= 96,
                      adjustment.decimals.map({ (0...18).contains($0) }) ?? true,
                      adjustment.fontSize.map({ (10...32).contains($0) }) ?? true else { throw CoreError.invalid("本机微调超出范围") }
            }
        }
        guard !card.id.isEmpty, !card.streamID.isEmpty, !card.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              card.name.utf8.count <= 128,
              card.fields.count <= 32, Set(card.fields.map(\.key)).count == card.fields.count else {
            throw CoreError.invalid("无效的卡片身份、标题或字段绑定")
        }
        for field in card.fields {
            guard matches(field.key, "^[A-Za-z][A-Za-z0-9_]{0,63}$"),
                  (field.alias?.utf8.count ?? 0) <= 96 else { throw CoreError.invalid("无效的字段绑定") }
            if let decimals = field.decimals, !(0...18).contains(decimals) { throw CoreError.invalid("小数位超出范围") }
        }
    }

    private static func validateFields(_ fields: [String: DataField]) throws {
        guard fields.count <= 32 else { throw CoreError.invalid("字段过多") }
        for (key, field) in fields {
            guard matches(key, "^[A-Za-z][A-Za-z0-9_]{0,63}$"), (field.label?.utf8.count ?? 0) <= 96,
                  (field.unit?.utf8.count ?? 0) <= 96 else { throw CoreError.invalid("无效字段 key、名称或单位") }
            if field.value == .unavailable { continue }
            switch (field.type, field.value) {
            case (.text, .text(let value)):
                guard value.utf8.count <= 512 else { throw CoreError.invalid("文本过长") }
            case (.decimal, .text(let value)), (.percent, .text(let value)):
                _ = try decimal(value)
            case (.integer, .text(let value)): _ = try decimal(value, integerOnly: true)
            case (.datetime, .text(let value)):
                guard date(value) != nil else { throw CoreError.invalid("无效时间字段") }
            case (.boolean, .boolean): break
            default: throw CoreError.invalid("字段类型与值不匹配")
            }
        }
    }

    private static func validateSeries(_ series: [String: DataSeries]) throws {
        for (key, value) in series {
            guard matches(key, "^[A-Za-z][A-Za-z0-9_]{0,63}$"), value.intervalSeconds > 0,
                  value.points.count <= 60 else { throw CoreError.invalid("无效序列或点数过多") }
            var previous: Date?
            for point in value.points {
                guard let time = date(point.t), previous == nil || time > previous! else {
                    throw CoreError.invalid("序列时间须严格递增")
                }
                previous = time
                if value.type == .line {
                    guard let text = point.value else { throw CoreError.invalid("折线缺少 value") }
                    _ = try decimal(text)
                } else {
                    guard let o = point.o, let h = point.h, let l = point.l, let c = point.c else {
                        throw CoreError.invalid("OHLC 缺少数值")
                    }
                    let open = try decimal(o), high = try decimal(h), low = try decimal(l), close = try decimal(c)
                    guard high >= max(open, close), low <= min(open, close), high >= low else {
                        throw CoreError.invalid("OHLC 高低关系错误")
                    }
                    if let v = point.v, try decimal(v) < 0 { throw CoreError.invalid("成交量不可为负") }
                }
            }
        }
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}

public enum FieldFormatter {
    public static func label(for binding: FieldBinding, field: DataField?) -> String {
        if let alias = binding.alias, !alias.isEmpty { return alias }
        return field?.label ?? binding.key
    }

    public static func display(_ field: DataField?, decimals: Int? = nil, showUnit: Bool = true, locale: Locale = VaoL10n.locale) -> String {
        guard let field else { return VaoL10n.text("不可用") }
        switch field.value {
        case .unavailable: return VaoL10n.text("不可用")
        case .boolean(let value): return value ? VaoL10n.text("是") : VaoL10n.text("否")
        case .text(let text):
            switch field.type {
            case .decimal, .integer, .percent:
                guard let value = try? ProtocolRules.decimal(text, integerOnly: field.type == .integer) else { return VaoL10n.text("不可用") }
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = decimals ?? 0
                formatter.maximumFractionDigits = decimals ?? 18
                let result = formatter.string(from: NSDecimalNumber(decimal: value)) ?? text
                return field.type == .percent ? result + "%" : result + (showUnit ? (field.unit.map { " " + $0 } ?? "") : "")
            case .datetime:
                guard let date = ProtocolRules.date(text) else { return VaoL10n.text("不可用") }
                return date.formatted(date: .abbreviated, time: .shortened)
            case .text: return text
            case .boolean: return VaoL10n.text("不可用")
            }
        }
    }
}

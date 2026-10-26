import Foundation

/// Local layout examples. Values are illustrative and are never a live market feed.
public enum PrototypeData {
    public static let owner = "account_demo"
    public static let quoteStream = "stream_demo_quote"
    public static let taskStream = "stream_demo_task"

    public static func snapshots(revision: Int64 = 1, at date: Date = .now) -> [StateSnapshot] {
        let stamp = ISO8601DateFormatter().string(from: date)
        let offset = Decimal((revision - 1) % 10)
        var quote = WidgetState(sourceUpdatedAt: stamp, fields: [
            "name": DataField(type: .text, label: "标的", value: .text("AAPL · 苹果公司")),
            "price": DataField(type: .decimal, label: "价格", value: .text("\(Decimal(string: "128.50")! + offset)"), unit: "USD"),
            "change": DataField(type: .percent, label: "涨跌幅", value: .text("1.25")),
            "high": DataField(type: .decimal, label: "当日最高价", value: .text("142.30"), unit: "USD"),
            "low": DataField(type: .decimal, label: "当日最低价", value: .text("121.70"), unit: "USD"),
            "volume": DataField(type: .decimal, label: "成交量", value: .text("256800")),
            "funding": DataField(type: .percent, label: "资金费率", value: .text("0.01"))
        ], title: "美股行情示例")
        // Explicit OHLC fixtures stand for sender-supplied history; never derived from the current price.
        let candles = [(124.0, 129.0, 122.0, 127.0), (127, 131, 125, 130), (130, 132, 126, 128),
                       (128, 134, 127, 132), (132, 135, 129, 130), (130, 133, 128, 128.5)]
        quote.series = ["candles": DataSeries(type: .ohlc, label: "示例 K 线 · 5 分钟", intervalSeconds: 300,
            unit: "USD", points: candles.enumerated().map { index, p in
                SeriesPoint(t: ISO8601DateFormatter().string(from: date.addingTimeInterval(Double(index - 6) * 300)),
                            o: String(p.0), h: String(p.1), l: String(p.2), c: String(p.3), isClosed: true)
            })]
        var task = WidgetState(sourceUpdatedAt: stamp, fields: [
            "name": DataField(type: .text, label: "任务", value: .text("设计资源备份")),
            "progress": DataField(type: .percent, label: "完成进度", value: .text("\(68 + (revision - 1) % 20)")),
            "status": DataField(type: .text, label: "状态", value: .text("进行中")),
            "remaining": DataField(type: .integer, label: "剩余文件", value: .text("128"), unit: "个")
        ], title: "任务进度", validForSeconds: 300)
        task.series = ["progressHistory": DataSeries(type: .line, label: "示例进度历史", intervalSeconds: 60,
            points: [12, 23, 35, 40, 56, 68].enumerated().map { index, value in
                SeriesPoint(t: ISO8601DateFormatter().string(from: date.addingTimeInterval(Double(index - 6) * 60)), value: String(value))
            })]
        return [StateSnapshot(streamID: quoteStream, dataID: "demo_quote", revision: String(revision), receivedAt: stamp, state: quote),
                StateSnapshot(streamID: taskStream, dataID: "demo_task", revision: String(revision), receivedAt: stamp, state: task)]
    }

    public static var cards: [CardConfiguration] { [
        CardConfiguration(id: "card_demo_quote", name: "美股行情 · AAPL", streamID: quoteStream,
            fields: [FieldBinding(key: "price", decimals: 2), FieldBinding(key: "change", decimals: 2), FieldBinding(key: "name"),
                     FieldBinding(key: "high", decimals: 2), FieldBinding(key: "low", decimals: 2),
                     FieldBinding(key: "volume", visible: false, decimals: 0), FieldBinding(key: "funding", visible: false, decimals: 2)],
            template: .metric, seriesKey: "candles"),
        CardConfiguration(id: "card_demo_task", name: "任务进度", streamID: taskStream,
            fields: [FieldBinding(key: "name"), FieldBinding(key: "progress", alias: "已完成", decimals: 0),
                     FieldBinding(key: "status"), FieldBinding(key: "remaining", decimals: 0)], seriesKey: "progressHistory")
    ] }

    /// Upgrade only the old local fixture, preserving user names, field aliases and other servers.
    @discardableResult
    public static func upgradeStockExample(_ store: SharedStore) throws -> Bool {
        guard var snapshot = try store.snapshot(streamID: quoteStream, owner: owner),
              snapshot.state.fields?["name"]?.value == .text("VAO / USD · 虚构"),
              let revision = Int64(snapshot.revision), revision < Int64.max else { return false }
        snapshot.revision = String(revision + 1)
        snapshot.state.title = "美股行情示例"
        snapshot.state.validForSeconds = nil
        snapshot.state.fields?["name"] = DataField(type: .text, label: "标的", value: .text("AAPL · 苹果公司"))
        snapshot.state.fields?["high"]?.label = "当日最高价"
        snapshot.state.fields?["low"]?.label = "当日最低价"
        try store.apply(snapshot, owner: owner)
        for var card in try store.cards(owner: owner) where card.streamID == quoteStream && card.name == "行情概览" {
            card.name = "美股行情 · AAPL"
            try store.save(card, owner: owner)
        }
        return true
    }

    public static func seed(_ store: SharedStore) throws {
        let existing = Set(try store.snapshots(owner: owner).map(\.streamID))
        let isNew = existing.isEmpty
        guard !existing.contains(quoteStream) || !existing.contains(taskStream) else { return }
        for snapshot in snapshots() where !existing.contains(snapshot.streamID) {
            try store.apply(snapshot, owner: owner)
        }
        // Seed once. Never recreate deleted cards or overwrite the user's edits on launch.
        if isNew {
            for card in cards { try store.save(card, owner: owner) }
            try store.archive(ArchivedMessage(id: "prototype_welcome", title: "欢迎体验 Vao Push", body: "当前为示例内容，仅展示布局，不连接真实业务。", receivedAt: ISO8601DateFormatter().string(from: .now)), owner: owner)
        }
    }
}

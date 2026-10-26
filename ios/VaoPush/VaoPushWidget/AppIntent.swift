import AppIntents
import WidgetKit
import VaoPushCore

struct SavedCardEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "已保存卡片" }
    static var defaultQuery: SavedCardQuery { SavedCardQuery() }
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct SavedCardQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SavedCardEntity] {
        let store = try PrototypeStorage.open()
        let sources = try store.sources().filter(\.isEnabled)
        return try identifiers.compactMap { id in
            let identity = try ScopedCardID.decode(id)
            guard let source = sources.first(where: { $0.owner == identity.owner }),
                  let card = try store.card(id: identity.cardID, owner: identity.owner) else { return nil }
            return SavedCardEntity(id: id, name: card.name + " · " + source.name)
        }
    }

    func suggestedEntities() async throws -> [SavedCardEntity] {
        let store = try PrototypeStorage.open()
        return try store.sources().filter(\.isEnabled).flatMap { source in
            try store.cards(owner: source.owner).map {
                SavedCardEntity(id: ScopedCardID.encode(owner: source.owner, cardID: $0.id), name: $0.name + " · " + source.name)
            }
        }
    }

    func defaultResult() async -> SavedCardEntity? { try? await suggestedEntities().first }
}

struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "选择已保存的卡片" }
    static var description: IntentDescription { "先在 Vao Push 中编辑并保存卡片，再将其添加到桌面。" }
    @Parameter(title: "卡片") var card: SavedCardEntity?
}

struct SetCardModeIntent: AppIntent {
    static var title: LocalizedStringResource { "切换卡片图表" }
    static var supportedModes: IntentModes { .background }
    @Parameter(title: "卡片 ID") var cardID: String
    @Parameter(title: "尺寸") var family: String
    @Parameter(title: "显示图表") var showChart: Bool

    init() {}
    init(cardID: String, family: String, showChart: Bool) {
        self.cardID = cardID; self.family = family; self.showChart = showChart
    }

    func perform() async throws -> some IntentResult {
        let store = try PrototypeStorage.open()
        let identity = try ScopedCardID.decode(cardID)
        guard try store.sources().contains(where: { $0.owner == identity.owner && $0.isEnabled }),
              let card = try store.card(id: identity.cardID, owner: identity.owner),
              let key = card.seriesKey,
              let series = try store.snapshot(streamID: card.streamID, owner: identity.owner)?.state.series?[key],
              !series.points.isEmpty else { throw CoreError.invalid("卡片或历史数据已不可用") }
        try store.setMode(showChart ? .chart : .summary, cardID: card.id, family: family, owner: identity.owner)
        WidgetCenter.shared.reloadTimelines(ofKind: PrototypeStorage.widgetKind)
        return .result()
    }
}

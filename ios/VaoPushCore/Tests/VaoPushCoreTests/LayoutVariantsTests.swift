import Foundation
import Testing

@testable import VaoPushCore

@Suite("尺寸布局与旧版兼容") struct LayoutVariantsTests {
  private func card() throws -> SubscribedCard {
    let json =
      #"{"card_id":"card_11111111111111111111111111111111","revision":"1","design":{"schema_version":1,"name":"Status","family":"medium","layout":{"id":"root","type":"text","text":"default"}},"snapshot":{"stream_id":"s","data_id":"d","revision":"1","received_at":"2026-11-08T01:00:00Z","state":{"schema_version":1,"source_updated_at":"2026-11-08T01:00:00Z","fields":{"status":{"type":"text","value":"ok"}}}}}"#
    return try JSONDecoder().decode(SubscribedCard.self, from: Data(json.utf8))
  }
  @Test("四尺寸选择及同版本旧缓存迁移") func migration() throws {
    var info = try card()
    let old = try info.configuration()
    info.design.schemaVersion = 2
    var compact = info.design.layout
    compact.text = "compact"
    info.design.layouts = ["small": compact]
    try info.design.validate()
    let new = try info.configuration(previous: old)
    #expect(new.remote?.design.layout(for: "small").text == "compact")
    #expect(new.remote?.design.layout(for: "medium").text == "default")
    #expect(new.remote?.design.layout(for: "large").text == "default")
    #expect(new.remote?.design.layout(for: "extraLarge").text == "default")
    var legacy = info
    legacy.design = info.design.legacy
    #expect(try legacy.configuration(previous: new).remote?.design.schemaVersion == 2)
    info.design.name = "different same revision"
    #expect(throws: CoreError.self) { try info.configuration(previous: new) }
  }
  @Test("按尺寸微调不串用，默认微调保留") func scopes() throws {
    var info = try card()
    info.design.schemaVersion = 2
    info.design.layouts = ["small": info.design.layout]
    var card = try info.configuration()
    var old = NodeAdjustment()
    old.fontSize = 20
    card.remote?.adjustments.nodes["root"] = old
    var small = NodeAdjustment()
    small.fontSize = 12
    card.remote?.adjustments.familyNodes = ["small": ["root": small]]
    let remote = try #require(card.remote)
    #expect(remote.adjustments.nodes(for: "small", design: remote.design)["root"]?.fontSize == 12)
    #expect(remote.adjustments.nodes(for: "medium", design: remote.design)["root"]?.fontSize == 20)
    try ProtocolRules.validate(card)
    card.remote?.adjustments.familyNodes?["small"]?["root"]?.fontSize = 100
    #expect(throws: CoreError.self) { try ProtocolRules.validate(card) }
  }
  @Test("损坏覆盖不能被默认布局掩盖") func invalidVariant() throws {
    var info = try card()
    info.design.schemaVersion = 2
    var bad = info.design.layout
    bad.type = "script"
    info.design.layouts = ["large": bad]
    #expect(throws: CoreError.self) { try info.design.validate() }
  }
  @Test("旧历史无图标仍可解码，新图标可持久化") func optionalIcon() throws {
    let old = try JSONDecoder().decode(
      ArchivedMessage.self,
      from: Data(#"{"id":"m","title":"t","body":"b","receivedAt":"2026-11-08T01:00:00Z"}"#.utf8))
    #expect(old.icon == nil)
    var next = old
    next.icon = "https://example.com/icon.png"
    #expect(
      try JSONDecoder().decode(ArchivedMessage.self, from: JSONEncoder().encode(next)).icon
        == next.icon)
  }
}

import Testing
import Foundation
@testable import VaoPushCore
@Suite("1.2 节点、缺值及旧端兼容") struct CardCapabilitiesTests {
    func design() throws -> CardDesign {
        try JSONDecoder().decode(CardDesign.self, from: Data(##"{"schema_version":3,"name":"Test","family":"medium","theme":"system","layout":{"id":"root","type":"column","background":"surface","children":[{"id":"number","type":"number","bind":"fields.value","prefix":"$","suffix":" /s","colors":{"light":"#153047","dark":"#E6EDF3"}},{"id":"status","type":"badge","bind":"fields.status","states":{"ok":{"text":"正常","color":"#16835B"}}}]},"fallback":{"layout":{"id":"root","type":"column","children":[{"id":"number","type":"number","bind":"fields.value"},{"id":"status","type":"badge","bind":"fields.status"}]}}}"##.utf8))
    }
    @Test func stableProjectionAndMigration() throws {
        let d = try design(); try d.validate(); try d.projected(schema: 1).validate(); try d.projected(schema: 2).validate()
        #expect(d.projected(schema: 2).schemaVersion == 2)
        var s = WidgetState(sourceUpdatedAt: "2026-11-09T00:00:00Z", fields: ["value":DataField(type:.decimal,value:.text("0"))])
        let snapshot = StateSnapshot(streamID:"stream",dataID:"data",revision:"1",receivedAt:s.sourceUpdatedAt,state:s)
        var old = try SubscribedCard(cardID:"card_test",revision:"2",design:d.projected(schema:2),snapshot:snapshot).configuration()
        old.remote?.adjustments.nodes["number"] = NodeAdjustment(); old.remote?.adjustments.nodes["number"]?.decimals = 2
        let new = try SubscribedCard(cardID:"card_test",revision:"2",design:d,snapshot:snapshot).configuration(previous:old)
        #expect(new.remote?.design.schemaVersion == 3); #expect(new.remote?.adjustments.nodes["number"]?.decimals == 2)
        s.fields?["value"]?.value = .text("20")
        #expect(d.projected(schema:2) == d.projected(schema:2))
        var bad = d; bad.layout.children?[0].suffix = "changed"
        #expect(throws:CoreError.conflictingRevision) { _ = try SubscribedCard(cardID:"card_test",revision:"2",design:bad,snapshot:snapshot).configuration(previous:new) }
        let retained = try SubscribedCard(cardID:"card_test",revision:"2",design:d.projected(schema:2),snapshot:snapshot).configuration(previous:new)
        #expect(retained.remote?.design.schemaVersion == 3)
    }
    @Test func missingNullBlankZeroFalseAndItemScope() throws {
        var d = try design(), n = d.layout.children![0]
        n.hideIfEmpty = true
        for v: FieldValue in [.unavailable,.text(""),.text(" \n ")] {
            let s=WidgetState(sourceUpdatedAt:"2026-11-09T00:00:00Z",fields:["value":DataField(type:.text,value:v)])
            #expect(!n.visible(in:s,item:nil))
        }
        for v: FieldValue in [.text("0"),.boolean(false)] {
            let s=WidgetState(sourceUpdatedAt:"2026-11-09T00:00:00Z",fields:["value":DataField(type:.text,value:v)])
            #expect(n.visible(in:s,item:nil))
            let item=DataItem(itemID:"empty",fields:[:]); #expect(!n.visible(in:s,item:item))
        }
        var divider = n; divider.id="separator"; divider.type="divider"; divider.bind=nil;divider.hideIfEmpty=nil
        d.layout.children=[divider,n,divider]
        let blank=WidgetState(sourceUpdatedAt:"2026-11-09T00:00:00Z",fields:[:])
        #expect(d.layout.visibleChildren(in:blank,item:nil,adjustments:[:]).isEmpty)
        #expect(!d.layout.visible(in:blank,item:nil))
        let zero=WidgetState(sourceUpdatedAt:blank.sourceUpdatedAt,fields:["value":DataField(type:.integer,value:.text("0"))])
        #expect(d.layout.visibleChildren(in:zero,item:nil,adjustments:[:]).map(\.id) == ["number"])
    }
    @Test func stateMappingAndUnknownNeutral() throws {
        let n=try design().layout.children![1]
        #expect(n.stateStyle(field:DataField(type:.text,value:.text("ok")))?.text == "正常")
        #expect(n.stateStyle(field:DataField(type:.text,value:.text("warming")))?.color == "secondary")
        #expect(n.stateStyle(field:nil)?.background == "surface")
    }
    @Test func timestampGeometryAndGaps() {
        let s=DataSeries(type:.line,intervalSeconds:60,points:[SeriesPoint(t:"2026-11-09T00:00:00Z",value:"0"),SeriesPoint(t:"2026-11-09T00:01:00Z",value:"-2"),SeriesPoint(t:"2026-11-09T00:10:00Z",value:"3")])
        let t=CardTrend(series:s,gapSeconds:nil)
        #expect(t.segments.count == 2); #expect(abs(t.segments[0][1].x-0.1)<0.00001)
        #expect(t.segments[0][1].positive == false)
        #expect(t.baseline>0 && t.baseline<1)
    }
    @Test func preciseTrendUsesDifferencesBeforeFloatingPoint() {
        let s = DataSeries(type:.line,intervalSeconds:60,points:[SeriesPoint(t:"2026-11-09T00:00:00Z",value:"12345678901234567890123456.01"),SeriesPoint(t:"2026-11-09T00:01:00Z",value:"12345678901234567890123456.02")])
        let trend=CardTrend(series:s,gapSeconds:nil)
        #expect(trend.segments[0][0].y == 1); #expect(trend.segments[0][1].y == 0)
        #expect(CardTrend.changeSign(s) == 1)
        var down = s; down.points.reverse(); #expect(CardTrend.changeSign(down) == -1)
    }
    @Test func urlBoundary() {
        for url in ["http://example.com/a.png","https://user:secret@example.com/x","https://localhost/x","https://127.0.0.1/x","https://192.168.1.2/x","https://[::1]/x","https://example.com:444/x","https://example.com/a#x"] { #expect(!CardIconPolicy.validURL(url)) }
        #expect(CardIconPolicy.validURL("https://images.example.com/icon.png"))
    }
}

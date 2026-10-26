import Foundation
import Testing
@testable import VaoPushCore

struct LocalizationAndNavigationTests {
    @Test("语言偏好与系统回退，参数不会改写用户内容")
    func languages() {
        #expect(VaoL10n.identifier(preference: "system", preferredLanguages: ["zh-Hant-TW", "en"]) == "zh-Hans")
        #expect(VaoL10n.identifier(preference: "system", preferredLanguages: ["fr-FR"]) == "en")
        #expect(VaoL10n.identifier(preference: "en", preferredLanguages: ["zh-Hans"]) == "en")
        #expect(VaoL10n.text("消息详情", language: "en") == "Message Details")
        #expect(VaoL10n.text("消息详情", language: "zh-Hans") == "消息详情")
        #expect(VaoL10n.format("清理{0}的本地消息", values: ["My {1} Server"], language: "en") == "Clear local messages from My {1} Server")
        #expect(VaoL10n.text("用户自定义名称", language: "en") == "用户自定义名称")
    }

    @Test("通知详情只定位唯一有效的本机绑定，同名及其他服务器不能匹配")
    func notificationDestination() throws {
        let payload = Data(#"{"vao_push":{"version":1,"kind":"message","server_id":"srv_1","account_id":"acct_1","binding_id":"dev_1","message_id":"msg_1"}}"#.utf8)
        let target = try NotificationMessageTarget(payload: payload)
        var first = ServerConnection(id: "first", name: "Same Name", baseURL: URL(string: "http://192.0.2.1:8188")!, serverID: "srv_1", accountID: "acct_1", bindingID: "dev_1")
        let second = ServerConnection(id: "second", name: "Same Name", baseURL: URL(string: "https://example.com")!, serverID: "srv_2", accountID: "acct_1", bindingID: "dev_1")
        #expect(target.messageID == "msg_1")
        #expect(target.owner(in: [first, second]) == first.owner)
        #expect(target.owner(in: [second]) == nil)
        #expect(target.owner(in: [first, first]) == nil)
        first.isEnabled = false
        #expect(target.owner(in: [first]) == nil)
        first.isEnabled = true; first.isDemo = true
        #expect(target.owner(in: [first]) == nil)
        #expect(throws: (any Error).self) { try NotificationMessageTarget(payload: Data(#"{"vao_push":{"kind":"message"}}"#.utf8)) }
    }
}

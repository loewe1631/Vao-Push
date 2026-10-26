import Foundation
import Testing
@testable import VaoPushCore

@Suite("发布推送环境")
struct PushEnvironmentTests {
    private func profile(_ environment: String) throws -> Data {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": ["aps-environment": environment]], format: .xml, options: 0)
        // CMS contains binary bytes around the XML payload; the whole file isn't UTF-8 text.
        return Data([0x30, 0x80, 0xFF]) + xml + Data([0, 0xFF])
    }
    @Test("签入的描述文件优先于构建类型和手动配置")
    func signedProfile() throws {
        #expect(PushEnvironment.resolve(profile: try profile("development"), configured: "production", debugBuild: false) == "sandbox")
        #expect(PushEnvironment.resolve(profile: try profile("production"), configured: "sandbox", debugBuild: true) == "production")
    }
    @Test("没有描述文件的商店版本使用正式APNs")
    func distributionFallback() {
        #expect(PushEnvironment.resolve(profile: nil, configured: nil, debugBuild: false) == "production")
        #expect(PushEnvironment.resolve(profile: nil, configured: nil, debugBuild: true) == "sandbox")
    }
    @Test("缺失或不完整描述文件可使用明确配置")
    func configuredEnvironment() {
        #expect(PushEnvironment.resolve(profile: Data("incomplete".utf8), configured: "development", debugBuild: false) == "sandbox")
        #expect(PushEnvironment.resolve(profile: nil, configured: "production", debugBuild: true) == "production")
    }
}

#if os(iOS)
import Foundation
import Security

/// Session credentials stay in the App's default group. Widget read credentials use an explicit shared group.
public enum CredentialVault {
    private static let service = "VaoPush.DeviceCredentials.v1"
    private static func query(_ id: String, shared: Bool) throws -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: false]
        do {
            let key = shared ? "VaoKeychainAccessGroup" : "VaoPrivateKeychainAccessGroup"
            guard let group = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  !group.isEmpty, !group.contains("$(") else { throw CoreError.invalid("共享凭证配置未就绪") }
            value[kSecAttrAccessGroup as String] = group
        }
        return value
    }
    public static func save(_ data: Data, id: String, shared: Bool = false) throws {
        let q = try query(id, shared: shared)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw CoreError.invalid("无法保存安全凭证（\(status)）") }
    }
    public static func load(id: String, shared: Bool = false) throws -> Data? {
        var q = try query(id, shared: shared)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CoreError.invalid("无法读取安全凭证，请解锁设备后重试（\(status)）") }
        return value as? Data
    }
    public static func remove(id: String, shared: Bool = false) throws {
        let status = SecItemDelete(try query(id, shared: shared) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CoreError.invalid("无法移除安全凭证（\(status)）") }
    }
}
#endif

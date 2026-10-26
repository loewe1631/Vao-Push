import Foundation

public enum PushEnvironment {
    /// A Release build can still carry a development profile. The signed profile wins.
    static func resolve(profile: Data?, configured: String?, debugBuild: Bool) -> String {
        if let profile, let start = profile.range(of: Data("<?xml".utf8)),
           let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
           let value = try? PropertyListSerialization.propertyList(from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil),
           let plist = value as? [String: Any], let entitlements = plist["Entitlements"] as? [String: Any],
           let environment = normalized(entitlements["aps-environment"] as? String) {
            return environment
        }
        if let environment = normalized(configured) { return environment }
        // App Store/TestFlight builds may omit the embedded profile and use production APNs.
        return debugBuild ? "sandbox" : "production"
    }

    private static func normalized(_ value: String?) -> String? {
        switch value { case "development", "sandbox": "sandbox"; case "production": "production"; default: nil }
    }

    #if os(iOS)
    public static var current: String {
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        return resolve(profile: profile, configured: Bundle.main.object(forInfoDictionaryKey: "VaoAPNsEnvironment") as? String,
                       debugBuild: debugBuild)
    }
    #endif
}

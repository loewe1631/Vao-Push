import Foundation

/// One preference is shared by the App, notification extension, and widgets.
/// Display strings are localized explicitly; server content and saved names are never rewritten.
public enum VaoL10n {
    public static let groupID = "group.app.vaovao.push"
    public static let preferenceKey = "interface-language"
    public static var preferences: UserDefaults { UserDefaults(suiteName: groupID) ?? .standard }

    public static func identifier(preference: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if preference == "zh" { return "zh-Hans" }
        if preference == "en" { return "en" }
        return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }

    public static var language: String {
        identifier(preference: preferences.string(forKey: preferenceKey) ?? "system")
    }
    public static var locale: Locale { Locale(identifier: language) }

    public static func text(_ key: String, _ values: String..., language: String? = nil) -> String {
        format(key, values: values, language: language ?? self.language)
    }

    public static func format(_ key: String, values: [String], language: String) -> String {
        let selected = language.hasPrefix("zh") ? "zh-Hans" : "en"
        let bundle = Bundle.module.path(forResource: selected, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
        var result = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        // Replace only original slots, so names containing braces are kept verbatim.
        let regex = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let numberRange = Range(match.range(at: 1), in: result),
                  let index = Int(result[numberRange]), values.indices.contains(index),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: values[index])
        }
        return result
    }

}

extension CoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .database(let message): return VaoL10n.text(message)
        case .conflictingRevision: return VaoL10n.text("同一版本的数据发生冲突，请重新同步。")
        case .streamIdentityChanged: return VaoL10n.text("数据来源身份已变化，请重新连接。")
        case .unsupportedDatabaseVersion: return VaoL10n.text("本地资料版本较新，请更新 App。")
        }
    }
}

import Foundation

enum AppText {
    static var isChinese: Bool {
        Locale.preferredLanguages
            .first?
            .lowercased()
            .hasPrefix("zh") ?? false
    }

    static func t(_ english: String, zh chinese: String) -> String {
        isChinese ? chinese : english
    }
}

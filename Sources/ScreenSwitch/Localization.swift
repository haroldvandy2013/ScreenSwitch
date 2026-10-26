import Foundation

enum AppLanguage: String, CaseIterable {
    case chinese = "zh-Hans"
    case english = "en"
}

final class LanguageSettings {
    static let shared = LanguageSettings()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults(suiteName: "local.ScreenSwitch.settings")!) {
        self.defaults = defaults
    }

    var language: AppLanguage {
        get {
            AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .chinese
        }
        set {
            defaults.set(newValue.rawValue, forKey: "language")
        }
    }
}

func L(_ chinese: String, _ english: String) -> String {
    LanguageSettings.shared.language == .chinese ? chinese : english
}

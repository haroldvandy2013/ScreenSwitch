import Foundation

enum AppLanguage: String, CaseIterable {
    case chinese = "zh-Hans"
    case english = "en"
}

final class AppSettings {
    static let shared = AppSettings()
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

    var restoreOnDisplaySleep: Bool {
        get { defaults.bool(forKey: "restoreOnDisplaySleep") }
        set { defaults.set(newValue, forKey: "restoreOnDisplaySleep") }
    }
}

func L(_ chinese: String, _ english: String) -> String {
    AppSettings.shared.language == .chinese ? chinese : english
}

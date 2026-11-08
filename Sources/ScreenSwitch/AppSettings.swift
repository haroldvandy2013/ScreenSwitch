import Foundation

enum AppLanguage: String, CaseIterable {
    case chinese = "zh-Hans"
    case english = "en"
}

final class AppSettings {
    static let shared = AppSettings()
    #if DEBUG
    static var checkDefaults: UserDefaults?
    #endif
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        #if DEBUG
        self.defaults = defaults ?? Self.checkDefaults ?? UserDefaults(suiteName: "local.ScreenSwitch.settings")!
        #else
        self.defaults = defaults ?? UserDefaults(suiteName: "local.ScreenSwitch.settings")!
        #endif
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

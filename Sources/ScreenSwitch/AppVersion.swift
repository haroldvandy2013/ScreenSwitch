import Foundation

enum AppVersion {
    static func label(in bundle: Bundle = .main) -> String {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return "version dev"
        }
        return "version \(version)"
    }
}

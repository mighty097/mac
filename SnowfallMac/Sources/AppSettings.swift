import Foundation

/// Persists the menu choices between launches.
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    var isEnabled: Bool {
        get { defaults.object(forKey: "snowEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "snowEnabled") }
    }

    var finderOnly: Bool {
        get { defaults.object(forKey: "snowFinderOnly") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "snowFinderOnly") }
    }

    var intensity: SnowIntensity {
        get {
            if let raw = defaults.object(forKey: "snowIntensity") as? Int,
               let value = SnowIntensity(rawValue: raw) {
                return value
            }
            return .normal
        }
        set { defaults.set(newValue.rawValue, forKey: "snowIntensity") }
    }
}

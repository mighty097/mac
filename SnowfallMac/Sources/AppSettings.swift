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
               let value = SnowIntensity(rawValue: raw) { return value }
            return .normal
        }
        set { defaults.set(newValue.rawValue, forKey: "snowIntensity") }
    }

    var windStrength: Double {
        get { defaults.object(forKey: "windStrength") as? Double ?? 1.0 }
        set { defaults.set(min(2.0, max(0.0, newValue)), forKey: "windStrength") }
    }

    var windDirection: Int {
        get { defaults.object(forKey: "windDirection") as? Int ?? 0 }
        set { defaults.set(min(2, max(-2, newValue)), forKey: "windDirection") }
    }

    var accumulateOnWindows: Bool {
        get { defaults.object(forKey: "accumulateOnWindows") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "accumulateOnWindows") }
    }

    var behindWindowsOnly: Bool {
        get { defaults.object(forKey: "behindWindowsOnly") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "behindWindowsOnly") }
    }

    var includeDesktopWidgets: Bool {
        get { defaults.object(forKey: "includeDesktopWidgets") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "includeDesktopWidgets") }
    }

    /// Empty means every connected display. Display IDs are stable across normal reboots.
    var selectedDisplayIDs: [UInt32] {
        get { (defaults.array(forKey: "selectedDisplayIDs") as? [NSNumber])?.map { $0.uint32Value } ?? [] }
        set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: "selectedDisplayIDs") }
    }
}

/// Only stable ledges are persisted. Window IDs are session-specific, so window
/// piles intentionally remain transient rather than being restored onto the wrong window.
struct SnowPileSnapshot: Codable {
    let surfaceID: Int
    let kind: String
    let fresh: [CGFloat]
    let packed: [CGFloat]
    let snowAge: CGFloat
    /// Optional for backwards compatibility with snapshots written before
    /// the dog event introduced a localized snow tint.
    let yellow: [CGFloat]?
}

enum SnowPersistence {
    static func save(_ snapshots: [SnowPileSnapshot], key: String) {
        guard let data = try? JSONEncoder().encode(snapshots) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load(key: String) -> [SnowPileSnapshot] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshots = try? JSONDecoder().decode([SnowPileSnapshot].self, from: data) else {
            return []
        }
        return snapshots
    }
}

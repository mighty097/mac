import Foundation
import CoreGraphics

enum SnowIntensity: Int, CaseIterable {
    case light = 0
    case normal = 1
    case heavy = 2

    var title: String {
        switch self {
        case .light: return "Лёгкий снег"
        case .normal: return "Обычный снег"
        case .heavy: return "Метель"
        }
    }

    var spawnChancePerFrame: CGFloat {
        switch self {
        case .light: return 0.18
        case .normal: return 0.42
        case .heavy: return 0.85
        }
    }

    var maximumParticles: Int {
        switch self {
        case .light: return 100
        case .normal: return 220
        case .heavy: return 420
        }
    }

    var maximumPileHeight: CGFloat {
        switch self {
        case .light: return 9
        case .normal: return 16
        case .heavy: return 25
        }
    }

    var fallSpeed: ClosedRange<CGFloat> {
        switch self {
        case .light: return 17...34
        case .normal: return 24...49
        case .heavy: return 35...72
        }
    }
}

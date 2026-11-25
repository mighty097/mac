import AppKit

// MARK: - Surfaces snow can rest on

enum SurfaceKind {
    case window
    case dock
    case ground
}

/// A horizontal ledge: the top edge of a window, Dock panel or display bottom.
/// Coordinates are AppKit points local to the display, origin at bottom-left.
struct Surface {
    let id: Int
    let frame: CGRect
    let supportY: CGFloat
    let kind: SurfaceKind
    let ownerName: String
    let isTarget: Bool

    var isGround: Bool { kind == .ground }
    var cornerInset: CGFloat { isGround ? 0 : 12 }
    var left: CGFloat { frame.minX + cornerInset }
    var right: CGFloat { frame.maxX - cornerInset }
    var width: CGFloat { max(1, right - left) }

    // Surface-specific snow response. Window glass is slick and exposed, Dock
    // is sheltered by its panel, while the display edge behaves like a broad,
    // rough ground surface that can hold a deeper drift.
    var looseReposeSlope: CGFloat {
        switch kind {
        case .window: return 0.68
        case .dock: return 0.82
        case .ground: return 1.08
        }
    }

    var packedReposeSlope: CGFloat {
        switch kind {
        case .window: return 1.85
        case .dock: return 2.15
        case .ground: return 2.75
        }
    }

    var looseFlowRate: CGFloat {
        switch kind {
        case .window: return 0.225
        case .dock: return 0.19
        case .ground: return 0.145
        }
    }

    var packedFlowRate: CGFloat {
        switch kind {
        case .window: return 0.043
        case .dock: return 0.035
        case .ground: return 0.026
        }
    }

    var edgeRisePerBin: CGFloat {
        switch kind {
        case .window: return 1.10
        case .dock: return 1.25
        case .ground: return 1.70
        }
    }

    var compactionRate: CGFloat {
        switch kind {
        case .window: return 0.00015
        case .dock: return 0.00018
        case .ground: return 0.00023
        }
    }

    var depositionRadius: Int {
        switch kind {
        case .window: return 2
        case .dock: return 3
        case .ground: return 5
        }
    }
}

struct SurfaceInterval {
    var lo: CGFloat
    var hi: CGFloat
}

/// The exact movement since the previous geometry sample. No accumulated
/// 4-point threshold: every visible position change is reported immediately.
struct MovedSurface {
    let previous: Surface
    let delta: CGVector
    let distance: CGFloat
    let velocity: CGVector
    let sampleDuration: TimeInterval
}

struct SurfaceChange {
    var moved: [MovedSurface] = []
    var removed: [Surface] = []
}

// MARK: - Tracker

/// Samples the window list and keeps stable per-window IDs. Rendering uses the
/// latest frame directly; movement events are only for shedding/physics.
final class SurfaceTracker {
    private struct Known {
        var surface: Surface
        var lastSeen: TimeInterval
    }

    private struct PredictedFrame {
        var surface: Surface
        var isDragging: Bool
        var expiresAt: TimeInterval
    }

    /// Front-to-back order. Briefly missing windows remain during transition.
    private(set) var surfaces: [Surface] = []
    private(set) var isDisplayCovered = false
    private(set) var lastMovementTime: TimeInterval = -100

    var finderOnly = false
    var accumulateOnWindows = true
    var includeDesktopWidgets = false
    var includesBottomEdge = true

    private var known: [Int: Known] = [:]
    private var predictedFrames: [Int: PredictedFrame] = [:]
    private var lastPredictionTime: [Int: TimeInterval] = [:]
    private var lastRefreshTime: TimeInterval = 0
    private let graceSeconds: TimeInterval = 1.25
    private let movementEpsilon: CGFloat = 0.005

    func refresh(screen: NSScreen, size: CGSize, now: TimeInterval) -> SurfaceChange {
        var change = SurfaceChange()
        let sampleDuration = lastRefreshTime > 0
            ? max(1.0 / 240.0, now - lastRefreshTime)
            : (1.0 / 60.0)

        var fresh: [Surface] = []
        var coveredByFullScreen = false

        for info in WindowGeometryProvider.visibleWindowSurfaces(on: screen, includeDesktopWidgets: includeDesktopWidgets) {
            let frame = info.frame
            let isTarget = (!finderOnly || info.ownerName == "Finder") && accumulateOnWindows
            fresh.append(Surface(
                id: Int(info.windowID),
                frame: frame,
                supportY: frame.maxY,
                kind: .window,
                ownerName: info.ownerName,
                isTarget: isTarget
            ))

            let coversWidth = frame.width >= size.width * 0.985
            let coversHeight = frame.height >= size.height * 0.985
            let atOrigin = abs(frame.minX) < 8 && abs(frame.minY) < 8
            if coversWidth && coversHeight && atOrigin { coveredByFullScreen = true }
        }

        if includesBottomEdge {
            if let dockFrame = WindowGeometryProvider.dockSurfaceFrame(on: screen) {
                fresh.insert(Surface(
                    id: -3,
                    frame: dockFrame,
                    supportY: dockFrame.maxY,
                    kind: .dock,
                    ownerName: "Dock",
                    isTarget: !finderOnly
                ), at: 0)
            }
            fresh.append(Surface(
                id: -2,
                frame: CGRect(x: 0, y: 0, width: size.width, height: 4),
                supportY: 0,
                kind: .ground,
                ownerName: "Screen edge",
                isTarget: true
            ))
        }

        // While a title-bar drag is active, pointer-derived geometry is more
        // current than the asynchronous WindowServer window-list snapshot.
        // Keep the prediction until the real frame catches up after mouse-up.
        for index in fresh.indices {
            let id = fresh[index].id
            guard let prediction = predictedFrames[id] else { continue }
            let actual = fresh[index].frame
            let error = hypot(
                actual.minX - prediction.surface.frame.minX,
                actual.minY - prediction.surface.frame.minY
            )
            if prediction.isDragging || (now < prediction.expiresAt && error >= 1.5) {
                fresh[index] = prediction.surface
            } else if error < 1.5 || now >= prediction.expiresAt {
                predictedFrames.removeValue(forKey: id)
                lastPredictionTime.removeValue(forKey: id)
            }
        }

        var seen = Set<Int>()
        for surface in fresh {
            seen.insert(surface.id)
            if var entry = known[surface.id] {
                let dx = surface.frame.minX - entry.surface.frame.minX
                let dy = surface.frame.minY - entry.surface.frame.minY
                let distance = hypot(dx, dy)
                if distance >= movementEpsilon {
                    change.moved.append(MovedSurface(
                        previous: entry.surface,
                        delta: CGVector(dx: dx, dy: dy),
                        distance: distance,
                        velocity: CGVector(dx: dx / sampleDuration, dy: dy / sampleDuration),
                        sampleDuration: sampleDuration
                    ))
                    lastMovementTime = now
                }
                entry.surface = surface
                entry.lastSeen = now
                known[surface.id] = entry
            } else {
                known[surface.id] = Known(surface: surface, lastSeen: now)
            }
        }

        var ghosts: [Surface] = []
        for id in Array(known.keys) where !seen.contains(id) {
            guard let entry = known[id] else { continue }
            if now - entry.lastSeen < graceSeconds {
                ghosts.append(entry.surface)
            } else {
                change.removed.append(entry.surface)
                known.removeValue(forKey: id)
                predictedFrames.removeValue(forKey: id)
                lastPredictionTime.removeValue(forKey: id)
            }
        }

        surfaces = fresh + ghosts
        isDisplayCovered = coveredByFullScreen
        lastRefreshTime = now
        return change
    }

    // MARK: Drag prediction

    /// Returns the frontmost snow-bearing window when the pointer is in its
    /// title-bar grab area. The small left inset avoids the standard traffic lights.
    func draggableWindow(at point: CGPoint) -> Surface? {
        for surface in surfaces {
            guard surface.kind == .window, surface.frame.contains(point) else { continue }
            // Only the topmost window under the pointer may be selected. Never
            // fall through to a covered window if this one is not draggable here.
            guard surface.isTarget else { return nil }

            let frame = surface.frame
            let titleBandHeight = min(48, max(30, frame.height * 0.12))
            let leftInset = min(78, frame.width * 0.24)
            let inTitleBand = point.y >= frame.maxY - titleBandHeight && point.y <= frame.maxY - 2
            let clearOfTrafficLights = point.x >= frame.minX + leftInset
                && point.x <= frame.maxX - 12
            return (inTitleBand && clearOfTrafficLights) ? surface : nil
        }
        return nil
    }

    /// Applies a window position predicted from the global pointer at frame rate.
    /// This path avoids waiting for CGWindowListCopyWindowInfo to publish the move.
    func applyPredictedFrame(id: Int, frame: CGRect, now: TimeInterval) -> SurfaceChange {
        var change = SurfaceChange()
        guard frame.width > 8, frame.height > 8,
              let index = surfaces.firstIndex(where: { $0.id == id }) else { return change }

        let previous = surfaces[index]
        let dx = frame.minX - previous.frame.minX
        let dy = frame.minY - previous.frame.minY
        let distance = hypot(dx, dy)
        let previousSample = lastPredictionTime[id] ?? (now - 1.0 / 60.0)
        let sampleDuration = max(1.0 / 240.0, now - previousSample)

        let updated = Surface(
            id: previous.id,
            frame: frame,
            supportY: frame.maxY,
            kind: previous.kind,
            ownerName: previous.ownerName,
            isTarget: previous.isTarget
        )
        surfaces[index] = updated
        predictedFrames[id] = PredictedFrame(
            surface: updated,
            isDragging: true,
            expiresAt: .infinity
        )
        lastPredictionTime[id] = now

        if var entry = known[id] {
            entry.surface = updated
            entry.lastSeen = now
            known[id] = entry
        }

        if distance >= movementEpsilon {
            change.moved.append(MovedSurface(
                previous: previous,
                delta: CGVector(dx: dx, dy: dy),
                distance: distance,
                velocity: CGVector(dx: dx / sampleDuration, dy: dy / sampleDuration),
                sampleDuration: sampleDuration
            ))
            lastMovementTime = now
        }
        return change
    }

    /// Holds the last predicted frame briefly after release while the WindowServer
    /// snapshot catches up; refresh() drops it as soon as the real frame matches.
    func finishPredictedDrag(id: Int, now: TimeInterval) {
        guard var prediction = predictedFrames[id] else { return }
        prediction.isDragging = false
        prediction.expiresAt = now + 0.35
        predictedFrames[id] = prediction
    }

    func cancelPredictedDrag(id: Int) {
        predictedFrames.removeValue(forKey: id)
        lastPredictionTime.removeValue(forKey: id)
    }

    // MARK: Occlusion

    func isOccluded(point: CGPoint, beforeIndex index: Int) -> Bool {
        guard index > 0 else { return false }
        for position in 0..<min(index, surfaces.count) {
            let upper = surfaces[position]
            if !upper.isGround && upper.frame.contains(point) { return true }
        }
        return false
    }

    /// Merged horizontal intervals covered by surfaces in front of `index`.
    func hiddenIntervals(beforeIndex index: Int, minY: CGFloat, maxY: CGFloat) -> [SurfaceInterval] {
        guard index > 0 else { return [] }
        var raw: [SurfaceInterval] = []
        for position in 0..<min(index, surfaces.count) {
            let upper = surfaces[position]
            if upper.isGround { continue }
            if upper.frame.maxY < minY || upper.frame.minY > maxY { continue }
            raw.append(SurfaceInterval(lo: upper.frame.minX, hi: upper.frame.maxX))
        }
        guard raw.count > 1 else { return raw }

        raw.sort { $0.lo < $1.lo }
        var merged: [SurfaceInterval] = [raw[0]]
        for item in raw.dropFirst() {
            let lastIndex = merged.count - 1
            if item.lo <= merged[lastIndex].hi {
                merged[lastIndex].hi = max(merged[lastIndex].hi, item.hi)
            } else {
                merged.append(item)
            }
        }
        return merged
    }
}

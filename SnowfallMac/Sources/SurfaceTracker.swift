import AppKit

// MARK: - Surfaces snow can rest on

enum SurfaceKind {
    case window
    case dock
    case ground
}

/// A horizontal ledge: the top edge of a window, the Dock panel or the bottom edge of the display.
/// Coordinates are AppKit points local to the display, origin at the bottom-left corner.
struct Surface {
    let id: Int
    let frame: CGRect
    let supportY: CGFloat
    let kind: SurfaceKind
    let ownerName: String
    let isTarget: Bool

    var isGround: Bool { kind == .ground }
    /// Windows have rounded top corners where snow cannot rest.
    var cornerInset: CGFloat { isGround ? 0 : 12 }
    var left: CGFloat { frame.minX + cornerInset }
    var right: CGFloat { frame.maxX - cornerInset }
    var width: CGFloat { max(1, right - left) }
}

struct SurfaceInterval {
    var lo: CGFloat
    var hi: CGFloat
}

/// A surface that moved since the previous report.
struct MovedSurface {
    let previous: Surface
    let delta: CGVector
    let distance: CGFloat
    /// Points per second, averaged over the period the movement was accumulated.
    let velocity: CGVector
}

struct SurfaceChange {
    var moved: [MovedSurface] = []
    var removed: [Surface] = []
}

// MARK: - Tracker

/// Polls the window list, keeps a front-to-back list of surfaces, reports movement and removal,
/// and answers occlusion questions. It knows nothing about snow.
final class SurfaceTracker {
    private struct Known {
        var surface: Surface
        var lastSeen: TimeInterval
        var pending: CGVector
        var pendingDistance: CGFloat
        var pendingSince: TimeInterval
    }

    /// Front-to-back order. Surfaces that are briefly missing are kept at the end for a grace period.
    private(set) var surfaces: [Surface] = []
    private(set) var isDisplayCovered = false
    private(set) var lastMovementTime: TimeInterval = -100

    var finderOnly = false
    var includesBottomEdge = true

    private var known: [Int: Known] = [:]
    private var lastRefreshTime: TimeInterval = 0
    private let graceSeconds: TimeInterval = 1.25
    private let movementThreshold: CGFloat = 4

    func refresh(screen: NSScreen, size: CGSize, now: TimeInterval) -> SurfaceChange {
        var change = SurfaceChange()
        if lastRefreshTime == 0 { lastRefreshTime = now }

        var fresh: [Surface] = []
        var coveredByFullScreen = false

        for info in WindowGeometryProvider.visibleWindowSurfaces(on: screen) {
            let frame = info.frame
            let isTarget = !finderOnly || info.ownerName == "Finder"
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
            // The Dock ledge comes from Accessibility; without that permission there is no Dock ledge.
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

        var seen = Set<Int>()
        for surface in fresh {
            seen.insert(surface.id)
            if var entry = known[surface.id] {
                let dx = surface.frame.minX - entry.surface.frame.minX
                let dy = surface.frame.minY - entry.surface.frame.minY
                let step = hypot(dx, dy)
                if step > 0.01 {
                    if entry.pendingDistance == 0 { entry.pendingSince = lastRefreshTime }
                    entry.pending.dx += dx
                    entry.pending.dy += dy
                    entry.pendingDistance += step
                }
                if entry.pendingDistance >= movementThreshold {
                    let span = CGFloat(max(0.016, now - entry.pendingSince))
                    change.moved.append(MovedSurface(
                        previous: entry.surface,
                        delta: entry.pending,
                        distance: entry.pendingDistance,
                        velocity: CGVector(dx: entry.pending.dx / span, dy: entry.pending.dy / span)
                    ))
                    entry.pending = CGVector(dx: 0, dy: 0)
                    entry.pendingDistance = 0
                    lastMovementTime = now
                }
                entry.surface = surface
                entry.lastSeen = now
                known[surface.id] = entry
            } else {
                known[surface.id] = Known(
                    surface: surface,
                    lastSeen: now,
                    pending: CGVector(dx: 0, dy: 0),
                    pendingDistance: 0,
                    pendingSince: now
                )
            }
        }

        var ghosts: [Surface] = []
        for id in Array(known.keys) where !seen.contains(id) {
            guard let entry = known[id] else { continue }
            if now - entry.lastSeen < graceSeconds {
                // CGWindowList sometimes omits a window for a moment while it animates or moves.
                ghosts.append(entry.surface)
            } else {
                change.removed.append(entry.surface)
                known.removeValue(forKey: id)
            }
        }

        surfaces = fresh + ghosts
        isDisplayCovered = coveredByFullScreen
        lastRefreshTime = now
        return change
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

    /// Merged horizontal intervals covered by surfaces in front of `index`, restricted to the vertical band.
    /// One pass over the windows replaces a rectangle test per snow column.
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

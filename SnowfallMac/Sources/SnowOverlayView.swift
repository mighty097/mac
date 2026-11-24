import AppKit
import CoreGraphics
import MetalKit
import IOKit.ps

// MARK: - Rendering layers

enum SnowRenderLayer {
    case background // Behind normal application windows: distant, soft flakes only.
    case foreground // Above windows: near flakes, snowdrifts and mouse interaction.
}

struct SnowFlake {
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var alpha: CGFloat
    var phase: CGFloat
    var rotation: CGFloat
    var rotationSpeed: CGFloat
    var wobbleSpeed: CGFloat
    var wobbleAmplitude: CGFloat
    var depth: CGFloat
    var life: CGFloat // Negative means an ambient flake.
    var sourceSurfaceID: Int?
}

/// Two height fields on one ledge: loose fresh powder on top of a slowly compacting base.
final class SnowPile {
    var surface: Surface
    var fresh: [CGFloat]
    var packed: [CGFloat]

    init(surface: Surface, binCount: Int) {
        self.surface = surface
        fresh = Array(repeating: 0, count: max(1, binCount))
        packed = Array(repeating: 0, count: max(1, binCount))
    }

    var count: Int { min(fresh.count, packed.count) }

    func height(at index: Int) -> CGFloat {
        guard index >= 0, index < count else { return 0 }
        return fresh[index] + packed[index]
    }

    func resize(to newCount: Int) {
        let target = max(1, newCount)
        guard target != fresh.count else { return }
        fresh = Self.resample(fresh, to: target)
        packed = Self.resample(packed, to: target)
    }

    private static func resample(_ source: [CGFloat], to count: Int) -> [CGFloat] {
        guard !source.isEmpty else { return Array(repeating: 0, count: count) }
        if count == 1 { return [source[source.count / 2]] }
        return (0..<count).map { index in
            let t = CGFloat(index) / CGFloat(count - 1)
            let oldPosition = t * CGFloat(max(0, source.count - 1))
            let lower = min(source.count - 1, Int(oldPosition))
            let upper = min(source.count - 1, lower + 1)
            let fraction = oldPosition - CGFloat(lower)
            return source[lower] * (1 - fraction) + source[upper] * fraction
        }
    }

    func totalHeight() -> CGFloat {
        var sum: CGFloat = 0
        for index in 0..<count { sum += height(at: index) }
        return sum
    }

    func maxHeight() -> CGFloat {
        var best: CGFloat = 0
        for index in 0..<count { best = max(best, height(at: index)) }
        return best
    }
}

/// Transparent, click-through snow renderer. Uses AppKit points and a bottom-left origin.
/// AppDelegate creates one background instance and one foreground instance per display.
final class SnowOverlayView: NSView {
    // MARK: Configuration exposed to the menu bar controller

    let renderLayer: SnowRenderLayer

    var intensity: SnowIntensity = .normal {
        didSet { resizeAmbientFlakes() }
    }

    var finderOnly = false {
        didSet { tracker.finderOnly = finderOnly }
    }

    // MARK: Simulation state

    private let screen: NSScreen
    private let tracker = SurfaceTracker()
    private let binWidth: CGFloat = 4
    private let maximumBurstFlakes = 420
    private let baseWindStrength: CGFloat = 150
    private var maximumSnowHeight: CGFloat { max(8, intensity.maximumPileHeight) }

    private var ambientFlakes: [SnowFlake] = []
    private var burstFlakes: [SnowFlake] = []
    private var piles: [Int: SnowPile] = [:]
    private var output = SnowFrameOutput()
    private var metalView: SnowMetalView?

    private var isRunning = false
    private var lastTick: TimeInterval = 0
    private var lastSurfaceScan: TimeInterval = 0
    private var lastPowerCheck: TimeInterval = 0
    private var elapsed: CGFloat = 0
    private var previousMouse: CGPoint?
    private var lastHapticTime: TimeInterval = 0
    private var onBatteryPower = false
    private var lowPowerMode = false
    private var clearFadeRemaining: CGFloat = 0
    private var coveredTimer: Timer?

    private var isDarkAppearance: Bool {
        let appearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        return appearance == .darkAqua
    }

    init(frame frameRect: NSRect, screen: NSScreen, renderLayer: SnowRenderLayer = .foreground) {
        self.screen = screen
        self.renderLayer = renderLayer
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        resizeAmbientFlakes()
        if let view = SnowMetalView(size: frameRect.size) {
            view.autoresizingMask = [.width, .height]
            view.onFrame = { [weak self] in self?.tick() }
            addSubview(view)
            metalView = view
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    deinit {
        coveredTimer?.invalidate()
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let now = ProcessInfo.processInfo.systemUptime
        lastTick = now
        lastPowerCheck = now
        previousMouse = nil
        refreshPowerState(force: true)
        resizeAmbientFlakes()
        if renderLayer == .foreground {
            scanSurfaces(now: now)
            lastSurfaceScan = now
        }
        metalView?.preferredFramesPerSecond = targetFramesPerSecond
        metalView?.isPaused = false
    }

    func stop() {
        isRunning = false
        coveredTimer?.invalidate()
        coveredTimer = nil
        metalView?.isPaused = true
        ambientFlakes.removeAll(keepingCapacity: true)
        burstFlakes.removeAll(keepingCapacity: true)
        output.reset()
        metalView?.submit(output)
        metalView?.draw() // Clears the last frame.
    }

    /// Gradually melts the piles instead of removing them in one frame.
    func clearSnow() {
        clearFadeRemaining = 1.25
        for pile in piles.values {
            for index in 0..<pile.count {
                let removed = pile.fresh[index] * 0.72
                pile.fresh[index] -= removed
                pile.packed[index] = max(0, pile.packed[index] - pile.packed[index] * 0.16)
            }
        }
    }

    // MARK: Power management

    private var targetFramesPerSecond: Int {
        let displayRate = min(120, max(60, screen.maximumFramesPerSecond))
        if lowPowerMode { return 30 }
        if onBatteryPower { return min(displayRate, 60) }
        return displayRate
    }

    /// On battery or in Low Power Mode the effect is half as dense.
    private var powerScale: CGFloat {
        (onBatteryPower || lowPowerMode) ? 0.5 : 1.0
    }

    private func refreshPowerState(force: Bool) {
        let battery = isOnBatteryPower()
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard force || battery != onBatteryPower || lowPower != lowPowerMode else { return }
        onBatteryPower = battery
        lowPowerMode = lowPower
        resizeAmbientFlakes()
        metalView?.preferredFramesPerSecond = targetFramesPerSecond
    }

    private func isOnBatteryPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return false
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let state = description[kIOPSPowerSourceStateKey] as? String,
               state == kIOPSBatteryPowerValue {
                return true
            }
        }
        return false
    }

    // MARK: Particle creation and depth layers

    private func resizeAmbientFlakes() {
        let fraction: CGFloat = renderLayer == .background ? 0.36 : 0.64
        let target = max(28, Int(CGFloat(intensity.maximumParticles) * fraction * powerScale))
        if ambientFlakes.count < target {
            for _ in ambientFlakes.count..<target {
                ambientFlakes.append(makeAmbientFlake(randomY: true))
            }
        } else if ambientFlakes.count > target {
            ambientFlakes.removeLast(ambientFlakes.count - target)
        }
    }

    private func makeAmbientFlake(randomY: Bool) -> SnowFlake {
        let roll = CGFloat.random(in: 0...1)
        let depth: CGFloat
        let radius: CGFloat
        let fallSpeed: CGFloat
        let alpha: CGFloat

        if renderLayer == .background {
            depth = CGFloat.random(in: 0.34...0.60)
            radius = CGFloat.random(in: 1.4...3.3)
            fallSpeed = CGFloat.random(in: intensity.fallSpeed) * 0.72
            alpha = CGFloat.random(in: 0.24...0.53)
        } else if roll < 0.52 {
            depth = CGFloat.random(in: 0.58...0.78)
            radius = CGFloat.random(in: 3.1...5.5)
            fallSpeed = CGFloat.random(in: intensity.fallSpeed) * 0.90
            alpha = CGFloat.random(in: 0.48...0.78)
        } else {
            depth = CGFloat.random(in: 0.79...1.05)
            radius = CGFloat.random(in: 5.0...9.5)
            fallSpeed = CGFloat.random(in: intensity.fallSpeed) * 1.08
            alpha = CGFloat.random(in: 0.36...0.72)
        }

        let startY: CGFloat = randomY
            ? CGFloat.random(in: 0...max(bounds.height, 1))
            : bounds.height + CGFloat.random(in: 12...60)

        return SnowFlake(
            position: CGPoint(
                x: CGFloat.random(in: -28...max(bounds.width + 28, 29)),
                y: startY
            ),
            velocity: CGVector(dx: CGFloat.random(in: -5...5), dy: -fallSpeed),
            radius: radius,
            alpha: alpha,
            phase: CGFloat.random(in: 0...(CGFloat.pi * 2)),
            rotation: CGFloat.random(in: 0...(CGFloat.pi * 2)),
            rotationSpeed: CGFloat.random(in: -1.2...1.2),
            wobbleSpeed: CGFloat.random(in: 0.55...1.45),
            wobbleAmplitude: CGFloat.random(in: 3...11) * depth,
            depth: depth,
            life: -1,
            sourceSurfaceID: nil
        )
    }

    private func spawnPowder(at point: CGPoint, velocity: CGVector, count: Int, sourceSurfaceID: Int?) {
        for _ in 0..<count {
            guard burstFlakes.count < maximumBurstFlakes else { return }
            burstFlakes.append(SnowFlake(
                position: CGPoint(
                    x: point.x + CGFloat.random(in: -3...3),
                    y: point.y + CGFloat.random(in: -2...2)
                ),
                velocity: CGVector(
                    dx: velocity.dx + CGFloat.random(in: -34...34),
                    dy: velocity.dy + CGFloat.random(in: -24...25)
                ),
                radius: CGFloat.random(in: 3.2...7.8),
                alpha: CGFloat.random(in: 0.56...0.94),
                phase: CGFloat.random(in: 0...(CGFloat.pi * 2)),
                rotation: CGFloat.random(in: 0...(CGFloat.pi * 2)),
                rotationSpeed: CGFloat.random(in: -2.2...2.2),
                wobbleSpeed: CGFloat.random(in: 0.8...1.8),
                wobbleAmplitude: CGFloat.random(in: 3...8),
                depth: 0.88,
                life: CGFloat.random(in: 18...28),
                sourceSurfaceID: sourceSurfaceID
            ))
        }
    }

    // MARK: Wind field

    /// Smooth scalar potential. Its perpendicular gradient gives a low-cost 2-D curl field.
    private func windPotential(x: CGFloat, y: CGFloat, time: CGFloat) -> CGFloat {
        let p1 = sin(x * 0.0032 + time * 0.45) * cos(y * 0.0028 - time * 0.31)
        let p2 = 0.5 * sin((x * 0.0061 - y * 0.0053) + time * 0.72)
        let p3 = 0.25 * cos((x * 0.011 + y * 0.009) - time * 1.15)
        return p1 + p2 + p3
    }

    private func curlWind(at point: CGPoint) -> CGVector {
        let epsilon: CGFloat = 3
        let dPsiDy = (windPotential(x: point.x, y: point.y + epsilon, time: elapsed)
            - windPotential(x: point.x, y: point.y - epsilon, time: elapsed)) / (2 * epsilon)
        let dPsiDx = (windPotential(x: point.x + epsilon, y: point.y, time: elapsed)
            - windPotential(x: point.x - epsilon, y: point.y, time: elapsed)) / (2 * epsilon)
        return CGVector(
            dx: dPsiDy * baseWindStrength,
            dy: -dPsiDx * baseWindStrength * 0.42
        )
    }

    // MARK: Window and Dock surfaces

    private func scanSurfaces(now: TimeInterval) {
        guard renderLayer == .foreground else { return }
        let change = tracker.refresh(screen: screen, size: bounds.size, now: now)
        syncPiles(with: change)
    }

    private func syncPiles(with change: SurfaceChange) {
        // 1. Moved windows: snow slides against the motion and part of it is shaken off.
        for movement in change.moved {
            guard let pile = piles[movement.previous.id] else { continue }
            applyWindowMovement(movement, to: pile)
        }

        // 2. Closed windows lose all their snow.
        for removedSurface in change.removed {
            guard let pile = piles.removeValue(forKey: removedSurface.id) else { continue }
            shedPile(pile, from: removedSurface, velocity: CGVector(dx: 0, dy: 0), ratio: 1)
        }

        // 3. Create or resize piles for the current surfaces.
        var active = Set<Int>()
        for surface in tracker.surfaces where surface.isTarget {
            active.insert(surface.id)
            let binCount = max(1, Int(ceil(surface.width / binWidth)))
            if let pile = piles[surface.id] {
                pile.resize(to: binCount)
                pile.surface = surface
            } else {
                piles[surface.id] = SnowPile(surface: surface, binCount: binCount)
            }
        }
        for id in Array(piles.keys) where !active.contains(id) {
            piles.removeValue(forKey: id)
        }
    }

    private func applyWindowMovement(_ movement: MovedSurface, to pile: SnowPile) {
        let speed = hypot(movement.velocity.dx, movement.velocity.dy)

        // Inertia: snow tends to stay where it was, so relative to the window it slides backwards.
        let slide = min(60, max(-60, -movement.delta.dx * 0.42))
        if abs(slide) > 0.4 {
            slidePile(pile, bins: slide / binWidth, surface: movement.previous, velocity: movement.velocity)
        }

        // A drag shakes some off; a throw sends most of it flying.
        let distanceShare = movement.distance / 1800
        let speedShare = max(0, speed - 300) / 5000
        let ratio = min(0.9, max(0.0015, distanceShare + speedShare))
        shedPile(pile, from: movement.previous, velocity: movement.velocity, ratio: ratio)
    }

    private func slidePile(_ pile: SnowPile, bins: CGFloat, surface: Surface, velocity: CGVector) {
        guard pile.count > 2 else { return }
        let before = pile.totalHeight()
        pile.fresh = Self.shifted(pile.fresh, by: bins)
        pile.packed = Self.shifted(pile.packed, by: bins * 0.35) // Compacted snow clings to the window.
        let lost = before - pile.totalHeight()
        guard lost > 0.6 else { return }

        // What slid past the edge falls off as powder.
        let edgeX = bins > 0 ? surface.right : surface.left
        let direction: CGFloat = bins > 0 ? 1 : -1
        let count = min(6, max(1, Int(lost / 3)))
        spawnPowder(
            at: CGPoint(x: edgeX, y: surface.supportY + 2),
            velocity: CGVector(dx: direction * 36 + velocity.dx * 0.10, dy: -28),
            count: count,
            sourceSurfaceID: surface.id
        )
    }

    private static func shifted(_ source: [CGFloat], by bins: CGFloat) -> [CGFloat] {
        let count = source.count
        var result = [CGFloat](repeating: 0, count: count)
        for index in 0..<count {
            let origin = CGFloat(index) - bins
            let lower = Int(floor(origin))
            let fraction = origin - CGFloat(lower)
            let a: CGFloat = (lower >= 0 && lower < count) ? source[lower] : 0
            let b: CGFloat = (lower + 1 >= 0 && lower + 1 < count) ? source[lower + 1] : 0
            result[index] = a * (1 - fraction) + b * fraction
        }
        return result
    }

    private func shedPile(_ pile: SnowPile, from surface: Surface, velocity: CGVector, ratio: CGFloat) {
        guard ratio > 0 else { return }
        for index in 0..<pile.count {
            let height = pile.height(at: index)
            guard height > 0.12 else { continue }
            let removedFresh = pile.fresh[index] * ratio
            let packedRatio: CGFloat = ratio >= 0.999 ? 1 : ratio * 0.46
            let removedPacked = pile.packed[index] * packedRatio
            let removed = removedFresh + removedPacked
            pile.fresh[index] -= removedFresh
            pile.packed[index] -= removedPacked
            guard removed > 0.08 else { continue }

            let x = surface.left + (CGFloat(index) + 0.5) * binWidth
            let y = surface.supportY + height * 0.55
            // Snow keeps its place while the window moves, so it is thrown against the window's motion.
            let dx = min(220, max(-220, -velocity.dx * 0.30))
            let dy = min(80, max(-160, -30 - velocity.dy * 0.15))
            let count = min(6, max(1, Int(removed / 2.2)))
            spawnPowder(at: CGPoint(x: x, y: y), velocity: CGVector(dx: dx, dy: dy), count: count, sourceSurfaceID: surface.id)
        }
    }

    private func pileIndex(for x: CGFloat, on surface: Surface) -> Int {
        let raw = Int((x - surface.left) / binWidth)
        let count = piles[surface.id]?.count ?? 1
        return max(0, min(count - 1, raw))
    }

    private func depositSnow(on surface: Surface, x: CGFloat, amount: CGFloat) {
        guard let pile = piles[surface.id], pile.count > 0 else { return }
        let center = pileIndex(for: x, on: surface)
        // A Gaussian footprint makes each landing form a small rounded pillow.
        for offset in -3...3 {
            let index = center + offset
            guard index >= 0, index < pile.count else { continue }
            let weight = exp(-CGFloat(offset * offset) / 4.2)
            let freshAmount = amount * weight
            let total = pile.height(at: index)
            let accepted = min(freshAmount, max(0, maximumSnowHeight - total))
            pile.fresh[index] += accepted
        }
    }

    private func relaxPile(_ pile: SnowPile, deltaTime: CGFloat) {
        guard pile.count > 2 else { return }
        let timeScale = max(0, deltaTime * 60)
        // Avalanche relaxation: transfer only enough snow to keep a natural repose slope.
        let maxSlope: CGFloat = 1.45
        for index in 0..<(pile.count - 1) {
            let left = pile.height(at: index)
            let right = pile.height(at: index + 1)
            let difference = left - right
            if difference > maxSlope {
                let transfer = (difference - maxSlope) * 0.18 * timeScale
                let loose = min(pile.fresh[index], transfer)
                pile.fresh[index] -= loose
                pile.fresh[index + 1] += loose
            } else if difference < -maxSlope {
                let transfer = (abs(difference) - maxSlope) * 0.18 * timeScale
                let loose = min(pile.fresh[index + 1], transfer)
                pile.fresh[index + 1] -= loose
                pile.fresh[index] += loose
            }
        }
        // A tiny amount of fresh powder compacts into a denser base over time.
        for index in 0..<pile.count {
            let compaction = min(pile.fresh[index], 0.00035 * timeScale)
            pile.fresh[index] -= compaction
            pile.packed[index] += compaction
        }
    }

    private func spillPileEdges(_ pile: SnowPile, deltaTime dt: CGFloat) {
        guard pile.count > 1, dt > 0 else { return }

        let surface = pile.surface
        for index in [0, pile.count - 1] {
            let edgeHeight = pile.height(at: index)
            let overflow = max(0, edgeHeight - 1.45)
            guard overflow > 0 else { continue }

            let freshSpill = min(pile.fresh[index], overflow * dt * 0.85)
            let packedSpill = min(pile.packed[index], overflow * dt * 0.06)
            let removed = freshSpill + packedSpill
            guard removed > 0 else { continue }

            pile.fresh[index] -= freshSpill
            pile.packed[index] -= packedSpill

            if removed >= 0.05 {
                let direction: CGFloat = index == 0 ? -1 : 1
                let x = index == 0 ? surface.left : surface.right
                spawnPowder(
                    at: CGPoint(x: x, y: surface.supportY + edgeHeight * 0.55),
                    velocity: CGVector(dx: direction * 25, dy: -20),
                    count: 1,
                    sourceSurfaceID: surface.id
                )
            }
        }
    }

    // MARK: Mouse interaction: swept path, brush, soft powder and air wake

    private func currentMouseLocal() -> CGPoint {
        let global = NSEvent.mouseLocation
        return CGPoint(x: global.x - screen.frame.minX, y: global.y - screen.frame.minY)
    }

    private func applyMouseInteraction(mouse current: CGPoint, deltaTime dt: CGFloat) {
        guard let previous = previousMouse else { return }

        let dx = current.x - previous.x
        let dy = current.y - previous.y
        let distanceTravelled = hypot(dx, dy)
        guard distanceTravelled > 0.8,
              bounds.insetBy(dx: -36, dy: -36).contains(current) else { return }

        let speed = min(1200, distanceTravelled / max(dt, 0.001))
        let brushRadius = min(44, 22 + distanceTravelled * 0.22)
        let stepCount = max(1, min(24, Int(ceil(distanceTravelled / 8))))
        let swipeVelocity = CGVector(dx: dx / max(dt, 0.001) * 0.16, dy: dy / max(dt, 0.001) * 0.13)
        var removedVolume: CGFloat = 0

        let surfaces = tracker.surfaces
        for (surfaceIndex, surface) in surfaces.enumerated() where surface.isTarget {
            guard let pile = piles[surface.id], pile.count > 0 else { continue }
            let minMouseY = min(previous.y, current.y)
            let maxMouseY = max(previous.y, current.y)
            let maxPile = pile.maxHeight()
            guard maxMouseY >= surface.supportY - brushRadius,
                  minMouseY <= surface.supportY + maxPile + brushRadius else { continue }

            var changed = false
            var particleWeight: CGFloat = 0
            var particleX: CGFloat = 0
            var particleY: CGFloat = 0
            var particleVelocityX: CGFloat = 0
            var particleVelocityY: CGFloat = 0

            for sample in 0...stepCount {
                let t = CGFloat(sample) / CGFloat(stepCount)
                let cursor = CGPoint(x: previous.x + dx * t, y: previous.y + dy * t)
                guard cursor.x >= surface.left - brushRadius,
                      cursor.x <= surface.right + brushRadius else { continue }

                let first = max(0, Int((cursor.x - brushRadius - surface.left) / binWidth))
                let last = min(pile.count - 1, Int((cursor.x + brushRadius - surface.left) / binWidth))
                guard first <= last else { continue }

                for index in first...last {
                    let x = surface.left + (CGFloat(index) + 0.5) * binWidth
                    if !surface.isGround,
                       tracker.isOccluded(point: CGPoint(x: x, y: surface.supportY + 1.5), beforeIndex: surfaceIndex) { continue }
                    let total = pile.height(at: index)
                    guard total > 0.35 else { continue }
                    let crest = CGPoint(x: x, y: surface.supportY + total * 0.62)
                    let d = hypot(crest.x - cursor.x, crest.y - cursor.y)
                    guard d < brushRadius else { continue }

                    let falloff = pow(max(0, 1 - d / brushRadius), 1.65)
                    let swipePower = min(0.78, 0.16 + speed / 1800)
                    let freshRemoved = pile.fresh[index] * swipePower * falloff
                    let packedRemoved = pile.packed[index] * swipePower * falloff * min(0.78, speed / 720)
                    let removed = freshRemoved + packedRemoved
                    guard removed > 0.12 else { continue }

                    pile.fresh[index] = max(0, pile.fresh[index] - freshRemoved)
                    pile.packed[index] = max(0, pile.packed[index] - packedRemoved)
                    removedVolume += removed
                    changed = true

                    if removed > 0.55 {
                        let side: CGFloat = (dx * (crest.y - cursor.y) - dy * (crest.x - cursor.x)) >= 0 ? 1 : -1
                        let swirl = CGVector(dx: -swipeVelocity.dy * side * 0.18, dy: swipeVelocity.dx * side * 0.18)
                        let velocity = CGVector(
                            dx: swipeVelocity.dx * 0.45 + swirl.dx,
                            dy: swipeVelocity.dy * 0.30 + swirl.dy - 18
                        )
                        particleWeight += removed
                        particleX += x * removed
                        particleY += (surface.supportY + total * 0.68) * removed
                        particleVelocityX += velocity.dx * removed
                        particleVelocityY += velocity.dy * removed
                    }
                }
            }
            if particleWeight > 1.0 {
                let center = CGPoint(x: particleX / particleWeight, y: particleY / particleWeight)
                let velocity = CGVector(
                    dx: particleVelocityX / particleWeight,
                    dy: particleVelocityY / particleWeight
                )
                let particleCount = min(5, max(1, Int(particleWeight / 3.5)))
                spawnPowder(at: center, velocity: velocity, count: particleCount, sourceSurfaceID: surface.id)
            }
            if changed { relaxPile(pile, deltaTime: dt) }
        }

        // A moving hand creates a small curl in nearby ambient flakes.
        let wakeRadius: CGFloat = 76
        for index in ambientFlakes.indices {
            let offset = CGPoint(
                x: ambientFlakes[index].position.x - current.x,
                y: ambientFlakes[index].position.y - current.y
            )
            let d = hypot(offset.x, offset.y)
            guard d > 1, d < wakeRadius else { continue }
            let falloff = (1 - d / wakeRadius) * ambientFlakes[index].depth
            let side: CGFloat = (dx * offset.y - dy * offset.x) >= 0 ? 1 : -1
            let swirlX = -dy * side * 0.018
            let swirlY = dx * side * 0.018
            ambientFlakes[index].velocity.dx += (dx * 0.12 + swirlX + offset.x / d * 5) * falloff
            ambientFlakes[index].velocity.dy += (dy * 0.08 + swirlY) * falloff
        }

        let now = ProcessInfo.processInfo.systemUptime
        if removedVolume > 14, now - lastHapticTime > 0.12 {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            lastHapticTime = now
        }
    }

    // MARK: Frame loop

    private func tick() {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(0.05, max(0.001, now - lastTick)))
        lastTick = now
        elapsed += dt

        if now - lastPowerCheck > 15 {
            lastPowerCheck = now
            refreshPowerState(force: false)
        }

        if renderLayer == .foreground {
            // Poll the window list slowly, but quickly while a window is being dragged.
            let recentlyMoved = now - tracker.lastMovementTime < 0.7
            let interval: TimeInterval = recentlyMoved ? 1.0 / 30.0 : 0.12
            if now - lastSurfaceScan >= interval {
                lastSurfaceScan = now
                scanSurfaces(now: now)
            }
            if tracker.isDisplayCovered {
                enterCoveredState()
                return
            }
        }

        let mouse = currentMouseLocal()
        if renderLayer == .foreground {
            applyMouseInteraction(mouse: mouse, deltaTime: dt)
        }
        previousMouse = mouse

        updateAmbientFlakes(deltaTime: dt)
        updateBurstFlakes(deltaTime: dt)
        updatePiles(deltaTime: dt)

        buildOutput(mouse: mouse)
        metalView?.submit(output)
    }

    /// A full-screen window covers the display: draw nothing and stop the frame loop until it goes away.
    private func enterCoveredState() {
        output.reset()
        metalView?.submit(output)
        metalView?.isPaused = true
        guard coveredTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkCoveredState()
        }
        RunLoop.main.add(timer, forMode: .common)
        coveredTimer = timer
    }

    private func checkCoveredState() {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        scanSurfaces(now: now)
        guard !tracker.isDisplayCovered else { return }
        coveredTimer?.invalidate()
        coveredTimer = nil
        lastTick = now
        lastSurfaceScan = now
        metalView?.isPaused = false
    }

    private func updateAmbientFlakes(deltaTime dt: CGFloat) {
        let globalWind = sin(elapsed * 0.32) * 7 + sin(elapsed * 0.79) * 3
        for index in ambientFlakes.indices {
            var flake = ambientFlakes[index]
            let previous = flake.position
            let curl = curlWind(at: flake.position)

            flake.phase += dt * flake.wobbleSpeed
            flake.velocity.dx += (curl.dx + globalWind * flake.depth + sin(flake.phase) * flake.wobbleAmplitude) * dt
            flake.velocity.dx *= exp(-0.28 * dt)
            flake.velocity.dx = min(42, max(-42, flake.velocity.dx))
            let targetFallSpeed: CGFloat = flake.depth < 0.6 ? 25 : (flake.depth < 0.85 ? 36 : 48)
            let verticalSpeedError = -targetFallSpeed - flake.velocity.dy
            let verticalResponse = min(CGFloat(1), dt * CGFloat(0.75))
            flake.velocity.dy += verticalSpeedError * verticalResponse
            flake.rotation += flake.rotationSpeed * dt
            flake.position.x += flake.velocity.dx * dt
            flake.position.y += flake.velocity.dy * dt

            if renderLayer == .foreground,
               let landedSurface = landingSurface(from: previous, to: flake.position) {
                depositSnow(on: landedSurface, x: flake.position.x, amount: flake.radius * 0.22)
                flake = makeAmbientFlake(randomY: false)
            } else if flake.position.y < -24 {
                flake = makeAmbientFlake(randomY: false)
            } else if flake.position.x < -42 {
                flake.position.x = bounds.width + 36
            } else if flake.position.x > bounds.width + 42 {
                flake.position.x = -36
            }
            ambientFlakes[index] = flake
        }
    }

    private func landingSurface(from old: CGPoint, to new: CGPoint, excludingSurfaceID: Int? = nil) -> Surface? {
        guard new.y < old.y else { return nil }
        let surfaces = tracker.surfaces
        for (index, surface) in surfaces.enumerated() where surface.isTarget {
            if surface.id == excludingSurfaceID { continue }
            guard new.x >= surface.left, new.x <= surface.right else { continue }
            let bin = pileIndex(for: new.x, on: surface)
            let pileHeight = piles[surface.id]?.height(at: bin) ?? 0
            let top = surface.supportY + pileHeight
            guard old.y >= top, new.y <= top else { continue }
            let probe = CGPoint(x: new.x, y: surface.supportY + 1.5)
            if surface.isGround || !tracker.isOccluded(point: probe, beforeIndex: index) {
                return surface
            }
        }
        return nil
    }

    private func updateBurstFlakes(deltaTime dt: CGFloat) {
        guard !burstFlakes.isEmpty else { return }
        for index in burstFlakes.indices.reversed() {
            var flake = burstFlakes[index]
            let previous = flake.position
            flake.life -= dt
            flake.phase += dt * flake.wobbleSpeed
            let curl = curlWind(at: flake.position)

            // Strong air resistance makes swept snow drift as powder, not sparks.
            flake.velocity.dx += curl.dx * dt * 0.16
            flake.velocity.dx *= exp(-2.15 * dt)
            flake.velocity.dy += (-30 + curl.dy * 0.08) * dt
            flake.velocity.dy *= exp(-0.36 * dt)
            flake.velocity.dx = min(230, max(-230, flake.velocity.dx))
            flake.velocity.dy = min(90, max(-160, flake.velocity.dy))
            flake.rotation += flake.rotationSpeed * dt
            flake.position.x += (flake.velocity.dx + sin(flake.phase) * 7) * dt
            flake.position.y += flake.velocity.dy * dt

            if flake.velocity.dy < -8,
               let landed = landingSurface(from: previous, to: flake.position, excludingSurfaceID: flake.sourceSurfaceID) {
                depositSnow(on: landed, x: flake.position.x, amount: flake.radius * 0.13)
                burstFlakes.remove(at: index)
                continue
            }

            if flake.position.x < -12 {
                flake.position.x = -12
                flake.velocity.dx = abs(flake.velocity.dx) * 0.35
            } else if flake.position.x > bounds.width + 12 {
                flake.position.x = bounds.width + 12
                flake.velocity.dx = -abs(flake.velocity.dx) * 0.35
            }

            if flake.life <= 0 || flake.position.y < -40 {
                burstFlakes.remove(at: index)
            } else {
                burstFlakes[index] = flake
            }
        }
    }

    private func updatePiles(deltaTime dt: CGFloat) {
        guard renderLayer == .foreground else { return }
        let freshMeltFactor = exp(-dt * 0.0008)
        let packedMeltFactor = exp(-dt * 0.00018)
        for pile in piles.values {
            relaxPile(pile, deltaTime: dt)
            spillPileEdges(pile, deltaTime: dt)
            for index in 0..<pile.count {
                pile.fresh[index] *= freshMeltFactor
                pile.packed[index] *= packedMeltFactor
            }
        }
        if clearFadeRemaining > 0 {
            let fadeTime = min(dt, clearFadeRemaining)
            let fade = exp(-fadeTime * 2.6)
            for pile in piles.values {
                for index in 0..<pile.count {
                    pile.fresh[index] *= fade
                    pile.packed[index] *= fade
                }
            }
            clearFadeRemaining = max(0, clearFadeRemaining - fadeTime)
        }
    }

    // MARK: Building the frame (everything is drawn by the GPU)

    private func buildOutput(mouse: CGPoint) {
        output.reset()
        if renderLayer == .foreground {
            appendDrifts()
        }
        appendFlakes(ambientFlakes, mouse: mouse, fadesNearCursor: true)
        if renderLayer == .foreground {
            appendFlakes(burstFlakes, mouse: mouse, fadesNearCursor: false)
        }
    }

    private func appendFlakes(_ flakes: [SnowFlake], mouse: CGPoint, fadesNearCursor: Bool) {
        for flake in flakes {
            // Near flakes thin out around the cursor so they never get in the way of reading or clicking.
            var focusFade: CGFloat = 1
            if fadesNearCursor, flake.depth > 0.82 {
                let distance = hypot(flake.position.x - mouse.x, flake.position.y - mouse.y)
                let normalized = min(1, distance / 92)
                focusFade = 0.15 + 0.85 * normalized * normalized
            }
            let lifeFade: CGFloat = flake.life > 0 ? min(1, flake.life * 0.8) : 1
            let alpha = flake.alpha * focusFade * lifeFade
            guard alpha > 0.015 else { continue }

            // Tumbling flattens the flake slightly, as if it turned in 3-D.
            let squash = 0.80 + 0.20 * abs(cos(flake.rotation * 1.7))
            output.particles.append(SnowGPUInstance(
                cx: Float(flake.position.x),
                cy: Float(flake.position.y),
                hw: Float(flake.radius * squash),
                hh: Float(flake.radius),
                rotation: Float(flake.rotation),
                alpha: Float(alpha),
                softness: Float(flake.depth)
            ))
        }
    }

    private func isHidden(_ lo: CGFloat, _ hi: CGFloat, by intervals: [SurfaceInterval]) -> Bool {
        for interval in intervals where interval.lo < hi && interval.hi > lo {
            return true
        }
        return false
    }

    private func appendDrifts() {
        let surfaces = tracker.surfaces
        // Rear windows first, so the piles of front windows are drawn over them.
        for surfaceIndex in surfaces.indices.reversed() {
            let surface = surfaces[surfaceIndex]
            guard surface.isTarget, let pile = piles[surface.id], pile.count > 0 else { continue }
            let maxHeight = pile.maxHeight()
            guard maxHeight > 0.3 else { continue }

            // Mask the part of the pile covered by windows in front, without deleting the snow underneath.
            var hidden: [SurfaceInterval] = []
            if !surface.isGround {
                hidden = tracker.hiddenIntervals(
                    beforeIndex: surfaceIndex,
                    minY: surface.supportY - 3,
                    maxY: surface.supportY + maxHeight + 2
                )
            }

            var heights = [CGFloat](repeating: 0, count: pile.count)
            for index in 0..<pile.count {
                let columnLeft = surface.left + CGFloat(index) * binWidth
                if isHidden(columnLeft, columnLeft + binWidth, by: hidden) { continue }
                heights[index] = pile.height(at: index)
            }

            var runStart: Int? = nil
            for index in 0...heights.count {
                let height: CGFloat = index < heights.count ? heights[index] : 0
                if height > 0.30 {
                    if runStart == nil { runStart = index }
                } else if let start = runStart {
                    appendRun(heights: heights, range: start...(index - 1), surface: surface)
                    runStart = nil
                }
            }
            appendGlints(heights: heights, surface: surface)
        }
    }

    private func appendRun(heights: [CGFloat], range: ClosedRange<Int>, surface: Surface) {
        let baseY = surface.supportY - (surface.isGround ? 0 : 2.5)
        let firstX = surface.left + CGFloat(range.lowerBound) * binWidth
        let lastX = min(surface.right, surface.left + CGFloat(range.upperBound + 1) * binWidth)
        guard lastX > firstX else { return }

        var crest: [CGPoint] = []
        crest.append(CGPoint(x: firstX, y: baseY))
        crest.append(CGPoint(x: firstX + binWidth * 0.18, y: surface.supportY + heights[range.lowerBound] * 0.5))
        for index in range {
            let centerX = min(lastX, surface.left + (CGFloat(index) + 0.5) * binWidth)
            let ridge = sin(CGFloat(index) * 1.73 + CGFloat(surface.id) * 0.11) * 0.42
            crest.append(CGPoint(x: centerX, y: surface.supportY + heights[index] + ridge))
        }
        crest.append(CGPoint(x: lastX - binWidth * 0.18, y: surface.supportY + heights[range.upperBound] * 0.5))
        crest.append(CGPoint(x: lastX, y: baseY))

        appendDriftMesh(crest: chaikin(crest), baseY: baseY, surface: surface)
    }

    /// One round of corner cutting turns the 4-point bins into a smooth silhouette.
    private func chaikin(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result: [CGPoint] = [points[0]]
        for index in 0..<(points.count - 1) {
            let p = points[index]
            let q = points[index + 1]
            result.append(CGPoint(x: p.x * 0.75 + q.x * 0.25, y: p.y * 0.75 + q.y * 0.25))
            result.append(CGPoint(x: p.x * 0.25 + q.x * 0.75, y: p.y * 0.25 + q.y * 0.75))
        }
        result.append(points[points.count - 1])
        return result
    }

    private func appendDriftMesh(crest: [CGPoint], baseY: CGFloat, surface: Surface) {
        guard crest.count > 1 else { return }
        let dark = isDarkAppearance

        let top = dark
            ? DriftColor(r: 0.90, g: 0.94, b: 1.00, a: 0.94)
            : DriftColor(r: 1.00, g: 1.00, b: 1.00, a: 0.98)
        let bottom = dark
            ? DriftColor(r: 0.48, g: 0.60, b: 0.78, a: 0.90)
            : DriftColor(r: 0.76, g: 0.84, b: 0.94, a: 0.92)
        let topClear = DriftColor(r: top.r, g: top.g, b: top.b, a: 0)
        let rim = DriftColor(r: 1, g: 1, b: 1, a: dark ? 0.50 : 0.72)
        let rimClear = DriftColor(r: 1, g: 1, b: 1, a: 0)
        let shadowStrength: Float = dark ? 0.34 : 0.24

        for index in 0..<(crest.count - 1) {
            let p = crest[index]
            let q = crest[index + 1]
            let pBase = CGPoint(x: p.x, y: baseY)
            let qBase = CGPoint(x: q.x, y: baseY)

            // Body: bright crest fading to a cool blue where it meets the window.
            appendQuad(p, q, pBase, qBase, topLeft: top, topRight: top, bottomLeft: bottom, bottomRight: bottom)

            // Soft anti-aliased fringe above the crest.
            let pUp = CGPoint(x: p.x, y: p.y + 1.4)
            let qUp = CGPoint(x: q.x, y: q.y + 1.4)
            appendQuad(pUp, qUp, p, q, topLeft: topClear, topRight: topClear, bottomLeft: top, bottomRight: top)

            // Light catching the top of the drift.
            let pLow = CGPoint(x: p.x, y: p.y - 1.7)
            let qLow = CGPoint(x: q.x, y: q.y - 1.7)
            appendQuad(p, q, pLow, qLow, topLeft: rim, topRight: rim, bottomLeft: rimClear, bottomRight: rimClear)

            // Contact shadow on the window frame below the drift.
            if !surface.isGround {
                let pStrength = shadowStrength * Float(min(1, max(0, (p.y - baseY) / 3)))
                let qStrength = shadowStrength * Float(min(1, max(0, (q.y - baseY) / 3)))
                let pShadow = DriftColor(r: 0.10, g: 0.18, b: 0.29, a: pStrength)
                let qShadow = DriftColor(r: 0.10, g: 0.18, b: 0.29, a: qStrength)
                let clear = DriftColor(r: 0.10, g: 0.18, b: 0.29, a: 0)
                let pDeep = CGPoint(x: p.x, y: baseY - 3.6)
                let qDeep = CGPoint(x: q.x, y: baseY - 3.6)
                appendQuad(pBase, qBase, pDeep, qDeep, topLeft: pShadow, topRight: qShadow, bottomLeft: clear, bottomRight: clear)
            }
        }
    }

    private func appendQuad(
        _ topLeftPoint: CGPoint,
        _ topRightPoint: CGPoint,
        _ bottomLeftPoint: CGPoint,
        _ bottomRightPoint: CGPoint,
        topLeft: DriftColor,
        topRight: DriftColor,
        bottomLeft: DriftColor,
        bottomRight: DriftColor
    ) {
        let a = driftVertex(topLeftPoint, topLeft)
        let b = driftVertex(topRightPoint, topRight)
        let c = driftVertex(bottomLeftPoint, bottomLeft)
        let d = driftVertex(bottomRightPoint, bottomRight)
        output.drift.append(a)
        output.drift.append(b)
        output.drift.append(c)
        output.drift.append(b)
        output.drift.append(d)
        output.drift.append(c)
    }

    private func driftVertex(_ point: CGPoint, _ color: DriftColor) -> DriftVertex {
        DriftVertex(x: Float(point.x), y: Float(point.y), r: color.r, g: color.g, b: color.b, a: color.a)
    }

    /// Rare tiny crystals glint briefly inside the drift.
    private func appendGlints(heights: [CGFloat], surface: Surface) {
        let phase = Int(elapsed * 1.7) % 9
        for index in stride(from: phase, to: heights.count, by: 9) {
            guard heights[index] > 1.2 else { continue }
            let sparkle = sin(elapsed * 2.6 + CGFloat(index) * 1.7 + CGFloat(surface.id))
            guard sparkle > 0.78 else { continue }
            let x = surface.left + (CGFloat(index) + 0.5) * binWidth
            let y = surface.supportY + heights[index] * 0.64
            output.particles.append(SnowGPUInstance(
                cx: Float(x),
                cy: Float(y),
                hw: 1.3,
                hh: 1.3,
                rotation: 0,
                alpha: Float(0.26 + sparkle * 0.5),
                softness: 0.2
            ))
        }
    }
}

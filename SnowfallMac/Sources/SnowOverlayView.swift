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
    /// Physical snow volume carried by a detached grain. Zero is decorative.
    var snowMass: CGFloat
    var sourceSurfaceID: Int?
}

/// Two height fields on one ledge: loose fresh powder over a compacting base.
/// Temporary arrays are retained to avoid allocating buffers every frame.
final class SnowPile {
    var surface: Surface
    var fresh: [CGFloat]
    var packed: [CGFloat]
    /// Localized yellow tint left by the rare dog event. This is a visual
    /// surface mark, not extra snow mass; fresh snowfall gradually buries it.
    var yellow: [CGFloat]
    var freshDelta: [CGFloat]
    var packedDelta: [CGFloat]
    var yellowDelta: [CGFloat]
    var edgeDepth: [Int]
    var pendingEdgeSpill: [CGFloat] = [0, 0]
    var pendingEdgeSpillHeight: [CGFloat] = [0, 0]
    var edgeSpillCooldown: [CGFloat] = [0, 0]
    var quietTime: CGFloat = 0
    var snowAge: CGFloat = 0

    init(surface: Surface, binCount: Int) {
        self.surface = surface
        let count = max(1, binCount)
        fresh = Array(repeating: 0, count: count)
        packed = Array(repeating: 0, count: count)
        yellow = Array(repeating: 0, count: count)
        freshDelta = Array(repeating: 0, count: count)
        packedDelta = Array(repeating: 0, count: count)
        yellowDelta = Array(repeating: 0, count: count)
        edgeDepth = Array(repeating: Int.max, count: count)
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
        yellow = Self.resample(yellow, to: target)
        freshDelta = Array(repeating: 0, count: target)
        packedDelta = Array(repeating: 0, count: target)
        yellowDelta = Array(repeating: 0, count: target)
        edgeDepth = Array(repeating: Int.max, count: target)
        pendingEdgeSpill = [0, 0]
        pendingEdgeSpillHeight = [0, 0]
        edgeSpillCooldown = [0, 0]
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

/// A compact snowball that can be rolled with Shift-drag and stacked into a snowman.
private final class RollingSnowball {
    let id = UUID()
    var position: CGPoint
    var velocity = CGVector(dx: 0, dy: 0)
    var radius: CGFloat = 5
    var mass: CGFloat = 0
    var rotation: CGFloat = 0
    var isHeld = true
    var stackedOn: UUID?
    // Stable per-ball seed: the snow grain pattern must not shimmer between frames.
    let textureSeed: CGFloat

    init(position: CGPoint, textureSeed: CGFloat = CGFloat.random(in: 0...(CGFloat.pi * 2))) {
        self.position = position
        self.textureSeed = textureSeed
    }
}

/// A tiny snow-clearing machine that rolls the collected snow instead of deleting it.
private final class SnowblowerState {
    var x: CGFloat
    let direction: CGFloat
    let surfaceID: Int
    var collectedFresh: CGFloat = 0
    var collectedPacked: CGFloat = 0
    var collectedYellow: CGFloat = 0
    // Separate animation channels: the windrow rolls, while the track loop,
    // chassis suspension and blade react independently to terrain contact.
    var rotation: CGFloat = 0
    var trackPhase: CGFloat = 0
    var suspensionOffset: CGFloat = 0
    var suspensionVelocity: CGFloat = 0
    var bodyPitch: CGFloat = 0
    var bodyPitchVelocity: CGFloat = 0
    var bladePitch: CGFloat = -0.025
    var bladePitchVelocity: CGFloat = 0
    var bladeLoad: CGFloat = 0
    var bladeLoadVelocity: CGFloat = 0
    let textureSeed = CGFloat.random(in: 0...(CGFloat.pi * 2))

    init(startX: CGFloat, direction: CGFloat, surfaceID: Int) {
        self.x = startX
        self.direction = direction
        self.surfaceID = surfaceID
    }

    var collectedMass: CGFloat { collectedFresh + collectedPacked }
    var rollRadius: CGFloat { min(15.5, 2.8 + sqrt(max(0, collectedMass)) * 0.68) }
}

private enum SnowDogPhase {
    case running
    case marking
    case leaving
}

private final class SnowDogState {
    let surfaceID: Int
    let targetX: CGFloat
    var direction: CGFloat
    let exitX: CGFloat
    var x: CGFloat
    var phase: SnowDogPhase = .running
    var phaseTime: CGFloat = 0
    var markWasApplied = false
    var tailPhase: CGFloat = 0

    init(surfaceID: Int, startX: CGFloat, targetX: CGFloat, direction: CGFloat, exitX: CGFloat) {
        self.surfaceID = surfaceID
        self.x = startX
        self.targetX = targetX
        self.direction = direction
        self.exitX = exitX
    }
}

private final class SnowDogCandidate {
    weak var owner: SnowOverlayView?
    let surfaceID: Int
    let targetX: CGFloat
    let mass: CGFloat
    let timestamp: TimeInterval

    init(owner: SnowOverlayView, surfaceID: Int, targetX: CGFloat, mass: CGFloat, timestamp: TimeInterval) {
        self.owner = owner
        self.surfaceID = surfaceID
        self.targetX = targetX
        self.mass = mass
        self.timestamp = timestamp
    }
}

/// Shared between the per-display foreground overlays so only one dog visits
/// the desktop at a time, and it chooses the largest mound across monitors.
private enum SnowDogCoordinator {
    static var nextEventTime: TimeInterval = 0
    static var activeOwner: ObjectIdentifier?
    static var candidates: [ObjectIdentifier: SnowDogCandidate] = [:]
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

    var accumulateOnWindows = true {
        didSet { tracker.accumulateOnWindows = accumulateOnWindows }
    }

    var includeDesktopWidgets = false {
        didSet { tracker.includeDesktopWidgets = includeDesktopWidgets }
    }

    var windStrength: CGFloat = 1.0
    /// -2 = left, -1 = light left, 0 = variable, 1 = light right, 2 = right.
    var windDirection: Int = 0

    // MARK: Simulation state

    private let screen: NSScreen
    private let tracker = SurfaceTracker()
    private let binWidth: CGFloat = 4
    private let maximumBurstFlakes = 420
    private let baseWindStrength: CGFloat = 150

    private var ambientFlakes: [SnowFlake] = []
    private var burstFlakes: [SnowFlake] = []
    private var piles: [Int: SnowPile] = [:]
    private var output = SnowFrameOutput()
    private var metalView: SnowMetalView?

    private var isRunning = false
    private var lastTick: TimeInterval = 0
    private var lastSurfaceScan: TimeInterval = 0
    private var surfaceSamplingTimer: Timer?
    private var globalMouseMonitor: Any?
    private var lastPowerCheck: TimeInterval = 0
    private var elapsed: CGFloat = 0
    private var previousMouse: CGPoint?
    private var lastHapticTime: TimeInterval = 0
    private var onBatteryPower = false
    private var lowPowerMode = false
    private var clearFadeRemaining: CGFloat = 0
    private var persistenceAccumulator: CGFloat = 0
    private var isInteractiveTracking = false
    private var coveredTimer: Timer?

    // Input-driven window movement prediction. Global drag events update the
    // support surface immediately; the pile remains indexed in window-local x.
    private var dragCandidateID: Int?
    private var dragStartMouse: CGPoint?
    private var dragStartFrame: CGRect?
    private var dragPredictionActive = false
    private var dragDetectionAttempted = false

    // Shift-drag rolls a snowball. The ball follows the pointer, gathers mass
    // from the pile, then falls/settles when released.
    private var snowballs: [RollingSnowball] = []
    private var activeSnowball: RollingSnowball?
    private var snowballGestureActive = false
    private var lastSnowballPointer: CGPoint?
    private var lastSnowballEventTime: TimeInterval = 0

    private var snowblower: SnowblowerState?
    private var nextSnowblowerAutoTime: TimeInterval = 0
    private var nextSnowblowerDirection: CGFloat = 1
    private var snowDog: SnowDogState?
    private var lastDogCandidateScan: TimeInterval = 0
    private var cachedDogCandidate: SnowDogCandidate?

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
        surfaceSamplingTimer?.invalidate()
        coveredTimer?.invalidate()
        SnowDogCoordinator.candidates.removeValue(forKey: ObjectIdentifier(self))
        if SnowDogCoordinator.activeOwner == ObjectIdentifier(self) {
            SnowDogCoordinator.activeOwner = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let now = ProcessInfo.processInfo.systemUptime
        lastTick = now
        lastPowerCheck = now
        if nextSnowblowerAutoTime == 0 { nextSnowblowerAutoTime = now + 55 }
        previousMouse = nil
        refreshPowerState(force: true)
        resizeAmbientFlakes()
        if renderLayer == .foreground {
            scanSurfaces(now: now)
            restorePersistentSnow()
            lastSurfaceScan = now
            installGlobalMouseMonitor()
            startSurfaceSampling()
        }
        metalView?.preferredFramesPerSecond = targetFramesPerSecond
        metalView?.isPaused = false
    }

    func stop() {
        if renderLayer == .foreground { savePersistentSnow() }
        let ownerID = ObjectIdentifier(self)
        SnowDogCoordinator.candidates.removeValue(forKey: ownerID)
        if SnowDogCoordinator.activeOwner == ownerID {
            SnowDogCoordinator.activeOwner = nil
            snowDog = nil
        }
        isRunning = false
        isInteractiveTracking = false
        activeSnowball?.isHeld = false
        activeSnowball = nil
        snowballGestureActive = false
        lastSnowballPointer = nil
        if let id = dragCandidateID {
            tracker.cancelPredictedDrag(id: id)
        }
        dragCandidateID = nil
        dragStartMouse = nil
        dragStartFrame = nil
        dragPredictionActive = false
        dragDetectionAttempted = false
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        stopSurfaceSampling()
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
        snowballs.removeAll(keepingCapacity: true)
        activeSnowball = nil
        snowballGestureActive = false
        lastSnowballPointer = nil
        for pile in piles.values {
            for index in 0..<pile.count {
                let removed = pile.fresh[index] * 0.72
                pile.fresh[index] -= removed
                pile.packed[index] = max(0, pile.packed[index] - pile.packed[index] * 0.16)
                pile.yellow[index] *= 0.28
            }
        }
    }

    /// A manual sweep targets the most heavily covered visible ledge, including
    /// ordinary windows. Automatic patrols are deliberately less intrusive.
    func callSnowblower() {
        guard renderLayer == .foreground, snowblower == nil else { return }
        guard let surface = snowblowerSurface(preferSnowy: true, includeWindows: true) else { return }
        launchSnowblower(on: surface, now: ProcessInfo.processInfo.systemUptime)
    }

    /// Manual test hook: sends one dog to the largest current mound across displays.
    static func callDogNow() {
        let now = ProcessInfo.processInfo.systemUptime
        let candidate = SnowDogCoordinator.candidates.values
            .filter { now - $0.timestamp < 1.5 && $0.owner?.isRunning == true }
            .max { $0.mass < $1.mass }
        guard let candidate, let owner = candidate.owner,
              SnowDogCoordinator.activeOwner == nil else { return }
        SnowDogCoordinator.activeOwner = ObjectIdentifier(owner)
        SnowDogCoordinator.nextEventTime = now + 600
        owner.startSnowDog(on: candidate.surfaceID, targetX: candidate.targetX)
    }

    // MARK: Power management

    private var targetFramesPerSecond: Int {
        let displayRate = max(60, screen.maximumFramesPerSecond)
        // A drag is latency-sensitive: do not throttle the simulation while
        // a window is moving, even on battery or in Low Power Mode.
        if isInteractiveTracking { return displayRate }
        if lowPowerMode { return min(displayRate, 30) }
        if onBatteryPower { return min(displayRate, 30) }
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
            snowMass: 0,
            sourceSurfaceID: nil
        )
    }

    @discardableResult
    private func spawnPowder(
        at point: CGPoint,
        velocity: CGVector,
        count: Int,
        sourceSurfaceID: Int?,
        radiusRange: ClosedRange<CGFloat> = 2.0...4.8,
        massPerParticle: CGFloat = 0
    ) -> Int {
        var spawned = 0
        for _ in 0..<max(0, count) {
            guard burstFlakes.count < maximumBurstFlakes else { break }
            burstFlakes.append(SnowFlake(
                position: CGPoint(
                    x: point.x + CGFloat.random(in: -2.4...2.4),
                    y: point.y + CGFloat.random(in: -1.8...1.8)
                ),
                velocity: CGVector(
                    dx: velocity.dx + CGFloat.random(in: -22...22),
                    dy: velocity.dy + CGFloat.random(in: -16...18)
                ),
                radius: CGFloat.random(in: radiusRange),
                alpha: CGFloat.random(in: 0.56...0.94),
                phase: CGFloat.random(in: 0...(CGFloat.pi * 2)),
                rotation: CGFloat.random(in: 0...(CGFloat.pi * 2)),
                rotationSpeed: CGFloat.random(in: -2.2...2.2),
                wobbleSpeed: CGFloat.random(in: 0.8...1.8),
                wobbleAmplitude: CGFloat.random(in: 2...6),
                depth: 0.88,
                life: -1, // Detached snow persists until it lands or leaves the bottom edge.
                snowMass: max(0, massPerParticle),
                sourceSurfaceID: sourceSurfaceID
            ))
            spawned += 1
        }
        return spawned
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
        let directionalBias = CGFloat(windDirection) * 13.0
        return CGVector(
            dx: (dPsiDy * baseWindStrength + directionalBias) * windStrength,
            dy: -dPsiDx * baseWindStrength * 0.42 * windStrength
        )
    }

    // MARK: Window and Dock surfaces

    private func scanSurfaces(now: TimeInterval) {
        guard renderLayer == .foreground else { return }
        let change = tracker.refresh(screen: screen, size: bounds.size, now: now)
        syncPiles(with: change)
    }

    /// Observes the real mouse event stream from other apps. The overlay ignores
    /// mouse input, so window dragging events continue to reach the target app
    /// while this monitor receives copies of them.
    private func installGlobalMouseMonitor() {
        guard renderLayer == .foreground, globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]
        ) { [weak self] event in
            // Capture the position with the event; do not wait for the next
            // display frame to sample NSEvent.mouseLocation.
            let type = event.type
            let modifiers = event.modifierFlags
            let quartzPoint = event.cgEvent?.location
            let appKitPoint = NSEvent.mouseLocation
            if Thread.isMainThread {
                self?.handleGlobalMouseEvent(type, modifiers: modifiers, quartzPoint: quartzPoint, appKitPoint: appKitPoint)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.handleGlobalMouseEvent(type, modifiers: modifiers, quartzPoint: quartzPoint, appKitPoint: appKitPoint)
                }
            }
        }
        if globalMouseMonitor == nil {
            NSLog("[SnowfallMac] Global mouse monitor unavailable; using cursor polling fallback")
        }
    }

    private func handleGlobalMouseEvent(
        _ type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags,
        quartzPoint: CGPoint?,
        appKitPoint: CGPoint
    ) {
        guard isRunning, renderLayer == .foreground else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let point: CGPoint
        if let quartzPoint,
           let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            let quartzDisplayFrame = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
            point = CGPoint(
                x: quartzPoint.x - quartzDisplayFrame.minX,
                y: quartzDisplayFrame.maxY - quartzPoint.y
            )
        } else {
            point = CGPoint(
                x: appKitPoint.x - screen.frame.minX,
                y: appKitPoint.y - screen.frame.minY
            )
        }

        switch type {
        case .rightMouseDown:
            // Right-click removes the complete stacked snowman. The global
            // monitor observes the event without consuming the app's context menu.
            _ = removeSnowman(at: point)

        case .leftMouseDown:
            // Shift-drag is reserved for rolling a snowball. It takes priority
            // over title-bar prediction and does not consume the underlying event.
            if modifiers.contains(.shift) {
                if let oldID = dragCandidateID { tracker.cancelPredictedDrag(id: oldID) }
                dragCandidateID = nil
                dragStartMouse = nil
                dragStartFrame = nil
                dragPredictionActive = false
                dragDetectionAttempted = false
                beginSnowballRoll(at: point, now: now)
                previousMouse = point
                return
            }

            if snowballGestureActive { finishSnowballRoll(at: point) }
            snowballGestureActive = false
            activeSnowball = nil
            lastSnowballPointer = nil
            // A fresh down event always replaces stale state from an interrupted drag.
            if let oldID = dragCandidateID { tracker.cancelPredictedDrag(id: oldID) }
            dragCandidateID = nil
            dragStartMouse = nil
            dragStartFrame = nil
            dragPredictionActive = false
            dragDetectionAttempted = true
            if let candidate = tracker.draggableWindow(at: point) {
                dragCandidateID = candidate.id
                dragStartMouse = point
                dragStartFrame = candidate.frame
            }

        case .leftMouseDragged:
            if snowballGestureActive {
                updateSnowballRoll(to: point, now: now)
                previousMouse = point
                return
            }
            // The mouse-down decides which window owns the drag. Never switch
            // to a different window merely because the pointer crosses it.
            guard let id = dragCandidateID,
                  let startMouse = dragStartMouse,
                  let startFrame = dragStartFrame else { return }

            let offset = CGVector(
                dx: point.x - startMouse.x,
                dy: point.y - startMouse.y
            )
            guard dragPredictionActive || hypot(offset.dx, offset.dy) >= 2.0 else { return }
            dragPredictionActive = true

            let predicted = startFrame.offsetBy(dx: offset.dx, dy: offset.dy)
            let change = tracker.applyPredictedFrame(id: id, frame: predicted, now: now)
            if !change.moved.isEmpty {
                syncPiles(with: change)
            }

        case .leftMouseUp:
            if snowballGestureActive {
                finishSnowballRoll(at: point)
                snowballGestureActive = false
                activeSnowball = nil
                lastSnowballPointer = nil
                previousMouse = point
                return
            }
            if let id = dragCandidateID {
                if dragPredictionActive {
                    tracker.finishPredictedDrag(id: id, now: now)
                } else {
                    tracker.cancelPredictedDrag(id: id)
                }
            }
            dragCandidateID = nil
            dragStartMouse = nil
            dragStartFrame = nil
            dragPredictionActive = false
            dragDetectionAttempted = false
            previousMouse = point

        default:
            break
        }
    }

    /// Polling fallback used only if AppKit cannot create a global monitor.
    private func updateWindowDragPredictionFallback(mouse: CGPoint, now: TimeInterval) {
        let leftButtonDown = (NSEvent.pressedMouseButtons & 1) != 0
        if !leftButtonDown {
            if let id = dragCandidateID {
                if dragPredictionActive { tracker.finishPredictedDrag(id: id, now: now) }
                else { tracker.cancelPredictedDrag(id: id) }
            }
            dragCandidateID = nil
            dragStartMouse = nil
            dragStartFrame = nil
            dragPredictionActive = false
            dragDetectionAttempted = false
            return
        }
        if !dragDetectionAttempted {
            dragDetectionAttempted = true
            let previousPoint = previousMouse ?? mouse
            let candidate = tracker.draggableWindow(at: previousPoint) ?? tracker.draggableWindow(at: mouse)
            if let candidate {
                dragCandidateID = candidate.id
                dragStartMouse = previousPoint
                dragStartFrame = candidate.frame
            }
        }
        guard let id = dragCandidateID, let startMouse = dragStartMouse, let startFrame = dragStartFrame else { return }
        let offset = CGVector(dx: mouse.x - startMouse.x, dy: mouse.y - startMouse.y)
        guard dragPredictionActive || hypot(offset.dx, offset.dy) >= 2 else { return }
        dragPredictionActive = true
        let predicted = startFrame.offsetBy(dx: offset.dx, dy: offset.dy)
        let change = tracker.applyPredictedFrame(id: id, frame: predicted, now: now)
        if !change.moved.isEmpty { syncPiles(with: change) }
    }

    /// Window discovery is sampled independently of MTKView's draw callback.
    /// Live title-bar motion is predicted in tick(); this timer only refreshes
    /// window identity, z-order, occlusion and the final WindowServer position.
    private func startSurfaceSampling() {
        guard surfaceSamplingTimer == nil else { return }
        // Window-list discovery is deliberately capped at 60 Hz. Active window
        // movement comes from AppKit drag events, so repeatedly rebuilding the
        // full system window list at render rate adds cost without reducing latency.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.sampleSurfaceGeometry()
        }
        RunLoop.main.add(timer, forMode: .common)
        surfaceSamplingTimer = timer
    }

    private func stopSurfaceSampling() {
        surfaceSamplingTimer?.invalidate()
        surfaceSamplingTimer = nil
    }

    private func sampleSurfaceGeometry() {
        guard isRunning, renderLayer == .foreground, coveredTimer == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pointerPressed = NSEvent.pressedMouseButtons != 0
        let movementIsRecent = now - tracker.lastMovementTime < 0.30
        let interactive = pointerPressed || movementIsRecent

        if interactive != isInteractiveTracking {
            isInteractiveTracking = interactive
            metalView?.preferredFramesPerSecond = targetFramesPerSecond
        }

        // The global event monitor updates the dragged surface immediately.
        // This timer only discovers windows, refreshes stacking/occlusion and
        // reconciles the final WindowServer position: 60 Hz active, 20 Hz idle.
        let scanInterval: TimeInterval = interactive ? (1.0 / 60.0) : (1.0 / 10.0)
        guard now - lastSurfaceScan >= scanInterval else { return }
        scanSurfaces(now: now)
        lastSurfaceScan = now

        if tracker.isDisplayCovered {
            enterCoveredState()
        }
    }

    private func persistenceKey() -> String {
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return "snowPileState.display.\(displayID)"
    }

    private func savePersistentSnow() {
        let snapshots = piles.values.compactMap { pile -> SnowPileSnapshot? in
            guard pile.surface.kind == .ground || pile.surface.kind == .dock else { return nil }
            return SnowPileSnapshot(
                surfaceID: pile.surface.id,
                kind: pile.surface.kind == .dock ? "dock" : "ground",
                fresh: pile.fresh,
                packed: pile.packed,
                snowAge: pile.snowAge,
                yellow: pile.yellow
            )
        }
        SnowPersistence.save(snapshots, key: persistenceKey())
    }

    private func restorePersistentSnow() {
        let snapshots = SnowPersistence.load(key: persistenceKey())
        guard !snapshots.isEmpty else { return }
        for snapshot in snapshots {
            guard let pile = piles[snapshot.surfaceID] else { continue }
            let count = min(pile.count, min(snapshot.fresh.count, snapshot.packed.count))
            guard count > 0 else { continue }
            for index in 0..<count {
                pile.fresh[index] = max(0, snapshot.fresh[index])
                pile.packed[index] = max(0, snapshot.packed[index])
                if let yellow = snapshot.yellow, index < yellow.count {
                    pile.yellow[index] = min(1, max(0, yellow[index]))
                }
            }
            pile.snowAge = max(0, snapshot.snowAge)
        }
    }

    private func syncPiles(with change: SurfaceChange) {
        // 1. Moved windows: the pile remains in window-local coordinates and
        // follows the latest surface frame as one object; only a little mass sheds.
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
        // Ordinary drags should make loose snow creep and slide; a fast fling
        // should throw it farther. Use a time-based fraction so the result does
        // not depend on whether the display is running at 60, 120 or 144 Hz.
        let speed = hypot(movement.velocity.dx, movement.velocity.dy)
        guard speed > 55 else { return }
        let speedFactor = min(1, max(0, (speed - 55) / 900))
        let sheddingRate = 1.85 * speedFactor
        let ratio = 1 - exp(-sheddingRate * CGFloat(movement.sampleDuration))
        guard ratio > 0.00001 else { return }
        shedPile(pile, from: movement.previous, velocity: movement.velocity, ratio: ratio)
    }

    private func shedPile(_ pile: SnowPile, from surface: Surface, velocity: CGVector, ratio: CGFloat) {
        guard ratio > 0, pile.count > 0 else { return }

        let clusterSize = 10
        let packedRatio = ratio * 0.12
        let dx = min(260, max(-260, -velocity.dx * 0.48))
        let dy = min(90, max(-180, -24 - velocity.dy * 0.18))

        for clusterStart in stride(from: 0, to: pile.count, by: clusterSize) {
            let clusterEnd = min(pile.count, clusterStart + clusterSize)
            var removals: [(index: Int, fresh: CGFloat, packed: CGFloat)] = []
            var totalRemoved: CGFloat = 0
            var weightedX: CGFloat = 0
            var weightedY: CGFloat = 0

            for index in clusterStart..<clusterEnd {
                let height = pile.height(at: index)
                guard height > 0.12 else { continue }

                // A moving window leaves the snow's inertia behind. Bias the
                // sliding toward the trailing edge instead of dusting the whole
                // ledge uniformly: rightward motion sheds left, and vice versa.
                let position = CGFloat(index) / CGFloat(max(1, pile.count - 1))
                let trailingSide = velocity.dx >= 0 ? (1 - position) : position
                let lateralBias = abs(velocity.dx) > abs(velocity.dy) * 0.65
                    ? (0.30 + 1.35 * trailingSide * trailingSide)
                    : 1.0
                let localLooseRatio = min(1, ratio * lateralBias)
                let localPackedRatio = min(1, packedRatio * lateralBias)
                let removedFresh = pile.fresh[index] * localLooseRatio
                let removedPacked = pile.packed[index] * localPackedRatio
                let removed = removedFresh + removedPacked
                guard removed > 0.001 else { continue }

                let x = surface.left + (CGFloat(index) + 0.5) * binWidth
                let y = surface.supportY + height * 0.55
                removals.append((index, removedFresh, removedPacked))
                totalRemoved += removed
                weightedX += x * removed
                weightedY += y * removed
            }

            // Tiny amounts stay in the pile; a full-size cloud is never emitted
            // for less snow than the cloud can visually represent.
            guard totalRemoved >= 0.24, !removals.isEmpty else { continue }
            let requestedCount = min(3, max(1, Int(ceil(totalRemoved / 1.9))))
            let spawned = spawnPowder(
                at: CGPoint(x: weightedX / totalRemoved, y: weightedY / totalRemoved),
                velocity: CGVector(dx: dx, dy: dy),
                count: requestedCount,
                sourceSurfaceID: surface.id,
                radiusRange: 1.25...2.55,
                massPerParticle: totalRemoved / CGFloat(requestedCount)
            )
            guard spawned > 0 else { break }

            // If the particle pool is full, remove only the mass represented
            // by the particles that were actually created.
            let representedRatio = min(1, CGFloat(spawned) / CGFloat(requestedCount))
            for removal in removals {
                pile.fresh[removal.index] = max(0, pile.fresh[removal.index] - removal.fresh * representedRatio)
                pile.packed[removal.index] = max(0, pile.packed[removal.index] - removal.packed * representedRatio)
            }
        }
    }
    private func pileIndex(for x: CGFloat, on surface: Surface) -> Int {
        let raw = Int((x - surface.left) / binWidth)
        let count = piles[surface.id]?.count ?? 1
        return max(0, min(count - 1, raw))
    }

    private func depositSnow(on surface: Surface, x: CGFloat, amount: CGFloat) {
        guard let pile = piles[surface.id], pile.count > 0, amount > 0 else { return }
        let center = pileIndex(for: x, on: surface)
        pile.quietTime = 0

        // The landing footprint depends on the support: glass keeps a narrow
        // ridge, Dock produces a modest rounded pillow, and ground spreads it.
        // Normalize weights so depositing a grain cannot manufacture extra mass.
        let radius = surface.depositionRadius
        var samples: [(index: Int, weight: CGFloat)] = []
        var totalWeight: CGFloat = 0
        for offset in -radius...radius {
            let index = center + offset
            guard index >= 0, index < pile.count else { continue }
            let sigma: CGFloat = surface.kind == .ground ? 2.5 : (surface.kind == .dock ? 1.75 : 1.25)
            let weight = exp(-CGFloat(offset * offset) / (2 * sigma * sigma))
            samples.append((index, weight))
            totalWeight += weight
        }
        guard totalWeight > 0 else { return }
        for sample in samples {
            pile.fresh[sample.index] += amount * sample.weight / totalWeight
            // New white snow gradually buries the small yellow surface mark.
            pile.yellow[sample.index] *= exp(-amount * 0.22)
        }
    }

    private func relaxPile(_ pile: SnowPile, deltaTime: CGFloat) {
        guard pile.count > 2 else { return }
        let count = pile.count
        let dt = min(0.05, max(0, deltaTime))
        guard dt > 0 else { return }
        let timeScale = min(3, dt * 60)
        // Angle-of-repose thresholds in the pile's height units per bin.
        // Loose powder starts sliding at a gentler slope than compacted snow.
        let looseReposeSlope = pile.surface.looseReposeSlope
        let packedReposeSlope = pile.surface.packedReposeSlope
        let looseFlowRate = pile.surface.looseFlowRate
        let packedFlowRate = pile.surface.packedFlowRate

        for index in 0..<count {
            pile.freshDelta[index] = 0
            pile.packedDelta[index] = 0
        }

        // Build a distance map around every contiguous snow patch. The slope
        // extends into empty neighbouring bins, so a narrow tall pile can spread
        // sideways instead of becoming a vertical block. Its width grows with height.
        for index in 0..<count { pile.edgeDepth[index] = Int.max }
        let edgeRisePerBin = pile.surface.edgeRisePerBin
        var runStart: Int? = nil
        for cursor in 0...count {
            let occupied = cursor < count && pile.height(at: cursor) > 0.08
            if occupied && runStart == nil {
                runStart = cursor
            } else if !occupied, let start = runStart {
                let end = cursor - 1
                var runMaxHeight: CGFloat = 0
                for index in start...end { runMaxHeight = max(runMaxHeight, pile.height(at: index)) }
                let neededBins = min(
                    count - 1,
                    max(2, Int(ceil(pow(max(0.01, runMaxHeight / edgeRisePerBin), 1.0 / 0.78))) + 2)
                )
                let leftBound = max(0, start - neededBins)
                let rightBound = min(count - 1, end + neededBins)
                if leftBound <= rightBound {
                    for index in leftBound...rightBound {
                        let depth = min(index - leftBound, rightBound - index)
                        pile.edgeDepth[index] = min(pile.edgeDepth[index], depth)
                    }
                }
                runStart = nil
            }
        }

        func edgeCap(_ index: Int) -> CGFloat? {
            let depth = pile.edgeDepth[index]
            guard depth != Int.max else { return nil }
            return edgeRisePerBin * pow(CGFloat(depth + 1), 0.78)
        }

        // Calculate neighbour transfers from the same frame snapshot. This
        // avoids the old left-to-right bias when many bins are steep at once.
        for index in 0..<(count - 1) {
            let left = pile.height(at: index)
            let right = pile.height(at: index + 1)
            let difference = left - right
            guard abs(difference) > looseReposeSlope else { continue }

            let donor = difference > 0 ? index : index + 1
            let receiver = difference > 0 ? index + 1 : index
            let slopeExcess = abs(difference) - looseReposeSlope
            var looseFlow = min(
                pile.fresh[donor] * min(0.46, looseFlowRate * timeScale),
                slopeExcess * looseFlowRate * 0.84 * timeScale
            )
            if let cap = edgeCap(receiver) {
                looseFlow = min(looseFlow, max(0, cap - pile.height(at: receiver)))
            }
            if looseFlow > 0 {
                pile.freshDelta[donor] -= looseFlow
                pile.freshDelta[receiver] += looseFlow
            }

            let packedExcess = max(0, abs(difference) - packedReposeSlope)
            if packedExcess > 0 {
                var packedFlow = min(
                    pile.packed[donor] * min(0.14, packedFlowRate * timeScale),
                    packedExcess * packedFlowRate * timeScale
                )
                if let cap = edgeCap(receiver) {
                    let heightAfterLoose = pile.height(at: receiver) + looseFlow
                    packedFlow = min(packedFlow, max(0, cap - heightAfterLoose))
                }
                if packedFlow > 0 {
                    pile.packedDelta[donor] -= packedFlow
                    pile.packedDelta[receiver] += packedFlow
                }
            }
        }

        // Move excess mass inward from both ends of every contiguous patch.
        // Because this uses delta buffers, left and right edges are symmetric.
        for index in 0..<count {
            let depth = pile.edgeDepth[index]
            guard depth != Int.max else { continue }
            let nextDepth = depth + 1
            var inward: Int?
            if index > 0 && pile.edgeDepth[index - 1] == nextDepth {
                inward = index - 1
            } else if index + 1 < count && pile.edgeDepth[index + 1] == nextDepth {
                inward = index + 1
            }
            guard let inward else { continue }

            let cap = CGFloat(depth + 1) * edgeRisePerBin
            let excess = max(0, pile.height(at: index) - cap)
            guard excess > 0 else { continue }

            let freshMove = min(pile.fresh[index], excess * min(0.035, dt * 0.72))
            let remaining = max(0, excess - freshMove)
            let packedMove = min(pile.packed[index], remaining * min(0.008, dt * 0.10))
            pile.freshDelta[index] -= freshMove
            pile.freshDelta[inward] += freshMove
            pile.packedDelta[index] -= packedMove
            pile.packedDelta[inward] += packedMove
        }

        for index in 0..<count {
            pile.fresh[index] = max(0, pile.fresh[index] + pile.freshDelta[index])
            pile.packed[index] = max(0, pile.packed[index] + pile.packedDelta[index])
            let depthFactor = min(2.2, 0.7 + pile.height(at: index) / 18)
            let compaction = min(pile.fresh[index], pile.surface.compactionRate * depthFactor * timeScale)
            pile.fresh[index] -= compaction
            pile.packed[index] += compaction
        }
    }

    private func spillPileEdges(_ pile: SnowPile, deltaTime dt: CGFloat) {
        guard pile.count > 5, dt > 0 else { return }
        let surface = pile.surface
        let edgeGroups: [(indices: [Int], spillIndex: Int, direction: CGFloat, edgeNumber: Int)] = [
            (Array(0..<3), 0, -1, 0),
            (Array((pile.count - 3)..<pile.count), pile.count - 1, 1, 1)
        ]

        for group in edgeGroups {
            pile.edgeSpillCooldown[group.edgeNumber] = max(0, pile.edgeSpillCooldown[group.edgeNumber] - dt)
            var removedThisStep: CGFloat = 0
            var weightedHeight: CGFloat = 0
            for index in group.indices {
                let proximity: CGFloat = index == group.spillIndex ? 1.0 : (index == (group.edgeNumber == 0 ? 1 : pile.count - 2) ? 0.34 : 0.12)
                let height = pile.height(at: index)
                let exposed = max(0, height - 0.10)
                guard exposed > 0 else { continue }

                // A window ledge should visibly shed its exposed powder. The
                // compacted layer moves too, but at a much lower rate.
                let freshRate = min(pile.fresh[index] * 0.022, exposed * dt * 1.35 * proximity)
                let packedRate = min(pile.packed[index] * 0.004, max(0, height - 0.60) * dt * 0.20 * proximity)
                let removed = freshRate + packedRate
                guard removed > 0 else { continue }
                pile.fresh[index] -= freshRate
                pile.packed[index] -= packedRate
                removedThisStep += removed
                weightedHeight += height * removed
            }

            if removedThisStep > 0 {
                pile.pendingEdgeSpill[group.edgeNumber] += removedThisStep
                pile.pendingEdgeSpillHeight[group.edgeNumber] += weightedHeight
            }

            let emissionMass: CGFloat = 0.24
            guard pile.pendingEdgeSpill[group.edgeNumber] >= emissionMass,
                  pile.edgeSpillCooldown[group.edgeNumber] <= 0 else { continue }
            let queuedMass = pile.pendingEdgeSpill[group.edgeNumber]
            let averageHeight = pile.pendingEdgeSpillHeight[group.edgeNumber] / max(0.001, queuedMass)
            let x = (group.direction < 0 ? surface.left : surface.right) + group.direction * 1.6
            let speed: CGFloat = surface.ownerName == "Dock" ? 118 : 92
            let spawned = spawnPowder(
                at: CGPoint(x: x, y: surface.supportY + max(0.5, averageHeight) * 0.78),
                velocity: CGVector(dx: group.direction * speed, dy: -24),
                count: 1,
                sourceSurfaceID: surface.id,
                radiusRange: 1.20...1.95,
                massPerParticle: emissionMass
            )
            if spawned > 0 {
                let consumedFraction = min(1, emissionMass / max(0.001, queuedMass))
                pile.pendingEdgeSpill[group.edgeNumber] = max(0, queuedMass - emissionMass)
                pile.pendingEdgeSpillHeight[group.edgeNumber] *= (1 - consumedFraction)
                pile.edgeSpillCooldown[group.edgeNumber] = 0.14 // At most ~7 small grains/sec per side.
            }
        }
    }

    /// Window tops are narrow ledges, not deep snow fields. Excess above the
    /// soft profile is routed into the left/right runoff queues and then exits
    /// as the same small falling powder used by ordinary edge shedding.
    private func drainOvergrownSurfaceSnow(_ pile: SnowPile, deltaTime dt: CGFloat) {
        guard dt > 0, pile.count > 5 else { return }
        let heightLimit: CGFloat
        switch pile.surface.kind {
        case .window: heightLimit = 16.0
        case .dock: heightLimit = 9.5
        case .ground: return
        }

        // Smoothly drain only the amount above the soft height. Fresh snow is
        // released first; dense base snow resists the blade and drains slower.
        let drainFraction = min(0.065, dt * 1.15)
        for index in 0..<pile.count {
            let height = pile.height(at: index)
            let excess = height - heightLimit
            guard excess > 0.015 else { continue }
            let budget = excess * drainFraction
            let freshOut = min(pile.fresh[index], budget * 0.88)
            let packedOut = min(pile.packed[index], max(0, budget - freshOut) * 0.35)
            let removed = freshOut + packedOut
            guard removed > 0 else { continue }

            pile.fresh[index] -= freshOut
            pile.packed[index] -= packedOut
            let side = index < pile.count / 2 ? 0 : 1
            pile.pendingEdgeSpill[side] += removed
            pile.pendingEdgeSpillHeight[side] += removed * height
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

        let speed = min(2200, distanceTravelled / max(dt, 0.001))
        let brushRadius = min(46, 23 + distanceTravelled * 0.18)
        let segmentLengthSquared = max(1, dx * dx + dy * dy)
        let pushFraction = min(0.48, 0.17 + speed / 4300)
        let packedFraction = min(0.13, 0.025 + speed / 14000)
        // A firm, quick stroke becomes a physical impulse. Gentle movement
        // still only compresses and moves the snow; a fling releases powder.
        let normalizedImpulse = min(1, max(0, (speed - 360) / 1200))
        let flingStrength = normalizedImpulse * normalizedImpulse * (3 - 2 * normalizedImpulse) * 0.88
        let packedFlingStrength = flingStrength * 0.24
        var movedVolume: CGFloat = 0

        let surfaces = tracker.surfaces
        for (surfaceIndex, surface) in surfaces.enumerated() where surface.isTarget {
            guard let pile = piles[surface.id], pile.count > 0 else { continue }
            var surfaceMovedVolume: CGFloat = 0
            var flingRecords: [(target: Int, fresh: CGFloat, packed: CGFloat, x: CGFloat, y: CGFloat)] = []
            var totalFlingMass: CGFloat = 0
            var weightedX: CGFloat = 0
            var weightedY: CGFloat = 0

            // The pile relaxation step also uses these buffers. Clear the old
            // frame's values before writing this cursor-driven transfer.
            for index in 0..<pile.count {
                pile.freshDelta[index] = 0
                pile.packedDelta[index] = 0
                pile.yellowDelta[index] = 0
            }
            let minMouseY = min(previous.y, current.y)
            let maxMouseY = max(previous.y, current.y)
            guard maxMouseY >= surface.supportY - brushRadius,
                  minMouseY <= surface.supportY + pile.maxHeight() + brushRadius else { continue }
            let minX = min(previous.x, current.x) - brushRadius
            let maxX = max(previous.x, current.x) + brushRadius
            let firstIndex = max(0, Int((minX - surface.left) / binWidth))
            let lastIndex = min(pile.count - 1, Int((maxX - surface.left) / binWidth))
            guard firstIndex <= lastIndex else { continue }

            for index in firstIndex...lastIndex {
                let x = surface.left + (CGFloat(index) + 0.5) * binWidth
                if !surface.isGround,
                   tracker.isOccluded(point: CGPoint(x: x, y: surface.supportY + 1.5), beforeIndex: surfaceIndex) { continue }

                let total = pile.height(at: index)
                guard total > 0.28 else { continue }
                let crestY = surface.supportY + total * 0.58

                // Find the closest point on the full cursor segment. Each bin is
                // processed once, so long swipes cannot multiply the removed mass.
                let projection = min(1, max(0, ((x - previous.x) * dx + (crestY - previous.y) * dy) / segmentLengthSquared))
                let closestX = previous.x + dx * projection
                let closestY = previous.y + dy * projection
                let distance = hypot(x - closestX, crestY - closestY)
                guard distance < brushRadius else { continue }

                let falloff = pow(max(0, 1 - distance / brushRadius), 1.35)
                let freshMove = min(pile.fresh[index], pile.fresh[index] * pushFraction * falloff)
                let packedMove = min(pile.packed[index], pile.packed[index] * packedFraction * falloff)
                let yellowMove = min(pile.yellow[index], pile.yellow[index] * pushFraction * falloff * 0.72)
                let moved = freshMove + packedMove
                guard moved > 0.035 else { continue }

                // A horizontal stroke acts like a small snowplough: it pushes
                // the snow ahead of the hand. A vertical stroke splits the flow
                // away from the centre line, leaving a trough with two side banks.
                let direction: CGFloat
                if abs(dx) > max(1.8, abs(dy) * 0.30) {
                    direction = dx >= 0 ? 1 : -1
                } else {
                    direction = x < closestX ? -1 : 1
                }
                let offsetBins = max(2, min(12, Int((brushRadius * 0.62 / binWidth).rounded())))
                let target = max(0, min(pile.count - 1, index + Int(direction) * offsetBins))
                if target == index && flingStrength < 0.08 { continue }

                // First transfer the entire moved amount to the receiving bank.
                // After the emitter confirms how many grains were created, only
                // that represented fraction is removed from the bank and launched.
                pile.freshDelta[index] -= freshMove
                pile.freshDelta[target] += freshMove
                pile.packedDelta[index] -= packedMove
                pile.packedDelta[target] += packedMove
                pile.yellowDelta[index] -= yellowMove
                pile.yellowDelta[target] += yellowMove

                let flingFresh = freshMove * flingStrength
                let flingPacked = packedMove * packedFlingStrength
                let flingMass = flingFresh + flingPacked
                if flingMass > 0.005 {
                    flingRecords.append((target, flingFresh, flingPacked, x, surface.supportY + total * 0.55))
                    totalFlingMass += flingMass
                    weightedX += x * flingMass
                    weightedY += (surface.supportY + total * 0.55) * flingMass
                }
                surfaceMovedVolume += moved
                movedVolume += moved
            }

            if totalFlingMass > 0.12 {
                let targetParticleMass: CGFloat = 0.26
                let requestedCount = min(18, max(1, Int(ceil(totalFlingMass / targetParticleMass))))
                let particleMass = totalFlingMass / CGFloat(requestedCount)
                let directionLength = max(1, distanceTravelled)
                let launchVelocity = CGVector(
                    dx: (dx / directionLength) * min(980, speed * 0.46),
                    dy: (dy / directionLength) * min(620, speed * 0.34) + 38 + min(92, speed * 0.055)
                )
                let spawned = spawnPowder(
                    at: CGPoint(x: weightedX / totalFlingMass, y: weightedY / totalFlingMass),
                    velocity: launchVelocity,
                    count: requestedCount,
                    sourceSurfaceID: surface.id,
                    radiusRange: 1.30...2.65,
                    massPerParticle: particleMass
                )
                let representedMass = min(totalFlingMass, CGFloat(spawned) * particleMass)
                let representedRatio = representedMass / max(0.001, totalFlingMass)
                if representedRatio > 0 {
                    for record in flingRecords {
                        pile.freshDelta[record.target] -= record.fresh * representedRatio
                        pile.packedDelta[record.target] -= record.packed * representedRatio
                    }
                }
            }

            if surfaceMovedVolume > 0 {
                for index in 0..<pile.count {
                    pile.fresh[index] = max(0, pile.fresh[index] + pile.freshDelta[index])
                    pile.packed[index] = max(0, pile.packed[index] + pile.packedDelta[index])
                    pile.yellow[index] = min(1, max(0, pile.yellow[index] + pile.yellowDelta[index]))
                    pile.freshDelta[index] = 0
                    pile.packedDelta[index] = 0
                    pile.yellowDelta[index] = 0
                }
                pile.quietTime = 0
                relaxPile(pile, deltaTime: dt)
            } else {
                // Keep the reusable transfer buffers clean even if the cursor
                // passed through an empty section of a surface.
                for index in 0..<pile.count {
                    pile.freshDelta[index] = 0
                    pile.packedDelta[index] = 0
                    pile.yellowDelta[index] = 0
                }
            }
        }

        // A small wake accompanies the physical transfer. Strong strokes already
        // have real detached particles above, so this stays subtle and fine-grained.
        if movedVolume > 1.2 {
            let direction = dx >= 0 ? 1.0 : -1.0
            _ = spawnPowder(
                at: CGPoint(x: current.x - direction * 4, y: current.y + 3),
                velocity: CGVector(dx: direction * min(48, speed * 0.035), dy: 8),
                count: min(2, max(1, Int(movedVolume / 12))),
                sourceSurfaceID: nil,
                radiusRange: 1.0...1.8
            )
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
        if movedVolume > 14, now - lastHapticTime > 0.12 {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            lastHapticTime = now
        }
    }

    // MARK: Rolling snowballs

    /// Removes the whole stacked assembly when the user right-clicks any ball.
    /// Loose single snowballs are deliberately left alone.
    @discardableResult
    private func removeSnowman(at point: CGPoint) -> Bool {
        // Written as an explicit loop, not a map/filter/min chain: the chained-closure
        // tuple form made the Swift type-checker time out during Release (-O) builds.
        var bestBall: RollingSnowball?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for ball in snowballs {
            let distance = hypot(ball.position.x - point.x, ball.position.y - point.y)
            guard distance <= ball.radius * 0.92 + 2, distance < bestDistance else { continue }
            bestDistance = distance
            bestBall = ball
        }
        guard let hit = bestBall else { return false }

        let hasChild = snowballs.contains { $0.stackedOn == hit.id }
        guard hit.stackedOn != nil || hasChild else { return false }

        var component = Set<UUID>([hit.id])
        var expanded = true
        while expanded {
            expanded = false
            for ball in snowballs {
                if let parentID = ball.stackedOn, component.contains(parentID), component.insert(ball.id).inserted {
                    expanded = true
                }
                if component.contains(ball.id), let parentID = ball.stackedOn,
                   component.insert(parentID).inserted {
                    expanded = true
                }
            }
        }

        let removed = snowballs.filter { component.contains($0.id) }
        guard removed.count >= 2 else { return false }
        for ball in removed {
            let puffCount = min(18, max(5, Int(ball.radius * 0.42)))
            _ = spawnPowder(
                at: ball.position,
                velocity: CGVector(dx: 0, dy: 17),
                count: puffCount,
                sourceSurfaceID: nil,
                radiusRange: 1.0...2.5
            )
        }
        snowballs.removeAll { component.contains($0.id) }
        if let activeSnowball, component.contains(activeSnowball.id) {
            self.activeSnowball = nil
            snowballGestureActive = false
            lastSnowballPointer = nil
        }
        return true
    }

    /// Menu action counterpart to right-click: remove all assembled snowmen,
    /// while preserving loose snowballs that have not been stacked.
    func removeAllSnowmen() {
        let parentIDs = Set(snowballs.compactMap(\.stackedOn))
        let assemblyIDs = Set(snowballs.compactMap { ball -> UUID? in
            (ball.stackedOn != nil || parentIDs.contains(ball.id)) ? ball.id : nil
        })
        guard !assemblyIDs.isEmpty else { return }
        let removed = snowballs.filter { assemblyIDs.contains($0.id) }
        for ball in removed {
            _ = spawnPowder(
                at: ball.position,
                velocity: CGVector(dx: 0, dy: 14),
                count: min(14, max(4, Int(ball.radius * 0.34))),
                sourceSurfaceID: nil,
                radiusRange: 1.0...2.3
            )
        }
        snowballs.removeAll { assemblyIDs.contains($0.id) }
        if let activeSnowball, assemblyIDs.contains(activeSnowball.id) {
            self.activeSnowball = nil
            snowballGestureActive = false
            lastSnowballPointer = nil
        }
    }

    private func beginSnowballRoll(at point: CGPoint, now: TimeInterval) {
        let startPoint = constrainedSnowballPoint(point, radius: 8)
        let existing = snowballs
            .filter { hypot($0.position.x - startPoint.x, $0.position.y - startPoint.y) <= $0.radius * 1.35 }
            .min { $0.radius < $1.radius }

        let ball: RollingSnowball
        if let existing {
            ball = existing
            // Detach any smaller ball stacked on the one being picked up.
            for child in snowballs where child.stackedOn == ball.id {
                child.stackedOn = nil
                child.velocity = CGVector(dx: 0, dy: 0)
            }
            ball.stackedOn = nil
        } else {
            if snowballs.count >= 18 {
                // Recycle the smallest idle ball instead of growing without bound.
                let recyclable = snowballs.filter { !$0.isHeld }.min { $0.mass < $1.mass }
                if let recyclable {
                    snowballs.removeAll { $0.id == recyclable.id }
                } else {
                    return
                }
            }
            ball = RollingSnowball(position: startPoint)
            snowballs.append(ball)
        }

        ball.position = constrainedSnowballPoint(startPoint, radius: ball.radius)
        ball.velocity = CGVector(dx: 0, dy: 0)
        ball.isHeld = true
        activeSnowball = ball
        snowballGestureActive = true
        lastSnowballPointer = point
        lastSnowballEventTime = now
    }

    private func updateSnowballRoll(to point: CGPoint, now: TimeInterval) {
        guard let ball = activeSnowball else { return }
        let previous = lastSnowballPointer ?? point
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        let distance = hypot(dx, dy)
        let dt = max(1.0 / 240.0, now - lastSnowballEventTime)
        if distance > 0.1 {
            let steps = max(1, min(20, Int(ceil(distance / 5))))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let rawSample = CGPoint(x: previous.x + dx * t, y: previous.y + dy * t)
                let sample = constrainedSnowballPoint(rawSample, radius: ball.radius)
                collectSnow(into: ball, at: sample)
                ball.position = constrainedSnowballPoint(sample, radius: ball.radius)
            }
            // Keep only a little rolling inertia. A quick pointer gesture must not
            // turn a snowball into a projectile that leaves the display.
            ball.velocity = CGVector(
                dx: min(42, max(-42, dx / CGFloat(dt) * 0.045)),
                dy: min(16, max(-16, dy / CGFloat(dt) * 0.018))
            )
            ball.rotation += distance / max(5, ball.radius)
        }
        lastSnowballPointer = point
        lastSnowballEventTime = now
    }

    private func collectSnow(into ball: RollingSnowball, at point: CGPoint) {
        let surfaces = tracker.surfaces
        var collected: CGFloat = 0
        for (surfaceIndex, surface) in surfaces.enumerated() where surface.isTarget {
            var surfaceCollected: CGFloat = 0
            guard point.x >= surface.left - ball.radius, point.x <= surface.right + ball.radius,
                  let pile = piles[surface.id], pile.count > 0 else { continue }
            let searchRadius = ball.radius * 1.25 + 8
            let first = max(0, Int((point.x - searchRadius - surface.left) / binWidth))
            let last = min(pile.count - 1, Int((point.x + searchRadius - surface.left) / binWidth))
            guard first <= last else { continue }

            for index in first...last {
                let x = surface.left + (CGFloat(index) + 0.5) * binWidth
                if !surface.isGround,
                   tracker.isOccluded(point: CGPoint(x: x, y: surface.supportY + 1.5), beforeIndex: surfaceIndex) { continue }
                let height = pile.height(at: index)
                guard height > 0.25 else { continue }
                let topY = surface.supportY + height * 0.58
                let distance = hypot(x - point.x, topY - point.y)
                guard distance < searchRadius else { continue }
                let falloff = pow(max(0, 1 - distance / searchRadius), 1.6)
                let fresh = min(pile.fresh[index], pile.fresh[index] * 0.20 * falloff)
                let packed = min(pile.packed[index], pile.packed[index] * 0.045 * falloff)
                pile.fresh[index] -= fresh
                pile.packed[index] -= packed
                let amount = fresh + packed
                collected += amount
                surfaceCollected += amount
                if amount > 0.02 { pile.quietTime = 0 }
            }
            if surfaceCollected > 0 { relaxPile(pile, deltaTime: 1.0 / 60.0) }
        }

        if collected > 0 {
            ball.mass += collected
            ball.radius = min(38, 7 + sqrt(ball.mass) * 1.85)
            ball.position = constrainedSnowballPoint(ball.position, radius: ball.radius)
        }
    }

    private func finishSnowballRoll(at point: CGPoint) {
        guard let ball = activeSnowball else { return }
        ball.position = constrainedSnowballPoint(point, radius: ball.radius)
        ball.isHeld = false
        // A Shift-click in an empty area should not leave a decorative bead.
        guard ball.mass >= 0.18 else {
            snowballs.removeAll { $0.id == ball.id }
            return
        }

        // Releasing is a careful drop, not a throw. The pointer's event speed
        // must not be converted into projectile velocity.
        ball.velocity = CGVector(dx: 0, dy: 0)
        if !snapSnowballOntoLargerBall(ball) {
            settleSnowballIfNearSurface(ball)
        }
    }

    private func constrainedSnowballPoint(_ point: CGPoint, radius: CGFloat) -> CGPoint {
        let margin = max(2, radius + 2)
        let minX = min(bounds.midX, margin)
        let maxX = max(minX, bounds.maxX - margin)
        let minY = min(bounds.midY, margin)
        let maxY = max(minY, bounds.maxY - margin)
        return CGPoint(
            x: min(maxX, max(minX, point.x)),
            y: min(maxY, max(minY, point.y))
        )
    }

    private func snapSnowballOntoLargerBall(_ ball: RollingSnowball) -> Bool {
        let candidates = snowballs.filter {
            $0.id != ball.id && !$0.isHeld && $0.radius > ball.radius + 1.5
        }
        for base in candidates {
            let targetY = base.position.y + base.radius + ball.radius * 0.72
            let horizontalLimit = (base.radius + ball.radius) * 0.42
            let verticalLimit = max(16, ball.radius * 0.90)
            let stackTop = targetY + ball.radius
            let hasHeadroom = stackTop <= bounds.maxY - 8
            if hasHeadroom,
               abs(ball.position.x - base.position.x) <= horizontalLimit,
               abs(ball.position.y - targetY) <= verticalLimit {
                ball.position = CGPoint(x: base.position.x, y: targetY)
                ball.velocity = CGVector(dx: 0, dy: 0)
                ball.stackedOn = base.id
                return true
            }
        }
        return false
    }

    private func settleSnowballIfNearSurface(_ ball: RollingSnowball) {
        var bestTop: CGFloat?
        for surface in tracker.surfaces where surface.isTarget {
            guard ball.position.x >= surface.left, ball.position.x <= surface.right else { continue }
            let height = piles[surface.id]?.height(at: pileIndex(for: ball.position.x, on: surface)) ?? 0
            let top = surface.supportY + height
            if top <= ball.position.y && (bestTop == nil || top > bestTop!) { bestTop = top }
        }
        if let bestTop, ball.position.y - ball.radius <= bestTop + 18 {
            ball.position.y = bestTop + ball.radius
            ball.velocity = CGVector(dx: 0, dy: 0)
        }
    }

    private func updateSnowballs(deltaTime dt: CGFloat) {
        guard !snowballs.isEmpty else { return }
        for ball in snowballs where !ball.isHeld {
            if let baseID = ball.stackedOn,
               let base = snowballs.first(where: { $0.id == baseID }) {
                ball.position = CGPoint(
                    x: base.position.x,
                    y: base.position.y + base.radius + ball.radius * 0.72
                )
                ball.velocity = CGVector(dx: 0, dy: 0)
                continue
            }

            let previous = ball.position
            ball.velocity.dy -= 430 * dt
            ball.velocity.dx *= exp(-3.8 * dt)
            ball.position.x += ball.velocity.dx * dt
            ball.position.y += ball.velocity.dy * dt
            ball.rotation += ball.velocity.dx / max(5, ball.radius) * dt

            // Clamp the complete ball to this display. No release gesture can
            // launch it beyond the edge or let a snowman drift off-screen.
            let sideLimit = ball.radius + 3
            let rightLimit = max(sideLimit, bounds.maxX - ball.radius - 3)
            if ball.position.x < sideLimit {
                ball.position.x = sideLimit
                ball.velocity.dx = 0
            } else if ball.position.x > rightLimit {
                ball.position.x = rightLimit
                ball.velocity.dx = 0
            }
            let topLimit = max(ball.radius + 3, bounds.maxY - ball.radius - 5)
            if ball.position.y > topLimit {
                ball.position.y = topLimit
                ball.velocity.dy = min(0, ball.velocity.dy)
            }

            var landedTop: CGFloat?
            if ball.velocity.dy <= 0 {
                for surface in tracker.surfaces where surface.isTarget {
                    guard ball.position.x >= surface.left - ball.radius * 0.30,
                          ball.position.x <= surface.right + ball.radius * 0.30 else { continue }
                    let height = piles[surface.id]?.height(at: pileIndex(for: ball.position.x, on: surface)) ?? 0
                    let top = surface.supportY + height
                    let crossed = previous.y - ball.radius >= top - 1
                        && ball.position.y - ball.radius <= top + 1
                    let restingContact = previous.y - ball.radius <= top
                        && previous.y >= top - ball.radius * 0.5
                    if crossed || restingContact {
                        if landedTop == nil || top > (landedTop ?? -CGFloat.greatestFiniteMagnitude) {
                            landedTop = top
                        }
                    }
                }
            }

            if let landedTop {
                ball.position.y = landedTop + ball.radius
                // Settle on first contact. Repeated tiny bounces looked like
                // the snowball was being kicked away from the snowbank.
                ball.velocity = CGVector(dx: 0, dy: 0)
                _ = snapSnowballOntoLargerBall(ball)
            }

            // Ground fallback for displays or surfaces temporarily absent from
            // the WindowServer snapshot.
            if ball.position.y - ball.radius < 3 {
                ball.position.y = ball.radius + 3
                ball.velocity = CGVector(dx: 0, dy: 0)
            }
        }
    }

    // MARK: Occasional dog visit

    /// Each foreground display publishes its largest mound. A shared coordinator
    /// chooses the largest one on the whole desktop and permits only one visit
    /// every ten minutes, regardless of the number of connected monitors.
    private func updateSnowDog(deltaTime dt: CGFloat, now: TimeInterval) {
        guard renderLayer == .foreground else { return }
        let ownerID = ObjectIdentifier(self)

        if cachedDogCandidate == nil || now - lastDogCandidateScan >= 0.5 {
            cachedDogCandidate = largestDogTarget(now: now)
            lastDogCandidateScan = now
        }
        if let candidate = cachedDogCandidate {
            SnowDogCoordinator.candidates[ownerID] = SnowDogCandidate(
                owner: self,
                surfaceID: candidate.surfaceID,
                targetX: candidate.targetX,
                mass: candidate.mass,
                timestamp: now
            )
        } else {
            SnowDogCoordinator.candidates.removeValue(forKey: ownerID)
        }
        SnowDogCoordinator.candidates = SnowDogCoordinator.candidates.filter {
            now - $0.value.timestamp < 1.5 && $0.value.owner != nil
        }

        if SnowDogCoordinator.nextEventTime == 0 {
            SnowDogCoordinator.nextEventTime = now + 600
        }

        if SnowDogCoordinator.activeOwner == ownerID {
            advanceSnowDog(deltaTime: dt)
            return
        }
        guard SnowDogCoordinator.activeOwner == nil,
              now >= SnowDogCoordinator.nextEventTime else { return }

        guard let best = SnowDogCoordinator.candidates.values.max(by: { $0.mass < $1.mass }),
              let owner = best.owner,
              owner.isRunning else {
            SnowDogCoordinator.nextEventTime = now + 30
            return
        }

        SnowDogCoordinator.activeOwner = ObjectIdentifier(owner)
        SnowDogCoordinator.nextEventTime = now + 600
        owner.startSnowDog(on: best.surfaceID, targetX: best.targetX)
    }

    private func largestDogTarget(now: TimeInterval) -> SnowDogCandidate? {
        var best: (surface: Surface, pile: SnowPile, mass: CGFloat, peakIndex: Int)?
        for pile in piles.values {
            let surface = pile.surface
            guard surface.isTarget, pile.count > 3 else { continue }
            let peak = pile.maxHeight()
            guard peak >= 1.25 else { continue }
            let mass = pile.totalHeight()
            guard mass >= 5 else { continue }
            if best == nil || mass > best!.mass {
                var peakIndex = 0
                var peakHeight: CGFloat = 0
                for index in 0..<pile.count where pile.height(at: index) > peakHeight {
                    peakHeight = pile.height(at: index)
                    peakIndex = index
                }
                best = (surface, pile, mass, peakIndex)
            }
        }
        guard let best else { return nil }
        let targetX = best.surface.left + (CGFloat(best.peakIndex) + 0.5) * binWidth
        return SnowDogCandidate(owner: self, surfaceID: best.surface.id, targetX: targetX,
                                mass: best.mass, timestamp: now)
    }

    private func startSnowDog(on surfaceID: Int, targetX peakX: CGFloat) {
        guard snowDog == nil, let pile = piles[surfaceID], pile.count > 3 else { return }
        let surface = pile.surface

        // Pick an approach side independently on every visit. The dog enters
        // from just outside that ledge and returns the same way after marking,
        // instead of crossing the entire mound and climbing its highest peak.
        let comesFromLeft = Bool.random()
        let direction: CGFloat = comesFromLeft ? 1 : -1
        let peakIndex = pileIndex(for: peakX, on: surface)
        let peakHeight = max(0, pile.height(at: peakIndex))

        // Aim for the accessible shoulder of a tall mound, not its summit.
        // This keeps the dog on the snow surface and prevents the marking
        // animation from being projected high above the actual snow.
        let walkableHeight = min(13.0, max(3.5, peakHeight * 0.38))
        var targetIndex = peakIndex
        if comesFromLeft {
            while targetIndex > 0 && pile.height(at: targetIndex) > walkableHeight {
                targetIndex -= 1
            }
            // If the whole approach side is deeply covered, use its lowest
            // point rather than placing the dog on an inaccessible summit.
            if pile.height(at: targetIndex) > walkableHeight {
                targetIndex = (0...peakIndex).min {
                    pile.height(at: $0) < pile.height(at: $1)
                } ?? targetIndex
            }
        } else {
            while targetIndex < pile.count - 1 && pile.height(at: targetIndex) > walkableHeight {
                targetIndex += 1
            }
            if pile.height(at: targetIndex) > walkableHeight {
                targetIndex = (peakIndex..<pile.count).min {
                    pile.height(at: $0) < pile.height(at: $1)
                } ?? targetIndex
            }
        }
        // Move one bin back toward the mound only when it remains walkable.
        let nextTowardPeak = comesFromLeft ? targetIndex + 1 : targetIndex - 1
        if nextTowardPeak >= 0, nextTowardPeak < pile.count,
           pile.height(at: nextTowardPeak) <= walkableHeight * 1.22 {
            targetIndex = nextTowardPeak
        }
        let markX = surface.left + (CGFloat(targetIndex) + 0.5) * binWidth

        let startX = comesFromLeft ? surface.left - 31 : surface.right + 31
        let exitX = startX
        snowDog = SnowDogState(surfaceID: surfaceID, startX: startX, targetX: markX,
                               direction: direction, exitX: exitX)
    }

    private func advanceSnowDog(deltaTime dt: CGFloat) {
        guard let dog = snowDog,
              let pile = piles[dog.surfaceID],
              pile.surface.isTarget else {
            snowDog = nil
            SnowDogCoordinator.activeOwner = nil
            return
        }
        let step = min(0.05, max(0, dt))
        dog.phaseTime += step
        dog.tailPhase += step * 13

        switch dog.phase {
        case .running:
            let stopX = dog.targetX - dog.direction * 9
            let remaining = abs(stopX - dog.x)
            if remaining <= 2 {
                dog.x = stopX
                dog.phase = .marking
                dog.phaseTime = 0
                if !dog.markWasApplied {
                    applyYellowSnow(on: pile, at: dog.targetX)
                    dog.markWasApplied = true
                }
            } else {
                dog.x += dog.direction * min(148 * step, remaining)
            }

        case .marking:
            if dog.phaseTime >= 3.4 {
                // Turn around and leave by the same side. This avoids running
                // over the mound crest after the visit and makes the route
                // more believable on tall piles.
                dog.direction *= -1
                dog.phase = .leaving
                dog.phaseTime = 0
            }

        case .leaving:
            dog.x += dog.direction * 158 * step
            let hasLeft = dog.direction > 0 ? dog.x >= dog.exitX : dog.x <= dog.exitX
            if hasLeft {
                snowDog = nil
                SnowDogCoordinator.activeOwner = nil
            }
        }
    }

    private func applyYellowSnow(on pile: SnowPile, at x: CGFloat) {
        let center = pileIndex(for: x, on: pile.surface)
        // A compact pigment patch embedded in the snow surface. This is a tint
        // on the snow crust, not a liquid pool: no radial spreading, droplets,
        // or extra volume are created.
        let radius = 7
        for offset in -radius...radius {
            let index = center + offset
            guard index >= 0, index < pile.count else { continue }
            let normalized = CGFloat(offset) / 2.8
            let irregularEdge = 0.94 + 0.06 * sin(CGFloat(index) * 1.73)
            let intensity = 0.78 * exp(-0.5 * normalized * normalized) * irregularEdge
            pile.yellow[index] = max(pile.yellow[index], intensity)
        }
    }

    // MARK: Snowblower

    /// Dock glass is the preferred route. If Dock geometry is unavailable,
    /// sweep the bottom edge so the feature still works without Accessibility.
    private func snowblowerSurface(preferSnowy: Bool, includeWindows: Bool = false) -> Surface? {
        let candidates = tracker.surfaces.filter { surface in
            surface.kind == .dock || surface.kind == .ground
                || (includeWindows && surface.kind == .window && surface.isTarget)
        }
        guard !candidates.isEmpty else { return nil }

        if preferSnowy {
            let snowy = candidates.compactMap { surface -> (Surface, CGFloat)? in
                guard let pile = piles[surface.id], pile.maxHeight() > 1.0 else { return nil }
                // Prefer a meaningful snow load, but rank by total mass so a
                // broad shallow drift can beat one isolated tall spike.
                let mass = pile.totalHeight()
                guard mass > 18 else { return nil }
                return (surface, mass)
            }
            if let best = snowy.max(by: { $0.1 < $1.1 }) { return best.0 }
        }

        return candidates.first(where: { $0.kind == .dock })
            ?? candidates.first(where: { $0.kind == .ground })
            ?? candidates.first(where: { $0.kind == .window })
    }

    private func launchSnowblower(on surface: Surface, now: TimeInterval) {
        let direction = nextSnowblowerDirection
        nextSnowblowerDirection *= -1
        let startX = direction > 0 ? surface.left - 34 : surface.right + 34
        snowblower = SnowblowerState(startX: startX, direction: direction, surfaceID: surface.id)
        nextSnowblowerAutoTime = now + 95
    }

    private func updateSnowblower(deltaTime dt: CGFloat, now: TimeInterval) {
        guard renderLayer == .foreground else { return }

        if snowblower == nil, now >= nextSnowblowerAutoTime {
            nextSnowblowerAutoTime = now + 32
            if let surface = snowblowerSurface(preferSnowy: true) {
                launchSnowblower(on: surface, now: now)
            } else {
                // Avoid checking all piles every frame while the display is still clean.
                nextSnowblowerAutoTime = now + 28
            }
        }

        guard let machine = snowblower,
              let pile = piles[machine.surfaceID], pile.count > 0 else { return }

        let surface = pile.surface
        let oldX = machine.x
        let snowAhead = snowHeight(on: pile, at: oldX + machine.direction * 27)
        // The engine slows under a deep windrow instead of maintaining an
        // implausibly constant speed while pushing a heavy load.
        let loadDrag = min(18, sqrt(max(0, machine.collectedMass)) * 1.65)
        let driveSpeed = max(42, 104 - min(42, snowAhead * 3.0) - loadDrag)
        let newX = oldX + machine.direction * driveSpeed * dt
        let distance = abs(newX - oldX)
        let steps = max(1, min(48, Int(ceil(distance / 2.0))))
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let centerX = oldX + (newX - oldX) * t
            let bladeX = centerX + machine.direction * 18
            collectSnowForSnowblower(machine, pile: pile, bladeX: bladeX)
        }
        machine.x = newX
        machine.rotation += machine.direction * distance / max(5, machine.rollRadius)
        machine.trackPhase = (machine.trackPhase + distance * 1.12).truncatingRemainder(dividingBy: 35.2)

        // The chassis rides over the actual snow profile. A damped spring keeps
        // it from snapping vertically when one track climbs a drift or a ridge.
        let rearHeight = snowHeight(on: pile, at: machine.x - machine.direction * 13)
        let frontHeight = snowHeight(on: pile, at: machine.x + machine.direction * 13)
        let bladeHeight = snowHeight(on: pile, at: machine.x + machine.direction * 25)
        let averageTrackHeight = (rearHeight + frontHeight) * 0.5
        let targetLift = min(10.0, max(0, averageTrackHeight * 0.62))
        let targetPitch = min(0.115, max(-0.115, atan((frontHeight - rearHeight) / 26) * 0.34 * machine.direction))
        let targetBladeLoad = min(1, max(0, (bladeHeight - 0.4) / 8.0))
        let targetBladePitch = min(0.17, max(-0.05, bladeHeight * 0.013 - 0.032 - targetBladeLoad * 0.025))
        advanceSnowblowerSpring(
            value: &machine.bladeLoad,
            velocity: &machine.bladeLoadVelocity,
            target: targetBladeLoad,
            stiffness: 88,
            damping: 0.86,
            deltaTime: dt
        )
        advanceSnowblowerSpring(
            value: &machine.suspensionOffset,
            velocity: &machine.suspensionVelocity,
            target: targetLift,
            stiffness: 92,
            damping: 0.82,
            deltaTime: dt
        )
        advanceSnowblowerSpring(
            value: &machine.bodyPitch,
            velocity: &machine.bodyPitchVelocity,
            target: targetPitch,
            stiffness: 76,
            damping: 0.88,
            deltaTime: dt
        )
        advanceSnowblowerSpring(
            value: &machine.bladePitch,
            velocity: &machine.bladePitchVelocity,
            target: targetBladePitch,
            stiffness: 118,
            damping: 0.90,
            deltaTime: dt
        )

        let hasExited = machine.direction > 0
            ? machine.x > surface.right + 44
            : machine.x < surface.left - 44
        if hasExited {
            depositSnowblowerLoad(machine, into: pile)
            snowblower = nil
            nextSnowblowerAutoTime = now + 82
        }
    }

    private func snowHeight(on pile: SnowPile, at x: CGFloat) -> CGFloat {
        guard pile.count > 0 else { return 0 }
        let position = min(CGFloat(pile.count - 1), max(0, (x - pile.surface.left) / binWidth - 0.5))
        let lower = min(pile.count - 1, max(0, Int(position)))
        let upper = min(pile.count - 1, lower + 1)
        let blend = position - CGFloat(lower)
        return pile.height(at: lower) * (1 - blend) + pile.height(at: upper) * blend
    }

    private func advanceSnowblowerSpring(
        value: inout CGFloat,
        velocity: inout CGFloat,
        target: CGFloat,
        stiffness: CGFloat,
        damping: CGFloat,
        deltaTime: CGFloat
    ) {
        let dt = min(0.05, max(0.001, deltaTime))
        let frequency = sqrt(stiffness)
        let acceleration = (target - value) * stiffness - velocity * (2 * damping * frequency)
        velocity += acceleration * dt
        value += velocity * dt
        if abs(value - target) < 0.0015 && abs(velocity) < 0.008 {
            value = target
            velocity = 0
        }
    }

    private func collectSnowForSnowblower(_ machine: SnowblowerState, pile: SnowPile, bladeX: CGFloat) {
        let radius: CGFloat = 14 + machine.bladeLoad * 3
        let first = max(0, Int((bladeX - radius - pile.surface.left) / binWidth))
        let last = min(pile.count - 1, Int((bladeX + radius - pile.surface.left) / binWidth))
        guard first <= last else { return }

        var freshRemoved: CGFloat = 0
        var packedRemoved: CGFloat = 0
        for index in first...last {
            let centerX = pile.surface.left + (CGFloat(index) + 0.5) * binWidth
            let distance = abs(centerX - bladeX)
            guard distance < radius else { continue }

            let height = pile.height(at: index)
            guard height > 0.10 else { continue }
            let lateralFalloff = pow(max(0, 1 - distance / radius), 0.72)
            let penetration = min(1, max(0.20, (height + 2.5 - machine.bladeLoad * 1.8) / 7.0))
            let freshBite = min(0.56, 0.30 + height * 0.010 + machine.bladeLoad * 0.08)
            let packedBite = min(0.18, 0.075 + height * 0.0035 + machine.bladeLoad * 0.035)
            let freshPart = min(pile.fresh[index], pile.fresh[index] * freshBite * lateralFalloff * penetration)
            let packedPart = min(pile.packed[index], pile.packed[index] * packedBite * lateralFalloff * penetration)
            let removedFraction = min(1, (freshPart + packedPart) / max(0.1, height))
            let yellowPart = pile.yellow[index] * removedFraction * 0.72
            pile.fresh[index] -= freshPart
            pile.packed[index] -= packedPart
            pile.yellow[index] = max(0, pile.yellow[index] - yellowPart)
            freshRemoved += freshPart
            packedRemoved += packedPart
            machine.collectedYellow += yellowPart * lateralFalloff

            // Tracks compact a small amount beneath the chassis. Snow is not
            // deleted: a fraction of powder becomes packed in the wheel path.
            let trackIndex = max(0, min(pile.count - 1, index - Int(machine.direction * 5)))
            let trackCompaction = min(pile.fresh[trackIndex], pile.fresh[trackIndex] * 0.035 * lateralFalloff)
            pile.fresh[trackIndex] -= trackCompaction
            pile.packed[trackIndex] += trackCompaction
        }

        if freshRemoved + packedRemoved > 0.0001 {
            // Most of the cut snow rolls ahead of the blade. A smaller fraction
            // is squeezed sideways into low windrows along the machine's path.
            let freshSide = freshRemoved * 0.12
            let packedSide = packedRemoved * 0.06
            machine.collectedFresh += freshRemoved - freshSide
            machine.collectedPacked += packedRemoved - packedSide

            let sideFreshEach = freshSide * 0.5
            let sidePackedEach = packedSide * 0.5
            for side in [-1, 1] {
                let targetX = bladeX + CGFloat(side) * 25
                let target = max(0, min(pile.count - 1, Int((targetX - pile.surface.left) / binWidth)))
                let next = max(0, min(pile.count - 1, target + side * 2))
                pile.fresh[target] += sideFreshEach * 0.72
                pile.fresh[next] += sideFreshEach * 0.28
                pile.packed[target] += sidePackedEach * 0.72
                pile.packed[next] += sidePackedEach * 0.28
            }
            pile.quietTime = 0
        }
    }

    /// The blower leaves the collected snow as a compact windrow at the far end.
    /// Both snow layers are transferred separately, so the sweep conserves mass.
    private func depositSnowblowerLoad(_ machine: SnowblowerState, into pile: SnowPile) {
        let total = machine.collectedMass
        guard total > 0.0001, pile.count > 0 else { return }

        let footprint = min(16, pile.count)
        var weights: [CGFloat] = []
        weights.reserveCapacity(footprint)
        for offset in 0..<footprint {
            let normalized = CGFloat(offset) / 6.0
            weights.append(exp(-normalized * normalized * 0.72))
        }
        let weightTotal = max(0.0001, weights.reduce(0, +))

        for offset in 0..<footprint {
            let index = machine.direction > 0 ? pile.count - 1 - offset : offset
            let fraction = weights[offset] / weightTotal
            pile.fresh[index] += machine.collectedFresh * fraction
            pile.packed[index] += machine.collectedPacked * fraction
            pile.yellow[index] = min(1, pile.yellow[index] + machine.collectedYellow * fraction)
        }
        pile.quietTime = 0
        relaxPile(pile, deltaTime: 1.0 / 60.0)
    }

    private func appendSnowblower() {
        guard let machine = snowblower,
              let pile = piles[machine.surfaceID] else { return }
        let surface = pile.surface
        let supportY: CGFloat = surface.kind == .dock
            ? surface.frame.midY
            : max(7, surface.supportY + 7)
        let baseY = supportY + machine.suspensionOffset
        let trackBaseY = supportY + machine.suspensionOffset * 0.72
        let direction = machine.direction
        let rollRadius = machine.rollRadius
        let rollCenter = CGPoint(
            x: machine.x + direction * (25 + rollRadius * 0.72),
            y: baseY + max(2.5, rollRadius * 0.78)
        )
        let x = machine.x
        let bodyCos = cos(machine.bodyPitch)
        let bodySin = sin(machine.bodyPitch)
        func point(_ localX: CGFloat, _ localY: CGFloat) -> CGPoint {
            let orientedX = direction * localX
            return CGPoint(
                x: x + orientedX * bodyCos - localY * bodySin,
                y: baseY + orientedX * bodySin + localY * bodyCos
            )
        }
        // The track frame follows the terrain less aggressively than the body.
        // This small relative motion is the visible suspension travel.
        let trackPitch = machine.bodyPitch * 0.58
        let trackCos = cos(trackPitch)
        let trackSin = sin(trackPitch)
        func trackPoint(_ localX: CGFloat, _ localY: CGFloat) -> CGPoint {
            let orientedX = direction * localX
            return CGPoint(
                x: x + orientedX * trackCos - localY * trackSin,
                y: trackBaseY + orientedX * trackSin + localY * trackCos
            )
        }
        func bladePoint(_ localX: CGFloat, _ localY: CGFloat) -> CGPoint {
            let pivotX: CGFloat = 19
            let pivotY: CGFloat = 6
            let dx = localX - pivotX
            let dy = localY - pivotY
            let c = cos(machine.bladePitch)
            let sn = sin(machine.bladePitch)
            return point(pivotX + dx * c - dy * sn, pivotY + dx * sn + dy * c)
        }

        if machine.collectedMass > 0.08 {
            appendSnowOval(
                center: CGPoint(x: rollCenter.x, y: baseY + 1.5),
                radiusX: rollRadius * 1.08,
                radiusY: max(1.3, rollRadius * 0.30),
                color: DriftColor(r: 0.22, g: 0.31, b: 0.43, a: 0.22)
            )
            let roll = RollingSnowball(position: rollCenter, textureSeed: machine.textureSeed)
            roll.radius = rollRadius
            roll.mass = machine.collectedMass
            roll.rotation = machine.rotation
            appendTexturedSnowball(roll)
        }

        // Flat steel blade and two mounting arms. The front attachment is drawn
        // first so the tracked chassis visibly sits behind it.
        appendSnowPolygon([
            bladePoint(19, 1), bladePoint(34, 4), bladePoint(34, 13), bladePoint(20, 9)
        ], color: DriftColor(r: 0.31, g: 0.40, b: 0.51, a: 1.0))
        appendSnowPolygon([
            bladePoint(20, 8.7), bladePoint(33.2, 12.1), bladePoint(33.2, 13.2), bladePoint(20, 10.1)
        ], color: DriftColor(r: 0.70, g: 0.77, b: 0.84, a: 0.96))
        appendSnowPolygon([
            point(12, 9), point(20, 7), point(21, 8.5), point(13, 12)
        ], color: DriftColor(r: 0.17, g: 0.23, b: 0.31, a: 1.0))
        appendSnowPolygon([
            point(10, 5), point(20, 3), point(20.8, 4.2), point(11, 7)
        ], color: DriftColor(r: 0.24, g: 0.31, b: 0.40, a: 1.0))

        // Angular rubber tracks: chamfered rectangular silhouette, not an oval.
        appendSnowPolygon([
            trackPoint(-22, 2), trackPoint(-19, 11.5), trackPoint(17, 11.5),
            trackPoint(22, 7.5), trackPoint(21, 2), trackPoint(16, -1), trackPoint(-18, -1)
        ], color: DriftColor(r: 0.075, g: 0.105, b: 0.15, a: 1.0))
        appendSnowPolygon([
            trackPoint(-17, 2.4), trackPoint(-15, 8.8), trackPoint(15, 8.8),
            trackPoint(18, 6.4), trackPoint(17, 2.4), trackPoint(14, 1), trackPoint(-15, 1)
        ], color: DriftColor(r: 0.25, g: 0.31, b: 0.38, a: 1.0))

        // The tread blocks circulate around the track instead of being painted
        // as static stripes. Opposing runs move in opposite directions.
        let trackLoop: CGFloat = 35.2
        for tread in 0..<8 {
            let spacing = CGFloat(tread) * 4.4
            var lowerX = (spacing - machine.trackPhase).truncatingRemainder(dividingBy: trackLoop) - 17.6
            var upperX = (spacing + machine.trackPhase).truncatingRemainder(dividingBy: trackLoop) - 17.6
            if lowerX < -17.6 { lowerX += trackLoop }
            if upperX < -17.6 { upperX += trackLoop }
            appendSnowPolygon([
                trackPoint(lowerX - 1.35, 1.15), trackPoint(lowerX + 1.15, 1.15),
                trackPoint(lowerX + 1.45, 2.15), trackPoint(lowerX - 1.05, 2.15)
            ], color: DriftColor(r: 0.54, g: 0.61, b: 0.68, a: 0.92))
            appendSnowPolygon([
                trackPoint(upperX - 1.15, 9.1), trackPoint(upperX + 1.35, 9.1),
                trackPoint(upperX + 1.05, 10.1), trackPoint(upperX - 1.45, 10.1)
            ], color: DriftColor(r: 0.54, g: 0.61, b: 0.68, a: 0.88))
        }
        for roller in -1...1 {
            let rollerX = CGFloat(roller) * 9.0
            let rollerCenter = trackPoint(rollerX, 5.4)
            appendSnowDisc(center: rollerCenter, radius: 2.45,
                           color: DriftColor(r: 0.10, g: 0.15, b: 0.22, a: 1.0))
            appendSnowDisc(center: rollerCenter, radius: 0.9,
                           color: DriftColor(r: 0.66, g: 0.72, b: 0.79, a: 0.95))
            let spokeAngle = machine.trackPhase * (roller == 0 ? 0.085 : 0.065) + CGFloat(roller) * 0.9
            for spoke in 0..<3 {
                let angle = spokeAngle + CGFloat(spoke) * (2 * .pi / 3)
                let inner = CGPoint(x: rollerCenter.x + cos(angle) * 0.55,
                                    y: rollerCenter.y + sin(angle) * 0.55)
                let outer = CGPoint(x: rollerCenter.x + cos(angle) * 1.75,
                                    y: rollerCenter.y + sin(angle) * 1.75)
                let side = CGPoint(x: -sin(angle) * 0.28, y: cos(angle) * 0.28)
                appendSnowPolygon([
                    CGPoint(x: inner.x + side.x, y: inner.y + side.y),
                    CGPoint(x: outer.x + side.x, y: outer.y + side.y),
                    CGPoint(x: outer.x - side.x, y: outer.y - side.y),
                    CGPoint(x: inner.x - side.x, y: inner.y - side.y)
                ], color: DriftColor(r: 0.79, g: 0.84, b: 0.89, a: 0.88))
            }
        }

        // Short visible suspension links bridge the moving track frame and body.
        for anchorX in [CGFloat(-11.0), CGFloat(10.0)] {
            let trackAnchor = trackPoint(anchorX, 6.0)
            let bodyAnchor = point(anchorX * 0.78, 9.2)
            let dx = bodyAnchor.x - trackAnchor.x
            let dy = bodyAnchor.y - trackAnchor.y
            let length = max(0.001, hypot(dx, dy))
            let nx = -dy / length * 0.62
            let ny = dx / length * 0.62
            appendSnowPolygon([
                CGPoint(x: trackAnchor.x + nx, y: trackAnchor.y + ny),
                CGPoint(x: bodyAnchor.x + nx, y: bodyAnchor.y + ny),
                CGPoint(x: bodyAnchor.x - nx, y: bodyAnchor.y - ny),
                CGPoint(x: trackAnchor.x - nx, y: trackAnchor.y - ny)
            ], color: DriftColor(r: 0.39, g: 0.45, b: 0.52, a: 1.0))
            appendSnowDisc(center: trackAnchor, radius: 1.05,
                           color: DriftColor(r: 0.72, g: 0.77, b: 0.82, a: 0.95))
        }

        // Box-section chassis and squared engine bonnet in construction orange.
        appendSnowPolygon([
            point(-15, 10), point(15, 10), point(18, 16),
            point(13, 23), point(-9, 23), point(-15, 18)
        ], color: DriftColor(r: 0.72, g: 0.25, b: 0.08, a: 1.0))
        appendSnowPolygon([
            point(-7, 13), point(14, 13), point(16, 18),
            point(12, 22), point(-7, 22)
        ], color: DriftColor(r: 0.91, g: 0.39, b: 0.10, a: 1.0))
        appendSnowPolygon([
            point(-6, 21.5), point(11, 21.5), point(14, 23.5),
            point(-7, 23.5)
        ], color: DriftColor(r: 0.98, g: 0.57, b: 0.16, a: 1.0))

        // Small squared operator cab with a dark, slanted windscreen.
        appendSnowPolygon([
            point(-17, 17), point(-15, 29), point(-5, 29),
            point(-1, 22), point(-2, 17)
        ], color: DriftColor(r: 0.82, g: 0.34, b: 0.10, a: 1.0))
        appendSnowPolygon([
            point(-14, 21), point(-13, 27), point(-6, 27),
            point(-3.5, 22), point(-4, 21)
        ], color: DriftColor(r: 0.12, g: 0.22, b: 0.32, a: 0.98))
        appendSnowPolygon([
            point(-17, 29), point(-5, 29), point(-4, 31), point(-17, 31)
        ], color: DriftColor(r: 0.29, g: 0.35, b: 0.42, a: 1.0))

        // Exhaust stack, grille and a small square work light.
        appendSnowPolygon([
            point(-9.7, 23), point(-7.6, 23), point(-7.6, 31), point(-9.7, 31)
        ], color: DriftColor(r: 0.20, g: 0.25, b: 0.31, a: 1.0))
        appendSnowPolygon([
            point(3, 14), point(7, 14), point(7, 19.5), point(3, 19.5)
        ], color: DriftColor(r: 0.43, g: 0.17, b: 0.08, a: 0.9))
        for line in 0..<3 {
            let grilleX = CGFloat(line) * 1.35 + 13.0
            appendSnowPolygon([
                point(grilleX, 14.2), point(grilleX + 0.65, 14.2),
                point(grilleX + 0.65, 17.8), point(grilleX, 17.8)
            ], color: DriftColor(r: 0.28, g: 0.20, b: 0.16, a: 0.95))
        }
        appendSnowPolygon([
            point(15, 19.5), point(17.8, 19.5), point(17.8, 21.7), point(15, 21.7)
        ], color: DriftColor(r: 1.00, g: 0.88, b: 0.52, a: 0.98))
    }

    private func appendSnowDog() {
        guard let dog = snowDog,
              let pile = piles[dog.surfaceID],
              pile.surface.isTarget else { return }

        let terrain = snowHeight(on: pile, at: dog.x)
        let feetY = pile.surface.supportY + max(0, terrain) + 1.2
        let marking: Bool = {
            if case .marking = dog.phase { return true }
            return false
        }()
        // The dog turns its back toward the mound for the brief marking pose.
        let facing = marking ? -dog.direction : dog.direction
        func point(_ localX: CGFloat, _ localY: CGFloat) -> CGPoint {
            CGPoint(x: dog.x + facing * localX, y: feetY + localY)
        }
        func polygon(_ coordinates: [(CGFloat, CGFloat)], _ color: DriftColor) {
            appendSnowPolygon(coordinates.map { point($0.0, $0.1) }, color: color)
        }

        let darkFur = DriftColor(r: 0.34, g: 0.19, b: 0.11, a: 1)
        let fur = DriftColor(r: 0.68, g: 0.39, b: 0.20, a: 1)
        let lightFur = DriftColor(r: 0.88, g: 0.68, b: 0.46, a: 1)
        let cream = DriftColor(r: 0.94, g: 0.86, b: 0.72, a: 1)
        let dark = DriftColor(r: 0.10, g: 0.075, b: 0.06, a: 1)

        appendSnowOval(
            center: CGPoint(x: dog.x, y: feetY + 0.5),
            radiusX: 14.5, radiusY: 3.0,
            color: DriftColor(r: 0.13, g: 0.20, b: 0.29, a: 0.20)
        )

        // Wagging tail, drawn behind the body.
        let wag = sin(dog.tailPhase) * (marking ? 0.08 : 0.27)
        let tailTip = point(-15, 15 + sin(dog.tailPhase) * (marking ? 1.0 : 2.5))
        appendSnowPolygon([
            point(-8, 13), point(-12, 16 + wag * 8), tailTip,
            point(-12, 12)
        ], color: darkFur)

        // Four short legs; one hind leg rises during the marking pose.
        polygon([(-9, 8), (-6, 8), (-6.5, 1.1), (-9.5, 1.1)], darkFur)
        polygon([(5, 8), (8, 8), (9, 1.1), (6, 1.1)], darkFur)
        if marking {
            polygon([(-5, 8), (-2.5, 8), (-1, 12), (-3, 14), (-5.5, 12)], fur)
        } else {
            let gait = sin(elapsed * 17 + dog.x * 0.09) * 1.8
            polygon([(-4, 8), (-1, 8), (-2 + gait, 1.0), (-5 + gait, 1.0)], fur)
        }
        let frontGait = marking ? 0 : -sin(elapsed * 17 + dog.x * 0.09) * 1.8
        polygon([(7, 8), (10, 8), (11 + frontGait, 1.0), (8 + frontGait, 1.0)], fur)

        // Compact body, chest and a slightly oversized friendly head.
        appendSnowOval(center: point(-1, 11), radiusX: 11.5, radiusY: 6.5, color: fur)
        appendSnowOval(center: point(5, 9.5), radiusX: 4.5, radiusY: 4.6, color: lightFur)
        appendSnowOval(center: point(10, 16), radiusX: 5.6, radiusY: 5.3, color: fur)
        appendSnowOval(center: point(14, 14), radiusX: 3.8, radiusY: 2.8, color: cream)

        // Floppy ear, muzzle, nose and one visible eye.
        polygon([(7, 19), (8, 24), (12, 22), (12, 17)], darkFur)
        appendSnowOval(center: point(11, 13.7), radiusX: 1.15, radiusY: 1.25, color: dark)
        appendSnowOval(center: point(17.0, 14.6), radiusX: 1.25, radiusY: 0.95, color: dark)
        appendSnowOval(center: point(10.8, 14.1), radiusX: 0.32, radiusY: 0.32,
                       color: DriftColor(r: 1, g: 1, b: 1, a: 0.95))

        // Collar and tiny tag.
        polygon([(6, 10.5), (8, 10), (9, 13.5), (7, 14)],
                DriftColor(r: 0.72, g: 0.12, b: 0.13, a: 1))
        appendSnowDisc(center: point(8, 9.5), radius: 0.85,
                       color: DriftColor(r: 0.95, g: 0.76, b: 0.22, a: 1))

    }

    private func appendSnowPolygon(_ points: [CGPoint], color: DriftColor) {
        guard points.count >= 3 else { return }
        for index in 1..<(points.count - 1) {
            appendSnowTriangle(points[0], points[index], points[index + 1], color)
        }
    }

    private func appendSnowRect(_ rect: CGRect, color: DriftColor) {
        let a = CGPoint(x: rect.minX, y: rect.minY)
        let b = CGPoint(x: rect.maxX, y: rect.minY)
        let c = CGPoint(x: rect.maxX, y: rect.maxY)
        let d = CGPoint(x: rect.minX, y: rect.maxY)
        appendSnowTriangle(a, b, c, color)
        appendSnowTriangle(a, c, d, color)
    }

    // MARK: Snowman / snowball rendering

    private func appendSnowballs() {
        for ball in snowballs.sorted(by: { $0.position.y < $1.position.y }) {
            let r = ball.radius
            appendSnowOval(
                center: CGPoint(x: ball.position.x, y: ball.position.y - r * 0.58),
                radiusX: r * 0.92,
                radiusY: r * 0.30,
                color: DriftColor(r: 0.28, g: 0.39, b: 0.54, a: 0.20)
            )
            appendTexturedSnowball(ball)

            let hasChild = snowballs.contains { $0.stackedOn == ball.id }
            let isHead = ball.stackedOn != nil && !hasChild
            if isHead && r >= 8 {
                let eyeY = ball.position.y + r * 0.18
                let eyeX = r * 0.23
                appendSnowDisc(center: CGPoint(x: ball.position.x - eyeX, y: eyeY), radius: max(0.8, r * 0.065),
                               color: DriftColor(r: 0.12, g: 0.19, b: 0.27, a: 0.96))
                appendSnowDisc(center: CGPoint(x: ball.position.x + eyeX, y: eyeY), radius: max(0.8, r * 0.065),
                               color: DriftColor(r: 0.12, g: 0.19, b: 0.27, a: 0.96))
                appendSnowTriangle(
                    CGPoint(x: ball.position.x - r * 0.02, y: ball.position.y + r * 0.08),
                    CGPoint(x: ball.position.x + r * 0.48, y: ball.position.y + r * 0.01),
                    CGPoint(x: ball.position.x - r * 0.01, y: ball.position.y - r * 0.08),
                    DriftColor(r: 0.98, g: 0.48, b: 0.16, a: 0.98)
                )
            } else if hasChild && r >= 12 {
                for button in 0..<3 {
                    appendSnowDisc(center: CGPoint(x: ball.position.x + r * 0.08, y: ball.position.y + CGFloat(button - 1) * r * 0.22),
                                   radius: max(0.8, r * 0.055),
                                   color: DriftColor(r: 0.25, g: 0.34, b: 0.48, a: 0.82))
                }
            }
        }
    }

    /// A slightly irregular silhouette, cool shaded rim and stable fine-grain
    /// speckles make the ball read as compacted snow instead of a flat white disc.
    private func appendTexturedSnowball(_ ball: RollingSnowball) {
        let center = ball.position
        let radius = ball.radius
        let seed = ball.textureSeed + ball.rotation * 0.22
        let segmentCount = 72
        let centerColor = DriftColor(r: 0.96, g: 0.985, b: 1.00, a: 0.99)
        var perimeter: [CGPoint] = []
        var perimeterColors: [DriftColor] = []
        perimeter.reserveCapacity(segmentCount)
        perimeterColors.reserveCapacity(segmentCount)

        for index in 0..<segmentCount {
            let angle = CGFloat(index) / CGFloat(segmentCount) * 2 * .pi
            // Broad lobes plus finer irregularity: compacted snow is not a
            // mathematically perfect sphere, but avoid a jagged cartoon edge.
            let noise = sin(angle * 5 + seed) * 0.021
                + cos(angle * 9 - seed * 1.17) * 0.009
                + sin(angle * 15 + seed * 0.61) * 0.004
            let radial = radius * (1 + noise)
            let point = CGPoint(
                x: center.x + cos(angle) * radial,
                y: center.y + sin(angle) * radial * 0.96
            )
            let light = max(0, -cos(angle) * 0.34 + sin(angle) * 0.82)
            let shade = 0.70 + light * 0.28
            perimeter.append(point)
            perimeterColors.append(DriftColor(
                r: Float(0.67 + shade * 0.31),
                g: Float(0.77 + shade * 0.22),
                b: Float(0.89 + shade * 0.11),
                a: 0.99
            ))
        }

        let centerVertex = driftVertex(center, centerColor)
        for index in 0..<segmentCount {
            let next = (index + 1) % segmentCount
            output.drift.append(centerVertex)
            output.drift.append(driftVertex(perimeter[index], perimeterColors[index]))
            output.drift.append(driftVertex(perimeter[next], perimeterColors[next]))
        }

        // Shallow compressed-snow dimples and crust patches. Their positions
        // rotate with the ball, unlike screen-space noise, so the texture reads
        // as material attached to a rolling object.
        for index in 0..<26 {
            let localAngle = seed + CGFloat(index) * 2.399963
            let radialFraction = 0.18 + CGFloat((index * 7) % 17) / 17 * 0.62
            let localRadius = radius * radialFraction
            let x = center.x + cos(localAngle) * localRadius
            let y = center.y + sin(localAngle) * localRadius * 0.90
            let grainRadius = max(0.45, radius * (0.022 + CGFloat(index % 4) * 0.006))
            let grainColor: DriftColor = index % 5 == 0
                ? DriftColor(r: 1.00, g: 1.00, b: 1.00, a: 0.62)
                : DriftColor(r: 0.61, g: 0.75, b: 0.91, a: 0.27)
            appendSnowDisc(center: CGPoint(x: x, y: y), radius: grainRadius, color: grainColor)
        }

        // A soft highlight and an icy lower rim give the sphere volume.
        appendSnowOval(
            center: CGPoint(x: center.x - radius * 0.25, y: center.y + radius * 0.31),
            radiusX: radius * 0.39,
            radiusY: radius * 0.18,
            color: DriftColor(r: 1.00, g: 1.00, b: 1.00, a: 0.24)
        )
        appendSnowOval(
            center: CGPoint(x: center.x + radius * 0.12, y: center.y - radius * 0.48),
            radiusX: radius * 0.48,
            radiusY: radius * 0.13,
            color: DriftColor(r: 0.56, g: 0.70, b: 0.87, a: 0.15)
        )
    }

    private func appendSnowOval(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, color: DriftColor) {
        guard radiusX > 0.1, radiusY > 0.1 else { return }
        let segments = 40
        let centerVertex = driftVertex(center, color)
        for segment in 0..<segments {
            let a = CGFloat(segment) / CGFloat(segments) * 2 * .pi
            let b = CGFloat(segment + 1) / CGFloat(segments) * 2 * .pi
            let first = CGPoint(x: center.x + cos(a) * radiusX, y: center.y + sin(a) * radiusY)
            let second = CGPoint(x: center.x + cos(b) * radiusX, y: center.y + sin(b) * radiusY)
            output.drift.append(centerVertex)
            output.drift.append(driftVertex(first, color))
            output.drift.append(driftVertex(second, color))
        }
    }

    private func appendSnowDisc(center: CGPoint, radius: CGFloat, color: DriftColor) {
        guard radius > 0.1 else { return }
        let segments = 24
        let centerVertex = driftVertex(center, color)
        for segment in 0..<segments {
            let a = CGFloat(segment) / CGFloat(segments) * 2 * .pi
            let b = CGFloat(segment + 1) / CGFloat(segments) * 2 * .pi
            let first = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            let second = CGPoint(x: center.x + cos(b) * radius, y: center.y + sin(b) * radius)
            output.drift.append(centerVertex)
            output.drift.append(driftVertex(first, color))
            output.drift.append(driftVertex(second, color))
        }
    }

    private func appendSnowTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ color: DriftColor) {
        output.drift.append(driftVertex(a, color))
        output.drift.append(driftVertex(b, color))
        output.drift.append(driftVertex(c, color))
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

        if renderLayer == .foreground, tracker.isDisplayCovered {
            enterCoveredState()
            return
        }

        let mouse = currentMouseLocal()
        if renderLayer == .foreground {
            // Fallback for systems where AppKit refuses a global mouse monitor.
            if globalMouseMonitor == nil {
                updateWindowDragPredictionFallback(mouse: mouse, now: now)
            }
            if dragCandidateID == nil && !snowballGestureActive {
                applyMouseInteraction(mouse: mouse, deltaTime: dt)
            }
        }
        previousMouse = mouse

        updateAmbientFlakes(deltaTime: dt)
        updateBurstFlakes(deltaTime: dt)
        updatePiles(deltaTime: dt)
        updateSnowblower(deltaTime: dt, now: now)
        updateSnowballs(deltaTime: dt)
        updateSnowDog(deltaTime: dt, now: now)

        buildOutput(mouse: mouse)
        metalView?.submit(output)
    }

    /// A full-screen window covers the display: draw nothing and stop the frame loop until it goes away.
    private func enterCoveredState() {
        stopSurfaceSampling()
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
        startSurfaceSampling()
    }

    private func updateAmbientFlakes(deltaTime dt: CGFloat) {
        let directionalBias = CGFloat(windDirection) * 10.0
        let globalWind = (sin(elapsed * 0.32) * 7 + sin(elapsed * 0.79) * 3 + directionalBias) * windStrength
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
                // depositSnow now normalizes its footprint. Scale this decorative
                // ambient impact to keep the pre-0.8.2 accumulation rate unchanged.
                depositSnow(on: landedSurface, x: flake.position.x, amount: flake.radius * 0.22 * 3.58)
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

    /// Finds the first unoccluded support crossed by a falling grain. Mass-bearing
    /// grains can therefore cascade from an upper window/Dock ledge onto a lower
    /// window or the display ground without being recreated or duplicated.
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
            let hasLifetime = flake.life > 0
            if hasLifetime { flake.life = max(0, flake.life - dt) }
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
                let landingMass = flake.snowMass > 0 ? flake.snowMass : flake.radius * 0.13 * 3.58
                depositSnow(on: landed, x: flake.position.x, amount: landingMass)
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

            if (hasLifetime && flake.life <= 0) || flake.position.y < -40 {
                burstFlakes.remove(at: index)
            } else {
                burstFlakes[index] = flake
            }
        }
    }

    private func updatePiles(deltaTime dt: CGFloat) {
        guard renderLayer == .foreground else { return }
        for pile in piles.values {
            relaxPile(pile, deltaTime: dt)
            drainOvergrownSurfaceSnow(pile, deltaTime: dt)
            spillPileEdges(pile, deltaTime: dt)
            pile.quietTime += dt

            let hasSnow = pile.maxHeight() > 0.02
            if hasSnow {
                pile.snowAge += dt
            } else {
                pile.snowAge = 0
            }

            // Melt is based on the age of the snowpack, not on the time since
            // the last flake landed. Continuous snowfall therefore cannot keep
            // older deposits frozen forever. A short settling grace remains.
            if pile.snowAge > 14 {
                let freshRate: CGFloat
                let packedRate: CGFloat
                switch pile.surface.kind {
                case .window:
                    freshRate = 0.0038
                    packedRate = 0.00120
                case .dock:
                    freshRate = 0.0030
                    packedRate = 0.00095
                case .ground:
                    freshRate = 0.00235
                    packedRate = 0.00074
                }
                let freshMeltFactor = exp(-dt * freshRate)
                let packedMeltFactor = exp(-dt * packedRate)
                for index in 0..<pile.count {
                    pile.fresh[index] *= freshMeltFactor
                    pile.packed[index] *= packedMeltFactor
                    let remaining = pile.fresh[index] + pile.packed[index]
                    if remaining < 0.025 {
                        pile.yellow[index] *= exp(-dt * 1.4)
                    } else {
                        pile.yellow[index] *= exp(-dt * 0.00022)
                    }
                }
            } else {
                for index in 0..<pile.count {
                    pile.yellow[index] *= exp(-dt * 0.00004)
                }
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

        // Persist stable ledges periodically, not only on a clean application
        // shutdown. This protects accumulated Dock / ground snow from crashes
        // or forced quits without writing UserDefaults every frame.
        persistenceAccumulator += dt
        if persistenceAccumulator >= 15 {
            persistenceAccumulator = 0
            savePersistentSnow()
        }
    }

    // MARK: Building the frame (everything is drawn by the GPU)

    private func buildOutput(mouse: CGPoint) {
        output.reset()
        if renderLayer == .foreground {
            appendDrifts()
            appendSnowDog()
            appendSnowballs()
            appendSnowblower()
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
            var yellow = [CGFloat](repeating: 0, count: pile.count)
            for index in 0..<pile.count {
                let columnLeft = surface.left + CGFloat(index) * binWidth
                if isHidden(columnLeft, columnLeft + binWidth, by: hidden) { continue }
                heights[index] = pile.height(at: index)
                yellow[index] = pile.yellow[index]
            }

            var runStart: Int? = nil
            for index in 0...heights.count {
                let height: CGFloat = index < heights.count ? heights[index] : 0
                if height > 0.30 {
                    if runStart == nil { runStart = index }
                } else if let start = runStart {
                    appendRun(heights: heights, yellow: yellow, range: start...(index - 1), surface: surface)
                    runStart = nil
                }
            }
            appendGlints(heights: heights, surface: surface)
        }
    }

    private func appendRun(heights: [CGFloat], yellow: [CGFloat], range: ClosedRange<Int>, surface: Surface) {
        let baseY = surface.supportY - (surface.isGround ? 0 : 2.5)
        let firstX = surface.left + CGFloat(range.lowerBound) * binWidth
        let lastX = min(surface.right, surface.left + CGFloat(range.upperBound + 1) * binWidth)
        guard lastX > firstX else { return }

        let localHeights = Array(heights[range])
        let localYellow = Array(yellow[range])
        guard !localHeights.isEmpty else { return }

        // Seven-tap Gaussian-like smoothing rounds narrow spikes and stair-step
        // ridges before meshing. Edge samples are extended rather than zeroed,
        // so a short drift does not collapse into a sharp triangular tip.
        let smoothingWeights: [CGFloat] = [1, 3, 7, 12, 18, 22, 18, 12, 7, 3, 1]
        let weightTotal: CGFloat = smoothingWeights.reduce(0, +)
        var profile = [CGFloat](repeating: 0, count: localHeights.count)
        for index in localHeights.indices {
            var weightedHeight: CGFloat = 0
            for offset in -5...5 {
                let source = min(localHeights.count - 1, max(0, index + offset))
                weightedHeight += localHeights[source] * smoothingWeights[offset + 5]
            }
            profile[index] = max(0, weightedHeight / weightTotal)
        }

        // Fade the first and last few rendered bins into the support surface.
        // This removes the sharp triangular cut at small isolated snow patches;
        // it is a visual mesh treatment only and does not delete physical snow.
        if profile.count > 1 {
            let toeWidth: CGFloat = 6.0
            for index in profile.indices {
                let edgeDistance = CGFloat(min(index + 1, profile.count - index)) / toeWidth
                let t = min(1, max(0, edgeDistance))
                let smoothFade = t * t * (3 - 2 * t)
                profile[index] *= smoothFade
            }
        }

        // A snowbank is not a triangular ramp: its toe rises gently, the flank
        // rounds over, and the crest broadens. Let the allowable local rise grow
        // with height instead of enforcing one constant slope everywhere.
        if profile.count > 1 {
            for index in 1..<profile.count {
                let localHeight = max(profile[index - 1], profile[index])
                let allowedRise = 0.42 + min(0.83, localHeight * 0.055)
                profile[index] = min(profile[index], profile[index - 1] + allowedRise)
            }
            for index in (0..<(profile.count - 1)).reversed() {
                let localHeight = max(profile[index + 1], profile[index])
                let allowedRise = 0.42 + min(0.83, localHeight * 0.055)
                profile[index] = min(profile[index], profile[index + 1] + allowedRise)
            }
        }

        // Local dome rounding softens the long straight faces of broad mounds.
        // This affects vertices only; the underlying height-field mass is intact.
        if profile.count > 4 {
            let radius = max(8, min(56, profile.count / 5))
            let source = profile
            for index in profile.indices {
                let lower = max(0, index - radius)
                let upper = min(source.count - 1, index + radius)
                var localPeak: CGFloat = source[index]
                if lower <= upper {
                    for sample in lower...upper { localPeak = max(localPeak, source[sample]) }
                }
                guard localPeak > 0.05 else { continue }
                let t = min(1, max(0, source[index] / localPeak))
                let rounded = localPeak * sqrt(max(0, 1 - (1 - t) * (1 - t)))
                profile[index] = source[index] + (rounded - source[index]) * 0.62
            }
        }

        var crest: [CGPoint] = [CGPoint(x: firstX, y: baseY)]
        crest.reserveCapacity(profile.count + 2)
        for (offset, height) in profile.enumerated() {
            let sourceIndex = range.lowerBound + offset
            let centerX = min(lastX, surface.left + (CGFloat(sourceIndex) + 0.5) * binWidth)
            crest.append(CGPoint(x: centerX, y: surface.supportY + height))
        }
        crest.append(CGPoint(x: lastX, y: baseY))

        appendDriftMesh(
            crest: smoothNonOvershooting(crest),
            baseY: baseY,
            surface: surface,
            yellowProfile: localYellow,
            firstBinCenterX: surface.left + (CGFloat(range.lowerBound) + 0.5) * binWidth
        )
    }

    /// Catmull-Rom smoothing with each interpolated point clamped to its segment.
    /// This preserves monotonic x and prevents the inverted hooks caused by
    /// smoothing the support points and the crest with one generic corner cut.
    private func smoothNonOvershooting(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result: [CGPoint] = [points[0]]
        result.reserveCapacity((points.count - 1) * 6 + 1)

        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]

            for step in 1...5 {
                let t = CGFloat(step) / 6
                let t2 = t * t
                let t3 = t2 * t
                let y = 0.5 * (
                    (2 * p1.y) +
                    (-p0.y + p2.y) * t +
                    (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
                    (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
                )
                let lowerY = min(p1.y, p2.y)
                let upperY = max(p1.y, p2.y)
                result.append(CGPoint(
                    x: p1.x + (p2.x - p1.x) * t,
                    y: min(upperY, max(lowerY, y))
                ))
            }
            result.append(p2)
        }
        return result
    }

    private func appendDriftMesh(
        crest: [CGPoint],
        baseY: CGFloat,
        surface: Surface,
        yellowProfile: [CGFloat],
        firstBinCenterX: CGFloat
    ) {
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

        func stain(at x: CGFloat) -> CGFloat {
            guard !yellowProfile.isEmpty else { return 0 }
            let position = (x - firstBinCenterX) / binWidth
            let lower = min(yellowProfile.count - 1, max(0, Int(floor(position))))
            let upper = min(yellowProfile.count - 1, lower + 1)
            let blend = min(1, max(0, position - CGFloat(lower)))
            return yellowProfile[lower] * (1 - blend) + yellowProfile[upper] * blend
        }

        for index in 0..<(crest.count - 1) {
            let p = crest[index]
            let q = crest[index + 1]
            let pBase = CGPoint(x: p.x, y: baseY)
            let qBase = CGPoint(x: q.x, y: baseY)

            // Body: bright crest fading to a cool blue where it meets the window.
            appendQuad(p, q, pBase, qBase, topLeft: top, topRight: top, bottomLeft: bottom, bottomRight: bottom)

            // The dog mark is a narrow, uneven tint on the snow surface, not a
            // yellow rectangle through the whole drift. Sample the pigment in
            // pile-local coordinates so it follows a moving window as one mark.
            let stainAmount = stain(at: (p.x + q.x) * 0.5)
            if stainAmount > 0.012 {
                let tintTop = DriftColor(r: 0.91, g: 0.84, b: 0.55, a: Float(0.88 * stainAmount))
                let tintBottom = DriftColor(r: 0.82, g: 0.75, b: 0.48, a: Float(0.42 * stainAmount))
                let pTint = CGPoint(x: p.x, y: max(baseY, p.y - 2.2))
                let qTint = CGPoint(x: q.x, y: max(baseY, q.y - 2.2))
                appendQuad(p, q, pTint, qTint,
                           topLeft: tintTop, topRight: tintTop,
                           bottomLeft: tintBottom, bottomRight: tintBottom)
            }

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

import AppKit
import CoreGraphics

private struct SnowParticle {
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var phase: CGFloat
}

private final class SnowSurface {
    let windowID: CGWindowID
    var frame: CGRect
    var depths: [CGFloat]
    let binWidth: CGFloat = 5

    init(windowID: CGWindowID, frame: CGRect) {
        self.windowID = windowID
        self.frame = frame
        self.depths = Array(repeating: 0, count: max(1, Int(ceil(frame.width / binWidth))))
    }

    func updateFrame(_ newFrame: CGRect) {
        let oldDepths = depths
        let oldCount = max(1, oldDepths.count)
        let newCount = max(1, Int(ceil(newFrame.width / binWidth)))
        if newCount != oldCount {
            depths = (0..<newCount).map { index in
                let normalized = CGFloat(index) / CGFloat(max(1, newCount - 1))
                let oldIndex = min(oldCount - 1, Int(normalized * CGFloat(max(0, oldCount - 1))))
                return oldDepths[oldIndex]
            }
        }
        frame = newFrame
    }

    func height(at localX: CGFloat) -> CGFloat {
        let index = max(0, min(depths.count - 1, Int(localX / binWidth)))
        return depths[index]
    }

    func addSnow(at localX: CGFloat, amount: CGFloat, maximum: CGFloat) {
        let index = max(0, min(depths.count - 1, Int(localX / binWidth)))
        depths[index] = min(maximum, depths[index] + amount)
        if index > 0 { depths[index - 1] = min(maximum, depths[index - 1] + amount * 0.22) }
        if index + 1 < depths.count { depths[index + 1] = min(maximum, depths[index + 1] + amount * 0.22) }
    }

    func clearSnow() {
        for index in depths.indices { depths[index] = 0 }
    }
}

final class SnowOverlayView: NSView {
    private let screen: NSScreen
    private var particles: [SnowParticle] = []
    private var surfaces: [CGWindowID: SnowSurface] = [:]
    private var groundDepths: [CGFloat] = []
    private let groundBinWidth: CGFloat = 7
    private var timer: Timer?
    private var lastWindowScan: TimeInterval = 0
    private var previousTick: TimeInterval = 0
    var intensity: SnowIntensity = .normal

    init(frame frameRect: NSRect, screen: NSScreen) {
        self.screen = screen
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        groundDepths = Array(repeating: 0, count: max(1, Int(ceil(frameRect.width / groundBinWidth))))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    func start() {
        guard timer == nil else { return }
        previousTick = ProcessInfo.processInfo.systemUptime
        refreshWindowSurfaces()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        particles.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let dt = CGFloat(min(0.05, max(0.001, now - previousTick)))
        previousTick = now

        if now - lastWindowScan > 0.14 {
            refreshWindowSurfaces()
            lastWindowScan = now
        }

        spawnParticles()
        updateParticles(deltaTime: dt)
        needsDisplay = true
    }

    private func refreshWindowSurfaces() {
        let visible = WindowGeometryProvider.visibleWindowSurfaces(on: screen)
        var seen = Set<CGWindowID>()
        for item in visible {
            seen.insert(item.windowID)
            if let existing = surfaces[item.windowID] {
                let oldFrame = existing.frame
                let deltaX = item.frame.minX - oldFrame.minX
                let deltaY = item.frame.minY - oldFrame.minY
                if hypot(deltaX, deltaY) > 2.0 {
                    releaseSnow(from: existing, previousFrame: oldFrame, deltaX: deltaX, deltaY: deltaY)
                    existing.clearSnow()
                }
                existing.updateFrame(item.frame)
            } else {
                surfaces[item.windowID] = SnowSurface(windowID: item.windowID, frame: item.frame)
            }
        }
        // Keep a little residual snow briefly after a window closes, then let it fade.
        for id in Array(surfaces.keys) where !seen.contains(id) {
            if let surface = surfaces[id] {
                for index in surface.depths.indices {
                    surface.depths[index] *= 0.86
                }
                if surface.depths.allSatisfy({ $0 < 0.15 }) {
                    surfaces.removeValue(forKey: id)
                }
            }
        }
    }


    private func releaseSnow(from surface: SnowSurface, previousFrame: CGRect, deltaX: CGFloat, deltaY: CGFloat) {
        for index in surface.depths.indices {
            let depth = surface.depths[index]
            guard depth > 0.35, particles.count < intensity.maximumParticles else { continue }
            let sampleCount = min(4, max(1, Int(ceil(depth / 3.5))))
            for _ in 0..<sampleCount where particles.count < intensity.maximumParticles {
                let x = previousFrame.minX + (CGFloat(index) + CGFloat.random(in: 0.1...0.9)) * surface.binWidth
                let y = previousFrame.maxY + depth * CGFloat.random(in: 0.5...1.0)
                particles.append(
                    SnowParticle(
                        position: CGPoint(x: x, y: y),
                        velocity: CGVector(
                            dx: -deltaX * 1.15 + CGFloat.random(in: -10...10),
                            dy: -deltaY * 0.9 - CGFloat.random(in: 10...24)
                        ),
                        radius: CGFloat.random(in: 1.2...2.8),
                        phase: CGFloat.random(in: 0...(CGFloat.pi * 2))
                    )
                )
            }
        }
    }

    private func spawnParticles() {
        guard particles.count < intensity.maximumParticles else { return }
        if CGFloat.random(in: 0...1) < intensity.spawnChancePerFrame {
            let radius = CGFloat.random(in: 1.0...2.7)
            let speed = CGFloat.random(in: intensity.fallSpeed)
            particles.append(
                SnowParticle(
                    position: CGPoint(x: CGFloat.random(in: 0...bounds.width), y: bounds.height + radius + 2),
                    velocity: CGVector(dx: CGFloat.random(in: -9...9), dy: -speed),
                    radius: radius,
                    phase: CGFloat.random(in: 0...(CGFloat.pi * 2))
                )
            )
        }
    }

    private func updateParticles(deltaTime dt: CGFloat) {
        guard !particles.isEmpty else { return }
        var survivors: [SnowParticle] = []
        survivors.reserveCapacity(particles.count)

        for var particle in particles {
            particle.phase += dt * CGFloat.random(in: 0.7...1.8)
            particle.velocity.dx += sin(particle.phase) * 2.2 * dt
            particle.velocity.dx = min(24, max(-24, particle.velocity.dx))
            particle.velocity.dy -= 3.5 * dt

            let oldPosition = particle.position
            let newPosition = CGPoint(
                x: oldPosition.x + particle.velocity.dx * dt,
                y: oldPosition.y + particle.velocity.dy * dt
            )

            if let surface = landingSurface(from: oldPosition, to: newPosition) {
                let localX = newPosition.x - surface.frame.minX
                surface.addSnow(at: localX, amount: max(0.45, particle.radius * 0.42), maximum: intensity.maximumPileHeight)
                continue
            }

            if newPosition.y <= groundHeight(at: newPosition.x) {
                let index = max(0, min(groundDepths.count - 1, Int(newPosition.x / groundBinWidth)))
                groundDepths[index] = min(intensity.maximumPileHeight * 1.3, groundDepths[index] + particle.radius * 0.3)
                continue
            }

            if newPosition.y > -10, newPosition.x > -20, newPosition.x < bounds.width + 20 {
                particle.position = newPosition
                survivors.append(particle)
            }
        }
        particles = survivors
    }

    private func landingSurface(from old: CGPoint, to new: CGPoint) -> SnowSurface? {
        // The nearest visible window top crossed by this falling particle wins.
        let candidates = surfaces.values
            .filter { old.x >= $0.frame.minX && old.x <= $0.frame.maxX && new.y <= $0.frame.maxY + $0.height(at: old.x - $0.frame.minX) && old.y >= $0.frame.maxY }
            .sorted { $0.frame.maxY > $1.frame.maxY }
        return candidates.first
    }

    private func groundHeight(at x: CGFloat) -> CGFloat {
        guard !groundDepths.isEmpty else { return 0 }
        let index = max(0, min(groundDepths.count - 1, Int(x / groundBinWidth)))
        return groundDepths[index]
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        NSColor.clear.setFill()
        NSBezierPath(rect: dirtyRect).fill()

        drawGround()
        drawWindowSnow()
        drawFallingSnow()

        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawGround() {
        guard groundDepths.contains(where: { $0 > 0.1 }) else { return }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: 0))
        for index in groundDepths.indices {
            let x = CGFloat(index) * groundBinWidth
            let top = groundDepths[index]
            path.line(to: CGPoint(x: x, y: top))
            path.line(to: CGPoint(x: x + groundBinWidth, y: top))
        }
        path.line(to: CGPoint(x: bounds.width, y: 0))
        path.close()
        NSColor(calibratedWhite: 0.96, alpha: 0.72).setFill()
        path.fill()
    }

    private func drawWindowSnow() {
        for surface in surfaces.values where surface.depths.contains(where: { $0 > 0.15 }) {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: surface.frame.minX, y: surface.frame.maxY))
            for index in surface.depths.indices {
                let x = surface.frame.minX + CGFloat(index) * surface.binWidth
                let depth = surface.depths[index]
                let wobble = CGFloat((index % 3)) * 0.22
                path.line(to: CGPoint(x: x, y: surface.frame.maxY + depth))
                path.line(to: CGPoint(x: min(surface.frame.maxX, x + surface.binWidth), y: surface.frame.maxY + max(0, depth - wobble)))
            }
            path.line(to: CGPoint(x: surface.frame.maxX, y: surface.frame.maxY))
            path.close()
            NSColor(calibratedWhite: 0.98, alpha: 0.86).setFill()
            path.fill()

            NSColor(calibratedWhite: 1.0, alpha: 0.9).setStroke()
            path.lineWidth = 0.8
            path.stroke()
        }
    }

    private func drawFallingSnow() {
        for particle in particles {
            let rect = CGRect(
                x: particle.position.x - particle.radius,
                y: particle.position.y - particle.radius,
                width: particle.radius * 2,
                height: particle.radius * 2
            )
            NSColor(calibratedWhite: 1.0, alpha: 0.82).setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}

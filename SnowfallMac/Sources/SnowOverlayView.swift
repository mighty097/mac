import AppKit
import CoreGraphics
import Foundation

private struct SnowParticle {
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var phase: CGFloat
    var opacity: CGFloat
}

private final class SnowSurface {
    let windowID: CGWindowID
    var frame: CGRect
    var depths: [CGFloat]
    let binWidth: CGFloat = 5

    var cornerInset: CGFloat {
        min(16, max(9, frame.width * 0.035))
    }

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
                let oldPosition = normalized * CGFloat(max(0, oldCount - 1))
                let lower = min(oldCount - 1, Int(floor(oldPosition)))
                let upper = min(oldCount - 1, lower + 1)
                let blend = oldPosition - CGFloat(lower)
                return oldDepths[lower] * (1 - blend) + oldDepths[upper] * blend
            }
        }
        frame = newFrame
    }

    func height(at localX: CGFloat) -> CGFloat {
        guard !depths.isEmpty else { return 0 }
        let x = min(max(0, localX), frame.width)
        let position = x / binWidth
        let lower = min(depths.count - 1, Int(floor(position)))
        let upper = min(depths.count - 1, lower + 1)
        let blend = position - CGFloat(lower)
        let raw = depths[lower] * (1 - blend) + depths[upper] * blend
        return raw * edgeFactor(at: x)
    }

    func edgeFactor(at localX: CGFloat) -> CGFloat {
        let inset = cornerInset
        let rampWidth: CGFloat = 10
        let left = smoothStep((localX - (inset - rampWidth)) / rampWidth)
        let right = smoothStep((frame.width - inset + rampWidth - localX) / rampWidth)
        return min(left, right)
    }

    func topEdgeY(at localX: CGFloat) -> CGFloat {
        let x = min(max(0, localX), frame.width)
        let radius = cornerInset

        if x < radius {
            let dx = x - radius
            return frame.maxY - radius + sqrt(max(0, radius * radius - dx * dx))
        }
        if x > frame.width - radius {
            let dx = x - (frame.width - radius)
            return frame.maxY - radius + sqrt(max(0, radius * radius - dx * dx))
        }
        return frame.maxY
    }

    func isRoundedCorner(at localX: CGFloat) -> Bool {
        localX < cornerInset || localX > frame.width - cornerInset
    }

    func canCatchSnow(at localX: CGFloat) -> Bool {
        !isRoundedCorner(at: localX)
    }

    func addSnow(at localX: CGFloat, amount: CGFloat, maximum: CGFloat) {
        guard !depths.isEmpty else { return }
        let safeX = min(max(localX, cornerInset + 1), max(cornerInset + 1, frame.width - cornerInset - 1))
        let center = min(depths.count - 1, max(0, Int(safeX / binWidth)))
        let spread = 2
        let sigma: CGFloat = 1.25

        for index in max(0, center - spread)...min(depths.count - 1, center + spread) {
            let distance = CGFloat(index - center)
            let weight = exp(-(distance * distance) / (2 * sigma * sigma))
            depths[index] = min(maximum, depths[index] + amount * weight)
        }
    }

    func relaxSnow(deltaTime: CGFloat) {
        guard depths.count > 2 else { return }
        var changes = Array(repeating: CGFloat.zero, count: depths.count)
        let step = min(1, deltaTime * 60)

        for index in 0..<(depths.count - 1) {
            let difference = depths[index] - depths[index + 1]
            let slope = abs(difference)
            guard slope > 1.7 else { continue }
            let transfer = min(0.13 * step, (slope - 1.7) * 0.022 * step)
            if difference > 0 {
                changes[index] -= transfer
                changes[index + 1] += transfer
            } else {
                changes[index] += transfer
                changes[index + 1] -= transfer
            }
        }

        for index in depths.indices {
            depths[index] = max(0, depths[index] + changes[index])
        }
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

    private static let flakeGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.72, green: 0.82, blue: 0.94, alpha: 1),
        NSColor(calibratedRed: 0.93, green: 0.97, blue: 1.00, alpha: 1),
        NSColor(calibratedWhite: 1.0, alpha: 1)
    ])!

    private static let pileGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.74, green: 0.84, blue: 0.94, alpha: 0.92),
        NSColor(calibratedRed: 0.91, green: 0.96, blue: 1.00, alpha: 0.97),
        NSColor(calibratedWhite: 1.0, alpha: 0.99)
    ])!

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

        for surface in surfaces.values {
            surface.relaxSnow(deltaTime: dt)
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

        // Keep a faint trace for a moment after a window closes, then let it disappear.
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
            guard depth > 0.45, particles.count < intensity.maximumParticles else { continue }

            let localX = (CGFloat(index) + 0.5) * surface.binWidth
            guard surface.canCatchSnow(at: localX) else { continue }
            let sampleCount = min(5, max(1, Int(ceil(depth / 4.5))))
            let baseY = previousFrame.maxY
                + depth * CGFloat.random(in: 0.45...0.95)

            for _ in 0..<sampleCount where particles.count < intensity.maximumParticles {
                let speedX = min(180, max(-180, -deltaX * 1.8 + CGFloat.random(in: -14...14)))
                let speedY = min(150, max(-150, -deltaY * 1.35 + CGFloat.random(in: -24...7)))
                particles.append(
                    SnowParticle(
                        position: CGPoint(
                            x: previousFrame.minX + localX + CGFloat.random(in: -2...2),
                            y: baseY
                        ),
                        velocity: CGVector(dx: speedX, dy: speedY),
                        radius: CGFloat.random(in: 2.1...4.8),
                        phase: CGFloat.random(in: 0...(CGFloat.pi * 2)),
                        opacity: CGFloat.random(in: 0.72...0.98)
                    )
                )
            }
        }
    }

    private func spawnParticles() {
        guard particles.count < intensity.maximumParticles else { return }
        guard CGFloat.random(in: 0...1) < intensity.spawnChancePerFrame else { return }

        let radius = CGFloat.random(in: 1.25...3.8)
        let speed = CGFloat.random(in: intensity.fallSpeed)
        particles.append(
            SnowParticle(
                position: CGPoint(
                    x: CGFloat.random(in: -8...(bounds.width + 8)),
                    y: bounds.height + radius + 3
                ),
                velocity: CGVector(dx: CGFloat.random(in: -13...13), dy: -speed),
                radius: radius,
                phase: CGFloat.random(in: 0...(CGFloat.pi * 2)),
                opacity: CGFloat.random(in: 0.62...0.96)
            )
        )
    }

    private func updateParticles(deltaTime dt: CGFloat) {
        guard !particles.isEmpty else { return }
        var survivors: [SnowParticle] = []
        survivors.reserveCapacity(particles.count)

        for var particle in particles {
            particle.phase += dt * CGFloat.random(in: 0.65...1.15)
            particle.velocity.dx += sin(particle.phase) * 5.0 * dt
            particle.velocity.dx *= max(0.94, 1 - 0.08 * dt)
            particle.velocity.dx = min(34, max(-34, particle.velocity.dx))
            particle.velocity.dy -= 4.2 * dt

            let oldPosition = particle.position
            let newPosition = CGPoint(
                x: oldPosition.x + particle.velocity.dx * dt,
                y: oldPosition.y + particle.velocity.dy * dt
            )

            if let landing = landingSurface(from: oldPosition, to: newPosition) {
                if landing.surface.isRoundedCorner(at: landing.localX) {
                    // Snow that touches a rounded top corner cannot rest on the sloping edge:
                    // it rolls outward, clears the corner and continues falling.
                    let direction: CGFloat = landing.localX < landing.surface.cornerInset ? -1 : 1
                    particle.position = CGPoint(x: newPosition.x, y: landing.edgeY)
                    particle.velocity.dx = direction * CGFloat.random(in: 18...34)
                    particle.velocity.dy = -CGFloat.random(in: 7...17)
                    survivors.append(particle)
                } else {
                    let impact = max(0.45, particle.radius * 0.72)
                    landing.surface.addSnow(at: landing.localX, amount: impact, maximum: intensity.maximumPileHeight)
                }
                continue
            }

            if newPosition.y <= groundHeight(at: newPosition.x) {
                addGroundSnow(at: newPosition.x, amount: max(0.35, particle.radius * 0.35))
                continue
            }

            if newPosition.y > -14, newPosition.x > -28, newPosition.x < bounds.width + 28 {
                particle.position = newPosition
                survivors.append(particle)
            }
        }
        particles = survivors
    }

    private func landingSurface(from old: CGPoint, to new: CGPoint) -> (surface: SnowSurface, localX: CGFloat, edgeY: CGFloat)? {
        let impactX = (old.x + new.x) * 0.5
        let candidates = surfaces.values.compactMap { surface -> (SnowSurface, CGFloat, CGFloat)? in
            let localX = impactX - surface.frame.minX
            guard localX >= 0, localX <= surface.frame.width else { return nil }

            let edgeY = surface.topEdgeY(at: localX) + surface.height(at: localX)
            guard old.y >= edgeY, new.y <= edgeY else { return nil }
            return (surface, localX, edgeY)
        }.sorted { $0.2 > $1.2 }

        guard let first = candidates.first else { return nil }
        return (first.0, first.1, first.2)
    }

    private func addGroundSnow(at x: CGFloat, amount: CGFloat) {
        guard !groundDepths.isEmpty else { return }
        let center = min(groundDepths.count - 1, max(0, Int(x / groundBinWidth)))
        let sigma: CGFloat = 1.2
        for index in max(0, center - 2)...min(groundDepths.count - 1, center + 2) {
            let distance = CGFloat(index - center)
            let weight = exp(-(distance * distance) / (2 * sigma * sigma))
            groundDepths[index] = min(intensity.maximumPileHeight * 1.5, groundDepths[index] + amount * weight)
        }
    }

    private func groundHeight(at x: CGFloat) -> CGFloat {
        guard !groundDepths.isEmpty else { return 0 }
        let position = min(max(0, x / groundBinWidth), CGFloat(groundDepths.count - 1))
        let lower = Int(floor(position))
        let upper = min(groundDepths.count - 1, lower + 1)
        let blend = position - CGFloat(lower)
        return groundDepths[lower] * (1 - blend) + groundDepths[upper] * blend
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
        let points = groundDepths.indices.map { index in
            CGPoint(
                x: min(bounds.width, CGFloat(index) * groundBinWidth),
                y: groundDepths[index]
            )
        }
        guard let first = points.first, let last = points.last else { return }

        let path = NSBezierPath()
        path.move(to: CGPoint(x: first.x, y: 0))
        path.line(to: first)
        appendSmoothCurve(points, to: path)
        path.line(to: CGPoint(x: last.x, y: 0))
        path.close()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedRed: 0.35, green: 0.52, blue: 0.68, alpha: 0.18)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: 1)
        shadow.set()
        Self.pileGradient.draw(in: path, angle: 90)
        NSShadow().set()

        let highlight = NSBezierPath()
        appendSmoothCurve(points, to: highlight)
        NSColor(calibratedWhite: 1, alpha: 0.64).setStroke()
        highlight.lineWidth = 0.8
        highlight.stroke()
    }

    private func drawWindowSnow() {
        for surface in surfaces.values where surface.depths.contains(where: { $0 > 0.15 }) {
            // The baseline follows the actual rounded top corners of the window.
            // Snow depth fades in at the corner tangent and forms a soft, rounded cap.
            let startX: CGFloat = 0
            let endX = surface.frame.width
            let sampleCount = max(2, Int(ceil((endX - startX) / surface.binWidth)) + 1)
            let localSamples = (0..<sampleCount).map { index in
                startX + (endX - startX) * CGFloat(index) / CGFloat(sampleCount - 1)
            }
            let points = localSamples.map { localX in
                CGPoint(
                    x: surface.frame.minX + localX,
                    y: surface.topEdgeY(at: localX) + surface.height(at: localX)
                )
            }
            guard let first = points.first, let last = points.last else { continue }

            let path = NSBezierPath()
            let firstDepth = surface.height(at: 0)
            path.move(to: CGPoint(
                x: first.x,
                y: surface.topEdgeY(at: 0) + min(2.3, firstDepth * 0.30)
            ))
            path.line(to: first)
            appendSmoothCurve(points, to: path)
            for localX in localSamples.reversed() {
                let depth = surface.height(at: localX)
                path.line(to: CGPoint(
                    x: surface.frame.minX + localX,
                    y: surface.topEdgeY(at: localX) + min(2.3, depth * 0.30)
                ))
            }
            path.close()

            let shadow = NSShadow()
            shadow.shadowColor = NSColor(calibratedRed: 0.18, green: 0.33, blue: 0.48, alpha: 0.24)
            shadow.shadowBlurRadius = 3.2
            shadow.shadowOffset = CGSize(width: 0, height: -1.2)
            shadow.set()
            Self.pileGradient.draw(in: path, angle: 90)
            NSShadow().set()

            let crest = NSBezierPath()
            appendSmoothCurve(points, to: crest)
            NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.82).setStroke()
            crest.lineWidth = 0.9
            crest.lineCapStyle = .round
            crest.stroke()

            drawSnowGrains(on: surface)
        }
    }

    private func drawSnowGrains(on surface: SnowSurface) {
        for index in stride(from: 1, to: surface.depths.count - 1, by: 3) {
            let depth = surface.depths[index]
            guard depth > 3.2 else { continue }

            // Deterministic tiny highlights keep the powder texture stable between frames.
            let seed = CGFloat(index) * 12.9898 + CGFloat(surface.windowID % 997) * 0.17
            let noise = abs(sin(seed) * 43758.5453).truncatingRemainder(dividingBy: 1)
            let localX = (CGFloat(index) + 0.5) * surface.binWidth
            let localY = surface.frame.maxY + surface.height(at: localX) * (0.35 + noise * 0.38)
            let size: CGFloat = 0.65 + noise * 0.65
            let grain = NSBezierPath(ovalIn: CGRect(
                x: surface.frame.minX + localX - size / 2,
                y: localY,
                width: size,
                height: size
            ))
            NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.42).setFill()
            grain.fill()
        }
    }

    private func drawFallingSnow() {
        for particle in particles {
            let center = particle.position
            let radius = particle.radius
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            context?.setAlpha(particle.opacity)

            let haloRect = CGRect(
                x: center.x - radius * 1.65,
                y: center.y - radius * 1.65,
                width: radius * 3.3,
                height: radius * 3.3
            )
            NSColor(calibratedRed: 0.86, green: 0.94, blue: 1, alpha: 0.11).setFill()
            NSBezierPath(ovalIn: haloRect).fill()

            let puffPath = NSBezierPath()
            if radius > 2.25 {
                let lobeCount = 5
                for index in 0..<lobeCount {
                    let angle = CGFloat(index) * (2 * .pi / CGFloat(lobeCount)) + particle.phase * 0.08
                    let lobeCenter = CGPoint(
                        x: center.x + cos(angle) * radius * 0.34,
                        y: center.y + sin(angle) * radius * 0.34
                    )
                    let lobeVariation = 0.47 + 0.10 * (0.5 + 0.5 * sin(CGFloat(index) * 1.7 + particle.phase * 0.12))
                    let lobeRadius = radius * lobeVariation
                    puffPath.appendOval(in: CGRect(
                        x: lobeCenter.x - lobeRadius,
                        y: lobeCenter.y - lobeRadius,
                        width: lobeRadius * 2,
                        height: lobeRadius * 2
                    ))
                }
            }
            let coreRadius = radius * 0.72
            puffPath.appendOval(in: CGRect(
                x: center.x - coreRadius,
                y: center.y - coreRadius,
                width: coreRadius * 2,
                height: coreRadius * 2
            ))

            context?.setShadow(
                offset: CGSize(width: 0, height: -0.45),
                blur: max(0.7, radius * 0.48),
                color: NSColor(calibratedRed: 0.38, green: 0.55, blue: 0.72, alpha: 0.22).cgColor
            )
            Self.flakeGradient.draw(in: puffPath, angle: 48)
            context?.restoreGState()

            let glintSize = max(0.6, radius * 0.32)
            let glint = NSBezierPath(ovalIn: CGRect(
                x: center.x - radius * 0.22,
                y: center.y + radius * 0.18,
                width: glintSize,
                height: glintSize
            ))
            NSColor(calibratedWhite: 1, alpha: min(0.9, particle.opacity)).setFill()
            glint.fill()
        }
    }

    private func appendSmoothCurve(_ points: [CGPoint], to path: NSBezierPath) {
        guard let first = points.first else { return }
        if points.count == 1 {
            if path.elementCount == 0 { path.move(to: first) }
            return
        }

        // Continue an existing silhouette when present; start a fresh path for highlights.
        if path.elementCount == 0 { path.move(to: first) }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let beforePrevious = index > 1 ? points[index - 2] : previous
            let afterCurrent = index + 1 < points.count ? points[index + 1] : current

            let control1 = CGPoint(
                x: previous.x + (current.x - beforePrevious.x) / 6,
                y: previous.y + (current.y - beforePrevious.y) / 6
            )
            let control2 = CGPoint(
                x: current.x - (afterCurrent.x - previous.x) / 6,
                y: current.y - (afterCurrent.y - previous.y) / 6
            )
            path.curve(to: current, controlPoint1: control1, controlPoint2: control2)
        }
    }
}

private func smoothStep(_ value: CGFloat) -> CGFloat {
    let x = min(1, max(0, value))
    return x * x * (3 - 2 * x)
}

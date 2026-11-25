import AppKit
import CoreGraphics
import ApplicationServices
import CoreFoundation

struct WindowSurfaceInfo {
    let windowID: CGWindowID
    let ownerName: String
    let frame: CGRect // AppKit points, relative to the target display, bottom-left origin.
}

enum WindowGeometryProvider {
    static func visibleWindowSurfaces(on screen: NSScreen, includeDesktopWidgets: Bool = false) -> [WindowSurfaceInfo] {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return []
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let quartzDisplayFrame = CGDisplayBounds(displayID)
        let cocoaDisplayFrame = screen.frame
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let regularEntries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        var entries = regularEntries
        if includeDesktopWidgets,
           let allEntries = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            let knownIDs = Set(regularEntries.compactMap {
                ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            })
            let widgetEntries = allEntries.filter { entry in
                let owner = (entry[kCGWindowOwnerName as String] as? String ?? "").lowercased()
                let isWidgetHost = owner.contains("notificationcenter")
                    || owner.contains("widgetkit")
                    || owner.contains("widget")
                let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
                guard isWidgetHost, id != 0, !knownIDs.contains(id),
                      let raw = entry[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return false }
                return rect.width >= 100 && rect.height >= 60
                    && rect.width < quartzDisplayFrame.width * 0.82
                    && rect.height < quartzDisplayFrame.height * 0.82
            }
            entries.append(contentsOf: widgetEntries)
        }

        var results: [WindowSurfaceInfo] = []
        results.reserveCapacity(entries.count)

        // Core Graphics returns visible windows front-to-back. Preserve that ordering;
        // the renderer uses it to stop snow landing on occluded parts of background windows.
        for entry in entries {
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            if ownerPID == ownPID { continue }

            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }

            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0.05 else { continue }

            guard
                let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let quartzRect = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                quartzRect.width >= 90,
                quartzRect.height >= 45
            else {
                continue
            }

            let cocoaRect = CGRect(
                x: cocoaDisplayFrame.minX + quartzRect.minX - quartzDisplayFrame.minX,
                y: cocoaDisplayFrame.minY + quartzDisplayFrame.maxY - quartzRect.maxY,
                width: quartzRect.width,
                height: quartzRect.height
            )
            let clipped = cocoaRect.intersection(cocoaDisplayFrame)
            guard !clipped.isNull, clipped.width > 90, clipped.height > 30 else { continue }

            let windowID = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            guard windowID != 0 else { continue }
            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? "Unknown"
            // Keep the complete window frame in display-local coordinates.
            // Clipping the simulation surface here changes its width while the
            // window crosses a display edge and makes the snow profile resample.
            // The GPU clips drawing to the overlay bounds naturally.
            results.append(WindowSurfaceInfo(
                windowID: windowID,
                ownerName: ownerName,
                frame: cocoaRect.offsetBy(dx: -cocoaDisplayFrame.minX, dy: -cocoaDisplayFrame.minY)
            ))
        }
        return results
    }

    // MARK: Accessibility permission (needed only for the Dock ledge)

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that leads to System Settings → Privacy & Security → Accessibility.
    static func requestAccessibilityAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Dock geometry via Accessibility

    private static var dockAXCacheDate: TimeInterval = 0
    private static var dockAXCacheWasRead = false
    private static var cachedDockAXFrame: CGRect?

    /// Set whenever `dockSurfaceFrame` fails, so the menu's diagnostic item can show why
    /// instead of just "доступ разрешён" while no snow actually appears on the Dock.
    private(set) static var lastDockDetectionFailure: String?

    /// Returns the bottom Dock panel as a rectangle local to this display.
    /// The AXList describes the actual Dock strip; full-screen Dock helper
    /// windows from CGWindowList are intentionally not used as geometry.
    static func dockSurfaceFrame(on screen: NSScreen) -> CGRect? {
        guard AXIsProcessTrusted() else {
            lastDockDetectionFailure = "нет разрешения Универсального доступа"
            return nil
        }
        guard let axFrame = currentDockAXFrame() else {
            lastDockDetectionFailure = "не нашли панель Dock через Accessibility (AXList)"
            return nil
        }
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            lastDockDetectionFailure = "нет номера экрана"
            return nil
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let quartzDisplayFrame = CGDisplayBounds(displayID)
        guard quartzDisplayFrame.width > 0, quartzDisplayFrame.height > 0 else {
            lastDockDetectionFailure = "пустые границы экрана"
            return nil
        }

        // kAXPositionAttribute and CGDisplayBounds both use global top-left
        // coordinates. SnowfallMac's NSView uses local bottom-left coordinates.
        let localFrame = CGRect(
            x: axFrame.minX - quartzDisplayFrame.minX,
            y: quartzDisplayFrame.maxY - axFrame.maxY,
            width: axFrame.width,
            height: axFrame.height
        )
        let displayBounds = CGRect(origin: .zero, size: screen.frame.size)
        let clipped = localFrame.intersection(displayBounds)
        guard !clipped.isNull, !clipped.isEmpty else {
            lastDockDetectionFailure = "Dock не пересекается с этим экраном (другой монитор?)"
            return nil
        }

        // Recognize a horizontal Dock at the bottom edge by shape and position instead of
        // fixed pixel caps: those broke on some Retina/4K setups and with larger Dock icon
        // sizes or magnification, where the panel is taller or sits higher than 220pt/180pt
        // but is still clearly "much wider than tall, low on the screen".
        let aspectRatio = clipped.width / max(1, clipped.height)
        let verticalCenterFraction = clipped.midY / max(1, displayBounds.height)
        guard clipped.width >= max(140, displayBounds.width * 0.08),
              clipped.height >= 24,
              aspectRatio >= 2.2,
              verticalCenterFraction <= 0.45 else {
            lastDockDetectionFailure = "геометрия Dock не прошла проверку (w=\(Int(clipped.width)) h=\(Int(clipped.height)))"
            return nil
        }
        lastDockDetectionFailure = nil
        return clipped
    }

    private static func currentDockAXFrame() -> CGRect? {
        let now = ProcessInfo.processInfo.systemUptime
        if dockAXCacheWasRead, now - dockAXCacheDate < 1.0 {
            return cachedDockAXFrame
        }
        dockAXCacheWasRead = true
        dockAXCacheDate = now
        cachedDockAXFrame = nil

        // Accessibility permission is per process. Terminal permission used
        // by the diagnostic script does not automatically authorize the app.
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
              ).first else {
            return nil
        }

        let application = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var candidates: [CGRect] = []
        var visited = 0

        func readAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return error == .success ? value : nil
        }

        func readFrame(_ element: AXUIElement) -> CGRect? {
            guard let positionRef = readAttribute(element, "AXPosition"),
                  let sizeRef = readAttribute(element, "AXSize"),
                  CFGetTypeID(positionRef) == AXValueGetTypeID(),
                  CFGetTypeID(sizeRef) == AXValueGetTypeID() else {
                return nil
            }
            let positionValue = positionRef as! AXValue
            let sizeValue = sizeRef as! AXValue
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetValue(positionValue, .cgPoint, &position),
                  AXValueGetValue(sizeValue, .cgSize, &size),
                  size.width > 0, size.height > 0 else {
                return nil
            }
            return CGRect(origin: position, size: size)
        }

        func walk(_ element: AXUIElement, depth: Int) {
            guard visited < 250, depth <= 6 else { return }
            visited += 1

            if let role = readAttribute(element, "AXRole") as? String,
               role == "AXList",
               let frame = readFrame(element),
               frame.width >= 140,
               frame.height >= 24 {
                candidates.append(frame)
            }

            guard let childrenValue = readAttribute(element, "AXChildren"),
                  let children = childrenValue as? [AXUIElement] else {
                return
            }
            for child in children {
                walk(child, depth: depth + 1)
                if visited >= 250 { break }
            }
        }

        walk(application, depth: 0)
        // The Dock's primary AXList is the broadest candidate; individual
        // AXDockItem rectangles are deliberately not treated as separate ledges.
        cachedDockAXFrame = candidates.max {
            ($0.width * $0.height) < ($1.width * $1.height)
        }
        return cachedDockAXFrame
    }

}

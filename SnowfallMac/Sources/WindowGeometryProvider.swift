import AppKit
import CoreGraphics

struct WindowSurfaceInfo {
    let windowID: CGWindowID
    let ownerName: String
    let frame: CGRect // AppKit points, relative to the target display, bottom-left origin.
}

enum WindowGeometryProvider {
    static func visibleWindowSurfaces(on screen: NSScreen) -> [WindowSurfaceInfo] {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return []
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let quartzDisplayFrame = CGDisplayBounds(displayID)
        let cocoaDisplayFrame = screen.frame
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let entries = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
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

            results.append(WindowSurfaceInfo(
                windowID: windowID,
                ownerName: ownerName,
                frame: cocoaRect.offsetBy(dx: -cocoaDisplayFrame.minX, dy: -cocoaDisplayFrame.minY)
            ))
        }
        return results
    }
}

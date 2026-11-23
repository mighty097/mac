import AppKit
import CoreGraphics

struct WindowSurfaceInfo {
    let windowID: CGWindowID
    let frame: CGRect
}

enum WindowGeometryProvider {
    static func visibleWindowSurfaces(on screen: NSScreen) -> [WindowSurfaceInfo] {
        guard
            let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return []
        }

        let displayID = CGDirectDisplayID(screenNumber.uint32Value)
        let quartzDisplayFrame = CGDisplayBounds(displayID)
        let cocoaDisplayFrame = screen.frame
        let ownPID = ProcessInfo.processInfo.processIdentifier

        guard let entries = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var results: [WindowSurfaceInfo] = []
        for entry in entries {
            let ownerPID = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            if ownerPID == ownPID { continue }

            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { continue }

            let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1.0
            guard alpha > 0.05 else { continue }

            // CGWindowListCopyWindowInfo bridges each window entry to [String: Any].
            // Read its bounds as NSDictionary first, then bridge explicitly to CFDictionary.
            // `as? CFDictionary` directly from Any triggers a Swift compiler diagnostic
            // in Xcode 16.4 because that CoreFoundation cast is considered always-successful.
            guard
                let rawBounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let quartzRect = CGRect(dictionaryRepresentation: rawBounds as CFDictionary),
                quartzRect.width > 90,
                quartzRect.height > 45
            else {
                continue
            }

            // Core Graphics reports display coordinates with a top-left origin;
            // AppKit uses a bottom-left origin. Convert through the matching display.
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
            // Keep the true window frame (rather than the clipped frame) so its top edge
            // does not jump to the edge of a display when the window is partly off-screen.
            results.append(WindowSurfaceInfo(
                windowID: windowID,
                frame: cocoaRect.offsetBy(dx: -cocoaDisplayFrame.minX, dy: -cocoaDisplayFrame.minY)
            ))
        }
        return results
    }
}

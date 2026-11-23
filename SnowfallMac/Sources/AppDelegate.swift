import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var overlays: [OverlayEntry] = []
    private var isSnowEnabled = true
    private var intensity: SnowIntensity = .normal
    private var toggleMenuItem: NSMenuItem!
    private var intensityMenuItems: [NSMenuItem] = []
    private var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildStatusItem()
        rebuildOverlays()
        setSnowEnabled(true)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.rebuildOverlays()
            self?.setSnowEnabled(self?.isSnowEnabled ?? true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowfall")
            button.image?.isTemplate = true
            button.toolTip = "Snowfall — снег на окнах"
        }

        let menu = NSMenu()
        menu.delegate = self

        toggleMenuItem = NSMenuItem(
            title: "Остановить снег",
            action: #selector(toggleSnow),
            keyEquivalent: ""
        )
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)
        menu.addItem(.separator())

        let intensityRoot = NSMenuItem(title: "Интенсивность", action: nil, keyEquivalent: "")
        let intensityMenu = NSMenu()
        intensityMenuItems = SnowIntensity.allCases.map { value in
            let item = NSMenuItem(title: value.title, action: #selector(selectIntensity(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value.rawValue
            item.state = value == intensity ? .on : .off
            intensityMenu.addItem(item)
            return item
        }
        intensityRoot.submenu = intensityMenu
        menu.addItem(intensityRoot)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        toggleMenuItem.title = isSnowEnabled ? "Остановить снег" : "Включить снег"
        for item in intensityMenuItems {
            item.state = item.tag == intensity.rawValue ? .on : .off
        }
    }

    private func rebuildOverlays() {
        overlays.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()

        for screen in NSScreen.screens {
            let overlayView = SnowOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen)
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .fullScreenAuxiliary,
                .ignoresCycle
            ]
            window.contentView = overlayView
            overlays.append(OverlayEntry(window: window, view: overlayView))
        }
    }

    private func setSnowEnabled(_ enabled: Bool) {
        isSnowEnabled = enabled
        for entry in overlays {
            entry.view.intensity = intensity
            if enabled {
                entry.window.orderFrontRegardless()
                entry.view.start()
            } else {
                entry.view.stop()
                entry.window.orderOut(nil)
            }
        }
        toggleMenuItem?.title = enabled ? "Остановить снег" : "Включить снег"
    }

    @objc private func toggleSnow() {
        setSnowEnabled(!isSnowEnabled)
    }

    @objc private func selectIntensity(_ sender: NSMenuItem) {
        guard let selected = SnowIntensity(rawValue: sender.tag) else { return }
        intensity = selected
        for entry in overlays {
            entry.view.intensity = selected
        }
        for item in intensityMenuItems {
            item.state = item.tag == selected.rawValue ? .on : .off
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private struct OverlayEntry {
    let window: NSWindow
    let view: SnowOverlayView
}

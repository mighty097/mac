import AppKit
import CoreGraphics
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared

    private var statusItem: NSStatusItem!
    private var overlays: [OverlayEntry] = []
    private var isSnowEnabled = true
    private var finderOnlyEnabled = false
    private var intensity: SnowIntensity = .normal
    private var windStrength: Double = 1.0
    private var windDirection: Int = 0
    private var accumulateOnWindows = true
    private var behindWindowsOnly = false
    private var includeDesktopWidgets = false
    private var selectedDisplayIDs: [UInt32] = []

    private var toggleMenuItem: NSMenuItem!
    private var finderOnlyMenuItem: NSMenuItem!
    private var accumulateMenuItem: NSMenuItem!
    private var behindWindowsMenuItem: NSMenuItem!
    private var widgetsMenuItem: NSMenuItem!
    private var displayMenuItems: [NSMenuItem] = []
    private var displaysMenu: NSMenu?
    private var windMenuItems: [NSMenuItem] = []
    private var dockAccessMenuItem: NSMenuItem!
    private var snowblowerMenuItem: NSMenuItem!
    private var dogMenuItem: NSMenuItem!
    private var launchAtLoginMenuItem: NSMenuItem!
    private var intensityMenuItems: [NSMenuItem] = []
    private var screenObserver: NSObjectProtocol?
    private var screenSleepObserver: NSObjectProtocol?
    private var screenWakeObserver: NSObjectProtocol?
    private var screensAreAsleep = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        isSnowEnabled = settings.isEnabled
        finderOnlyEnabled = settings.finderOnly
        intensity = settings.intensity
        windStrength = settings.windStrength
        windDirection = settings.windDirection
        accumulateOnWindows = settings.accumulateOnWindows
        behindWindowsOnly = settings.behindWindowsOnly
        includeDesktopWidgets = settings.includeDesktopWidgets
        selectedDisplayIDs = settings.selectedDisplayIDs

        buildStatusItem()
        rebuildOverlays()
        setSnowEnabled(isSnowEnabled)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let connected = Set(NSScreen.screens.compactMap { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            })
            self.selectedDisplayIDs = self.selectedDisplayIDs.filter { connected.contains($0) }
            self.settings.selectedDisplayIDs = self.selectedDisplayIDs
            self.rebuildOverlays()
            self.refreshDisplayMenu()
            self.setSnowEnabled(self.isSnowEnabled)
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        screenSleepObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.setScreensAsleep(true)
        }
        screenWakeObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.setScreensAsleep(false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        if let screenSleepObserver { workspaceCenter.removeObserver(screenSleepObserver) }
        if let screenWakeObserver { workspaceCenter.removeObserver(screenWakeObserver) }
        for entry in overlays {
            entry.backgroundView.stop()
            entry.foregroundView.stop()
        }
    }

    // MARK: Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Snowfall")
            button.image?.isTemplate = true
            button.toolTip = "Snowfall — снег на окнах"
        }

        let menu = NSMenu()
        menu.delegate = self

        toggleMenuItem = NSMenuItem(title: "Остановить снег", action: #selector(toggleSnow), keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        let clearItem = NSMenuItem(title: "Очистить сугробы", action: #selector(clearSnow), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        snowblowerMenuItem = NSMenuItem(title: "Вызвать снегоуборщик — убрать самый большой сугроб", action: #selector(callSnowblower), keyEquivalent: "")
        snowblowerMenuItem.target = self
        menu.addItem(snowblowerMenuItem)

        dogMenuItem = NSMenuItem(title: "Позвать собаку сейчас (проверка)", action: #selector(callDog), keyEquivalent: "")
        dogMenuItem.target = self
        menu.addItem(dogMenuItem)

        let removeSnowmenItem = NSMenuItem(title: "Убрать снеговиков", action: #selector(removeSnowmen), keyEquivalent: "")
        removeSnowmenItem.target = self
        menu.addItem(removeSnowmenItem)

        finderOnlyMenuItem = NSMenuItem(title: "Только Finder", action: #selector(toggleFinderOnly), keyEquivalent: "")
        finderOnlyMenuItem.target = self
        finderOnlyMenuItem.state = finderOnlyEnabled ? .on : .off
        menu.addItem(finderOnlyMenuItem)

        accumulateMenuItem = NSMenuItem(title: "Не накапливать на окнах", action: #selector(toggleAccumulateOnWindows), keyEquivalent: "")
        accumulateMenuItem.target = self
        menu.addItem(accumulateMenuItem)

        behindWindowsMenuItem = NSMenuItem(title: "Только за окнами", action: #selector(toggleBehindWindowsOnly), keyEquivalent: "")
        behindWindowsMenuItem.target = self
        menu.addItem(behindWindowsMenuItem)

        widgetsMenuItem = NSMenuItem(title: "Виджеты рабочего стола (экспериментально)", action: #selector(toggleDesktopWidgets), keyEquivalent: "")
        widgetsMenuItem.target = self
        menu.addItem(widgetsMenuItem)

        let windRoot = NSMenuItem(title: "Ветер", action: nil, keyEquivalent: "")
        let windMenu = NSMenu()
        let directionOptions: [(String, Int, Int)] = [("Переменный", 0, 100), ("Слева направо", 2, 102), ("Справа налево", -2, 98)]
        for (title, value, tag) in directionOptions {
            let item = NSMenuItem(title: title, action: #selector(selectWindDirection(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = value == windDirection ? .on : .off
            windMenu.addItem(item)
            windMenuItems.append(item)
        }
        windMenu.addItem(.separator())
        for (title, value) in [("Штиль", 0.0), ("Слабый", 0.5), ("Обычный", 1.0), ("Сильный", 1.5), ("Шквалы", 2.0)] {
            let item = NSMenuItem(title: title, action: #selector(selectWindStrength(_:)), keyEquivalent: "")
            item.target = self
            item.tag = 200 + Int(value * 10)
            item.state = abs(windStrength - value) < 0.01 ? .on : .off
            windMenu.addItem(item)
            windMenuItems.append(item)
        }
        windRoot.submenu = windMenu
        menu.addItem(windRoot)

        let displaysRoot = NSMenuItem(title: "Экраны", action: nil, keyEquivalent: "")
        displaysMenu = NSMenu()
        refreshDisplayMenu()
        displaysRoot.submenu = displaysMenu
        menu.addItem(displaysRoot)
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

        dockAccessMenuItem = NSMenuItem(title: "Снег на Dock: разрешить доступ…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        dockAccessMenuItem.target = self
        menu.addItem(dockAccessMenuItem)

        launchAtLoginMenuItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchAtLoginMenuItem.target = self
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Выйти", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func refreshDisplayMenu() {
        guard let displaysMenu else { return }
        displaysMenu.removeAllItems()
        displayMenuItems.removeAll()
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = number.uint32Value
            let item = NSMenuItem(title: screen.localizedName, action: #selector(toggleDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(id)
            item.state = selectedDisplayIDs.isEmpty || selectedDisplayIDs.contains(id) ? .on : .off
            displaysMenu.addItem(item)
            displayMenuItems.append(item)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        toggleMenuItem.title = isSnowEnabled ? "Остановить снег" : "Включить снег"
        finderOnlyMenuItem.state = finderOnlyEnabled ? .on : .off
        accumulateMenuItem.state = accumulateOnWindows ? .off : .on
        behindWindowsMenuItem.state = behindWindowsOnly ? .on : .off
        widgetsMenuItem.state = includeDesktopWidgets ? .on : .off
        for item in displayMenuItems {
            let id = UInt32(item.tag)
            item.state = selectedDisplayIDs.isEmpty || selectedDisplayIDs.contains(id) ? .on : .off
        }
        for item in windMenuItems {
            if item.tag >= 200 && item.tag <= 220 {
                item.state = abs(windStrength - Double(item.tag - 200) / 10.0) < 0.01 ? .on : .off
            } else {
                item.state = item.tag == 100 + windDirection ? .on : .off
            }
        }
        for item in intensityMenuItems {
            item.state = item.tag == intensity.rawValue ? .on : .off
        }

        if WindowGeometryProvider.isAccessibilityTrusted {
            // Разрешение может числиться включённым, а сама панель Dock при этом
            // не определяться (смена подписи при пересборке, нестандартная геометрия
            // Dock и т.п.) — поэтому здесь дополнительно проверяем реальное обнаружение,
            // а не только флаг доверия.
            let dockFound = NSScreen.main.flatMap { WindowGeometryProvider.dockSurfaceFrame(on: $0) } != nil
            if dockFound {
                dockAccessMenuItem.title = "Снег на Dock: доступ разрешён"
                dockAccessMenuItem.state = .on
                dockAccessMenuItem.isEnabled = false
            } else {
                let reason = WindowGeometryProvider.lastDockDetectionFailure ?? "причина неизвестна"
                dockAccessMenuItem.title = "Снег на Dock: разрешение есть, Dock не найден (\(reason))"
                dockAccessMenuItem.state = .off
                dockAccessMenuItem.isEnabled = true
            }
        } else {
            dockAccessMenuItem.title = "Снег на Dock: разрешить доступ…"
            dockAccessMenuItem.state = .off
            dockAccessMenuItem.isEnabled = true
        }

        launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: Overlay windows

    private func rebuildOverlays() {
        for entry in overlays {
            entry.backgroundWindow.orderOut(nil)
            entry.foregroundWindow.orderOut(nil)
            entry.backgroundView.stop()
            entry.foregroundView.stop()
        }
        overlays.removeAll()

        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let displayID = screenNumber.uint32Value
            if !selectedDisplayIDs.isEmpty && !selectedDisplayIDs.contains(displayID) { continue }
            let localFrame = NSRect(origin: .zero, size: screen.frame.size)
            let backgroundView = SnowOverlayView(frame: localFrame, screen: screen, renderLayer: .background)
            let foregroundView = SnowOverlayView(frame: localFrame, screen: screen, renderLayer: .foreground)
            backgroundView.intensity = intensity
            foregroundView.intensity = intensity
            foregroundView.finderOnly = finderOnlyEnabled
            foregroundView.accumulateOnWindows = accumulateOnWindows
            foregroundView.includeDesktopWidgets = includeDesktopWidgets
            backgroundView.windStrength = CGFloat(windStrength)
            foregroundView.windStrength = CGFloat(windStrength)
            backgroundView.windDirection = windDirection
            foregroundView.windDirection = windDirection

            let backgroundWindow = makeOverlayWindow(screen: screen, view: backgroundView)
            let foregroundWindow = makeOverlayWindow(screen: screen, view: foregroundView)

            // Keep the distant snow between desktop icons and regular application windows.
            let desktopLevel = Int(CGWindowLevelForKey(.desktopIconWindow)) + 1
            backgroundWindow.level = NSWindow.Level(rawValue: desktopLevel)
            // Above normal application windows but below the Dock. Snow and the
            // snowblower are therefore visible through the translucent Dock glass
            // instead of being painted on top of the panel and its icons.
            foregroundWindow.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) + 1)

            overlays.append(OverlayEntry(
                backgroundWindow: backgroundWindow,
                foregroundWindow: foregroundWindow,
                backgroundView: backgroundView,
                foregroundView: foregroundView
            ))
        }
    }

    private func makeOverlayWindow(screen: NSScreen, view: NSView) -> NSWindow {
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
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
        window.contentView = view
        return window
    }

    private func setSnowEnabled(_ enabled: Bool) {
        isSnowEnabled = enabled
        settings.isEnabled = enabled
        for entry in overlays {
            entry.backgroundView.intensity = intensity
            entry.foregroundView.intensity = intensity
            entry.foregroundView.finderOnly = finderOnlyEnabled

            if enabled && !screensAreAsleep {
                entry.backgroundWindow.orderFrontRegardless()
                entry.backgroundView.start()
                if behindWindowsOnly {
                    entry.foregroundWindow.orderOut(nil)
                    entry.foregroundView.stop()
                } else {
                    entry.foregroundWindow.orderFrontRegardless()
                    entry.foregroundView.start()
                }
            } else {
                entry.backgroundView.stop()
                entry.foregroundView.stop()
                entry.backgroundWindow.orderOut(nil)
                entry.foregroundWindow.orderOut(nil)
            }
        }
        toggleMenuItem?.title = enabled ? "Остановить снег" : "Включить снег"
    }

    private func setScreensAsleep(_ asleep: Bool) {
        screensAreAsleep = asleep
        for entry in overlays {
            if asleep || !isSnowEnabled {
                entry.backgroundView.stop()
                entry.foregroundView.stop()
                entry.backgroundWindow.orderOut(nil)
                entry.foregroundWindow.orderOut(nil)
            } else {
                entry.backgroundWindow.orderFrontRegardless()
                entry.backgroundView.start()
                if behindWindowsOnly {
                    entry.foregroundWindow.orderOut(nil)
                    entry.foregroundView.stop()
                } else {
                    entry.foregroundWindow.orderFrontRegardless()
                    entry.foregroundView.start()
                }
            }
        }
    }

    // MARK: Actions

    @objc private func toggleSnow() {
        setSnowEnabled(!isSnowEnabled)
    }

    @objc private func clearSnow() {
        for entry in overlays {
            entry.foregroundView.clearSnow()
        }
    }

    @objc private func callSnowblower() {
        for entry in overlays {
            entry.foregroundView.callSnowblower()
        }
    }

    @objc private func callDog() {
        SnowOverlayView.callDogNow()
    }

    @objc private func removeSnowmen() {
        for entry in overlays {
            entry.foregroundView.removeAllSnowmen()
        }
    }

    @objc private func toggleAccumulateOnWindows() {
        accumulateOnWindows.toggle()
        settings.accumulateOnWindows = accumulateOnWindows
        for entry in overlays { entry.foregroundView.accumulateOnWindows = accumulateOnWindows }
        accumulateMenuItem.state = accumulateOnWindows ? .off : .on
    }

    @objc private func toggleDesktopWidgets() {
        includeDesktopWidgets.toggle()
        settings.includeDesktopWidgets = includeDesktopWidgets
        for entry in overlays { entry.foregroundView.includeDesktopWidgets = includeDesktopWidgets }
        // Refresh the tracked geometry immediately so widget-host windows can appear.
        rebuildOverlays()
        setSnowEnabled(isSnowEnabled)
        widgetsMenuItem.state = includeDesktopWidgets ? .on : .off
    }

    @objc private func toggleBehindWindowsOnly() {
        behindWindowsOnly.toggle()
        settings.behindWindowsOnly = behindWindowsOnly
        for entry in overlays {
            if behindWindowsOnly {
                entry.foregroundView.stop()
                entry.foregroundWindow.orderOut(nil)
            } else if isSnowEnabled && !screensAreAsleep {
                entry.foregroundWindow.orderFrontRegardless()
                entry.foregroundView.start()
            }
        }
        behindWindowsMenuItem.state = behindWindowsOnly ? .on : .off
    }

    @objc private func selectWindDirection(_ sender: NSMenuItem) {
        windDirection = sender.tag - 100
        settings.windDirection = windDirection
        for entry in overlays {
            entry.backgroundView.windDirection = windDirection
            entry.foregroundView.windDirection = windDirection
        }
        for item in windMenuItems where item.tag >= 98 && item.tag <= 102 {
            item.state = item.tag == 100 + windDirection ? .on : .off
        }
    }

    @objc private func selectWindStrength(_ sender: NSMenuItem) {
        windStrength = Double(sender.tag - 200) / 10.0
        settings.windStrength = windStrength
        for entry in overlays {
            entry.backgroundView.windStrength = CGFloat(windStrength)
            entry.foregroundView.windStrength = CGFloat(windStrength)
        }
        for item in windMenuItems where item.tag >= 200 && item.tag <= 220 {
            item.state = item.tag == sender.tag ? .on : .off
        }
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        let id = UInt32(sender.tag)
        let allIDs = NSScreen.screens.compactMap { screen -> UInt32? in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        var selected = selectedDisplayIDs.isEmpty ? allIDs : selectedDisplayIDs
        if selected.contains(id) {
            if selected.count > 1 { selected.removeAll { $0 == id } }
        } else {
            selected.append(id)
        }
        selectedDisplayIDs = selected.count == allIDs.count ? [] : selected
        settings.selectedDisplayIDs = selectedDisplayIDs
        rebuildOverlays()
        setSnowEnabled(isSnowEnabled)
        for item in displayMenuItems {
            let displayID = UInt32(item.tag)
            item.state = selectedDisplayIDs.isEmpty || selectedDisplayIDs.contains(displayID) ? .on : .off
        }
    }

    @objc private func toggleFinderOnly() {
        finderOnlyEnabled.toggle()
        settings.finderOnly = finderOnlyEnabled
        for entry in overlays {
            entry.foregroundView.finderOnly = finderOnlyEnabled
            entry.foregroundView.clearSnow()
        }
        finderOnlyMenuItem.state = finderOnlyEnabled ? .on : .off
    }

    @objc private func selectIntensity(_ sender: NSMenuItem) {
        guard let selected = SnowIntensity(rawValue: sender.tag) else { return }
        intensity = selected
        settings.intensity = selected
        for entry in overlays {
            entry.backgroundView.intensity = selected
            entry.foregroundView.intensity = selected
        }
        for item in intensityMenuItems {
            item.state = item.tag == selected.rawValue ? .on : .off
        }
    }

    /// Snow on the Dock needs the Accessibility permission, because only that API reports the Dock's real size.
    @objc private func openAccessibilitySettings() {
        WindowGeometryProvider.requestAccessibilityAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        guard WindowGeometryProvider.isAccessibilityTrusted else { return }
        let dockFound = NSScreen.main.flatMap { WindowGeometryProvider.dockSurfaceFrame(on: $0) } != nil
        guard !dockFound else { return }
        let alert = NSAlert()
        alert.messageText = "Разрешение есть, но Dock не найден"
        alert.informativeText = """
        Доступ в Универсальном доступе включён, но приложение подписано заново при каждой пересборке — \
        macOS иногда сбрасывает разрешение именно из-за этого. В списке в Настройках удали Snowfall \
        (кнопка «–») и добавь заново (кнопка «+», выбери Snowfall.app), либо один раз выполни \
        ./scripts/create_dev_cert.sh — тогда подпись перестанет меняться между сборками и разрешение \
        перестанет слетать. Если это не помогло — на этом Mac нестандартная раскладка Dock; напиши, \
        что показывает пункт меню «Снег на Dock» после этого.
        """
        alert.runModal()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = "Приложение должно лежать в «Программы» (или в другой постоянной папке). Ошибка: \(error.localizedDescription)"
            alert.runModal()
        }
        launchAtLoginMenuItem.state = service.status == .enabled ? .on : .off
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private struct OverlayEntry {
    let backgroundWindow: NSWindow
    let foregroundWindow: NSWindow
    let backgroundView: SnowOverlayView
    let foregroundView: SnowOverlayView
}

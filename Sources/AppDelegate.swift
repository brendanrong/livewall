import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusMenu: StatusMenu!
    var controller: WallpaperController!
    var prefsWindow: PreferencesWindowController!
    let hotkey = HotkeyManager()
    let battery = BatteryMonitor()
    let fullscreen = FullscreenMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = WallpaperController()
        prefsWindow = PreferencesWindowController(controller: controller)
        statusMenu = StatusMenu(controller: controller, openPreferences: { [weak self] in
            self?.prefsWindow.show()
        })
        controller.start()

        applyHotkeyFromPrefs()

        // Re-position windows if displays change
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Power-aware pausing — react to battery and fullscreen-app state.
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPowerPause),
            name: BatteryMonitor.stateChangedNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPowerPause),
            name: FullscreenMonitor.stateChangedNotification, object: nil
        )
        // Initial state pass.
        refreshPowerPause()
    }

    /// Re-register the global hotkey from current Preferences. Called at
    /// launch and whenever the user toggles / re-records the hotkey.
    func applyHotkeyFromPrefs() {
        hotkey.unregister()
        guard Preferences.shared.hotkeyEnabled else { return }
        hotkey.onTrigger = { [weak self] in
            self?.controller.toggleEnabled()
        }
        hotkey.register(
            keyCode: Preferences.shared.hotkeyKeyCode,
            modifiers: Preferences.shared.hotkeyModifiers
        )
    }

    @objc func refreshPowerPause() {
        let prefs = Preferences.shared
        let onBatt = battery.hasBattery && battery.isOnBattery && prefs.pauseOnBattery
        let onFs = fullscreen.isAnyAppFullscreen && prefs.pauseOnFullscreen
        controller?.setPausedByPower(onBatt || onFs)
    }

    @objc func screensChanged(_ note: Notification) {
        controller.handleScreenChange()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusMenu: StatusMenu!
    var controller: WallpaperController!
    var prefsWindow: PreferencesWindowController!
    let hotkey = HotkeyManager()
    let battery = BatteryMonitor()
    let fullscreen = FullscreenMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install a main menu (with at least an Edit menu) so text fields
        // anywhere in the app can respond to cmd+X / cmd+C / cmd+V / cmd+A.
        // LSUIElement apps don't show a menu bar, but the menu still has
        // to exist in memory for those shortcuts to route via the
        // responder chain.
        installMainMenu()

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

        // First-launch onboarding: open the Settings window so the user
        // immediately sees what's configurable. Otherwise the app is
        // invisible apart from the menu bar icon, which is easy to miss.
        // Tiny delay so the menu bar icon paints first — gives spatial
        // context for where the app lives.
        if !Preferences.shared.hasCompletedFirstLaunch {
            Preferences.shared.hasCompletedFirstLaunch = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.prefsWindow.show()
            }
        }
    }

    /// Re-apply the dock-icon visibility from the current preference.
    /// Called when the user flips the "Show in dock" toggle in Settings.
    func applyDockIconVisibility() {
        let show = Preferences.shared.showDockIcon
        NSApp.setActivationPolicy(show ? .regular : .accessory)
    }

    /// Hit GitHub's latest-release API and tell the user whether a newer
    /// version of LiveWall is available. Manual update flow: if newer, we
    /// open the Releases page in their browser so they can download the
    /// new DMG. (No Sparkle integration yet — keeping the project
    /// dependency-free.)
    func checkForUpdates() {
        let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        guard let url = URL(string: "https://api.github.com/repos/brendanrong/livewall/releases/latest") else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    self.presentUpdateAlert(title: "Couldn't check for updates",
                                            body: error.localizedDescription,
                                            url: nil)
                    return
                }
                guard
                    let data = data,
                    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let tag = json["tag_name"] as? String,
                    let pageURL = json["html_url"] as? String
                else {
                    self.presentUpdateAlert(title: "Couldn't read the latest release info",
                                            body: "GitHub returned an unexpected response.",
                                            url: nil)
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                if Self.isNewer(latest, than: currentVersion) {
                    self.presentUpdateAlert(
                        title: "Update available: LiveWall \(latest)",
                        body: "You're running \(currentVersion). Click below to download the latest version from GitHub.",
                        url: URL(string: pageURL)
                    )
                } else {
                    self.presentUpdateAlert(
                        title: "You're up to date",
                        body: "LiveWall \(currentVersion) is the latest version.",
                        url: nil
                    )
                }
            }
        }.resume()
    }

    private func presentUpdateAlert(title: String, body: String, url: URL?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .informational
        if let url = url {
            alert.addButton(withTitle: "View Release")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    /// Compare two semver-ish strings ("1.0", "1.1", "1.0.2") and return
    /// true if `remote` is newer than `local`. Tolerates missing components.
    private static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
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

    /// Build a minimal main menu so keyboard shortcuts route correctly
    /// through the responder chain. Required for cmd+V to paste into our
    /// NSAlert text fields. The menu itself never appears (LSUIElement).
    private func installMainMenu() {
        let main = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit LiveWall",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // Edit menu — the one we actually need.
        let editMenuItem = NSMenuItem()
        main.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo",
                         action: Selector(("undo:")),
                         keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo",
                         action: Selector(("redo:")),
                         keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut",
                         action: #selector(NSText.cut(_:)),
                         keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",
                         action: #selector(NSText.copy(_:)),
                         keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",
                         action: #selector(NSText.paste(_:)),
                         keyEquivalent: "v")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSResponder.selectAll(_:)),
                         keyEquivalent: "a")

        NSApp.mainMenu = main
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the Settings window shouldn't quit the app — the wallpaper
        // and menu bar icon keep running in the background.
        return false
    }

    /// Called when the user clicks the dock icon (or relaunches the app
    /// while it's already running). If there's no visible window, open
    /// Settings — that's the only thing they could reasonably want.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            prefsWindow?.show()
        }
        return true
    }
}

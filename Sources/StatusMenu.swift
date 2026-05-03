import Cocoa
import UniformTypeIdentifiers

final class StatusMenu: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private weak var controller: WallpaperController?
    private let openPreferences: () -> Void

    init(controller: WallpaperController, openPreferences: @escaping () -> Void) {
        self.controller = controller
        self.openPreferences = openPreferences
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            // Layered rectangles + play triangle — reads as "play inside a
            // monitor wall". Fallbacks for older macOS.
            let candidates = [
                "play.rectangle.on.rectangle.fill",
                "play.display",
                "play.rectangle.fill",
                "play.fill"
            ]
            var icon: NSImage?
            for name in candidates {
                if let img = NSImage(systemSymbolName: name, accessibilityDescription: "LiveWall") {
                    icon = img
                    break
                }
            }
            if let img = icon {
                img.isTemplate = true   // auto-tinted by macOS for menu bar
                button.image = img
            } else {
                button.title = "LW"
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        refreshIcon()

        NotificationCenter.default.addObserver(
            self, selector: #selector(stateChanged),
            name: WallpaperController.enabledStateChangedNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func stateChanged() {
        rebuildMenu()
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let enabled = Preferences.shared.wallpaperEnabled
        // Same family of glyphs but a "slash" variant when disabled, so the
        // user can tell at a glance whether the wallpaper is active.
        let names = enabled
            ? ["play.rectangle.on.rectangle.fill", "play.display", "play.rectangle.fill", "play.fill"]
            : ["rectangle.on.rectangle.slash.fill",   // looks like wallpaper turned off
               "rectangle.on.rectangle.slash",
               "play.slash.fill",
               "rectangle.slash"]
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: "LiveWall") {
                img.isTemplate = true
                button.image = img
                return
            }
        }
        button.title = enabled ? "LW" : "—"
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // Master enable/disable at the top — this is the most important action.
        let enabled = Preferences.shared.wallpaperEnabled
        let toggleTitle = enabled ? "Disable LiveWall" : "Enable LiveWall"
        addItem(to: menu, title: toggleTitle,
                action: #selector(toggleEnabled),
                keyEquivalent: "p", keyEquivalentModifier: [.command, .option])

        menu.addItem(.separator())
        addItem(to: menu, title: "Open Settings", action: #selector(openLiveWallWindow), keyEquivalent: ",")
        menu.addItem(.separator())

        addItem(to: menu, title: "Choose Video File…", action: #selector(chooseVideoFile))
        addItem(to: menu, title: "Choose Video Folder…", action: #selector(chooseVideoFolder))
        addItem(to: menu, title: "Set Web URL…", action: #selector(setWebURLAction))
        menu.addItem(.separator())

        // Rotation submenu
        let rotItem = NSMenuItem(title: "Rotate Every", action: nil, keyEquivalent: "")
        let rotMenu = NSMenu()
        let intervals: [(String, TimeInterval)] = [
            ("Off", 0),
            ("5 minutes", 5 * 60),
            ("15 minutes", 15 * 60),
            ("30 minutes", 30 * 60),
            ("1 hour", 60 * 60),
            ("3 hours", 3 * 60 * 60)
        ]
        let current = Preferences.shared.rotationInterval
        for (label, secs) in intervals {
            let item = NSMenuItem(title: label, action: #selector(setRotation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = secs
            item.state = (abs(secs - current) < 0.5) ? .on : .off
            rotMenu.addItem(item)
        }
        rotItem.submenu = rotMenu
        menu.addItem(rotItem)

        let muteTitle = Preferences.shared.muted ? "Unmute" : "Mute"
        addItem(to: menu, title: muteTitle, action: #selector(toggleMute))

        // Skip-to-next is only meaningful when a folder is the source.
        let nextItem = addItem(to: menu, title: "Next Video", action: #selector(nextVideo))
        nextItem.isEnabled = (Preferences.shared.contentMode == .videoFolder)

        menu.addItem(.separator())
        addItem(to: menu, title: "Quit LiveWall", action: #selector(quit), keyEquivalent: "q")
    }

    @objc private func openLiveWallWindow() {
        openPreferences()
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector,
                         keyEquivalent: String = "",
                         keyEquivalentModifier: NSEvent.ModifierFlags? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let mods = keyEquivalentModifier {
            item.keyEquivalentModifierMask = mods
        }
        menu.addItem(item)
        return item
    }

    @objc private func toggleEnabled() {
        controller?.toggleEnabled()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - Actions

    @objc private func chooseVideoFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose a video file"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.movie, UTType.video, UTType.quickTimeMovie, UTType.mpeg4Movie]
        if panel.runModal() == .OK, let url = panel.url {
            controller?.setVideoFile(url)
        }
    }

    @objc private func chooseVideoFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose a folder of videos"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            controller?.setVideoFolder(url)
        }
    }

    @objc private func setWebURLAction() {
        let alert = NSAlert()
        alert.messageText = "Set Web URL"
        alert.informativeText = "Paste a YouTube link or any webpage URL.\n(YouTube watch links are auto-converted to a muted, looping embed.)"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = "https://youtube.com/watch?v=..."
        if Preferences.shared.contentMode == .web, let s = Preferences.shared.contentPath {
            input.stringValue = s
        }
        alert.accessoryView = input
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            controller?.setWebURL(input.stringValue)
        }
    }

    @objc private func setRotation(_ sender: NSMenuItem) {
        if let secs = sender.representedObject as? TimeInterval {
            controller?.setRotationInterval(secs)
            rebuildMenu()
        }
    }

    @objc private func toggleMute() {
        let new = !Preferences.shared.muted
        controller?.setMuted(new)
        rebuildMenu()
    }

    @objc private func nextVideo() {
        controller?.nextVideo()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

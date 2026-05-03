import Cocoa
import ServiceManagement

// Edit these to point to your own links.
private let SUPPORT_URL       = "https://ko-fi.com/livewall"
private let FEEDBACK_FORM_URL = "https://docs.google.com/forms/d/e/1FAIpQLScOTXryCm9j5NXLCxL9HCOX9kE697IDE2bSSLkmjmLCMSKkdA/viewform"

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private weak var controller: WallpaperController?

    // MARK: General
    private var enableToggle: NSSwitch!
    private var enableHintLabel: NSTextField!
    private var sourceSegmented: NSSegmentedControl!
    private var sourceThumb: NSImageView!
    private var sourcePathLabel: NSTextField!
    private var browseButton: NSButton!
    private var launchAtLoginToggle: NSSwitch!
    private var showDockIconToggle: NSSwitch!

    // MARK: Display
    private var screenCheckList: NSStackView!
    private var screenStatusLabel: NSTextField!
    private var screenCheckboxes: [(NSButton, UInt32)] = []
    private var spacesToggle: NSSwitch!
    private var opacitySlider: NSSlider!
    private var opacityValueLabel: NSTextField!

    // Source (recents popup button)
    private var recentButton: NSButton!

    // MARK: Playback
    private var rotationSection: NSStackView!  // hidden when source isn't a folder
    private var rotateToggle: NSSwitch!
    private var rotateStepper: NSStepper!
    private var rotateValueLabel: NSTextField!
    private var shuffleToggle: NSSwitch!
    private var crossFadeToggle: NSSwitch!
    private var muteToggle: NSSwitch!
    private var hotkeyToggle: NSSwitch!
    private var hotkeyRecorder: HotkeyRecorderButton!
    private var pauseBatteryToggle: NSSwitch!
    private var pauseFullscreenToggle: NSSwitch!

    // MARK: Sidebar state
    private var sidebarItems: [SidebarItemButton] = []
    private var detailContainer: NSView!
    private var sectionViews: [PrefsSection: NSView] = [:]

    init(controller: WallpaperController) {
        self.controller = controller
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "LiveWall Settings"
        win.center()
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.delegate = self
        buildUI()
        // Restore last visible section if we have one.
        let saved = Preferences.shared.lastSettingsSection
        let initial = PrefsSection.allCases.first { $0.identifier == saved } ?? .general
        showSection(initial)

        NotificationCenter.default.addObserver(
            self, selector: #selector(externalEnableStateChange),
            name: WallpaperController.enabledStateChangedNotification, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func externalEnableStateChange() {
        // Hotkey or status-menu toggle fired — refresh the master switch.
        if let toggle = enableToggle {
            toggle.state = Preferences.shared.wallpaperEnabled ? .on : .off
        }
        enableHintLabel?.stringValue = enableHintText(on: Preferences.shared.wallpaperEnabled)
    }

    private func enableHintText(on: Bool) -> String {
        on ? "Showing on your displays" : "Off — your normal desktop is visible"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func show() {
        loadValues()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - UI assembly

    private func buildUI() {
        guard let win = window else { return }

        let root = NSView()
        let sidebar = buildSidebar()
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSView()
        detail.translatesAutoresizingMaskIntoConstraints = false
        detailContainer = detail

        root.addSubview(sidebar)
        root.addSubview(separator)
        root.addSubview(detail)

        NSLayoutConstraint.activate([
            // Hard lock the window's content width so subviews (e.g. a long
            // filename in the Source row) can never push the window wider.
            // Anything that wants more space gets compressed instead.
            root.widthAnchor.constraint(equalToConstant: 740),

            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 180),

            separator.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            detail.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: root.topAnchor),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        sectionViews[.general]  = buildPaneShell(
            title: "General",
            subtitle: "Source content and app behavior",
            content: buildGeneralPane()
        )
        sectionViews[.display]  = buildPaneShell(
            title: "Display",
            subtitle: "Where the wallpaper appears",
            content: buildDisplayPane()
        )
        sectionViews[.playback] = buildPaneShell(
            title: "Playback",
            subtitle: "Audio, rotation, and global shortcut",
            content: buildPlaybackPane()
        )
        sectionViews[.about] = buildAboutPane()

        win.contentView = root
    }

    private func buildSidebar() -> NSView {
        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        for section in PrefsSection.allCases {
            let item = SidebarItemButton(section: section) { [weak self] in
                self?.showSection(section)
            }
            sidebarItems.append(item)
            stack.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let supportBtn = sidebarBigButton(title: "Buy me a coffee",
                                          symbol: "heart.fill",
                                          tint: .systemRed,
                                          action: #selector(supportClicked))
        let feedbackBtn = sidebarBigButton(title: "Send feedback",
                                           symbol: "envelope",
                                           tint: nil,
                                           action: #selector(feedbackClicked))
        let quitBtn = sidebarBigButton(title: "Quit LiveWall",
                                       symbol: "power",
                                       tint: nil,
                                       action: #selector(quitClicked))

        sidebar.addSubview(stack)
        sidebar.addSubview(supportBtn)
        sidebar.addSubview(feedbackBtn)
        sidebar.addSubview(quitBtn)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),

            supportBtn.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            supportBtn.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            supportBtn.bottomAnchor.constraint(equalTo: feedbackBtn.topAnchor, constant: -8),

            feedbackBtn.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            feedbackBtn.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            feedbackBtn.bottomAnchor.constraint(equalTo: quitBtn.topAnchor, constant: -8),

            quitBtn.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 12),
            quitBtn.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            quitBtn.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),
        ])

        return sidebar
    }

    private func sidebarBigButton(title: String, symbol: String, tint: NSColor?, action: Selector) -> NSButton {
        let btn = NSButton(title: "  \(title)", target: self, action: action)
        if var img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            // Apply colour to just the symbol via SymbolConfiguration so the
            // button title stays default-coloured. (`contentTintColor` would
            // tint the whole button, text included.)
            if let t = tint {
                let cfg = NSImage.SymbolConfiguration(paletteColors: [t])
                img = img.withSymbolConfiguration(cfg) ?? img
            }
            btn.image = img
            btn.imagePosition = .imageLeft
        }
        btn.bezelStyle = .rounded
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    private func showSection(_ section: PrefsSection) {
        Preferences.shared.lastSettingsSection = section.identifier
        for item in sidebarItems {
            item.setSelected(item.section == section)
        }
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let view = sectionViews[section] else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
    }

    // MARK: - Pane builders

    private func buildPaneShell(title: String, subtitle: String, content: NSView) -> NSView {
        let pane = NSView()
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false

        pane.addSubview(titleLabel)
        pane.addSubview(subtitleLabel)
        pane.addSubview(content)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: pane.topAnchor, constant: 26),
            titleLabel.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 28),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -28),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -28),

            // Force content to fill the pane width (minus 28pt margins) so
            // the cards inside stretch and every row's trailing edge lines up.
            content.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 22),
            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -28),
            content.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor, constant: -24),
        ])
        return pane
    }

    // MARK: General

    private func buildGeneralPane() -> NSView {
        // ── LiveWall master toggle (its own card, top of pane) ──
        enableToggle = smallSwitch(target: self, action: #selector(enableToggleChanged))

        enableHintLabel = NSTextField(labelWithString: "")
        enableHintLabel.font = NSFont.systemFont(ofSize: 11)
        enableHintLabel.textColor = .secondaryLabelColor
        enableHintLabel.lineBreakMode = .byTruncatingTail
        enableHintLabel.maximumNumberOfLines = 1
        enableHintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The hint sits inline with the toggle; keep it short.
        let toggleCluster = NSStackView(views: [enableHintLabel, enableToggle])
        toggleCluster.orientation = .horizontal
        toggleCluster.spacing = 10
        toggleCluster.alignment = .centerY
        let liveWallRow = makeRow(icon: "power", title: "LiveWall", control: toggleCluster)
        let liveWallCard = makeCard([liveWallRow])

        // ── Source card ─────────────────────────────────────────
        sourceSegmented = NSSegmentedControl(
            labels: ["File", "Folder", "URL"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(sourceTypeChanged)
        )
        sourceSegmented.segmentStyle = .rounded

        sourceThumb = NSImageView()
        sourceThumb.imageScaling = .scaleProportionallyUpOrDown
        sourceThumb.wantsLayer = true
        sourceThumb.layer?.cornerRadius = 4
        sourceThumb.layer?.masksToBounds = true
        sourceThumb.layer?.borderWidth = 1
        sourceThumb.layer?.borderColor = NSColor.separatorColor.cgColor
        sourceThumb.translatesAutoresizingMaskIntoConstraints = false
        sourceThumb.widthAnchor.constraint(equalToConstant: 56).isActive = true
        sourceThumb.heightAnchor.constraint(equalToConstant: 36).isActive = true

        sourcePathLabel = NSTextField(labelWithString: "Not set — click Browse")
        sourcePathLabel.lineBreakMode = .byTruncatingMiddle
        sourcePathLabel.maximumNumberOfLines = 1
        sourcePathLabel.font = NSFont.systemFont(ofSize: 12)
        sourcePathLabel.textColor = .secondaryLabelColor
        // Let the label be squeezed (and truncate via byTruncatingMiddle) when
        // the filename is long, instead of forcing the whole row — and the
        // window — to grow to fit it.
        sourcePathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sourcePathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        browseButton = NSButton(title: "Browse…", target: self, action: #selector(browseClicked))
        browseButton.bezelStyle = .rounded
        browseButton.controlSize = .small

        recentButton = NSButton(title: "Recent  ▾", target: self, action: #selector(showRecentMenu(_:)))
        recentButton.bezelStyle = .rounded
        recentButton.controlSize = .small
        recentButton.toolTip = "Switch to a recently used source"

        // Type row: segmented selector pinned right.
        let typeRow = makeRow(icon: "film", title: "Type", control: sourceSegmented)

        // Selected row: a wider row with thumbnail + path on the left and
        // Browse/Recent on the right. Built by hand so the path can grow
        // and truncate while the buttons stay fixed-width.
        let selectedSpacer = NSView()
        selectedSpacer.translatesAutoresizingMaskIntoConstraints = false
        selectedSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        selectedSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let selectedIcon = rowIcon("photo")
        let selectedTitle = NSTextField(labelWithString: "Selected")
        selectedTitle.font = NSFont.systemFont(ofSize: 13)

        let selectedRow = NSStackView(views: [
            selectedIcon, selectedTitle, sourceThumb, sourcePathLabel,
            selectedSpacer, browseButton, recentButton
        ])
        selectedRow.orientation = .horizontal
        selectedRow.alignment = .centerY
        selectedRow.spacing = 10
        selectedRow.distribution = .fill
        selectedRow.translatesAutoresizingMaskIntoConstraints = false
        selectedRow.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        // Drag-and-drop wrapper around the entire row.
        let dropContainer = DropTargetView()
        dropContainer.onURLs = { [weak self] urls in self?.handleSourceDrop(urls) }
        dropContainer.translatesAutoresizingMaskIntoConstraints = false
        dropContainer.addSubview(selectedRow)
        NSLayoutConstraint.activate([
            selectedRow.leadingAnchor.constraint(equalTo: dropContainer.leadingAnchor),
            selectedRow.trailingAnchor.constraint(equalTo: dropContainer.trailingAnchor),
            selectedRow.topAnchor.constraint(equalTo: dropContainer.topAnchor),
            selectedRow.bottomAnchor.constraint(equalTo: dropContainer.bottomAnchor),
        ])
        dropContainer.toolTip = "Drag a video file or folder here"

        let sourceCard = makeCard([typeRow, dropContainer])
        let sourceSection = makeSection(symbol: "film.stack",
                                        title: "Source",
                                        content: sourceCard)

        // ── System card ────────────────────────────────────────
        launchAtLoginToggle = smallSwitch(target: self, action: #selector(launchAtLoginChanged))
        let launchRow = makeRow(icon: "bolt.fill",
                                title: "Launch at login",
                                control: launchAtLoginToggle)

        showDockIconToggle = smallSwitch(target: self, action: #selector(showDockIconChanged))
        let dockRow = makeRow(icon: "dock.rectangle",
                              title: "Show in dock",
                              control: showDockIconToggle)

        let resetBtn = NSButton(title: "Reset All Settings…",
                                target: self, action: #selector(resetAllClicked))
        resetBtn.bezelStyle = .rounded
        resetBtn.controlSize = .small
        resetBtn.contentTintColor = .systemRed
        let resetRow = makeRow(icon: "arrow.counterclockwise",
                               title: "Reset",
                               control: resetBtn)

        let systemCard = makeCard([launchRow, dockRow, resetRow])
        let systemSection = makeSection(symbol: "gearshape",
                                        title: "System",
                                        content: systemCard)

        // Compose pane.
        let pane = NSStackView(views: [liveWallCard, sourceSection, systemSection])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 20
        pane.distribution = .fill
        pane.setHuggingPriority(.defaultLow, for: .horizontal)
        fillWidth(pane)
        return pane
    }

    // MARK: Display

    private func buildDisplayPane() -> NSView {
        // ── Displays card ─────────────────────────────────────
        // Per-display rows are added dynamically by rebuildScreenCheckboxes.
        screenCheckList = NSStackView()
        screenCheckList.orientation = .vertical
        screenCheckList.alignment = .leading
        screenCheckList.spacing = 4
        screenCheckList.translatesAutoresizingMaskIntoConstraints = false

        screenStatusLabel = NSTextField(labelWithString: "")
        screenStatusLabel.font = NSFont.systemFont(ofSize: 11)
        screenStatusLabel.textColor = .secondaryLabelColor

        // The dynamic checklist + the status caption sit together as one
        // "row" inside the Displays card. Wrap them so the card layout
        // treats them as a single unit.
        let displaysBlock = NSStackView(views: [screenCheckList, screenStatusLabel])
        displaysBlock.orientation = .vertical
        displaysBlock.alignment = .leading
        displaysBlock.spacing = 8
        displaysBlock.translatesAutoresizingMaskIntoConstraints = false
        displaysBlock.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        // Stretch the checklist to fill displaysBlock's width so its dynamically
        // added per-display rows can pin their popup buttons to the right edge.
        screenCheckList.widthAnchor.constraint(equalTo: displaysBlock.widthAnchor).isActive = true

        let displaysCard = makeCard([displaysBlock])
        let displaysSection = makeSection(symbol: "display",
                                          title: "Displays",
                                          content: displaysCard)

        // ── Behavior card ─────────────────────────────────────
        spacesToggle = smallSwitch(target: self, action: #selector(spacesChanged))
        let spacesRow = makeRow(icon: "rectangle.on.rectangle",
                                title: "Show on all Spaces",
                                control: spacesToggle)

        opacitySlider = NSSlider(value: 100, minValue: 10, maxValue: 100,
                                 target: self, action: #selector(opacityChanged))
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        opacitySlider.controlSize = .small

        opacityValueLabel = NSTextField(labelWithString: "100%")
        opacityValueLabel.alignment = .right
        opacityValueLabel.font = NSFont.systemFont(ofSize: 12)
        opacityValueLabel.textColor = .secondaryLabelColor
        opacityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        opacityValueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let opacityCluster = NSStackView(views: [opacitySlider, opacityValueLabel])
        opacityCluster.orientation = .horizontal
        opacityCluster.spacing = 8
        opacityCluster.alignment = .centerY
        let opacityRow = makeRow(icon: "circle.lefthalf.filled",
                                 title: "Opacity",
                                 control: opacityCluster)

        let behaviorCard = makeCard([spacesRow, opacityRow])
        let behaviorSection = makeSection(symbol: "slider.horizontal.3",
                                          title: "Behavior",
                                          content: behaviorCard)

        // Compose pane.
        let pane = NSStackView(views: [displaysSection, behaviorSection])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 20
        pane.distribution = .fill
        pane.setHuggingPriority(.defaultLow, for: .horizontal)
        fillWidth(pane)
        return pane
    }

    // MARK: Playback

    private func buildPlaybackPane() -> NSView {
        // ── Audio card ────────────────────────────────────────
        muteToggle = smallSwitch(target: self, action: #selector(muteChanged))
        let muteRow = makeRow(icon: "speaker.slash", title: "Mute audio", control: muteToggle)
        let audioCard = makeCard([muteRow])
        let audioSection = makeSection(symbol: "speaker.wave.2",
                                       title: "Audio",
                                       content: audioCard)

        // ── Rotation card (hidden unless source is a folder) ──
        rotateToggle = smallSwitch(target: self, action: #selector(rotateToggleChanged))
        let enableRotationRow = makeRow(icon: "arrow.triangle.2.circlepath",
                                        title: "Enable rotation",
                                        control: rotateToggle)

        rotateStepper = NSStepper()
        rotateStepper.minValue = 1
        rotateStepper.maxValue = 1440
        rotateStepper.intValue = 30
        rotateStepper.target = self
        rotateStepper.action = #selector(rotateStepperChanged)
        rotateStepper.controlSize = .small

        rotateValueLabel = NSTextField(labelWithString: "30")
        rotateValueLabel.alignment = .right
        rotateValueLabel.font = NSFont.systemFont(ofSize: 12)
        rotateValueLabel.translatesAutoresizingMaskIntoConstraints = false
        rotateValueLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        let minutesText = NSTextField(labelWithString: "minutes")
        minutesText.font = NSFont.systemFont(ofSize: 12)
        minutesText.textColor = .secondaryLabelColor

        let intervalCluster = NSStackView(views: [rotateValueLabel, rotateStepper, minutesText])
        intervalCluster.orientation = .horizontal
        intervalCluster.spacing = 6
        intervalCluster.alignment = .centerY
        let intervalRow = makeRow(icon: "clock", title: "Rotate every", control: intervalCluster)

        crossFadeToggle = smallSwitch(target: self, action: #selector(crossFadeChanged))
        let crossFadeRow = makeRow(icon: "sparkles", title: "Cross-fade", control: crossFadeToggle)

        shuffleToggle = smallSwitch(target: self, action: #selector(shuffleChanged))
        let shuffleRow = makeRow(icon: "shuffle", title: "Shuffle", control: shuffleToggle)

        let rotationCard = makeCard([enableRotationRow, intervalRow, crossFadeRow, shuffleRow])
        rotationSection = makeSection(symbol: "arrow.triangle.2.circlepath",
                                      title: "Rotation",
                                      content: rotationCard)
        // Initial visibility — refreshSourceUI() will keep this in sync.
        rotationSection.isHidden = (Preferences.shared.contentMode != .videoFolder)

        // ── Power saving card ─────────────────────────────────
        pauseBatteryToggle = smallSwitch(target: self, action: #selector(pauseBatteryChanged))
        let batteryRow = makeRow(icon: "battery.50",
                                 title: "Pause on battery",
                                 control: pauseBatteryToggle)

        pauseFullscreenToggle = smallSwitch(target: self, action: #selector(pauseFullscreenChanged))
        let fullscreenRow = makeRow(icon: "arrow.up.left.and.arrow.down.right",
                                    title: "Pause when fullscreen",
                                    control: pauseFullscreenToggle)

        let powerCard = makeCard([batteryRow, fullscreenRow])
        let powerSection = makeSection(symbol: "battery.50",
                                       title: "Power saving",
                                       content: powerCard)

        // ── Global hotkey card ────────────────────────────────
        hotkeyToggle = smallSwitch(target: self, action: #selector(hotkeyToggleChanged))
        let enableHotkeyRow = makeRow(icon: "keyboard",
                                      title: "Enable hotkey",
                                      control: hotkeyToggle)

        hotkeyRecorder = HotkeyRecorderButton(frame: .zero)
        hotkeyRecorder.translatesAutoresizingMaskIntoConstraints = false
        hotkeyRecorder.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        hotkeyRecorder.onRecorded = { code, mods in
            Preferences.shared.hotkeyKeyCode = code
            Preferences.shared.hotkeyModifiers = mods
            (NSApp.delegate as? AppDelegate)?.applyHotkeyFromPrefs()
        }
        let shortcutRow = makeRow(icon: "command",
                                  title: "Shortcut",
                                  control: hotkeyRecorder)

        let hotkeyCard = makeCard([enableHotkeyRow, shortcutRow])
        let hotkeySection = makeSection(symbol: "keyboard",
                                        title: "Global hotkey",
                                        content: hotkeyCard)

        // Compose pane.
        let pane = NSStackView(views: [audioSection, rotationSection, powerSection, hotkeySection])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = 20
        pane.distribution = .fill
        pane.setHuggingPriority(.defaultLow, for: .horizontal)
        fillWidth(pane)
        return pane
    }

    // MARK: About

    private func buildAboutPane() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 80).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 80).isActive = true

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let nameLabel = NSTextField(labelWithString: "LiveWall")
        nameLabel.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = NSFont.systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor
        let taglineLabel = NSTextField(labelWithString: "Live video wallpapers for macOS")
        taglineLabel.font = NSFont.systemFont(ofSize: 13)
        taglineLabel.textColor = .secondaryLabelColor

        titleStack.addArrangedSubview(nameLabel)
        titleStack.addArrangedSubview(versionLabel)
        titleStack.addArrangedSubview(taglineLabel)
        header.addArrangedSubview(iconView)
        header.addArrangedSubview(titleStack)

        let descLabel = NSTextField(wrappingLabelWithString:
            "A native macOS menu-bar app that turns your desktop into a video wallpaper. Built for OLED displays to keep pixels moving so they don't burn in.")
        descLabel.preferredMaxLayoutWidth = 480

        // Small "Signed and notarized by Apple" line. Both claims are
        // factual: the build is signed with a Developer ID Application cert
        // and stapled with an Apple notarisation ticket.
        let sealIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "checkmark.seal.fill", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            sealIcon.image = img.withSymbolConfiguration(cfg)
        }
        sealIcon.contentTintColor = .systemGreen
        sealIcon.translatesAutoresizingMaskIntoConstraints = false
        sealIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let notarizedLabel = NSTextField(labelWithString: "Signed and notarized by Apple")
        notarizedLabel.font = NSFont.systemFont(ofSize: 11)
        notarizedLabel.textColor = .secondaryLabelColor

        let notarizedRow = NSStackView(views: [sealIcon, notarizedLabel])
        notarizedRow.orientation = .horizontal
        notarizedRow.alignment = .centerY
        notarizedRow.spacing = 4

        let creditLabel = NSTextField(wrappingLabelWithString:
            "Built by Brendan. If LiveWall is useful to you, please consider supporting the project.")
        creditLabel.preferredMaxLayoutWidth = 480
        creditLabel.textColor = .secondaryLabelColor

        let supportBtn = NSButton(title: "  Buy me a coffee",
                                  target: self, action: #selector(supportClicked))
        if let heart = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            supportBtn.image = heart.withSymbolConfiguration(cfg)
            supportBtn.imagePosition = .imageLeft
        }
        supportBtn.bezelStyle = .rounded

        let feedbackBtn = NSButton(title: "  Send feedback",
                                   target: self, action: #selector(feedbackClicked))
        if let env = NSImage(systemSymbolName: "envelope", accessibilityDescription: nil) {
            feedbackBtn.image = env
            feedbackBtn.imagePosition = .imageLeft
        }
        feedbackBtn.bezelStyle = .rounded

        let updateBtn = NSButton(title: "  Check for updates",
                                 target: self, action: #selector(checkForUpdatesClicked))
        if let img = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil) {
            updateBtn.image = img
            updateBtn.imagePosition = .imageLeft
        }
        updateBtn.bezelStyle = .rounded

        let buttonRow = NSStackView(views: [supportBtn, feedbackBtn, updateBtn])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(descLabel)
        stack.addArrangedSubview(notarizedRow)
        stack.addArrangedSubview(creditLabel)
        stack.addArrangedSubview(buttonRow)

        return buildPaneShell(title: "About",
                              subtitle: "Version info and ways to support development",
                              content: stack)
    }

    // MARK: - Layout helpers

    /// Section header used inside a pane: small SF Symbol + bold title in the
    /// secondary label colour. Visually anchors a sub-section without being
    /// loud.
    private func makeSectionHeader(symbol: String, title: String) -> NSView {
        let icon = NSImageView()
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            icon.image = img.withSymbolConfiguration(cfg)
        }
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabelColor

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    /// Container for a sub-section: header on top (icon + title outside the
    /// card), card with rows below. Returns an NSStackView so callers can
    /// hide the whole group via `isHidden`.
    private func makeSection(symbol: String, title: String, content: NSView) -> NSStackView {
        let header = makeSectionHeader(symbol: symbol, title: title)
        let stack = NSStackView(views: [header, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // Make the section stretch to the pane width so the card inside
        // fills horizontally and every toggle pins to the same right edge.
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        // The card content must fill the section's width — without this it
        // sizes to its longest row's intrinsic width and toggles drift.
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    /// Pin every arranged subview of a vertical NSStackView to the stack's
    /// full width. NSStackView's `.alignment = .leading` doesn't stretch
    /// arranged views; we need explicit width constraints for the cards
    /// to all share a trailing edge.
    private func fillWidth(_ stack: NSStackView) {
        for sub in stack.arrangedSubviews {
            sub.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    /// 16-wide SF Symbol used as a row's leading icon. Drawn in secondary
    /// label colour so it doesn't compete with the row title.
    private func rowIcon(_ symbol: String) -> NSImageView {
        let iv = NSImageView()
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            iv.image = img.withSymbolConfiguration(cfg)
        }
        iv.contentTintColor = .secondaryLabelColor
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 18).isActive = true
        return iv
    }

    /// NSSwitch in the small control size. The default size feels too chunky
    /// for a settings list with this many toggles.
    private func smallSwitch(target: AnyObject?, action: Selector?) -> NSSwitch {
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.target = target
        sw.action = action
        return sw
    }

    /// One row inside a card: leading icon (optional) + title + flexible
    /// spacer + control. The spacer keeps every control at the card's right
    /// edge regardless of title length, so toggles all line up.
    private func makeRow(icon: String?, title: String, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = []
        if let icon = icon { views.append(rowIcon(icon)) }
        views.append(titleLabel)
        views.append(spacer)
        views.append(control)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        // Vertical padding so each row has breathing room inside its card.
        row.edgeInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
        return row
    }

    /// Wrap a list of rows in a rounded card with an internal padding and
    /// hairline separators between rows. The card fills the width of its
    /// parent so every row's trailing edge lines up.
    private func makeCard(_ rows: [NSView]) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.backgroundColor = NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 0
        inner.distribution = .fill
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)

        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 2),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -2),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
        ])

        for (i, row) in rows.enumerated() {
            if i > 0 {
                let sep = NSBox()
                sep.boxType = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                inner.addArrangedSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
                    sep.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
                ])
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            inner.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            ])
        }
        return card
    }

    // MARK: - Load values into controls

    private func loadValues() {
        let prefs = Preferences.shared

        // Master enable
        enableToggle.state = prefs.wallpaperEnabled ? .on : .off
        enableHintLabel.stringValue = enableHintText(on: prefs.wallpaperEnabled)

        // Source segmented
        switch prefs.contentMode {
        case .singleVideo:  sourceSegmented.selectedSegment = 0
        case .videoFolder:  sourceSegmented.selectedSegment = 1
        case .web:          sourceSegmented.selectedSegment = 2
        case .none:         sourceSegmented.selectedSegment = 0
        }
        refreshSourceUI()

        // Launch at login
        if #available(macOS 13.0, *) {
            launchAtLoginToggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            launchAtLoginToggle.isEnabled = true
        } else {
            launchAtLoginToggle.isEnabled = false
            launchAtLoginToggle.toolTip = "Requires macOS 13 or later"
        }

        // Show in dock
        showDockIconToggle.state = prefs.showDockIcon ? .on : .off

        // Display
        rebuildScreenCheckboxes()
        spacesToggle.state = prefs.allSpaces ? .on : .off
        let pct = Int(prefs.opacity * 100)
        opacitySlider.doubleValue = Double(pct)
        opacityValueLabel.stringValue = "\(pct)%"

        // Playback
        let interval = prefs.rotationInterval
        let mins = interval > 0 ? max(1, Int(interval / 60)) : 30
        rotateStepper.intValue = Int32(mins)
        rotateValueLabel.stringValue = "\(mins)"
        rotateToggle.state = (interval > 0) ? .on : .off
        rotateStepper.isEnabled = (interval > 0)

        muteToggle.state = prefs.muted ? .on : .off
        shuffleToggle.state = prefs.shuffle ? .on : .off
        crossFadeToggle.state = prefs.crossFade ? .on : .off
        pauseBatteryToggle.state = prefs.pauseOnBattery ? .on : .off
        pauseFullscreenToggle.state = prefs.pauseOnFullscreen ? .on : .off

        hotkeyRecorder.setHotkey(keyCode: prefs.hotkeyKeyCode, modifiers: prefs.hotkeyModifiers)
        hotkeyToggle.state = prefs.hotkeyEnabled ? .on : .off
        hotkeyRecorder.isEnabled = prefs.hotkeyEnabled
    }

    private func rebuildScreenCheckboxes() {
        screenCheckList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        screenCheckboxes.removeAll()

        let saved = Preferences.shared.targetScreenIDs   // nil = all
        for screen in NSScreen.screens {
            let id = WallpaperController.screenID(of: screen)
            let name: String
            if #available(macOS 10.15, *) { name = screen.localizedName }
            else { name = "Display \(id)" }
            let f = screen.frame
            let title = "\(name)   (\(Int(f.width))×\(Int(f.height)))"

            let cb = NSButton(checkboxWithTitle: title,
                              target: self,
                              action: #selector(screenCheckboxToggled(_:)))
            cb.state = (saved == nil || saved!.contains(id)) ? .on : .off

            // Per-display source popup.
            let popup = NSPopUpButton(frame: .zero, pullsDown: true)
            popup.bezelStyle = .rounded
            popup.tag = Int(id)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
            rebuildPerScreenSourceMenu(for: popup, displayID: id)

            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 16).isActive = true
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let label = NSTextField(labelWithString: "Source:")
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor

            let row = NSStackView(views: [cb, spacer, label, popup])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY

            screenCheckList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: screenCheckList.widthAnchor).isActive = true

            screenCheckboxes.append((cb, id))
        }
        updateScreenStatusLabel()
    }

    private func rebuildPerScreenSourceMenu(for popup: NSPopUpButton, displayID: UInt32) {
        let override = Preferences.shared.perScreenSources[displayID]
        let menu = NSMenu()

        // Item 0 = displayed title (in pulldown mode).
        let titleText: String
        if let o = override {
            if let mode = ContentMode(rawValue: o.mode), mode == .web {
                titleText = "🌐  " + o.path
            } else {
                titleText = (o.path as NSString).lastPathComponent
            }
        } else {
            titleText = "Default (global source)"
        }
        menu.addItem(NSMenuItem(title: titleText, action: nil, keyEquivalent: ""))

        // Default
        let useDefault = NSMenuItem(title: "Use global source",
                                    action: #selector(perScreenUseDefault(_:)),
                                    keyEquivalent: "")
        useDefault.target = self
        useDefault.tag = Int(displayID)
        useDefault.state = (override == nil) ? .on : .off
        menu.addItem(useDefault)

        menu.addItem(.separator())

        let chooseFile = NSMenuItem(title: "Choose File…",
                                    action: #selector(perScreenChooseFile(_:)),
                                    keyEquivalent: "")
        chooseFile.target = self
        chooseFile.tag = Int(displayID)
        menu.addItem(chooseFile)

        let setURL = NSMenuItem(title: "Set URL…",
                                action: #selector(perScreenSetURL(_:)),
                                keyEquivalent: "")
        setURL.target = self
        setURL.tag = Int(displayID)
        menu.addItem(setURL)

        // Recent — file/URL only (folders are global-only).
        let recents = Preferences.shared.recentSources.filter {
            ContentMode(rawValue: $0.mode) != .videoFolder
        }
        if !recents.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for r in recents.prefix(8) {
                let mode = ContentMode(rawValue: r.mode) ?? .none
                let label = mode == .web ? r.path : (r.path as NSString).lastPathComponent
                let item = NSMenuItem(title: "  " + label,
                                      action: #selector(perScreenRecentChosen(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.tag = Int(displayID)
                item.representedObject = r
                item.image = recentMenuIcon(for: mode)
                menu.addItem(item)
            }
        }

        popup.menu = menu
    }

    @objc private func perScreenUseDefault(_ sender: NSMenuItem) {
        let id = UInt32(sender.tag)
        Preferences.shared.setPerScreenSource(displayID: id, source: nil)
        controller?.reloadDisplay(id)
        rebuildScreenCheckboxes()
    }

    @objc private func perScreenChooseFile(_ sender: NSMenuItem) {
        let id = UInt32(sender.tag)
        let panel = NSOpenPanel()
        panel.title = "Choose a video file for this display"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let src = ContentSource(mode: ContentMode.singleVideo.rawValue, path: url.path)
            Preferences.shared.setPerScreenSource(displayID: id, source: src)
            Preferences.shared.pushRecent(mode: .singleVideo, path: url.path)
            controller?.reloadDisplay(id)
            rebuildScreenCheckboxes()
        }
    }

    @objc private func perScreenSetURL(_ sender: NSMenuItem) {
        let id = UInt32(sender.tag)
        let alert = NSAlert()
        alert.messageText = "Set URL for this display"
        alert.informativeText = "Paste a YouTube link or any webpage URL."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        if let existing = Preferences.shared.perScreenSources[id], existing.mode == ContentMode.web.rawValue {
            input.stringValue = existing.path
        }
        alert.accessoryView = input
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn {
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let src = ContentSource(mode: ContentMode.web.rawValue, path: trimmed)
                Preferences.shared.setPerScreenSource(displayID: id, source: src)
                Preferences.shared.pushRecent(mode: .web, path: trimmed)
                controller?.reloadDisplay(id)
                rebuildScreenCheckboxes()
            }
        }
    }

    @objc private func perScreenRecentChosen(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? RecentSource else { return }
        let id = UInt32(sender.tag)
        let src = ContentSource(mode: entry.mode, path: entry.path)
        Preferences.shared.setPerScreenSource(displayID: id, source: src)
        controller?.reloadDisplay(id)
        rebuildScreenCheckboxes()
    }

    private func updateScreenStatusLabel() {
        let total = screenCheckboxes.count
        let checked = screenCheckboxes.filter { $0.0.state == .on }.count
        if total == 0 {
            screenStatusLabel.stringValue = "No displays detected."
        } else if checked == total {
            screenStatusLabel.stringValue = "Showing on all \(total) display\(total == 1 ? "" : "s") (auto-includes new ones)."
        } else {
            screenStatusLabel.stringValue = "Showing on \(checked) of \(total) display\(total == 1 ? "" : "s")."
        }
    }

    private func refreshSourceUI() {
        let prefs = Preferences.shared

        // Path label + full-path tooltip
        switch prefs.contentMode {
        case .singleVideo:
            sourcePathLabel.stringValue = (prefs.contentPath as NSString?)?.lastPathComponent ?? "—"
            sourcePathLabel.toolTip = prefs.contentPath
        case .videoFolder:
            sourcePathLabel.stringValue = (prefs.contentPath as NSString?)?.lastPathComponent ?? "—"
            sourcePathLabel.toolTip = prefs.contentPath
        case .web:
            sourcePathLabel.stringValue = prefs.contentPath ?? "—"
            sourcePathLabel.toolTip = prefs.contentPath
        case .none:
            sourcePathLabel.stringValue = "Not set — click Browse, drop a video here, or pick from Recent"
            sourcePathLabel.toolTip = nil
        }

        // Thumbnail
        switch prefs.contentMode {
        case .singleVideo:
            if let p = prefs.contentPath {
                let url = URL(fileURLWithPath: p)
                sourceThumb.image = symbolPlaceholder("film")
                VideoThumbnail.generate(for: url, size: NSSize(width: 56, height: 36)) { [weak self] img in
                    if let img = img { self?.sourceThumb.image = img }
                }
            } else {
                sourceThumb.image = symbolPlaceholder("film")
            }
        case .videoFolder:
            sourceThumb.image = symbolPlaceholder("folder.fill")
        case .web:
            sourceThumb.image = symbolPlaceholder("globe")
        case .none:
            sourceThumb.image = symbolPlaceholder("questionmark.square.dashed")
        }

        // Show/hide the Rotation sub-section based on whether we're in
        // folder mode (rotation is meaningless for a single file or URL).
        rotationSection?.isHidden = (prefs.contentMode != .videoFolder)
    }

    private func symbolPlaceholder(_ name: String) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        return img.withSymbolConfiguration(cfg)
    }

    // MARK: - Actions

    @objc private func sourceTypeChanged() {
        // Switching the segment immediately prompts to set a source of that type.
        switch sourceSegmented.selectedSegment {
        case 0: chooseFile()
        case 1: chooseFolder()
        case 2: chooseURL()
        default: break
        }
    }

    @objc private func browseClicked() {
        sourceTypeChanged()
    }

    private func handleSourceDrop(_ urls: [URL]) {
        guard let url = urls.first else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            controller?.setVideoFolder(url)
        } else {
            controller?.setVideoFile(url)
        }
        loadValues()
    }

    @objc private func showRecentMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let recents = Preferences.shared.recentSources

        if recents.isEmpty {
            let empty = NSMenuItem(title: "No recent sources yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for r in recents {
                let mode = ContentMode(rawValue: r.mode) ?? .none
                let display: String
                switch mode {
                case .web:
                    display = r.path
                default:
                    display = (r.path as NSString).lastPathComponent
                }
                let item = NSMenuItem(title: display,
                                      action: #selector(recentChosen(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = r
                item.image = recentMenuIcon(for: mode)
                item.toolTip = r.path
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Recents",
                                   action: #selector(clearRecentsClicked),
                                   keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        let location = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: sender)
    }

    private func recentMenuIcon(for mode: ContentMode) -> NSImage? {
        let name: String
        switch mode {
        case .singleVideo: name = "film"
        case .videoFolder: name = "folder.fill"
        case .web:         name = "globe"
        case .none:        name = "questionmark.square.dashed"
        }
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return img.withSymbolConfiguration(cfg)
    }

    @objc private func recentChosen(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? RecentSource,
              let mode = ContentMode(rawValue: entry.mode) else { return }
        switch mode {
        case .singleVideo:
            controller?.setVideoFile(URL(fileURLWithPath: entry.path))
        case .videoFolder:
            controller?.setVideoFolder(URL(fileURLWithPath: entry.path))
        case .web:
            controller?.setWebURL(entry.path)
        case .none:
            break
        }
        loadValues()
    }

    @objc private func clearRecentsClicked() {
        Preferences.shared.clearRecents()
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a video file"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            controller?.setVideoFile(url)
        }
        loadValues()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder of videos"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            controller?.setVideoFolder(url)
        }
        loadValues()
    }

    private func chooseURL() {
        let alert = NSAlert()
        alert.messageText = "Set Web URL"
        alert.informativeText = "Paste a YouTube link or any webpage URL."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        if Preferences.shared.contentMode == .web, let s = Preferences.shared.contentPath {
            input.stringValue = s
        }
        alert.accessoryView = input
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        // Without this the text field isn't first responder on open, so the
        // user's paste shortcut has nothing to land in.
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn {
            controller?.setWebURL(input.stringValue)
        }
        loadValues()
    }

    @objc private func enableToggleChanged() {
        controller?.setEnabled(enableToggle.state == .on)
        enableHintLabel.stringValue = enableHintText(on: enableToggle.state == .on)
    }

    @objc private func launchAtLoginChanged() {
        let on = (launchAtLoginToggle.state == .on)
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
                let path = Bundle.main.bundlePath
                if !path.hasPrefix("/Applications/") {
                    let warn = NSAlert()
                    warn.messageText = "Move LiveWall to /Applications"
                    warn.informativeText = "Launch at login is registered, but for it to keep working after a reboot the app should live in /Applications/. Currently it's at:\n\n\(path)"
                    warn.alertStyle = .warning
                    warn.addButton(withTitle: "OK")
                    warn.runModal()
                }
            } else {
                try service.unregister()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            launchAtLoginToggle.state = (service.status == .enabled) ? .on : .off
        }
    }

    @objc private func showDockIconChanged() {
        Preferences.shared.showDockIcon = (showDockIconToggle.state == .on)
        (NSApp.delegate as? AppDelegate)?.applyDockIconVisibility()
    }

    @objc private func resetAllClicked() {
        let alert = NSAlert()
        alert.messageText = "Reset all LiveWall settings?"
        alert.informativeText = "This restores defaults: source, rotation, opacity, target display, hotkey, and audio. Launch at Login is not touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Preferences.shared.resetAll()
            controller?.reconfigureScreens()
            (NSApp.delegate as? AppDelegate)?.applyHotkeyFromPrefs()
            loadValues()
        }
    }

    @objc private func screenCheckboxToggled(_ sender: NSButton) {
        // Don't allow zero displays — bounce the toggle back if user tried.
        let checkedCount = screenCheckboxes.filter { $0.0.state == .on }.count
        if checkedCount == 0 {
            sender.state = .on
            NSSound.beep()
            return
        }

        let total = screenCheckboxes.count
        if checkedCount == total {
            // All checked → store nil so any future displays auto-join.
            Preferences.shared.targetScreenIDs = nil
        } else {
            let checkedIDs = screenCheckboxes
                .filter { $0.0.state == .on }
                .map { $0.1 }
            Preferences.shared.targetScreenIDs = checkedIDs
        }
        updateScreenStatusLabel()
        controller?.reconfigureScreens()
    }

    @objc private func spacesChanged() {
        controller?.setShowOnAllSpaces(spacesToggle.state == .on)
    }

    @objc private func opacityChanged() {
        let v = opacitySlider.doubleValue
        opacityValueLabel.stringValue = "\(Int(v))%"
        controller?.setOpacity(v / 100.0)
    }

    @objc private func rotateStepperChanged() {
        let mins = Int(rotateStepper.intValue)
        rotateValueLabel.stringValue = "\(mins)"
        if rotateToggle.state == .on {
            controller?.setRotationInterval(TimeInterval(mins * 60))
        }
    }

    @objc private func rotateToggleChanged() {
        let on = (rotateToggle.state == .on)
        rotateStepper.isEnabled = on
        if on {
            let mins = Int(rotateStepper.intValue)
            controller?.setRotationInterval(TimeInterval(mins * 60))
        } else {
            controller?.setRotationInterval(0)
        }
    }

    @objc private func muteChanged() {
        controller?.setMuted(muteToggle.state == .on)
    }

    @objc private func shuffleChanged() {
        Preferences.shared.shuffle = (shuffleToggle.state == .on)
    }

    @objc private func crossFadeChanged() {
        Preferences.shared.crossFade = (crossFadeToggle.state == .on)
    }

    @objc private func pauseBatteryChanged() {
        Preferences.shared.pauseOnBattery = (pauseBatteryToggle.state == .on)
        (NSApp.delegate as? AppDelegate)?.refreshPowerPause()
    }

    @objc private func pauseFullscreenChanged() {
        Preferences.shared.pauseOnFullscreen = (pauseFullscreenToggle.state == .on)
        (NSApp.delegate as? AppDelegate)?.refreshPowerPause()
    }

    @objc private func hotkeyToggleChanged() {
        let on = (hotkeyToggle.state == .on)
        Preferences.shared.hotkeyEnabled = on
        hotkeyRecorder.isEnabled = on
        (NSApp.delegate as? AppDelegate)?.applyHotkeyFromPrefs()
    }

    @objc private func supportClicked() {
        if let url = URL(string: SUPPORT_URL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func feedbackClicked() {
        // Opens the public Google Form in the default browser. Submissions
        // land in the form's response sheet — no mail client involved.
        guard let url = URL(string: FEEDBACK_FORM_URL) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdatesClicked() {
        (NSApp.delegate as? AppDelegate)?.checkForUpdates()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        // No-op for now.
    }
}

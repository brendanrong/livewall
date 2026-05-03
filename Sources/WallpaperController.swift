import Cocoa

final class WallpaperController {
    static let enabledStateChangedNotification = Notification.Name("LiveWall.enabledStateChanged")

    private var windows: [WallpaperWindow] = []
    private var rotationTimer: Timer?

    /// Global folder-mode playlist (only used when the GLOBAL source is a
    /// folder — per-display overrides only support file/URL, not folders).
    private var videoFiles: [URL] = []
    private var currentIndex = 0

    /// True when playback is suspended for power-saving reasons. UI controls
    /// (mute / opacity / source) still work; we just stop the rate.
    private var pausedByPower = false

    // MARK: - Lifecycle

    func start() {
        if Preferences.shared.wallpaperEnabled {
            loadFromPreferences()
        }
    }

    func handleScreenChange() {
        teardownAllWindows()
        replayCurrentContent()
    }

    // MARK: - Master enable / disable

    func setEnabled(_ on: Bool) {
        Preferences.shared.wallpaperEnabled = on
        if on {
            replayCurrentContent()
        } else {
            rotationTimer?.invalidate()
            rotationTimer = nil
            teardownAllWindows()
        }
        NotificationCenter.default.post(
            name: Self.enabledStateChangedNotification, object: nil
        )
    }

    func toggleEnabled() {
        setEnabled(!Preferences.shared.wallpaperEnabled)
    }

    // MARK: - Public source actions (global)

    func setVideoFile(_ url: URL) {
        Preferences.shared.contentMode = .singleVideo
        Preferences.shared.contentPath = url.path
        Preferences.shared.pushRecent(mode: .singleVideo, path: url.path)
        videoFiles = []
        currentIndex = 0
        rotationTimer?.invalidate()
        rotationTimer = nil
        showCurrent()
    }

    func setVideoFolder(_ url: URL) {
        let found = loadVideosFromFolder(url)
        if found.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No videos found in this folder"
            alert.informativeText = "LiveWall plays .mp4, .mov, and .m4v files. Pick a folder that contains at least one of those."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        Preferences.shared.contentMode = .videoFolder
        Preferences.shared.contentPath = url.path
        Preferences.shared.pushRecent(mode: .videoFolder, path: url.path)
        videoFiles = found
        currentIndex = 0
        showCurrent()
        startRotation()
    }

    func setWebURL(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Preferences.shared.contentMode = .web
        Preferences.shared.contentPath = trimmed
        Preferences.shared.pushRecent(mode: .web, path: trimmed)
        videoFiles = []
        currentIndex = 0
        rotationTimer?.invalidate()
        rotationTimer = nil
        showCurrent()
    }

    func setRotationInterval(_ seconds: TimeInterval) {
        Preferences.shared.rotationInterval = seconds
        startRotation()
    }

    func setMuted(_ muted: Bool) {
        Preferences.shared.muted = muted
        applyMuteAcrossWindows()
    }

    /// Skip immediately to the next video in folder-rotation mode.
    func nextVideo() {
        advanceVideo()
    }

    func togglePaused() {
        windows.forEach { $0.togglePaused() }
    }

    func setOpacity(_ value: Double) {
        Preferences.shared.opacity = value
        windows.forEach { $0.setOpacity(value) }
    }

    func setShowOnAllSpaces(_ on: Bool) {
        Preferences.shared.allSpaces = on
        windows.forEach { $0.setAllSpaces(on) }
    }

    /// Tell the controller a per-display override changed. We just reload
    /// that one display rather than every window.
    func reloadDisplay(_ displayID: UInt32) {
        guard let w = windows.first(where: { $0.displayID == displayID }) else { return }
        applyResolvedSource(to: w, fade: false)
    }

    // MARK: - Power state coordination

    func setPausedByPower(_ paused: Bool) {
        guard pausedByPower != paused else { return }
        pausedByPower = paused
        for w in windows { w.setPlaybackPaused(paused) }
    }

    // MARK: - Private — plumbing

    private func replayCurrentContent() {
        showCurrent()
        if Preferences.shared.contentMode == .videoFolder {
            startRotation()
        }
    }

    /// (Re)apply each window's resolved source. Also (re)applies opacity,
    /// spaces behavior, and pause-by-power.
    private func showCurrent() {
        ensureWindows()
        for w in windows {
            applyResolvedSource(to: w, fade: false)
        }
        if pausedByPower {
            for w in windows { w.setPlaybackPaused(true) }
        }
    }

    /// Resolve and apply the right source for a single window.
    private func applyResolvedSource(to w: WallpaperWindow, fade: Bool) {
        let src = resolveSource(for: w.displayID)
        guard let mode = ContentMode(rawValue: src.mode) else { return }
        switch mode {
        case .singleVideo:
            let url = URL(fileURLWithPath: src.path)
            w.showVideo(url: url, muted: shouldMute(window: w), fade: fade)
        case .videoFolder:
            // Folders are only valid as the GLOBAL source. The current rotation
            // file applies to every folder-mode window.
            guard !videoFiles.isEmpty else { return }
            let url = videoFiles[currentIndex % videoFiles.count]
            w.showVideo(url: url, muted: shouldMute(window: w), fade: fade)
        case .web:
            let normalized = normalizeURL(src.path)
            if let url = URL(string: normalized) {
                w.showWeb(url: url)
            }
        case .none:
            break
        }
    }

    /// What source should the given displayID actually use?
    /// Per-display overrides win; otherwise the global source.
    private func resolveSource(for displayID: UInt32) -> ContentSource {
        if let override = Preferences.shared.perScreenSources[displayID] {
            return override
        }
        let mode = Preferences.shared.contentMode
        let path = Preferences.shared.contentPath ?? ""
        return ContentSource(mode: mode.rawValue, path: path)
    }

    /// Rule: only the first window emits audio (avoid stacked tracks).
    private func shouldMute(window: WallpaperWindow) -> Bool {
        if Preferences.shared.muted { return true }
        guard let first = windows.first else { return false }
        return first.displayID != window.displayID
    }

    private func ensureWindows() {
        guard Preferences.shared.wallpaperEnabled else { return }

        let screens = targetScreens()
        guard !screens.isEmpty else { return }
        guard windows.count != screens.count else { return }
        teardownAllWindows()
        for screen in screens {
            let w = WallpaperWindow(targetScreen: screen)
            w.setOpacity(Preferences.shared.opacity)
            w.setAllSpaces(Preferences.shared.allSpaces)
            w.orderFront(nil)
            windows.append(w)
        }
    }

    private func targetScreens() -> [NSScreen] {
        let all = NSScreen.screens
        guard !all.isEmpty else { return [] }
        guard let wanted = Preferences.shared.targetScreenIDs, !wanted.isEmpty else {
            return all
        }
        let filtered = all.filter { wanted.contains(Self.screenID(of: $0)) }
        return filtered.isEmpty ? [NSScreen.main ?? all[0]] : filtered
    }

    static func screenID(of screen: NSScreen) -> UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let n = screen.deviceDescription[key] as? NSNumber {
            return n.uint32Value
        }
        return 0
    }

    func reconfigureScreens() {
        teardownAllWindows()
        replayCurrentContent()
    }

    private func teardownAllWindows() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
    }

    private func applyMuteAcrossWindows() {
        for w in windows {
            w.setMuted(shouldMute(window: w))
        }
    }

    /// Pure: returns the list of playable video files in `url`. Caller decides
    /// whether to assign to `videoFiles` and what to do on empty.
    private func loadVideosFromFolder(_ url: URL) -> [URL] {
        let exts: Set<String> = ["mp4", "mov", "m4v"]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func startRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        let interval = Preferences.shared.rotationInterval
        guard interval > 0, videoFiles.count > 1 else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceVideo()
        }
    }

    private func advanceVideo() {
        guard videoFiles.count > 1 else { return }
        if Preferences.shared.shuffle {
            // Random index that isn't the current one.
            var next = Int.random(in: 0..<videoFiles.count)
            if next == currentIndex { next = (next + 1) % videoFiles.count }
            currentIndex = next
        } else {
            currentIndex = (currentIndex + 1) % videoFiles.count
        }
        let url = videoFiles[currentIndex]
        let fade = Preferences.shared.crossFade
        for w in windows {
            let src = resolveSource(for: w.displayID)
            if src.mode == ContentMode.videoFolder.rawValue {
                w.showVideo(url: url, muted: shouldMute(window: w), fade: fade)
            }
        }
    }

    private func loadFromPreferences() {
        let prefs = Preferences.shared
        switch prefs.contentMode {
        case .singleVideo:
            if let path = prefs.contentPath, FileManager.default.fileExists(atPath: path) {
                videoFiles = []
                showCurrent()
            }
        case .videoFolder:
            if let path = prefs.contentPath, FileManager.default.fileExists(atPath: path) {
                videoFiles = loadVideosFromFolder(URL(fileURLWithPath: path))
                showCurrent()
                startRotation()
            }
        case .web:
            if prefs.contentPath != nil {
                videoFiles = []
                showCurrent()
            }
        case .none:
            break
        }
    }

    // MARK: - URL normalization

    private func normalizeURL(_ input: String) -> String {
        var s = input
        if !s.lowercased().hasPrefix("http") {
            s = "https://" + s
        }
        if let id = extractYouTubeID(s) {
            // youtube-nocookie.com is the privacy-enhanced embed domain.
            // It avoids YouTube's "Error 153: video player configuration"
            // failure that the regular youtube.com embed often returns
            // inside a WKWebView, and it skips most cookie/origin checks.
            return "https://www.youtube-nocookie.com/embed/\(id)" +
                "?autoplay=1&mute=1&loop=1&playlist=\(id)" +
                "&controls=0&modestbranding=1&rel=0&iv_load_policy=3"
        }
        return s
    }

    private func extractYouTubeID(_ url: String) -> String? {
        let patterns = [
            #"youtube\.com/watch\?[^ ]*v=([\w-]{6,})"#,
            #"youtu\.be/([\w-]{6,})"#,
            #"youtube\.com/embed/([\w-]{6,})"#,
            #"youtube\.com/shorts/([\w-]{6,})"#
        ]
        for p in patterns {
            guard let regex = try? NSRegularExpression(pattern: p) else { continue }
            let range = NSRange(url.startIndex..., in: url)
            if let match = regex.firstMatch(in: url, range: range),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: url) {
                return String(url[r])
            }
        }
        return nil
    }
}

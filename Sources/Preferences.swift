import Foundation

enum ContentMode: String {
    case none
    case singleVideo
    case videoFolder
    case web
}

/// One past wallpaper source the user picked. Stored as JSON in UserDefaults.
struct RecentSource: Codable, Equatable {
    let mode: String       // ContentMode raw value
    let path: String
    let lastUsed: TimeInterval
}

/// Per-display override of the global source.
struct ContentSource: Codable, Equatable {
    let mode: String       // ContentMode raw value
    let path: String
}

final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private enum Key {
        static let contentMode = "contentMode"
        static let contentPath = "contentPath"
        static let rotationInterval = "rotationInterval"
        static let muted = "muted"
        static let opacity = "opacity"
        static let allSpaces = "allSpaces"
        // New: explicit set of displays to paint on. nil = all displays.
        static let targetScreenIDs = "targetScreenIDs"
        // Legacy keys (still cleared on resetAll for users coming from older builds).
        static let targetScreenMode = "targetScreenMode"
        static let targetScreenID = "targetScreenID"
        static let hotkeyEnabled = "hotkeyEnabled"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let recentSources = "recentSources"
        static let wallpaperEnabled = "wallpaperEnabled"
        static let pauseOnBattery = "pauseOnBattery"
        static let pauseOnFullscreen = "pauseOnFullscreen"
        static let shuffle = "shuffle"
        static let lastSettingsSection = "lastSettingsSection"
        static let crossFade = "crossFade"
        static let perScreenSources = "perScreenSources"
        static let hasCompletedFirstLaunch = "hasCompletedFirstLaunch"
        static let showDockIcon = "showDockIcon"
        // Generate pane: remembered model / resolution / duration
        static let generateModel = "generateModel"
        static let generateResolution = "generateResolution"
        static let generateDuration = "generateDuration"

        static let allKeys: [String] = [
            contentMode, contentPath, rotationInterval, muted, opacity, allSpaces,
            targetScreenIDs, targetScreenMode, targetScreenID,
            hotkeyEnabled, hotkeyKeyCode, hotkeyModifiers,
            recentSources, wallpaperEnabled,
            pauseOnBattery, pauseOnFullscreen, shuffle, lastSettingsSection,
            crossFade, perScreenSources, hasCompletedFirstLaunch, showDockIcon,
            generateModel, generateResolution, generateDuration,
        ]
    }

    static let recentLimit = 10

    var contentMode: ContentMode {
        get { ContentMode(rawValue: defaults.string(forKey: Key.contentMode) ?? "") ?? .none }
        set { defaults.set(newValue.rawValue, forKey: Key.contentMode) }
    }

    var contentPath: String? {
        get { defaults.string(forKey: Key.contentPath) }
        set { defaults.set(newValue, forKey: Key.contentPath) }
    }

    var rotationInterval: TimeInterval {
        get { defaults.double(forKey: Key.rotationInterval) }
        set { defaults.set(newValue, forKey: Key.rotationInterval) }
    }

    var muted: Bool {
        get {
            if defaults.object(forKey: Key.muted) == nil { return true }
            return defaults.bool(forKey: Key.muted)
        }
        set { defaults.set(newValue, forKey: Key.muted) }
    }

    /// 0.0 ... 1.0
    var opacity: Double {
        get {
            if defaults.object(forKey: Key.opacity) == nil { return 1.0 }
            return defaults.double(forKey: Key.opacity)
        }
        set { defaults.set(max(0.0, min(1.0, newValue)), forKey: Key.opacity) }
    }

    var allSpaces: Bool {
        get {
            if defaults.object(forKey: Key.allSpaces) == nil { return true }
            return defaults.bool(forKey: Key.allSpaces)
        }
        set { defaults.set(newValue, forKey: Key.allSpaces) }
    }

    /// Explicit set of CGDirectDisplayIDs to paint on. `nil` (the default)
    /// means "all displays, including any added later". Stored as `[Int]`
    /// because UserDefaults can't natively hold UInt32 arrays.
    var targetScreenIDs: [UInt32]? {
        get {
            guard let arr = defaults.array(forKey: Key.targetScreenIDs) as? [Int] else { return nil }
            return arr.map { UInt32($0) }
        }
        set {
            if let v = newValue { defaults.set(v.map { Int($0) }, forKey: Key.targetScreenIDs) }
            else { defaults.removeObject(forKey: Key.targetScreenIDs) }
        }
    }

    /// Master switch — when false, every wallpaper window is torn down and
    /// the normal desktop is visible. The configured source/folder/url is
    /// preserved so flipping back on resumes where you left off.
    var wallpaperEnabled: Bool {
        get {
            if defaults.object(forKey: Key.wallpaperEnabled) == nil { return true }
            return defaults.bool(forKey: Key.wallpaperEnabled)
        }
        set { defaults.set(newValue, forKey: Key.wallpaperEnabled) }
    }

    var hotkeyEnabled: Bool {
        get {
            if defaults.object(forKey: Key.hotkeyEnabled) == nil { return true }
            return defaults.bool(forKey: Key.hotkeyEnabled)
        }
        set { defaults.set(newValue, forKey: Key.hotkeyEnabled) }
    }

    /// Carbon virtual key code (e.g. kVK_ANSI_P = 35). Default ⌘⌥P.
    /// Note: kVK_ANSI_A == 0, so we must distinguish "unset" from "zero"
    /// via `object(forKey:)` rather than `integer(forKey:)`.
    var hotkeyKeyCode: UInt32 {
        get {
            guard defaults.object(forKey: Key.hotkeyKeyCode) != nil else { return 35 } // P
            return UInt32(defaults.integer(forKey: Key.hotkeyKeyCode))
        }
        set { defaults.set(Int(newValue), forKey: Key.hotkeyKeyCode) }
    }

    /// Carbon modifier mask (cmdKey | optionKey | …). Default cmd+option.
    var hotkeyModifiers: UInt32 {
        get {
            guard defaults.object(forKey: Key.hotkeyModifiers) != nil else {
                return UInt32(1 << 8) | UInt32(1 << 11) // cmdKey | optionKey
            }
            return UInt32(defaults.integer(forKey: Key.hotkeyModifiers))
        }
        set { defaults.set(Int(newValue), forKey: Key.hotkeyModifiers) }
    }

    // MARK: - Recent sources

    var recentSources: [RecentSource] {
        get {
            guard let data = defaults.data(forKey: Key.recentSources) else { return [] }
            return (try? JSONDecoder().decode([RecentSource].self, from: data)) ?? []
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.recentSources)
        }
    }

    /// Push a new entry to the front of the recents list, dedup by (mode, path),
    /// cap at `recentLimit`.
    func pushRecent(mode: ContentMode, path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, mode != .none else { return }
        var list = recentSources
        list.removeAll { $0.mode == mode.rawValue && $0.path == trimmed }
        list.insert(RecentSource(mode: mode.rawValue, path: trimmed,
                                 lastUsed: Date().timeIntervalSince1970), at: 0)
        if list.count > Preferences.recentLimit {
            list = Array(list.prefix(Preferences.recentLimit))
        }
        recentSources = list
    }

    func clearRecents() {
        recentSources = []
    }

    // MARK: - Power & playback flags

    var pauseOnBattery: Bool {
        get {
            if defaults.object(forKey: Key.pauseOnBattery) == nil { return false }
            return defaults.bool(forKey: Key.pauseOnBattery)
        }
        set { defaults.set(newValue, forKey: Key.pauseOnBattery) }
    }

    var pauseOnFullscreen: Bool {
        get {
            if defaults.object(forKey: Key.pauseOnFullscreen) == nil { return true }
            return defaults.bool(forKey: Key.pauseOnFullscreen)
        }
        set { defaults.set(newValue, forKey: Key.pauseOnFullscreen) }
    }

    var shuffle: Bool {
        get { defaults.bool(forKey: Key.shuffle) }
        set { defaults.set(newValue, forKey: Key.shuffle) }
    }

    /// True after the user has seen Settings at least once (auto-shown on
    /// first launch). Stays true forever after that.
    var hasCompletedFirstLaunch: Bool {
        get { defaults.bool(forKey: Key.hasCompletedFirstLaunch) }
        set { defaults.set(newValue, forKey: Key.hasCompletedFirstLaunch) }
    }

    /// Whether the LiveWall app icon shows in the macOS dock. Default true.
    /// When false, the app behaves as a traditional menu-bar utility.
    var showDockIcon: Bool {
        get {
            if defaults.object(forKey: Key.showDockIcon) == nil { return true }
            return defaults.bool(forKey: Key.showDockIcon)
        }
        set { defaults.set(newValue, forKey: Key.showDockIcon) }
    }

    var crossFade: Bool {
        get {
            if defaults.object(forKey: Key.crossFade) == nil { return true }
            return defaults.bool(forKey: Key.crossFade)
        }
        set { defaults.set(newValue, forKey: Key.crossFade) }
    }

    /// Last visible Settings section (e.g. "general", "display"). nil → default.
    var lastSettingsSection: String? {
        get { defaults.string(forKey: Key.lastSettingsSection) }
        set { defaults.set(newValue, forKey: Key.lastSettingsSection) }
    }

    // MARK: - Per-display source overrides

    /// Map of CGDirectDisplayID (as String key) → ContentSource override.
    /// Stored as JSON because UserDefaults can't natively hold a [String: Codable].
    var perScreenSources: [UInt32: ContentSource] {
        get {
            guard let data = defaults.data(forKey: Key.perScreenSources),
                  let raw = try? JSONDecoder().decode([String: ContentSource].self, from: data)
            else { return [:] }
            var out: [UInt32: ContentSource] = [:]
            for (k, v) in raw { if let id = UInt32(k) { out[id] = v } }
            return out
        }
        set {
            var raw: [String: ContentSource] = [:]
            for (k, v) in newValue { raw[String(k)] = v }
            let data = try? JSONEncoder().encode(raw)
            defaults.set(data, forKey: Key.perScreenSources)
        }
    }

    func setPerScreenSource(displayID: UInt32, source: ContentSource?) {
        var map = perScreenSources
        if let source = source { map[displayID] = source }
        else { map.removeValue(forKey: displayID) }
        perScreenSources = map
    }

    // MARK: - Generate pane state

    /// Last-selected video model in the Generate pane. Default: LTX 2.3 Pro
    /// (highest quality of the four; goes up to 1440p).
    var generateModel: String {
        get { defaults.string(forKey: Key.generateModel) ?? "ltxv-2.3-pro" }
        set { defaults.set(newValue, forKey: Key.generateModel) }
    }

    /// Last-selected resolution mode. Default: 1440p (LTX 2.3 Pro's
    /// top resolution). The dropdown clamps to whatever the picked
    /// model actually supports.
    var generateResolution: String {
        get { defaults.string(forKey: Key.generateResolution) ?? "RESOLUTION_1440" }
        set { defaults.set(newValue, forKey: Key.generateResolution) }
    }

    /// Last-selected duration in seconds. Default: 8s (matches Veo default).
    var generateDuration: Int {
        get {
            if defaults.object(forKey: Key.generateDuration) == nil { return 8 }
            return defaults.integer(forKey: Key.generateDuration)
        }
        set { defaults.set(newValue, forKey: Key.generateDuration) }
    }

    /// Wipe every key this app stores. Intentionally does NOT touch
    /// SMAppService (Launch at Login) — that's a system service.
    func resetAll() {
        for k in Key.allKeys { defaults.removeObject(forKey: k) }
    }
}

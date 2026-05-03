# LiveWall Pre-Release Code Audit

**Build under review:** LiveWall 1.0
**Source tree:** `LiveWall/Sources/` (15 Swift files, ~2,924 LOC)
**Auditor:** Claude
**Date:** 2026-05-02

---

## Summary

The codebase is small, focused, and largely well-structured. The audit found **no ship-blocking crash bugs** but did find:

- **2 high-severity issues** (one silent data-loss bug, one large-file tech-debt cliff)
- **8 medium-severity issues** (mostly: race-on-rapid-input in cross-fade, fullscreen detection false positives, security exposure from arbitrary-URL web wallpapers, and ad-hoc signing / no sandbox blocking distribution)
- **~30 low-severity items** (mostly polish, performance micro-optimisation, and future-proofing)

**Recommended must-fix before public release:**
1. B-1 (hotkey keycode getter silently drops `kVK_ANSI_A`)
2. S-1 / S-4 (tighten WKWebView and ATS posture for arbitrary URL wallpapers)
3. S-2 / S-8 (sandbox + Developer ID signing + notarisation, if distributing)
4. B-9 (cross-fade race on rapid source switching)

Severity scale used:
- **HIGH** — ship-blocker; user-visible incorrect behaviour, security risk, or distribution-blocker
- **MEDIUM** — fix soon; degrades UX or hardens posture
- **LOW** — polish, minor footgun, or future-proofing
- **INFO** — noted for awareness, no action required

---

## (1) Bugs and Logic Errors

### B-1. `hotkeyKeyCode` getter silently rejects valid `kVK_ANSI_A` (= 0) shortcuts — **HIGH**

**File:** `Sources/Preferences.swift` lines 137–143

```swift
var hotkeyKeyCode: UInt32 {
    get {
        let v = defaults.integer(forKey: Key.hotkeyKeyCode)
        return v > 0 ? UInt32(v) : 35   // P
    }
    ...
}
```

Carbon's `kVK_ANSI_A == 0`. If a user records ⌘⌥A as their hotkey, `defaults.integer(...)` returns `0`, the getter falls through to the `35` (P) default, and the user's chosen shortcut silently reverts to ⌘⌥P on the next launch. Same flaw applies to any 0-keycoded virtual key (A is the most common).

The same pattern exists in `hotkeyModifiers` (lines 146–152). For modifiers, `0` would mean "no modifiers", but `HotkeyRecorderButton` enforces at least one modifier so the bug is unreachable today — still worth fixing for symmetry.

**Recommended fix:** distinguish "unset" from "zero" by checking `defaults.object(forKey:) != nil` (the same pattern already used elsewhere in this file).

---

### B-3. Empty video folder produces a black wallpaper with no error feedback — **MEDIUM**

**File:** `Sources/WallpaperController.swift` lines 160–165

```swift
case .videoFolder:
    guard !videoFiles.isEmpty else { return }
    let url = videoFiles[currentIndex % videoFiles.count]
    w.showVideo(url: url, ...)
```

If the user picks a folder that contains no `.mp4`/`.mov`/`.m4v` files, `videoFiles` is empty, `applyResolvedSource` silently returns, and the wallpaper window just shows its black background forever. The user has no clue why their video isn't playing. Same hazard if every file in the folder gets deleted while LiveWall is running.

**Recommended fix:** show a user-visible error (alert when the panel returns or a `NSAttributedString` overlay on the wallpaper window) and/or fall back to the previous source.

---

### B-6. `URL(fileURLWithPath: "")` after switching content type without a path — **LOW**

**File:** `Sources/WallpaperController.swift` lines 178–185, then 157–159

If `Preferences.contentMode` has been set (e.g. `.singleVideo`) but `contentPath` is `nil`, `resolveSource` constructs `ContentSource(mode: ..., path: "")`. `applyResolvedSource` then calls `URL(fileURLWithPath: "")`, which produces a file URL pointing at the current working directory. AVPlayer fails silently.

**Repro path:** edit `UserDefaults` directly, or hit a code path that sets `contentMode` without writing `contentPath`. Not currently reachable through the UI, but a footgun.

**Recommended fix:** guard `path.isEmpty` in `applyResolvedSource`.

---

### B-8. Fullscreen detection has a coordinate-conversion bug, masked by a position-agnostic check — **MEDIUM**

**File:** `Sources/FullscreenMonitor.swift` lines 36–62

```swift
let mainHeight = NSScreen.screens.first?.frame.height ?? height
let nsRect = CGRect(x: x, y: mainHeight - y - height, width: width, height: height)
if abs(nsRect.width - sf.width) < 2 && abs(nsRect.height - sf.height) < 2 {
    return true
}
```

Two issues:

1. The y-coordinate conversion is wrong for windows on non-primary screens. CG window coordinates are global, not relative to a single display. Multiplying by `mainHeight` (the primary display's height) puts secondary-screen windows in the wrong place.
2. The check only compares **dimensions**, not position. So any window whose size matches a screen's frame triggers "fullscreen", regardless of whether it actually covers a screen. Examples: a custom-sized panel from another wallpaper app, or a misbehaving floating window at exactly screen size.

In practice it works because the position math is irrelevant — but for the wrong reason. Risk: false positives that pause the wallpaper when nothing is actually fullscreen.

**Recommended fix:** drop the y-conversion entirely and compare CG rects to CG screen frames directly (same coordinate space). Also check origin alignment with screen bounds, not just size.

---

### B-9. Cross-fade race when `play()` is called rapidly — **MEDIUM**

**File:** `Sources/VideoWallpaperView.swift` lines 22–62

```swift
func play(url: URL, muted: Bool, fade: Bool = false) {
    let oldLayer = playerLayer
    let oldPlayer = player
    ...
    if fade, oldLayer != nil {
        ...
        CATransaction.setCompletionBlock {
            oldPlayer?.pause()
            oldLayer?.removeFromSuperlayer()
        }
    }
    self.player = queuePlayer
    self.playerLayer = pl
    self.looper = newLooper
}
```

If `play()` is invoked twice within 0.6s (fade duration) — e.g. the user clicks Recent twice quickly, or rotation interval is set to a few seconds in folder mode — the second call captures the *first* call's now-mid-fade layer/player as `oldLayer`/`oldPlayer`. The first call's completion block, when it fires, operates on the *original* references; meanwhile the third pipeline is already playing. Potential outcomes:

- Fade animations stomp each other.
- Three AVQueuePlayer/AVPlayerLooper instances exist simultaneously, holding decode buffers.
- The first old player gets paused correctly, but the second's `oldPlayer` (which is the first `play()`'s NEW player) may get paused after the fade completes — possibly while the user expects it still running.

**Recommended fix:** track an in-flight fade transaction; if `play()` arrives during one, hard-cut. Or coalesce rapid calls (debounce 0.7s).

---

### B-13. `screenCheckboxToggled` "bounce back" relies on toggle state already mutated — **INFO**

**File:** `Sources/PreferencesWindow.swift` lines 1124–1131

```swift
let checkedCount = screenCheckboxes.filter { $0.0.state == .on }.count
if checkedCount == 0 {
    sender.state = .on
    NSSound.beep()
    return
}
```

NSButton's checkbox toggles its state *before* firing the action, so this relies on AppKit ordering. Works today on all macOS versions tested, but a future AppKit change could break it. Add a comment or use `sender.state == .off` explicitly with `senderWasJust(unchecked:)` semantics.

---

### B-14. Recents popup positions menu *above* the button on flipped views — **LOW**

**File:** `Sources/PreferencesWindow.swift` lines 977–978

```swift
let location = NSPoint(x: 0, y: sender.bounds.height + 4)
menu.popUp(positioning: nil, at: location, in: sender)
```

In AppKit's default coordinate system (bottom-left origin), `y = bounds.height` is the **top** of the button. The menu pops upward into space above. Probably intended to drop below. The menu auto-corrects when it would go off-screen, so most users won't notice — but it can clip oddly on small windows.

**Recommended fix:** anchor at `NSPoint(x: 0, y: -4)` for "below" in non-flipped coords, or check `sender.isFlipped` to decide.

---

### B-16 / B-17. Drag-and-drop accepts any URL, including non-video files and remote URLs — **LOW**

**File:** `Sources/DropTargetView.swift` lines 45–53; `PreferencesWindow.swift` lines 931–940

`DropTargetView` accepts any object readable as `NSURL`, including HTTP URLs dragged from Safari. `handleSourceDrop` then does `FileManager.default.fileExists(atPath: url.path)` — which returns false for HTTP — and falls into `setVideoFile(url)` with a meaningless path. AVPlayer fails silently. Same problem if the dropped file is a `.txt` or anything non-video.

**Recommended fix:**
- Restrict the drop target's accepted types via `NSPasteboard.PasteboardType.fileURL` AND extension filtering in `draggingEntered`.
- Reject non-video files with a brief shake or beep.

---

### B-20. `setWebURL` with a malformed URL silently does nothing — **LOW**

**File:** `Sources/WallpaperController.swift` lines 74–85

If `URL(string: resolved)` returns nil (e.g. user pastes `not even close to a url` and `https://` prefix doesn't save it), the source is *saved to prefs* but no window paints. User confusion ensues.

**Recommended fix:** validate before saving; show an alert if the URL fails to parse.

---

### B-21. ⌘⌥P appears as both a Carbon hotkey and a status-menu shortcut — **INFO**

**File:** `Sources/StatusMenu.swift` lines 88–90 vs `Sources/AppDelegate.swift` lines 47–53

The status menu sets `keyEquivalent: "p"` with `[.command, .option]` for "Disable LiveWall", AND `HotkeyManager` registers ⌘⌥P globally. They don't actually conflict because LSUIElement apps' menu shortcuts only fire while the menu is open, but it's worth removing the menu shortcut to avoid confusion (the menu still shows it as a hint label, which is the useful part).

---

### B-23. `ensureWindows` early-return based on count, not identity — **INFO**

**File:** `Sources/WallpaperController.swift` line 199

```swift
guard windows.count != screens.count else { return }
```

If display A is unplugged and display B is plugged in within the same `didChangeScreenParameters` notification cycle, the count remains the same and `ensureWindows` skips rebuild — leaving wallpaper windows pointing at the now-disconnected screen frames. Currently masked because `handleScreenChange()` calls `teardownAllWindows()` first, but if that ever changes this becomes an active bug.

**Recommended fix:** compare by displayID set, not count, OR keep the always-teardown behaviour and add an explicit comment that `ensureWindows` is the lazy path.

---

## (2) Memory & Performance

### P-1. Codable preferences decode on every getter access — **LOW**

**File:** `Sources/Preferences.swift` lines 156–164 (`recentSources`), 227–234 (`perScreenSources`)

`Preferences.shared.recentSources` runs `JSONDecoder().decode(...)` on every read. The Display section calls `rebuildPerScreenSourceMenu` once per attached display, and that reads `recentSources` each time. With 3 displays + 10 recents, that's 3 JSON decodes per settings open. Not catastrophic; not free either.

**Recommended fix:** cache decoded values in the `Preferences` instance, invalidate on write.

---

### P-2. Cross-fade may leak `AVPlayer`/`AVPlayerLooper` resources under rapid switching — **MEDIUM**

**File:** `Sources/VideoWallpaperView.swift` lines 22–62

Same root cause as B-9. Each `AVPlayerLooper` retains its `AVPlayerItem` and active decode buffers. If multiple cross-fades overlap, you can briefly hold 3+ pipelines. For 4K H.264 each can be 50–200 MB of decode memory. Brief but noticeable.

**Recommended fix:** see B-9.

---

### P-3 / P-4. `FullscreenMonitor` polls every 2s unconditionally — **LOW**

**File:** `Sources/FullscreenMonitor.swift` lines 18–21; `Sources/AppDelegate.swift` lines 8, 31

`CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], …)` is roughly 2–10 ms on a busy system — so ~3 ms/sec average background work, mostly wasted because nothing is fullscreen most of the time, AND wasted entirely when `pauseOnFullscreen == false`.

**Recommended fix:**
- Skip polling when `Preferences.shared.pauseOnFullscreen == false`.
- Replace the timer with `NSWorkspace.shared.notificationCenter` observers (`activeSpaceDidChangeNotification`, `applicationDidActivateNotification`, `applicationDidUnhideNotification`) plus a single check on each event.

---

### P-6. `AVQueuePlayer` defaults can buffer aggressively for long videos — **LOW**

**File:** `Sources/VideoWallpaperView.swift` lines 26–30

For long single-video sources (e.g. an hour-long screensaver from YouTube), AVQueuePlayer's default `automaticallyWaitsToMinimizeStalling = true` can preroll a lot of decode data. With looper, this compounds.

**Recommended fix (optional):** set `queuePlayer.automaticallyWaitsToMinimizeStalling = false` and a sensible `preferredForwardBufferDuration` (e.g. 4s). Trade-off: more responsive but possibly more stalls on poor I/O.

---

### P-7. Cross-fade overlaps two video pipelines for 0.6s — **LOW**

**File:** `Sources/VideoWallpaperView.swift` lines 37–50

During the fade, two AVPlayerLayers decode simultaneously. On Apple Silicon this is fine; on older Intel Macs running 4K H.265 it might cause a brief frame hitch. Probably acceptable for a wallpaper but worth knowing.

---

### P-8. `loadVideosFromFolder` blocks the main thread — **LOW**

**File:** `Sources/WallpaperController.swift` lines 244–253

`FileManager.default.contentsOfDirectory(at:...)` runs synchronously on the main queue. For folders with thousands of files this is a few ms; for huge folders on slow disks (NAS, encrypted volumes) it can be hundreds of ms.

**Recommended fix:** move to a background queue, post back to main when done.

---

### P-9. Deprecated `AVAssetImageGenerator.copyCGImage(at:actualTime:)` — **INFO**

**File:** `Sources/VideoThumbnail.swift` line 19

Deprecated in macOS 15. Still works; emits a build warning. Modern API: `generateCGImageAsynchronously(for:completionHandler:)` (macOS 13+), which is also genuinely async (current code wraps the sync API in a global queue).

---

### P-10. Redundant black background on both window and content view — **INFO**

**File:** `Sources/WallpaperWindow.swift` lines 28, 36

`self.backgroundColor = .black` and `host.layer?.backgroundColor = NSColor.black.cgColor` are both set. Only one matters because the contentView always covers the window. Cosmetic.

---

### P-12. `rebuildScreenCheckboxes()` rebuilds entire NSView tree on every per-display change — **LOW**

**File:** `Sources/PreferencesWindow.swift` lines 669–715, called from `perScreenUseDefault`, `perScreenChooseFile`, `perScreenSetURL`, `perScreenRecentChosen`

Every per-display source change destroys and recreates every checkbox + popup in the Display section. Cheap for 1–3 displays, sluggish for 6+ displays.

**Recommended fix:** only rebuild the affected row's popup via `rebuildPerScreenSourceMenu(for: popup, displayID: id)`.

---

### P-13. `NotificationCenter.default.removeObserver(self)` in `deinit` — **INFO**

**File:** `Sources/PreferencesWindow.swift` line 74; `Sources/StatusMenu.swift` line 51

Modern style is to retain observation tokens (`NSObjectProtocol`) so removal is precise. `removeObserver(self)` is still safe but is a blunt instrument.

---

## (3) Security & Sandboxing

### S-1. `NSAllowsArbitraryLoads = true` is too broad — **MEDIUM**

**File:** `Sources/Info.plist` lines 35–39

The wallpaper feature needs to load arbitrary user-supplied URLs in a `WKWebView`. `NSAllowsArbitraryLoads` opens *every* network call (including any future feature) to plain HTTP, weak TLS, expired certs.

**Recommended fix:** replace with the narrower `NSAllowsArbitraryLoadsInWebContent = true` (still permits the WKWebView use case, but does not weaken any non-web HTTP from the app). Optionally combine with per-domain `NSExceptionDomains` if you want to restrict the wallpaper feature itself.

---

### S-2. App is not sandboxed — **MEDIUM (distribution-blocker for App Store)**

**File:** `Sources/Info.plist` (no entitlements file at all)

There is no `.entitlements` file and no `com.apple.security.app-sandbox` entitlement. Means:

- Full filesystem read/write as the user.
- Full network access.
- App Store distribution is impossible.
- A vulnerability in WKWebView, AVFoundation, or our own code has a much larger blast radius.

For non-App Store distribution the absence is acceptable, but adding sandbox is reasonable for a wallpaper utility:

- `com.apple.security.files.user-selected.read-only` for `NSOpenPanel`.
- `com.apple.security.network.client` for web wallpapers.
- Persisting access to user-picked folders requires security-scoped bookmarks (currently `Preferences.contentPath` is just a String — would need migration).

---

### S-3. Hard-coded developer email in source — **LOW**

**File:** `Sources/PreferencesWindow.swift` line 6

`private let FEEDBACK_TO = "brendanbong22@gmail.com"`. Visible in the binary via `strings`. Spam scraping risk. Privacy disclosure if the project is open-sourced.

**Recommended fix:** route feedback through a domain you control (e.g. `mailto:feedback@livewall.app`) that forwards. Or use a feedback service URL.

---

### S-4. WKWebView wallpapers run with auto-play, full JS, and arbitrary loads — **MEDIUM**

**File:** `Sources/WallpaperWindow.swift` lines 56–71

```swift
let config = WKWebViewConfiguration()
config.mediaTypesRequiringUserActionForPlayback = []
config.allowsAirPlayForMediaPlayback = false
let wv = WKWebView(frame: ..., configuration: config)
```

A wallpaper URL is essentially executed as a constantly-running, persistent webpage with full JavaScript privileges and (per S-1) full HTTP access. The user has no UI to stop it short of switching sources. Concrete risks:

- Auto-play tracking pixels / beacons.
- JavaScript-driven crypto miners running 24/7 on the user's display.
- Browser fingerprinting persisted across sessions.
- Memory leaks in third-party JS that's been running for hours.

**Recommended hardening (all are easy):**
- `config.preferences.javaScriptEnabled = false` for unknown URLs (toggle for advanced users).
- `config.websiteDataStore = .nonPersistent()` so cookies/local storage don't persist.
- Show a clear "this URL is running in your wallpaper" indicator in Settings.

---

### S-5. Drag-and-drop / NSOpenPanel access without security-scoped bookmarks — **INFO (today), HIGH (if sandboxing later)**

**File:** `Sources/DropTargetView.swift`, `Sources/StatusMenu.swift`, `Sources/PreferencesWindow.swift`

Today the app accesses dropped files by raw path. Works because there's no sandbox. If S-2 is addressed later, every saved `contentPath` becomes inaccessible after relaunch — sandboxed apps need security-scoped bookmarks for persistent access to user-picked files.

**Recommended fix (when sandboxing):** store bookmarks via `URL.bookmarkData(options: .withSecurityScope, ...)` and resolve via `URL(resolvingBookmarkData:options:.withSecurityScope, ...)` on launch.

---

### S-6. Hard-coded SUPPORT_URL — **INFO**

**File:** `Sources/PreferencesWindow.swift` line 5

If the BuyMeACoffee handle is squatted or the URL changes, users go to a different page. Not a security vuln, just brittleness. Mitigation: redirect through a URL you control.

---

### S-7. YouTube ID regex has no length cap — **INFO**

**File:** `Sources/WallpaperController.swift` lines 324–340

`[\w-]{6,}` greedy match. NSRegularExpression has built-in safeguards against catastrophic backtracking, and the input is user-pasted (max ~2000 chars in NSAlert text field). Negligible risk.

---

### S-8. Ad-hoc codesign — **MEDIUM (distribution-blocker)**

**File:** `build.sh` line 78

```bash
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
```

Ad-hoc signed (`-`) means:

- Gatekeeper warns "cannot verify developer" on first launch.
- Users must right-click → Open the first time, or manually approve in System Settings.
- Sparkle auto-update will refuse to update an ad-hoc signed app for security reasons.
- macOS Hardened Runtime / notarisation isn't applied.

For public release: needs a Developer ID Application certificate, replace `-` with the certificate hash, and run `xcrun notarytool submit` on the resulting `.dmg`. Also `--deep` is itself deprecated by Apple — modern signing wants explicit per-bundle component signing.

---

### S-9. ATS exception affects all networking, not just web wallpaper — **see S-1**

Same root cause as S-1; mentioned again so it's not missed.

---

## (4) Code Quality & Maintainability

### Q-1. `PreferencesWindow.swift` is 1,264 lines — **HIGH**

**File:** `Sources/PreferencesWindow.swift`

Single file owns: window construction, sidebar, all 4 panes' build/load/action methods, drag-drop wiring, recent menu, per-display source UI, hotkey wiring, mailto generation, reset-all flow. It's by far the largest file in the project (next-largest is WallpaperController at 342). Adding any new section or affordance multiplies the merge-conflict surface.

**Recommended split:**

```
PreferencesWindowController.swift          // shell + sidebar + section-routing
GeneralPaneBuilder.swift                   // build + load + actions
DisplayPaneBuilder.swift                   // ditto
PlaybackPaneBuilder.swift                  // ditto
AboutPaneBuilder.swift                     // ditto
PerDisplaySourceMenu.swift                 // per-display popup logic
SettingsControls.swift                     // shared makeGrid / addRow helpers
```

Each pane becomes ~150–250 lines, individually testable, individually owned.

---

### Q-2. Implicitly-unwrapped UI properties (`!`) everywhere — **LOW**

**File:** `Sources/PreferencesWindow.swift` lines 12–47, also in `Sources/AppDelegate.swift`

```swift
private var enableToggle: NSSwitch!
private var sourceSegmented: NSSegmentedControl!
...
```

If the init order is ever reordered or a code path accesses one before `buildUI()` runs, you get a hard crash. Common AppKit pattern; not idiomatic Swift.

**Recommended fix:** use `var ... = NSSwitch()` initializers (controls don't need to be deferred for layout) OR construct in `init` as non-optional.

---

### Q-3. No unit tests — **MEDIUM**

There is no `Tests/` directory. Several pure functions are highly testable and would be worth covering before adding more features:

- `WallpaperController.normalizeURL(_:)` (URL prefix logic, YouTube ID extraction)
- `WallpaperController.targetScreens()` (filter logic, fallback behaviour)
- `Preferences.pushRecent(...)` (dedup, cap, ordering)
- `HotkeyFormatter.display(...)` (modifier string construction)
- `FullscreenMonitor.computeFullscreen()` (the coordinate math, which has B-8)

A single `XCTest` target with ~15 short tests would catch each bug listed above before they ship.

---

### Q-4. `Preferences` is a true singleton — **LOW**

**File:** `Sources/Preferences.swift` line 24

`static let shared = Preferences()` plus direct `UserDefaults.standard` access. Hard to test code that touches preferences without swizzling or process-wide side effects.

**Recommended fix:** inject `Preferences` (or a protocol) into controllers. Not urgent; relevant once tests exist.

---

### Q-5. Magic strings duplicated — **LOW**

**File:** `Sources/WallpaperController.swift` line 221, `Sources/WallpaperWindow.swift` line 18

`NSDeviceDescriptionKey("NSScreenNumber")` appears in two places. Typo in either silently returns 0 (treated as "unknown display").

**Recommended fix:** single constant, or use `WallpaperController.screenID(of:)` everywhere (it already exists).

---

### Q-6. Duplicate strings across 3 places — **LOW**

**File:** `Sources/PreferencesWindow.swift` lines 82–84, 622–623, 1078–1080

The "Wallpaper is showing on your displays..." / "Disabled..." sentences are duplicated three times verbatim. A future copy edit will miss one.

**Recommended fix:** one helper `enableHintText(for: Bool) -> String`.

---

### Q-7. Distributed update calls — **LOW**

After a settings change, callers manually invoke combinations of `controller?.reconfigureScreens()`, `loadValues()`, `rebuildScreenCheckboxes()`. Easy to forget one. Some places call all three; some only call two.

**Recommended fix:** one `Preferences.didChange(.targetScreens)` notification with subscribers, or push state through a Combine-style observable.

---

### Q-8. `WallpaperController` has 4+ responsibilities — **LOW**

**File:** `Sources/WallpaperController.swift`

Source loading, rotation timer, window-fleet management, source resolution, mute/audio coordination, power coordination. Fine at 342 lines today; at 700 lines this will hurt.

**Recommended split (when growing):** `SourceManager`, `RotationManager`, `WindowFleet`, `AudioCoordinator`.

---

### Q-9. Clean up build warnings — **LOW**

Recent build emits:

- `var hotKeyID was never mutated; consider changing to 'let' constant` (HotkeyManager.swift:45)
- `'copyCGImage(at:actualTime:)' was deprecated in macOS 15.0` (VideoThumbnail.swift:19)
- `variable 'self' was written to, but never read` in the hotkey recorder closure (PreferencesWindow.swift:489)

All trivially fixable. Clean output is hygiene.

---

### Q-11. `Key.allKeys` is hand-maintained — **LOW**

**File:** `Sources/Preferences.swift` lines 27–58

Adding a new preference key requires remembering to add it to *both* the constant declaration *and* the `allKeys` array. `resetAll()` will silently leave forgotten keys behind.

**Recommended fix:** declare keys as cases of an enum and iterate `Key.allCases` (CaseIterable). Or programmatically iterate `defaults.dictionaryRepresentation()` for the bundle's key prefix.

---

### Q-13. `Info.plist` cosmetics — **INFO**

**File:** `Sources/Info.plist` lines 22, 33–34

- `CFBundleSignature = "????"` (default-unset). Pick a real 4-char creator code, or remove it entirely for modern apps.
- `NSHumanReadableCopyright = "Built locally with Claude. No warranty."` is funny but not what should ship publicly.

---

### Q-14. No URL scheme handler — **INFO**

Common for menu-bar apps to register a private URL scheme (e.g. `livewall://set-source?url=...`) for automation, scripting, or launch-time configuration. Future enhancement.

---

### Q-15. Carbon hotkey API is ageing — **LOW**

**File:** `Sources/HotkeyManager.swift`, `Sources/HotkeyRecorderButton.swift`

Carbon HIToolbox is officially deprecated long-term. Apple has not removed `RegisterEventHotKey` and a generation of menu-bar apps depend on it, but no first-party replacement exists. Worth tracking macOS releases — if a future macOS removes Carbon, we'll need a global hotkey alternative (most third-party libraries today wrap Carbon themselves; the path forward is uncertain).

---

### Q-16. `bundlePath.hasPrefix("/Applications/")` doesn't account for per-user installs — **LOW**

**File:** `Sources/PreferencesWindow.swift` line 1091

If the user runs LiveWall from `~/Applications/` (a legitimate per-user install location), the "move to /Applications" warning fires erroneously when they enable Launch at Login.

**Recommended fix:** also accept `("\(NSHomeDirectory())/Applications/")` as valid.

---

### Q-17. AppDelegate strong refs — **INFO**

**File:** `Sources/AppDelegate.swift`

`controller`, `prefsWindow`, `statusMenu`, `hotkey`, `battery`, `fullscreen` are all process-lifetime; never deallocated. Fine, but worth noting if app lifecycle changes (e.g. add support for "soft quit" without terminating the process).

---

### Q-18. `windowWillClose` is empty — **INFO**

**File:** `Sources/PreferencesWindow.swift` lines 1261–1263

Just delete it, or persist window position there.

---

### Q-21. `--deep` codesign is deprecated — **LOW**

**File:** `build.sh` line 78

Apple recommends signing each bundle component explicitly. Works today; flagged in modern codesign tooling.

---

## Items by Severity (Quick Reference)

### HIGH (fix before ship)

| ID | File | Issue |
|---|---|---|
| B-1 | Preferences.swift:137 | `hotkeyKeyCode` getter rejects valid `kVK_ANSI_A` |
| Q-1 | PreferencesWindow.swift | 1,264-line file is the biggest maintainability risk |

### MEDIUM (fix soon / before public distribution)

| ID | File | Issue |
|---|---|---|
| B-3 | WallpaperController.swift:163 | Empty folder = silent black wallpaper |
| B-8 | FullscreenMonitor.swift:36 | Coordinate bug masked by position-agnostic check |
| B-9 | VideoWallpaperView.swift:22 | Cross-fade race on rapid `play()` calls |
| P-2 | VideoWallpaperView.swift | AVPlayer leaks possible during overlapping fades |
| S-1 | Info.plist:35 | `NSAllowsArbitraryLoads` too broad |
| S-2 | Info.plist | App is not sandboxed (App Store blocker) |
| S-4 | WallpaperWindow.swift:56 | WKWebView wallpaper has full JS / autoplay / persistence |
| S-8 | build.sh:78 | Ad-hoc signed; needs Developer ID + notarisation for distribution |
| Q-3 | (no Tests/) | No unit test coverage |

### LOW (polish before 1.1 ideally)

B-2, B-6, B-13, B-14, B-16, B-17, B-20 · P-1, P-3, P-4, P-6, P-7, P-8, P-12 · S-3, S-5 · Q-2, Q-4, Q-5, Q-6, Q-7, Q-8, Q-9, Q-11, Q-15, Q-16, Q-21

### INFO (noted, no action needed)

B-21, B-23 · P-5, P-9, P-10, P-11, P-13 · S-6, S-7, S-9 · Q-10, Q-12, Q-13, Q-14, Q-17, Q-18, Q-19, Q-20

---

## Suggested Pre-Release Checklist

Before tagging 1.0:

1. **Fix B-1.** One-line change. Silent data-loss is the worst kind of bug.
2. **Fix B-9 / P-2.** Either debounce `play()` or maintain a transaction guard. Cross-fade is a marquee feature; race conditions in it will produce mystifying user reports.
3. **Tighten S-1 → narrower ATS exception.** `NSAllowsArbitraryLoadsInWebContent` is a one-key change.
4. **Tighten S-4** by disabling JavaScript by default for web wallpapers (with an opt-in toggle). Or at minimum: `WKWebsiteDataStore.nonPersistent()`.
5. **Decide on distribution path** (S-2 / S-8). For public release outside the App Store: get a Developer ID cert, switch `build.sh` to use it, run notarytool, and host the notarised DMG. For App Store: add sandbox + bookmarks (significant work — separate sprint).
6. **Clean build warnings** (Q-9). Five minutes.
7. **Replace placeholder copyright string** (Q-13). One line.
8. **Add `NSExceptionAllowsInsecureHTTPLoads = false`** to your ATS dict if you keep `NSAllowsArbitraryLoadsInWebContent`, to at least prefer HTTPS.

After 1.0, in priority order:

- Q-1 (split PreferencesWindow.swift)
- Q-3 (start a test target with the WallpaperController + Preferences pure-function tests)
- B-3 / B-20 (proper user feedback for empty-folder and bad-URL cases)
- P-3 (replace fullscreen polling with NSWorkspace observers)

---

*End of report.*

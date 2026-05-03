# LiveWall

A tiny native macOS menu-bar app that turns your desktop into a video wallpaper. Plays a local video, a folder of videos (auto-rotating with cross-fade), or any web URL — including YouTube, which auto-converts to a muted, looping, chrome-free embed.

Built for OLED displays. Keeps pixels moving so they don't burn in.

## Install

Easiest: download the latest `LiveWall.dmg` from the [Releases page](../../releases), open it, drag LiveWall.app to Applications, and double-click. The app is signed with a Developer ID and notarised by Apple, so it opens cleanly without Gatekeeper warnings.

Or build from source — see below.

## Use

LiveWall lives in the menu bar (look for the layered-rectangles + play icon, top right). Click it for the dropdown, or open Settings for the full configuration.

- **Source** — pick a single video file, a folder of videos, or a web URL. YouTube links are auto-converted.
- **Rotation** (folder mode) — rotate every N minutes, with optional shuffle and cross-fade between clips.
- **Multi-display** — paint on every connected display, or pick which ones. Each display can have its own source override.
- **Power saving** — pause when on battery, pause when any app is fullscreen.
- **Global hotkey** — toggle the wallpaper on/off from anywhere (default ⌘⌥P, configurable).

Settings persist across launches. Enable Launch at Login from the General pane if you want LiveWall up on boot.

## Build from source

You need Xcode Command Line Tools:

```
xcode-select --install
```

Then from this folder:

```
./build.sh         # compiles Sources/*.swift into LiveWall.app
./make_dmg.sh      # builds and packages into LiveWall.dmg (drag-to-install layout)
./notarize.sh      # builds, signs, packages, notarises, and staples the DMG
                   # (requires a Developer ID cert + notarytool credentials)
```

`build.sh` falls back to ad-hoc signing if you don't have a Developer ID cert installed, so the build still works for local testing.

## OLED tips

- Use a folder of full-motion videos rather than one looping clip. Static-looking videos (slow drone shots) are nearly as bad as a still image for OLED.
- Set rotation to 30 min or 1 hour. Combined with motion within each clip, that gives you full-frame pixel coverage over time.
- Run your monitor's pixel-refresh cycle weekly. LG/ASUS/Samsung OLEDs all have one. LiveWall complements that, doesn't replace it.
- Pause-on-fullscreen is on by default, which is useful — but don't leave the wallpaper paused for long stretches when you're at the desk.

## How it works (briefly)

LiveWall creates a borderless `NSWindow` per target display at the macOS desktop window level (above the OS wallpaper, below your desktop icons) and renders an `AVPlayerLayer` (for video) or `WKWebView` (for web URLs) into each one. Audio only plays on the primary display so you don't get N copies overlapping. Windows ignore mouse events, so clicks pass through to the desktop. No private APIs, no kexts, no admin password, no third-party dependencies.

## Files

```
LiveWall/
├── Sources/
│   ├── main.swift                   entry point
│   ├── AppDelegate.swift            app lifecycle + screen-change handling
│   ├── WallpaperController.swift    sources, rotation, multi-display coord
│   ├── WallpaperWindow.swift        the desktop-level NSWindow
│   ├── VideoWallpaperView.swift     AVQueuePlayer + cross-fade
│   ├── Preferences.swift            UserDefaults wrapper
│   ├── StatusMenu.swift             menu bar dropdown
│   ├── PreferencesWindow.swift      the settings UI (4 panes)
│   ├── SidebarItemButton.swift      sidebar nav item
│   ├── HotkeyManager.swift          Carbon RegisterEventHotKey wrapper
│   ├── HotkeyRecorderButton.swift   hotkey capture UI
│   ├── DropTargetView.swift         drag-and-drop file targets
│   ├── BatteryMonitor.swift         IOKit power-source observer
│   ├── FullscreenMonitor.swift      detects fullscreen apps to pause playback
│   ├── VideoThumbnail.swift         first-frame extraction for previews
│   └── Info.plist                   bundle metadata (LSUIElement only)
├── Resources/                       app icon assets
├── build.sh                         compile to LiveWall.app
├── make_dmg.sh                      package into LiveWall.dmg
└── notarize.sh                      build → sign → notarise → staple
```

## Privacy

No tracking. No telemetry. No analytics. No external network calls except the WebKit web wallpaper feature (which only loads URLs you give it). Your file picks and preferences live in `~/Library/Preferences/com.brendan.livewall.plist`.

## Caveats

- macOS 13 (Ventura) or later.
- Desktop icons sit on top of the wallpaper, like normal. If you want them hidden: `defaults write com.apple.finder CreateDesktop -bool false && killall Finder` (reverse with `true`).
- YouTube embeds depend on YouTube allowing the embed for that video. Some videos disable embedding and will show an error in the web view.

## License

MIT. Tweak away.

---

Built by [Brendan](https://ko-fi.com/livewall). If LiveWall is useful to you, please consider [supporting the project ❤️](https://ko-fi.com/livewall).

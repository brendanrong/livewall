import Cocoa

/// Detects whether any application has a fullscreen window on any display.
/// Posts `stateChangedNotification` when the answer changes.
///
/// Strategy: poll on a low-frequency timer (every 2s) using
/// `CGWindowListCopyWindowInfo`. Looking at every visible window and checking
/// whether its bounds match a screen frame is cheap, doesn't require any
/// permissions, and works regardless of how the app entered fullscreen.
final class FullscreenMonitor {
    static let stateChangedNotification = Notification.Name("LiveWall.fullscreenStateChanged")

    private(set) var isAnyAppFullscreen: Bool = false
    private var timer: Timer?

    init() {
        refreshState()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }

    deinit { timer?.invalidate() }

    private func refreshState() {
        let was = isAnyAppFullscreen
        isAnyAppFullscreen = computeFullscreen()
        if was != isAnyAppFullscreen {
            NotificationCenter.default.post(
                name: Self.stateChangedNotification, object: nil
            )
        }
    }

    private func computeFullscreen() -> Bool {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        // Convert each NSScreen frame to CG global coords (origin top-left,
        // primary screen at 0,0). This is the same coordinate space that
        // CGWindowListCopyWindowInfo returns window bounds in, so we can
        // compare position and size directly. The previous implementation
        // used the primary screen's height for every screen's y-conversion,
        // which produced wrong rects on secondary displays — and only
        // compared dimensions, so any same-size window registered as
        // fullscreen regardless of where it was.
        let screens = NSScreen.screens
        guard let primary = screens.first else { return false }
        let primaryHeight = primary.frame.height
        let cgScreenFrames: [CGRect] = screens.map { sc in
            CGRect(
                x: sc.frame.minX,
                y: primaryHeight - sc.frame.maxY,
                width: sc.frame.width,
                height: sc.frame.height
            )
        }

        let slop: CGFloat = 2
        for w in list {
            // Ignore our own wallpaper windows.
            if let pid = w[kCGWindowOwnerPID as String] as? Int, pid == Int(myPID) { continue }
            // Skip non-normal layers (menubar, dock, sheets, etc.)
            if let layer = w[kCGWindowLayer as String] as? Int, layer != 0 { continue }
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"],
                  let width = b["Width"], let height = b["Height"]
            else { continue }
            let winRect = CGRect(x: x, y: y, width: width, height: height)
            for sf in cgScreenFrames {
                if abs(winRect.minX   - sf.minX)   < slop &&
                   abs(winRect.minY   - sf.minY)   < slop &&
                   abs(winRect.width  - sf.width)  < slop &&
                   abs(winRect.height - sf.height) < slop {
                    return true
                }
            }
        }
        return false
    }
}

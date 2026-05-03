import Cocoa
import WebKit

final class WallpaperWindow: NSWindow {
    private var videoView: VideoWallpaperView?
    private var webView: WKWebView?
    private(set) var displayID: UInt32 = 0

    convenience init(targetScreen screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // Move to the requested screen (NSWindow's designated init doesn't take one).
        self.setFrame(screen.frame, display: false)
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            self.displayID = n.uint32Value
        }

        // Sit at desktop wallpaper level: above the OS wallpaper but below desktop icons.
        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.ignoresMouseEvents = true
        self.backgroundColor = .black
        self.isOpaque = true
        self.hasShadow = false
        self.canHide = false
        self.isReleasedWhenClosed = false

        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.black.cgColor
        host.autoresizingMask = [.width, .height]
        self.contentView = host
    }

    func showVideo(url: URL, muted: Bool, fade: Bool = false) {
        teardownWeb()
        if videoView == nil, let host = contentView {
            let v = VideoWallpaperView(frame: host.bounds)
            v.autoresizingMask = [.width, .height]
            host.addSubview(v)
            videoView = v
        }
        videoView?.play(url: url, muted: muted, fade: fade)
    }

    func setPlaybackPaused(_ paused: Bool) {
        videoView?.setPaused(paused)
    }

    func showWeb(url: URL) {
        teardownVideo()
        if webView == nil, let host = contentView {
            let config = WKWebViewConfiguration()
            config.mediaTypesRequiringUserActionForPlayback = []
            config.allowsAirPlayForMediaPlayback = false
            // A web wallpaper is a page that runs 24/7 on the user's display.
            // Use a non-persistent data store so cookies, localStorage, IndexedDB
            // etc. don't accumulate across launches and aren't shared with any
            // future webview the app might add. JavaScript stays enabled —
            // YouTube embeds need it for autoplay/loop, and that's the marquee
            // use case for this feature.
            config.websiteDataStore = .nonPersistent()
            let wv = WKWebView(frame: host.bounds, configuration: config)
            wv.autoresizingMask = [.width, .height]
            // Transparent background trick (KVC)
            wv.setValue(false, forKey: "drawsBackground")
            wv.layer?.backgroundColor = NSColor.black.cgColor
            host.addSubview(wv)
            webView = wv
        }
        webView?.load(URLRequest(url: url))
    }

    func setMuted(_ muted: Bool) {
        videoView?.setMuted(muted)
    }

    func togglePaused() {
        videoView?.togglePaused()
    }

    func setOpacity(_ value: Double) {
        self.alphaValue = CGFloat(max(0.0, min(1.0, value)))
    }

    func setAllSpaces(_ on: Bool) {
        var b: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        if on {
            b.insert(.canJoinAllSpaces)
        } else {
            b.insert(.moveToActiveSpace)
        }
        self.collectionBehavior = b
    }

    private func teardownVideo() {
        videoView?.stop()
        videoView?.removeFromSuperview()
        videoView = nil
    }

    private func teardownWeb() {
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    // Allow the borderless window to become key when needed (it usually shouldn't).
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

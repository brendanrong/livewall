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

        // YouTube refuses to play /embed/ URLs loaded as a top-level page
        // (Error 153: "Video player configuration error" — its origin check
        // fails). Wrapping the embed in an <iframe> on a tiny HTML host page
        // with a stable baseURL gives YouTube a legitimate embedding origin
        // and the player works.
        if isYouTubeEmbed(url) {
            let html = youTubeWrapperHTML(embedURL: url)
            webView?.loadHTMLString(html, baseURL: URL(string: "https://livewall.local/"))
        } else {
            webView?.load(URLRequest(url: url))
        }
    }

    private func isYouTubeEmbed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return (host == "www.youtube.com" || host == "youtube.com")
            && url.path.hasPrefix("/embed/")
    }

    private func youTubeWrapperHTML(embedURL: URL) -> String {
        let safeURL = embedURL.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            html, body { margin: 0; padding: 0; height: 100%; background: #000; overflow: hidden; }
            iframe { position: absolute; top: 0; left: 0; width: 100%; height: 100%; border: 0; }
        </style>
        </head>
        <body>
        <iframe src="\(safeURL)"
                allow="autoplay; encrypted-media; picture-in-picture"
                allowfullscreen></iframe>
        </body>
        </html>
        """
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

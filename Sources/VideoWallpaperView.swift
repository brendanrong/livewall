import Cocoa
import AVFoundation

final class VideoWallpaperView: NSView {
    private var player: AVQueuePlayer?
    private var playerLayer: AVPlayerLayer?
    private var looper: AVPlayerLooper?

    /// References to a fade-out that hasn't finished yet. Held so a
    /// follow-up `play()` arriving mid-fade can tear them down instead
    /// of stacking pipelines and stomping the completion handler.
    private var fadingOutLayer: AVPlayerLayer?
    private var fadingOutPlayer: AVQueuePlayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    /// Start playing `url`. If `fade` is true, the existing layer fades out
    /// while the new one fades in (~0.6s), giving a cross-fade between
    /// rotated videos.
    func play(url: URL, muted: Bool, fade: Bool = false) {
        // If a previous cross-fade hasn't completed, snap it to its end state now.
        // Without this, rapid play() calls stack pipelines, stomp each other's
        // completion handlers, and can leak AVPlayer/AVPlayerLooper instances.
        finishPendingFade()

        let oldLayer = playerLayer
        let oldPlayer = player

        let item = AVPlayerItem(url: url)
        let queuePlayer = AVQueuePlayer()
        let newLooper = AVPlayerLooper(player: queuePlayer, templateItem: item)
        queuePlayer.isMuted = muted
        queuePlayer.actionAtItemEnd = .advance

        let pl = AVPlayerLayer(player: queuePlayer)
        pl.frame = bounds
        pl.videoGravity = .resizeAspectFill
        pl.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        if fade, let oldLayer = oldLayer {
            // Cancel any pending animation on the old layer so the fade-out
            // starts from its current presented opacity.
            oldLayer.removeAllAnimations()
            pl.opacity = 0
            layer?.addSublayer(pl)
            queuePlayer.play()
            self.fadingOutLayer = oldLayer
            self.fadingOutPlayer = oldPlayer
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            pl.opacity = 1
            oldLayer.opacity = 0
            CATransaction.setCompletionBlock { [weak self] in
                guard let self = self else { return }
                // Only tear down if we're still the active fade. A subsequent
                // play() may have already finalized us via finishPendingFade().
                if self.fadingOutLayer === oldLayer {
                    oldPlayer?.pause()
                    oldLayer.removeFromSuperlayer()
                    self.fadingOutLayer = nil
                    self.fadingOutPlayer = nil
                }
            }
            CATransaction.commit()
        } else {
            // Hard cut.
            oldPlayer?.pause()
            oldLayer?.removeFromSuperlayer()
            layer?.addSublayer(pl)
            queuePlayer.play()
        }

        self.player = queuePlayer
        self.playerLayer = pl
        self.looper = newLooper
    }

    private func finishPendingFade() {
        guard let l = fadingOutLayer else { return }
        l.removeAllAnimations()
        l.removeFromSuperlayer()
        fadingOutPlayer?.pause()
        fadingOutLayer = nil
        fadingOutPlayer = nil
    }

    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
    }

    func setPaused(_ paused: Bool) {
        guard let p = player else { return }
        if paused { p.pause() } else { p.play() }
    }

    func togglePaused() {
        guard let p = player else { return }
        if p.rate == 0 { p.play() } else { p.pause() }
    }

    func stop() {
        finishPendingFade()
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        looper = nil
    }
}

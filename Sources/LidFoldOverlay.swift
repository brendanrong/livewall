import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
@preconcurrency import ScreenCaptureKit

/// Folds a frozen picture of the built-in display as the lid closes.
///
/// One fold: the lid starts moving toward the start angle, so the capture stream is warmed. Turn
/// crosses 0.0005: the newest stream frame is frozen into the renderer and the panel is shown once
/// that frame is drawable. The sensor drives `targetTurn`; the renderer eases toward it at the display
/// rate. Turn returns to 0 (lid opened, or the lid rested and the fold released): the frozen frame
/// fades out over 90 ms onto the live desktop and everything is torn down. The stream stops 1.5 s later.
final class LidFoldOverlay: NSObject, SCStreamOutput, SCStreamDelegate {
    // MARK: Settings (AppDelegate.rebuildHingeOverlay writes these)

    /// Blur strength, 0.2 to 1.0. Geometry never scales with it; it follows the lid.
    var intensity: Double = 0.5 { didSet { renderer.blurStrength = Float(min(max(intensity, 0.2), 1)) } }
    /// Lid angle where the fold starts, degrees.
    var clearAngle: Double = 110 { didSet { renderer.rangeDegrees = Float(clearAngle - Self.endAngle) } }
    /// Close to black over the last tenth of the turn.
    var fadeToBlack = true { didSet { renderer.finalClose = fadeToBlack ? 1 : 0 } }
    var onCaptureFailure: ((String) -> Void)?
    /// Main thread, when the fold becomes visible or goes away. AppDelegate pauses the video on it.
    var onFoldStateChanged: ((Bool) -> Void)?
    private(set) var isFolded = false {
        didSet { if isFolded != oldValue { onFoldStateChanged?(isFolded) } }
    }

    // MARK: Design constants (not settings)

    /// Turn reaches 1 here. The last tenth of the turn (13.7 to 3 degrees with a 110 start) closes to black.
    static let endAngle: Double = 3
    private static let showAbove: Double = 0.0005
    private static let hideBelow: Float = 0.0001
    private static let openFade: CFTimeInterval = 0.09
    private static let preArmMargin: Double = 25            // degrees above the start angle where a closing lid warms the stream
    private static let streamIdleTail: TimeInterval = 1.5
    private static let releaseAfter: CFTimeInterval = 1.0   // lid still for this long: the fold lets go
    private static let releaseDuration: CFTimeInterval = 0.45
    private static let motionBand: Double = 0.03            // turn units, about 3 degrees, above whole-degree jitter
    private static let noReleaseBelow: Double = 20          // degrees; a lid this far shut is closing, not resting
    private static let leadSeconds: Double = 0.07           // predict the lid this far ahead so the follow filter's lag cancels
    private static let leadDeadZone: Double = 12            // degrees per second; below this the lid is resting, no lead
    private static let leadMaxDegrees: Double = 6

    private let panel: NSPanel
    private let renderer: FoldRenderer
    private let displayID: CGDirectDisplayID

    // Fold state (main thread)
    private var visible = false
    private var pendingShow = false
    private var reEngaging = false
    private var fadeDeadline: CFTimeInterval?
    private var framesSinceShow = 0

    // Lid motion (main thread). The sensor is polled at 60 Hz but its report only refreshes about
    // 8 times a second, so at closing speed each fresh value is 15 to 30 degrees from the last.
    // Velocity comes from the last two fresh values; between them the estimate is dead-reckoned
    // (last value + velocity * elapsed) so the renderer gets a continuous target.
    private var lastChange: (angle: Double, time: CFTimeInterval)?
    private var velocity: Double = 0
    private static let reckonMaxSeconds: CFTimeInterval = 0.35  // never extrapolate further than this (sensor can go 300 ms between refreshes on reopen)
    private static let stoppedAfter: CFTimeInterval = 0.35      // no fresh value for this long: the lid is still

    // Auto-release (main thread)
    private var stillSince: CFTimeInterval = 0
    private var stillLow: Double = 0
    private var stillHigh: Double = 0
    private var releasing = false
    private var releaseStart: CFTimeInterval = 0
    private var releaseFrom: Double = 0
    private var releasedAt: Double = 0
    private var released = false
    private var releasedFloor: Double = 0
    private var handingBack = false
    private var handbackStart: CFTimeInterval = 0
    private var handbackFrom: Double = 0
    private static let handbackDuration: CFTimeInterval = 0.25

    // Capture stream. Lifecycle on main; frames arrive on sampleQueue; shared bits under `lock`.
    private let sampleQueue = DispatchQueue(label: "com.brendan.livewall.fold-frames", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var starting = false
    private var streamGeneration: UInt64 = 0
    private var idleStop: DispatchWorkItem?
    private var latest: CVPixelBuffer?
    private var acceptFramesAfter: CFTimeInterval = 0
    private var awaitingFrame = false

    // MARK: - Creation

    static func make() -> LidFoldOverlay? {
        guard let screen = builtInScreen(), let id = displayID(of: screen),
              let renderer = FoldRenderer(size: screen.frame.size) else { return nil }
        return LidFoldOverlay(screen: screen, displayID: id, renderer: renderer)
    }

    private init(screen: NSScreen, displayID: CGDirectDisplayID, renderer: FoldRenderer) {
        self.displayID = displayID
        self.renderer = renderer
        panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.alphaValue = 0
        panel.contentView = renderer
        // Give the panel a window number now: in and straight out at alpha 0 creates the server-side
        // window, so the capture filter can exclude it before it is ever visible.
        panel.orderFrontRegardless()
        panel.orderOut(nil)

        renderer.blurStrength = Float(intensity)
        renderer.rangeDegrees = Float(clearAngle - Self.endAngle)
        renderer.onFrame = { [weak self] now in self?.frameDrawn(at: now) }
        renderer.onFrameReady = { [weak self] in self?.present() }

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(self, selector: #selector(interrupted), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        hide()
        stopStream()
    }

    // MARK: - Sensor input

    /// Feed the raw sensor angle here on every tick (whole degrees). Smoothing happens in the renderer,
    /// once per displayed frame; feeding the monitor's smoothed angle would double the lag.
    func update(angle raw: Double) {
        let now = CACurrentMediaTime()
        if let last = lastChange {
            if raw != last.angle {
                let v = (raw - last.angle) / max(now - last.time, 0.01)
                velocity += (v - velocity) * 0.6
                lastChange = (raw, now)
            } else if now - last.time > Self.stoppedAfter {
                velocity = 0
            }
        } else {
            lastChange = (raw, now)
        }
        if abs(velocity) < 1 { velocity = 0 }

        // Dead reckoning between sensor refreshes.
        var estimate = raw
        if let last = lastChange, velocity != 0 {
            estimate = raw + velocity * min(now - last.time, Self.reckonMaxSeconds)
            estimate = min(max(estimate, Self.endAngle), 180)
        }

        let target = turn(for: raw)

        // Warm the stream while a closing lid approaches the start angle; let it lapse otherwise.
        let closing = velocity < -12
        let preArmTop = clearAngle + Self.preArmMargin + min(-velocity, 600) * 0.03
        let preArming = !visible && closing && raw < preArmTop && raw >= clearAngle - 1
        if preArming {
            keepWarm()
        } else if !visible && !pendingShow && stream != nil && idleStop == nil {
            stopStreamSoon()
        }

        let resolved = resolveRelease(target: target, angle: raw, now: now)
        // Lead prediction, only while the sensor is driving (not during a release or after one):
        // aim the renderer at where the lid will be one filter constant from now.
        var renderTarget = resolved
        if resolved == target {
            var lead = 0.0
            if abs(velocity) > Self.leadDeadZone {
                lead = min(max(velocity * Self.leadSeconds, -Self.leadMaxDegrees), Self.leadMaxDegrees)
            }
            renderTarget = turn(for: estimate + lead)
        }
        renderer.targetTurn = Float(renderTarget)
        let speed = abs(velocity)
        renderer.motionBoost = speed > 30 ? Float(min((speed - 30) * 0.02, 12)) : 0

        if resolved > Self.showAbove {
            if fadeDeadline != nil {       // reopening reversed mid-fade: keep the same frozen frame
                fadeDeadline = nil
                panel.alphaValue = 1
            }
            if !visible && !pendingShow { show() }
        }
        // Hide is decided per drawn frame in frameDrawn, where the eased turn is fresh.
    }

    private func turn(for angle: Double) -> Double {
        let range = clearAngle - Self.endAngle
        guard range > 0.5 else { return 0 }
        return min(max((clearAngle - angle) / range, 0), 1)
    }

    // MARK: - Auto-release

    /// A lid parked at a partial angle is a screen someone is using, not a fold in progress. After
    /// `releaseAfter` inside `motionBand`, unwind the fold and stay unfolded until the lid is taken
    /// further closed than where it let go; then grow the fold back in from flat.
    private func resolveRelease(target: Double, angle: Double, now: CFTimeInterval) -> Double {
        if releasing {
            let t = min(1, (now - releaseStart) / Self.releaseDuration)
            let eased = 1 - pow(1 - t, 3)
            if abs(target - releasedAt) > Self.motionBand {      // the lid moved again: blend back to it, no snap
                releasing = false
                handingBack = true
                handbackStart = now
                handbackFrom = releaseFrom * (1 - eased)
                resetStillness(target)
                return handbackFrom
            }
            if t >= 1 {
                releasing = false
                released = true
                releasedFloor = target
                stillSince = 0
                return 0
            }
            return releaseFrom * (1 - eased)
        }
        if handingBack {
            let t = min(1, (now - handbackStart) / Self.handbackDuration)
            let eased = 1 - pow(1 - t, 3)
            if t >= 1 { handingBack = false; return target }
            return handbackFrom + (target - handbackFrom) * eased
        }
        if released {
            if target < releasedFloor - Self.motionBand { releasedFloor = target }
            guard target > releasedFloor + Self.motionBand else { return 0 }
            released = false
            reEngaging = true
            resetStillness(target)
        }
        guard target > 0, angle >= Self.noReleaseBelow else {
            resetStillness(target)
            return target
        }
        stillLow = min(stillLow, target)
        stillHigh = max(stillHigh, target)
        if stillHigh - stillLow > Self.motionBand {
            resetStillness(target)
            stillSince = now
        } else if stillSince == 0 {
            stillSince = now
        }
        if visible, target > Self.showAbove, stillSince > 0, now - stillSince >= Self.releaseAfter {
            releasing = true
            releaseStart = now
            releaseFrom = target
            releasedAt = target
        }
        return target
    }

    private func resetStillness(_ target: Double) {
        stillSince = 0
        stillLow = target
        stillHigh = target
    }

    // MARK: - Show / hide

    private func show() {
        guard Self.screenRecordingAllowed, !isClamshellDesktop else { return }
        pendingShow = true
        keepWarm()
        if let buffer = takeLatest() {
            renderer.setFrame(buffer)          // onFrameReady -> present()
        } else {
            lock.lock(); awaitingFrame = true; lock.unlock()   // cold gate: the first stream frame shows the fold
        }
    }

    /// The frozen frame is on the GPU. Refit the panel, start the render loop, and reveal it two
    /// frames later so the first thing on glass is a folded frame, never the clear color.
    private func present() {
        guard pendingShow else { return }
        pendingShow = false
        let screen = Self.builtInScreen()
        if let screen = screen, panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        if reEngaging {
            renderer.seed(turn: 0)
            reEngaging = false
        }
        visible = true
        isFolded = true
        framesSinceShow = 0
        panel.alphaValue = 0
        renderer.resume(on: screen)
        panel.orderFrontRegardless()
    }

    private func frameDrawn(at now: CFTimeInterval) {
        guard visible else { return }
        framesSinceShow += 1
        if framesSinceShow == 2 && fadeDeadline == nil { panel.alphaValue = 1 }
        if let deadline = fadeDeadline {
            let remaining = (deadline - now) / Self.openFade
            if remaining <= 0 { hide() } else { panel.alphaValue = CGFloat(remaining) }
            return
        }
        if renderer.targetTurn <= 0 && renderer.displayedTurn < Self.hideBelow {
            fadeDeadline = now + Self.openFade
        }
    }

    private func hide() {
        let wasVisible = visible
        visible = false
        pendingShow = false
        reEngaging = false
        fadeDeadline = nil
        lock.lock()
        awaitingFrame = false
        latest = nil                                   // a re-show must use a frame taken after this hide
        acceptFramesAfter = CACurrentMediaTime() + 0.05
        lock.unlock()
        panel.orderOut(nil)
        panel.alphaValue = 0
        renderer.suspend()
        renderer.discardFrame()
        renderer.targetTurn = 0
        if wasVisible { stopStreamSoon() }
        isFolded = false
    }

    @objc private func interrupted() {
        hide()
        stopStream()
        releasing = false
        released = false
        handingBack = false
    }

    @objc private func screensChanged() {
        hide()
        stopStream()
        if let screen = Self.builtInScreen() { panel.setFrame(screen.frame, display: false) }
    }

    /// Built-in panel asleep or missing from the active display list: nothing to fold.
    private var isClamshellDesktop: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return false }
        for i in 0..<Int(count) where CGDisplayIsBuiltin(ids[i]) != 0 {
            return CGDisplayIsAsleep(ids[i]) != 0
        }
        return true
    }

    // MARK: - Capture stream

    private func keepWarm() {
        idleStop?.cancel()
        idleStop = nil
        guard stream == nil, !starting, Self.screenRecordingAllowed else { return }
        starting = true
        streamGeneration &+= 1
        let generation = streamGeneration
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let result = await self.startStream()
            guard self.streamGeneration == generation else {
                if case .success(let stale) = result { Task { try? await stale.stopCapture() } }
                return
            }
            self.starting = false
            switch result {
            case .success(let stream): self.stream = stream
            case .failure(let error): self.onCaptureFailure?(error.localizedDescription)
            }
        }
    }

    @MainActor
    private func startStream() async -> Result<SCStream, Error> {
        do {
            // Off-screen windows included, so the ordered-out overlay can be excluded by window number.
            // Never exclude the whole app: LiveWall's wallpaper windows must stay in the frame.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.displayUnavailable
            }
            let mine = content.windows.filter { $0.windowID == CGWindowID(panel.windowNumber) }
            let filter = SCContentFilter(display: display, excludingWindows: mine)
            let scale = Self.builtInScreen()?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.width = max(2, Int(CGFloat(display.width) * scale))     // native Retina: the shader assumes two texels per point
            config.height = max(2, Int(CGFloat(display.height) * scale))
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 3
            config.showsCursor = false
            config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
            return .success(stream)
        } catch {
            return .failure(error)
        }
    }

    private func stopStreamSoon() {
        idleStop?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.idleStop = nil
            self?.stopStream()
        }
        idleStop = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.streamIdleTail, execute: item)
    }

    private func stopStream() {
        idleStop?.cancel()
        idleStop = nil
        streamGeneration &+= 1
        starting = false
        let old = stream
        stream = nil
        lock.lock()
        latest = nil
        awaitingFrame = false
        lock.unlock()
        if let old = old {
            Task { try? await old.stopCapture() }    // can stall for seconds; never on the caller
        }
    }

    private func takeLatest() -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        awaitingFrame = false
        return latest
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        lock.lock()
        guard timestamp > acceptFramesAfter else { lock.unlock(); return }   // frames that may still contain the fading overlay
        latest = pixelBuffer
        let wanted = awaitingFrame
        lock.unlock()
        if wanted {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.pendingShow, let buffer = self.takeLatest() else { return }
                self.renderer.setFrame(buffer)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.stream === stream else { return }
            self.stream = nil
            self.hide()
            self.onCaptureFailure?(error.localizedDescription)
        }
    }

    // MARK: - Permission and display helpers

    static var screenRecordingAllowed: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system consent dialog the first time. macOS applies a new grant after relaunch.
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let id = displayID(of: screen) else { return false }
            return CGDisplayIsBuiltin(id) != 0
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    enum CaptureError: LocalizedError {
        case displayUnavailable
        var errorDescription: String? { "The built-in display is not available for capture." }
    }
}

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

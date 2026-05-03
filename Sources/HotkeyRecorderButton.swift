import Cocoa
import Carbon.HIToolbox

/// A button that displays the current global hotkey and lets the user
/// re-record it. Click → "Press a new shortcut…" → next keystroke captures
/// keyCode + Carbon modifier mask. Esc cancels.
final class HotkeyRecorderButton: NSButton {

    var onRecorded: ((UInt32, UInt32) -> Void)?

    private(set) var keyCode: UInt32 = 35
    private(set) var modifiers: UInt32 = 0

    private var isRecording = false {
        didSet { refreshTitle() }
    }
    private var localMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        bezelStyle = .rounded
        target = self
        action = #selector(toggleRecording)
        refreshTitle()
    }

    deinit { stopRecording() }

    /// Set the displayed hotkey (without invoking onRecorded).
    func setHotkey(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        refreshTitle()
    }

    @objc private func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        // Local monitor: only fires while our app is frontmost. That's
        // exactly what we want — we don't want to swallow keystrokes
        // globally while in record mode.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isRecording else { return event }
            if event.keyCode == kVK_Escape {
                self.stopRecording()
                return nil
            }
            // Need at least one modifier to qualify as a global shortcut.
            let cocoaMods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !cocoaMods.isEmpty else { return event }

            self.keyCode = UInt32(event.keyCode)
            self.modifiers = HotkeyRecorderButton.toCarbonModifiers(cocoaMods)
            self.stopRecording()
            self.onRecorded?(self.keyCode, self.modifiers)
            return nil
        }
    }

    private func stopRecording() {
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        isRecording = false
    }

    private func refreshTitle() {
        if isRecording {
            title = "Press a new shortcut…   (Esc to cancel)"
        } else {
            title = HotkeyFormatter.display(keyCode: keyCode, modifiers: modifiers)
        }
    }

    private static func toCarbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }
}

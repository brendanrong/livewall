import Cocoa
import Carbon.HIToolbox

/// Registers a single global hotkey via the Carbon API.
///
/// Carbon's `RegisterEventHotKey` is the standard way menu-bar utilities
/// (Alfred, Magnet, etc.) bind system-wide shortcuts. It does NOT require
/// Accessibility permission — unlike `NSEvent.addGlobalMonitorForEvents`.
final class HotkeyManager {

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4C575F50   // 'LW_P'

    deinit { unregister() }

    /// Register the given key+modifiers. Returns true on success.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()

        // Install the application-wide event handler the first time.
        if eventHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, _, ctx) -> OSStatus in
                    guard let ctx = ctx else { return noErr }
                    let me = Unmanaged<HotkeyManager>.fromOpaque(ctx).takeUnretainedValue()
                    DispatchQueue.main.async { me.onTrigger?() }
                    return noErr
                },
                1, &spec, context, &eventHandler
            )
            if status != noErr {
                NSLog("LiveWall: InstallEventHandler failed (\(status))")
                return false
            }
        }

        let hotKeyID = EventHotKeyID(signature: HotkeyManager.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref = ref {
            hotKeyRef = ref
            return true
        }
        NSLog("LiveWall: RegisterEventHotKey failed (\(status))")
        return false
    }

    func unregister() {
        if let h = hotKeyRef {
            UnregisterEventHotKey(h)
            hotKeyRef = nil
        }
    }
}

// MARK: - Display helpers

enum HotkeyFormatter {
    /// Pretty-print a Carbon (keyCode, modifiers) pair as e.g. "⌘⌥P".
    static func display(keyCode: UInt32, modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += keyName(for: keyCode)
        return s
    }

    private static func keyName(for code: UInt32) -> String {
        // A pragmatic subset — covers the keys people actually pick for
        // global hotkeys. Falls back to "Key 0xNN" for the obscure stuff.
        switch Int(code) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space:  return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_Tab:    return "⇥"
        case kVK_F1:     return "F1"
        case kVK_F2:     return "F2"
        case kVK_F3:     return "F3"
        case kVK_F4:     return "F4"
        case kVK_F5:     return "F5"
        case kVK_F6:     return "F6"
        case kVK_F7:     return "F7"
        case kVK_F8:     return "F8"
        case kVK_F9:     return "F9"
        case kVK_F10:    return "F10"
        case kVK_F11:    return "F11"
        case kVK_F12:    return "F12"
        default:         return String(format: "Key 0x%02X", code)
        }
    }
}

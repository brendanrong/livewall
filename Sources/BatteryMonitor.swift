import Foundation
import IOKit
import IOKit.ps

/// Watches the system power source and reports whether we're on battery.
/// Posts `stateChangedNotification` whenever AC/battery transitions occur.
final class BatteryMonitor {
    static let stateChangedNotification = Notification.Name("LiveWall.batteryStateChanged")

    /// `true` when running on battery, `false` on AC. `nil` for desktops or
    /// machines without a battery (in which case "on battery" is never true).
    private(set) var isOnBattery: Bool = false
    private(set) var hasBattery: Bool = false

    private var runLoopSource: CFRunLoopSource?

    init() {
        refreshState()
        startObserving()
    }

    deinit { stopObserving() }

    private func startObserving() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let me = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            me.refreshState()
            NotificationCenter.default.post(
                name: BatteryMonitor.stateChangedNotification, object: nil
            )
        }, context).takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    private func stopObserving() {
        if let s = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .defaultMode)
            runLoopSource = nil
        }
    }

    private func refreshState() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            hasBattery = false; isOnBattery = false; return
        }
        guard let listCF = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() else {
            hasBattery = false; isOnBattery = false; return
        }
        let list = listCF as Array
        var foundBattery = false
        var onBattery = false
        for source in list {
            guard let descCF = IOPSGetPowerSourceDescription(blob, source as CFTypeRef)?.takeUnretainedValue(),
                  let desc = descCF as? [String: Any] else { continue }
            // Real internal battery (skip UPS / external)
            if let type = desc[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType {
                foundBattery = true
                if let state = desc[kIOPSPowerSourceStateKey] as? String,
                   state == kIOPSBatteryPowerValue {
                    onBattery = true
                }
            }
        }
        self.hasBattery = foundBattery
        self.isOnBattery = onBattery
    }
}

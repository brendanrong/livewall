import AppKit
import Foundation
import IOKit
import IOKit.hid

/// Reads the MacBook lid-angle sensor and posts smoothed readings.
///
/// The sensor is an undocumented Apple HID device: vendor 0x05AC, usage page
/// 0x0020 (Sensor), usage 0x008A (Orientation). Feature report 1 carries the
/// lid angle in whole degrees, little-endian, in bytes 1-2. 0 = closed,
/// ~180 = lid flat. Present on the 16-inch MacBook Pro (2019) and later and on
/// Apple silicon MacBook Pros from M1 Pro onward. The M1 Air and the 13-inch
/// M1/M2 Pro reportedly do not expose it, so `isAvailable` must gate every use.
///
/// Same shape as BatteryMonitor: a plain class owned by AppDelegate that posts
/// notifications when state changes. Everything runs on the main run loop.
final class LidAngleMonitor {
    static let angleChangedNotification = Notification.Name("LiveWall.lidAngleChanged")
    static let availabilityChangedNotification = Notification.Name("LiveWall.lidSensorAvailabilityChanged")

    /// True when a readable sensor was found. Flips to false at runtime if
    /// reads start failing; the overlay treats that as "hide immediately".
    private(set) var isAvailable = false

    /// Latest raw reading in degrees; nil until the first successful read.
    private(set) var rawAngle: Double?

    /// Smoothed angle in degrees. Reopening responds faster than closing so
    /// the desktop snaps back the moment you lift the lid.
    private(set) var angle: Double = 180

    /// Below this angle we poll at 60 Hz; above it, 10 Hz. Keep it a few
    /// degrees above the fold's clear angle so the first folding frames are
    /// already sampled at full rate.
    var activeBelow: Double = 118

    private let manager: IOHIDManager
    private var device: IOHIDDevice?
    private var isOpen = false
    private var timer: Timer?
    private var report = [UInt8](repeating: 0, count: 8)
    private var failures = 0
    private var lastSampleTime = CFAbsoluteTimeGetCurrent()
    private var rediscoverTimer: Timer?
    private var rediscoverAttempts = 0

    private static let idleInterval: TimeInterval = 1.0 / 10.0
    private static let activeInterval: TimeInterval = 1.0 / 60.0
    private static let maxFailures = 5
    private static let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)
    /// The sensor is sometimes not enumerable (first seconds after launch, still held by a previous
    /// instance, or the Mac was asleep and reads failed). Keep looking for it, and never give up: a
    /// long sleep would otherwise exhaust a bounded retry while the machine is still asleep. Fast
    /// for the first half minute, then a slow heartbeat.
    private static let rediscoverInterval: TimeInterval = 2
    private static let rediscoverSlowInterval: TimeInterval = 15
    private static let rediscoverFastAttempts = 15

    init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, Self.noOptions)
        // After wake the device is usually back within a second; retry right away instead of
        // waiting for the heartbeat, and forgive read failures that happened while asleep.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDDeviceUsagePageKey as String: 0x0020,
            kIOHIDDeviceUsageKey as String: 0x008A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, Self.noOptions)
        device = Self.firstReadableDevice(in: manager)
        isAvailable = device != nil
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stop()
        IOHIDManagerClose(manager, Self.noOptions)
    }

    @objc private func didWake() {
        failures = 0
        guard !isAvailable else { return }
        rediscoverTimer?.invalidate()
        rediscoverTimer = nil
        rediscoverAttempts = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.rediscover()
            self?.scheduleRediscovery()
        }
    }

    // MARK: - Control

    func start() {
        guard timer == nil else { return }
        guard isAvailable, let device = device else {
            scheduleRediscovery()
            return
        }
        guard IOHIDDeviceOpen(device, Self.noOptions) == kIOReturnSuccess else {
            markUnavailable()
            return
        }
        isOpen = true
        failures = 0
        if let first = Self.read(device, into: &report) {
            rawAngle = first
            angle = first
        }
        schedule(Self.idleInterval)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        rediscoverTimer?.invalidate()
        rediscoverTimer = nil
        if isOpen, let device = device {
            IOHIDDeviceClose(device, Self.noOptions)
            isOpen = false
        }
    }

    // MARK: - Polling

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        t.tolerance = interval * 0.2
        timer = t
    }

    private func poll() {
        guard let device = device, let reading = Self.read(device, into: &report) else {
            failures += 1
            if failures >= Self.maxFailures { markUnavailable() }
            return
        }
        failures = 0
        rawAngle = reading

        // Frame-rate independent exponential smoothing.
        let now = CFAbsoluteTimeGetCurrent()
        let dt = min(max(now - lastSampleTime, 0), 0.1)
        lastSampleTime = now
        let response = reading > angle ? 0.055 : 0.10   // seconds; faster when opening
        angle += (reading - angle) * (1 - exp(-dt / response))
        if abs(angle - reading) < 0.05 { angle = reading }

        // Adaptive rate: fast only while the fold can be visible.
        let wantFast = angle < activeBelow
        let current = timer?.timeInterval ?? Self.idleInterval
        if wantFast && current > Self.activeInterval * 1.5 {
            schedule(Self.activeInterval)
        } else if !wantFast && current < Self.idleInterval * 0.5 {
            schedule(Self.idleInterval)
        }

        NotificationCenter.default.post(name: Self.angleChangedNotification, object: nil)
    }

    private func markUnavailable() {
        stop()
        isAvailable = false
        NotificationCenter.default.post(name: Self.availabilityChangedNotification, object: nil)
        rediscoverAttempts = 0
        scheduleRediscovery()
    }

    // MARK: - Rediscovery

    /// Look for the sensor again every few seconds, for a while. Runs when the device was not found
    /// at launch or stopped answering. On success, starts polling and tells the app.
    private func scheduleRediscovery() {
        guard rediscoverTimer == nil, !isAvailable else { return }
        let interval = rediscoverAttempts < Self.rediscoverFastAttempts ? Self.rediscoverInterval : Self.rediscoverSlowInterval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.rediscover()
        }
        t.tolerance = interval * 0.2
        rediscoverTimer = t
    }

    private func rediscover() {
        rediscoverAttempts += 1
        if let found = Self.firstReadableDevice(in: manager) {
            rediscoverTimer?.invalidate()
            rediscoverTimer = nil
            rediscoverAttempts = 0
            device = found
            isAvailable = true
            start()
            if isAvailable {
                NotificationCenter.default.post(name: Self.availabilityChangedNotification, object: nil)
            }
        } else if rediscoverAttempts == Self.rediscoverFastAttempts {
            // Drop to the slow heartbeat.
            rediscoverTimer?.invalidate()
            rediscoverTimer = nil
            scheduleRediscovery()
        }
    }

    // MARK: - HID plumbing (isolated so a future report-format change is a one-place fix)

    private static func read(_ device: IOHIDDevice, into buffer: inout [UInt8]) -> Double? {
        var length = CFIndex(buffer.count)
        let result = buffer.withUnsafeMutableBufferPointer { ptr -> IOReturn in
            guard let base = ptr.baseAddress else { return kIOReturnError }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, base, &length)
        }
        guard result == kIOReturnSuccess, length >= 3 else { return nil }
        let degrees = Int(buffer[1]) | (Int(buffer[2]) << 8)
        guard (0...180).contains(degrees) else { return nil }
        return Double(degrees)
    }

    private static func firstReadableDevice(in manager: IOHIDManager) -> IOHIDDevice? {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        var scratch = [UInt8](repeating: 0, count: 8)
        for candidate in devices {
            guard IOHIDDeviceOpen(candidate, noOptions) == kIOReturnSuccess else { continue }
            let ok = read(candidate, into: &scratch) != nil
            IOHIDDeviceClose(candidate, noOptions)
            if ok { return candidate }
        }
        return nil
    }
}

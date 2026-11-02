import CoreFoundation
import Darwin
import Foundation
import IcliKit
import notify

/// Makes Auto-Lock "Never" hold on the Lock Screen too.
///
/// Settings › Display & Brightness › Auto-Lock sets `maxInactivity`, and
/// SpringBoard applies it only while the device is unlocked. On the Lock
/// Screen it uses its own six seconds whatever the setting says, so a guest
/// that has just booted, or whose SpringBoard has just restarted, goes dark
/// before anyone looks at it.
///
/// SpringBoard reads one more value there, `SBMinimumLockscreenIdleTime` in
/// `com.apple.springboard`, and replaces the six seconds with it. vphoned
/// keeps that key at the same "never" while Auto-Lock is Never, and removes
/// it again when Auto-Lock is anything else. A value some other tool put
/// there is left alone.
///
/// SpringBoard takes the key when it starts. Setting it later does nothing
/// until SpringBoard restarts, and changing or removing it puts the six
/// seconds back at once. So this runs before anything else at startup, to be
/// ahead of SpringBoard on a boot where the key is missing.
///
/// Measured on iOS 27.0 and iPadOS 26.6.2; see
/// Research/Guest/lock_screen_idle_timer.md.
enum GuestLockScreenIdle {
    /// profiled's merged settings for user mobile. It rewrites the file and
    /// then posts `changedNotification`; ManagedConfiguration's own clients
    /// re-read it on the same signal.
    nonisolated(unsafe) static var settingsPath = "/var/mobile/Library/UserConfigurationProfiles/EffectiveUserSettings.plist"
    nonisolated(unsafe) static var userSettingsPath = "/var/mobile/Library/UserConfigurationProfiles/UserSettings.plist"
    private static let changedNotification = "com.apple.managedconfiguration.effectivesettingschanged"
    private static let domain = "com.apple.springboard"
    private static let key = "SBMinimumLockscreenIdleTime"
    /// What Settings stores for "Never", in seconds.
    private static let never = Int(Int32.max)
    private static let queue = DispatchQueue(label: "vphoned.lock-screen-idle", qos: .utility)

    static func startOnStartup() {
        queue.sync { apply(reason: "startup") }
        var token: Int32 = 0
        let status = notify_register_dispatch(changedNotification, &token, queue) { _ in
            apply(reason: "settings changed")
        }
        if status != 0 {
            NSLog("vphoned: lock screen idle: cannot observe Auto-Lock changes (notify status %u)", status)
        }
    }

    /// Auto-Lock in seconds, `never` for Never, nil when profiled has not
    /// written its settings yet.
    static func autoLockSeconds() -> Int? {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let values = plist["restrictedValue"] as? [String: Any],
              let setting = values["maxInactivity"] as? [String: Any]
        else { return nil }
        return (setting["value"] as? NSNumber)?.intValue
    }

    static func lockScreenMinimum() -> Int? {
        let value = CFPreferencesCopyValue(key as CFString, domain as CFString, "mobile" as CFString, kCFPreferencesAnyHost)
        return (value as? NSNumber)?.intValue
    }

    static func describe() -> [String: Any] {
        let autoLock = autoLockSeconds()
        let minimum = lockScreenMinimum()
        return [
            "auto_lock_seconds": autoLock.map { $0 as Any } ?? NSNull(),
            "never": autoLock.map { $0 >= never } ?? false,
            "lock_screen_minimum_seconds": minimum.map { $0 as Any } ?? NSNull(),
        ]
    }

    /// Updates both UserSettings.plist and EffectiveUserSettings.plist on disk,
    /// synchronizes notifications, and mirrors Never into SpringBoard lock screen idle.
    static func setAutoLockSeconds(_ seconds: Int) throws -> [String: Any] {
        guard seconds >= 0, seconds <= Int(Int32.max) else {
            throw IcliError.failed("Auto-Lock seconds must be between 0 and Int32.max")
        }
        let effectiveSeconds = (seconds == 0) ? never : seconds
        // Validate both inputs before changing either file. Each subsequent
        // write is atomic; the pair is not a filesystem transaction.
        let userData = try updatedSettingsPlist(atPath: userSettingsPath, seconds: effectiveSeconds)
        let effectiveData = try updatedSettingsPlist(atPath: settingsPath, seconds: effectiveSeconds)
        try writeSettingsPlist(userData, atPath: userSettingsPath)
        try writeSettingsPlist(effectiveData, atPath: settingsPath)
        notify_post(changedNotification)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(changedNotification as CFString),
            nil,
            nil,
            true
        )
        apply(reason: "requested Auto-Lock \(seconds)s")
        var result = describe()
        result["requested_auto_lock_seconds"] = seconds
        return result
    }

    private static func updatedSettingsPlist(atPath path: String, seconds: Int) throws -> Data {
        var plist: [String: Any] = [:]
        let data: Data?
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch CocoaError.fileReadNoSuchFile {
            data = nil
        }
        if let data {
            guard let existing = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw IcliError.failed("Settings plist must contain a dictionary: \(path)")
            }
            plist = existing
        }
        guard plist["restrictedValue"] == nil || plist["restrictedValue"] is [String: Any] else {
            throw IcliError.failed("restrictedValue must contain a dictionary: \(path)")
        }
        var restricted = plist["restrictedValue"] as? [String: Any] ?? [:]
        guard restricted["maxInactivity"] == nil || restricted["maxInactivity"] is [String: Any] else {
            throw IcliError.failed("maxInactivity must contain a dictionary: \(path)")
        }
        var setting = restricted["maxInactivity"] as? [String: Any] ?? [:]
        setting["value"] = seconds
        if seconds >= never || seconds < (setting["rangeMinimum"] as? Int ?? 0) {
            setting.removeValue(forKey: "rangeMinimum")
        }
        restricted["maxInactivity"] = setting
        plist["restrictedValue"] = restricted
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    private static func writeSettingsPlist(_ data: Data, atPath path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dir) {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            chown(dir, 501, 501)
        }
        let url = URL(fileURLWithPath: path)
        try data.write(to: url, options: .atomic)
        chown(path, 501, 501)
        chmod(path, 0o644)
    }

    private static func apply(reason: String) {
        guard let autoLock = autoLockSeconds() else {
            NSLog("vphoned: lock screen idle (%@): Auto-Lock is not readable, nothing changed", reason)
            return
        }
        let minimum = lockScreenMinimum()
        do {
            if autoLock >= never {
                guard minimum != never else { return }
                _ = try writePreference(domain: domain, key: key, value: .int(Int64(never)))
                NSLog("vphoned: lock screen idle (%@): Auto-Lock is Never, Lock Screen follows from the next SpringBoard start", reason)
            } else if minimum == never {
                _ = try deletePreference(domain: domain, key: key)
                NSLog("vphoned: lock screen idle (%@): Auto-Lock is %d s, Lock Screen is back to its own timeout", reason, autoLock)
            }
        } catch {
            NSLog("vphoned: lock screen idle (%@): %@", reason, String(describing: error))
        }
    }
}

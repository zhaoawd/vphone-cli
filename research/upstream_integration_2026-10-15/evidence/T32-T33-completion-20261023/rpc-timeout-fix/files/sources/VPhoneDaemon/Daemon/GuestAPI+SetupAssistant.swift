import Darwin
import Foundation

extension GuestAPI {
    /// Read the mobile preferences used by SpringBoard. Unknown framework
    /// versions remain unknown; this does not modify or skip Setup Assistant.
    static func setupAssistantPending() -> Bool? {
        let domain = "com.apple.purplebuddy" as CFString
        func value(_ key: String) -> Any? {
            CFPreferencesCopyValue(key as CFString, domain, "mobile" as CFString, kCFPreferencesAnyHost)
        }
        guard value("SetupDone") as? Bool == true else { return true }
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SetupAssistant.framework/SetupAssistant", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "BYBuddyIOSCurrentVersion") else { return nil }
        let current = Int(symbol.assumingMemoryBound(to: Int32.self).pointee)
        guard current > 0 else { return nil }
        return ((value("SetupVersion") as? NSNumber)?.intValue ?? 0) < current
    }
}

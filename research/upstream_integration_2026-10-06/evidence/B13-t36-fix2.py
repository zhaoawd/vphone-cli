from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/vphone-cli/VPhoneAppDelegate.swift';s=p.read_text().replace('let unlock = VPhoneStartupUnlock(enabled: cli.unlockAtStartup || (try VPhoneVirtualMachineManifest.load(from: options.configURL)).usesStartupUnlock)', 'let persistedUnlock = try VPhoneVirtualMachineManifest.load(from: options.configURL).usesStartupUnlock\n                        let unlock = VPhoneStartupUnlock(enabled: cli.unlockAtStartup || persistedUnlock)');p.write_text(s)
p=r/'sources/VPhoneDaemon/Daemon/GuestAPI.swift';s=p.read_text();s=s.replace('        return [\n            "name": "vphoned",','        var result: [String: Any] = [\n            "name": "vphoned",',1);s=s.replace('    static func execute(method:', '    static func execute(method:',1);s=s.replace('        ]\n    }\n\n    static func execute(method:', '        ]\n        if let pending = setupAssistantPending() { result["setup_pending"] = pending }\n        return result\n    }\n\n    static func execute(method:',1);p.write_text(s)
(r/'sources/VPhoneDaemon/Daemon/GuestAPI+SetupAssistant.swift').write_text('''import Darwin
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
        return (value("SetupVersion") as? NSNumber)?.intValue ?? 0 < current
    }
}
''')

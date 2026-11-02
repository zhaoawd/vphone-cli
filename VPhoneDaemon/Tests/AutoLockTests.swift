import Foundation
import IcliKit

@main
enum AutoLockTests {
    static func main() throws {
        var checks = 0, failures = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: \(label)") }
        }

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let userPlist = tmpDir.appendingPathComponent("UserSettings.plist").path
        let effectivePlist = tmpDir.appendingPathComponent("EffectiveUserSettings.plist").path
        GuestLockScreenIdle.userSettingsPath = userPlist
        GuestLockScreenIdle.settingsPath = effectivePlist

        // Initially absent
        let desc0 = GuestLockScreenIdle.describe()
        expect(desc0["auto_lock_seconds"] is NSNull, "initial auto_lock_seconds is null")
        expect(desc0["never"] as? Bool == false, "initial never is false")

        // Set to 1800 seconds
        let res1800 = try GuestLockScreenIdle.setAutoLockSeconds(1800)
        expect(res1800["auto_lock_seconds"] as? Int == 1800, "res1800 auto_lock_seconds is 1800")
        expect(res1800["never"] as? Bool == false, "res1800 never is false")
        expect(res1800["requested_auto_lock_seconds"] as? Int == 1800, "res1800 requested is 1800")

        let desc1800 = GuestLockScreenIdle.describe()
        expect(desc1800["auto_lock_seconds"] as? Int == 1800, "describe auto_lock_seconds is 1800")

        // Verify disk files
        guard let dataUser = FileManager.default.contents(atPath: userPlist),
              let dictUser = try PropertyListSerialization.propertyList(from: dataUser, format: nil) as? [String: Any],
              let restUser = dictUser["restrictedValue"] as? [String: Any],
              let maxInactUser = restUser["maxInactivity"] as? [String: Any]
        else { fatalError("UserSettings.plist corrupt") }
        expect(maxInactUser["value"] as? Int == 1800, "UserSettings value is 1800")

        guard let dataEff = FileManager.default.contents(atPath: effectivePlist),
              let dictEff = try PropertyListSerialization.propertyList(from: dataEff, format: nil) as? [String: Any],
              let restEff = dictEff["restrictedValue"] as? [String: Any],
              let maxInactEff = restEff["maxInactivity"] as? [String: Any]
        else { fatalError("EffectiveUserSettings.plist corrupt") }
        expect(maxInactEff["value"] as? Int == 1800, "EffectiveUserSettings value is 1800")

        // Set to Never (0 seconds)
        let resNever = try GuestLockScreenIdle.setAutoLockSeconds(0)
        expect(resNever["never"] as? Bool == true, "resNever never is true")
        expect(resNever["auto_lock_seconds"] as? Int == Int(Int32.max), "resNever value is Int32.max")

        let descNever = GuestLockScreenIdle.describe()
        expect(descNever["never"] as? Bool == true, "describe never is true")

        // Set to 60 seconds (clamping removal test)
        let res60 = try GuestLockScreenIdle.setAutoLockSeconds(60)
        expect(res60["auto_lock_seconds"] as? Int == 60, "res60 auto_lock_seconds is 60")
        expect(res60["never"] as? Bool == false, "res60 never is false")

        // Invalid negative value throws
        var threwNegative = false
        do {
            _ = try GuestLockScreenIdle.setAutoLockSeconds(-1)
        } catch {
            threwNegative = true
        }
        expect(threwNegative, "negative seconds throws")

        print("auto-lock tests: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}

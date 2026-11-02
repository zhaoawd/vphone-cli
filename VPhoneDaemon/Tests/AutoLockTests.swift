import Foundation
import IcliKit

enum GuestAPIError: Error { case invalidRequest(String) }
enum GuestAPI {}

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

        func plistData(_ value: Any) throws -> Data {
            try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        }
        func readPlist(_ path: String) throws -> [String: Any] {
            try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
        }

        // Seed the actual restriction before each request, including Never.
        let seeded: [String: Any] = [
            "unrelated": "preserve",
            "restrictedValue": [
                "otherSetting": ["value": 42],
                "maxInactivity": ["value": 300, "rangeMinimum": 120, "metadata": "keep"],
            ],
        ]
        for seconds in [0, 60, 1800] {
            try plistData(seeded).write(to: URL(fileURLWithPath: userPlist))
            try plistData(seeded).write(to: URL(fileURLWithPath: effectivePlist))
            _ = try GuestLockScreenIdle.setAutoLockSeconds(seconds)
            for path in [userPlist, effectivePlist] {
                let plist = try readPlist(path)
                let restricted = plist["restrictedValue"] as! [String: Any]
                let setting = restricted["maxInactivity"] as! [String: Any]
                expect(setting["value"] as? Int == (seconds == 0 ? Int(Int32.max) : seconds), "seeded value: \(seconds), \(path)")
                expect(seconds < 120 ? setting["rangeMinimum"] == nil : setting["rangeMinimum"] as? Int == 120,
                       "rangeMinimum removed only when needed: \(seconds), \(path)")
                expect(plist["unrelated"] as? String == "preserve"
                    && (restricted["otherSetting"] as? [String: Int])?["value"] == 42
                    && setting["metadata"] as? String == "keep", "unrelated settings preserved: \(path)")
            }
        }

        // Either invalid input must reject the request before either file changes.
        let valid = try plistData(seeded)
        let invalidInputs: [(String, Data)] = [
            ("corrupt", Data("not a plist".utf8)),
            ("array root", try plistData(["unexpected"])),
            ("invalid restrictedValue", try plistData(["restrictedValue": "unexpected"])),
            ("invalid maxInactivity", try plistData(["restrictedValue": ["maxInactivity": "unexpected"]])),
        ]
        for (label, invalid) in invalidInputs {
            for invalidPath in [userPlist, effectivePlist] {
                let userBefore = invalidPath == userPlist ? invalid : valid
                let effectiveBefore = invalidPath == effectivePlist ? invalid : valid
                try userBefore.write(to: URL(fileURLWithPath: userPlist))
                try effectiveBefore.write(to: URL(fileURLWithPath: effectivePlist))
                var rejected = false
                do { _ = try GuestLockScreenIdle.setAutoLockSeconds(60) }
                catch { rejected = true }
                expect(rejected, "\(label) rejected: \(invalidPath)")
                expect(try Data(contentsOf: URL(fileURLWithPath: userPlist)) == userBefore, "\(label): user file unchanged")
                expect(try Data(contentsOf: URL(fileURLWithPath: effectivePlist)) == effectiveBefore, "\(label): effective file unchanged")
            }
        }

        // A directory at the read path gives a deterministic read error without
        // relying on permission bits (the runner may be root).
        let unreadable = tmpDir.appendingPathComponent("directory-instead-of-plist")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
        GuestLockScreenIdle.settingsPath = unreadable.path
        try valid.write(to: URL(fileURLWithPath: userPlist))
        var rejectedReadError = false
        do { _ = try GuestLockScreenIdle.setAutoLockSeconds(60) }
        catch { rejectedReadError = true }
        expect(rejectedReadError, "file read error rejected")
        expect(try Data(contentsOf: URL(fileURLWithPath: userPlist)) == valid, "read error leaves user file unchanged")
        GuestLockScreenIdle.settingsPath = effectivePlist

        // Exercise the same request handler that executeDevice calls.
        try valid.write(to: URL(fileURLWithPath: effectivePlist))
        let neverRequest = try GuestAPI.setAutoLock(["never": true])
        expect(neverRequest["never"] as? Bool == true, "never:true request")
        let zeroRequest = try GuestAPI.setAutoLock(["seconds": 0])
        expect(zeroRequest["auto_lock_seconds"] as? Int == Int(Int32.max), "seconds:0 request")
        let secondsRequest = try GuestAPI.setAutoLock(["seconds": 1800])
        expect(secondsRequest["auto_lock_seconds"] as? Int == 1800, "seconds:1800 request")
        let beforeInvalidUser = try Data(contentsOf: URL(fileURLWithPath: userPlist))
        let beforeInvalidEffective = try Data(contentsOf: URL(fileURLWithPath: effectivePlist))
        let invalidRequests: [[String: Any]] = [
            [:], ["never": false], ["never": 1], ["never": "true"],
            ["seconds": true], ["seconds": 1.5], ["seconds": "60"],
            ["seconds": -1], ["seconds": Int64(Int32.max) + 1],
            ["seconds": NSNull(), "never": true],
        ]
        for params in invalidRequests {
            var rejected = false
            do { _ = try GuestAPI.setAutoLock(params) }
            catch GuestAPIError.invalidRequest { rejected = true }
            catch { }
            expect(rejected, "invalid request rejected as invalidRequest: \(params)")
            expect(try Data(contentsOf: URL(fileURLWithPath: userPlist)) == beforeInvalidUser
                && Data(contentsOf: URL(fileURLWithPath: effectivePlist)) == beforeInvalidEffective,
                   "invalid request leaves both files unchanged")
        }

        print("auto-lock tests: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}

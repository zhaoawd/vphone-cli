import Foundation
import IcliKit

enum GuestAPIError: Error { case invalidRequest(String), operationFailed(String) }
enum GuestAPI {
    static let interfaceLock = NSRecursiveLock()
    static func nestedHierarchy(_ params: [String: Any]) throws -> [String: Any] { fatalError("unused") }
    static func string(_ p: [String: Any], _ key: String) throws -> String { p[key] as! String }
    static func optionalString(_ p: [String: Any], _ key: String) -> String? { p[key] as? String }
    static func number(_ p: [String: Any], _ key: String, default fallback: Double = 0) -> Double { p[key] as? Double ?? fallback }
    static func requiredNumber(_ p: [String: Any], _ key: String) throws -> Double { p[key] as! Double }
    static func bool(_ p: [String: Any], _ key: String, default fallback: Bool = false) -> Bool { p[key] as? Bool ?? fallback }
}

@main
enum ElementTapAPITests {
    static func main() throws {
        var checks = 0, failures = 0
        func expect(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: \(label)") }
        }
        let params: [String: Any] = ["identifier": "target"]
        // Execute the actual RPC boundary repeatedly in one process, covering
        // inner -> cover -> inner -> rotated cover without a geometry cache.
        for (name, w, h) in [("inner", 669.0, 951.0), ("cover", 466.0, 678.0), ("inner", 669.0, 951.0), ("cover", 466.0, 678.0)] {
            for degrees in [0, 90, 180, 270] {
                TestIcli.degrees = degrees
                TestIcli.display = ["dual_display": true, "name": name, "width": w, "height": h]
                for bundle in ["com.autophone.tap-probe", "com.apple.springboard"] {
                    TestIcli.bundle = bundle
                    for (nx, ny) in [(0.2, 0.3), (0.7, 0.15), (0.85, 0.9)] {
                        // SpringBoard's fixed AX point was converted by icli
                        // with Main's dimensions; app AX uses the active panel.
                        let rw = bundle == "com.apple.springboard" ? TestIcli.primary.0 : w
                        let rh = bundle == "com.apple.springboard" ? TestIcli.primary.1 : h
                        let fx = nx * w, fy = ny * h
                        let x: Double, y: Double
                        switch degrees {
                        case 90: (x, y) = (rh - fy, fx)
                        case 180: (x, y) = (rw - fx, rh - fy)
                        case 270: (x, y) = (fy, rw - fx)
                        default: (x, y) = (fx, fy)
                        }
                        TestIcli.elements = [["identifier": "target", "x": x, "y": y,
                            "visible": false, "frame": ["x": x - 5, "y": y - 5, "width": 10.0, "height": 10.0]]]
                        TestIcli.injected = []
                        let result = try GuestAPI.executeInterface("ui.tap_element", params)
                        expect(result?["tapped"] as? Bool == true, "tap result")
                        let actual = TestIcli.injected.last ?? (-1, -1)
                        let expected = bundle == "com.apple.springboard" ? (fx, fy) : (x, y)
                        expect(TestIcli.injected.count == 1 && abs(actual.0 - expected.0) < 1e-9 && abs(actual.1 - expected.1) < 1e-9,
                               "\(name) \(degrees) \(bundle): context point \(expected), got \(actual)")
                    }
                }
            }
        }
        // Preserve the original context coordinates of a compatibility canvas;
        // the system owns its placement, scale and book-mode projection.
        TestIcli.bundle = "com.autophone.tap-probe"
        for (name, w, h) in [("cover", 466.0, 678.0), ("inner", 669.0, 951.0)] {
            for degrees in [0, 90, 180, 270] {
                TestIcli.degrees = degrees
                TestIcli.display = ["dual_display": true, "name": name, "width": w, "height": h]
                let sideways = [90, 270].contains(degrees)
                TestIcli.appFrame = ["x": 0.0, "y": 0.0, "width": sideways ? 667.0 : 375.0,
                                     "height": sideways ? 375.0 : 667.0]
                let x: Double, y: Double
                switch degrees {
                case 90: (x, y) = (267, 200)
                case 180: (x, y) = (175, 267)
                case 270: (x, y) = (400, 175)
                default: (x, y) = (200, 400)
                }
                TestIcli.elements = [["identifier": "target", "x": x, "y": y,
                    "frame": ["x": x - 5, "y": y - 5, "width": 10.0, "height": 10.0]]]
                TestIcli.injected = []
                _ = try GuestAPI.executeInterface("ui.tap_element", params)
                let actual = TestIcli.injected.last ?? (-1, -1)
                expect(abs(actual.0 - x) < 1e-9 && abs(actual.1 - y) < 1e-9,
                       "compatibility canvas \(name) \(degrees)")
            }
        }
        // Observed old-SDK scene: the inner parent is 90 degrees while the
        // application keeps its portrait 375x667 canvas.
        TestIcli.display = ["dual_display": true, "name": "inner", "width": 669.0, "height": 951.0]
        TestIcli.degrees = 90
        TestIcli.appFrame = ["x": 0.0, "y": 0.0, "width": 375.0, "height": 667.0]
        TestIcli.elements = [["identifier": "target", "x": 75.16666666666667, "y": 142.2,
            "frame": ["x": 39.0, "y": 120.2, "width": 72.0, "height": 44.0]]]
        TestIcli.injected = []
        _ = try GuestAPI.executeInterface("ui.tap_element", params)
        let pinned = TestIcli.injected.last ?? (-1, -1)
        expect(abs(pinned.0 - 75.16666666666667) < 1e-9 && abs(pinned.1 - 142.2) < 1e-9,
               "portrait application on rotated inner panel")
        TestIcli.appFrame = nil
        TestIcli.bundle = "com.autophone.tap-probe"
        TestIcli.elements = [["identifier": "target", "x": 100.0, "y": 124.0,
                             "frame": ["x": 90.0, "y": 114.0, "width": 20.0, "height": 20.0]]]
        TestIcli.degrees = 0
        func refuses(_ label: String) {
            TestIcli.injected = []
            do { _ = try GuestAPI.executeInterface("ui.tap_element", params); expect(false, label) }
            catch { expect(TestIcli.injected.isEmpty, "\(label): no injection") }
        }
        TestIcli.display = ["dual_display": true, "name": "inner", "width": 669.0, "height": 951.0]
        TestIcli.appFrame = ["error": "unavailable"]
        refuses("missing application frame")
        TestIcli.appFrame = ["x": 12.0, "y": 0.0, "width": 375.0, "height": 667.0]
        refuses("nonzero application origin")
        TestIcli.appFrame = ["x": 0.0, "y": 0.0, "width": 375.0, "height": 667.0]
        TestIcli.afterFrameRead = { TestIcli.appFrame?["width"] = 400.0 }
        refuses("application frame changes during query")
        TestIcli.afterFrameRead = nil
        TestIcli.appFrame = nil
        TestIcli.afterQuery = { TestIcli.display["name"] = "cover" }
        refuses("fold during query")
        TestIcli.afterQuery = { TestIcli.degrees = 90 }
        refuses("rotation during query")
        TestIcli.afterQuery = { TestIcli.bundle = "other.app" }
        refuses("foreground change")
        TestIcli.afterQuery = nil
        TestIcli.display = ["dual_display": true, "error": "state unavailable"]
        refuses("unknown panel")
        TestIcli.display = ["dual_display": true, "name": "inner", "width": 669.0, "height": 951.0]
        TestIcli.failInjection = true
        refuses("HID failure")
        TestIcli.failInjection = false
        TestIcli.truncated = true
        refuses("truncated query")
        TestIcli.truncated = false
        TestIcli.elements = []
        refuses("missing element")
        // A non-Duo uses the original route.
        TestIcli.display = ["dual_display": false]
        TestIcli.degrees = 0
        TestIcli.elements = [["identifier": "target", "x": 100.0, "y": 124.0]]
        TestIcli.injected = []
        _ = try GuestAPI.executeInterface("ui.tap_element", params)
        expect(abs(TestIcli.injected[0].0 - 100 / 466.0) < 1e-9, "single display legacy path")
        TestIcli.primary = (669, 951)
        TestIcli.injected = []
        _ = try GuestAPI.executeInterface("ui.tap_element", params)
        expect(abs(TestIcli.injected[0].0 - 100 / 669.0) < 1e-9, "static inner legacy path")
        TestIcli.primary = (466, 678)

        TestIcli.bundle = "com.autophone.tap-probe"
        TestIcli.display = ["dual_display": true, "name": "inner", "width": 669.0, "height": 951.0]
        TestIcli.elements = [
            ["identifier": "first", "label": "Target", "value": "", "role": "text", "clickable": false,
             "x": 120.0, "y": 124.0, "frame": ["x": 110.0, "y": 114.0, "width": 20.0, "height": 20.0]],
            ["identifier": "second", "label": "TARGET", "value": "", "role": "button", "clickable": true,
             "x": 200.0, "y": 124.0, "frame": ["x": 190.0, "y": 114.0, "width": 20.0, "height": 20.0]],
        ]
        for selection: [String: Any] in [
            ["text": "target", "match": "exact", "index": 1],
            ["text": "arg", "role": "button"],
            ["text": "target", "role": "control"],
            ["identifier": "second"],
            ["identifier": "TARGET", "text": "ignored"],
        ] {
            TestIcli.injected = []
            let result = try GuestAPI.executeInterface("ui.tap_element", selection)
            expect((result?["element"] as? [String: Any])?["identifier"] as? String == "second", "selector compatibility: \(selection)")
        }

        // MARK: - SpringBoard Frontmost App Recognition Tests
        TestIcli.bundle = "com.apple.springboard"
        TestIcli.springboardPID = 555
        TestIcli.rawFrontmost = [
            "bundle_id": "com.apple.springboard",
            "verified": false,
            "source": "unavailable",
            "runningboard": [
                "reason": "no_focal_app",
                "handles": 16,
                "states": 5
            ]
        ]
        TestIcli.isLocked = false
        TestIcli.isScreenOff = false

        // Unlocked and screen on: SpringBoard recognized as verified foreground app with PID
        let sbFront = frontmostApp()
        expect(sbFront["verified"] as? Bool == true, "SpringBoard verified when unlocked and no focal app")
        expect(sbFront["source"] as? String == "runningboard", "SpringBoard source is runningboard")
        expect(sbFront["bundle_id"] as? String == "com.apple.springboard", "SpringBoard bundle_id matches")
        expect(sbFront["pid"] as? Int == 555, "SpringBoard pid resolved from vp_springboard_pid")

        // Locked state rejection
        TestIcli.isLocked = true
        let lockedFront = frontmostApp()
        expect(lockedFront["verified"] as? Bool == false, "SpringBoard unverified when locked")
        TestIcli.isLocked = false

        // Screen-off rejection
        TestIcli.isScreenOff = true
        let screenOffFront = frontmostApp()
        expect(screenOffFront["verified"] as? Bool == false, "SpringBoard unverified when screen off")
        TestIcli.isScreenOff = false

        // Focal app present
        TestIcli.rawFrontmost = [
            "bundle_id": "com.apple.mobilesafari",
            "verified": true,
            "source": "runningboard"
        ]
        let appFront = frontmostApp()
        expect(appFront["bundle_id"] as? String == "com.apple.mobilesafari", "foreground app preserved")
        expect(appFront["verified"] as? Bool == true, "foreground app verified")

        // Reset to SpringBoard Home Screen
        TestIcli.rawFrontmost = [
            "bundle_id": "com.apple.springboard",
            "verified": false,
            "source": "unavailable",
            "runningboard": [
                "reason": "no_focal_app",
                "handles": 16,
                "states": 5
            ]
        ]

        // ui.tree flat query on SpringBoard
        TestIcli.elements = [
            ["identifier": "Safari", "label": "Safari", "role": "button", "clickable": true, "visible": true,
             "x": 60.0, "y": 80.0, "frame": ["x": 40.0, "y": 60.0, "width": 40.0, "height": 40.0]],
            ["identifier": "Settings", "label": "Settings", "role": "button", "clickable": true, "visible": false,
             "x": 160.0, "y": 80.0, "frame": ["x": 140.0, "y": 60.0, "width": 40.0, "height": 40.0]]
        ]
        let treeResult = try GuestAPI.executeInterface("ui.tree", ["visible_only": false])
        expect(treeResult?["count"] as? Int == 2, "SpringBoard tree returns all elements when visible_only=false")
        expect(treeResult?["pid"] as? Int == 555, "SpringBoard tree query uses SpringBoard PID")

        let visibleTree = try GuestAPI.executeInterface("ui.tree", ["visible_only": true])
        expect(visibleTree?["count"] as? Int == 1, "SpringBoard tree filters visible elements")

        // ui.element_at on SpringBoard
        let elementAtResult = try GuestAPI.executeInterface("ui.element_at", ["x": 60.0, "y": 80.0])
        expect(elementAtResult?["pid"] as? Int == 555, "element_at uses SpringBoard PID")
        expect((elementAtResult?["element"] as? [String: Any])?["identifier"] as? String == "Safari", "element_at returns node")

        // ui.tap_element on SpringBoard (single display fallback)
        TestIcli.display = ["dual_display": false]
        TestIcli.injected = []
        let tapFallback = try GuestAPI.executeInterface("ui.tap_element", ["identifier": "Safari"])
        expect(tapFallback?["tapped"] as? Bool == true, "SpringBoard single-display tap succeeded")
        expect(TestIcli.injected.count == 1, "SpringBoard single-display touch injected")
        print("element tap API: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}

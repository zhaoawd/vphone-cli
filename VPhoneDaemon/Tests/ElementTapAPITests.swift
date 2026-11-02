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
                        expect(TestIcli.injected.count == 1 && abs(actual.0 - nx) < 1e-9 && abs(actual.1 - ny) < 1e-9,
                               "\(name) \(degrees) \(bundle): expected \(nx),\(ny), got \(actual)")
                    }
                }
            }
        }
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
        print("element tap API: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}

import CoreFoundation
import Foundation

@main
enum DisplayMetricsTests {
    static func main() throws {
        // The iPad observation has a usable display configuration while the
        // layout's interface orientation remains unknown. No portrait or
        // coordinate transform may be inferred from these metrics.
        let fixture = #"""
        {"available":true,"geometry_available":false,"reason":"","monitors":[{
          "available":true,"monitor_source":"default_main","geometry_available":false,
          "interface_orientation":0,"display_id":1,"point_scale":2,
          "bounds":{"x":0,"y":0,"width":744,"height":1133},
          "reference_bounds":{"x":0,"y":0,"width":744,"height":1133}
        }]}
        """#
        let layout = try JSONSerialization.jsonObject(with: Data(fixture.utf8)) as! [String: Any]
        let report = GuestDisplayMetrics.report(from: layout)
        precondition(report["available"] as? Bool == true)
        precondition(report["source"] as? String == "frontboard_default_main")
        precondition(report["display_id"] as? Int == 1)
        precondition(report["point_scale"] as? Double == 2)
        precondition((report["bounds"] as? [String: Double])?["width"] == 744)
        precondition((report["reference_bounds"] as? [String: Double])?["height"] == 1133)
        precondition(report["interface_orientation"] == nil && report["geometry_available"] == nil)
        let catalog = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: GuestDuoMethod.catalog()))
            as! [String: Any]
        precondition(catalog["scope"] as? String == "duo_display" && catalog["complete"] as? Bool == false)
        let methods = catalog["methods"] as! [[String: Any]]
        let names = methods.map { $0["name"] as! String }
        precondition(names == Array(Set(names)).sorted())
        func fields(_ name: String, _ kind: String = "result") -> [[String: Any]] {
            methods.first { $0["name"] as? String == name }![kind] as! [[String: Any]]
        }
        func checkMetricSchema(_ report: [String: Any]) {
            let fields = fields("display.metrics")
            let required = fields.filter { $0["required"] as? Bool == true }.map { $0["name"] as! String }
            let declared = fields.map { $0["name"] as! String }
            precondition(Set(required).isSubset(of: report.keys) && Set(report.keys).isSubset(of: declared))
            for field in fields {
                guard let value = report[field["name"] as! String] else { continue }
                switch field["type"] as! String {
                case "boolean": precondition(CFGetTypeID(value as! NSNumber) == CFBooleanGetTypeID())
                case "integer":
                    let number = value as! NSNumber
                    precondition(CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.rounded() == number.doubleValue)
                case "number": precondition(CFGetTypeID(value as! NSNumber) != CFBooleanGetTypeID())
                case "string": precondition(value is String)
                case "object": precondition(value is [String: Any])
                default: preconditionFailure("Unknown metric result type")
                }
            }
        }
        checkMetricSchema(report)
        let degrees = fields("display.orientation").first { $0["name"] as? String == "degrees" }!
        precondition(degrees["required"] as? Bool == true && degrees["nullable"] as? Bool == true && degrees["type"] as? String == "integer")
        let autoLockOptions = fields("display.auto_lock.set", "params")
        precondition(Set(autoLockOptions.map { $0["name"] as! String }) == ["seconds", "never"])
        precondition(autoLockOptions.allSatisfy { $0["required"] as? Bool == false })

        func changingMonitor(_ change: (inout [String: Any]) -> Void) -> [String: Any] {
            var changed = layout
            var monitor = (changed["monitors"] as! [[String: Any]])[0]
            change(&monitor)
            changed["monitors"] = [monitor]
            return changed
        }
        func refuses(_ input: [String: Any]) {
            let answer = GuestDisplayMetrics.report(from: input)
            checkMetricSchema(answer)
            precondition(answer["available"] as? Bool == false)
            precondition(!(answer["reason"] as! String).isEmpty)
            precondition(answer["point_scale"] == nil && answer["display_id"] == nil)
        }

        // Orientation belongs to another contract, including when absent or
        // when the upright and reference bounds differ after a rotation.
        for orientation: Any? in [nil, 1, 4] {
            let input = changingMonitor { $0["interface_orientation"] = orientation }
            precondition(GuestDisplayMetrics.report(from: input)["available"] as? Bool == true)
        }
        let rotated = changingMonitor {
            $0["bounds"] = ["x": 0, "y": 0, "width": 1133, "height": 744]
        }
        precondition(GuestDisplayMetrics.report(from: rotated)["available"] as? Bool == true)

        var missing = layout
        missing["available"] = false
        missing["reason"] = "Owned monitor cleanup failed"
        refuses(missing)
        precondition(GuestDisplayMetrics.report(from: missing)["reason"] as? String == "Owned monitor cleanup failed")
        missing["available"] = 1
        refuses(missing)
        missing["available"] = true
        missing["monitors"] = []
        refuses(missing)
        missing["monitors"] = (layout["monitors"] as! [[String: Any]]) + (layout["monitors"] as! [[String: Any]])
        refuses(missing)
        refuses(changingMonitor { $0["monitor_source"] = "shared_display_type" })
        refuses(changingMonitor { $0["available"] = false })
        refuses(changingMonitor { $0["available"] = 1 })
        for invalid: Any in [true, NSNull(), "2", 0, -1, Double.infinity, Double.nan] {
            refuses(changingMonitor { $0["point_scale"] = invalid })
        }
        for invalid: Any in [true, NSNull(), "1", 0, -1, 1.5, Double(UInt32.max) + 1, Double.infinity] {
            refuses(changingMonitor { $0["display_id"] = invalid })
        }
        for field in ["bounds", "reference_bounds"] {
            refuses(changingMonitor { $0.removeValue(forKey: field) })
            for (key, invalid) in [("x", 1.0), ("y", -1.0), ("width", 0.0), ("height", -1.0),
                                   ("width", Double.infinity), ("height", Double.nan)] {
                refuses(changingMonitor {
                    var rect = $0[field] as! [String: Any]
                    rect[key] = invalid
                    $0[field] = rect
                })
            }
            refuses(changingMonitor {
                var rect = $0[field] as! [String: Any]
                rect["width"] = true
                $0[field] = rect
            })
        }
        // A CADisplay with attractive metrics cannot replace a missing or
        // ambiguous FrontBoard source. It is an independent inventory.
        missing["cadisplays"] = [["displayId": 1, "pointScale": 2]]
        refuses(missing)
        print("Display metrics behavior checks passed")
    }
}

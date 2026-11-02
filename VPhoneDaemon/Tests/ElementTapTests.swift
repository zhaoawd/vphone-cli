import Foundation

@main
enum ElementTapTests {
    static func main() throws {
        var checks = 0
        // Fixed normalized points, with independent upright AX observations.
        for (name, width, height) in [("cover", 466.0, 678.0), ("inner", 669.0, 951.0)] {
            for degrees in [0, 90, 180, 270] {
                let display = try GuestElementTap.Display(name: name, width: width, height: height, degrees: degrees)
                for (nx, ny) in [(0.2, 0.3), (0.7, 0.15), (0.4, 0.8)] {
                    let x: Double, y: Double
                    switch degrees {
                    case 90: (x, y) = ((1 - ny) * height, nx * width)
                    case 180: (x, y) = ((1 - nx) * width, (1 - ny) * height)
                    case 270: (x, y) = (ny * height, (1 - nx) * width)
                    default: (x, y) = (nx * width, ny * height)
                    }
                    let actual = try GuestElementTap.point(x: x, y: y, display: display)
                    precondition(abs(actual.0 - nx) < 1e-9 && abs(actual.1 - ny) < 1e-9,
                                 "\(name) \(degrees): expected \(nx),\(ny); got \(actual)")
                    checks += 1
                }
            }
        }
        for (w, h, degrees) in [(0.0, 678.0, 0), (466.0, Double.nan, 0), (466.0, 678.0, 45)] {
            do {
                _ = try GuestElementTap.Display(name: "invalid", width: w, height: h, degrees: degrees)
                preconditionFailure("invalid display accepted")
            } catch { checks += 1 }
        }
        let display = try GuestElementTap.Display(name: "inner", width: 669, height: 951, degrees: 0)
        for (x, y) in [(-1.0, 10.0), (669.0, 10.0), (10.0, 951.0), (Double.nan, 10.0)] {
            do {
                _ = try GuestElementTap.point(x: x, y: y, display: display)
                preconditionFailure("invalid activation point accepted")
            } catch { checks += 1 }
        }
        print("element tap geometry: \(checks) checks passed")
    }
}

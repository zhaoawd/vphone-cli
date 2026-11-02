import Foundation

/// AX application points belong to the active panel. The shared scanout and
/// icli's screen metrics still belong to Main while Duo shows its inner panel.
enum GuestElementTap {
    struct Display: Equatable {
        let name: String
        let width: Double
        let height: Double
        let degrees: Int

        init(name: String, width: Double, height: Double, degrees: Int) throws {
            guard width.isFinite, height.isFinite, width > 0, height > 0,
                  [0, 90, 180, 270].contains(degrees)
            else { throw Failure.invalidGeometry }
            self.name = name
            self.width = width
            self.height = height
            self.degrees = degrees
        }
    }

    enum Failure: LocalizedError {
        case invalidGeometry, invalidPoint

        var errorDescription: String? {
            switch self {
            case .invalidGeometry: "Active display geometry is unavailable"
            case .invalidPoint: "Element activation point lies outside the active display"
            }
        }
    }

    /// Fixed, normalized digitizer coordinates; no screenshot-size cache.
    static func point(x: Double, y: Double, display: Display, application: Display? = nil) throws -> (Double, Double) {
        let space = application ?? display
        guard space.degrees == display.degrees else { throw Failure.invalidGeometry }
        let fixed = try fixedPoint(x: x, y: y, display: space)
        guard application != nil else { return (fixed.0 / display.width, fixed.1 / display.height) }
        if display.name == "inner" {
            // Duo hosts an older application's canvas at the center of the
            // inner panel, retaining its point size.
            guard space.width <= display.width, space.height <= display.height else { throw Failure.invalidGeometry }
            return ((fixed.0 + (display.width - space.width) / 2) / display.width,
                    (fixed.1 + (display.height - space.height) / 2) / display.height)
        }
        // The cover fits the application's compatibility canvas to its panel.
        let scale = min(display.width / space.width, display.height / space.height)
        return (fixed.0 * scale / display.width, fixed.1 * scale / display.height)
    }

    static func fixedPoint(x: Double, y: Double, display: Display, validate: Bool = true) throws -> (Double, Double) {
        let sideways = display.degrees == 90 || display.degrees == 270
        let width = sideways ? display.height : display.width
        let height = sideways ? display.width : display.height
        guard x.isFinite, y.isFinite,
              !validate || (x >= 0 && y >= 0 && x < width && y < height) else {
            throw Failure.invalidPoint
        }
        switch display.degrees {
        case 90: return (y, display.height - x)
        case 180: return (display.width - x, display.height - y)
        case 270: return (display.width - y, x)
        default: return (x, y)
        }
    }

    static func uprightPoint(x: Double, y: Double, display: Display) -> (Double, Double) {
        switch display.degrees {
        case 90: return (display.height - y, x)
        case 180: return (display.width - x, display.height - y)
        case 270: return (y, display.width - x)
        default: return (x, y)
        }
    }

    /// SpringBoard AX frames were already turned by icli using Main's size.
    static func convert(x: Double, y: Double, display: Display, source: Display?) throws -> (Double, Double) {
        guard let source else { return (x, y) }
        let fixed = try fixedPoint(x: x, y: y, display: source, validate: false)
        return uprightPoint(x: fixed.0, y: fixed.1, display: display)
    }

    static func visible(_ element: [String: Any], display: Display, source: Display?) -> Bool {
        guard let frame = element["frame"] as? [String: Any],
              let x = frame["x"] as? Double, let y = frame["y"] as? Double,
              let w = frame["width"] as? Double, let h = frame["height"] as? Double,
              [x, y, w, h, x + w, y + h].allSatisfy(\.isFinite), w > 0, h > 0,
              let a = try? convert(x: x, y: y, display: display, source: source),
              let b = try? convert(x: x + w, y: y + h, display: display, source: source)
        else { return false }
        let sideways = display.degrees == 90 || display.degrees == 270
        let width = sideways ? display.height : display.width
        let height = sideways ? display.width : display.height
        return min(a.0, b.0) < width && max(a.0, b.0) > 0
            && min(a.1, b.1) < height && max(a.1, b.1) > 0
    }
}

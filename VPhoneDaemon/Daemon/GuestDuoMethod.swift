import Foundation

/// Metadata for the Duo acceptance interface. Keep this separate from request
/// validation: the handlers still own admission and the meaning of each result.
enum GuestDuoMethod: String, CaseIterable {
    case list = "methods.list"
    case layout = "display.layout"
    case metrics = "display.metrics"
    case capture = "display.capture_active"
    case orientation = "display.orientation"
    case rotation = "display.rotation"
    case posture = "display.posture"
    case autoLock = "display.auto_lock"
    case setAutoLock = "display.auto_lock.set"
    case tap = "input.tap"
    case elementAt = "ui.element_at"
    case tapElement = "ui.tap_element"

    enum Kind: String { case string, integer, number, boolean, array, object, any }

    struct Field {
        let name: String
        let type: Kind
        let required: Bool
        let nullable: Bool

        init(_ name: String, _ type: Kind, optional: Bool = false, nullable: Bool = false) {
            self.name = name
            self.type = type
            self.required = !optional
            self.nullable = nullable
        }

        var json: [String: Any] {
            ["name": name, "type": type.rawValue, "required": required,
             "nullable": nullable, "open": type == .object || type == .array]
        }
    }

    var spec: (description: String, params: [Field], result: [Field]) {
        let point: [Field] = [.init("x", .number), .init("y", .number)]
        let autoLock: [Field] = [
            .init("auto_lock_seconds", .integer, nullable: true),
            .init("lock_screen_minimum_seconds", .integer, nullable: true),
            .init("never", .boolean),
        ]
        switch self {
        case .list:
            return ("Describe the RPC methods documented by this Duo build.", [],
                    [.init("methods", .array), .init("scope", .string), .init("complete", .boolean)])
        case .layout:
            return ("Read the FrontBoard layout and CoreAnimation display inventory.", [],
                    [.init("available", .boolean), .init("geometry_available", .boolean), .init("reason", .string),
                     .init("monitors", .array), .init("cadisplays", .array), .init("thread", .object),
                     .init("observation", .object), .init("capability_failures", .object)])
        case .metrics:
            return ("Read the active display point geometry without requiring a known interface orientation.", [],
                    [.init("available", .boolean), .init("source", .string), .init("reason", .string),
                     .init("display_id", .integer, optional: true), .init("bounds", .object, optional: true),
                     .init("reference_bounds", .object, optional: true), .init("point_scale", .number, optional: true)])
        case .capture:
            return ("Capture the active display surface as a PNG, or report why it is unavailable.", [],
                    [.init("available", .boolean), .init("reason", .string, optional: true),
                     .init("state", .string, optional: true), .init("format", .string, optional: true),
                     .init("base64", .string, optional: true), .init("width", .integer, optional: true),
                     .init("height", .integer, optional: true), .init("identity_binding", .string, optional: true),
                     .init("source", .object, optional: true), .init("source_after", .object, optional: true)])
        case .orientation:
            return ("Read the interface orientation and available device pose.", [],
                    [.init("degrees", .integer, nullable: true), .init("source", .string),
                     .init("device_degrees", .integer, optional: true), .init("fold_angle", .number, optional: true),
                     .init("screen_off", .boolean, optional: true)])
        case .rotation:
            return ("Read rotation or request an interface orientation.", [.init("orientation", .string, optional: true)],
                    [.init("degrees", .integer), .init("name", .string), .init("device_orientation", .integer),
                     .init("locked", .boolean), .init("requested", .integer, optional: true),
                     .init("accelerometer", .object, optional: true)])
        case .posture:
            return ("Set the fold pose using a hinge state or a sweep position.",
                    [.init("position", .any, optional: true), .init("hinge", .any, optional: true),
                     .init("duration", .number, optional: true), .init("profile", .string, optional: true),
                     .init("orientation", .any, optional: true), .init("tabletop", .integer, optional: true),
                     .init("angle", .number, optional: true)],
                    [.init("hinge", .integer), .init("orientation", .integer), .init("tabletop", .integer, nullable: true),
                     .init("angle", .number), .init("hinge_hid", .object), .init("source", .string),
                     .init("sweep", .object, optional: true)])
        case .autoLock:
            return ("Read the effective Auto-Lock setting.", [], autoLock)
        case .setAutoLock:
            return ("Set Auto-Lock with seconds or never: true, then read the effective value.",
                    [.init("seconds", .integer, optional: true), .init("never", .boolean, optional: true)],
                    autoLock + [.init("requested_auto_lock_seconds", .integer)])
        case .tap:
            return ("Tap the active display at a point.", point, point)
        case .elementAt:
            return ("Find the accessibility element at a screen point.", point,
                    [.init("element", .object, optional: true), .init("error", .string, optional: true),
                     .init("pid", .integer, optional: true), .init("x", .number, optional: true),
                     .init("y", .number, optional: true),
                     .init("source", .string, optional: true)])
        case .tapElement:
            return ("Tap an accessibility element matched by identifier or text.",
                    [.init("identifier", .string, optional: true), .init("text", .string, optional: true),
                     .init("role", .string, optional: true), .init("match", .string, optional: true),
                     .init("index", .integer, optional: true)],
                    [.init("tapped", .boolean), .init("element", .object)])
        }
    }

    static func catalog() -> [String: Any] {
        let methods: [[String: Any]] = allCases.sorted { $0.rawValue < $1.rawValue }.map {
            let spec = $0.spec
            return ["name": $0.rawValue, "description": spec.description, "force": "never",
                    "params": spec.params.map(\.json), "result": spec.result.map(\.json)]
        }
        return ["scope": "duo_display", "complete": false, "methods": methods]
    }
}

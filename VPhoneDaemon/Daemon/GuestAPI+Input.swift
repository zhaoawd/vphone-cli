import CoreFoundation
import Foundation
import IcliKit
import VphonedNative

// MARK: - Buttons, Text, Gestures

extension GuestAPI {
    /// Gesture coordinates are screen points, as `device.screen` reports them.
    static func executeInput(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "input.button":
            return try pressButton(string(params, "name"))
        case "input.key":
            return try pressKey(string(params, "name"))
        case "input.type":
            return try typeText(string(params, "text"), delayMS: number(params, "delay_ms", default: 30))
        case "input.paste":
            return try pasteText(string(params, "text"))
        case "input.tap":
            return try tap(x: requiredNumber(params, "x"), y: requiredNumber(params, "y"))
        case "input.double_tap":
            return try doubleTap(
                x: requiredNumber(params, "x"),
                y: requiredNumber(params, "y"),
                interval: number(params, "interval", default: 0.1),
            )
        case "input.long_press":
            return try longPress(
                x: requiredNumber(params, "x"),
                y: requiredNumber(params, "y"),
                seconds: number(params, "seconds", default: 1),
            )
        case "input.swipe":
            return try swipe(
                x1: requiredNumber(params, "x1"),
                y1: requiredNumber(params, "y1"),
                x2: requiredNumber(params, "x2"),
                y2: requiredNumber(params, "y2"),
                seconds: number(params, "seconds", default: 0.3),
                steps: (params["steps"] as? NSNumber)?.intValue ?? 20,
            )
        case "input.drag":
            guard let rows = params["points"] as? [[NSNumber]], rows.count >= 2,
                  rows.allSatisfy({ $0.count == 2 })
            else {
                throw GuestAPIError.invalidRequest("points must be at least two [x, y] pairs")
            }
            return try drag(
                points: rows.map { ($0[0].doubleValue, $0[1].doubleValue) },
                seconds: number(params, "seconds", default: 0.5),
                hold: number(params, "hold", default: 0.5),
                steps: (params["steps"] as? NSNumber)?.intValue ?? 20,
            )
        case "input.touch_sequence":
            guard let events = params["events"] as? [[String: Any]] else {
                throw GuestAPIError.invalidRequest("events must be an array of {phase, x, y, delay_ms}")
            }
            let json = try String(decoding: JSONSerialization.data(withJSONObject: events), as: UTF8.self)
            return try touchSequence(
                TouchEvent.list(fromJSON: json),
                normalized: bool(params, "normalized", default: true),
            )
        default:
            return nil
        }
    }

    // MARK: - Accessibility and OCR

    static func executeInterface(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        interfaceLock.lock()
        defer { interfaceLock.unlock() }
        switch method {
        case "ui.tree", "accessibility.tree":
            if let value = params["nested"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw GuestAPIError.invalidRequest("nested must be a boolean")
                }
            }
            if bool(params, "nested") {
                return try nestedHierarchy(params)
            }
            return try uiElements(
                maxElements: (params["max_elements"] as? NSNumber)?.intValue ?? 500,
                visibleOnly: bool(params, "visible_only", default: true),
                clickableOnly: bool(params, "clickable_only"),
                limit: (params["limit"] as? NSNumber)?.intValue,
            )
        case "ui.element_at":
            return try elementAt(x: requiredNumber(params, "x"), y: requiredNumber(params, "y"))
        case "ui.tap_element":
            return try tapInterfaceElement(selector(params))
        case "ui.wait", "ui.wait_gone":
            return try waitForElement(
                selector(params),
                appear: method == "ui.wait",
                timeout: number(params, "timeout", default: 10),
            )
        case "ui.ocr":
            try requireTextRecognition()
            return try recognizeScreen(
                languages: params["languages"] as? [String] ?? ["en-US"],
                minConfidence: Float(number(params, "min_confidence", default: 0.3)),
            )
        case "ui.describe":
            try requireTextRecognition()
            return try describeScreen()
        default:
            return nil
        }
    }

    /// IcliKit's OCR is Vision's, which watchOS does not ship: vphoned links
    /// it weakly, so its classes are nil on a watch.
    private static func requireTextRecognition() throws {
        guard NSClassFromString("VNRecognizeTextRequest") != nil else {
            throw GuestAPIError.operationFailed("Text recognition needs Vision, which this guest does not have")
        }
    }

    private static func selector(_ params: [String: Any]) throws -> ElementSelector {
        try ElementSelector(
            text: optionalString(params, "text"),
            identifier: optionalString(params, "identifier"),
            role: optionalString(params, "role"),
            match: optionalString(params, "match") ?? "contains",
            index: (params["index"] as? NSNumber)?.intValue ?? 0,
        )
    }

    private static func elementTapDisplay() throws -> GuestElementTap.Display? {
        let report = vp_element_tap_display()
        guard report["dual_display"] as? Bool == true else { return nil }
        guard let name = report["name"] as? String,
              let width = report["width"] as? Double, let height = report["height"] as? Double,
              let degrees = interfaceRotationDegrees()
        else {
            throw GuestAPIError.operationFailed(report["error"] as? String ?? "Active display geometry unavailable")
        }
        return try GuestElementTap.Display(name: name, width: width, height: height, degrees: degrees)
    }

    private static func tapInterfaceElement(_ selector: ElementSelector) throws -> [String: Any] {
        guard let before = try elementTapDisplay() else { return try tapElement(selector) }
        let foreground = frontmostApp()
        guard foreground["verified"] as? Bool == true, let bundle = foreground["bundle_id"] as? String else {
            throw GuestAPIError.operationFailed("Cannot verify foreground application before element tap")
        }
        // icli's visible filter uses Main's bounds too. Query unfiltered and
        // test each AX frame against the active panel before selecting a hit.
        let inputScreen = screenInfo()
        let source: GuestElementTap.Display?
        if bundle == "com.apple.springboard" {
            guard let width = inputScreen["width"] as? Double, let height = inputScreen["height"] as? Double,
                  let degrees = (inputScreen["orientation"] as? NSNumber)?.intValue, degrees == before.degrees else {
                throw GuestAPIError.operationFailed("Screen orientation changed before element query; retry")
            }
            let sideways = degrees == 90 || degrees == 270
            source = try GuestElementTap.Display(name: "main", width: sideways ? height : width,
                                                height: sideways ? width : height, degrees: degrees)
        } else { source = nil }
        let query = try uiElements(maxElements: 2000, visibleOnly: false)
        guard query["truncated"] as? Bool != true else {
            throw IcliError.failed("AX query was truncated; narrow the screen before selecting an element")
        }
        let applicationFrame: [String: Any]?
        let application: GuestElementTap.Display?
        let queryPID = (query["pid"] as? NSNumber)?.int32Value ?? 0
        if bundle == "com.apple.springboard" {
            applicationFrame = nil
            application = nil
        } else {
            let frame = vp_element_tap_application_frame(queryPID)
            guard frame["x"] as? Double == 0, frame["y"] as? Double == 0,
                  let width = frame["width"] as? Double, let height = frame["height"] as? Double else {
                throw GuestAPIError.operationFailed("Full application coordinate space unavailable")
            }
            let sideways = before.degrees == 90 || before.degrees == 270
            applicationFrame = frame
            application = try GuestElementTap.Display(name: "application", width: sideways ? height : width,
                height: sideways ? width : height, degrees: before.degrees)
        }
        let hits = (query["elements"] as? [[String: Any]] ?? []).filter {
            matchesInterfaceElement($0, selector) && GuestElementTap.visible($0, display: application ?? before, source: source)
        }
        guard hits.indices.contains(selector.index) else { throw IcliError.failed("element not found") }
        var element = hits[selector.index]
        element["visible"] = true
        guard let x = element["x"] as? Double, let y = element["y"] as? Double else {
            throw IcliError.failed("element has no tap point")
        }
        let after = frontmostApp()
        guard after["verified"] as? Bool == true, after["bundle_id"] as? String == bundle,
              try elementTapDisplay() == before else {
            throw GuestAPIError.operationFailed("Foreground application or display changed during element query; retry")
        }
        if source != nil {
            guard NSDictionary(dictionary: screenInfo()).isEqual(to: inputScreen) else {
                throw GuestAPIError.operationFailed("Screen geometry changed during element query; retry")
            }
        }
        if let applicationFrame,
           !NSDictionary(dictionary: applicationFrame).isEqual(to: vp_element_tap_application_frame(queryPID)) {
            throw GuestAPIError.operationFailed("Application coordinate space changed during element query; retry")
        }
        let upright = try GuestElementTap.convert(x: x, y: y, display: before, source: source)
        _ = try GuestElementTap.fixedPoint(x: upright.0, y: upright.1, display: application ?? before)
        var raw = element
        if let source {
            // Undo icli's Main-based turn. AXElement takes its original
            // window coordinates and applies the actual scene-host context.
            let point = try GuestElementTap.fixedPoint(x: x, y: y, display: source, validate: false)
            let frame = element["frame"] as! [String: Any]
            let a = try GuestElementTap.fixedPoint(x: frame["x"] as! Double, y: frame["y"] as! Double,
                display: source, validate: false)
            let b = try GuestElementTap.fixedPoint(x: (frame["x"] as! Double) + (frame["width"] as! Double),
                y: (frame["y"] as! Double) + (frame["height"] as! Double), display: source, validate: false)
            raw["x"] = point.0; raw["y"] = point.1
            raw["frame"] = ["x": min(a.0, b.0), "y": min(a.1, b.1),
                            "width": abs(a.0 - b.0), "height": abs(a.1 - b.1)]
        }
        let sent = vp_element_tap_in_context(queryPID, raw)
        guard sent["tapped"] as? Bool == true else {
            throw GuestAPIError.operationFailed(sent["error"] as? String ?? "AX context tap failed")
        }
        return ["tapped": true, "element": element]
    }

    /// Preserve ElementSelector.matches from pinned icli 0.10.0. That method
    /// is internal to IcliKit, and its public tap/wait paths filter on Main.
    private static func matchesInterfaceElement(_ element: [String: Any], _ selector: ElementSelector) -> Bool {
        if let role = selector.role {
            if role == "control" {
                if element["clickable"] as? Bool != true { return false }
            } else if role != "element", element["role"] as? String != role { return false }
        }
        if let identifier = selector.identifier {
            return element["identifier"] as? String == identifier || element["label"] as? String == identifier
        }
        guard let text = selector.text else { return false }
        return ["label", "identifier", "value"].contains {
            let value = element[$0] as? String ?? ""
            return selector.match == "exact" ? value.compare(text, options: .caseInsensitive) == .orderedSame
                : value.localizedCaseInsensitiveContains(text)
        }
    }
}

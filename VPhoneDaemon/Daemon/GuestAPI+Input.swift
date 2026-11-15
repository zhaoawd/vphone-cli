import CoreFoundation
import Foundation
import IcliKit
import VphonedNative

// MARK: - Buttons, Text, Gestures

extension GuestAPI {
    // MARK: - Accessibility and OCR

    /// `observed` for `input.*` calls with `observe: true`. `executeInterface` takes `interfaceLock` itself.
    static func liveObservation(
        frontmost: () throws -> [String: Any] = { frontmostApp() },
        tree: () throws -> [String: Any] = { try executeInterface(.uiTree, ["visible_only": true, "max_elements": 500]) },
    ) throws -> [String: Any] {
        try GuestMethodArea.observation(frontmost: frontmost, tree: tree)
    }

    static func executeInterface(_ m: InterfaceMethod, _ params: [String: Any]) throws -> [String: Any] {
        interfaceLock.lock()
        defer { interfaceLock.unlock() }
        switch m {
        case .uiTree, .accessibilityTree:
            if let value = params["nested"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw GuestAPIError.invalidRequest("nested must be a boolean", hint: "true or false")
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
        case .uiElementAt:
            return try elementAt(x: requiredNumber(params, "x"), y: requiredNumber(params, "y"))
        case .uiTapElement:
            return try tapInterfaceElement(selector(params))
        case .uiWait, .uiWaitGone:
            // Checked here so the refusal names timeout_ms in milliseconds;
            // IcliKit's own check speaks in seconds.
            let timeout = number(params, "timeout_ms", default: 10000)
            guard timeout.isFinite, (0 ... 60000).contains(timeout) else {
                throw GuestAPIError.invalidRequest("timeout_ms must be 0–60000")
            }
            return try waitForElement(selector(params), appear: m == .uiWait, timeout: timeout / 1000)
        case .uiOcr:
            try requireTextRecognition()
            return try recognizeScreen(
                languages: params["languages"] as? [String] ?? ["en-US"],
                minConfidence: Float(number(params, "min_confidence", default: 0.3)),
            )
        case .uiDescribe:
            try requireTextRecognition()
            return try describeScreen()
        }
    }

    /// IcliKit's OCR is Vision's, which watchOS does not ship: vphoned links
    /// it weakly, so its classes are nil on a watch.
    private static func requireTextRecognition() throws {
        guard NSClassFromString("VNRecognizeTextRequest") != nil else {
            throw GuestAPIError.unavailable("Text recognition needs Vision, which this guest does not have")
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

    static func uiElements(
        maxElements: Int = 250,
        visibleOnly: Bool = true,
        clickableOnly: Bool = false,
        limit: Int? = nil
    ) throws -> [String: Any] {
        guard (1 ... 2000).contains(maxElements), limit == nil || (limit! > 0 && limit! <= 2000) else {
            throw IcliError.failed("element limits must be between 1 and 2000")
        }
        let foreground = frontmostApp()
        guard foreground["verified"] as? Bool == true,
              let bundle = foreground["bundle_id"] as? String, !bundle.isEmpty
        else {
            throw IcliError.failed("frontmost application could not be verified")
        }
        if bundle == "com.apple.springboard" || bundle == "com.apple.PineBoard" {
            let pid = (foreground["pid"] as? Int) ?? Int(vp_springboard_pid())
            guard pid > 1 else {
                throw IcliError.failed("frontmost app process not found: \(bundle)")
            }
            guard let ptr = vp_ax_elements_json(Int32(pid), Int32(maxElements)) else {
                throw IcliError.failed("AX runtime unavailable")
            }
            var result = try decodeBridgeJSON(takeCString(ptr), "AX response")
            var elements = result["elements"] as? [[String: Any]] ?? []
            if visibleOnly {
                elements = elements.filter { $0["visible"] as? Bool == true }
            }
            if clickableOnly {
                elements = elements.filter { $0["clickable"] as? Bool == true }
            }
            if let limit {
                elements = Array(elements.prefix(limit))
            }
            result["elements"] = elements
            result["count"] = elements.count
            return result
        }
        return try IcliKit.uiElements(
            maxElements: maxElements,
            visibleOnly: visibleOnly,
            clickableOnly: clickableOnly,
            limit: limit
        )
    }

    static func elementAt(x: Double, y: Double) throws -> [String: Any] {
        let foreground = frontmostApp()
        guard foreground["verified"] as? Bool == true,
              let bundle = foreground["bundle_id"] as? String, !bundle.isEmpty
        else {
            throw IcliError.failed("frontmost application could not be verified")
        }
        if let before = try elementTapDisplay() {
            let report = vp_element_tap_display()
            guard let identifier = report["display_id"] as? NSNumber,
                  CFGetTypeID(identifier) != CFBooleanGetTypeID(), identifier.doubleValue > 0,
                  identifier.doubleValue <= Double(UInt32.max), identifier.doubleValue.rounded() == identifier.doubleValue else {
                throw IcliError.failed("Active AX display identity unavailable")
            }
            let pid = try elementHitPID(foreground)
            let result = vp_ax_display_element_at(Int32(pid), identifier.uint32Value, x, y,
                                                 before.width, before.height, Int32(before.degrees))
            if let error = result["error"] as? String { throw IcliError.failed(error) }
            let after = frontmostApp()
            guard before == (try elementTapDisplay()),
                  after["verified"] as? Bool == true, try elementHitPID(after) == pid,
                  after["bundle_id"] as? String == bundle,
                  (vp_element_tap_display()["display_id"] as? NSNumber)?.uint32Value == identifier.uint32Value else {
                throw IcliError.failed("Foreground application or display changed during hit testing; retry")
            }
            return result
        }
        if bundle == "com.apple.springboard" || bundle == "com.apple.PineBoard" {
            let pid = (foreground["pid"] as? Int) ?? Int(vp_springboard_pid())
            guard pid > 1 else {
                throw IcliError.failed("frontmost app process not found: \(bundle)")
            }
            guard x.isFinite, y.isFinite, x >= 0, y >= 0 else {
                throw IcliError.failed("coordinates must be non-negative finite numbers")
            }
            guard let ptr = vp_ax_element_at_json(Int32(pid), x, y) else {
                throw IcliError.failed("AX hit testing unavailable")
            }
            return try decodeBridgeJSON(takeCString(ptr), "AX response")
        }
        return try IcliKit.elementAt(x: x, y: y)
    }

    private static func elementHitPID(_ foreground: [String: Any]) throws -> Int {
        var value = foreground["pid"] as? NSNumber
        if value == nil, let bundle = foreground["bundle_id"] as? String {
            let apps = try runningApps()["apps"] as? [[String: Any]] ?? []
            let matches = apps.filter { $0["bundle_id"] as? String == bundle }
            if matches.count == 1 { value = matches[0]["pid"] as? NSNumber }
        }
        guard let value, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue > 1,
              value.doubleValue <= Double(Int32.max), value.doubleValue.rounded() == value.doubleValue else {
            throw IcliError.failed("The verified foreground application's PID is unavailable")
        }
        return value.intValue
    }

    private static func tapElementFallback(_ selector: ElementSelector) throws -> [String: Any] {
        let foreground = frontmostApp()
        let bundle = foreground["bundle_id"] as? String ?? ""
        if bundle != "com.apple.springboard" && bundle != "com.apple.PineBoard" {
            return try tapElement(selector)
        }
        let result = try uiElements(maxElements: 2000, visibleOnly: true)
        guard result["truncated"] as? Bool != true else {
            throw IcliError.failed("AX query was truncated; narrow the screen before selecting an element")
        }
        let hits = (result["elements"] as? [[String: Any]] ?? []).filter { matchesInterfaceElement($0, selector) }
        guard hits.indices.contains(selector.index) else { throw IcliError.failed("element not found") }
        let hit = hits[selector.index]
        guard let x = hit["x"] as? Double, let y = hit["y"] as? Double else {
            throw IcliError.failed("element has no tap point")
        }
        _ = try tap(x: x, y: y)
        return ["tapped": true, "element": hit]
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
        guard let before = try elementTapDisplay() else { return try tapElementFallback(selector) }
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
        let queryPID = (query["pid"] as? NSNumber)?.int32Value ?? Int32((foreground["pid"] as? Int) ?? 0)
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

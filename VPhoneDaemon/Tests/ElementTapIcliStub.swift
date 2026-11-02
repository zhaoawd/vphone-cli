// Test-only boundary double for compiling the real GuestAPI+Input on macOS.
// The legacy tap reproduces icli 0.10.0's primary-scanout normalization.
import Foundation

public enum IcliError: Error { case failed(String) }
public enum TouchPhase { case down, up }
public struct TouchEvent {
    public let phase: TouchPhase
    public let x: Double, y: Double
    public init(phase: TouchPhase, x: Double, y: Double, delayMS: Double = 0) {
        self.phase = phase; self.x = x; self.y = y
    }
    public static func list(fromJSON: String) throws -> [TouchEvent] { fatalError("unused") }
}
public struct ElementSelector {
    public let text: String?, identifier: String?, role: String?, match: String
    public let index: Int
    public init(text: String?, identifier: String?, role: String?, match: String, index: Int) throws {
        self.text = text; self.identifier = identifier; self.role = role; self.match = match; self.index = index
    }
}
public enum TestIcli {
    nonisolated(unsafe) public static var primary = (466.0, 678.0)
    nonisolated(unsafe) public static var degrees = 0
    nonisolated(unsafe) public static var bundle = "com.autophone.tap-probe"
    nonisolated(unsafe) public static var elements: [[String: Any]] = []
    nonisolated(unsafe) public static var display: [String: Any] = [:]
    nonisolated(unsafe) public static var afterQuery: (() -> Void)?
    nonisolated(unsafe) public static var injected: [(Double, Double)] = []
    nonisolated(unsafe) public static var failInjection = false
    nonisolated(unsafe) public static var truncated = false
}
public func frontmostApp() -> [String: Any] { ["verified": true, "bundle_id": TestIcli.bundle] }
public func interfaceRotationDegrees() -> Int? { TestIcli.degrees }
public func screenInfo() -> [String: Any] {
    let sideways = [90, 270].contains(TestIcli.degrees)
    return ["width": sideways ? TestIcli.primary.1 : TestIcli.primary.0,
            "height": sideways ? TestIcli.primary.0 : TestIcli.primary.1, "orientation": TestIcli.degrees]
}
public func uiElements(maxElements: Int = 250, visibleOnly: Bool = true, clickableOnly: Bool = false,
                       limit: Int? = nil) throws -> [String: Any] {
    TestIcli.afterQuery?()
    return ["elements": TestIcli.elements.filter { !visibleOnly || $0["visible"] as? Bool == true },
            "truncated": TestIcli.truncated]
}
public func waitForElement(_ selector: ElementSelector, appear: Bool, timeout: Double) throws -> [String: Any] {
    // Selection itself belongs to icli; test one exact identifier here.
    let hits = TestIcli.elements.filter { $0["identifier"] as? String == selector.identifier }
    TestIcli.afterQuery?()
    guard hits.indices.contains(selector.index) else { throw IcliError.failed("element wait timed out") }
    return ["element": hits[selector.index]]
}
public func tapElement(_ selector: ElementSelector) throws -> [String: Any] {
    let result = try waitForElement(selector, appear: true, timeout: 0)
    let hit = result["element"] as! [String: Any]
    _ = try tap(x: hit["x"] as! Double, y: hit["y"] as! Double)
    return ["tapped": true, "element": hit]
}
public func tap(x: Double, y: Double) throws -> [String: Any] {
    let (w, h) = TestIcli.primary
    let point: (Double, Double)
    switch TestIcli.degrees {
    case 90: point = (y / w, 1 - x / h)
    case 180: point = (1 - x / w, 1 - y / h)
    case 270: point = (1 - y / w, x / h)
    default: point = (x / w, y / h)
    }
    TestIcli.injected.append(point)
    return ["x": x, "y": y]
}
public func touchSequence(_ events: [TouchEvent], normalized: Bool) throws -> [String: Any] {
    precondition(normalized && events.count == 2)
    precondition(events[0].phase == .down && events[1].phase == .up)
    precondition(events[0].x == events[1].x && events[0].y == events[1].y)
    if TestIcli.failInjection { throw IcliError.failed("hid unavailable") }
    TestIcli.injected.append((events[0].x, events[0].y))
    return [:]
}
public func pressButton(_ name: String) throws -> [String: Any] { fatalError("unused") }
public func pressKey(_ name: String) throws -> [String: Any] { fatalError("unused") }
public func typeText(_ text: String, delayMS: Double) throws -> [String: Any] { fatalError("unused") }
public func pasteText(_ text: String) throws -> [String: Any] { fatalError("unused") }
public func doubleTap(x: Double, y: Double, interval: Double) throws -> [String: Any] { fatalError("unused") }
public func longPress(x: Double, y: Double, seconds: Double) throws -> [String: Any] { fatalError("unused") }
public func swipe(x1: Double, y1: Double, x2: Double, y2: Double, seconds: Double, steps: Int) throws -> [String: Any] { fatalError("unused") }
public func drag(points: [(Double, Double)], seconds: Double, hold: Double, steps: Int) throws -> [String: Any] { fatalError("unused") }
public func elementAt(x: Double, y: Double) throws -> [String: Any] { fatalError("unused") }
public func recognizeScreen(languages: [String], minConfidence: Float) throws -> [String: Any] { fatalError("unused") }
public func describeScreen() throws -> [String: Any] { fatalError("unused") }

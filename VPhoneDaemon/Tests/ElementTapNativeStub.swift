import Foundation
import IcliKit

public func vp_element_tap_display() -> [String: Any] { TestIcli.display }

public func vp_element_tap_application_frame(_ pid: Int32) -> [String: Any] {
    precondition(pid == 123 || pid == Int32(TestIcli.springboardPID))
    let sideways = [90, 270].contains(TestIcli.degrees)
    let width = TestIcli.display["width"] as? Double ?? 466
    let height = TestIcli.display["height"] as? Double ?? 678
    let result = TestIcli.appFrame ?? ["x": 0.0, "y": 0.0,
        "width": sideways ? height : width, "height": sideways ? width : height]
    TestIcli.afterFrameRead?()
    return result
}

public func vp_element_tap_in_context(_ pid: Int32, _ element: [String: Any]) -> [String: Any] {
    precondition(pid == 123 || pid == Int32(TestIcli.springboardPID))
    if TestIcli.failInjection { return ["error": "context tap failed"] }
    TestIcli.injected.append((element["x"] as! Double, element["y"] as! Double))
    return ["tapped": true]
}

public func vp_springboard_pid() -> Int32 { Int32(TestIcli.springboardPID) }

public func vp_ax_elements_json(_ pid: Int32, _ maxElements: Int32) -> UnsafeMutablePointer<CChar>? {
    TestIcli.afterQuery?()
    let dict: [String: Any] = [
        "pid": Int(pid),
        "elements": TestIcli.elements,
        "count": TestIcli.elements.count,
        "truncated": TestIcli.truncated,
        "source": "ax"
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let json = String(data: data, encoding: .utf8)
    else { return nil }
    return strdup(json)
}

public func vp_ax_element_at_json(_ pid: Int32, _ x: Double, _ y: Double) -> UnsafeMutablePointer<CChar>? {
    let dict: [String: Any] = [
        "source": "ax",
        "pid": Int(pid),
        "element": TestIcli.elements.first ?? [:],
        "x": x,
        "y": y
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: dict),
          let json = String(data: data, encoding: .utf8)
    else { return nil }
    return strdup(json)
}

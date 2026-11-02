import IcliKit

public func vp_element_tap_display() -> [String: Any] { TestIcli.display }

public func vp_element_tap_application_frame(_ pid: Int32) -> [String: Any] {
    precondition(pid == 123)
    let sideways = [90, 270].contains(TestIcli.degrees)
    let width = TestIcli.display["width"] as? Double ?? 466
    let height = TestIcli.display["height"] as? Double ?? 678
    let result = TestIcli.appFrame ?? ["x": 0.0, "y": 0.0,
        "width": sideways ? height : width, "height": sideways ? width : height]
    TestIcli.afterFrameRead?()
    return result
}

public func vp_element_tap_in_context(_ pid: Int32, _ element: [String: Any]) -> [String: Any] {
    precondition(pid == 123)
    if TestIcli.failInjection { return ["error": "context tap failed"] }
    TestIcli.injected.append((element["x"] as! Double, element["y"] as! Double))
    return ["tapped": true]
}

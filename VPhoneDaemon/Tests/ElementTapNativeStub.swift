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

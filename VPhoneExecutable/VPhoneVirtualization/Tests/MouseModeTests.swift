import AppKit

@main enum MouseModeTests {
    @MainActor static func main() {
        precondition(ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]?.contains("/.build/mouse-mode-tests/host-home") == true)
        if CommandLine.arguments.contains("--expect-touch") {
            precondition(VPhoneGuestMouseMode.current == .touch, "Touch preference must survive process exit")
            print("Mouse mode preference: persisted Touch read by a new process")
            return
        }
        UserDefaults.standard.removeObject(forKey: "guestMouseMode")
        precondition(VPhoneGuestMouseMode.current == .pointer)
        UserDefaults.standard.set("unknown", forKey: "guestMouseMode")
        precondition(VPhoneGuestMouseMode.current == .pointer)
        let menu = MouseModeProduction()
        menu.mouseModeItems = ["pointer", "touch"].map { mode in
            let item = NSMenuItem(title: mode, action: nil, keyEquivalent: "")
            item.representedObject = mode
            return item
        }
        for mode in [VPhoneGuestMouseMode.pointer, .touch] {
            menu.setGuestMouseMode(menu.mouseModeItems.first { $0.representedObject as? String == mode.rawValue }!)
            precondition(VPhoneGuestMouseMode.current == mode)
            precondition(menu.captureView?.mouseMode == mode)
            for item in menu.mouseModeItems {
                precondition(item.state == (item.representedObject as? String == mode.rawValue ? .on : .off))
            }
        }
        let invalid = NSMenuItem(title: "invalid", action: nil, keyEquivalent: "")
        invalid.representedObject = "invalid"
        menu.setGuestMouseMode(invalid)
        precondition(VPhoneGuestMouseMode.current == .touch && menu.captureView?.mouseMode == .touch)
        var combinations = 0
        // Captured, iPad, capability, expected Pointer mode, expected Touch mode.
        let policyCases = [
            (false, false, false, false, false), (false, false, true, false, false),
            (false, true, false, false, false), (false, true, true, true, false),
            (true, false, false, false, false), (true, false, true, true, true),
            (true, true, false, false, false), (true, true, true, true, true),
        ]
        for (captured, pad, supported, pointer, touch) in policyCases {
            for (mode, expected) in [(VPhoneGuestMouseMode.pointer, pointer), (.touch, touch)] {
                menu.isMouseCaptured = captured; menu.isPadGuest = pad
                menu.control?.supportsPointerScroll = supported; menu.mouseMode = mode
                precondition(menu.usesGuestPointer == expected)
                combinations += 1
            }
        }
        menu.control = nil
        precondition(!menu.usesGuestPointer)
        precondition(UserDefaults.standard.synchronize())
        print("Mouse mode: default/invalid preferences, menu state, view update and \(combinations) pointer-policy combinations passed")
    }
}

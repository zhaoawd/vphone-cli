import AppKit
import Virtualization
import Foundation
func record(_ method: String, _ event: NSEvent) {
    let value: [String: Any] = ["method": method, "keyCode": event.keyCode, "flags": event.modifierFlags.rawValue,
        "command": event.modifierFlags.contains(.command), "control": event.modifierFlags.contains(.control),
        "option": event.modifierFlags.contains(.option), "shift": event.modifierFlags.contains(.shift), "keyWindow": NSApp.keyWindow?.isKeyWindow == true,
        "active": NSApp.isActive, "charactersIsV": event.type == .keyDown && event.charactersIgnoringModifiers == "v"]
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
    let file = try! FileHandle(forWritingTo: URL(fileURLWithPath: "/private/tmp/vphone-b15-key-probe-v2.jsonl"))
    try! file.seekToEnd(); try! file.write(contentsOf: data); try! file.close()
}
@MainActor final class Probe: VZVirtualMachineView {
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { record("equivalent", event); return super.performKeyEquivalent(with: event) }
    override func keyDown(with event: NSEvent) { record("down", event) }
    override func flagsChanged(with event: NSEvent) { record("flags", event) }
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 100,y: 100,width: 400,height: 200),styleMask: [.titled,.closable],backing: .buffered,defer: false)
window.isReleasedWhenClosed = false
window.title = "VPhone B15 Key Probe"
let view = Probe(); view.capturesSystemKeys = true
window.contentView = view
FileManager.default.createFile(atPath: "/private/tmp/vphone-b15-key-probe-v2.jsonl", contents: Data())
window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view); application.activate(ignoringOtherApps: true)
application.run()

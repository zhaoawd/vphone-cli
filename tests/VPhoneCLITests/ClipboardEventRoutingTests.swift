import AppKit
import XCTest
@testable import vphone_cli

@MainActor
final class ClipboardEventRoutingTests: XCTestCase {
    private func event(_ key: String, flags: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 9))
    }

    func testDirectKeyDownRoutesClipboardShortcutsWhenKeyEquivalentIsSkipped() throws {
        let view = VPhoneVirtualMachineView(frame: .zero)
        var requests: [String] = []
        view.onClipboardShortcut = { requests.append($0); return true }
        for key in ["c", "x", "v"] { view.keyDown(with: try event(key)) }
        XCTAssertEqual(requests, ["c", "x", "v"])
    }

    func testAcceptedKeyEquivalentDoesNotNeedKeyDownDelivery() throws {
        let view = VPhoneVirtualMachineView(frame: .zero)
        var requests: [String] = []
        view.onClipboardShortcut = { requests.append($0); return true }
        let paste = try event("v")
        if !view.performKeyEquivalent(with: paste) { view.keyDown(with: paste) }
        XCTAssertEqual(requests, ["v"])
    }

    func testOtherModifiersAndKeysDoNotRequestClipboardSynchronization() throws {
        let view = VPhoneVirtualMachineView(frame: .zero)
        var requests: [String] = []
        view.onClipboardShortcut = { requests.append($0); return true }
        for flags: NSEvent.ModifierFlags in [[], [.command, .shift], [.command, .option], [.command, .control]] {
            view.keyDown(with: try event("v", flags: flags))
        }
        view.keyDown(with: try event("a"))
        XCTAssertEqual(requests, [])
    }
}

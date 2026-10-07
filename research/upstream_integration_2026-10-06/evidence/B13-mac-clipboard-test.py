from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
(r/'tests/VPhoneCLITests/ClipboardMacWriterTests.swift').write_text('''import AppKit
import Foundation
import Testing
@testable import vphone_cli

@MainActor
struct ClipboardMacWriterTests {
    @Test func sameTextReadbackPreservesOriginalRichTextAndMacChangeCount() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("original", forType: .string)
        let rich = Data(#"{\\rtf1\\ansi original}"#.utf8)
        board.setData(rich, forType: .rtf)
        let count = board.changeCount
        VPhoneClipboardMacWriter.write(.init(text: "original", types: [], hasImage: false, changeCount: 8, imageData: nil), to: board)
        #expect(board.changeCount == count)
        #expect(board.data(forType: .rtf) == rich)
    }
}
''')
(r/'sources/vphone-cli/VPhoneClipboardMacWriter.swift').write_text('''import AppKit
@MainActor
enum VPhoneClipboardMacWriter {
    static func write(_ value: VPhoneControl.ClipboardContent, to board: NSPasteboard = .general) {
        if let text = value.text {
            board.clearContents(); board.setString(text, forType: .string)
        } else if let data = value.imageData {
            board.clearContents(); board.setData(data, forType: .png)
        }
    }
}
''')

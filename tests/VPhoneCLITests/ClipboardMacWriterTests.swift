import AppKit
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
        let rich = Data(#"{\rtf1\ansi original}"#.utf8)
        board.setData(rich, forType: .rtf)
        let count = board.changeCount
        VPhoneClipboardMacWriter.write(.init(text: "original", types: [], hasImage: false, changeCount: 8, imageData: nil), to: board)
        #expect(board.changeCount == count)
        #expect(board.data(forType: .rtf) == rich)
    }
}

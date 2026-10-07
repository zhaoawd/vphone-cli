import AppKit
@MainActor
enum VPhoneClipboardMacWriter {
    static func write(_ value: VPhoneControl.ClipboardContent, to board: NSPasteboard = .general) {
        if let text = value.text {
            guard board.string(forType: .string) != text else { return }
            board.clearContents(); board.setString(text, forType: .string)
        } else if let data = value.imageData {
            guard board.data(forType: .png) != data else { return }
            board.clearContents(); board.setData(data, forType: .png)
        }
    }
}

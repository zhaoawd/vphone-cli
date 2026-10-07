from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/vphone-cli/VPhoneVirtualMachineView.swift';s=p.read_text().replace('    var keyHelper: VPhoneKeyHelper?','    var keyHelper: VPhoneKeyHelper?\n    var onClipboardShortcut: ((String) -> Bool)?');s=s.replace('    override func performKeyEquivalent(with event: NSEvent) -> Bool {','''    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
           let key = event.charactersIgnoringModifiers, ["c", "x", "v"].contains(key),
           onClipboardShortcut?(key) == true { return true }''');p.write_text(s)
p=r/'sources/vphone-cli/VPhoneWindowController.swift';s=p.read_text();s='import VPhoneCore\n'+s;s=s.replace('    private var clipboardSync: VPhoneClipboardFocusSync?','    private var clipboardSync: VPhoneClipboardFocusSync?\n    private var shortcutSync: VPhoneClipboardShortcutSync?')
s=s.replace('keyHelper: VPhoneKeyHelper, control: VPhoneControl, ecid: String?','keyHelper: VPhoneKeyHelper, control: VPhoneControl, ecid: String?, inputQueue: VPhoneHostInputQueue = VPhoneHostInputQueue()')
needle='        clipboardSync = sync';assert needle in s
s=s.replace(needle,'''        let shortcuts = VPhoneClipboardShortcutSync(identity: { [weak control] in
            guard let control, let connection = control.clipboardSession else { return nil }
            return .init(connection: connection, revision: control.clipboardRevision)
        }, macCount: { NSPasteboard.general.changeCount }, read: { [weak control] in
            guard let control else { throw CancellationError() }
            return try await control.clipboardGet()
        }, set: { [weak control] value in
            guard let control else { throw CancellationError() }
            if let text = value.text { try await control.clipboardSet(text: text) }
            else if let bytes = value.imageData { try await control.clipboardSet(imageData: bytes, uti: "public.png") }
        }, chord: { [weak control] usage in
            control?.sendHIDDown(page: 0x07, usage: 0xE3)
            control?.sendHIDPress(page: 0x07, usage: usage)
            control?.sendHIDUp(page: 0x07, usage: 0xE3)
        }, write: { value in
            let board = NSPasteboard.general
            board.clearContents()
            if let text = value.text { board.setString(text, forType: .string) }
            else if let data = value.imageData { board.setData(data, forType: .png) }
            sync.clipboardMutated()
        })
        shortcutSync = shortcuts
        clipboardSync = sync''',1)
s=s.replace('        view.control = control','''        view.control = control
        view.onClipboardShortcut = { [weak self, weak control, weak shortcuts] key in
            guard let self, self.windowController?.window?.isKeyWindow == true,
                  let control, control.clipboardSession != nil, let shortcuts else { return false }
            let connection = control.clipboardSession
            let mac = NSPasteboard.general.changeCount
            let payload = key == "v" ? Self.macClipboardPayload() : nil
            if key == "v", payload == nil { return true }
            Task { @MainActor [weak self, weak control] in
                await inputQueue.run(cancelled: ()) {
                    guard self?.windowController?.window?.isKeyWindow == true,
                          control?.clipboardSession == connection,
                          NSPasteboard.general.changeCount == mac else { return }
                    if let payload { await shortcuts.paste(payload) }
                    else { await shortcuts.copy(cut: key == "x") }
                }
            }
            return true
        }''',1)
s=s.replace('func windowDidResignKey(_: Notification) { clipboardSync?.focusChanged(key: false) }','func windowDidResignKey(_: Notification) { shortcutSync?.invalidate(); clipboardSync?.focusChanged(key: false) }')
s=s.replace('func windowWillClose(_: Notification) { clipboardSync?.stop() }','func windowWillClose(_: Notification) { shortcutSync?.invalidate(); clipboardSync?.stop() }')
pos=s.index('    private nonisolated static let homeItemID');s=s[:pos]+'''    private static func macClipboardPayload() -> VPhoneControl.ClipboardContent? {
        let board = NSPasteboard.general
        guard let kind = VPhoneClipboardTransfer.macKind(types: board.types?.map(\\.rawValue) ?? []) else { return nil }
        switch kind {
        case .text:
            guard let text = board.string(forType: .string), VPhoneClipboardTransfer.fits(text: text) else { return nil }
            return .init(text: text, types: [], hasImage: false, changeCount: nil, imageData: nil)
        case let .image(type):
            guard let data = board.data(forType: .init(type)),
                  let representation = NSBitmapImageRep(data: data),
                  let png = representation.representation(using: .png, properties: [:]),
                  VPhoneClipboardTransfer.fits(image: png) else { return nil }
            return .init(text: nil, types: ["public.png"], hasImage: true, changeCount: nil, imageData: png)
        }
    }

'''+s[pos:];p.write_text(s)
p=r/'sources/vphone-cli/VPhoneAppDelegate.swift';s=p.read_text();s=s.replace('                ecid: vm.ecid','                ecid: vm.ecid, inputQueue: hostInputQueue');p.write_text(s)

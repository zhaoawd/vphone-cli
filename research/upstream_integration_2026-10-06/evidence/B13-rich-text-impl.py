from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/vphone-cli/VPhoneClipboardMacWriter.swift';s=p.read_text().replace('        if let text = value.text {','        if let text = value.text {\n            guard board.string(forType: .string) != text else { return }').replace('        } else if let data = value.imageData {','        } else if let data = value.imageData {\n            guard board.data(forType: .png) != data else { return }');p.write_text(s)
p=r/'sources/vphone-cli/VPhoneWindowController.swift';s=p.read_text();a='''            let board = NSPasteboard.general
            if let text = content.text, !text.isEmpty {
                board.clearContents()
                board.setString(text, forType: .string)
            } else if let data = content.imageData {
                board.clearContents()
                board.setData(data, forType: .png)
            }''';assert a in s;s=s.replace(a,'            VPhoneClipboardMacWriter.write(content)',1)
a='''            let board = NSPasteboard.general
            board.clearContents()
            if let text = value.text { board.setString(text, forType: .string) }
            else if let data = value.imageData { board.setData(data, forType: .png) }''';assert a in s;s=s.replace(a,'            VPhoneClipboardMacWriter.write(value)',1).replace('if key == "v", payload == nil { return true }','if key == "v", payload == nil { return false }');p.write_text(s)
p=r/'tests/VPhoneCLITests/ClipboardShortcutTests.swift';s=p.read_text();i=s.rindex('\n}');s=s[:i]+'''
    @Test func oldGuestWithoutCountStillReceivesCopyKeyWithoutOverwritingMac() async {
        var chords = 0, writes = 0
        let coordinator = VPhoneClipboardShortcutSync(identity: { .init(connection: 1, revision: 0) }, macCount: { 10 },
            read: { .init(text: "old", types: [], hasImage: false, changeCount: nil, imageData: nil) },
            set: { _ in }, chord: { _ in chords += 1 }, write: { _ in writes += 1 })
        await coordinator.copy(cut: false)
        #expect(chords == 1)
        #expect(writes == 0)
    }
'''+s[i:];p.write_text(s)

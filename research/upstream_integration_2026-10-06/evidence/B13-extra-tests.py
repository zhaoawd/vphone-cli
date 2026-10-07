from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'tests/VPhoneCLITests/ClipboardShortcutTests.swift';s=p.read_text();i=s.rindex('\n}');s=s[:i]+'''
    @Test func successfulPasteSendsExactlyOneChordAfterOwnClipboardRevision() async {
        var identity = VPhoneClipboardFocusSync.Identity(connection: 1, revision: 0)
        var chords: [UInt32] = []
        let coordinator = VPhoneClipboardShortcutSync(identity: { identity }, macCount: { 10 },
            read: { .init(text: nil, types: [], hasImage: false, changeCount: 1, imageData: nil) },
            set: { _ in identity = .init(connection: 1, revision: 1) },
            chord: { chords.append($0) }, write: { _ in })
        await coordinator.paste(.init(text: "mac", types: [], hasImage: false, changeCount: nil, imageData: nil))
        #expect(chords == [0x19])
    }

    @Test func macChangeDuringCopyDoesNotWriteGuestPlainText() async {
        var mac = 10, count = 5, writes = 0
        let coordinator = VPhoneClipboardShortcutSync(identity: { .init(connection: 1, revision: 0) }, macCount: { mac },
            read: { .init(text: "guest", types: [], hasImage: false, changeCount: count, imageData: nil) },
            set: { _ in }, chord: { _ in count += 1; mac += 1 }, write: { _ in writes += 1 })
        await coordinator.copy(cut: false)
        #expect(writes == 0)
    }
'''+s[i:];p.write_text(s)
p=r/'tests/VPhoneCLITests/StartupUnlockCLITests.swift';s=p.read_text();i=s.rindex('\n}');s=s[:i]+'''
    @Test func configOptionIsExplicitAndLaunchForwardingKeepsAPIListener() throws {
        #expect(try VPhoneVMConfigCommand.parse(["vm", "--startup-unlock", "off"]).startupUnlock?.enabled == false)
        let launch = try VPhoneVMLaunchCommand.parse(["vm", "--api-listen", "127.0.0.1:0"])
        #expect(launch.apiProxyArguments() == ["--api-listen", "127.0.0.1:0"])
    }
'''+s[i:];p.write_text(s)
p=r/'tests/VPhoneLaunchpadKitTests/BindingPersistenceTests.swift';s=p.read_text();i=s.rindex('\n}');s=s[:i]+'''
    @Test func cloneRenameAndExportPreserveAllRecordedOrigins() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let bundle = try LaunchpadReports.writeBundle(named: "vm", in: temp.url)
        let library = VPhoneLibrary(root: temp.url)
        let binding = try VPhoneLaunchpadMachineBinding(bundle: "2.6.1", guestEnvironment: "2.5.9", kernel: "2.6.0", bootChain: "2.2.3")
        let bytes = try JSONEncoder().encode(binding)
        try bytes.write(to: bundle.url.appendingPathComponent("launchpad.json"))
        let cloned = try VPhoneBundleOps.clone(bundleNamed: "vm", to: "copy", in: library)
        #expect(try Data(contentsOf: cloned.url.appendingPathComponent("launchpad.json")) == bytes)
        let renamed = try VPhoneBundleOps.rename(bundleNamed: "copy", to: "renamed", in: library)
        #expect(try Data(contentsOf: renamed.url.appendingPathComponent("launchpad.json")) == bytes)
        let archive = temp.url.appendingPathComponent("export.tar.zst")
        _ = try VPhoneBundleOps.export(bundleNamed: "renamed", to: archive, includeIPSW: false, in: library)
        let imported = try VPhoneBundleOps.importArchive(from: archive, name: "imported", in: library)
        #expect(try Data(contentsOf: imported.url.appendingPathComponent("launchpad.json")) == bytes)
    }
'''+s[i:];p.write_text(s)

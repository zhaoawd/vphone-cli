from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'tests/VPhoneCLITests/StartupUnlockCLITests.swift';s=p.read_text();i=s.rindex('\n}');s=s[:i]+'''
    @Test func boundHostExecutionDoesNotOfferPackagedDaemonForAutoUpdate() throws {
        let plain = try VPhoneBootCLI.parse(["--config", "/tmp/config.plist"])
        #expect(plain.autoUpdateGuestBinaryURL != nil)
        let bound = try VPhoneBootCLI.parse(["--config", "/tmp/config.plist", "--binding-sha256", String(repeating: "a", count: 64)])
        #expect(bound.autoUpdateGuestBinaryURL == nil)
    }
'''+s[i:];p.write_text(s)
p=r/'sources/vphone-cli/VPhoneCLI.swift';s=p.read_text().replace('    var guestBinaryURL: URL {','    var autoUpdateGuestBinaryURL: URL? { guestBinaryURL }\n\n    var guestBinaryURL: URL {',1);p.write_text(s)

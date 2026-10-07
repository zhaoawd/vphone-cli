from pathlib import Path
root=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=root/'tests/VPhoneCoreTests/ManifestTests.swift'
s=p.read_text(); pos=s.index('    @Test func missingKeyboard')
s=s[:pos]+'''    @Test func startupUnlockChoiceSurvivesUnrelatedManifestEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("config.plist")
        for enabled in [false, true] {
            try sampleManifest().write(to: url)
            var fields = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            fields["unlockAtStartup"] = enabled
            try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0).write(to: url)
            let loaded = try VPhoneVirtualMachineManifest.load(from: url)
            try loaded.updating(cpuCount: 4).write(to: url)
            let saved = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            #expect(saved["unlockAtStartup"] as? Bool == enabled)
        }
    }

'''+s[pos:];p.write_text(s)

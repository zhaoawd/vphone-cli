from pathlib import Path
p=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli/tests/VPhoneCoreTests/CreateResourceSnapshotTests.swift')
s=p.read_text().replace('    @Test func romChangesRequireExplicitResumeAcceptanceAndRetainEarlierOrigins() throws {','    @Test(arguments: [false, true])\n    func romChangesRequireExplicitResumeAcceptanceAndRetainEarlierOrigins(sep: Bool) throws {',1)
start=s.index('    func romChangesRequireExplicitResumeAcceptanceAndRetainEarlierOrigins')
at=s.index('        try Data("rom-B".utf8).write(to: f.rom)',start)
s=s[:at]+s[at:].replace('        try Data("rom-B".utf8).write(to: f.rom)','        try Data("rom-B".utf8).write(to: sep ? f.seprom : f.rom)',1)
s=s.replace('    @Test func snapshotMutationDuringFinalStageCannotBeAccepted() throws {','    @Test(arguments: ["script", "rom", "seprom"])\n    func snapshotMutationDuringFinalStageCannotBeAccepted(input: String) throws {',1)
s=s.replace('''            if stage == .verification { try Data("changed during final stage".utf8).write(to: snapshot.resources.fwPrepareScript) }''','''            if stage == .verification {
                let file = input == "rom" ? snapshot.romSource : input == "seprom" ? snapshot.sepromSource : snapshot.resources.fwPrepareScript
                try Data("changed during final stage".utf8).write(to: file)
            }''',1)
at=s.index('    @Test func redirectedROMAfterInventoryIsRefused()')
s=s[:at]+'''    @Test func romSymlinkIsMaterializedAndLaterTargetChangesAreIsolated() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = f.root.appendingPathComponent("linked-rom-input")
        try Data("rom-A".utf8).write(to: original)
        try FileManager.default.removeItem(at: f.rom)
        try FileManager.default.createSymbolicLink(at: f.rom, withDestinationURL: original)
        let snapshot = try f.capture()
        try Data("rom-B".utf8).write(to: original)
        var info = stat()
        #expect(lstat(snapshot.romSource.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG)
        #expect(try String(contentsOf: snapshot.romSource, encoding: .utf8) == "rom-A")
    }

''' +s[at:]
p.write_text(s)

from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'tests/VPhoneCoreTests/VMStopTests.swift';s=p.read_text();i=s.index('    @Test func reportsNotRunningWhenNothingHoldsTheLock()')
s=s[:i]+'''
    @Test func unlockedBundleWithOpenDiskCannotReportStoppedAndHolderIsNeverSignalled() throws {
        let fixture = try StopFixture()
        defer { fixture.terminateAll() }
        let holder = try fixture.spawnPlain("exec 3<>'\\(fixture.diskURL.path)'")
        let stop = VPhoneVMStopper(bundleDirectory: fixture.bundle, configURL: fixture.configURL, diskURL: fixture.diskURL)
        let outcome = stop.stop(timeout: 0, force: false)
        #expect(outcome.exitCode != 0)
        #expect(StopFixture.isRunning(holder.processIdentifier))
    }

    @Test func exitedTargetAndReleasedLockStillRequireDiskRelease() {
        let pid: pid_t = 424246
        let target = VPhoneProcessIdentity(pid: pid, startedAt: 4000, uid: 0)
        var running = true
        let stop = VPhoneVMStopper(listTargets: { running ? [pid] : [] }, identity: { _ in running ? target : nil },
            send: { _, _ in running = false; return 0 }, lockHeld: { running }, sleep: { _ in }, diskHolders: { [424247] })
        #expect(stop.stop(timeout: 0, force: true).exitCode != 0)
    }

''' +s[i:];p.write_text(s)
p=r/'tests/VPhoneLaunchpadKitTests/BindingPersistenceTests.swift';s=p.read_text();i=s.rfind('\n}')
s=s[:i]+'''
    @Test func legacyBindingRefusesOpenDiskBeforeBackupOrPublication() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let bundle = try LaunchpadReports.writeBundle(named: "vm", in: temp.url)
        let disk = bundle.url.appendingPathComponent(bundle.manifest.diskImage)
        try Data("disk in use".utf8).write(to: disk)
        let held = try FileHandle(forReadingFrom: disk)
        defer { try? held.close() }
        let backup = temp.url.appendingPathComponent("backup")
        #expect(throws: (any Error).self) { try VPhoneMachineBinding.persistHost("2.6.1", machine: bundle.url, expected: nil, firstMigrationBackup: backup) }
        #expect(!FileManager.default.fileExists(atPath: backup.path))
        #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("launchpad.json").path))
        withExtendedLifetime(held) {}
    }
''' +s[i:];p.write_text(s)

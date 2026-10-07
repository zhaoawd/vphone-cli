from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/VPhoneCore/VPhoneLaunchLayout.swift';s=p.read_text();a='public enum VPhoneLsof {';b='''public enum VPhoneLsof {
    /// A failed inspection is not evidence that a file is unused.
    public static func holders(of file: URL) throws -> [Int32] {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw NSError(domain: "VPhoneFileUse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot inspect missing VM disk: \\(file.path)"])
        }
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/sbin/lsof"),
            ["-nP", "-t", "--", file.path], timeout: 5)
        let holders = parsePIDs(result.stdout)
        guard !result.timedOut, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (result.exitCode == 0 && !holders.isEmpty) || (result.exitCode == 1 && result.stdout.isEmpty) else {
            throw NSError(domain: "VPhoneFileUse", code: 2, userInfo: [NSLocalizedDescriptionKey: "VM disk holder inspection failed (exit \\(result.exitCode)): \\(result.stderr)"])
        }
        return holders
    }
''';assert a in s;s=s.replace(a,b,1);p.write_text(s)
p=r/'sources/VPhoneCore/VPhoneVMStopper.swift';s=p.read_text()
s=s.replace('reports `.stopped`.','and the disk has no remaining holders before it reports `.stopped`.')
s=s.replace('/// Nothing holds the bundle lock.','/// Nothing holds the bundle lock or disk image.')
s=s.replace('/// Every target is gone and the bundle lock is released.','/// Every target is gone, the bundle lock is released and the disk is unused.')
s=s.replace('/// PIDs holding the disk image open. Diagnosis only — never signalled.','/// PIDs holding the disk image open. Holders are never signalled; inspection failure refuses completion.')
s=s.replace('public var diskHolders: () -> [pid_t]','public var diskHolders: () throws -> [pid_t]')
s=s.replace('diskHolders: @escaping () -> [pid_t] = { [] }','diskHolders: @escaping () throws -> [pid_t] = { [] }')
a='''            diskHolders: {
                guard FileManager.default.fileExists(atPath: diskURL.path),
                      let lsof = try? VPhoneProcessRunner.runCapturing(
                          URL(fileURLWithPath: "/usr/sbin/lsof"), ["-t", "--", diskURL.path])
                else { return [] }
                return VPhoneLsof.parsePIDs(lsof.stdout)
            },''';assert a in s;s=s.replace(a,'            diskHolders: { try VPhoneLsof.holders(of: diskURL) },',1)
s=s.replace('        guard lockHeld() else { return .notRunning }','''        guard lockHeld() else {
            do {
                let holders = try diskHolders()
                return holders.isEmpty ? .notRunning : .failed(survivors: [], reason: "VM disk is still open in \\(holders.map(String.init).joined(separator: ", ")); no holder was signalled")
            } catch { return .failed(survivors: [], reason: "VM disk release is unverified: \\(error.localizedDescription)") }
        }''',1)
a='''        while waited < Self.confirmWindow, !survivors(of: snapshot).isEmpty || lockHeld() {
            sleep(Self.confirmPollInterval)
            waited += Self.confirmPollInterval
        }

        let stillAlive = survivors(of: snapshot)
        let stillLocked = lockHeld()
        if stillAlive.isEmpty, !stillLocked {'''
b='''        var holders: [pid_t] = []
        do {
            holders = try diskHolders()
            while waited < Self.confirmWindow, !survivors(of: snapshot).isEmpty || lockHeld() || !holders.isEmpty {
                sleep(Self.confirmPollInterval)
                waited += Self.confirmPollInterval
                holders = try diskHolders()
            }
        } catch { return .failed(survivors: survivors(of: snapshot).map(\\.pid).sorted(), reason: "VM disk release is unverified: \\(error.localizedDescription)") }

        let stillAlive = survivors(of: snapshot)
        let stillLocked = lockHeld()
        if stillAlive.isEmpty, !stillLocked, holders.isEmpty {''';assert a in s;s=s.replace(a,b,1)
s=s.replace('survivors: stillAlive, sendErrors: sendErrors, lockHeld: stillLocked))','survivors: stillAlive, sendErrors: sendErrors, lockHeld: stillLocked)\n                + (holders.isEmpty ? "" : "; VM disk is still open in \\(holders.map(String.init).joined(separator: ", ")); no holder was signalled"))',1)
s=s.replace('        let holders = diskHolders()','        let holders = (try? diskHolders()) ?? []',1)
s=s.replace('/// wired in as `diskHolders` for diagnosis only.','/// inspected through `diskHolders` to confirm release; these PIDs are never signalled.')
p.write_text(s)
p=r/'sources/VPhoneCore/VPhoneMachineBindingPersistence.swift';s=p.read_text();a='''        try VPhoneBundleGuard.withBundleLock(directory: machine, operation: VPhoneVMOperation.bindCoreBundle) { _ in
            let current = try snapshot(machine)''';b='''        try VPhoneBundleGuard.withBundleLock(directory: machine, operation: VPhoneVMOperation.bindCoreBundle) { _ in
            let manifest = try VPhoneVirtualMachineManifest.load(from: machine.appendingPathComponent("config.plist"))
            let holders = try VPhoneLsof.holders(of: machine.appendingPathComponent(manifest.diskImage))
            guard holders.isEmpty else { throw VPhoneMachineBindingError("VM disk is still open; binding and backup were not changed") }
            let current = try snapshot(machine)''';assert a in s;s=s.replace(a,b,1);p.write_text(s)
p=r/'tests/VPhoneLaunchpadKitTests/BindingPersistenceTests.swift';s=p.read_text();a='''        let config = try Data(contentsOf: bundle.configURL)''';s=s.replace(a,'''        try Data("stopped disk".utf8).write(to: bundle.url.appendingPathComponent(bundle.manifest.diskImage))
'''+a,1);a='''        _ = try LaunchpadReports.writeBundle(named: "vm", in: temp.url)''';s=s.replace(a,'''        let bundle = try LaunchpadReports.writeBundle(named: "vm", in: temp.url)
        try Data("stopped disk".utf8).write(to: bundle.url.appendingPathComponent(bundle.manifest.diskImage))''',1);p.write_text(s)
p=r/'tests/VPhoneCoreTests/VMStopTests.swift';s=p.read_text();i=s.index('    @Test func reportsNotRunningWhenNothingHoldsTheLock()');s=s[:i]+'''
    @Test func diskInspectionFailureCannotReportStopped() {
        let stop = VPhoneVMStopper(listTargets: { [] }, lockHeld: { false }, diskHolders: { throw NSError(domain: "inspection", code: 1) })
        #expect(stop.stop(timeout: 0, force: false).exitCode != 0)
    }

''' +s[i:];p.write_text(s)

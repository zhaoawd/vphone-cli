from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli');p=r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadCommandLine.swift';s=p.read_text()
a='''        let entry = recordInHistory ? history.record(Self.display(arguments), warningStatuses: warningStatuses) : nil
        let writer = try recordInHistory ? logsDirectory.map { try VPhoneLaunchpadLogWriter(url: $0.appendingPathComponent("command-\\(UUID().uuidString).log")) } : nil'''
b='''        let writer = try recordInHistory ? logsDirectory.map { try VPhoneLaunchpadLogWriter(url: $0.appendingPathComponent("command-\\(UUID().uuidString).log")) } : nil
        let entry = recordInHistory ? history.record(Self.display(arguments), warningStatuses: warningStatuses) : nil'''
assert a in s;s=s.replace(a,b,1)
a='''        let child = try VPhoneLaunchpadChildProcess(executable: executable, arguments: arguments) { line in
            writer?.write(line)
            collector.append(line)
            onLine?(line)
        }'''
b='''        let child: VPhoneLaunchpadChildProcess
        do {
            child = try VPhoneLaunchpadChildProcess(executable: executable, arguments: arguments) { line in
                writer?.write(line)
                collector.append(line)
                onLine?(line)
            }
        } catch {
            try? await writer?.finish()
            if let entry { history.finish(entry, status: -1, outputDrained: false) }
            throw error
        }'''
assert a in s;s=s.replace(a,b,1);p.write_text(s)
p=r/'sources/VPhoneCore/VPhoneVMRuntimeState.swift';s=p.read_text();a='    public static let stageVphoned = "stage-vphoned"';assert a in s;s=s.replace(a,a+'\n    public static let bindCoreBundle = "bind-core-bundle"',1);p.write_text(s)
p=r/'sources/VPhoneCore/VPhoneMachineBindingPersistence.swift';s=p.read_text();s=s.replace('operation: "bind-core-bundle"','operation: VPhoneVMOperation.bindCoreBundle');p.write_text(s)

from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'tests/VPhoneLaunchpadKitTests/StopRefusalTests.swift'
p.write_text('''import Darwin
import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
struct StopRefusalTests {
    @Test func failedStopDoesNotInterruptLaunchpadChild() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let pidFile = temp.url.appendingPathComponent("child.pid")
        let script = temp.url.appendingPathComponent("vphone-cli")
        try """
        #!/bin/sh
        case "$2" in
          launch) echo $$ > '\(pidFile.path)'; exec /bin/sleep 30 ;;
          stop) echo 'operation conflict: update owns machine'; exit 3 ;;
          list) echo '[]' ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let history = VPhoneLaunchpadCommandHistory()
        let library = VPhoneLaunchpadMachineLibrary(defaults: InMemoryDefaults(), libraryRoot: temp.url.path,
            logsDirectory: temp.url.appendingPathComponent("logs"),
            runStateReader: VPhoneLaunchpadRunStateReader(readRecord: { _ in nil }, identity: { _ in nil }))
        library.startMonitoring(with: VPhoneLaunchpadCommandLine(executable: script, history: history))
        library.stopMonitoring()
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: temp.url.path, name: "sample")
        library.start(machine)
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        await library.stop(machine)
        try await Task.sleep(for: .milliseconds(350))
        #expect(library.actionError?.detail?.contains("operation conflict") == true)
        #expect(library.state(of: machine).isRunning)
        #expect(kill(pid, 0) == 0)
        #expect(history.entries.first(where: { $0.text.contains("vm launch") })?.status == nil)
        #expect(library.activities[machine] == nil)
    }
}
''')

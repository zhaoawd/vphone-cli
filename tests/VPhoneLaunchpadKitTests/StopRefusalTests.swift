import Darwin
import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
struct StopRefusalTests {
    @Test func failedStopDoesNotInterruptLaunchpadChild() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let pidFile = temp.url.appendingPathComponent("child.pid")
        let ready = temp.url.appendingPathComponent("ready")
        let release = temp.url.appendingPathComponent("release")
        let probe = temp.url.appendingPathComponent("probe")
        let acknowledgement = temp.url.appendingPathComponent("acknowledgement")
        let interrupted = temp.url.appendingPathComponent("interrupted")
        defer { try? Data().write(to: release) }
        let script = temp.url.appendingPathComponent("vphone-cli")
        try """
        #!/bin/sh
        case "$2" in
          launch)
            trap 'echo SIGINT > "\(interrupted.path)"; exit 130' INT
            echo $$ > '\(pidFile.path)'
            echo ready > '\(ready.path)'
            while [ ! -e '\(release.path)' ]; do
              if [ -e '\(probe.path)' ]; then echo alive > '\(acknowledgement.path)'; fi
              /bin/sleep 0.01
            done
            exit 0 ;;
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
        let child = try #require(library.launchedProcess(machine))
        // Failure cleanup uses the retained, identity-guarded child handle;
        // a release file alone can disappear with the temporary directory.
        defer { child.interrupt() }
        #expect(await eventually(10) { FileManager.default.fileExists(atPath: ready.path) })
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        await library.stop(machine)
        try Data().write(to: probe)
        #expect(await eventually(10) { FileManager.default.fileExists(atPath: acknowledgement.path) },
                "Launch child did not acknowledge a request after the refused stop; history: \(history.entries)")
        #expect(library.actionError?.detail?.contains("operation conflict") == true)
        #expect(library.state(of: machine).isRunning)
        #expect(kill(pid, 0) == 0)
        #expect(history.entries.first(where: { $0.text.contains("vm launch") })?.status == nil)
        #expect(library.activities[machine] == nil)
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
        try Data().write(to: release)
        try #require(await eventually(10) { !child.isRunning },
                     "Released launch fixture did not finish; history: \(history.entries)")
        let completion = await child.waitForCompletion()
        #expect(completion.status == 0)
        #expect(completion.outputDrained)
        #expect(!FileManager.default.fileExists(atPath: interrupted.path))
    }
}

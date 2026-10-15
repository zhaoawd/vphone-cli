import Darwin
import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
struct CommandTerminationTests {
    @Test func terminationPhasesRejectUnbegunWaitAndDuplicateBegin() async throws {
        let history = VPhoneLaunchpadCommandHistory()
        let command = VPhoneLaunchpadCommandLine(executable: URL(fileURLWithPath: "/usr/bin/true"), history: history)
        #expect(await command.waitForTermination(timeout: .zero) == .timedOut)
        #expect(try await command.run([]).succeeded)
        #expect(command.beginTermination())
        #expect(!command.beginTermination())
        #expect(await command.waitForTermination(timeout: .zero) == .drained)
        #expect(!command.beginTermination())
        #expect(await command.waitForTermination(timeout: .zero) == .timedOut)
        await #expect(throws: VPhoneLaunchpadError.self) { try await command.run([]) }
        #expect(history.entries.count == 1)
    }

    @Test func terminationWaitsForOrdinaryPanicTailAndClosedLog() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let script = temp.url.appendingPathComponent("interrupt-writer")
        let cleanup = temp.url.appendingPathComponent("release-fixture")
        defer { try? Data().write(to: cleanup) }
        try """
        #!/bin/sh
        trap 'printf "kernel panic: ordinary interrupted tail"; exit 130' INT
        i=0; while [ "$i" -lt 10000 ]; do printf 'line:%s\\n' "$i"; i=$((i + 1)); done
        printf 'ready\\n'
        # Only a failed test releases this path, without the expected panic tail.
        while [ ! -e '\(cleanup.path)' ] && [ -d '\(temp.url.path)' ]; do /bin/sleep 0.02; done
        exit 124
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let history = VPhoneLaunchpadCommandHistory()
        let logs = temp.url.appendingPathComponent("logs")
        let command = VPhoneLaunchpadCommandLine(executable: script, history: history, logsDirectory: logs)
        let lines = LaunchpadLines()
        let run = Task { try await command.run([]) { lines.append($0) } }
        #expect(await eventually(5) { lines.all.last == "ready" })
        #expect(command.hasActiveCommands)
        let termination = await command.prepareForTermination()
        #expect(termination == .drained)
        #expect(!command.hasActiveCommands)
        if termination != .drained { try Data().write(to: cleanup) }
        let result = try await run.value
        #expect(result.status == 130)
        #expect(result.outputDrained)
        #expect(result.lines.last == "kernel panic: ordinary interrupted tail")
        #expect(history.entries.first?.outputDrained == true)
        let log = try #require(FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).first)
        let persisted = try String(contentsOf: log, encoding: .utf8)
        let expected = (0..<10000).map { "line:\($0)" } + ["ready", "kernel panic: ordinary interrupted tail"]
        #expect(persisted == expected.joined(separator: "\n") + "\n")
        let openFiles = try LaunchpadProcess.run("/usr/sbin/lsof", ["-n", "-P", "-p", String(getpid()), "-F", "n"])
        #expect(openFiles.status == 0)
        let logPaths = Set(["n" + log.path, "n" + log.resolvingSymlinksInPath().path])
        #expect(!openFiles.output.split(separator: "\n").contains { logPaths.contains(String($0)) })
        // The command gate stays closed until the app exits after a drain.
        await #expect(throws: VPhoneLaunchpadError.self) { try await command.run([]) }
    }

    @Test func escapedPipeWriterTimesOutWithoutLosingTailAndReopensCommandGate() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let source = temp.url.appendingPathComponent("escaped-writer.c")
        let executable = temp.url.appendingPathComponent("escaped-writer")
        let release = temp.url.appendingPathComponent("release")
        let quickStarted = temp.url.appendingPathComponent("quick-started")
        defer { try? Data().write(to: release) }
        // The parent exits 0. Its descendant leaves the parent's process
        // group but retains stdout. Pipe EOF, not group absence, is required.
        try """
        #include <unistd.h>
        #include <signal.h>
        #include <stdio.h>
        #include <string.h>
        int main(int argc, char **argv) {
          if (!strcmp(argv[1], "quick")) {
            FILE *started = fopen(argv[2], "w");
            if (!started) return 90;
            fclose(started); puts("quick"); return 0;
          }
          if (fork() != 0) return 0;
          setsid(); signal(SIGINT, SIG_IGN);
          puts("escaped ready"); fflush(stdout);
          while (access(argv[1], F_OK) != 0) usleep(10000);
          printf("kernel panic: escaped final tail");
          return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiled = try LaunchpadProcess.run("/usr/bin/clang", [source.path, "-o", executable.path])
        try #require(compiled.status == 0, "\(compiled.output)")
        let logs = temp.url.appendingPathComponent("logs")
        let history = VPhoneLaunchpadCommandHistory()
        let command = VPhoneLaunchpadCommandLine(executable: executable, history: history, logsDirectory: logs)
        let lines = LaunchpadLines()
        let run = Task { try await command.run([release.path]) { lines.append($0) } }
        #expect(await eventually { lines.all == ["escaped ready"] })
        let clock = ContinuousClock()
        let start = clock.now
        // Closing the gate is synchronous. The timeout begins only when
        // waiting starts, so this assertion never races a 150ms deadline.
        #expect(command.beginTermination())
        #expect(!command.beginTermination())
        let entryCount = history.entries.count
        await #expect(throws: VPhoneLaunchpadError.self) { try await command.run(["quick", quickStarted.path]) }
        #expect(history.entries.count == entryCount)
        #expect(!FileManager.default.fileExists(atPath: quickStarted.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: logs.path).count == 1)
        #expect(await command.waitForTermination(timeout: .milliseconds(150)) == .timedOut)
        #expect(start.duration(to: clock.now) < .seconds(2))
        #expect(command.hasActiveCommands)
        #expect(history.entries.first?.outcome == .running)
        #expect(history.entries.first?.outputDrained == nil)
        #expect(await command.waitForTermination(timeout: .zero) == .timedOut)
        let quick = try await command.run(["quick", quickStarted.path])
        #expect(quick.succeeded)
        #expect(quick.lines == ["quick"])
        #expect(FileManager.default.fileExists(atPath: quickStarted.path))
        try Data().write(to: release)
        let result = try await run.value
        #expect(result.succeeded)
        #expect(result.lines == ["escaped ready", "kernel panic: escaped final tail"])
        #expect(!command.hasActiveCommands)
        let files = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        let persisted = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        #expect(Set(persisted) == ["quick\n", "escaped ready\nkernel panic: escaped final tail\n"])
    }

    @Test func quitDecisionDefersWhileOrdinaryCommandStillOwnsOutput() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let script = temp.url.appendingPathComponent("writer")
        let release = temp.url.appendingPathComponent("release")
        defer { try? Data().write(to: release) }
        try """
        #!/bin/sh
        if [ "$1" = vm ]; then printf '[]\\n'; exit 0; fi
        printf 'ready\\n'
        while [ ! -e "$1" ]; do /bin/sleep 0.02; done
        printf 'kernel panic: ordinary final tail'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let history = VPhoneLaunchpadCommandHistory()
        let logs = temp.url.appendingPathComponent("logs")
        let command = VPhoneLaunchpadCommandLine(executable: script, history: history, logsDirectory: logs)
        let library = VPhoneLaunchpadMachineLibrary(defaults: InMemoryDefaults(), libraryRoot: temp.url.path)
        library.startMonitoring(with: command)
        defer { library.stopMonitoring() }
        let lines = LaunchpadLines()
        let run = Task { try await command.run([release.path]) { lines.append($0) } }
        #expect(await eventually { lines.all == ["ready"] })
        #expect(history.entries.first?.outcome == .running)
        // Returning quit here lets AppKit exit before the pipe and writer drain.
        #expect(VPhoneLaunchpadQuit.decision(library) != .quit)
        try Data().write(to: release)
        let result = try await run.value
        #expect(result.succeeded)
        #expect(result.lines == ["ready", "kernel panic: ordinary final tail"])
        let log = try #require(FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil).first)
        #expect(try String(contentsOf: log, encoding: .utf8) == "ready\nkernel panic: ordinary final tail\n")
    }
}

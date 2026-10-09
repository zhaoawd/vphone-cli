import Darwin
import CryptoKit
import Foundation
import Testing
@testable import VPhoneLaunchpadKit

/// Production reader/sink paths with controlled child output. These tests
/// do not launch the application UI, download firmware, or boot a VM.
@MainActor
struct ConsoleLifecycleTests {
    @Test func productionConsolePipelineThroughput() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let input = temp.url.appendingPathComponent("throughput-input")
        let logs = temp.url.appendingPathComponent("logs")
        let expected = (0..<100_000).map { "throughput:\($0):" + String(repeating: "x", count: 100) }
            + ["kernel panic: throughput final tail"]
        let expectedData = Data((expected.joined(separator: "\n") + "\n").utf8)
        let source = Data((expected.dropLast().map { "\u{1B}[32m\($0)\u{1B}[0m\r\n" }.joined()
            + "\u{1B}[31m\(expected.last!)\u{1B}[0m").utf8)
        try source.write(to: input)
        let history = VPhoneLaunchpadCommandHistory()
        let command = VPhoneLaunchpadCommandLine(executable: URL(fileURLWithPath: "/bin/cat"), history: history, logsDirectory: logs)
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await command.run([input.path])
        let duration = started.duration(to: clock.now)
        let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let files = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let persisted = try Data(contentsOf: #require(files.first))
        let digest = SHA256.hash(data: persisted).map { String(format: "%02x", $0) }.joined()
        let expectedDigest = SHA256.hash(data: expectedData).map { String(format: "%02x", $0) }.joined()
        #expect(result.succeeded)
        #expect(result.lines.count == 4000)
        #expect(result.omittedLineCount == expected.count - 4000)
        #expect(result.lines.last == expected.last)
        #expect(VPhoneLaunchpadConsoleLog.isPanic(try #require(result.lines.last)))
        #expect(persisted.count == expectedData.count)
        #expect(digest == expectedDigest)
        #expect(history.entries.first?.outputDrained == true)
        let report: [String: Any] = [
            "scope": "production CommandLine/LineReader/LogWriter with cat input fixture; no VM or UI rendering",
            "input_bytes": source.count, "persisted_bytes": persisted.count, "lines": expected.count,
            "seconds_including_spawn_read_and_writer_finish": elapsed,
            "input_bytes_per_second": Double(source.count) / elapsed,
            "persisted_bytes_per_second": Double(persisted.count) / elapsed,
            "lines_per_second": Double(expected.count) / elapsed,
            "display_lines": result.lines.count, "omitted_display_lines": result.omittedLineCount,
            "persisted_sha256": digest, "final_tail": result.lines.last ?? "",
            "output_drained": result.outputDrained,
        ]
        print("T46_THROUGHPUT " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    }

    @Test func concurrentCommandsPersistNormalizedPanicTailsInSeparateLogs() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let script = temp.url.appendingPathComponent("console-output")
        try """
        #!/bin/sh
        i=0
        while [ "$i" -lt 5000 ]; do
            printf '\\033[32m%s:%s\\033[0m\\r\\n' "$1" "$i"
            i=$((i + 1))
        done
        printf '\\033[31m%s:kernel panic: final tail\\033[0m' "$1"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let logs = temp.url.appendingPathComponent("logs")
        let history = VPhoneLaunchpadCommandHistory()
        let command = VPhoneLaunchpadCommandLine(executable: script, history: history, logsDirectory: logs)
        async let first = command.run(["alpha"])
        async let second = command.run(["beta"])
        let results = try await [("alpha", first), ("beta", second)]
        let files = try FileManager.default.contentsOfDirectory(at: logs, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        let persisted = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        for (name, result) in results {
            let expected = (0..<5000).map { "\(name):\($0)" } + ["\(name):kernel panic: final tail"]
            #expect(result.succeeded)
            #expect(result.omittedLineCount == 1001)
            #expect(result.lines.last == expected.last)
            #expect(VPhoneLaunchpadConsoleLog.isPanic(try #require(result.lines.last)))
            #expect(persisted.filter { $0 == expected.joined(separator: "\n") + "\n" }.count == 1)
        }
        #expect(history.entries.count == 2)
        #expect(history.entries.allSatisfy { $0.outputDrained == true && $0.outcome == .succeeded })
    }

    @Test func cancelledDetachedWriterKeepsPanicTailAcrossRotation() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let script = temp.url.appendingPathComponent("cancel-output")
        let log = temp.url.appendingPathComponent("alpha.log")
        try """
        #!/bin/sh
        trap 'printf "\\033[31mkernel panic: cancelled tail\\033[0m\\r\\n"; exit 130' INT
        printf 'ready\\n'
        while :; do /bin/sleep 0.02; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let lines = LaunchpadLines()
        let child = try VPhoneLaunchpadChildProcess(executable: script, arguments: [], logFile: log) { lines.append($0) }
        #expect(await eventually(2) { lines.all.contains("ready") })
        #expect(child.interruptGroup())
        let completion = await child.waitForCompletion()
        #expect(completion.status == 130)
        #expect(completion.outputDrained)
        #expect(lines.all == ["ready", "kernel panic: cancelled tail"])
        #expect(VPhoneLaunchpadConsoleLog.isPanic(try #require(lines.all.last)))
        let raw = try Data(contentsOf: log)
        #expect(String(decoding: raw, as: UTF8.self).contains("\u{1B}[31mkernel panic: cancelled tail\u{1B}[0m\r\n"))
        var follower = VPhoneLaunchpadLogFollower(url: log)
        #expect(follower.poll() == [.lines(["ready", "kernel panic: cancelled tail"])])
        #expect(VPhoneLaunchpadConsoleLog.rotate(log, in: temp.url) == .rotated)
        let nextLines = LaunchpadLines()
        let next = try VPhoneLaunchpadChildProcess(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["next run\\n"], logFile: log) { nextLines.append($0) }
        let nextCompletion = await next.waitForCompletion()
        #expect(nextCompletion.status == 0)
        #expect(nextCompletion.outputDrained)
        #expect(nextLines.all == ["next run"])
        #expect(follower.poll() == [.reset, .lines(["next run"])])
        #expect(try Data(contentsOf: VPhoneLaunchpadConsoleLog.previousLog(log)) == raw)
    }
}

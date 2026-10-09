import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
struct OutputCompletionTests {
    @Test func concurrentChildrenRetainSeparateTailsAndReportTruncation() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let script = temp.url.appendingPathComponent("output")
        try """
        #!/bin/sh
        i=0; while [ "$i" -lt 4500 ]; do echo "$1:$i"; i=$((i + 1)); done
        printf "$1:panic tail"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let command = VPhoneLaunchpadCommandLine(executable: script, history: VPhoneLaunchpadCommandHistory())
        async let first = command.run(["first"])
        async let second = command.run(["second"])
        for (name, result) in [("first", try await first), ("second", try await second)] {
            #expect(result.status == 0)
            #expect(result.outputDrained)
            #expect(result.omittedLineCount == 501)
            #expect(result.lines.count == 4000)
            #expect(result.lines.allSatisfy { $0.hasPrefix(name + ":") })
            #expect(result.lines.last == name + ":panic tail")
        }
    }

    @Test func detachedParentExitDoesNotConfirmDescendantOutput() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let script = temp.url.appendingPathComponent("descendant")
        let log = temp.url.appendingPathComponent("child.log")
        let release = temp.url.appendingPathComponent("release")
        defer { try? Data().write(to: release) }
        try """
        #!/bin/sh
        ( i=0; while [ ! -e "$1" ] && [ "$i" -lt 600 ]; do /bin/sleep 0.05; i=$((i + 1)); done; printf 'late descendant tail\\n' ) &
        echo parent
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let lines = LaunchpadLines()
        let child = try VPhoneLaunchpadChildProcess(executable: script, arguments: [release.path], logFile: log) { lines.append($0) }
        let completion = await child.waitForCompletion()
        #expect(completion.status == 0)
        #expect(!completion.outputDrained)
        try Data().write(to: release)
        // The raw detached log remains available after the reader reports
        // incomplete output; let the finite descendant finish before cleanup.
        #expect(await eventually(4) { (try? String(contentsOf: log, encoding: .utf8))?.contains("late descendant tail") == true })
    }

    @Test func finalWriteBeforeGroupDisappearsIsDeliveredBeforeCompletion() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let log = temp.url.appendingPathComponent("last-write.log")
        let lines = LaunchpadLines()
        let child = try VPhoneLaunchpadChildProcess(
            executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], logFile: log,
            beforeDetachedGroupCheck: {
                // Deterministic final write after the previous EOF, before
                // the group disappearance check. The writer then closes.
                do {
                    let file = try FileHandle(forWritingTo: log)
                    try file.seekToEnd()
                    try file.write(contentsOf: Data("last write\n".utf8))
                    try file.close()
                } catch { Issue.record(error) }
            }, onLine: { lines.append($0) })
        let completion = await child.waitForCompletion()
        #expect(completion.status == 0)
        #expect(completion.outputDrained)
        #expect(lines.all == ["last write"])
    }

    @Test func livePipeDeliversLinesBeforeWriterCloses() async throws {
        let pipe = Pipe()
        let lines = LaunchpadLines()
        let completion = Task.detached {
            VPhoneLaunchpadLineReader.readLines(from: pipe.fileHandleForReading) { lines.append($0) }
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data("ready\n".utf8))
        #expect(await eventually(2) { lines.all == ["ready"] })
        try pipe.fileHandleForWriting.close()
        #expect(await completion.value == .drained)
    }

    @Test func readerFailureIsDistinctFromEOFAndDoesNotClaimDrain() throws {
        let pipe = Pipe()
        let fd = pipe.fileHandleForReading.fileDescriptor
        try pipe.fileHandleForReading.close()
        // A closed FileHandle's descriptor accessor raises NSException on macOS.
        // Pass the already captured descriptor to exercise POSIX read failure.
        #expect(VPhoneLaunchpadLineReader.readLines(fileDescriptor: fd, onLine: { _ in }) == .failed)
        try pipe.fileHandleForWriting.close()
        let empty = Pipe()
        try empty.fileHandleForWriting.close()
        #expect(VPhoneLaunchpadLineReader.readLines(from: empty.fileHandleForReading, onLine: { _ in }) == .drained)
    }

    @Test func exitZeroWithReadFailureIsNotACompleteCommand() {
        let result = VPhoneLaunchpadCommandResult(status: 0, lines: [], outputDrained: false)
        #expect(!result.succeeded)
        let history = VPhoneLaunchpadCommandHistory()
        let id = history.record("operation")
        history.finish(id, status: 0, outputDrained: false)
        #expect(history.entries[0].outcome == .failed)
        #expect(history.entries[0].status == 0)
    }
    @Test func logCreationFailureDoesNotLeaveRunningHistory() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let blocked = temp.url.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let history = VPhoneLaunchpadCommandHistory()
        let command = VPhoneLaunchpadCommandLine(executable: URL(fileURLWithPath: "/usr/bin/true"), history: history, logsDirectory: blocked)
        do { _ = try await command.run([]); Issue.record("Expected log creation failure") }
        catch { #expect(history.entries.isEmpty) }
    }

    @Test func spawnFailureFinishesHistoryAndClosesLog() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let history = VPhoneLaunchpadCommandHistory()
        let command = VPhoneLaunchpadCommandLine(executable: temp.url.appendingPathComponent("missing"), history: history, logsDirectory: temp.url)
        do { _ = try await command.run([]); Issue.record("Expected spawn failure") }
        catch {
            #expect(history.entries.count == 1)
            #expect(history.entries.first?.outcome == .failed)
            #expect(history.entries.first?.outputDrained == false)
        }
    }

}

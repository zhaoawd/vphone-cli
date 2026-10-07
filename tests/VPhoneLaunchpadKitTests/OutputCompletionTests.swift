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

    @Test func readerFailureIsDistinctFromEOFAndDoesNotClaimDrain() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        #expect(VPhoneLaunchpadLineReader.readLines(from: pipe.fileHandleForReading, onLine: { _ in }) == .failed)
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
}

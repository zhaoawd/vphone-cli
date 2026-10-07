import VPhoneCore
import Foundation
import Testing
@testable import VPhoneLaunchpadKit

struct LogWriterTests {
    @Test func drainPersistsEveryLineInOrderIncludingFinalPanic() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let url = temp.url.appendingPathComponent("console.log")
        let writer = try VPhoneLaunchpadLogWriter(url: url)
        let expected = (0..<10000).map { "line \($0)" } + ["panic: final tail"]
        for line in expected { writer.write(line) }
        try await writer.finish()
        #expect(try String(contentsOf: url, encoding: .utf8) == expected.joined(separator: "\n") + "\n")
        #expect(writer.tail.hasSuffix("panic: final tail"))
        try await writer.finish()
    }

    @Test func failedWritePreventsAcknowledgementAndLateWritesAreRejected() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let target = temp.url.appendingPathComponent("read-only")
        try Data().write(to: target)
        let writer = VPhoneLaunchpadLogWriter(url: target, handle: try FileHandle(forReadingFrom: target))
        writer.write("must not be acknowledged")
        await #expect(throws: (any Error).self) { try await writer.finish() }
        let normal = try VPhoneLaunchpadLogWriter(url: temp.url.appendingPathComponent("normal"))
        normal.write("first")
        try await normal.finish()
        normal.write("late")
        await #expect(throws: (any Error).self) { try await normal.finish() }
    }
}

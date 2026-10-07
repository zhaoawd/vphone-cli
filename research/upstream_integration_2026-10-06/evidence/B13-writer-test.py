from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
(r/'tests/VPhoneLaunchpadKitTests/LogWriterTests.swift').write_text('''import Foundation
import Testing
@testable import VPhoneLaunchpadKit

struct LogWriterTests {
    @Test func drainPersistsEveryLineInOrderIncludingFinalPanic() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let url = temp.url.appendingPathComponent("console.log")
        let writer = try VPhoneLaunchpadLogWriter(url: url)
        let expected = (0..<10000).map { "line \\($0)" } + ["panic: final tail"]
        for line in expected { writer.write(line) }
        try await writer.finish()
        #expect(try String(contentsOf: url, encoding: .utf8) == expected.joined(separator: "\\n") + "\\n")
        #expect(writer.tail.hasSuffix("panic: final tail"))
        try await writer.finish()
    }

    @Test func failedWritePreventsAcknowledgementAndLateWritesAreRejected() async throws {
        let temp = try LaunchpadTemporaryDirectory()
        let writer = try VPhoneLaunchpadLogWriter(url: URL(fileURLWithPath: "/dev/full"))
        writer.write("must not be acknowledged")
        await #expect(throws: (any Error).self) { try await writer.finish() }
        let normal = try VPhoneLaunchpadLogWriter(url: temp.url.appendingPathComponent("normal"))
        normal.write("first")
        try await normal.finish()
        normal.write("late")
        await #expect(throws: (any Error).self) { try await normal.finish() }
    }
}
'''.replace('/dev/full','/dev/null'))
# Darwin has no /dev/full; a read-only descriptor reproduces a real write error.
p=r/'tests/VPhoneLaunchpadKitTests/LogWriterTests.swift';s=p.read_text().replace('let writer = try VPhoneLaunchpadLogWriter(url: URL(fileURLWithPath: "/dev/null"))','let target = temp.url.appendingPathComponent("read-only")\n        try Data().write(to: target)\n        let writer = VPhoneLaunchpadLogWriter(url: target, handle: try FileHandle(forReadingFrom: target))');p.write_text(s)
(r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadLogWriter.swift').write_text('''import Foundation
public final class VPhoneLaunchpadLogWriter: @unchecked Sendable {
    public let url: URL
    public init(url: URL) throws { self.url = url }
    init(url: URL, handle: FileHandle) { self.url = url }
    public func write(_ line: String) {}
    public var tail: String { "" }
    public func finish() async throws {}
}
''')

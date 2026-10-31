import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
struct ChildEnvironmentTests {
    @Test func ordinaryCommandsInheritPath() async throws {
        let expected = try #require(ProcessInfo.processInfo.environment["PATH"])
        let command = VPhoneLaunchpadCommandLine(
            executable: URL(fileURLWithPath: "/usr/bin/printenv"),
            history: VPhoneLaunchpadCommandHistory())
        let result = try await command.run(["PATH"])
        #expect(result.succeeded)
        #expect(result.lines == [expected])
    }

    @Test(arguments: [["PATH": "/explicit/child/path"], [:]])
    func explicitEnvironmentRemainsAnOverride(_ environment: [String: String]) async throws {
        let lines = LaunchpadLines()
        let child = try VPhoneLaunchpadChildProcess(
            executable: URL(fileURLWithPath: "/usr/bin/printenv"), arguments: ["PATH"],
            environment: environment, onLine: { lines.append($0) })
        let result = await child.waitForCompletion()
        #expect(result.status == (environment["PATH"] == nil ? 1 : 0))
        #expect(lines.all == environment["PATH"].map { [$0] } ?? [])
    }
}

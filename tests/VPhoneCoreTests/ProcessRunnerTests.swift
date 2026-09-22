@testable import VPhoneCore
import Foundation
import Testing

struct ProcessRunnerTests {
    @Test func timeoutKillsChildIgnoringTermination() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "trap '' TERM; echo ready; exec /bin/sleep 5"], timeout: 0.5)
        #expect(result.stdout.contains("ready"))
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(ProcessInfo.processInfo.systemUptime - start < 4)
    }

    @Test func timeoutBoundsPipesInheritedByDescendant() throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "/bin/sleep 5 & echo $!"], timeout: 0.5)
        if let pid = Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            _ = kill(pid, SIGKILL)
        }
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(ProcessInfo.processInfo.systemUptime - start < 4)
    }

    @Test func timedOutZeroExitIsNotSuccess() {
        #expect(!VPhoneProcessResult(exitCode: 0, stdout: "", stderr: "", timedOut: true).succeeded)
    }

    @Test func capturesStdoutAndZeroExit() throws {
        let r = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/echo"), ["hello", "world"])
        #expect(r.exitCode == 0)
        #expect(r.succeeded)
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello world")
    }

    @Test func capturesNonzeroExit() throws {
        // `/usr/bin/false` exits 1 with no output.
        let r = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/false"), [])
        #expect(r.exitCode == 1)
        #expect(!r.succeeded)
    }

    @Test func passesCwd() throws {
        let r = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/pwd"), [], cwd: URL(fileURLWithPath: "/tmp"))
        // /tmp is a symlink to /private/tmp on macOS; accept either.
        let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(out == "/tmp" || out == "/private/tmp")
    }

    @Test(arguments: [false, true])
    func drainsBothPipesConcurrentlyWithoutDeadlock(bounded: Bool) throws {
        // Child writes 100 KB to stderr BEFORE any stdout; a sequential
        // "read stdout fully first" drain would deadlock at the ~64 KB stderr
        // pipe buffer. Concurrent draining must complete without hanging.
        let r = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/bin/sh"),
            ["-c", "yes E | head -c 100000 1>&2; yes X | head -c 100000"], timeout: bounded ? 5 : nil)
        #expect(r.exitCode == 0)
        #expect(r.stdout.utf8.count == 100000)
        #expect(r.stderr.utf8.count == 100000)
    }

    @Test func runStreamingReturnsExitCode() throws {
        #expect(try VPhoneProcessRunner.runStreaming(URL(fileURLWithPath: "/usr/bin/true"), []) == 0)
        #expect(try VPhoneProcessRunner.runStreaming(URL(fileURLWithPath: "/usr/bin/false"), []) == 1)
    }

    @Test func runStreamingEchoFalseStillReturnsExitCode() throws {
        // Child writes to stdout but echo:false discards it; exit code still propagates.
        #expect(try VPhoneProcessRunner.runStreaming(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo noise; exit 0"], echo: false) == 0)
        #expect(try VPhoneProcessRunner.runStreaming(
            URL(fileURLWithPath: "/bin/sh"), ["-c", "echo noise >&2; exit 7"], echo: false) == 7)
    }
}

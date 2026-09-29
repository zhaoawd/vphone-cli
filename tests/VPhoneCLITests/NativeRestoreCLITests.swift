import ArgumentParser
import Darwin
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

@Suite(.serialized)
struct NativeRestoreCLITests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func backendIsExplicitAndResumeKeepsUnspecifiedChoice() throws {
        let fresh = try VPhoneVMCreateCommand.parse(["test"])
        #expect(fresh.restoreBackend == nil)
        let native = try VPhoneVMCreateCommand.parse(["test", "--restore-backend", "native"])
        #expect(native.restoreBackend == .native)
        let resumed = try VPhoneVMCreateCommand.parse(["test", "--resume"])
        #expect(resumed.restoreBackend == nil)
        #expect(throws: (any Error).self) {
            _ = try VPhoneVMCreateCommand.parse(["test", "--restore-backend", "automatic"])
        }
    }

    @Test func identityMustMatchBundleAndCannotSelectAnyDevice() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "UDID=00008120-6378C23C514E44CC\nECID=0x6378C23C514E44CC\n".write(
            to: dir.appendingPathComponent("udid-prediction.txt"), atomically: true, encoding: .utf8)
        let target = try VPhoneNativeRestoreWorker.validateIdentity(
            directory: dir, ecid: "0x6378C23C514E44CC", udid: "00008120-6378c23c514e44cc")
        #expect(target == 0x6378C23C514E44CC)
        for bad in ["0", "1", "invalid"] {
            #expect(throws: (any Error).self) {
                _ = try VPhoneNativeRestoreWorker.validateIdentity(
                    directory: dir, ecid: bad, udid: "00008120-6378C23C514E44CC")
            }
        }
        #expect(throws: (any Error).self) {
            _ = try VPhoneNativeRestoreWorker.validateIdentity(
                directory: dir, ecid: "0x6378C23C514E44CC", udid: "00008120-1111111111111111")
        }
    }

    @Test func supervisorRejectsFailureAndStopsTimedOutWorker() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: (any Error).self) {
            try VPhoneNativeRestoreProcess.supervise(executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", "exit 23"], cwd: dir, timeout: 5, echo: false)
        }
        let pidFile = dir.appendingPathComponent("worker.pid")
        let script = "print -r -- $$ > worker.pid; trap '' INT TERM; zmodload zsh/zselect; while true; do zselect -t 1; done"
        let start = Date()
        #expect(throws: (any Error).self) {
            try VPhoneNativeRestoreProcess.supervise(executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", script], cwd: dir, timeout: 0.3, echo: false)
        }
        #expect(Date().timeIntervalSince(start) < 8)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test func supervisorCancellationRemainsCancellation() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        #expect(throws: CancellationError.self) {
            try VPhoneNativeRestoreProcess.supervise(executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", "zmodload zsh/zselect; while true; do zselect -t 1; done"],
                cwd: dir, timeout: 10, echo: false, shouldCancel: { Date().timeIntervalSince(start) > 0.2 })
        }
    }
}

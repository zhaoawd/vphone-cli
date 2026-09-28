import ArgumentParser
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

struct VMRuntimeEntryTests {
    @Test func commandExecutesPairedRuntimeAndPreservesExitStatus() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vm-entry-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cli = directory.appendingPathComponent("vphone-cli")
        try FileManager.default.copyItem(at: root.appendingPathComponent(".build/debug/vphone-cli"), to: cli)
        let runtime = directory.appendingPathComponent("vphone-vm")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 23\n".utf8).write(to: runtime)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runtime.path)
        for prefix in [[], ["boot"]] as [[String]] {
            let result = try VPhoneProcessRunner.runCapturing(cli, prefix + ["--config", "/fixture with spaces/config.plist", "--headless"], timeout: 5)
            #expect(result.exitCode == 23)
            #expect(result.stdout == "--config\n/fixture with spaces/config.plist\n--headless\n")
        }
        try FileManager.default.removeItem(at: runtime)
        let missing = try VPhoneProcessRunner.runCapturing(cli, ["--config", "/fixture/config.plist"], timeout: 5)
        #expect(!missing.succeeded)
        #expect(missing.stderr.contains("VM executable is missing"))
    }

    @Test func runtimeAcceptsBootOptionsAndRejectsManagementCommands() throws {
        let parsed = try VPhoneVMRuntimeCLI.parse(["--config", "/fixture/config.plist", "--dfu", "--headless"])
        #expect(parsed.boot.config.path == "/fixture/config.plist")
        #expect(parsed.boot.dfu && parsed.boot.headless)
        for args in [["vm", "delete", "a"], ["fw", "patch"], ["restore"], ["--config", "/x", "--dfu", "--api-listen", "127.0.0.1:0"]] {
            #expect(throws: (any Error).self) { try VPhoneVMRuntimeCLI.parse(args) }
        }
    }
}

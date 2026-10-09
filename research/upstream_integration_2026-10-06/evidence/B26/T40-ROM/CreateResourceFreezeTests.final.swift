import Darwin
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

struct CreateResourceFreezeTests {
    struct Fixture {
        let root: URL
        let resources: VPhoneResources
        let executable: URL

        var rom: URL { root.appendingPathComponent("framework/boot-rom") }
        var seprom: URL { root.appendingPathComponent("framework/sep-rom") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("create-freeze-" + UUID().uuidString)
            resources = VPhoneResources(base: root.appendingPathComponent("source"))
            executable = root.appendingPathComponent("source/bin/vphone-cli")
            for (path, content) in [
                ("bin/vphone-cli", "#!/bin/sh\nprintf cli-before"),
                ("bin/vphone-vm", "#!/bin/sh\nprintf vm-before"),
                ("scripts/fw_prepare.sh", "#!/bin/sh\nprintf script-before"),
                ("scripts/patchers/cfw.py", "patcher-before"),
                ("scripts/vphoned/signcert.p12", "cert-before"),
                ("requirements.txt", "requirements-before"),
                ("dependencies/python.lock", "lock-before"),
                ("scripts/resources/cfw_input.tar.zst", "archive-before"),
                (".tools/bin/trustcache", "tool-before"),
                (".build/guest/vphoned", "guest-before"),
                (".build/guest-components-v2/stage/manifest.json", "components-before"),
                ("tools/apfs_snap_rename.py", "rename-before"),
            ] { try write(path, content) }
            try FileManager.default.createDirectory(at: rom.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("rom-A".utf8).write(to: rom)
            try Data("sep-A".utf8).write(to: seprom)
        }

        func write(_ path: String, _ content: String) throws {
            let url = resources.base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func runner() throws -> VPhoneCreateRunner {
            try VPhoneCreateOrchestrator(library: VPhoneLibrary(root: root.appendingPathComponent("library")),
                resources: resources, selfExecutable: executable).makeRunner(.init(
                    sudoEnvExtras: [:], rootPopup: false, interactive: false, verbosity: .quiet, keepArtifacts: false), romSource: rom, sepromSource: seprom)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    // Catch new/prepare consumers selecting live system ROMs after snapshot capture.
    @Test func newAndPrepareRefreshUseCapturedROMBytes() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let runner = try f.runner()
        let selected = try #require(runner.executor as? VPhoneCreateLiveStages).orchestrator
        let snapshot = try #require(runner.resourceSnapshot)
        try Data("rom-B".utf8).write(to: f.rom)
        try Data("sep-B".utf8).write(to: f.seprom)
        let machine = try selected.createBundle(.init(name: "frozen", variant: "less", cpuCount: 2,
            memoryMB: 1024, diskSizeGB: 0), snapshot: snapshot)
        #expect(try String(contentsOf: machine.url.appendingPathComponent("AVPBooter.vresearch1.bin"), encoding: .utf8) == "rom-A")
        #expect(try String(contentsOf: machine.url.appendingPathComponent("AVPSEPBooter.vresearch1.bin"), encoding: .utf8) == "sep-A")
        try Data("patched".utf8).write(to: machine.url.appendingPathComponent("AVPBooter.vresearch1.bin"))
        try selected.refreshBootROM(bundleURL: machine.url)
        #expect(try String(contentsOf: machine.url.appendingPathComponent("AVPBooter.vresearch1.bin"), encoding: .utf8) == "rom-A")
    }

    @Test func createBundleWithoutSnapshotRefusesBeforeAllocatingDisk() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let orchestrator = VPhoneCreateOrchestrator(library: VPhoneLibrary(root: f.root.appendingPathComponent("library")),
            resources: f.resources, selfExecutable: f.executable)
        #expect(throws: Error.self) {
            try orchestrator.createBundle(.init(name: "missing", variant: "less", diskSizeGB: 0), snapshot: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("library/missing").path))
    }

    // Catch reading the original source path after a create attempt has selected inputs.
    @Test func attemptUsesCopiedScriptGuestArchiveAndExecutablesAfterOriginalReplacement() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let runner = try f.runner()
        let stages = try #require(runner.executor as? VPhoneCreateLiveStages)
        let fingerprint = try #require(runner.toolFingerprint())
        for (path, value) in [("scripts/fw_prepare.sh", "script-after"), (".build/guest/vphoned", "guest-after"),
                              ("scripts/resources/cfw_input.tar.zst", "archive-after"),
                              ("bin/vphone-cli", "#!/bin/sh\nprintf cli-after"), ("bin/vphone-vm", "#!/bin/sh\nprintf vm-after")] {
            try f.write(path, value)
        }
        let selected = stages.orchestrator
        #expect(try String(contentsOf: selected.resources.fwPrepareScript, encoding: .utf8) == "#!/bin/sh\nprintf script-before")
        #expect(try String(contentsOf: selected.resources.vphoned, encoding: .utf8) == "guest-before")
        #expect(try String(contentsOf: selected.resources.resourceArchivesDir.appendingPathComponent("cfw_input.tar.zst"), encoding: .utf8) == "archive-before")
        #expect(try VPhoneProcessRunner.runCapturing(selected.selfExecutable, []).stdout == "cli-before")
        #expect(try VPhoneProcessRunner.runCapturing(VPhoneResources.vmExecutable(executable: selected.selfExecutable), []).stdout == "vm-before")
        #expect(runner.toolFingerprint() == fingerprint)
    }

    // Catch resume treating changed non-executable inputs as the recorded toolchain.
    @Test func newAttemptDigestChangesForScriptsGuestToolsAndDependencyLocks() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = try f.runner()
        let digest = try #require(original.toolFingerprint())
        for path in ["scripts/fw_prepare.sh", ".build/guest/vphoned", ".tools/bin/trustcache", "dependencies/python.lock"] {
            let before = try Data(contentsOf: f.resources.base.appendingPathComponent(path))
            try f.write(path, "changed")
            let next = try f.runner()
            #expect(next.toolFingerprint() != digest, "resource omitted from create identity: \(path)")
            try before.write(to: f.resources.base.appendingPathComponent(path))
        }
    }

    @Test func attemptMaterializesResourceSymlinksAndRefusesDirectoryCycles() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let external = f.root.appendingPathComponent("external-guest")
        try Data("linked-guest-before".utf8).write(to: external)
        try FileManager.default.removeItem(at: f.resources.vphoned)
        try FileManager.default.createSymbolicLink(at: f.resources.vphoned, withDestinationURL: external)
        let runner = try f.runner()
        let selected = try #require(runner.executor as? VPhoneCreateLiveStages).orchestrator.resources.vphoned
        try Data("linked-guest-after".utf8).write(to: external)
        #expect(try String(contentsOf: selected, encoding: .utf8) == "linked-guest-before")
        var info = stat()
        #expect(lstat(selected.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG)
        try FileManager.default.createSymbolicLink(at: f.resources.scriptsDir.appendingPathComponent("loop"),
                                                  withDestinationURL: f.resources.scriptsDir)
        #expect(throws: Error.self) { try f.runner() }
    }

    @Test func unavailableResourceSourceRefusesBeforeReturningRunner() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.resources.signcert)
        #expect(throws: Error.self) { try f.runner() }
    }
}

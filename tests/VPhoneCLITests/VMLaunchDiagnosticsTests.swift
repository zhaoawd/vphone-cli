import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

/// `vm launch` end to end with stand-ins: a copy of the debug `vphone-cli`, a
/// stub `vphone-vm` next to it, a stub `boot_host_preflight.sh` under a
/// temporary resource base and a temporary library root. No VM is booted and
/// `~/.vphone/VMs` is not touched.
@Suite(.serialized)
struct VMLaunchDiagnosticsTests {
    static let marker = "=== Host ==="

    struct Rig {
        let directory: URL
        let cli: URL
        let runtime: URL
        let resources: URL
        let library: URL

        init() throws {
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let fm = FileManager.default
            directory = fm.temporaryDirectory.appendingPathComponent("vm-launch-diag-\(UUID())")
            cli = directory.appendingPathComponent("bin/vphone-cli")
            runtime = directory.appendingPathComponent("bin/vphone-vm")
            resources = directory.appendingPathComponent("resources")
            library = directory.appendingPathComponent("library")
            try fm.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: resources.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            let bundle = library.appendingPathComponent("vm1")
            try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
            try fm.copyItem(at: root.appendingPathComponent(".build/debug/vphone-cli"), to: cli)
            try VPhoneVirtualMachineManifest(cpuCount: 4, memorySize: 4 << 30,
                romImages: .init(avpBooter: "AVPBooter.vresearch1.bin", avpSEPBooter: "AVPSEPBooter.vresearch1.bin"))
                .write(to: bundle.appendingPathComponent("config.plist"))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        /// Preflight stand-in: prints the diagnostic report and exits with `status`.
        func preflight(exit status: Int32) throws {
            var script = "#!/bin/zsh\n"
            script += "echo ''\necho '\(VMLaunchDiagnosticsTests.marker)'\necho 'model: stand-in'\n"
            script += "echo ''\necho '=== Signed Release Binary ==='\necho '[release_help] exit=\(status)'\n"
            if status != 0 {
                script += "echo 'Error: signed release VM executable is not launchable on this host (exit \(status)).' >&2\n"
            }
            script += "exit \(status)\n"
            try write(script, to: resources.appendingPathComponent("scripts/boot_host_preflight.sh"))
        }

        /// Boot runtime stand-in.
        func runtime(_ body: String) throws {
            try write("#!/bin/sh\necho '[vphone] runtime started'\n" + body, to: runtime)
        }

        func launch() throws -> VPhoneProcessResult {
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "VPHONE_LIBRARY_ROOT")
            return try VPhoneProcessRunner.runCapturing(
                cli, ["vm", "launch", "vm1", "--library-root", library.path,
                      "--project-root", resources.path, "--no-vphoned"],
                env: env, timeout: 30)
        }

        private func write(_ text: String, to url: URL) throws {
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    @Test func childFailureRule() {
        #expect(!VPhoneVMLaunchCommand.childFailed(reason: .exit, status: 0))
        #expect(VPhoneVMLaunchCommand.childFailed(reason: .exit, status: 137))
        #expect(VPhoneVMLaunchCommand.childFailed(reason: .exit, status: 1))
        #expect(VPhoneVMLaunchCommand.childFailed(reason: .uncaughtSignal, status: SIGKILL))
    }

    @Test func normalStopDoesNotPrintHostDiagnostics() throws {
        let rig = try Rig()
        defer { rig.remove() }
        try rig.preflight(exit: 0)
        try rig.runtime("echo '[vphone] SIGINT — shutting down'\necho '[vphone] Guest stopped'\nexit 0\n")
        let result = try rig.launch()
        #expect(result.exitCode == 0, "\(result.stdout)\n\(result.stderr)")
        #expect(result.stdout.contains("[vphone] Guest stopped"))
        #expect(!result.stdout.contains(Self.marker), "\(result.stdout)")
        #expect(!result.stdout.contains("[release_help]"), "\(result.stdout)")
    }

    @Test func preflightRejectionPrintsHostDiagnostics() throws {
        let rig = try Rig()
        defer { rig.remove() }
        try rig.preflight(exit: 137)
        try rig.runtime("exit 0\n")
        let result = try rig.launch()
        #expect(result.exitCode == 137)
        #expect(result.stdout.contains(Self.marker), "\(result.stdout)")
        #expect(result.stdout.contains("[release_help] exit=137"))
        #expect(result.stderr.contains("not launchable on this host (exit 137)"))
        #expect(!result.stdout.contains("[vphone] runtime started"))
    }

    @Test func runtimeExit137PrintsHostDiagnostics() throws {
        let rig = try Rig()
        defer { rig.remove() }
        try rig.preflight(exit: 0)
        try rig.runtime("exit 137\n")
        let result = try rig.launch()
        #expect(result.exitCode == 137)
        #expect(result.stdout.contains(Self.marker), "\(result.stdout)")
        #expect(result.stdout.contains("[release_help] exit=0"))
    }

    @Test func runtimeSignalTerminationPrintsHostDiagnostics() throws {
        let rig = try Rig()
        defer { rig.remove() }
        try rig.preflight(exit: 0)
        try rig.runtime("kill -KILL $$\n")
        let result = try rig.launch()
        #expect(result.exitCode != 0)
        #expect(result.stdout.contains(Self.marker), "\(result.stdout)")
    }
}

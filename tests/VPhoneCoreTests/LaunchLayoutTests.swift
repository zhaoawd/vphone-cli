@testable import VPhoneCore
import Foundation
import Testing

struct LaunchLayoutTests {
    @Test func resolvesArtifactPaths() {
        let layout = VPhoneLaunchLayout(projectRoot: URL(fileURLWithPath: "/proj"))
        #expect(layout.preflightScript.path == "/proj/scripts/boot_host_preflight.sh")
    }

    @Test func resolvesToolPaths() {
        let layout = VPhoneLaunchLayout(projectRoot: URL(fileURLWithPath: "/proj"))
        #expect(layout.fwPrepareScript.path == "/proj/scripts/fw_prepare.sh")
        #expect(layout.cfwInstallHostScript.path == "/proj/scripts/cfw_install_host.sh")
        #expect(layout.pmd3Bridge.path == "/proj/scripts/pymobiledevice3_bridge.py")
    }

    @Test func delegatesToResources() {
        let resources = VPhoneResources(base: URL(fileURLWithPath: "/proj"))
        let layout = VPhoneLaunchLayout(resources: resources)
        #expect(layout.fwPrepareScript.path == resources.fwPrepareScript.path)
        #expect(layout.vphoned.path == resources.vphoned.path)
    }

    @Test func parsesLsofPIDs() {
        #expect(VPhoneLsof.parsePIDs("123\n456\n123\n\n  \nnotapid\n789\n") == [123, 456, 789])
        #expect(VPhoneLsof.parsePIDs("") == [])
    }

    // MARK: - Boot process locator

    @Test func locatesBootProcessByConfigArgument() {
        let ps = """
        80577 /repo/.build/release/vphone-cli vm launch rig-baseline --headless -vv
        80612 /repo/.build/release/vphone-cli --config /Users/u/.vphone/VMs/rig-baseline/config.plist --headless
        80614 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine
        """
        #expect(VPhoneBootProcessLocator.parsePIDs(
            ps, configPaths: ["/Users/u/.vphone/VMs/rig-baseline/config.plist"]) == [80612])
    }

    @Test func ignoresOtherBundlesAndUnrelatedProcesses() {
        let ps = """
        101 /repo/.build/release/vphone-cli --config /Users/u/.vphone/VMs/other/config.plist --headless
        102 /usr/bin/tail -f /Users/u/.vphone/VMs/rig-baseline/config.plist
        103 /bin/cat /Users/u/.vphone/VMs/rig-baseline/config.plist
        104 /repo/.build/release/vphone-cli vm config rig-baseline --show /Users/u/.vphone/VMs/rig-baseline/config.plist
        105 /repo/.build/release/vphone-cli vm stop rig-baseline
        """
        #expect(VPhoneBootProcessLocator.parsePIDs(
            ps, configPaths: ["/Users/u/.vphone/VMs/rig-baseline/config.plist"]).isEmpty)
    }

    @Test func matchesBundledAppBinaryAndEqualsForm() {
        let ps = """
        201 /Applications/vPhone.app/Contents/MacOS/vphone-cli --config /vms/a/config.plist
        202 /Applications/vPhone.app/Contents/MacOS/vphone-cli --config=/vms/a/config.plist --dfu
        """
        #expect(VPhoneBootProcessLocator.parsePIDs(ps, configPaths: ["/vms/a/config.plist"]) == [201, 202])
    }

    @Test func dedupsSortsAndSkipsMalformedLines() {
        let ps = """
        \(String(repeating: " ", count: 4))300 vphone-cli --config /vms/a/config.plist
        200 vphone-cli --config /vms/a/config.plist
        200 vphone-cli --config /vms/a/config.plist
        notapid vphone-cli --config /vms/a/config.plist
        400
        vphone-cli --config /vms/a/config.plist
        """
        #expect(VPhoneBootProcessLocator.parsePIDs(ps, configPaths: ["/vms/a/config.plist"]) == [200, 300])
        #expect(VPhoneBootProcessLocator.parsePIDs("", configPaths: ["/vms/a/config.plist"]).isEmpty)
        #expect(VPhoneBootProcessLocator.parsePIDs("200 vphone-cli --config /vms/a/config.plist",
                                                   configPaths: []).isEmpty)
    }

    @Test func matchesEitherRawOrResolvedConfigPath() throws {
        // A symlinked library root: the boot process may carry either spelling.
        let real = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let bundleDir = real.appendingPathComponent("rig")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let link = real.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundleDir)

        let viaLink = link.appendingPathComponent("config.plist")
        let variants = VPhoneBootProcessLocator.configPathVariants(for: viaLink)
        #expect(variants.contains(viaLink.path))
        #expect(variants.contains(bundleDir.appendingPathComponent("config.plist").path))
        #expect(VPhoneBootProcessLocator.parsePIDs(
            "700 vphone-cli --config \(bundleDir.appendingPathComponent("config.plist").path)",
            configURL: viaLink) == [700])
    }

    @Test func stageVphonedCopiesWhenSourceExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2, 3]).write(to: root.appendingPathComponent(".build/vphoned.signed"))

        let bundleDir = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2, memorySize: 1024 * 1024,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"))
        let bundle = VPhoneBundle(url: bundleDir, manifest: manifest)

        let layout = VPhoneLaunchLayout(projectRoot: root)
        #expect(try layout.stageVphoned(into: bundle) == true)
        #expect(FileManager.default.fileExists(atPath: bundleDir.appendingPathComponent(".vphoned.signed").path))
        // Second call is a no-op (already identical).
        #expect(try layout.stageVphoned(into: bundle) == false)
    }

    @Test func stageVphonedReturnsFalseWhenSourceAbsent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // No .build/vphoned.signed created → source absent.
        let bundleDir = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2, memorySize: 1024 * 1024, romImages: .init(avpBooter: "a", avpSEPBooter: "b"))
        let bundle = VPhoneBundle(url: bundleDir, manifest: manifest)

        #expect(try VPhoneLaunchLayout(projectRoot: root).stageVphoned(into: bundle) == false)
        #expect(!FileManager.default.fileExists(
            atPath: bundleDir.appendingPathComponent(".vphoned.signed").path))
    }

    @Test func stageVphonedOverwritesStaleDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([9, 9, 9, 9]).write(to: root.appendingPathComponent(".build/vphoned.signed"))

        let bundleDir = root.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        // Pre-populate dst with DIFFERENT bytes.
        try Data([1, 1]).write(to: bundleDir.appendingPathComponent(".vphoned.signed"))
        let manifest = VPhoneVirtualMachineManifest(
            cpuCount: 2, memorySize: 1024 * 1024, romImages: .init(avpBooter: "a", avpSEPBooter: "b"))
        let bundle = VPhoneBundle(url: bundleDir, manifest: manifest)

        #expect(try VPhoneLaunchLayout(projectRoot: root).stageVphoned(into: bundle) == true)
        let staged = try Data(contentsOf: bundleDir.appendingPathComponent(".vphoned.signed"))
        #expect(staged == Data([9, 9, 9, 9]))
    }
}

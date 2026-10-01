import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

/// The `VPhoneBundleReport` JSON `vm list --json` prints, decoded the way
/// Launchpad decodes it.
struct MachineDecodeTests {
    @Test func decodesEveryNetworkModeWithoutRestoreInfo() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let bundles = try [
            LaunchpadReports.writeBundle(named: "a-nat", in: temp.url,
                                         network: .init(mode: .nat, macAddress: "02:00:00:00:00:01")),
            LaunchpadReports.writeBundle(named: "b-bridged", in: temp.url,
                                         network: .init(mode: .bridged, macAddress: "02:00:00:00:00:02", bridgeInterface: "en0")),
            LaunchpadReports.writeBundle(named: "c-none", in: temp.url,
                                         network: .init(mode: .off, macAddress: "02:00:00:00:00:03")),
        ]
        let machines = try VPhoneLaunchpadMachine.decodeList(LaunchpadReports.listJSON(bundles), libraryRoot: temp.canonicalPath)
        #expect(machines.map(\.name) == ["a-nat", "b-bridged", "c-none"])
        #expect(machines.map(\.network.mode) == ["nat", "bridged", "none"])
        #expect(machines[1].network.bridgeInterface == "en0")
        #expect(machines[0].network.macAddress == "02:00:00:00:00:01")
        for machine in machines {
            #expect(machine.cpuCount == 4)
            #expect(machine.memoryMB == 6144)
            #expect(machine.diskSizeBytes == 0)
            #expect(machine.restoreInfo == nil)
            #expect(machine.customFirmwareInstalled == nil)
            #expect(machine.iosVersion == "")
            #expect(machine.libraryRoot == temp.canonicalPath)
            #expect(machine.path.url.lastPathComponent == machine.name)
            #expect(machine.path.configURL.path.hasSuffix("/\(machine.name)/config.plist"))
            #expect(machine.path.libraryArguments == ["--library-root", temp.canonicalPath])
        }
    }

    @Test func decodesRestoreInfoAndLocalVariantNames() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let bundle = try LaunchpadReports.writeBundle(named: "restored", in: temp.url)
        try VPhoneRestoreInfo(
            ios: .init(version: "26.1", build: "23B85"),
            cloudOS: .init(version: "26.1", build: "23B5072a"),
            variant: "jb", device: VPhoneRestoreInfo.baseDevice
        ).write(toBundle: bundle)
        let machine = try #require(VPhoneLaunchpadMachine.decodeList(LaunchpadReports.listJSON([bundle]), libraryRoot: "/x").first)
        let info = try #require(machine.restoreInfo)
        #expect(info.ios.version == "26.1")
        #expect(info.ios.build == "23B85")
        #expect(info.cloudOS.build == "23B5072a")
        #expect(info.variant == "jb")
        #expect(info.device == VPhoneRestoreInfo.baseDevice)
        #expect(machine.iosVersion == "26.1")
    }

    @Test(arguments: [
        ("regular", "Regular Firmware"), ("dev", "Development Firmware"), ("jb", "Jailbreak Firmware"),
        ("exp", "Experimental Firmware"), ("less", "Less Firmware"), ("std", "Unknown Firmware"),
    ])
    func firmwareNameFollowsLocalVariants(_ variant: String, _ name: String) throws {
        let json = #"{"ios":{"version":"26.1","build":"b"},"cloudOS":{"version":"26.1","build":"c"},"variant":"\#(variant)"}"#
        let info = try JSONDecoder().decode(VPhoneLaunchpadMachine.RestoreInfo.self, from: Data(json.utf8))
        // The test bundle has no catalog, so the English key comes back.
        #expect(info.firmwareName == name)
    }

    @Test func upstreamOnlyFieldDecodesWhenPresent() throws {
        let json = #"[{"name":"u","cpuCount":2,"memoryMB":2048,"diskSizeBytes":1,"network":{"mode":"nat","macAddress":"m"},"customFirmwareInstalled":false}]"#
        let machine = try #require(VPhoneLaunchpadMachine.decodeList(Data(json.utf8), libraryRoot: "/r").first)
        #expect(machine.customFirmwareInstalled == false)
        #expect(machine.udid == nil)
    }

    @Test func jsonFollowsWarningLines() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let bundle = try LaunchpadReports.writeBundle(named: "after-warning", in: temp.url)
        let json = String(decoding: try LaunchpadReports.listJSON([bundle]), as: UTF8.self)
        let result = VPhoneLaunchpadCommandResult(status: 0, lines: [
            "warning: skipping broken: config.plist unreadable",
            json,
        ])
        let data = try #require(result.jsonData)
        #expect(try VPhoneLaunchpadMachine.decodeList(data, libraryRoot: "/r").map(\.name) == ["after-warning"])
        #expect(VPhoneLaunchpadCommandResult(status: 0, lines: ["warning: only"]).jsonData == nil)
    }

    @Test func emptyLibraryDecodesAsEmptyList() throws {
        #expect(try VPhoneLaunchpadMachine.decodeList(Data("[]".utf8), libraryRoot: "/r").isEmpty)
    }

    @Test func displayQuotesArguments() {
        #expect(VPhoneLaunchpadCommandLine.display(["vm", "list", "--json", "--library-root", "/a b/it's"])
            == #"vphone-cli vm list --json --library-root '/a b/it'\''s'"#)
    }
}

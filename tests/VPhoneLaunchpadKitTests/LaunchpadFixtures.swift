import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

// MARK: - Temporary directories

final class LaunchpadTemporaryDirectory {
    let url: URL

    init(_ prefix: String = "launchpad-kit") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A short name (`<prefix>-<8 hex>`), for libraries whose machines'
    /// `vphone.sock` paths must fit `sun_path`.
    init(short prefix: String) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// The resolved path, as `VPhoneLaunchpadMachineLocations.canonical` reports it
    /// (`/var` is a link to `/private/var`).
    var canonicalPath: String {
        VPhoneLaunchpadMachineLocations.canonical(url)
    }
}

// MARK: - Process helpers

enum LaunchpadProcess {
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func sign(_ url: URL, identifier: String? = nil) throws {
        var arguments = ["--force", "--sign", "-"]
        if let identifier {
            arguments += ["--identifier", identifier]
        }
        let result = try run("/usr/bin/codesign", arguments + [url.path])
        try #require(result.status == 0, "codesign failed: \(result.output)")
    }

    /// `CDHash=` from `codesign -dvvv`, the value `scripts/build_launchpad.sh` records.
    static func codesignCDHash(_ url: URL) throws -> String {
        let result = try run("/usr/bin/codesign", ["-dvvv", url.path])
        let line = try #require(result.output.split(separator: "\n").first { $0.hasPrefix("CDHash=") })
        return String(line.dropFirst("CDHash=".count))
    }
}

// MARK: - Fixture app

/// A signed stand-in for `vphone-launchpad.app`: the outer app and the nested
/// `vphone-cli.app` carry copies of `/usr/bin/true`, signed ad hoc in the
/// order the build script uses (nested executables, nested app, manifest,
/// outer app).
struct LaunchpadFixtureApp {
    let app: URL

    var helper: URL { app.appendingPathComponent("Contents/Helpers/vphone-cli.app") }
    var cli: URL { helper.appendingPathComponent("Contents/MacOS/vphone-cli") }
    var vm: URL { helper.appendingPathComponent("Contents/MacOS/vphone-vm") }
    var manifest: URL { app.appendingPathComponent("Contents/Resources/embedded-toolchain.json") }

    /// `manifestData` replaces the recorded manifest bytes (still sealed by
    /// the outer signature).
    static func make(in directory: URL, manifestData: ((VPhoneLaunchpadToolchainManifest) throws -> Data)? = nil) throws -> LaunchpadFixtureApp {
        let fixture = LaunchpadFixtureApp(app: directory.appendingPathComponent("Fixture.app", isDirectory: true))
        let fm = FileManager.default
        try fm.createDirectory(at: fixture.helper.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fixture.app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: fixture.app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)

        try writeInfo(fixture.helper, executable: "vphone-cli", identifier: "com.vphone.cli")
        try writeInfo(fixture.app, executable: "Fixture", identifier: "com.vphone.cli.launchpad.fixture")
        let truePath = URL(fileURLWithPath: "/usr/bin/true")
        try fm.copyItem(at: truePath, to: fixture.cli)
        try fm.copyItem(at: truePath, to: fixture.vm)
        try fm.copyItem(at: truePath, to: fixture.app.appendingPathComponent("Contents/MacOS/Fixture"))

        try LaunchpadProcess.sign(fixture.vm, identifier: "com.vphone.vm")
        try LaunchpadProcess.sign(fixture.helper)
        let manifest = VPhoneLaunchpadToolchainManifest(
            gitHash: "fixture",
            vphoneCLI: .init(cdhash: try LaunchpadProcess.codesignCDHash(fixture.cli)),
            vphoneVM: .init(cdhash: try LaunchpadProcess.codesignCDHash(fixture.vm))
        )
        try (manifestData?(manifest) ?? JSONEncoder().encode(manifest)).write(to: fixture.manifest)
        try LaunchpadProcess.sign(fixture.app)
        return fixture
    }

    private static func writeInfo(_ bundle: URL, executable: String, identifier: String) throws {
        let info: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundleIdentifier": identifier,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }
}

// MARK: - Bundle reports

enum LaunchpadReports {
    static func manifest(network: VPhoneVirtualMachineManifest.NetworkConfig = .default) -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(
            cpuCount: 4, memorySize: 6 * 1024 * 1024 * 1024,
            networkConfig: network,
            romImages: .init(avpBooter: "a", avpSEPBooter: "b"))
    }

    /// Writes a bundle the way `vm new` leaves it (config.plist only).
    @discardableResult
    static func writeBundle(named name: String, in root: URL, network: VPhoneVirtualMachineManifest.NetworkConfig = .default) throws -> VPhoneBundle {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest = manifest(network: network)
        try manifest.write(to: url.appendingPathComponent("config.plist"))
        return VPhoneBundle(url: url, manifest: manifest)
    }

    /// The bytes `vphone-cli vm list --json` prints for `bundles`.
    static func listJSON(_ bundles: [VPhoneBundle]) throws -> Data {
        try JSONEncoder().encode(bundles.map(VPhoneBundleReport.init))
    }
}

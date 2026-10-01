import Foundation
import Testing
@testable import VPhoneLaunchpadKit

struct ToolchainTests {
    private func failure(_ result: Result<VPhoneLaunchpadToolchain, VPhoneLaunchpadToolchain.Failure>) -> VPhoneLaunchpadToolchain.Failure? {
        if case let .failure(failure) = result {
            return failure
        }
        return nil
    }

    @Test func verifiesSignedFixtureAndUsesNestedExecutable() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let fixture = try LaunchpadFixtureApp.make(in: temp.url)
        let toolchain = try VPhoneLaunchpadToolchain.verify(appBundle: fixture.app).get()
        #expect(toolchain.executable.path == fixture.cli.standardizedFileURL.path)
        #expect(toolchain.vmExecutable.path == fixture.vm.standardizedFileURL.path)
        #expect(toolchain.manifest.gitHash == "fixture")
    }

    @Test func cdhashMatchesCodesign() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let fixture = try LaunchpadFixtureApp.make(in: temp.url)
        for url in [fixture.cli, fixture.vm] {
            #expect(VPhoneLaunchpadToolchain.cdhash(of: url) == (try LaunchpadProcess.codesignCDHash(url)))
        }
        #expect(VPhoneLaunchpadToolchain.cdhash(of: fixture.cli) != VPhoneLaunchpadToolchain.cdhash(of: fixture.vm))
    }

    /// No environment variable or default can redirect the executable.
    @Test func ignoresEnvironmentAndDefaults() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let fixture = try LaunchpadFixtureApp.make(in: temp.url)
        let names = ["VPHONE_CLI", "VPHONE_CLI_PATH", "VPHONE_LAUNCHPAD_CLI", "VPHONE_LAUNCHPAD_EXECUTABLE"]
        for name in names {
            setenv(name, "/usr/bin/false", 1)
        }
        defer { names.forEach { unsetenv($0) } }
        UserDefaults.standard.set("/usr/bin/false", forKey: "VPhoneLaunchpadExecutable")
        defer { UserDefaults.standard.removeObject(forKey: "VPhoneLaunchpadExecutable") }
        let toolchain = try VPhoneLaunchpadToolchain.verify(appBundle: fixture.app).get()
        #expect(toolchain.executable.path == fixture.cli.standardizedFileURL.path)
    }

    @Test func rejectsMissingNestedApp() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let fixture = try LaunchpadFixtureApp.make(in: temp.url)
        try FileManager.default.removeItem(at: fixture.helper)
        let failure = try #require(failure(VPhoneLaunchpadToolchain.verify(appBundle: fixture.app)))
        #expect(failure.step == .layout)
        #expect(failure.reason.contains("vphone-cli.app"))
    }

    @Test func rejectsAppOutsideAnAppBundle() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let failure = try #require(failure(VPhoneLaunchpadToolchain.verify(appBundle: temp.url)))
        #expect(failure.step == .layout)
    }

    @Test func rejectsSymbolicLinkExecutable() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let fixture = try LaunchpadFixtureApp.make(in: temp.url)
        let elsewhere = temp.url.appendingPathComponent("vphone-cli")
        try FileManager.default.moveItem(at: fixture.cli, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: fixture.cli, withDestinationURL: elsewhere)
        let failure = try #require(failure(VPhoneLaunchpadToolchain.verify(appBundle: fixture.app)))
        #expect(failure.step == .layout)
        #expect(failure.reason.contains("symbolic link"))
    }

    @Test func rejectsSymbolicLinkHelpersDirectory() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let fixture = try LaunchpadFixtureApp.make(in: temp.url)
        let helpers = fixture.app.appendingPathComponent("Contents/Helpers")
        let elsewhere = temp.url.appendingPathComponent("Helpers")
        try FileManager.default.moveItem(at: helpers, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: helpers, withDestinationURL: elsewhere)
        let failure = try #require(failure(VPhoneLaunchpadToolchain.verify(appBundle: fixture.app)))
        #expect(failure.step == .layout)
        #expect(failure.reason.hasPrefix("Contents/Helpers:"))
    }

    @Test func rejectsModifiedNestedExecutable() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let fixture = try LaunchpadFixtureApp.make(in: temp.url)
        let handle = try FileHandle(forWritingTo: fixture.vm)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let failure = try #require(failure(VPhoneLaunchpadToolchain.verify(appBundle: fixture.app)))
        #expect(failure.step == .nestedSignature)
    }

    @Test func rejectsManifestEditedAfterSigning() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let fixture = try LaunchpadFixtureApp.make(in: temp.url)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest)) as? [String: Any])
        object["gitHash"] = "edited"
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.manifest)
        let failure = try #require(failure(VPhoneLaunchpadToolchain.verify(appBundle: fixture.app)))
        #expect(failure.step == .outerSignature)
    }

    @Test func rejectsCDHashThatDiffersFromManifest() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let fixture = try LaunchpadFixtureApp.make(in: temp.url) { manifest in
            try JSONEncoder().encode(VPhoneLaunchpadToolchainManifest(
                gitHash: manifest.gitHash,
                vphoneCLI: manifest.vphoneCLI,
                vphoneVM: .init(cdhash: String(repeating: "0", count: 40))
            ))
        }
        let failure = try #require(failure(VPhoneLaunchpadToolchain.verify(appBundle: fixture.app)))
        #expect(failure.step == .cdhash)
        #expect(failure.reason.hasPrefix("vphone-vm:"))
    }

    @Test func rejectsUnknownManifestSchema() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let fixture = try LaunchpadFixtureApp.make(in: temp.url) { manifest in
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
            object["schema"] = "upstream.core-bundle"
            return try JSONSerialization.data(withJSONObject: object)
        }
        let failure = try #require(failure(VPhoneLaunchpadToolchain.verify(appBundle: fixture.app)))
        #expect(failure.step == .manifest)
    }
}

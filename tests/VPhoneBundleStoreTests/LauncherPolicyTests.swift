import Foundation
import Testing
@testable import VPhoneBundleStore

struct LauncherPolicyTests {
    @Test func environmentReplacementRequiresItsOwnProtocol() throws {
        let request = try VPhoneLaunchpadLauncherRequest(executable: target,
            arguments: ["cfw", "update-environment", "machine", "--library-root", "/vm library", "--root-popup", "--work-parent", "/private/tmp"])
        #expect(request.isEnvironmentUpdate && !request.isKernelUpdate && !request.isKernelRollback)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = root.appendingPathComponent("Contents/MacOS/vphone-cli")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for value in ["", "vphone.environment-update.v0", "vphone.environment-update.v1"] {
            try PropertyListSerialization.data(fromPropertyList: ["VPhoneEnvironmentUpdateProtocol": value], format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Contents/Info.plist"))
            if value == "vphone.environment-update.v1" {
                try VPhoneLaunchpadLauncherRequest.validateEnvironmentUpdateProtocol(executable: executable)
            } else {
                #expect(throws: (any Error).self) { try VPhoneLaunchpadLauncherRequest.validateEnvironmentUpdateProtocol(executable: executable) }
            }
        }
    }

    @Test(arguments: [["--components", "/tmp/unverified"], ["--project-root", "/tmp"], ["--work-parent", "relative"],
                       ["--root-popup", "--root-popup"], ["--expected-binding-sha256", "bad"], ["--library-root"]])
    func environmentRejectsResourceOverridesAndMalformedOptions(options: [String]) {
        #expect(throws: (any Error).self) {
            try VPhoneLaunchpadLauncherRequest(executable: target, arguments: ["cfw", "update-environment", "machine"] + options)
        }
    }

    let target = "/Library/Application Support/vphone-launchpad/Bundles/2.6.1/VPhone.bundle/Contents/MacOS/vphone-cli"

    @Test func permitsExplicitCommittedKernelRollbackRoute() throws {
        let args = ["vm", "rollback-kernel", "machine", "--to-transaction", UUID().uuidString.lowercased()]
        #expect(try VPhoneLaunchpadLauncherRequest(executable: target, arguments: args).arguments == args)
    }

    @Test func permitsOnlyTheStoreCLIAndVMLaunch() throws {
        let request = try VPhoneLaunchpadLauncherRequest(executable: target, arguments: ["vm", "launch", "machine", "--headless"])
        #expect(request.version == "2.6.1")
        #expect(request.arguments == ["vm", "launch", "machine", "--headless"])
    }

    @Test(arguments: ["/usr/bin/true", "/tmp/vphone-cli", "/Library/Application Support/vphone-launchpad/Bundles/2.6.1/../2.6.1/VPhone.bundle/Contents/MacOS/vphone-cli", "/Library/Application Support/vphone-launchpad/Bundles//2.6.1/VPhone.bundle/Contents/MacOS/vphone-cli", "/Library/Application Support/vphone-launchpad/Bundles/2.6.1/VPhone.bundle/Contents/MacOS/vphone-vm"])
    func refusesOtherAndNoncanonicalPaths(path: String) {
        #expect(throws: (any Error).self) { try VPhoneLaunchpadLauncherRequest(executable: path, arguments: ["vm", "launch", "machine"]) }
    }

    @Test(arguments: [[String](), ["vm", "launch"], ["vm", "launch", ""], ["vm", "launch", "--headless"], ["vm", "create", "machine"], ["helper", "register"], ["vm", "launch", "machine", "\0"]])
    func refusesOtherVerbsAndInvalidArguments(arguments: [String]) {
        #expect(throws: (any Error).self) { try VPhoneLaunchpadLauncherRequest(executable: target, arguments: arguments) }
    }

    @Test(arguments: ["2.6.1-local.12345678", "2.6.1-ci.1234567"])
    func permitsValidBuildNames(version: String) throws {
        let path = target.replacingOccurrences(of: "/2.6.1/", with: "/\(version)/")
        #expect(try VPhoneLaunchpadLauncherRequest(executable: path, arguments: ["vm", "launch", "machine"]).version == version)
    }

    @Test func refusesLegacyVersionBeforeFilesystemAccess() {
        #expect(throws: (any Error).self) { try VPhoneLaunchpadLauncherRequest(executable: target.replacingOccurrences(of: "2.6.1", with: "2.0.8"), arguments: ["vm", "launch", "machine"]) }
    }
}

extension LauncherPolicyTests {
    @Test func kernelUpdateRequiresExplicitBundleProtocol() throws {
        let request = try VPhoneLaunchpadLauncherRequest(executable: target, arguments: ["vm", "update-kernel", "machine"])
        #expect(request.isKernelUpdate)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = root.appendingPathComponent("Contents/MacOS/vphone-cli")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for value in ["", "vphone.kernel-update.v0", "vphone.kernel-update.v1"] {
            try PropertyListSerialization.data(fromPropertyList: ["VPhoneKernelUpdateProtocol": value], format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Contents/Info.plist"))
            if value == "vphone.kernel-update.v1" { try VPhoneLaunchpadLauncherRequest.validateKernelUpdateProtocol(executable: executable) }
            else { #expect(throws: (any Error).self) { try VPhoneLaunchpadLauncherRequest.validateKernelUpdateProtocol(executable: executable) } }
        }
    }
}

extension LauncherPolicyTests {
    @Test func rollbackRequiresItsOwnSealedProtocol() throws {
        let request = try VPhoneLaunchpadLauncherRequest(executable: target, arguments: ["vm", "rollback-kernel", "machine", "--list"])
        #expect(request.isKernelRollback && !request.isKernelUpdate)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let executable = root.appendingPathComponent("Contents/MacOS/vphone-cli")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for value in ["", "vphone.kernel-rollback.v0", "vphone.kernel-rollback.v1"] {
            try PropertyListSerialization.data(fromPropertyList: ["VPhoneKernelUpdateProtocol": "vphone.kernel-update.v1", "VPhoneKernelRollbackProtocol": value], format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Contents/Info.plist"))
            if value == "vphone.kernel-rollback.v1" { try VPhoneLaunchpadLauncherRequest.validateKernelRollbackProtocol(executable: executable) }
            else { #expect(throws: (any Error).self) { try VPhoneLaunchpadLauncherRequest.validateKernelRollbackProtocol(executable: executable) } }
        }
    }
}

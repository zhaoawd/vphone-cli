import Foundation
import Testing
@testable import VPhoneLaunchpadKit

// MARK: - Command whitelist

/// B5 runs only `doctor --json`, `helper status` and `core-bundle verify
/// --version` (T26 design 9). Registration, installation and anything that
/// writes system directories cannot be built.
struct ReadOnlyCommandTests {
    @Test func factoriesBuildTheThreeReadOnlyCommands() throws {
        let doctor = try #require(VPhoneLaunchpadReadOnlyCommand.doctor(libraryRoot: "/Users/x/.vphone/VMs"))
        #expect(doctor.kind == .doctor)
        #expect(doctor.arguments == ["doctor", "--json", "--library-root", "/Users/x/.vphone/VMs"])
        #expect(VPhoneLaunchpadReadOnlyCommand.helperStatus.kind == .helperStatus)
        #expect(VPhoneLaunchpadReadOnlyCommand.helperStatus.arguments == ["helper", "status"])
        let verify = try #require(VPhoneLaunchpadReadOnlyCommand.coreBundleVerify(version: "2.2.3-local"))
        #expect(verify.kind == .coreBundleVerify)
        #expect(verify.arguments == ["core-bundle", "verify", "--version", "2.2.3-local"])
        #expect(VPhoneLaunchpadReadOnlyCommand.Kind.allCases.count == 3)
        for command in [doctor, .helperStatus, verify] {
            #expect(VPhoneLaunchpadReadOnlyCommand.isAllowed(command.arguments))
        }
    }

    @Test func factoriesRefuseValuesThatAreNotPathsOrVersions() {
        #expect(VPhoneLaunchpadReadOnlyCommand.doctor(libraryRoot: "relative/VMs") == nil)
        #expect(VPhoneLaunchpadReadOnlyCommand.doctor(libraryRoot: "--patch-record") == nil)
        #expect(VPhoneLaunchpadReadOnlyCommand.doctor(libraryRoot: "") == nil)
        for version in ["", "--help", "../2.2.3", "2.2.3; rm -rf /", "latest"] {
            #expect(VPhoneLaunchpadReadOnlyCommand.coreBundleVerify(version: version) == nil, "\(version)")
        }
    }

    /// Each privileged, installing or VM-changing command `vphone-cli`
    /// offers, and near misses of the allowed shapes.
    @Test(arguments: [
        ["helper", "register"],
        ["helper", "install-bundle", "--version", "2.2.3", "--archive", "/tmp/a.zip", "--sha256", String(repeating: "0", count: 64)],
        ["helper", "verify-bundle", "--version", "2.2.3"],
        ["helper"],
        ["helper", "status", "--help"],
        ["core-bundle", "install", "--version", "2.2.3", "--archive", "/tmp/a.zip", "--sha256", String(repeating: "0", count: 64)],
        ["core-bundle", "install", "--version", "2.2.3"],
        ["core-bundle", "verify", "--version", "--help"],
        ["core-bundle", "verify", "--version", "2.2.3", "--extra"],
        ["core-bundle", "verify", "2.2.3"],
        ["doctor"],
        ["doctor", "--json"],
        ["doctor", "--json", "--library-root", "relative"],
        ["doctor", "--json", "--library-root", "/x", "rig"],
        ["doctor", "--json", "--library-root", "/x", "--patch-record", "/y"],
        ["doctor", "--library-root", "/x", "--json"],
        ["vm", "list", "--json", "--library-root"],
        ["vm", "launch", "rig", "--library-root", "/x"],
        ["vm", "create", "rig", "--root-popup"],
        ["cfw", "install"],
        [],
    ])
    func everythingElseIsRefused(_ arguments: [String]) {
        #expect(!VPhoneLaunchpadReadOnlyCommand.isAllowed(arguments))
    }

    @Test func noFactoryOutputNamesAnInstallingSubcommand() throws {
        let commands = [
            try #require(VPhoneLaunchpadReadOnlyCommand.doctor(libraryRoot: "/x")),
            VPhoneLaunchpadReadOnlyCommand.helperStatus,
            try #require(VPhoneLaunchpadReadOnlyCommand.coreBundleVerify(version: "2.2.3")),
        ]
        let forbidden: Set<String> = ["register", "install", "install-bundle", "verify-bundle", "--sudo-password", "--root-popup"]
        for command in commands {
            #expect(forbidden.isDisjoint(with: command.arguments), "\(command.arguments)")
        }
    }
}

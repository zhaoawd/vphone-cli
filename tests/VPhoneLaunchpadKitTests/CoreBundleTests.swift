import Foundation
import Testing
@testable import VPhoneBundleStore
@testable import VPhoneLaunchpadKit

// MARK: - Rules shared with VPhoneBundleStore

struct CoreBundleRuleTests {
    @Test func storePathAndMinimumMatchTheStore() {
        #expect(VPhoneLaunchpadCoreBundle.storePath == VPhoneCoreBundleStore.root.path)
        #expect(VPhoneLaunchpadCoreBundleVersion.minimum == VPhoneBundleVersion.minimumText)
        #expect(VPhoneLaunchpadCoreBundleVersion.minimum == "2.2.0")
    }

    /// The panel's name filter accepts exactly the names the store's format
    /// check accepts; the version minimum stays with the CLI.
    @Test(arguments: [
        "2.2.3", "2.2.0-local", "2.2.3-ci.abcdef0", "10.0.0-ci.0123456789abcdef0123456789abcdef01234567",
        "2.0.8", "1.0.0-local",
        "", "x", "2.2", "2.2.3.4", "v2.2.3", "2.2.3-beta", "2.2.3-ci.ABCDEF0", "2.2.3-ci.abc", "2.2.3-local-local",
        "../2.2.3", "2.2.3/..", "--help", "2.2.3 ", "1234567890.0.0",
    ])
    func nameFilterMatchesTheStoreFormat(_ name: String) {
        var formatAccepted = true
        do {
            try VPhoneBundleVersion.require(name)
        } catch {
            formatAccepted = !"\(error.localizedDescription)".hasPrefix("Invalid Core Bundle version")
        }
        #expect(VPhoneLaunchpadCoreBundleVersion.isStoreName(name) == formatAccepted, "\(name)")
    }
}

// MARK: - verify output

struct CoreBundleVerifyMappingTests {
    static let receipt = VPhoneBundleReceipt(
        version: "2.2.3", sha256: String(repeating: "ab", count: 32),
        installedAt: Date(timeIntervalSince1970: 1_790_000_000),
        cdhashes: ["vphone-cli": String(repeating: "1", count: 40), "vphone-vm": String(repeating: "2", count: 40)]
    )

    static var receiptOutput: String {
        String(decoding: try! receipt.encoded(), as: UTF8.self) + "\n"
    }

    @Test func receiptPrintedByVerifyDecodes() {
        let check = VPhoneLaunchpadCoreBundle.check(.fixture(status: 0, output: Self.receiptOutput))
        guard case let .verified(decoded) = check else {
            Issue.record("expected verified, got \(check)")
            return
        }
        #expect(decoded.version == "2.2.3")
        #expect(decoded.sha256 == Self.receipt.sha256)
        #expect(decoded.installedAt == Self.receipt.installedAt)
        #expect(decoded.cdhashes == Self.receipt.cdhashes)
    }

    /// Messages recorded on this host.
    @Test func refusalsCarryTheCLIReason() {
        #expect(VPhoneLaunchpadCoreBundle.check(.fixture(status: 1, output:
            "Error: Core Bundle 2.0.8 is older than the minimum supported version 2.2.0.\n"))
            == .failed("Core Bundle 2.0.8 is older than the minimum supported version 2.2.0."))
        #expect(VPhoneLaunchpadCoreBundle.check(.fixture(status: 1, output:
            "Error: Unable to inspect at /Library/Application Support/vphone-launchpad: No such file or directory\n"))
            == .failed("Unable to inspect at /Library/Application Support/vphone-launchpad: No such file or directory"))
        #expect(VPhoneLaunchpadCoreBundle.check(.fixture(status: 0, output: "ok\n"))
            == .failed("core-bundle verify printed no receipt."))
    }
}

// MARK: - Store listing and refresh

@MainActor
struct CoreBundleStoreTests {
    let temp: LaunchpadTemporaryDirectory
    let cli: LaunchpadStandInCLI

    init() throws {
        temp = try LaunchpadTemporaryDirectory()
        cli = try LaunchpadStandInCLI(in: temp.url.appendingPathComponent("cli-dir", isDirectory: true).creatingDirectory())
    }

    @Test func listingSkipsHiddenEntriesAndReportsAbsentOrUnusableRoots() throws {
        let store = temp.url.appendingPathComponent("Bundles", isDirectory: true)
        #expect(VPhoneLaunchpadCoreBundle.listStore(store) == .absent)

        try "x".write(to: store, atomically: true, encoding: .utf8)
        #expect(VPhoneLaunchpadCoreBundle.listStore(store) == .unreadable("is not a directory"))
        try FileManager.default.removeItem(at: store)

        let real = temp.url.appendingPathComponent("real", isDirectory: true).creatingDirectory()
        try FileManager.default.createSymbolicLink(at: store, withDestinationURL: real)
        #expect(VPhoneLaunchpadCoreBundle.listStore(store) == .unreadable("is a symbolic link"))
        try FileManager.default.removeItem(at: store)

        _ = store.creatingDirectory()
        for name in ["2.2.3-local", ".store.lock", ".staging-1234", "2.2.3", "junk"] {
            _ = store.appendingPathComponent(name, isDirectory: true).creatingDirectory()
        }
        #expect(VPhoneLaunchpadCoreBundle.listStore(store) == .names(["2.2.3", "2.2.3-local", "junk"]))
    }

    @Test func absentStoreRunsNoCommand() async {
        let bundles = VPhoneLaunchpadCoreBundle(commandLine: cli.commandLine(),
                                                storeRoot: temp.url.appendingPathComponent("missing", isDirectory: true))
        await bundles.refresh()
        #expect(bundles.store == .absent)
        #expect(cli.recorded.isEmpty)
    }

    @Test func refreshVerifiesEachVersionAndNothingElse() async throws {
        let store = temp.url.appendingPathComponent("Bundles", isDirectory: true).creatingDirectory()
        for name in ["2.2.3", "2.2.3-local", "junk", ".store.lock"] {
            _ = store.appendingPathComponent(name, isDirectory: true).creatingDirectory()
        }
        try cli.respond("verify-2.2.3", output: CoreBundleVerifyMappingTests.receiptOutput, status: 0)
        try cli.respond("verify-2.2.3-local", output: "Error: Installed vphone-cli cdhash 00 differs from its receipt (11).\n", status: 1)

        let bundles = VPhoneLaunchpadCoreBundle(commandLine: cli.commandLine(), storeRoot: store)
        #expect(bundles.store == .notChecked)
        #expect(cli.recorded.isEmpty)
        await bundles.refresh()

        #expect(cli.recorded == ["core-bundle verify --version 2.2.3", "core-bundle verify --version 2.2.3-local"])
        guard case let .listed(installed) = bundles.store else {
            Issue.record("expected a listing, got \(bundles.store)")
            return
        }
        #expect(installed.map(\.name) == ["2.2.3", "2.2.3-local", "junk"])
        #expect(installed[0].isVerified)
        #expect(installed[1].check == .failed("Installed vphone-cli cdhash 00 differs from its receipt (11)."))
        #expect(installed[2].check == .notAVersion)
        #expect(bundles.isChecking == false)
    }
}

extension URL {
    /// Creates the directory (and parents) and returns self.
    @discardableResult
    func creatingDirectory() -> URL {
        try? FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}

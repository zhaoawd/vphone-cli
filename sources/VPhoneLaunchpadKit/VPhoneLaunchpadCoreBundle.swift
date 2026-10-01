import Darwin
import Foundation
import Observation

// MARK: - Version names

/// Core Bundle store names, as `VPhoneBundleVersion` in VPhoneBundleStore
/// accepts them: `X.Y.Z`, `X.Y.Z-local` or `X.Y.Z-ci.<commit>`, at most 64
/// bytes. The CLI still decides; this only keeps other directory names out
/// of the command line.
public enum VPhoneLaunchpadCoreBundleVersion {
    /// The oldest release the store accepts (T24).
    public static let minimum = "2.2.0"

    public static func isStoreName(_ value: String) -> Bool {
        value.utf8.count <= 64
            && value.range(of: "^[0-9]{1,9}\\.[0-9]{1,9}\\.[0-9]{1,9}(-local|-ci\\.[0-9a-f]{7,40})?$",
                           options: .regularExpression) != nil
    }
}

// MARK: - Receipt

/// `receipt.json` as `core-bundle verify` prints it after every check passed.
public struct VPhoneLaunchpadCoreBundleReceipt: Decodable, Equatable, Sendable {
    public let version: String
    public let sha256: String
    public let installedAt: Date
    public let cdhashes: [String: String]

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }
}

// MARK: - Installed versions

public struct VPhoneLaunchpadInstalledCoreBundle: Identifiable, Equatable, Sendable {
    public enum Check: Equatable, Sendable {
        case verified(VPhoneLaunchpadCoreBundleReceipt)
        /// `core-bundle verify` refused it; the reason is what it printed.
        case failed(String)
        /// Not a store version name, so no command ran for it.
        case notAVersion
    }

    public let name: String
    public let check: Check

    public var id: String {
        name
    }

    public var isVerified: Bool {
        if case .verified = check {
            return true
        }
        return false
    }
}

/// The Core Bundle panel's data: the store directory listing and one
/// `core-bundle verify --version` run per version in it. Nothing is
/// installed, removed or selected (decision of 2026-09-30); the embedded
/// toolchain stays the only one Launchpad runs.
@MainActor
@Observable
public final class VPhoneLaunchpadCoreBundle {
    public enum StoreState: Equatable, Sendable {
        case notChecked
        /// The store directory does not exist; no command ran.
        case absent
        /// The store path exists but could not be listed.
        case unreadable(String)
        case listed([VPhoneLaunchpadInstalledCoreBundle])
    }

    /// `VPhoneCoreBundleStore.root`, the root-owned store the CLI checks.
    public nonisolated static let storePath = "/Library/Application Support/vphone-launchpad/Bundles"

    public private(set) var store: StoreState = .notChecked
    public private(set) var isChecking = false
    public private(set) var checkedAt: Date?

    public let storeRoot: URL
    private let commandLine: VPhoneLaunchpadCommandLine

    public convenience init(commandLine: VPhoneLaunchpadCommandLine) {
        self.init(commandLine: commandLine, storeRoot: URL(fileURLWithPath: Self.storePath, isDirectory: true))
    }

    /// Test seam for a temporary store; the app uses the fixed path.
    init(commandLine: VPhoneLaunchpadCommandLine, storeRoot: URL) {
        self.commandLine = commandLine
        self.storeRoot = storeRoot
    }

    /// Lists the store, then verifies each version in name order.
    public func refresh() async {
        guard !isChecking else {
            return
        }
        isChecking = true
        defer {
            isChecking = false
            checkedAt = Date()
        }
        switch Self.listStore(storeRoot) {
        case .absent:
            store = .absent
        case let .unreadable(reason):
            store = .unreadable(reason)
        case let .names(names):
            var installed: [VPhoneLaunchpadInstalledCoreBundle] = []
            for name in names {
                installed.append(VPhoneLaunchpadInstalledCoreBundle(name: name, check: await verify(name)))
            }
            store = .listed(installed)
        }
        let line = switch store {
        case .notChecked: "not checked"
        case .absent: "absent"
        case .unreadable: "unreadable"
        case let .listed(bundles):
            "\(bundles.count) entries, \(bundles.count(where: \.isVerified)) verified"
        }
        FileHandle.standardOutput.write(Data("[launchpad] core bundle store: \(line)\n".utf8))
    }

    private func verify(_ name: String) async -> VPhoneLaunchpadInstalledCoreBundle.Check {
        guard let command = VPhoneLaunchpadReadOnlyCommand.coreBundleVerify(version: name) else {
            return .notAVersion
        }
        do {
            return Self.check(try await commandLine.run(command))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Maps a finished `core-bundle verify` run.
    public nonisolated static func check(_ result: VPhoneLaunchpadCommandResult) -> VPhoneLaunchpadInstalledCoreBundle.Check {
        guard result.succeeded else {
            return .failed(result.failureReason)
        }
        guard let data = result.jsonData, let receipt = try? VPhoneLaunchpadCoreBundleReceipt.decode(data) else {
            return .failed("core-bundle verify printed no receipt.")
        }
        return .verified(receipt)
    }

    // MARK: - Listing

    enum Listing: Equatable {
        case absent
        case unreadable(String)
        case names([String])
    }

    /// Entry names under the store, without hidden entries (the store lock
    /// and staging directories). Read-only: `lstat` and a directory read.
    nonisolated static func listStore(_ root: URL) -> Listing {
        var status = stat()
        guard lstat(root.path, &status) == 0 else {
            return errno == ENOENT ? .absent : .unreadable(String(cString: strerror(errno)))
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            return .unreadable(status.st_mode & S_IFMT == S_IFLNK ? "is a symbolic link" : "is not a directory")
        }
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            return .names(names.filter { !$0.hasPrefix(".") }.sorted())
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }
}

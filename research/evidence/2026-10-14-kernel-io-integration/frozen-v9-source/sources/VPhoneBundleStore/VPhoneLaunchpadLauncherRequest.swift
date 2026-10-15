import Foundation

/// The launcher accepts a root-owned bundle selector and launch/update/rollback routes.
/// Ordinary launch executes the verified local wrapper. Kernel update executes
/// the exact verified Bundle CLI after checking its sealed protocol marker.
/// Store verification checks receipt, ownership, signatures and lock throughout.
public struct VPhoneLaunchpadLauncherRequest: Sendable {
    public let version: String
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) throws {
        let prefix = VPhoneCoreBundleStore.root.path + "/"
        let suffix = "/VPhone.bundle/Contents/MacOS/vphone-cli"
        guard executable.hasPrefix(prefix), executable.hasSuffix(suffix),
              !executable.utf8.contains(0), executable.count > prefix.count + suffix.count else {
            throw VPhoneBundleStoreError("Launcher requires the vphone-cli in the root-owned Core Bundle store")
        }
        let version = String(executable.dropFirst(prefix.count).dropLast(suffix.count))
        try VPhoneBundleVersion.require(version)
        guard arguments.count >= 3, arguments[0] == "vm", ["launch", "update-kernel", "rollback-kernel"].contains(arguments[1]),
              !arguments[2].isEmpty, !arguments[2].hasPrefix("-"),
              arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw VPhoneBundleStoreError("Launcher permits only vm launch, vm update-kernel or vm rollback-kernel <machine> [options]")
        }
        self.version = version
        self.executable = executable
        self.arguments = arguments
    }

    public var isKernelUpdate: Bool { arguments[1] == "update-kernel" }

    public var isKernelRollback: Bool { arguments[1] == "rollback-kernel" }

    public static func validateKernelRollbackProtocol(executable: URL) throws {
        let info = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let fields = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any]
        guard fields?["VPhoneKernelRollbackProtocol"] as? String == "vphone.kernel-rollback.v1" else {
            throw VPhoneBundleStoreError("Selected Core Bundle does not declare the committed kernel rollback protocol")
        }
    }

    public static func validateKernelUpdateProtocol(executable: URL) throws {
        let info = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let fields = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any]
        guard fields?["VPhoneKernelUpdateProtocol"] as? String == "vphone.kernel-update.v1" else {
            throw VPhoneBundleStoreError("Selected Core Bundle does not declare the stopped kernel update protocol")
        }
    }

    /// Wait for the child inside this callback. A verified URL cannot be
    /// retained and used after the shared store lock is released.
    public func withVerifiedExecutable<T>(_ body: (URL) throws -> T) throws -> T {
        try VPhoneCoreBundleStore().withVerifiedExecutable(version: version, executable: .cli) { url in
            guard url.path == executable else {
                throw VPhoneBundleStoreError("Launcher target changed during verification")
            }
            return try body(url)
        }
    }
}

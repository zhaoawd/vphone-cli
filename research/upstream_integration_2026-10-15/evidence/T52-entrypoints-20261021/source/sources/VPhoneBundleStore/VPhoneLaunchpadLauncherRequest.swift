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
        guard arguments.count >= 3,
              (arguments[0] == "vm" && ["launch", "update-kernel", "rollback-kernel"].contains(arguments[1]))
                || (arguments[0] == "cfw" && arguments[1] == "update-environment"),
              !arguments[2].isEmpty, !arguments[2].hasPrefix("-"),
              arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw VPhoneBundleStoreError("Launcher permits vm launch/update-kernel/rollback-kernel or cfw update-environment <machine> [options]")
        }
        if arguments[0] == "cfw" { try Self.validateEnvironmentArguments(arguments) }
        self.version = version
        self.executable = executable
        self.arguments = arguments
    }

    public var isKernelUpdate: Bool { arguments[1] == "update-kernel" }

    public var isKernelRollback: Bool { arguments[1] == "rollback-kernel" }

    public var isEnvironmentUpdate: Bool { arguments[0] == "cfw" && arguments[1] == "update-environment" }

    /// Environment replacement cannot redirect its resource/component source.
    private static func validateEnvironmentArguments(_ arguments: [String]) throws {
        guard ![".", ".."].contains(arguments[2]), !arguments[2].contains("/") else {
            throw VPhoneBundleStoreError("Environment update requires a VM name")
        }
        var index = 3
        var seen = Set<String>()
        while index < arguments.count {
            let option = arguments[index]
            guard seen.insert(option).inserted else { throw VPhoneBundleStoreError("Duplicate environment option") }
            if ["--root-popup", "--check"].contains(option) { index += 1; continue }
            guard ["--library-root", "--work-parent", "--expected-binding-sha256"].contains(option),
                  index + 1 < arguments.count else { throw VPhoneBundleStoreError("Unsupported environment option") }
            let value = arguments[index + 1]
            if option == "--expected-binding-sha256" {
                guard value.count == 64, value.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    throw VPhoneBundleStoreError("Invalid binding digest")
                }
            } else if !value.hasPrefix("/") {
                throw VPhoneBundleStoreError("Environment paths must be absolute")
            }
            index += 2
        }
    }

    public static func validateEnvironmentUpdateProtocol(executable: URL) throws {
        let info = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        let fields = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any]
        guard fields?["VPhoneEnvironmentUpdateProtocol"] as? String == "vphone.environment-update.v1" else {
            throw VPhoneBundleStoreError("Selected Core Bundle does not declare the bound environment update protocol")
        }
    }

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

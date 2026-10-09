import Foundation

/// The ordinary launcher accepts a root-owned bundle selector and `vm launch`.
/// The selected CLI path identifies the bundle; only the verified local wrapper
/// is executed. Store verification checks its complete receipt, file ownership,
/// signatures and lock through VPhoneCoreBundleStore.
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
        guard arguments.count >= 3, arguments[0] == "vm", arguments[1] == "launch",
              !arguments[2].isEmpty, !arguments[2].hasPrefix("-"),
              arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw VPhoneBundleStoreError("Launcher permits only vm launch <machine> [options]")
        }
        self.version = version
        self.executable = executable
        self.arguments = arguments
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

import Foundation
import VPhoneCore
import VPhoneBundleStore

/// Freeze the selected host bundle before starting the ordinary launcher.
struct VPhoneLaunchpadLaunchRoute {
    let executable: URL
    let arguments: [String]
    let snapshot: VPhoneMachineBinding.Snapshot?

    static func resolve(embedded: URL, launcher: URL?, machine: URL, arguments: [String]) throws -> Self {
        guard let snapshot = try VPhoneMachineBinding.snapshot(machine) else {
            return Self(executable: embedded, arguments: arguments, snapshot: nil)
        }
        guard let launcher, VPhoneCoreBundleVersion.supportsTargetFeatures(snapshot.binding.bundle) else {
            throw VPhoneLaunchpadError("Bound VM execution requires the verified launcher and Core Bundle 2.6.0 or later.")
        }
        let target = VPhoneCoreBundleStore.root.appendingPathComponent(snapshot.binding.bundle)
            .appendingPathComponent("VPhone.bundle/Contents/MacOS/vphone-cli")
        let checked = try VPhoneLaunchpadLauncherRequest(executable: target.path, arguments: arguments)
        return Self(executable: launcher,
                    arguments: [checked.executable] + checked.arguments + ["--expected-binding-sha256", snapshot.sha256], snapshot: snapshot)
    }
}

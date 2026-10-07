import Foundation

// MARK: - Version names

/// Core Bundle store names, as `VPhoneBundleVersion` in VPhoneBundleStore
/// accepts them: `X.Y.Z`, `X.Y.Z-local[.<build>]` or `X.Y.Z-ci.<commit>`, at most 64
/// bytes. The CLI still decides; this only keeps other directory names out
/// of the command line.
public enum VPhoneCoreBundleVersion {
    /// The oldest release the store accepts (T24).
    public static let minimum = "2.2.0"

    public static func isStoreName(_ value: String) -> Bool {
        value.utf8.count <= 64
            && value.range(of: "^[0-9]{1,9}\\.[0-9]{1,9}\\.[0-9]{1,9}(-local(\\.[0-9a-f]{8,64})?|-ci\\.[0-9a-f]{7,40})?$",
                           options: .regularExpression) != nil
    }

    /// The target Launchpad interfaces require 2.6.0; this does not change
    /// the legacy store's ability to verify older installed bundles.
    public static let targetFeatureMinimum = "2.6.0"

    public static func supportsTargetFeatures(_ value: String) -> Bool {
        guard let version = components(value) else { return false }
        return version >= (2, 6, 0)
    }

    /// Default support policy for the target interfaces. Cross-series use
    /// needs independent validation; patches and build suffixes may differ.
    public static func supportsSeries(_ value: String, host: String) -> Bool {
        guard supportsTargetFeatures(value), supportsTargetFeatures(host),
              let bundle = components(value), let host = components(host) else { return false }
        return bundle.0 == host.0 && bundle.1 == host.1
    }

    private static func components(_ value: String) -> (Int, Int, Int)? {
        guard isStoreName(value) else { return nil }
        let release = value.split(separator: "-", maxSplits: 1)[0]
        let parts = release.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

}


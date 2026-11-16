import Foundation

@main
struct PCCRecoveryPolicyRegression {
    static func main() {
        for (version, expected): (String, UInt) in [
            ("18.5", 1), ("18.6.2", 1), ("25.9", 1),
            ("26.1", 8), ("26.4", 8), ("27.1", 8), ("", 8), ("unknown", 8),
        ] {
            precondition(VPhonePCCGPURecovery.restoreCPUCount(platformVersion: version) == expected,
                         "Unexpected temporary recovery CPU count for \(version)")
        }
        print("PCCRecoveryPolicyRegression: 8 cases passed")
    }
}

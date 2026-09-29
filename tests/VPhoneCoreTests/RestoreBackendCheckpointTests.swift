import Foundation
import Testing
@testable import VPhoneCore

struct RestoreBackendCheckpointTests {
    @Test func legacyOptionsKeepTheirEncodingAndDigest() throws {
        let options = VPhoneCreateEffectiveOptions(variant: "regular", iphoneSource: nil, cloudosSource: nil,
            spoofBuild: nil, forceDscMaxSlide: false, enableFrida: false, cpuCount: 8, memoryMb: 8192, diskSizeGb: 64)
        let encoded = try VPhoneCreateJSON.encoder.encode(options)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["restore_backend"] == nil)
        let decoded = try VPhoneCreateJSON.decoder.decode(VPhoneCreateEffectiveOptions.self, from: encoded)
        #expect(decoded.effectiveRestoreBackend == .python)
        #expect(decoded.digest == options.digest)
        var native = decoded
        native.restoreBackend = .native
        #expect(native.digest != options.digest)
        let changes = options.changes(to: native)
        #expect(changes.count == 1)
        #expect(changes.first?.field == "restore_backend")
        #expect(changes.first?.stage == .restore)
        let roundTrip = try VPhoneCreateJSON.decoder.decode(VPhoneCreateEffectiveOptions.self,
            from: VPhoneCreateJSON.encoder.encode(native))
        #expect(roundTrip.effectiveRestoreBackend == .native)
    }
}

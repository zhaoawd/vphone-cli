import Foundation
import Img4tool
import Testing
@testable import FirmwarePatcher

@Suite struct FirmwareComponentEffectIndexTests {
    static func payload(_ bytes: Data, wrapper: String) throws -> Data {
        switch wrapper {
        case "plain":
            return bytes
        case "slice":
            return (Data(repeating: 0, count: 17) + bytes).dropFirst(17)
        case "im4p":
            return try IM4P(IM4P(fourcc: "krnl", description: "synthetic", payload: bytes).data).payload()
        default:
            let im4p = try IM4P(fourcc: "krnl", description: "synthetic", payload: bytes)
            return try IMG4(IMG4(im4p: im4p).data).im4p().payload()
        }
    }

    @Test(arguments: ["plain", "slice", "im4p", "img4"], [0, 128, 252])
    func effectOffsetsAreRelativeToDecodedPayload(_ wrapper: String, _ offset: Int) throws {
        let expected = Data([42, 43, 44, 45])
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(offset..<offset + expected.count, with: expected)
        let decoded = try Self.payload(bytes, wrapper: wrapper)
        #expect(decoded == bytes)
        #expect(wrapper == "plain" ? decoded.startIndex == 0 : decoded.startIndex > 0)
        print("effect-index wrapper=\(wrapper) startIndex=\(decoded.startIndex) count=\(decoded.count) fileOffset=\(offset)")
        let record = PatchRecord(patchID: "kernel.apfs_root_snapshot", component: "kernelcache", fileOffset: offset,
            originalBytes: Data(repeating: 0, count: expected.count), patchedBytes: expected, description: "synthetic effect")
        try FirmwareComponentReceipt.verifyEffect(record, payload: decoded)
    }

    @Test(arguments: ["plain", "slice", "im4p", "img4"],
          ["wrong-offset", "different-bytes", "negative", "past-end", "overrun", "overflow", "empty"])
    func invalidEffectsRemainRejected(_ wrapper: String, _ fault: String) throws {
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(128..<132, with: [42, 43, 44, 45])
        let decoded = try Self.payload(bytes, wrapper: wrapper)
        let offset: Int
        switch fault {
        case "wrong-offset": offset = 129
        case "negative": offset = -1
        case "past-end": offset = 257
        case "overrun": offset = 254
        case "overflow": offset = Int.max
        default: offset = 128
        }
        let expected = fault == "empty" ? Data() : Data(fault == "different-bytes" ? [1, 2, 3, 4] : [42, 43, 44, 45])
        let record = PatchRecord(patchID: "kernel.apfs_root_snapshot", component: "kernelcache", fileOffset: offset,
            originalBytes: Data(repeating: 0, count: 4), patchedBytes: expected, description: "synthetic invalid effect")
        #expect(throws: (any Error).self) { try FirmwareComponentReceipt.verifyEffect(record, payload: decoded) }
    }
}

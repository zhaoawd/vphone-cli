import Foundation
import Img4tool
import Testing
@testable import FirmwarePatcher

struct KernelcacheSwapTests {
    static func element(_ tag: UInt8, _ body: Data) -> Data {
        var n = body.count
        var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(n & 255), at: 0); n >>= 8 } while n > 0
        return Data([tag]) + (body.count < 128 ? Data([UInt8(body.count)]) : Data([0x80 | UInt8(bytes.count)] + bytes)) + body
    }
    static func target(_ payload: Data, manifest: Data = Data([1, 2, 3]), restore: Data = Data([4, 5])) -> Data {
        element(0x30, element(0x16, Data("IMG4".utf8)) + payload + element(0xA0, manifest) + element(0xA1, restore))
    }
    @Test func replacesOnlyPayloadPreservingOpaqueManifestAndRestoreBytes() throws {
        let old = try IM4P(fourcc: "krnl", description: "old", payload: Data([1, 2])).data
        let new = try IM4P(fourcc: "krnl", description: "new", payload: Data(repeating: 3, count: 300)).data
        let manifest = Data((0..<129).map { UInt8($0) })
        let restore = Data([0, 255, 128])
        let input = Self.target(old, manifest: manifest, restore: restore)
        #expect(try VPhoneKernelcacheSwap.replacingPayload(in: input, with: new) == Self.target(new, manifest: manifest, restore: restore))
        #expect(try VPhoneKernelcacheSwap.replacingPayload(in: Self.target(new), with: new) == nil)
        #expect(try VPhoneKernelcacheSwap.replacingPayload(in: input, with: Self.target(new)) == Self.target(new, manifest: manifest, restore: restore))
    }
    @Test func refusesBareTargetWrongFourccAndMissingManifest() throws {
        let kernel = try IM4P(fourcc: "krnl", description: "", payload: Data([1])).data
        let tree = try IM4P(fourcc: "dtre", description: "", payload: Data([2])).data
        for (target, source) in [(kernel, kernel), (Self.target(kernel), tree), (Self.target(tree), kernel),
                                 (Self.element(0x30, Self.element(0x16, Data("IMG4".utf8)) + kernel), kernel)] {
            #expect(throws: (any Error).self) { try VPhoneKernelcacheSwap.replacingPayload(in: target, with: source) }
        }
    }
    @Test func malformedLengthsAndTrailingDataAreRejectedWithoutTrapping() throws {
        let kernel = try IM4P(fourcc: "krnl", description: "", payload: Data([1])).data
        for bytes in [Data([0x30, 0x80]), Data([0x30, 0x88] + Array(repeating: 255, count: 8)),
                      Data([0x30, 4, 0x16, 5, 0, 0]), Self.target(kernel) + Data([0])] {
            #expect(throws: (any Error).self) { try VPhoneKernelcacheSwap.replacingPayload(in: bytes, with: kernel) }
        }
    }
}

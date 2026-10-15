import Foundation
import Img4tool
import Testing
import VPhoneCore
@testable import FirmwarePatcher

@Suite struct KernelcacheMetadataTests {
    static func element(_ tag: UInt8, _ body: Data) -> Data { KernelcacheSwapTests.element(tag, body) }
    static func property(_ name: String = "kcsz") -> Data {
        var number = name.utf8.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var tag: [UInt8] = [UInt8(number & 127)]
        number >>= 7
        while number > 0 { tag.insert(UInt8(number & 127) | 128, at: 0); number >>= 7 }
        let body = element(0x30, element(0x16, Data(name.utf8)) + element(0x02, Data([1])))
        return Data([0xFF] + tag) + element(0xFF, body).dropFirst()
    }
    static func properties(_ body: Data) -> Data {
        element(0xA0, element(0x30, element(0x16, Data("PAYP".utf8)) + element(0x31, body)))
    }
    static let payp = properties(property())
    static func source(_ payload: Data, extras: Data = payp) -> Data {
        element(0x30, element(0x16, Data("IM4P".utf8)) + element(0x16, Data("krnl".utf8))
            + element(0x16, Data("original kernel description".utf8)) + element(0x04, payload) + extras)
    }

    @Test func repairsMissingMetadataFromPristineSourceInsteadOfTarget() throws {
        let payload = Data(repeating: 42, count: 256)
        let pristine = Self.source(payload)
        let damaged = try IM4P(fourcc: "krnl", description: "kernelcache", payload: payload).data
        let target = KernelcacheSwapTests.target(damaged)
        let replacement = try VPhoneKernelcacheSwap.repackKernelPayload(payload, sourceIM4P: pristine)
        #expect(try IM4P(replacement).description == "original kernel description")
        #expect(replacement == pristine)
        #expect(try IM4P(replacement).payload() == payload)
        #expect(try VPhoneKernelcacheSwap.replacingPayload(in: target, with: replacement) == KernelcacheSwapTests.target(pristine))
    }

    @Test func changedBytesKeepSourcePropertiesAndOpaqueTargetManifest() throws {
        let old = Data(repeating: 0, count: 256), patched = Data(repeating: 42, count: 256)
        let source = Self.source(old), expected = Self.source(patched)
        let repacked = try VPhoneKernelcacheSwap.repackKernelPayload(patched, sourceIM4P: source)
        #expect(repacked == expected)
        let target = KernelcacheSwapTests.target(try IM4P(fourcc: "krnl", description: "damaged", payload: old).data)
        #expect(try VPhoneKernelcacheSwap.replacingPayload(in: target, with: repacked) == KernelcacheSwapTests.target(expected))
        #expect(try VPhoneKernelcacheSwap.replacingPayload(in: KernelcacheSwapTests.target(expected), with: repacked) == nil)
    }

    @Test func markerInsidePayloadDoesNotCreateProperties() throws {
        let payload = Data(repeating: 0, count: 128) + Data("PAYP".utf8)
        let source = Self.source(payload, extras: Data())
        #expect(try VPhoneKernelcacheSwap.repackKernelPayload(payload, sourceIM4P: source) == source)
    }

    @Test func decodedPayloadDoesNotRetainStaleCompressionMetadata() throws {
        let original = Data(repeating: 0, count: 256), patched = Data(repeating: 42, count: 256)
        let compressed = try IM4P(fourcc: "krnl", description: "original kernel description", payload: original, compression: "lzfse").data
        let header = 2 + (compressed[1] & 128 == 0 ? 0 : Int(compressed[1] & 127))
        let source = Self.element(0x30, compressed.dropFirst(header) + Self.payp)
        let result = try VPhoneKernelcacheSwap.repackKernelPayload(patched, sourceIM4P: source)
        #expect(result == Self.source(patched))
        #expect(try IM4P(result).payload() == patched)
    }

    @Test(arguments: ["unknown", "encrypted", "duplicate-payp", "unknown-sequence", "malformed-payp",
                      "malformed-property", "duplicate-property", "compression-mismatch", "wrong-fourcc", "resized", "trailing", "lzss", "truncated"])
    func unknownOrInconsistentSourceMetadataIsRejected(_ fault: String) throws {
        let payload = Data(repeating: 0, count: 256)
        let extras: Data
        switch fault {
        case "unknown": extras = Self.element(0xA1, Data())
        case "encrypted": extras = Self.element(0x04, Data([1]))
        case "duplicate-payp": extras = Self.payp + Self.payp
        case "unknown-sequence": extras = Self.element(0x30, Self.element(0x02, Data([2])))
        case "malformed-payp": extras = Self.element(0xA0, Self.element(0x30, Self.element(0x16, Data("NOPE".utf8))))
        case "malformed-property": extras = Self.properties(Self.element(0x30, Data()))
        case "duplicate-property": extras = Self.properties(Self.property() + Self.property())
        case "compression-mismatch": extras = Self.element(0x30, Self.element(0x02, Data([1])) + Self.element(0x02, Data([1])))
        default: extras = Self.payp
        }
        var source = Self.source(payload, extras: extras)
        if fault == "lzss" { source = Self.source(Data("complzss".utf8) + Data(repeating: 0, count: 376)) }
        if fault == "truncated" { source.removeLast() }
        if fault == "wrong-fourcc" { source = try IM4P(source).renamed(to: "dtre").data }
        if fault == "trailing" { source.append(0) }
        #expect(throws: (any Error).self) {
            try VPhoneKernelcacheSwap.repackKernelPayload(fault == "resized" ? Data([1]) : payload, sourceIM4P: source)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_TEST_KERNEL_METADATA_SOURCE"] != nil))
    func actualPristineMetadataRestoresBaselineContainerExactly() throws {
        let env = ProcessInfo.processInfo.environment
        func file(_ key: String) throws -> Data {
            try VPhoneCreateDigest.strictFileData(URL(fileURLWithPath: #require(env[key])), maximumBytes: 512 << 20)
        }
        let source = try file("VPHONE_TEST_KERNEL_METADATA_SOURCE")
        let baseline = try file("VPHONE_TEST_KERNEL_METADATA_BASELINE")
        let damaged = try file("VPHONE_TEST_KERNEL_METADATA_DAMAGED")
        let reference = try #require(JSONSerialization.jsonObject(with: file("VPHONE_TEST_KERNEL_METADATA_REFERENCE")) as? [String: Any])
        let proof = try #require(reference["proof"] as? [String: Any])
        let kernels = try #require(reference["kernels"] as? [String: [String: Any]])
        #expect(VPhoneCreateDigest.sha256(source) == proof["inputSHA256"] as? String)
        #expect(VPhoneCreateDigest.sha256(baseline) == kernels["baseline"]?["image_sha256"] as? String)
        #expect(VPhoneCreateDigest.sha256(damaged) == kernels["installed"]?["image_sha256"] as? String)
        let payload = try IMG4(baseline).im4p().payload()
        #expect(VPhoneCreateDigest.sha256(payload) == proof["payloadSHA256"] as? String)
        let repacked = try VPhoneKernelcacheSwap.repackKernelPayload(payload, sourceIM4P: source)
        #expect(repacked == (try IMG4(baseline).im4p().data))
        let repaired = try #require(try VPhoneKernelcacheSwap.replacingPayload(in: damaged, with: repacked))
        #expect(repaired == baseline)
        if let output = env["VPHONE_TEST_KERNEL_METADATA_OUTPUT"] {
            try repaired.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
        }
        print("PAYP real source=\(VPhoneCreateDigest.sha256(source)) repaired=\(VPhoneCreateDigest.sha256(repaired)) baseline=\(VPhoneCreateDigest.sha256(baseline))")
    }
}

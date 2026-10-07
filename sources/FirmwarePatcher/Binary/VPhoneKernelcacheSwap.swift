import Foundation
import Img4tool

/// Pure IMG4 payload replacement. The caller must prove source/generation,
/// locate one Preboot target, check the kernel/DSC pair and publish transactionally.
/// Keeping a manifest's bytes does not verify its signature or establish boot success.
public enum VPhoneKernelcacheSwap {
    public static func replacingPayload(in prebootIMG4: Data, with patchedKernelcache: Data) throws -> Data? {
        let target = try parts(prebootIMG4, requireIMG4: true)
        let source = try parts(patchedKernelcache, requireIMG4: false)
        let old = try IM4P(target.payload)
        let new = try IM4P(source.payload)
        guard old.fourcc == "krnl", new.fourcc == "krnl", !new.isEncrypted else {
            throw Img4Error.invalidFormat("kernelcache swap requires a krnl target and an unencrypted krnl source")
        }
        guard target.payload != source.payload else { return nil }
        return element(0x30, target.leading + source.payload + target.trailing)
    }

    private struct Part {
        let tag: UInt8
        let raw: Data
        let value: Data
    }

    private static func read(_ data: Data, cursor: inout Int, limit: Int) throws -> Part {
        guard cursor >= 0, limit <= data.count, limit - cursor >= 2 else {
            throw Img4Error.invalidFormat("truncated DER element")
        }
        let start = cursor
        let tag = data[cursor]
        let first = data[cursor + 1]
        cursor += 2
        var length = Int(first)
        if first & 0x80 != 0 {
            let count = Int(first & 0x7F)
            guard count > 0, count <= 8, count <= limit - cursor else {
                throw Img4Error.invalidFormat("invalid DER length")
            }
            length = 0
            for _ in 0..<count {
                let (scaled, overflow) = length.multipliedReportingOverflow(by: 256)
                let (next, addedOverflow) = scaled.addingReportingOverflow(Int(data[cursor]))
                guard !overflow, !addedOverflow else { throw Img4Error.invalidFormat("DER length overflow") }
                length = next
                cursor += 1
            }
        }
        guard length <= limit - cursor else { throw Img4Error.invalidFormat("DER element exceeds its container") }
        let value = Data(data[cursor..<(cursor + length)])
        cursor += length
        return Part(tag: tag, raw: Data(data[start..<cursor]), value: value)
    }

    private static func parts(_ data: Data, requireIMG4: Bool) throws -> (leading: Data, payload: Data, trailing: Data) {
        var cursor = 0
        let outer = try read(Data(data), cursor: &cursor, limit: data.count)
        guard outer.tag == 0x30, cursor == data.count else { throw Img4Error.invalidFormat("expected one Image4 DER sequence") }
        cursor = 0
        var children: [Part] = []
        while cursor < outer.value.count {
            children.append(try read(outer.value, cursor: &cursor, limit: outer.value.count))
        }
        guard let first = children.first, first.tag == 0x16 else { throw Img4Error.invalidFormat("missing Image4 type") }
        if first.value == Data("IM4P".utf8), !requireIMG4 {
            return (Data(), data, Data())
        }
        guard first.value == Data("IMG4".utf8), children.count >= 3,
              children[1].tag == 0x30, children[2].tag == 0xA0, !children[2].value.isEmpty else {
            throw Img4Error.invalidFormat("expected IMG4 with IM4P and manifest")
        }
        return (first.raw, children[1].raw, children.dropFirst(2).reduce(Data()) { $0 + $1.raw })
    }

    private static func element(_ tag: UInt8, _ body: Data) -> Data {
        if body.count < 128 { return Data([tag, UInt8(body.count)]) + body }
        var value = body.count
        var bytes: [UInt8] = []
        while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }
        return Data([tag, 0x80 | UInt8(bytes.count)] + bytes) + body
    }
}

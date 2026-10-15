import Foundation
import Img4tool

/// Pure IMG4 payload replacement. The caller must prove source/generation,
/// locate one Preboot target, check the kernel/DSC pair and publish transactionally.
/// Keeping a manifest's bytes does not verify its signature or establish boot success.
public enum VPhoneKernelcacheSwap {
    static func repackKernelPayload(_ payload: Data, sourceIM4P: Data) throws -> Data {
        let fields = try sequenceParts(sourceIM4P)
        guard fields.count >= 4, fields[0].tag == 0x16, fields[0].value == Data("IM4P".utf8),
              fields[1].tag == 0x16, fields[1].value == Data("krnl".utf8),
              fields[2].tag == 0x16, String(data: fields[2].value, encoding: .ascii) != nil,
              fields[3].tag == 0x04, !fields[3].value.isEmpty, !payload.isEmpty else {
            throw Img4Error.invalidFormat("kernel repack requires a krnl IM4P metadata source")
        }
        var payp: Data?, decompressedSize: Int?
        for field in fields.dropFirst(4) {
            if field.tag == 0x30, decompressedSize == nil, payp == nil {
                let info = try sequenceParts(field.raw)
                guard info.count == 2, info[0].tag == 0x02, info[0].value == Data([1]),
                      info[1].tag == 0x02, !info[1].value.isEmpty, info[1].value.count <= 8,
                      info[1].value.first! & 0x80 == 0 else {
                    throw Img4Error.invalidFormat("unknown kernel compression metadata")
                }
                let count = info[1].value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                guard count > 0, count <= 512 << 20 else { throw Img4Error.invalidFormat("invalid kernel decompressed size") }
                decompressedSize = Int(count)
            } else if field.tag == 0xA0, payp == nil {
                try validatePAYP(field.value)
                payp = field.raw
            } else {
                throw Img4Error.invalidFormat("unknown, encrypted or duplicate kernel metadata")
            }
        }
        let encoded = fields[3].value
        guard encoded.prefix(8) != Data("complzss".utf8) else {
            throw Img4Error.invalidFormat("LZSS kernel metadata source is unsupported")
        }
        let lzfse = ["bvx2", "bvx-", "bvxn"].contains { encoded.prefix(4) == Data($0.utf8) }
        guard lzfse == (decompressedSize != nil) else {
            throw Img4Error.invalidFormat("kernel compression payload/metadata mismatch")
        }
        let original = try IM4P(sourceIM4P).payload()
        if let decompressedSize, original.count != decompressedSize {
            throw Img4Error.invalidFormat("kernel decompressed length differs from metadata")
        }
        guard payp == nil || original.count == payload.count else {
            throw Img4Error.invalidFormat("kernel PAYP cannot be retained across a payload size change")
        }
        // The producer supplies decoded bytes. Keep source metadata as raw TLVs,
        // but omit compression metadata because the rebuilt payload is raw.
        return element(0x30, fields[0].raw + fields[1].raw + fields[2].raw
            + element(0x04, payload) + (payp ?? Data()))
    }

    /// New rollback artifacts are always uncompressed producer output. Refuse
    /// unexpected encoding before any vendor decompressor can inspect it.
    static func rollbackArtifactPayload(_ data: Data) throws -> Data {
        let fields = try sequenceParts(data)
        guard (fields.count == 4 || fields.count == 5),
              fields[0].tag == 0x16, fields[0].value == Data("IM4P".utf8),
              fields[1].tag == 0x16, fields[1].value == Data("krnl".utf8),
              fields[2].tag == 0x16, String(data: fields[2].value, encoding: .ascii) != nil,
              fields[3].tag == 0x04, !fields[3].value.isEmpty,
              fields[3].value.prefix(8) != Data("complzss".utf8),
              !["bvx2", "bvx-", "bvxn"].contains(where: { fields[3].value.prefix(4) == Data($0.utf8) }) else {
            throw Img4Error.invalidFormat("rollback artifact must contain raw krnl producer output")
        }
        if fields.count == 5 {
            guard fields[4].tag == 0xA0 else { throw Img4Error.invalidFormat("unknown rollback artifact metadata") }
            try validatePAYP(fields[4].value)
        }
        return fields[3].value
    }

    /// Exact current IMG4 bytes outside IM4P, including its IM4M/IM4R.
    /// This checks preservation, not the manifest's cryptographic validity.
    static func containerEnvelope(_ data: Data) throws -> Data {
        let container = try parts(data, requireIMG4: true)
        return container.leading + container.trailing
    }

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
        let tagNumber: UInt64
        let raw: Data
        let value: Data
    }

    private static func read(_ data: Data, cursor: inout Int, limit: Int) throws -> Part {
        guard cursor >= 0, limit <= data.count, limit - cursor >= 2 else {
            throw Img4Error.invalidFormat("truncated DER element")
        }
        let start = cursor
        let tag = data[cursor]
        cursor += 1
        var tagNumber = UInt64(tag & 31)
        if tagNumber == 31 {
            tagNumber = 0
            var terminated = false
            for _ in 0..<8 {
                guard cursor < limit else { throw Img4Error.invalidFormat("truncated DER tag") }
                let byte = data[cursor]; cursor += 1
                tagNumber = (tagNumber << 7) | UInt64(byte & 127)
                if byte & 128 == 0 { terminated = true; break }
            }
            guard terminated else { throw Img4Error.invalidFormat("DER tag overflow") }
        }
        guard cursor < limit else { throw Img4Error.invalidFormat("missing DER length") }
        let first = data[cursor]; cursor += 1
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
        return Part(tag: tag, tagNumber: tagNumber, raw: Data(data[start..<cursor]), value: value)
    }

    private static func members(_ data: Data) throws -> [Part] {
        var cursor = 0, result: [Part] = []
        while cursor < data.count { result.append(try read(data, cursor: &cursor, limit: data.count)) }
        return result
    }

    private static func sequenceParts(_ data: Data) throws -> [Part] {
        let outer = try members(Data(data))
        guard outer.count == 1, outer[0].tag == 0x30 else { throw Img4Error.invalidFormat("expected one DER sequence") }
        return try members(outer[0].value)
    }

    private static func validatePAYP(_ data: Data) throws {
        let fields = try sequenceParts(data)
        guard fields.count == 2, fields[0].tag == 0x16, fields[0].value == Data("PAYP".utf8), fields[1].tag == 0x31 else {
            throw Img4Error.invalidFormat("unknown kernel payload properties")
        }
        var names = Set<Data>()
        for property in try members(fields[1].value) {
            guard property.tag == 0xFF else { throw Img4Error.invalidFormat("invalid PAYP property tag") }
            let pair = try sequenceParts(property.value)
            guard pair.count == 2, pair[0].tag == 0x16, pair[0].value.count == 4,
                  pair[0].value.allSatisfy({ $0 >= 32 && $0 < 127 }),
                  property.tagNumber == pair[0].value.reduce(UInt64(0), { ($0 << 8) | UInt64($1) }),
                  names.insert(pair[0].value).inserted,
                  [0x01, 0x02, 0x04, 0x16].contains(pair[1].tag) else {
                throw Img4Error.invalidFormat("unknown or duplicate PAYP property structure")
            }
            let value = pair[1]
            guard (value.tag != 0x01 || value.value == Data([0]) || value.value == Data([255])),
                  (value.tag != 0x02 || !value.value.isEmpty),
                  (value.tag != 0x16 || String(data: value.value, encoding: .ascii) != nil) else {
                throw Img4Error.invalidFormat("invalid PAYP property value")
            }
        }
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

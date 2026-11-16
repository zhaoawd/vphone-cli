@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Local pairing rejection gates")
struct CustomFirmwareRemotePairingTests {
    struct Fixture {
        static let base: UInt64 = 0x1_0000_0000
        var data = Data(count: 0x2400)
        let gates = [0x444, 0x484, 0x4c4]

        init(x1: Bool = false, releaseControl: Bool = false) throws {
            put(0xFEED_FACF, 0); put(0x0100_000C, 4); put(x1 ? 12 : 2, 8)
            put(2, 12); put(3, 16); put(416, 20)
            put(0x19, 32); put(312, 36); string("__TEXT", 40)
            put64(Self.base, 56); put64(0x1800, 64); put64(0, 72); put64(0x1800, 80); put(3, 96)
            section(0, "__text", 0x400, 0x400)
            section(1, "__cstring", 0x1000, 0x200)
            section(2, "__auth_stubs", 0x1400, 64, flags: 8)
            put(16, 104 + 2 * 80 + 72)
            put(2, 344); put(24, 348); put(0x1800, 352); put(4, 356); put(0x1900, 360); put(0x200, 364)
            put(0xB, 368); put(80, 372); put(0x1b00, 424); put(4, 428)
            var stringOffset = 1
            for (index, name) in ["_nw_connection_copy_current_path", "_nw_path_is_local", "_nw_path_uses_interface_type", "_swift_unknownObjectRelease"].enumerated() {
                put(UInt32(stringOffset), 0x1800 + index * 16)
                data[0x1804 + index * 16] = 1
                string(name, 0x1900 + stringOffset)
                put(UInt32(index), 0x1b00 + index * 4)
                stringOffset += name.utf8.count + 1
            }
            for offset in stride(from: 0x400, to: 0x800, by: 4) { write(ARM64.nop, offset) }
            let prologue = x1 ? ARM64.encodeU32(CustomFirmwareArm64eX1Tests.pac) : ARM64.pacibsp
            for start in [0x400, 0x440, 0x480, 0x4c0, 0x520] { write(prologue, start) }
            try call(0x404, 0x1400); try call(0x408, 0x1410)
            write(try #require(ARM64Encoder.encodeMovzW(rd: 1, imm16: 4)), 0x40c)
            try call(0x410, 0x1420); try call(0x414, 0x1430)
            write(ARM64.retab, 0x418)
            string("%{public}s: Rejecting control channel connection originating from local machine: %{public}s", 0x1000)
            string("Rejecting tunnel connection originating from local machine", 0x1100)
            try call(0x444, 0x400)
            if releaseControl {
                write(ARM64Encoder.encodeMovX(rd: 19, rm: 0), 0x448)
                write(ARM64Encoder.encodeMovX(rd: 0, rm: 20), 0x44c)
                try call(0x450, 0x1430)
                try bit(0x454, 0x474, register: 19)
                try reference(0x458, 0x1000)
            } else {
                try bit(0x448, 0x474)
                try reference(0x458, 0x1000)
            }
            write(ARM64.retab, 0x474)
            for start in [0x480, 0x4c0] {
                try call(start + 4, 0x400)
                try bit(start + 8, start + 24)
                write(try #require(ARM64Encoder.encodeLdrBUnsignedOffset(rt: 8, rn: 19, offset: 0)), start + 12)
                write(try #require(ARM64Encoder.encodeCmpWImmediate(rn: 8, imm12: 1)), start + 16)
                write(try #require(ARM64Encoder.encodeBCond(from: start + 20, to: start + 32, condition: .ne)), start + 20)
                try reference(start + 40, 0x1100)
                write(ARM64.retab, start + 48)
            }
        }

        mutating func write(_ value: Data, _ offset: Int) { data.replaceSubrange(offset..<offset + value.count, with: value) }
        mutating func put(_ value: UInt32, _ offset: Int) { write(ARM64.encodeU32(value), offset) }
        mutating func put64(_ value: UInt64, _ offset: Int) { var v = value.littleEndian; withUnsafeBytes(of: &v) { write(Data($0), offset) } }
        mutating func string(_ value: String, _ offset: Int) { write(Data(value.utf8) + [0], offset) }
        mutating func section(_ index: Int, _ name: String, _ offset: Int, _ size: Int, flags: UInt32 = 0) {
            let at = 104 + index * 80
            string(name, at); string("__TEXT", at + 16)
            put64(Self.base + UInt64(offset), at + 32); put64(UInt64(size), at + 40)
            put(UInt32(offset), at + 48); put(flags, at + 64)
        }
        mutating func call(_ from: Int, _ to: Int) throws { write(try #require(ARM64Encoder.encodeBL(from: from, to: to)), from) }
        mutating func bit(_ from: Int, _ to: Int, register: UInt32 = 0) throws {
            write(try #require(ARM64Encoder.encodeTestBitBranch(nonzero: false, register: register, bit: 0, from: from, to: to)), from)
        }
        mutating func reference(_ from: Int, _ to: Int) throws {
            write(try #require(ARM64Encoder.encodeADRP(rd: 3, pc: Self.base + UInt64(from), target: Self.base + UInt64(to))), from)
            write(try #require(ARM64Encoder.encodeAddImm12(rd: 3, rn: 3, imm12: UInt32(to & 0xfff))), from + 4)
        }
    }

    @Test(arguments: [false, true], [false, true])
    func `ordinary and X1 gates preserve unrelated bytes and repeat without changes`(x1: Bool, releaseControl: Bool) throws {
        let fixture = try Fixture(x1: x1, releaseControl: releaseControl)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.data.write(to: url)
        let dry = try CustomFirmwareRemotePairing.patch(fileAt: url, dryRun: true)
        #expect(dry.map(\.fileOffset) == fixture.gates)
        #expect(try Data(contentsOf: url) == fixture.data)
        let records = try CustomFirmwareRemotePairing.patch(fileAt: url)
        #expect(records.count == 3)
        var expected = fixture.data
        for site in fixture.gates { expected.replaceSubrange(site..<site + 4, with: ARM64.movW0_0) }
        #expect(try Data(contentsOf: url) == expected)
        #expect(try CustomFirmwareRemotePairing.patch(fileAt: url).isEmpty)
        #expect(try Data(contentsOf: url) == expected)
    }

    @Test(arguments: ["missingString", "ambiguousString", "unknownCaller", "predicate", "controlGate", "tunnelGate"])
    func `missing or ambiguous evidence refuses without writes`(_ mutation: String) throws {
        var fixture = try Fixture()
        switch mutation {
        case "missingString": fixture.data[0x1000] = 0
        case "ambiguousString":
            let message = Data(fixture.data[0x1000...].prefix { $0 != 0 }) + [0]
            fixture.write(message, 0x1180)
        case "unknownCaller": try fixture.call(0x528, 0x400)
        case "predicate": fixture.write(ARM64.nop, 0x40c)
        case "controlGate": fixture.write(ARM64.nop, 0x448)
        default: fixture.write(ARM64.nop, 0x494)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try fixture.data.write(to: url)
        #expect(throws: PatcherError.self) { try CustomFirmwareRemotePairing.patch(fileAt: url) }
        #expect(try Data(contentsOf: url) == fixture.data)
    }
}

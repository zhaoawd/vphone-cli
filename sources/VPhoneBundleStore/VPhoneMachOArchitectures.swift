import Darwin
import Foundation

/// Reads the CPU types in a Mach-O header without loading or executing it.
/// A Core Bundle executable must run on Apple silicon: an x86_64-only or
/// 32-bit file passes code signing but cannot start on the host.
///
/// Upstream 2.2.3 (7a9b4f7) ships `vphone-escalator` with `arm64e` and
/// `arm64e.x1` slices; both are `CPU_TYPE_ARM64`. This check does not require
/// a specific subtype: the local helper never runs the escalator.
enum VPhoneMachOArchitectures {
    static let arm64: Int32 = 0x0100_000C
    static let x86_64: Int32 = 0x0100_0007

    static func requireAppleSilicon(_ url: URL) throws {
        let types = try cpuTypes(url)
        guard types.contains(arm64) else {
            let names = types.map(name).joined(separator: ", ")
            throw VPhoneBundleStoreError("Core Bundle executable has no arm64 slice (found: \(names.isEmpty ? "none" : names)): \(url.path)")
        }
    }

    static func cpuTypes(_ url: URL) throws -> [Int32] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw VPhoneBundleStoreError("Unable to read Mach-O header at \(url.path): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var header = [UInt8](repeating: 0, count: 8192)
        let count = pread(fd, &header, header.count, 0)
        guard count >= 8 else { throw notMachO(url) }
        let data = Array(header.prefix(count))
        func big(_ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            return data[offset ..< offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        func little(_ offset: Int) -> UInt32? { big(offset).map { $0.byteSwapped } }
        switch big(0)! {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            // fat_header and fat_arch(_64) are big-endian; cputype leads each entry.
            let stride = big(0)! == 0xCAFE_BABE ? 20 : 32
            guard let n = big(4), n > 0, n <= 64 else { throw notMachO(url) }
            return try (0 ..< Int(n)).map { index in
                guard let type = big(8 + index * stride) else { throw notMachO(url) }
                return Int32(bitPattern: type)
            }
        case 0xCFFA_EDFE, 0xCEFA_EDFE:
            // Thin little-endian mach_header(_64): magic, then cputype.
            return [Int32(bitPattern: little(4)!)]
        default:
            throw notMachO(url)
        }
    }

    static func name(_ type: Int32) -> String {
        switch type {
        case arm64: "arm64"
        case x86_64: "x86_64"
        default: String(format: "cputype 0x%08x", UInt32(bitPattern: type))
        }
    }

    private static func notMachO(_ url: URL) -> VPhoneBundleStoreError {
        VPhoneBundleStoreError("Core Bundle executable is not a Mach-O file: \(url.path)")
    }
}

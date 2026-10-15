import Darwin
import Foundation
import VPhoneCore

/// Only a private candidate clone is ever mounted writable. The configured disk
/// uses the same association checks, but all its mounts are read-only.
enum FirmwareKernelMount {
    static func withVolumes<T>(image: URL, transaction: FirmwareTransaction, writable: Bool,
        operations: FirmwareInstalledReadback.Operations? = nil,
        body: ([String: URL]) throws -> T) throws -> T {
        if writable { _ = try FirmwareComponentReceipt.relative(image, in: transaction.work) }
        let before = writable ? nil : try FirmwareGeneration.fileSHA256(image)
        let ops = operations ?? FirmwareInstalledReadback.liveOperations(transaction: transaction, writablePreboot: writable)
        let attachment = try ops.attach(image, transaction.work)
        var detached = false
        do {
            guard attachment.image == image, Set(attachment.volumes.keys) == ["preboot", "system", "hardware"] else {
                throw FirmwareGeneration.fail("Kernel image volumes differ")
            }
            let roots = attachment.volumes.mapValues(\.root)
            for root in roots.values { _ = try FirmwareComponentReceipt.relative(root, in: transaction.work) }
            let identities = try roots.mapValues(identity)
            try FirmwareInstalledReadback.validate(attachment, observation: ops.inspect(attachment), writablePreboot: writable)
            let result = try body(roots)
            guard try roots.mapValues(identity) == identities else { throw FirmwareGeneration.fail("Kernel mount changed") }
            try FirmwareInstalledReadback.validate(attachment, observation: ops.inspect(attachment), writablePreboot: writable)
            guard try roots.mapValues(identity) == identities else { throw FirmwareGeneration.fail("Kernel mount changed during final observation") }
            detached = true
            try ops.detach(attachment)
            if let before, try FirmwareGeneration.fileSHA256(image) != before {
                throw FirmwareGeneration.fail("Readonly kernel image changed")
            }
            return result
        } catch {
            if !detached { try ops.detach(attachment) }
            throw error
        }
    }

    private static func identity(_ root: URL) throws -> String {
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw FirmwareGeneration.fail("Kernel mount is missing or linked")
        }
        return "\(info.st_dev):\(info.st_ino)"
    }

    static func uniqueKernel(in root: URL) throws -> URL {
        var matches: [URL] = []
        func visit(_ directory: URL) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let file = directory.appendingPathComponent(name)
                var info = stat()
                guard lstat(file.path, &info) == 0 else { throw FirmwareGeneration.fail("Unreadable Preboot subtree") }
                let targetName = ["kernelcache", "kernelcache.research.vphone600"].contains(name.lowercased())
                // Candidate paths contain ordinary directories only. Unrelated
                // JB links are never followed and cannot contribute candidates.
                if info.st_mode & S_IFMT == S_IFLNK {
                    guard !targetName else { throw FirmwareGeneration.fail("Linked Preboot kernel target") }
                    continue
                }
                if targetName {
                    guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                        throw FirmwareGeneration.fail("Preboot kernel must be one ordinary unlinked file")
                    }
                    _ = try FirmwareComponentReceipt.relative(file, in: root)
                    matches.append(file)
                }
                if info.st_mode & S_IFMT == S_IFDIR { try visit(file) }
            }
        }
        try visit(root)
        guard matches.count == 1 else { throw FirmwareGeneration.fail("Preboot kernel is missing or ambiguous") }
        return matches[0]
    }
}

/// Read the installed cache's complete mapping tables without changing maxSlide.
/// These are dyld_cache_header format fields, not kernel patch offsets.
enum FirmwareKernelDSC {
    static func validate(system: URL, region: FirmwareKernelRegion.Region) throws {
        let root = system.appendingPathComponent("System/Cryptexes/OS/System/Library/Caches/com.apple.dyld")
        _ = try FirmwareComponentReceipt.relative(root, in: system)
        try FirmwareGeneration.ensureDirectory(root, create: false)
        let base = "dyld_shared_cache_arm64e"
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
            // Apple's builder emits mainCacheFilePath + ".atlas" separately
            // from cacheBuffers; it has no dyld mapping header. Ignore only
            // that exact sidecar, never arbitrary subcache suffixes.
            $0.hasPrefix(base) && !$0.hasSuffix(".symbols") && !$0.hasSuffix(".map") && $0 != base + ".atlas"
        }.sorted()
        guard names.contains(base) else { throw FirmwareGeneration.fail("Installed DSC main cache is missing") }
        var lowest = UInt64.max, highest: UInt64 = 0, mainHeader: Data?, headerMapped = false
        var observed: [String: (uuid: Data, address: UInt64)] = [:]
        var expected: [String: (uuid: Data, offset: UInt64)] = [:]
        var ranges: [(UInt64, UInt64)] = []
        for name in names {
            let file = root.appendingPathComponent(name)
            _ = try FirmwareComponentReceipt.relative(file, in: root)
            let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? h.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw FirmwareGeneration.fail("DSC chunk is not regular") }
            let header = try h.read(upToCount: 0x200) ?? Data()
            guard header.count >= 0x100, header.starts(with: Data("dyld_v1".utf8)) else { throw FirmwareGeneration.fail("Unknown DSC header") }
            let offset = UInt64(header.loadLE(UInt32.self, at: 0x10)), count = Int(header.loadLE(UInt32.self, at: 0x14))
            guard offset >= 0xF8, offset <= 0x10000, count > 0, count <= 64 else { throw FirmwareGeneration.fail("Unknown DSC mapping table") }
            if name == base, offset >= 0x190 {
                guard header.count >= 0x190 else { throw FirmwareGeneration.fail("Truncated DSC subcache header") }
                let tableOffset = UInt64(header.loadLE(UInt32.self, at: 0x188))
                let tableCount = Int(header.loadLE(UInt32.self, at: 0x18C))
                let hasSuffix = offset >= 0x1CC
                let stride = hasSuffix ? 56 : 24
                guard tableCount <= 256, tableOffset <= UInt64(info.st_size),
                      UInt64(tableCount * stride) <= UInt64(info.st_size) - tableOffset else {
                    throw FirmwareGeneration.fail("Invalid DSC subcache table")
                }
                try h.seek(toOffset: tableOffset)
                let table = try h.read(upToCount: tableCount * stride) ?? Data()
                guard table.count == tableCount * stride else { throw FirmwareGeneration.fail("Truncated DSC subcache table") }
                for i in 0..<tableCount {
                    let p = i * stride
                    let suffix: String
                    if hasSuffix {
                        let bytes = table.subdata(in: p + 24..<p + 56)
                        guard let end = bytes.firstIndex(of: 0), let value = String(data: bytes.prefix(upTo: end), encoding: .utf8),
                              value.hasPrefix("."), !value.contains("/"), !value.contains(".."), value != ".symbols", value != ".map", value != ".atlas" else {
                            throw FirmwareGeneration.fail("Unsupported DSC subcache suffix")
                        }
                        suffix = value
                    } else { suffix = ".\(i + 1)" }
                    guard expected[base + suffix] == nil else { throw FirmwareGeneration.fail("Duplicate DSC subcache reference") }
                    expected[base + suffix] = (table.subdata(in: p..<p + 16), table.loadLE(UInt64.self, at: p + 16))
                }
            }
            var chunkLowest = UInt64.max
            try h.seek(toOffset: offset)
            let mappings = try h.read(upToCount: count * 32) ?? Data()
            guard mappings.count == count * 32 else { throw FirmwareGeneration.fail("Truncated DSC mappings") }
            for index in 0..<count {
                let p = index * 32, address = mappings.loadLE(UInt64.self, at: p)
                let size = mappings.loadLE(UInt64.self, at: p + 8), fileOffset = mappings.loadLE(UInt64.self, at: p + 16)
                let end = address.addingReportingOverflow(size), fileEnd = fileOffset.addingReportingOverflow(size)
                guard size > 0, !end.overflow, !fileEnd.overflow, fileEnd.partialValue <= UInt64(info.st_size) else {
                    throw FirmwareGeneration.fail("Invalid DSC mapping extent")
                }
                lowest = min(lowest, address); highest = max(highest, end.partialValue)
                chunkLowest = min(chunkLowest, address)
                ranges.append((address, end.partialValue))
                if name == base && fileOffset == 0 { headerMapped = true }
            }
            observed[name] = (header.subdata(in: 0x58..<0x68), chunkLowest)
            if name == base { mainHeader = header }
        }
        guard let header = mainHeader, headerMapped else { throw FirmwareGeneration.fail("DSC header has no mapping") }
        guard Set(observed.keys) == Set(expected.keys).union([base]) else { throw FirmwareGeneration.fail("Missing or unreferenced DSC subcache") }
        let mainBase = header.loadLE(UInt64.self, at: 0xE0)
        for (name, reference) in expected {
            let address = mainBase.addingReportingOverflow(reference.offset)
            guard let chunk = observed[name], chunk.uuid == reference.uuid, !address.overflow, chunk.address == address.partialValue else {
                throw FirmwareGeneration.fail("DSC subcache UUID or VM association differs")
            }
        }
        let sorted = ranges.sorted { $0.0 < $1.0 }
        for i in 1..<sorted.count where sorted[i - 1].1 > sorted[i].0 { throw FirmwareGeneration.fail("DSC mappings overlap") }
        try validate(header: header, lowest: lowest, highest: highest, region: region)
    }

    static func validate(header: Data, lowest: UInt64, highest: UInt64, region: FirmwareKernelRegion.Region) throws {
        guard header.count >= 0xF8 else { throw FirmwareGeneration.fail("DSC header is truncated") }
        let base = header.loadLE(UInt64.self, at: 0xE0), size = header.loadLE(UInt64.self, at: 0xE8)
        let slide = header.loadLE(UInt64.self, at: 0xF0), combined = size.addingReportingOverflow(slide)
        guard base == lowest, highest >= lowest, size >= highest - lowest, base == region.base,
              !combined.overflow, combined.partialValue <= region.size else {
            throw FirmwareGeneration.fail("Installed DSC span plus maxSlide exceeds or differs from candidate kernel region")
        }
    }
}

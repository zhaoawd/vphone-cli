import Foundation
@testable import FirmwarePatcher
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Dyld cache mapping lifetime")
struct DyldSharedCacheMappingLifetimeTests {
    private func resolved(_ path: String) -> String {
        guard let value = realpath(path, nil) else { return path }
        defer { free(value) }
        return String(cString: value)
    }

    private func mappings(in directory: URL) throws -> Int {
        let prefix = resolved(directory.path) + "/"
        #if os(Linux)
        let text = try String(contentsOfFile: "/proc/self/maps", encoding: .utf8)
        return text.split(separator: "\n").filter { $0.contains(prefix) }.count
        #elseif canImport(Darwin)
        var address: mach_vm_address_t = 0
        var total = 0
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_basic_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
            var object: mach_port_t = 0
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    mach_vm_region(mach_task_self_, &address, &size, VM_REGION_BASIC_INFO_64, $0, &count, &object)
                }
            }
            if result == KERN_INVALID_ADDRESS { break }
            try #require(result == KERN_SUCCESS, "Cannot inspect own VM regions: \(result)")
            if object != 0 { mach_port_deallocate(mach_task_self_, object) }
            var path = [CChar](repeating: 0, count: Int(PATH_MAX))
            if proc_regionfilename(getpid(), address, &path, UInt32(path.count)) > 0,
               resolved(String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).hasPrefix(prefix) {
                total += 1
            }
            let (next, overflow) = address.addingReportingOverflow(size)
            if overflow || next <= address { break }
            address = next
        }
        return total
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    @Test func imageScopeReleasesMappingsAfterSuccessAndFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("dyld_shared_cache_arm64e")
        var original = Data(repeating: 0, count: 0x8000)
        original.replaceSubrange(0 ..< 16, with: Data("dyld_v1  arm64e\0\0".utf8))
        func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { original.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        put(UInt32(0x100), at: 16); put(UInt32(1), at: 20)
        put(UInt64(0x180000000), at: 0x100); put(UInt64(0x4000), at: 0x108)
        put(UInt64(0x4000), at: 0x110); put(UInt32(5), at: 0x118); put(UInt32(5), at: 0x11c)
        original[0x4000] = 0x5a
        try original.write(to: file)
        let chunks = try DyldSharedCacheChunkSet(directory: directory, mappedReads: true)
        let result = try chunks.withScopedMappedReads {
            let bytes = try chunks.bytesAtVMA(0x180000000, length: 4)
            #expect(try mappings(in: directory) > 0)
            return bytes[0]
        }
        #expect(result == 0x5a)
        #expect(try mappings(in: directory) == 0)
        enum PlanningFailure: Error { case expected }
        #expect(throws: PlanningFailure.self) {
            try chunks.withScopedMappedReads {
                _ = try chunks.bytesAtVMA(0x180000000, length: 4)
                #expect(try mappings(in: directory) > 0)
                throw PlanningFailure.expected
            }
        }
        #expect(try mappings(in: directory) == 0)
        #expect(chunks.recordedWrites.isEmpty)
        #expect(try Data(contentsOf: file) == original)
    }

    #if canImport(Darwin)
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_DSC_LIFETIME_REFERENCE"] != nil))
    func exportedSymbolLookupReleasesTheReferenceCache() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_DSC_LIFETIME_REFERENCE"])
        let directory = URL(fileURLWithPath: path)
        let chunks = try DyldSharedCacheChunkSet(directory: directory)
        try autoreleasepool {
            var resolver: DyldSharedCacheSymbolResolver? = try DyldSharedCacheSymbolResolver(chunks: chunks)
            let image = try #require(resolver?.imagePaths.first { $0.hasSuffix("/IOMobileFramebuffer") })
            let symbols = try #require(try resolver?.symbols(inImage: image))
            #expect(symbols.values.contains { $0.source == .exportTrie })
            resolver = nil
            #expect(try mappings(in: directory) == 0,
                    "A finished lookup must release the cache before the caller drains its outer pool")
        }
    }
    #endif
}

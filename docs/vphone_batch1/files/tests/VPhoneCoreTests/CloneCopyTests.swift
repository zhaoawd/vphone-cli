@testable import VPhoneCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct CloneCopyTests {
    private let runtimeNames: Set<String> = [".vphone-runtime.json", "vphone.sock"]

    private func root() throws -> URL {
        // Keep Unix socket paths below sockaddr_un's platform-dependent limit.
        let url = URL(fileURLWithPath: "/tmp/vp-b1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return url
    }
    private func populate(_ source: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: source, withIntermediateDirectories: false)
        for name in ["Disk.img", "config.plist", "nvram.bin", "SEPStorage", "ABC123.shsh",
                     "udid-prediction.txt", ".vphone-runtime.json", "vphone.sock"] {
            try Data(name.utf8).write(to: source.appendingPathComponent(name))
        }
        let nested = source.appendingPathComponent("payload")
        try fm.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data([0xAF]).write(to: nested.appendingPathComponent("vphone.sock"))
    }
    private func checkCopy(_ source: URL, _ destination: URL) throws {
        for name in ["Disk.img", "config.plist", "nvram.bin", "SEPStorage", "ABC123.shsh",
                     "udid-prediction.txt", "payload/vphone.sock"] {
            #expect(try Data(contentsOf: destination.appendingPathComponent(name)) ==
                    Data(contentsOf: source.appendingPathComponent(name)))
        }
        for name in runtimeNames {
            #expect(try !VPhoneCloneCopy.exists(at: destination.appendingPathComponent(name)))
        }
    }

    @Test func forcedNonAPFSFallbackPreservesPersistentState() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        let destination = dir.appendingPathComponent("copy")
        try populate(source)
        var attempts = 0
        try VPhoneCloneCopy.copy(from: source, to: destination, excludingRootNames: runtimeNames,
                                cloneDirectory: { _, _ in attempts += 1; return ENOTSUP })
        #expect(attempts == 1)
        try checkCopy(source, destination)
        for name in runtimeNames {
            #expect(try Data(contentsOf: source.appendingPathComponent(name)) == Data(name.utf8))
        }
    }

    @Test func successfulNativeBranchCleansOnlyDestinationRuntime() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        let destination = dir.appendingPathComponent("copy")
        try populate(source)
        // Exercises the successful branch, NOT actual APFS clonefile semantics.
        var copyError: Error?
        try VPhoneCloneCopy.copy(from: source, to: destination, excludingRootNames: runtimeNames,
                                cloneDirectory: { src, dst in
            do { try FileManager.default.copyItem(at: src, to: dst); return 0 }
            catch { copyError = error; return EIO }
        })
        #expect(copyError == nil)
        try checkCopy(source, destination)
        #expect(try VPhoneCloneCopy.exists(at: source.appendingPathComponent("vphone.sock")))
    }

    @Test func existingDestinationIsNeverRemoved() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        let destination = dir.appendingPathComponent("copy")
        try populate(source)
        try Data("belongs to somebody else".utf8).write(to: destination)
        var called = false
        #expect(throws: (any Error).self) {
            try VPhoneCloneCopy.copy(from: source, to: destination, excludingRootNames: runtimeNames,
                                    cloneDirectory: { _, _ in called = true; return 0 })
        }
        #expect(!called)
        #expect(try Data(contentsOf: destination) == Data("belongs to somebody else".utf8))
    }

    @Test func EEXISTAfterCheckDoesNotDeleteCompetingOutput() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        let destination = dir.appendingPathComponent("copy")
        try populate(source)
        #expect(throws: (any Error).self) {
            try VPhoneCloneCopy.copy(from: source, to: destination, excludingRootNames: runtimeNames,
                                    cloneDirectory: { _, dst in
                do { try Data("rival".utf8).write(to: dst) }
                catch { Issue.record("Could not create race fixture: \(error)") }
                return EEXIST
            })
        }
        #expect(try Data(contentsOf: destination) == Data("rival".utf8))
    }

    @Test func danglingDestinationSymlinkIsAConflict() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        let destination = dir.appendingPathComponent("copy")
        let missing = dir.appendingPathComponent("missing")
        try populate(source)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: missing)
        #expect(throws: (any Error).self) {
            try VPhoneCloneCopy.copy(from: source, to: destination, excludingRootNames: runtimeNames)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func removesOnlyOwnedPartialOutputBeforeFallback() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        let destination = dir.appendingPathComponent("copy")
        try populate(source)
        try VPhoneCloneCopy.copy(from: source, to: destination, excludingRootNames: runtimeNames,
                                cloneDirectory: { _, dst in
            do {
                try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: false)
                try Data([0]).write(to: dst.appendingPathComponent("partial"))
            } catch { Issue.record("Could not create partial fixture: \(error)") }
            return ENOTSUP
        })
        try checkCopy(source, destination)
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("partial").path))
    }

    @Test func omitsRealUnixSocketBeforeFallbackCopy() throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        let destination = dir.appendingPathComponent("copy")
        try populate(source)
        let path = source.appendingPathComponent("vphone.sock").path
        try FileManager.default.removeItem(atPath: path)
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        #expect(fd >= 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let bytes = Array(path.utf8CString)
        #expect(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.copyMemory(from: source)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(result == 0)
        guard result == 0 else { return }
        try VPhoneCloneCopy.copy(from: source, to: destination, excludingRootNames: runtimeNames,
                                cloneDirectory: { _, _ in ENOTSUP })
        try checkCopy(source, destination)
        #expect(try VPhoneCloneCopy.exists(at: source.appendingPathComponent("vphone.sock")))
    }
}

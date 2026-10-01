import Darwin
import Foundation
import Testing
@testable import VPhoneCore

/// Leftovers of a process that ended without its cleanup: a runtime record
/// that names an exited pid, and a control socket nobody listens on.
struct StaleRuntimeStateTests {
    private func shortDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("vs-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func exitedPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func writeRecord(_ directory: URL, pid: pid_t, operation: String) throws {
        try VPhoneVMRuntimeState(
            bundleIdentifier: "1:2", bundlePath: directory.path, pid: pid, instanceID: "I", startedAt: Date(),
            operation: operation).write(in: directory)
    }

    @Test func recordOfAnExitedProcessDoesNotNameAHolderOrBlockTheLock() throws {
        let directory = try shortDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pid = try exitedPID()
        #expect(VPhoneProcessInfo.identity(of: pid) == nil)
        try writeRecord(directory, pid: pid, operation: VPhoneVMOperation.createCheckpoint)
        let guardian = VPhoneBundleGuard()
        #expect(!guardian.holderDetail(directory: directory).contains("pid \(pid)"))
        try writeRecord(directory, pid: getpid(), operation: VPhoneVMOperation.createCheckpoint)
        #expect(guardian.holderDetail(directory: directory).contains("pid \(getpid())"))
        // The lock decides occupancy: the next holder takes it and replaces the record.
        try writeRecord(directory, pid: pid, operation: VPhoneVMOperation.createCheckpoint)
        let lock = try VPhoneVMLock(directory: directory, operation: VPhoneVMOperation.boot)
        #expect(VPhoneVMRuntimeState.read(in: directory)?.operation == VPhoneVMOperation.boot)
        withExtendedLifetime(lock) {}
    }

    @Test func removeRecordDeletesOnlyThisProcessesRecordForTheOperation() throws {
        let directory = try shortDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(VPhoneVMRuntimeState.filename)
        try writeRecord(directory, pid: getpid() + 1, operation: VPhoneVMOperation.createCheckpoint)
        #expect(!VPhoneVMLock.removeRecord(directory: directory, operation: VPhoneVMOperation.createCheckpoint))
        try writeRecord(directory, pid: getpid(), operation: VPhoneVMOperation.fwPatch)
        #expect(!VPhoneVMLock.removeRecord(directory: directory, operation: VPhoneVMOperation.createCheckpoint))
        try writeRecord(directory, pid: getpid(), operation: VPhoneVMOperation.createCheckpoint)
        #expect(VPhoneVMLock.removeRecord(directory: directory, operation: VPhoneVMOperation.createCheckpoint))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!VPhoneVMLock.removeRecord(directory: directory, operation: VPhoneVMOperation.createCheckpoint))
    }

    @Test func staleSocketIsDeletedAndALiveOneIsKept() throws {
        let directory = try shortDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("vphone.sock").path
        func bind() throws -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: Array(path.utf8))
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            try #require(bound == 0 && listen(fd, 1) == 0)
            return fd
        }

        let listener = try bind()
        #expect(!HostControlClient.removeStaleSocket(at: path))
        #expect(FileManager.default.fileExists(atPath: path))
        // The listener ends without unlinking, as a SIGKILLed boot process does.
        close(listener)
        #expect(HostControlClient.removeStaleSocket(at: path))
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!HostControlClient.removeStaleSocket(at: path))

        try Data("not a socket".utf8).write(to: URL(fileURLWithPath: path))
        #expect(!HostControlClient.removeStaleSocket(at: path))
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

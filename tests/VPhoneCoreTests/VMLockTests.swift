import Darwin
import Foundation
import Testing
@testable import VPhoneCore

struct VMLockTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func diagnosticFailureDoesNotReleaseLock() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(VPhoneVMRuntimeState.filename), withIntermediateDirectories: true)
        let lock = try VPhoneVMLock(directory: dir, operation: "export")
        defer { withExtendedLifetime(lock) {} }
        #expect(throws: (any Error).self) { try VPhoneVMLock(directory: dir, operation: "boot") }
    }

    @Test func exportsReadOnlyBundle() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = root.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        try VPhoneVirtualMachineManifest(cpuCount: 2, memorySize: 1024 * 1024, romImages: nil)
            .write(to: vm.appendingPathComponent("config.plist"))
        try Data("test disk".utf8).write(to: vm.appendingPathComponent("Disk.img"))
        #expect(chmod(vm.path, 0o555) == 0)
        defer { chmod(vm.path, 0o755) }
        let output = root.appendingPathComponent("out.tar")
        try VPhoneBundleOps.export(bundleNamed: "vm", to: output, includeIPSW: false, in: VPhoneLibrary(root: root))
        #expect((try Data(contentsOf: output)).count > 0)
        #expect(!FileManager.default.fileExists(atPath: vm.appendingPathComponent(VPhoneVMRuntimeState.filename).path))
    }

    @Test func excludesAliasesAndSurvivesRecordRemoval() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        let lock = try VPhoneVMLock(directory: dir, operation: "boot")
        defer { withExtendedLifetime(lock) {} }
        #expect(throws: (any Error).self) { try VPhoneVMLock(directory: alias, operation: "boot") }
        try FileManager.default.removeItem(at: dir.appendingPathComponent(VPhoneVMRuntimeState.filename))
        #expect(throws: (any Error).self) { try VPhoneVMLock(directory: dir, operation: "boot") }
    }

    @Test func releasesAndReplacesStaleRecord() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = dir.appendingPathComponent(VPhoneVMRuntimeState.filename)
        try Data("stale invalid record".utf8).write(to: record)
        var first: VPhoneVMLock? = try VPhoneVMLock(directory: dir, operation: "dfu")
        let firstID = first!.state.instanceID
        #expect(first!.state.pid == getpid())
        #expect(first!.state.operation == "dfu")
        first = nil
        let second = try VPhoneVMLock(directory: dir, operation: "boot")
        #expect(second.state.instanceID != firstID)
        #expect(second.state.bundleIdentifier.contains(":"))
        withExtendedLifetime(second) {}
    }

    @Test func differentVMsDoNotBlockAndDescriptorsCloseOnExec() throws {
        let a = try directory(), b = try directory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let first = try VPhoneVMLock(directory: a, operation: "boot")
        let second = try VPhoneVMLock(directory: b, operation: "cfw")
        #expect(first.state.bundleIdentifier != second.state.bundleIdentifier)
        #expect(fcntl(first.descriptor, F_GETFD) & FD_CLOEXEC != 0)
        withExtendedLifetime((first, second)) {}
    }

    @Test func pythonAndSwiftUseTheSameKernelLock() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = try VPhoneVMLock(directory: dir, operation: "boot")
        defer { withExtendedLifetime(lock) {} }
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/env"),
            ["python3", "-c", "import os,fcntl,sys; f=os.open(sys.argv[1],os.O_RDONLY); fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)", dir.path])
        #expect(result.exitCode != 0)
        #expect(result.stderr.contains("BlockingIOError"))
    }
    @Test func offlineBundleOperationsRejectAnActiveOwner() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = root.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        try VPhoneVirtualMachineManifest(cpuCount: 2, memorySize: 1024 * 1024, romImages: nil).write(to: vm.appendingPathComponent("config.plist"))
        let library = VPhoneLibrary(root: root)
        let lock = try VPhoneVMLock(directory: vm, operation: "boot")
        defer { withExtendedLifetime(lock) {} }
        #expect(throws: (any Error).self) { try VPhoneBundleOps.delete(bundleNamed: "vm", in: library) }
        #expect(throws: (any Error).self) { try VPhoneBundleOps.rename(bundleNamed: "vm", to: "renamed", in: library) }
        #expect(throws: (any Error).self) { try VPhoneBundleOps.clone(bundleNamed: "vm", to: "clone", in: library) }
        #expect(throws: (any Error).self) {
            try VPhoneBundleOps.updateConfig(bundleNamed: "vm", in: library, cpuCount: 4, memoryMB: nil)
        }
        #expect(throws: (any Error).self) {
            try VPhoneBundleOps.export(bundleNamed: "vm", to: root.appendingPathComponent("out.tgz"), includeIPSW: false, in: library)
        }
        #expect(FileManager.default.fileExists(atPath: vm.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("out.tgz").path))
    }

    @Test func pythonOwnerExcludesSwiftUntilProcessExit() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = ["python3", "-c", "import os,fcntl,sys,time; f=os.open(sys.argv[1],os.O_RDONLY); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); time.sleep(30)", dir.path]
        let pipe = Pipe()
        child.standardOutput = pipe
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        #expect(!pipe.fileHandleForReading.availableData.isEmpty)
        #expect(throws: (any Error).self) { try VPhoneVMLock(directory: dir, operation: "boot") }
        child.terminate()
        child.waitUntilExit()
        let recovered = try VPhoneVMLock(directory: dir, operation: "boot")
        withExtendedLifetime(recovered) {}
    }

    @Test func ordinaryChildDoesNotRetainSwiftLock() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var owner: VPhoneVMLock? = try VPhoneVMLock(directory: dir, operation: "boot")
        #expect(owner != nil)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["2"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        owner = nil
        let replacement = try VPhoneVMLock(directory: dir, operation: "boot")
        #expect(child.isRunning)
        withExtendedLifetime(replacement) {}
    }

    @Test func releaseUnlocksEvenWhenDescriptorWasDuplicated() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var owner: VPhoneVMLock? = try VPhoneVMLock(directory: dir, operation: "boot")
        let duplicate = dup(owner!.descriptor)
        defer { close(duplicate) }
        owner = nil
        let replacement = try VPhoneVMLock(directory: dir, operation: "boot")
        withExtendedLifetime(replacement) {}
    }

}

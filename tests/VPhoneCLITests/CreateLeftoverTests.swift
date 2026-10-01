import Darwin
import Foundation
import Testing
@testable import VPhoneCore
@testable import vphone_cli

/// B4 acceptance (2026-10-01): after a successful create the bundle kept
/// `vphone.sock` and a `.vphone-runtime.json` naming the exited vm create.
/// No VM is started; a Python stand-in plays the VM process.
struct CreateLeftoverTests {
    /// A short directory: `sockaddr_un.sun_path` holds 104 bytes.
    private struct ShortBundle {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("vs-\(UUID().uuidString.prefix(8))")
        var bundle: URL { root.appendingPathComponent("vm") }
        var socket: URL { bundle.appendingPathComponent("vphone.sock") }

        init() throws { try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    /// Like the boot process: listens on vphone.sock; on SIGINT shuts down for
    /// `seconds` (the guest power-off wait), then deletes the socket and exits 0.
    private func standInVM(_ socket: URL, shutdownSeconds: Double) throws -> VPhoneManagedProcess {
        let script = """
        import os, signal, socket, sys, time
        path = sys.argv[1]
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(path)
        listener.listen(4)
        def stop(*_):
            time.sleep(float(sys.argv[2]))
            listener.close()
            os.unlink(path)
            os._exit(0)
        signal.signal(signal.SIGINT, stop)
        print("listening", flush=True)
        while True:
            time.sleep(0.05)
        """
        let child = VPhoneManagedProcess(
            URL(fileURLWithPath: "/usr/bin/env"), ["python3", "-c", script, socket.path, "\(shutdownSeconds)"], echo: false)
        try child.start()
        guard case .matched = child.waitForOutput(matching: "listening", timeout: 10) else {
            child.terminate()
            throw CancellationError()
        }
        return child
    }

    @Test func vmChildGetsTheShutdownGraceAndDeletesItsSocket() throws {
        let w = try ShortBundle(); defer { w.cleanup() }
        #expect(VPhoneCreateOrchestrator.vmStopGrace >= VPhoneShutdownPolicy.gracefulTimeout)
        let child = try standInVM(w.socket, shutdownSeconds: 3)
        try VPhoneCreateOrchestrator.withStoppedChild(child, "stand-in VM", timeout: 30) {}
        #expect(child.waitUntilExit() == 0, "the stand-in was killed during its shutdown")
        #expect(!FileManager.default.fileExists(atPath: w.socket.path))
    }

    /// The former 2 s grace: SIGKILL during the shutdown leaves the socket
    /// behind; the stage then deletes it because nothing listens on it.
    @Test func socketOfAKilledVMChildIsDeletedAfterTheStage() throws {
        let w = try ShortBundle(); defer { w.cleanup() }
        let child = try standInVM(w.socket, shutdownSeconds: 3)
        try VPhoneCreateOrchestrator.withStoppedChild(child, "stand-in VM", timeout: 30, grace: 2) {}
        #expect(child.waitUntilExit() != 0)
        var info = stat()
        #expect(lstat(w.socket.path, &info) == 0 && info.st_mode & S_IFMT == S_IFSOCK)
        VPhoneCreateOrchestrator.removeStaleControlSocket(w.bundle)
        #expect(!FileManager.default.fileExists(atPath: w.socket.path))
    }

    @Test func liveSocketIsNotDeleted() throws {
        let w = try ShortBundle(); defer { w.cleanup() }
        let child = try standInVM(w.socket, shutdownSeconds: 0)
        defer { child.terminate(); _ = child.waitUntilExit() }
        VPhoneCreateOrchestrator.removeStaleControlSocket(w.bundle)
        #expect(FileManager.default.fileExists(atPath: w.socket.path))
    }

    /// A record left by a process that ended without deleting it (SIGKILL,
    /// forced exit) is not reported as the holder.
    @Test func recoveryHintIgnoresARecordOfAnExitedOrReusedPid() throws {
        let w = try ShortBundle(); defer { w.cleanup() }
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        func write(pid: pid_t, startedAt: Date) throws {
            try VPhoneVMRuntimeState(
                bundleIdentifier: "1:2", bundlePath: w.bundle.path, pid: pid, instanceID: "I", startedAt: startedAt,
                operation: VPhoneVMOperation.createCheckpoint).write(in: w.bundle)
        }
        try write(pid: exited.processIdentifier, startedAt: Date())
        #expect(VPhoneCreateOrchestrator.liveHolder(w.bundle) == nil)
        try write(pid: getpid(), startedAt: Date())
        #expect(VPhoneCreateOrchestrator.liveHolder(w.bundle) == "pid \(getpid()) running operation \"create-checkpoint\"")
        // The pid runs, but the process started after the record was written.
        try write(pid: getpid(), startedAt: Date(timeIntervalSince1970: 1_000))
        #expect(VPhoneCreateOrchestrator.liveHolder(w.bundle) == nil)
        #expect(VPhoneCreateOrchestrator.liveHolder(w.bundle.appendingPathComponent("missing")) == nil)
    }
}

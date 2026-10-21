import Darwin
import Foundation
import Testing
@testable import VPhoneCore

/// Telling a running machine from a stopped one before its state files are
/// copied or replaced.
struct BundleActivityTests {
    private func makeBundle() throws -> (root: URL, bundle: VPhoneBundle) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let rom = root.appendingPathComponent("rom.bin")
        try Data([0xAA]).write(to: rom)
        let bundle = try VPhoneBundleOps.create(
            .init(name: "vm", cpuCount: 2, memoryMB: 1024, diskSizeGB: 1, romSource: rom, sepromSource: rom),
            in: VPhoneLibrary(root: root)
        )
        try Data([1, 2, 3]).write(to: bundle.url.appendingPathComponent("nvram.bin"))
        return (root, bundle)
    }

    private func isRunning(_ bundle: VPhoneBundle) -> Bool {
        (try? VPhoneBundleActivity.requireStopped(bundle)) == nil
    }

    @Test func findsThisProcessHoldingAnOpenFile() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = bundle.url.appendingPathComponent("Disk.img")

        #expect(!VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
        let fd = open(disk.path, O_RDONLY)
        #expect(fd >= 0)
        #expect(VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
        close(fd)
        #expect(!VPhoneBundleActivity.processesHolding([disk]).contains(getpid()))
    }

    @Test func findsAHolderOnADeviceNumberedPastInt32Max() throws {
        let null = URL(fileURLWithPath: "/dev/null")
        let fd = open(null.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(VPhoneBundleActivity.processesHolding([null]).contains(getpid()))
    }

    @Test func aMissingFileHasNoHolders() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(VPhoneBundleActivity.processesHolding([missing]).isEmpty)
    }

    @Test func aStoppedMachinePassesAndAHeldStateFileRefuses() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }

        try VPhoneBundleActivity.requireStopped(bundle)
        #expect(!isRunning(bundle))

        for name in ["Disk.img", "SEPStorage", "nvram.bin"] {
            let fd = open(bundle.url.appendingPathComponent(name).path, O_RDONLY)
            #expect(fd >= 0)
            #expect(isRunning(bundle))
            #expect(throws: VPhoneBundleActivityError.running(name: "vm", pids: [getpid()])) {
                try VPhoneBundleActivity.requireStopped(bundle)
            }
            close(fd)
        }
    }

    /// A socket bound and listening at the bundle's `vphone.sock`.
    private func listenAtControlSocket(of bundle: VPhoneBundle) throws -> (fd: Int32, path: String) {
        let path = bundle.url.appendingPathComponent("vphone.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        let bound = try VPhoneUnixSocket.withAddressablePath(path) { addressable in
            try #require(addressable.utf8CString.count <= VPhoneUnixSocket.maximumPathLength)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                for (index, byte) in addressable.utf8.enumerated() {
                    buffer[index] = byte
                }
            }
            return withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        return (fd, path)
    }

    @Test func aListeningControlSocketCountsAsRunningAndAStaleOneDoesNot() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let (fd, path) = try listenAtControlSocket(of: bundle)
        #expect(isRunning(bundle))

        close(fd)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!isRunning(bundle))
    }

    @Test func aLongControlSocketPathCanBindConnectAndDetectAStaleSocket() throws {
        let (root, original) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let longURL = root.appendingPathComponent(String(repeating: "long-path-", count: 16))
        try FileManager.default.moveItem(at: original.url, to: longURL)
        let bundle = VPhoneBundle(url: longURL, manifest: original.manifest)
        #expect(bundle.url.appendingPathComponent("vphone.sock").path.utf8.count >= VPhoneUnixSocket.maximumPathLength)
        let (fd, _) = try listenAtControlSocket(of: bundle)
        #expect(isRunning(bundle))
        close(fd)
        #expect(!isRunning(bundle))
    }

    @Test func aControlSocketThisUserMayNotConnectToCountsAsRunning() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let (fd, path) = try listenAtControlSocket(of: bundle)
        defer { close(fd) }

        #expect(chmod(path, 0) == 0)
        defer { chmod(path, 0o755) }
        #expect(throws: VPhoneBundleActivityError.running(name: "vm", pids: [])) {
            try VPhoneBundleActivity.requireStopped(bundle)
        }
    }

    // MARK: - Waiting for readers

    private static let meter = VPhoneProcessHolder(
        pid: 900,
        executablePath: "/Applications/vphone-launchpad.app/Contents/MacOS/vphone-launchpad"
    )
    private static let vm = VPhoneProcessHolder(
        pid: 410,
        executablePath: "/opt/VPhone.bundle/Contents/MacOS/vphone-vm"
    )
    private static let service = VPhoneProcessHolder(
        pid: 412,
        executablePath: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
            + "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
    )

    private func decide(
        wait: TimeInterval,
        _ answers: [[VPhoneProcessHolder]],
        socketIsLive: Bool = false
    ) -> (error: VPhoneBundleActivityError?, sleeps: [TimeInterval], probes: Int, socketProbes: Int) {
        var probes = 0
        var socketProbes = 0
        var sleeps: [TimeInterval] = []
        var error: VPhoneBundleActivityError?
        do {
            try VPhoneBundleActivity.requireStopped(
                name: "tpl",
                waitingForReaders: wait,
                holders: {
                    defer { probes += 1 }
                    return answers[min(probes, answers.count - 1)]
                },
                socketIsLive: {
                    socketProbes += 1
                    return socketIsLive
                },
                sleep: { sleeps.append($0) }
            )
        } catch let refusal as VPhoneBundleActivityError {
            error = refusal
        } catch {
            Issue.record(error)
        }
        return (error, sleeps, probes, socketProbes)
    }

    @Test func aReaderThatClosesWithinTheWaitLetsACloneThrough() {
        let found = decide(wait: 2, [[Self.meter], [Self.meter], []])
        #expect(found.error == nil)
        #expect(found.sleeps == [0.1, 0.1])
        #expect(found.probes == 3)
    }

    @Test func aReaderThatStaysRefusesOnceTheWaitIsOver() {
        let found = decide(wait: 2, [[Self.meter]])
        #expect(found.error == VPhoneBundleActivityError.running(name: "tpl", holders: [Self.meter]))
        #expect(found.sleeps.count == 20)
        #expect(found.probes == 21)
    }

    @Test func aVMHoldingTheFilesRefusesAtOnceWithOrWithoutReaders() {
        for holders in [[Self.vm], [Self.service], [Self.meter, Self.service]] {
            let found = decide(wait: 2, [holders, []])
            #expect(found.error == VPhoneBundleActivityError.running(name: "tpl", holders: holders))
            #expect(found.sleeps.isEmpty)
        }
        let starting = decide(wait: 2, [[Self.meter], [Self.meter, Self.vm], []])
        #expect(starting.error == VPhoneBundleActivityError.running(name: "tpl", holders: [Self.meter, Self.vm]))
        #expect(starting.sleeps.count == 1)
    }

    @Test func aLiveControlSocketRefusesAtOnce() {
        let held = decide(wait: 2, [[Self.meter], []], socketIsLive: true)
        #expect(held.error == VPhoneBundleActivityError.running(name: "tpl", holders: [Self.meter]))
        #expect(held.sleeps.isEmpty)
        let free = decide(wait: 2, [[]], socketIsLive: true)
        #expect(free.error == VPhoneBundleActivityError.running(name: "tpl", holders: []))
    }

    @Test func withoutAWaitAnyHolderRefusesAsBefore() {
        let found = decide(wait: 0, [[Self.meter], []])
        #expect(found.error == VPhoneBundleActivityError.running(name: "tpl", holders: [Self.meter]))
        #expect(found.sleeps.isEmpty)
        #expect(found.socketProbes == 0)
        #expect(decide(wait: 0, [[]]).error == nil)
    }

    @Test func aHeldStateFileIsWaitedForAndThenRefused() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let fd = open(bundle.url.appendingPathComponent("Disk.img").path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }
        let began = Date()
        #expect(throws: VPhoneBundleActivityError.running(name: "vm", pids: [getpid()])) {
            try VPhoneBundleActivity.requireStopped(bundle, waitingForReaders: 0.3)
        }
        #expect(Date().timeIntervalSince(began) >= 0.25)
    }

    @Test func aControlSocketPathThatIsNotASocketCountsAsStopped() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: bundle.url.appendingPathComponent("vphone.sock"))
        #expect(!isRunning(bundle))
    }
}

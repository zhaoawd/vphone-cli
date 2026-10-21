import Darwin
import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

struct DiskUsageTests {
    @Test func folderPreflightRunsOnceUnderALeaseAndFileAccessIsRechecked() async throws {
        let temp = try LaunchpadTemporaryDirectory("disk-meter-folder-lease")
        let folder = temp.url.appendingPathComponent("vm")
        let disk = try file(in: folder)
        try Data(repeating: 0x44, count: 4096).write(to: folder.appendingPathComponent("other"))
        let preflights = Calls(), checks = Calls(), mapped = Calls()
        let meter = VPhoneLaunchpadDiskMeter(mapper: { path, deadline in
            mapped.append(path)
            return VPhoneLaunchpadDiskExtents.map(path, deadline: deadline)
        })
        _ = await meter.measure([.init(path: folder.path)], mayOpenNow: { path in
            preflights.append(path)
            let fd = open(path, O_RDONLY | O_DIRECTORY)
            #expect(fd >= 0)
            if fd >= 0 {
                #expect(flock(fd, LOCK_EX | LOCK_NB) != 0)
                close(fd)
            }
            return true
        })
        #expect(preflights.count == 1)
        #expect(mapped.count == 2)
        // Change both files so the second pass must consult the local state
        // again immediately before each map, even after a successful preflight.
        try Data(repeating: 0x45, count: 4096).write(to: disk)
        try Data(repeating: 0x46, count: 4096).write(to: folder.appendingPathComponent("other"))
        _ = await meter.measure([.init(path: folder.path)], mayOpenNow: { _ in true }, mayMapNow: { path, _ in
            checks.append(path)
            return checks.count == 1
        })
        #expect(checks.count == 2)
        #expect(mapped.count == 3)
    }

    @Test func mappingBudgetDoesNotMakeLaterFoldersAllocationUnknown() async throws {
        let temp = try LaunchpadTemporaryDirectory("disk-meter-inventory-budget")
        let a = temp.url.appendingPathComponent("a"), b = temp.url.appendingPathComponent("b")
        _ = try file(in: a)
        _ = try file(in: b)
        let meter = VPhoneLaunchpadDiskMeter(budget: .zero)
        let result = await meter.measure([a, b].map { .init(path: $0.path) })
        for path in [a.path, b.path] {
            #expect(result[path]?.allocationKnown == true)
            #expect(result[path]?.allocated ?? 0 > 0)
            #expect(result[path]?.exclusive == nil)
        }
    }

    @Test func selectedRealVMMeasurementProbe() async throws {
        guard let root = ProcessInfo.processInfo.environment["VPHONE_METER_PROBE_ROOT"],
              let output = ProcessInfo.processInfo.environment["VPHONE_METER_PROBE_OUT"] else { return }
        let folders = ["base", "target"].map { VPhoneLaunchpadDiskMeter.Folder(path: root + "/" + $0) }
        var records: [[String: String]] = []
        for holders in [false, true] {
            let clock = ContinuousClock()
            let start = clock.now
            let calls = Calls()
            let meter = VPhoneLaunchpadDiskMeter(budget: .seconds(2), mapper: { path, deadline in
                calls.append(path)
                return VPhoneLaunchpadDiskExtents.map(path, deadline: deadline)
            })
            let probe: (@Sendable (String) async -> Bool)? = holders ? { @Sendable path in
                let disk = URL(fileURLWithPath: path).appendingPathComponent("Disk.img")
                return (try? VPhoneLsof.holders(of: disk).isEmpty) == true
            } : nil
            let result = await meter.measure(folders, mayOpenNow: probe)
            records.append(["holderProbe": String(holders), "duration": String(describing: clock.now - start),
                            "mappedFiles": String(calls.count), "result": String(describing: result)])
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
    }

    @Test func accessRefusesEveryBusyOrUnknownCondition() {
        #expect(VPhoneLaunchpadDiskAccess().mayOpen)
        #expect(!VPhoneLaunchpadDiskAccess(isLaunched: true).mayOpen)
        #expect(!VPhoneLaunchpadDiskAccess(isHeld: true).mayOpen)
        #expect(!VPhoneLaunchpadDiskAccess(isBusy: true).mayOpen)
        #expect(!VPhoneLaunchpadDiskAccess(isLibraryBusy: true).mayOpen)
        for current in [false, true] {
            for last in [false, true] {
                for allowed in [false, true] {
                    for time in [false, true] {
                        let expected: VPhoneLaunchpadDiskMeter.FileUse = current ? .current
                            : !allowed ? (last ? .last : .unknown) : time ? .map : .unknown
                        #expect(VPhoneLaunchpadDiskMeter.use(isCurrent: current, hasLast: last, mayOpen: allowed, hasTime: time) == expected)
                    }
                }
            }
        }
    }

    @Test func extentSweepCountsEachOwnerOnceAndKeepsDevicesSeparate() {
        typealias Extents = VPhoneLaunchpadDiskExtents
        let a = Extents(device: 1, ranges: [.init(start: 0, end: 100), .init(start: 50, end: 120)])
        let b = Extents(device: 1, ranges: [.init(start: 40, end: 80)])
        let c = Extents(device: 2, ranges: [.init(start: 0, end: 100)])
        #expect(a.bytes == 120)
        #expect(Extents.exclusiveBytes(of: [[a, a], [b], [c]]) == [80, 0, 100])
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func append(_ path: String) { lock.withLock { paths.append(path) } }
        var count: Int { lock.withLock { paths.count } }
    }

    private func file(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("Disk.img")
        let fd = open(file.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        try #require(fd >= 0)
        defer { close(fd) }
        try #require(ftruncate(fd, 64 << 20) == 0)
        let bytes = Data(repeating: 0x43, count: 1 << 20)
        try #require(bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) } == bytes.count)
        try #require(fcntl(fd, F_FULLFSYNC) == 0)
        return file
    }

    @Test func realClonesShareExtentsAndUnchangedOrRefusedPassesDoNotOpenFiles() async throws {
        let temp = try LaunchpadTemporaryDirectory("disk-meter")
        let a = temp.url.appendingPathComponent("a"), b = temp.url.appendingPathComponent("b")
        let disk = try file(in: a)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
        let clone = b.appendingPathComponent("Disk.img")
        try #require(clonefile(disk.path, clone.path, 0) == 0)
        let calls = Calls()
        let meter = VPhoneLaunchpadDiskMeter(mapper: { path, deadline in
            calls.append(path)
            return VPhoneLaunchpadDiskExtents.map(path, deadline: deadline)
        })
        let folders = [a, b].map { VPhoneLaunchpadDiskMeter.Folder(path: $0.path) }
        let first = await meter.measure(folders)
        #expect(calls.count == 2)
        #expect(first[a.path]?.exclusive == 0)
        #expect(first[b.path]?.exclusive == 0)
        #expect(first[a.path]?.allocated ?? 0 > 0)
        _ = await meter.measure(folders)
        #expect(calls.count == 2)
        let writer = try FileHandle(forWritingTo: disk)
        try writer.write(contentsOf: Data([0x44]))
        try writer.synchronize()
        try writer.close()
        let refused = await meter.measure([.init(path: a.path, mayOpen: false), folders[1]])
        #expect(calls.count == 2)
        #expect(refused[a.path]?.isCurrent == false)
        #expect(refused[a.path]?.exclusive == nil)
        let next = await meter.measure(folders)
        #expect(calls.count == 3)
        #expect(next[a.path]?.exclusive ?? 0 > 0)
        #expect(next[a.path]?.isCurrent == true)
    }

    @Test func lastMomentRefusalExclusiveLockAndPendingTransactionNeverInvokeTheMapper() async throws {
        let temp = try LaunchpadTemporaryDirectory("disk-meter-lock")
        let folder = temp.url.appendingPathComponent("vm")
        _ = try file(in: folder)
        let calls = Calls()
        let meter = VPhoneLaunchpadDiskMeter(mapper: { path, _ in calls.append(path); return .failure(.unsupported) })
        let folders = [VPhoneLaunchpadDiskMeter.Folder(path: folder.path)]
        let refused = await meter.measure(folders, mayOpenNow: { _ in false })
        #expect(calls.count == 0)
        #expect(refused[folder.path]?.exclusive == nil)
        do {
            let held = try VPhoneVMLock(directory: folder, operation: VPhoneVMOperation.boot)
            _ = await meter.measure(folders)
            #expect(calls.count == 0)
            withExtendedLifetime(held) {}
        }
        let pending = folder.appendingPathComponent(".cfw_disk.pending")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        _ = await meter.measure(folders)
        #expect(calls.count == 0)
    }

    @Test func unsupportedMapsAndExpiredBudgetAreUnknown() async throws {
        let temp = try LaunchpadTemporaryDirectory("disk-meter-unknown")
        let folder = temp.url.appendingPathComponent("vm")
        _ = try file(in: folder)
        let calls = Calls()
        let meter = VPhoneLaunchpadDiskMeter(budget: .zero, mapper: { path, _ in calls.append(path); return .failure(.unsupported) })
        let result = await meter.measure([.init(path: folder.path)])
        #expect(calls.count == 0)
        #expect(result[folder.path]?.exclusive == nil)
        let unsupported = VPhoneLaunchpadDiskMeter(mapper: { _, _ in .failure(.unsupported) })
        let other = await unsupported.measure([.init(path: folder.path)])
        #expect(other[folder.path]?.exclusive == nil)
    }

    @Test func missingAndUnreadableFoldersAreUnknownAndLinksAreNeverFollowed() async throws {
        let temp = try LaunchpadTemporaryDirectory("disk-meter-files")
        let folder = temp.url.appendingPathComponent("vm")
        let disk = try file(in: folder)
        let linked = temp.url.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("disk"), withDestinationURL: disk)
        let meter = VPhoneLaunchpadDiskMeter()
        let missing = temp.url.appendingPathComponent("missing")
        let result = await meter.measure([.init(path: missing.path), .init(path: linked.path)])
        #expect(result[missing.path]?.allocationKnown == false)
        #expect(result[missing.path]?.exclusive == nil)
        #expect(result[linked.path]?.allocated == 0)
        #expect(chmod(folder.path, 0) == 0)
        defer { chmod(folder.path, 0o700) }
        let unreadable = await meter.measure([.init(path: folder.path)])
        #expect(unreadable[folder.path]?.allocationKnown == false)
        #expect(unreadable[folder.path]?.exclusive == nil)
    }
}

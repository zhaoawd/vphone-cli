@testable import VPhoneCore
import Darwin
import Foundation
import Testing

/// The bundle lock and the cooperative DFU verification are the two ends of the
/// B4 occupancy model: exclusive operations take the lock, `restore` verifies
/// the holder. Both are exercised here.
struct BundleGuardTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("guard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fakeROM() throws -> URL {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        try Data([0xAA, 0xBB, 0xCC]).write(to: f)
        return f
    }

    private func record(_ operation: String, pid: Int32) -> VPhoneVMRuntimeState {
        VPhoneVMRuntimeState(
            bundleIdentifier: "1:2", bundlePath: "/vm", pid: pid,
            instanceID: "INSTANCE", startedAt: Date(), operation: operation)
    }

    // MARK: withBundleLock

    @Test func withBundleLockRunsBodyAndReturnsValue() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let value = try VPhoneBundleGuard.withBundleLock(
            directory: dir, operation: VPhoneVMOperation.config) { _ in 41 + 1 }
        #expect(value == 42)
    }

    @Test func nestedBundleLockOnSameDirectoryIsBusy() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // flock is per open file description, so a second acquisition on the same
        // directory fails even from the same process.
        #expect(throws: VPhoneBundleGuardError.self) {
            try VPhoneBundleGuard.withBundleLock(
                directory: dir, operation: VPhoneVMOperation.config
            ) { _ in
                try VPhoneBundleGuard.withBundleLock(
                    directory: dir, operation: VPhoneVMOperation.delete) { _ in }
            }
        }
    }

    /// A refused exclusive operation must not partially mutate the bundle: the
    /// files are byte-for-byte identical afterwards. `delete` is used because a
    /// leaked mutation there would be the removal of the whole bundle.
    @Test func refusedDeleteLeavesBundleBytesUnchanged() throws {
        let root = try makeDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let library = VPhoneLibrary(root: root)
        let spec = VPhoneBundleOps.NewBundleSpec(
            name: "vm", cpuCount: 2, memoryMB: 1024, diskSizeGB: 1, romSource: rom, sepromSource: seprom)
        let bundle = try VPhoneBundleOps.create(spec, in: library)

        // Hold the lock as a running VM would; the record write happens here, so
        // the snapshot below already reflects it.
        let holder = try VPhoneVMLock(directory: bundle.url, operation: VPhoneVMOperation.boot)
        let before = try Self.snapshot(of: bundle.url)

        #expect(throws: VPhoneBundleGuardError.self) {
            try VPhoneBundleOps.delete(bundleNamed: "vm", in: library)
        }

        let after = try Self.snapshot(of: bundle.url)
        #expect(before == after)
        withExtendedLifetime(holder) {}
    }

    /// Maps every regular file under `dir` to its bytes so a refusal that mutated
    /// or removed anything is caught.
    private static func snapshot(of dir: URL) throws -> [String: Data] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var out: [String: Data] = [:]
        for case let url as URL in en {
            let vals = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard vals.isRegularFile == true else { continue }
            out[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return out
    }

    // MARK: Inode-keyed locking (path-alias collision)

    /// The lock keys on the resolved inode, not the path spelling, so a symlinked
    /// parent and a non-standardized `/./` path both see the same held lock.
    @Test func lockIsKeyedByInodeNotPathSpelling() throws {
        let realParent = try makeDir()
        defer { try? FileManager.default.removeItem(at: realParent) }
        let bundle = realParent.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let aliasParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: aliasParent, withDestinationURL: realParent)
        defer { try? FileManager.default.removeItem(at: aliasParent) }
        let aliasBundle = aliasParent.appendingPathComponent("vm")
        let dottedBundle = URL(fileURLWithPath: realParent.path + "/./vm")

        let holder = try VPhoneVMLock(directory: bundle, operation: VPhoneVMOperation.boot)
        // Both aliases resolve to the same inode, so the probe reports it held.
        #expect(VPhoneVMLockProbe.isLockHeld(directory: aliasBundle))
        #expect(VPhoneVMLockProbe.isLockHeld(directory: dottedBundle))
        // A real acquisition through the alias is refused for the same reason.
        #expect(throws: VPhoneVMLockError.self) {
            _ = try VPhoneVMLock(directory: aliasBundle, operation: VPhoneVMOperation.delete)
        }
        withExtendedLifetime(holder) {}
    }

    // MARK: requireDFUOwner

    private func guard_(
        lockHeld: Bool,
        record: VPhoneVMRuntimeState?,
        identity: VPhoneProcessIdentity? = nil,
        bootPIDs: [pid_t] = []
    ) -> VPhoneBundleGuard {
        VPhoneBundleGuard(
            lockHeld: { _ in lockHeld },
            readRecord: { _ in record },
            identity: { _ in identity },
            bootPIDs: { _ in bootPIDs })
    }

    private let dir = URL(fileURLWithPath: "/vm")
    private let cfg = URL(fileURLWithPath: "/vm/config.plist")

    @Test func requireDFUOwnerRefusesWhenLockNotHeld() {
        let g = guard_(lockHeld: false, record: nil)
        #expect(throws: VPhoneBundleGuardError.self) {
            try g.requireDFUOwner(directory: dir, configURL: cfg)
        }
    }

    @Test func requireDFUOwnerRefusesWhenRecordMissing() {
        let g = guard_(lockHeld: true, record: nil)
        #expect(throws: VPhoneBundleGuardError.self) {
            try g.requireDFUOwner(directory: dir, configURL: cfg)
        }
    }

    @Test func requireDFUOwnerRefusesWhenOperationNotDFU() {
        let g = guard_(
            lockHeld: true, record: record(VPhoneVMOperation.boot, pid: 100),
            identity: VPhoneProcessIdentity(pid: 100, startedAt: 1, uid: 501), bootPIDs: [100])
        #expect(throws: VPhoneBundleGuardError.self) {
            try g.requireDFUOwner(directory: dir, configURL: cfg)
        }
    }

    @Test func requireDFUOwnerRefusesWhenPIDGone() {
        let g = guard_(lockHeld: true, record: record(VPhoneVMOperation.dfu, pid: 100), identity: nil, bootPIDs: [100])
        #expect(throws: VPhoneBundleGuardError.self) {
            try g.requireDFUOwner(directory: dir, configURL: cfg)
        }
    }

    @Test func requireDFUOwnerRefusesWhenPIDIsZombie() {
        let g = guard_(
            lockHeld: true, record: record(VPhoneVMOperation.dfu, pid: 100),
            identity: VPhoneProcessIdentity(pid: 100, startedAt: 1, uid: 501, isZombie: true), bootPIDs: [100])
        #expect(throws: VPhoneBundleGuardError.self) {
            try g.requireDFUOwner(directory: dir, configURL: cfg)
        }
    }

    @Test func requireDFUOwnerRefusesWhenPIDNotABootProcess() {
        let g = guard_(
            lockHeld: true, record: record(VPhoneVMOperation.dfu, pid: 100),
            identity: VPhoneProcessIdentity(pid: 100, startedAt: 1, uid: 501), bootPIDs: [999])
        #expect(throws: VPhoneBundleGuardError.self) {
            try g.requireDFUOwner(directory: dir, configURL: cfg)
        }
    }

    @Test func requireDFUOwnerReturnsRecordOnFullSuccessPath() throws {
        let rec = record(VPhoneVMOperation.dfu, pid: 100)
        let g = guard_(
            lockHeld: true, record: rec,
            identity: VPhoneProcessIdentity(pid: 100, startedAt: 1, uid: 501), bootPIDs: [100])
        let owner = try g.requireDFUOwner(directory: dir, configURL: cfg)
        #expect(owner.pid == 100)
        #expect(owner.isDFUOperation)
    }
}

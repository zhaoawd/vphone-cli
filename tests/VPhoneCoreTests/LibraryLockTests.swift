@testable import VPhoneCore
import Foundation
import Testing

/// `create` and `import` place a bundle *name*, which no bundle directory exists
/// to lock at check time. They run under the library-root lock instead; these
/// tests prove the name-check and the placement are one lock lifetime.
struct LibraryLockTests {
    private func makeRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fakeROM() throws -> URL {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        try Data([0xAA, 0xBB, 0xCC]).write(to: f)
        return f
    }

    private func spec(_ name: String, rom: URL, seprom: URL) -> VPhoneBundleOps.NewBundleSpec {
        VPhoneBundleOps.NewBundleSpec(
            name: name, cpuCount: 2, memoryMB: 1024, diskSizeGB: 1, romSource: rom, sepromSource: seprom)
    }

    /// The `afterNameCheck` seam runs between the existence check and the
    /// directory placement. The library lock must be held throughout that window.
    @Test func libraryLockHeldAcrossNameCheckAndPlacement() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }

        var probedHeld: Bool?
        _ = try VPhoneBundleOps.create(spec("vm", rom: rom, seprom: seprom), in: VPhoneLibrary(root: root)) {
            probedHeld = VPhoneLibraryLockProbe.isLockHeld(root: root)
        }
        #expect(probedHeld == true)
    }

    @Test func creatingSameNameTwiceThrowsAlreadyExists() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let library = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(spec("dup", rom: rom, seprom: seprom), in: library)
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "dup")) {
            _ = try VPhoneBundleOps.create(spec("dup", rom: rom, seprom: seprom), in: library)
        }
    }

    @Test func creatingDifferentNameSucceeds() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rom = try fakeROM(); let seprom = try fakeROM()
        defer { try? FileManager.default.removeItem(at: rom); try? FileManager.default.removeItem(at: seprom) }
        let library = VPhoneLibrary(root: root)
        _ = try VPhoneBundleOps.create(spec("one", rom: rom, seprom: seprom), in: library)
        let second = try VPhoneBundleOps.create(spec("two", rom: rom, seprom: seprom), in: library)
        #expect(second.name == "two")
    }

    /// The probe must not report a spurious lock on an idle library root.
    @Test func libraryLockProbeFalseWhenIdle() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!VPhoneLibraryLockProbe.isLockHeld(root: root))
    }
}

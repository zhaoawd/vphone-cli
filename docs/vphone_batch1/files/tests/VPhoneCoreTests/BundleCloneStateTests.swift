@testable import VPhoneCore
import Darwin
import Foundation
import Testing

/// Integration tests for the REAL VPhoneBundleOps and REAL directory locks.
/// These require the original macOS project; the Linux isolated harness excludes them.
struct BundleCloneStateTests {
    private enum Failure: Error { case injected }
    private let stateFiles = ["Disk.img", "config.plist", "nvram.bin", "SEPStorage",
                              "ABC123.shsh", "udid-prediction.txt"]

    private func fixture() throws -> (URL, VPhoneLibrary, VPhoneBundle) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            let rom = root.appendingPathComponent("rom.bin")
            try Data([0xAB]).write(to: rom)
            let lib = VPhoneLibrary(root: root)
            let src = try VPhoneBundleOps.create(.init(
                name: "src", cpuCount: 2, memoryMB: 2048, diskSizeGB: 0,
                romSource: rom, sepromSource: rom), in: lib)
            try src.manifest.updating(machineIdentifier: Data([9, 9])).write(to: src.configURL)
            for name in stateFiles where name != "config.plist" {
                try Data(name.utf8).write(to: src.url.appendingPathComponent(name))
            }
            try Data("stale socket sentinel".utf8).write(to: src.url.appendingPathComponent("vphone.sock"))
            return (root, lib, try lib.bundle(named: "src"))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
    private func snapshot(_ bundle: VPhoneBundle) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: stateFiles.map {
            ($0, try Data(contentsOf: bundle.url.appendingPathComponent($0)))
        })
    }
    private func noStaging(_ root: URL) throws {
        #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains(where: { $0.hasPrefix(".clone-") }))
    }

    @Test func forcedFallbackKeepsIdentityAndSourceBytes() throws {
        let (root, lib, src) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try snapshot(src)
        let clone = try VPhoneBundleOps.clone(bundleNamed: "src", to: "dst", in: lib,
            copyDirectory: { source, destination, exclusions in
                try VPhoneCloneCopy.copy(from: source, to: destination, excludingRootNames: exclusions,
                                         cloneDirectory: { _, _ in ENOTSUP })
            })
        #expect(try snapshot(clone) == before)
        #expect(try snapshot(src) == before)
        #expect(clone.manifest.machineIdentifier == src.manifest.machineIdentifier)
        #expect(try !VPhoneCloneCopy.exists(at: clone.url.appendingPathComponent(VPhoneVMRuntimeState.filename)))
        #expect(try !VPhoneCloneCopy.exists(at: clone.url.appendingPathComponent("vphone.sock")))
        try noStaging(root)
    }

    @Test func refusesLockedSourceWithoutProducingDestination() throws {
        let (root, lib, src) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try snapshot(src)
        let held = try VPhoneVMLock(directory: src.url, operation: VPhoneVMOperation.boot)
        defer { withExtendedLifetime(held) {} }
        #expect(throws: VPhoneBundleGuardError.self) {
            _ = try VPhoneBundleOps.clone(bundleNamed: "src", to: "dst", in: lib)
        }
        #expect(try !VPhoneCloneCopy.exists(at: lib.url(forName: "dst")))
        #expect(try snapshot(src) == before)
        try noStaging(root)
    }

    @Test func destinationRaceDoesNotDeleteRival() throws {
        let (root, lib, src) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try snapshot(src)
        let destination = lib.url(forName: "dst")
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "dst")) {
            _ = try VPhoneBundleOps.clone(bundleNamed: "src", to: "dst", in: lib,
                copyDirectory: { try VPhoneCloneCopy.copy(from: $0, to: $1, excludingRootNames: $2) },
                afterNameCheck: {
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    try Data("rival".utf8).write(to: destination.appendingPathComponent("marker"))
                })
        }
        #expect(try Data(contentsOf: destination.appendingPathComponent("marker")) == Data("rival".utf8))
        #expect(try snapshot(src) == before)
        try noStaging(root)
    }

    @Test func failedCopyCleansOnlyPrivateStaging() throws {
        let (root, lib, src) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try snapshot(src)
        #expect(throws: Failure.self) {
            _ = try VPhoneBundleOps.clone(bundleNamed: "src", to: "dst", in: lib,
                copyDirectory: { _, destination, _ in
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                    try Data([0]).write(to: destination.appendingPathComponent("partial"))
                    throw Failure.injected
                })
        }
        #expect(try !VPhoneCloneCopy.exists(at: lib.url(forName: "dst")))
        #expect(try snapshot(src) == before)
        try noStaging(root)
    }

    @Test func brokenDestinationSymlinkIsNotAdopted() throws {
        let (root, lib, src) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try snapshot(src)
        let destination = lib.url(forName: "dst")
        let missing = root.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: missing)
        #expect(throws: VPhoneLibraryError.alreadyExists(name: "dst")) {
            _ = try VPhoneBundleOps.clone(bundleNamed: "src", to: "dst", in: lib)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == missing.path)
        #expect(try snapshot(src) == before)
        try noStaging(root)
    }

    @Test func exportImportRetainsClonedBootState() throws {
        let (root, lib, src) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try snapshot(src)
        let clone = try VPhoneBundleOps.clone(bundleNamed: "src", to: "dst", in: lib)
        let archive = root.appendingPathComponent("clone.txz")
        try VPhoneBundleOps.export(bundleNamed: clone.name, to: archive, includeIPSW: false,
                                  compression: .max, in: lib)
        let imported = try VPhoneBundleOps.importArchive(from: archive, name: "imported", in: lib)
        #expect(try snapshot(imported) == before)
        #expect(imported.manifest.machineIdentifier == src.manifest.machineIdentifier)
        #expect(VPhoneVMRuntimeState.read(in: imported.url) == nil)
        try noStaging(root)
    }
}

import Darwin
import Foundation
import Testing
@testable import VPhoneCore

/// Machine disk snapshots: the state files cloned aside and put back while the
/// machine is stopped. The temporary directory is on the boot volume, which is
/// APFS, so every clone here is a real `clonefile`.
struct BundleSnapshotsTests {
    // MARK: - Fixtures

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
        try write([1, 2, 3], to: "Disk.img", in: bundle)
        try write([4, 5, 6], to: "SEPStorage", in: bundle)
        try write([7, 8, 9], to: "nvram.bin", in: bundle)
        try write(Array("receipt-1".utf8), to: "PatchReceipt.plist", in: bundle)
        return (root, bundle)
    }

    private func write(_ bytes: [UInt8], to name: String, in bundle: VPhoneBundle) throws {
        try Data(bytes).write(to: bundle.url.appendingPathComponent(name))
    }

    private func read(_ name: String, in directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(name))
    }

    private func snapshotDirectory(_ name: String, of bundle: VPhoneBundle) -> URL {
        VPhoneMachineSnapshots.directory(of: bundle).appendingPathComponent(name)
    }

    private func liveFiles(of bundle: VPhoneBundle) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: bundle.url.path) where !name.hasPrefix(".") {
            let url = bundle.url.appendingPathComponent(name)
            if VPhoneVirtualMachineManifest.fileKind(at: url) == .regularFile {
                files[name] = try Data(contentsOf: url)
            }
        }
        return files
    }

    private func editMetadata(of name: String, in bundle: VPhoneBundle, _ edit: (inout [String: Any]) -> Void) throws {
        let url = snapshotDirectory(name, of: bundle).appendingPathComponent(VPhoneMachineSnapshots.metadataFileName)
        var plist = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any]
        )
        edit(&plist)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }

    // MARK: - Create

    @Test func createClonesEveryPresentStateFileByteForByte() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }

        let snapshot = try VPhoneMachineSnapshots.create("clean", note: "fresh install", of: bundle)
        let directory = snapshotDirectory("clean", of: bundle)
        for name in ["Disk.img", "SEPStorage", "nvram.bin", "PatchReceipt.plist"] {
            #expect(try read(name, in: directory) == read(name, in: bundle.url), "\(name)")
        }
        #expect(snapshot.files == ["Disk.img", "SEPStorage", "nvram.bin", "PatchReceipt.plist"])
        #expect(snapshot.absentFiles == ["restore-info.json"])
        #expect(snapshot.note == "fresh install")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.plist").path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(VPhoneMachineSnapshots.metadataFileName).path
        ))
        let entries = try FileManager.default.contentsOfDirectory(atPath: VPhoneMachineSnapshots.directory(of: bundle).path)
        #expect(entries == ["clean"])
    }

    @Test func createRefusesAMachineWithNoNvramYet() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: bundle.url.appendingPathComponent("nvram.bin"))

        #expect(throws: VPhoneMachineSnapshotError.missingStateFile(machine: "vm", file: "nvram.bin")) {
            try VPhoneMachineSnapshots.create("early", of: bundle)
        }
        #expect(!FileManager.default.fileExists(atPath: VPhoneMachineSnapshots.directory(of: bundle).path))
    }

    @Test func duplicateAndInvalidNamesAreRefused() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }

        try VPhoneMachineSnapshots.create("one", of: bundle)
        #expect(throws: VPhoneMachineSnapshotError.alreadyExists(machine: "vm", name: "one")) {
            try VPhoneMachineSnapshots.create("one", of: bundle)
        }
        for bad in ["", "a/b", ".hidden", ".."] {
            #expect(throws: VPhoneMachineSnapshotError.invalidName(bad)) {
                try VPhoneMachineSnapshots.create(bad, of: bundle)
            }
        }
        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == ["one"])
    }

    @Test func createAndRevertRefuseWhileAStateFileIsHeldOpen() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("before", of: bundle)

        let fd = open(bundle.url.appendingPathComponent("SEPStorage").path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }
        let running = VPhoneBundleActivityError.running(name: "vm", pids: [getpid()])
        #expect(throws: running) {
            try VPhoneMachineSnapshots.create("during", of: bundle)
        }
        #expect(throws: running) {
            try VPhoneMachineSnapshots.revert(to: "before", of: bundle)
        }
        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == ["before"])
        let hidden = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".snapshot") }
        #expect(hidden.isEmpty)
    }

    @Test func createAndRevertRefuseWhenStateFileChangesMidOperation() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("base", of: bundle)

        #expect(throws: VPhoneBundleActivityError.stateChanged(name: "vm")) {
            try VPhoneMachineSnapshots.create("mutated", of: bundle) {
                try Data([9, 8, 7, 6]).write(to: bundle.url.appendingPathComponent("SEPStorage"))
            }
        }
        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == ["base"])

        #expect(throws: VPhoneBundleActivityError.stateChanged(name: "vm")) {
            try VPhoneMachineSnapshots.revert(to: "base", of: bundle, afterStageClone: {
                try Data([0, 0, 0]).write(to: bundle.url.appendingPathComponent("nvram.bin"))
            })
        }
        #expect(try read("nvram.bin", in: bundle.url) == Data([0, 0, 0]))
    }

    // MARK: - List

    @Test func listIsOldestFirstWithMetadata() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try VPhoneMachineSnapshots.list(of: bundle).isEmpty)

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try VPhoneMachineSnapshots.create("zeta", note: "first", of: bundle, now: base)
        try VPhoneMachineSnapshots.create("alpha", of: bundle, now: base.addingTimeInterval(60))
        try VPhoneMachineSnapshots.create("mid", note: "", of: bundle, now: base.addingTimeInterval(30))
        try FileManager.default.createDirectory(
            at: snapshotDirectory("stray", of: bundle),
            withIntermediateDirectories: true
        )

        let listed = try VPhoneMachineSnapshots.list(of: bundle)
        #expect(listed.map(\.name) == ["zeta", "mid", "alpha"])
        #expect(listed.map(\.created) == [base, base.addingTimeInterval(30), base.addingTimeInterval(60)])
        #expect(listed.map(\.note) == ["first", nil, nil])
    }

    // MARK: - Revert

    @Test func revertRestoresStateFilesLeavesConfigAloneAndReconcilesOrigins() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("before", of: bundle)
        let savedBinding = try VPhoneMachineBinding(
            bundle: "2.7.0",
            guestEnvironment: "2.6.1",
            kernel: "2.6.0",
            bootChain: "2.6.0"
        )
        try savedBinding.save(to: bundle.url, snapshot: "before")

        try write([9, 9, 9, 9], to: "Disk.img", in: bundle)
        try write([8, 8], to: "SEPStorage", in: bundle)
        try write([7], to: "nvram.bin", in: bundle)
        try write(Array("receipt-2".utf8), to: "PatchReceipt.plist", in: bundle)
        try write(Array("{}".utf8), to: "restore-info.json", in: bundle)
        let currentBinding = try VPhoneMachineBinding(
            bundle: "2.8.0",
            guestEnvironment: "2.8.0",
            kernel: "2.8.0",
            bootChain: "2.7.0"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(currentBinding).write(to: bundle.url.appendingPathComponent("launchpad.json"))

        let updated = try VPhoneBundleOps.updateConfig(
            bundleNamed: "vm",
            in: VPhoneLibrary(root: root),
            cpuCount: 6,
            memoryMB: nil
        )
        let config = try read("config.plist", in: bundle.url)

        try VPhoneMachineSnapshots.revert(to: "before", of: updated)

        #expect(try read("Disk.img", in: bundle.url) == Data([1, 2, 3]))
        #expect(try read("SEPStorage", in: bundle.url) == Data([4, 5, 6]))
        #expect(try read("nvram.bin", in: bundle.url) == Data([7, 8, 9]))
        #expect(try read("PatchReceipt.plist", in: bundle.url) == Data("receipt-1".utf8))
        #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("restore-info.json").path))
        #expect(try read("config.plist", in: bundle.url) == config)
        #expect(try VPhoneBundle.load(at: bundle.url).manifest.cpuCount == 6)
        #expect(VPhoneMachineBinding.load(bundle.url) == .loaded(try VPhoneMachineBinding(
            bundle: "2.8.0",
            guestEnvironment: "2.6.1",
            kernel: "2.6.0",
            bootChain: "2.6.0"
        )))

        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == ["before"])
        #expect(try read("Disk.img", in: snapshotDirectory("before", of: bundle)) == Data([1, 2, 3]))
        try write([0], to: "Disk.img", in: bundle)
        try VPhoneMachineSnapshots.revert(to: "before", of: bundle)
        #expect(try read("Disk.img", in: bundle.url) == Data([1, 2, 3]))

        let hidden = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") }
        #expect(hidden.isEmpty)
    }

    @Test func revertOfADamagedSnapshotLeavesLiveFilesIntact() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("broken", of: bundle)
        try FileManager.default.removeItem(at: snapshotDirectory("broken", of: bundle).appendingPathComponent("nvram.bin"))
        try write([5, 5], to: "Disk.img", in: bundle)

        #expect(throws: VPhoneMachineSnapshotError.self) {
            try VPhoneMachineSnapshots.revert(to: "broken", of: bundle)
        }
        #expect(try read("Disk.img", in: bundle.url) == Data([5, 5]))
        let hidden = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") }
        #expect(hidden.isEmpty)
    }

    @Test func revertRefusesMetadataThatDoesNotListStateFilesExactly() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("edited", of: bundle)
        let full = ["Disk.img", "SEPStorage", "nvram.bin", "PatchReceipt.plist"]
        let cases: [(files: [String], absent: [String])] = [
            (["Disk.img"], ["restore-info.json"]),
            (full.filter { $0 != "nvram.bin" }, ["restore-info.json", "nvram.bin"]),
            (full + ["launchpad.json"], ["restore-info.json"]),
            (full + ["config.plist"], ["restore-info.json"]),
            (full, ["restore-info.json", "launchpad.json"]),
            (full, ["restore-info.json", "../Disk.img"]),
            (full, ["restore-info.json", "Disk.img"]),
            (full, ["restore-info.json", "PatchReceipt.plist"]),
            (full + ["Disk.img"], ["restore-info.json"]),
            (full, ["restore-info.json", "restore-info.json"]),
        ]

        try write([5, 5], to: "Disk.img", in: bundle)
        try write([6, 6], to: "SEPStorage", in: bundle)
        try write([7, 7], to: "nvram.bin", in: bundle)
        try write(Array("{}".utf8), to: "restore-info.json", in: bundle)
        try write(Array(#"{"bundle":"2.7.0"}"#.utf8), to: "launchpad.json", in: bundle)
        let before = try liveFiles(of: bundle)

        for (files, absent) in cases {
            try editMetadata(of: "edited", in: bundle) {
                $0["Files"] = files
                $0["AbsentFiles"] = absent
            }
            do {
                try VPhoneMachineSnapshots.revert(to: "edited", of: bundle)
                Issue.record("revert accepted Files \(files), AbsentFiles \(absent)")
            } catch let VPhoneMachineSnapshotError.damaged(name, _) {
                #expect(name == "edited")
            }
            #expect(try liveFiles(of: bundle) == before, "Files \(files), AbsentFiles \(absent)")
        }
        let hidden = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") }
        #expect(hidden.isEmpty)
    }

    @Test(arguments: ["nvram.bin", "restore-info.json"])
    func aRevertThatFailsPartwayPutsEveryLiveFileBack(blocked: String) throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("before", of: bundle)

        try write([9, 9, 9, 9], to: "Disk.img", in: bundle)
        try write([8, 8], to: "SEPStorage", in: bundle)
        try write([7], to: "nvram.bin", in: bundle)
        try write(Array("receipt-2".utf8), to: "PatchReceipt.plist", in: bundle)
        try write(Array("{}".utf8), to: "restore-info.json", in: bundle)
        let before = try liveFiles(of: bundle)

        let blockedPath = bundle.url.appendingPathComponent(blocked).path
        #expect(chflags(blockedPath, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(blockedPath, 0) }

        do {
            try VPhoneMachineSnapshots.revert(to: "before", of: bundle)
            Issue.record("revert succeeded with \(blocked) immutable")
        } catch let VPhoneMachineSnapshotError.failed(path, _) {
            #expect(path == blockedPath)
        }
        #expect(try liveFiles(of: bundle) == before)
        let hidden = try FileManager.default.contentsOfDirectory(atPath: bundle.url.path).filter { $0.hasPrefix(".") }
        #expect(hidden.isEmpty)

        chflags(blockedPath, 0)
        try VPhoneMachineSnapshots.revert(to: "before", of: bundle)
        #expect(try read("Disk.img", in: bundle.url) == Data([1, 2, 3]))
        #expect(try read("nvram.bin", in: bundle.url) == Data([7, 8, 9]))
        #expect(!FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("restore-info.json").path))
    }

    @Test func interruptedRevertJournalBlocksBootUntilRecovered() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("before", of: bundle)

        try write([9, 9, 9, 9], to: "Disk.img", in: bundle)
        try write([8, 8], to: "SEPStorage", in: bundle)
        try write([7], to: "nvram.bin", in: bundle)
        try write(Array("receipt-2".utf8), to: "PatchReceipt.plist", in: bundle)
        try write(Array("{}".utf8), to: "restore-info.json", in: bundle)
        let before = try liveFiles(of: bundle)

        // Simulate a process crash after Disk.img and SEPStorage were swapped,
        // leaving `.snapshot-revert-*` and its `SnapshotRevertJournal.plist` on disk.
        let staging = bundle.url.appendingPathComponent(".snapshot-revert-crash", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        let journal = VPhoneMachineSnapshots.RevertJournal(
            snapshotName: "before",
            files: ["Disk.img", "SEPStorage", "nvram.bin", "PatchReceipt.plist"],
            absentFiles: ["restore-info.json"],
            existedBeforeRevert: ["Disk.img", "SEPStorage", "nvram.bin", "PatchReceipt.plist", "restore-info.json"]
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try encoder.encode(journal).write(
            to: staging.appendingPathComponent(VPhoneMachineSnapshots.revertJournalFileName)
        )
        #expect(rename(
            bundle.url.appendingPathComponent("Disk.img").path,
            staging.appendingPathComponent("old-Disk.img").path
        ) == 0)
        try Data([1, 2, 3]).write(to: bundle.url.appendingPathComponent("Disk.img"))
        #expect(rename(
            bundle.url.appendingPathComponent("SEPStorage").path,
            staging.appendingPathComponent("old-SEPStorage").path
        ) == 0)
        try Data([4, 5, 6]).write(to: bundle.url.appendingPathComponent("SEPStorage"))

        // Non-snapshot locks (such as boot or config) refuse while recovery is required.
        let canonicalPath = staging.resolvingSymlinksInPath().standardizedFileURL.path
        #expect(throws: VPhoneVMLockError.snapshotRecoveryRequired(canonicalPath)) {
            _ = try VPhoneVMLock(directory: bundle.url, operation: VPhoneVMOperation.boot)
        }

        // Recover restores the pre-revert live file set and clears the journal.
        try VPhoneMachineSnapshots.recover(of: bundle)
        #expect(try liveFiles(of: bundle) == before)
        #expect(!FileManager.default.fileExists(atPath: staging.path))

        // Lock acquisition now succeeds again.
        let lock = try VPhoneVMLock(directory: bundle.url, operation: VPhoneVMOperation.boot)
        withExtendedLifetime(lock) {}
    }

    @Test func unknownSnapshotsAreReported() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = VPhoneMachineSnapshotError.notFound(machine: "vm", name: "nope")
        #expect(throws: missing) { try VPhoneMachineSnapshots.revert(to: "nope", of: bundle) }
        #expect(throws: missing) { try VPhoneMachineSnapshots.delete("nope", of: bundle) }
    }

    // MARK: - Delete

    @Test func deleteRemovesTheSnapshotWithFilesAClientAdded() throws {
        let (root, bundle) = try makeBundle()
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneMachineSnapshots.create("keep", of: bundle)
        try VPhoneMachineSnapshots.create("drop", of: bundle)
        let extra = snapshotDirectory("drop", of: bundle).appendingPathComponent("launchpad.json")
        try Data(#"{"bundle":"2.7.0"}"#.utf8).write(to: extra)

        try VPhoneMachineSnapshots.revert(to: "drop", of: bundle)
        #expect(FileManager.default.fileExists(atPath: extra.path))
        #expect(FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("launchpad.json").path) == false)

        try VPhoneMachineSnapshots.delete("drop", of: bundle)
        #expect(!FileManager.default.fileExists(atPath: snapshotDirectory("drop", of: bundle).path))
        #expect(try VPhoneMachineSnapshots.list(of: bundle).map(\.name) == ["keep"])

        try VPhoneMachineSnapshots.delete("keep", of: bundle)
        #expect(!FileManager.default.fileExists(atPath: VPhoneMachineSnapshots.directory(of: bundle).path))
        #expect(try read("Disk.img", in: bundle.url) == Data([1, 2, 3]))
    }

    // MARK: - Export

    @Test func snapshotsAreExcludedFromExport() {
        let patterns = VPhoneBundleOps.exportExcludePatterns
        #expect(patterns.contains { fnmatch($0, VPhoneMachineSnapshots.directoryName, 0) == 0 })
        #expect(patterns.contains { fnmatch($0, ".snapshot-revert-1234", 0) == 0 })
        for kept in ["Disk.img", "SEPStorage", "nvram.bin", "config.plist", "PatchReceipt.plist"] {
            #expect(!patterns.contains { fnmatch($0, kept, 0) == 0 }, "\(kept)")
        }
    }
}

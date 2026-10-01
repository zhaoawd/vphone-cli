import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VPhoneDaemonWire

/// File side of the T17 online environment update, on a temporary directory
/// standing in for /usr/lib and the guest staging directory.
struct EnvironmentTransactionTests {
    static let names = ["launchdhook-vphone.dylib", "SystemHook-vphone.dylib", "libvcamcaptured.dylib",
                        "libcamfix.dylib", "libvlocation.dylib"]

    final class Guest {
        let root: URL
        let transaction: EnvironmentTransaction
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("vphone-env-tx-\(UUID())")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("usr/lib"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("staging"), withIntermediateDirectories: true)
            transaction = EnvironmentTransaction(libraries: EnvironmentTransactionTests.names,
                                                 libraryDirectory: root.appendingPathComponent("usr/lib").path,
                                                 stagingDirectory: root.appendingPathComponent("staging").path)
            for name in EnvironmentTransactionTests.names { try write("usr/lib/" + name, "old " + name) }
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ relative: String, _ text: String) throws {
            try Data(text.utf8).write(to: root.appendingPathComponent(relative))
        }
        func read(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }
        func stage(_ name: String, _ text: String) throws -> [String: Any] {
            try write("staging/" + name, text)
            return ["name": name, "sha256": EnvironmentTransactionTests.digest(text)]
        }
        /// Installs like the daemon: copy next to the target, then rename.
        func install(_ source: String, _ destination: String) throws {
            let temporary = destination + ".test-" + UUID().uuidString
            try FileManager.default.copyItem(atPath: source, toPath: temporary)
            guard rename(temporary, destination) == 0 else { throw POSIXError(.EIO) }
        }
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func statusReportsInstalledAndStagedDigests() throws {
        let guest = try Guest()
        _ = try guest.stage("libcamfix.dylib", "new camfix")
        let rows = guest.transaction.status()
        #expect(rows.map { $0["name"] as? String } == Self.names)
        let camfix = try #require(rows.first { $0["name"] as? String == "libcamfix.dylib" })
        #expect(camfix["sha256"] as? String == Self.digest("old libcamfix.dylib"))
        #expect(camfix["staged_sha256"] as? String == Self.digest("new camfix"))
        let other = try #require(rows.first { $0["name"] as? String == "libvlocation.dylib" })
        #expect(other["staged_sha256"] is NSNull)
        try FileManager.default.removeItem(at: guest.root.appendingPathComponent("usr/lib/libvlocation.dylib"))
        let missing = try #require(guest.transaction.status().first { $0["name"] as? String == "libvlocation.dylib" })
        #expect(missing["sha256"] is NSNull)
    }

    @Test func validationRejectsBeforeAnyWrite() throws {
        let guest = try Guest()
        let good = try guest.stage("libcamfix.dylib", "new camfix")
        var wrongDigest = good
        wrongDigest["sha256"] = Self.digest("something else")
        try FileManager.default.removeItem(at: guest.root.appendingPathComponent("usr/lib/libvlocation.dylib"))
        let notInstalled = try guest.stage("libvlocation.dylib", "new location")
        let cases: [Any?] = [nil, [], [["name": "libmisfix.dylib", "sha256": Self.digest("x")]], [wrongDigest],
                             [good, good], [["name": "libcamfix.dylib"]], [notInstalled],
                             [["name": "SystemHook-vphone.dylib", "sha256": Self.digest("not staged")]]]
        for value in cases {
            #expect(throws: EnvironmentTransaction.Failure.self) { try guest.transaction.validate(value) }
        }
        #expect(try guest.transaction.validate([good]).map(\.name) == ["libcamfix.dylib"])
        #expect(try guest.read("usr/lib/libcamfix.dylib") == "old libcamfix.dylib")
        #expect(!FileManager.default.fileExists(atPath: guest.transaction.stateDirectory))
    }

    @Test func completeInstallKeepsBackupsAndJournal() throws {
        let guest = try Guest()
        let entries = try guest.transaction.validate([try guest.stage("libcamfix.dylib", "new camfix"),
                                                      try guest.stage("libvcamcaptured.dylib", "new vcam")])
        let before = try #require(EnvironmentTransaction.identity(atPath: guest.root.appendingPathComponent("usr/lib/libcamfix.dylib").path))
        var journal = try guest.transaction.prepare(entries)
        #expect(journal.state == "prepared")
        guest.transaction.apply(&journal, replace: guest.install)
        #expect(journal.state == "complete")
        #expect(journal.libraries.map(\.state) == ["replaced", "replaced"])
        #expect(try guest.read("usr/lib/libcamfix.dylib") == "new camfix")
        #expect(try guest.read("usr/lib/libvcamcaptured.dylib") == "new vcam")
        let camfix = journal.libraries[0]
        #expect(camfix.previousSHA256 == Self.digest("old libcamfix.dylib"))
        #expect(camfix.previousDevice == before.device && camfix.previousInode == before.inode)
        #expect(try String(contentsOfFile: camfix.backup, encoding: .utf8) == "old libcamfix.dylib")
        #expect(!FileManager.default.fileExists(atPath: guest.root.appendingPathComponent("staging/libcamfix.dylib").path))
        let saved = try #require(try guest.transaction.journal(id: journal.id))
        #expect(saved.state == "complete")
        #expect(guest.transaction.transactions().first?["id"] as? String == journal.id)
    }

    @Test func failedReplacementStopsAndRecordsRecovery() throws {
        let guest = try Guest()
        let entries = try guest.transaction.validate([try guest.stage("launchdhook-vphone.dylib", "new launchd"),
                                                      try guest.stage("SystemHook-vphone.dylib", "new systemhook"),
                                                      try guest.stage("libvlocation.dylib", "new location")])
        var journal = try guest.transaction.prepare(entries)
        var calls = 0
        guest.transaction.apply(&journal) { source, destination in
            calls += 1
            if calls == 2 { throw EnvironmentTransaction.Failure.io("injected EIO") }
            try guest.install(source, destination)
        }
        #expect(calls == 2)
        #expect(journal.state == "incomplete")
        #expect(journal.libraries.map(\.state) == ["replaced", "failed", "not_attempted"])
        #expect(journal.libraries[1].error?.contains("injected EIO") == true)
        #expect(try guest.read("usr/lib/launchdhook-vphone.dylib") == "new launchd")
        #expect(try guest.read("usr/lib/SystemHook-vphone.dylib") == "old SystemHook-vphone.dylib")
        #expect(try guest.read("usr/lib/libvlocation.dylib") == "old libvlocation.dylib")
        // Staged copies stay for entries that were not installed.
        #expect(FileManager.default.fileExists(atPath: guest.root.appendingPathComponent("staging/SystemHook-vphone.dylib").path))
        let record = journal.dictionary
        #expect(record["state"] as? String == "incomplete")
        #expect((record["libraries"] as? [[String: Any]])?.first?["backup"] as? String == journal.libraries[0].backup)
        #expect(try guest.transaction.journal(id: journal.id)?.state == "incomplete")

        // Restore puts the replaced library back from its backup.
        var restored = try guest.transaction.prepareRestore(id: journal.id)
        guest.transaction.applyRestore(&restored, replace: guest.install)
        #expect(restored.state == "restored")
        #expect(restored.libraries.map(\.state) == ["restored", "failed", "not_attempted"])
        #expect(try guest.read("usr/lib/launchdhook-vphone.dylib") == "old launchdhook-vphone.dylib")
    }

    @Test func restoreRefusesAFileChangedAfterTheTransaction() throws {
        let guest = try Guest()
        let entries = try guest.transaction.validate([try guest.stage("libcamfix.dylib", "new camfix")])
        var journal = try guest.transaction.prepare(entries)
        guest.transaction.apply(&journal, replace: guest.install)
        try guest.write("usr/lib/libcamfix.dylib", "changed later")
        #expect(throws: EnvironmentTransaction.Failure.self) { try guest.transaction.prepareRestore(id: journal.id) }
        #expect(throws: EnvironmentTransaction.Failure.self) { try guest.transaction.prepareRestore(id: "../escape") }
        #expect(try guest.read("usr/lib/libcamfix.dylib") == "changed later")
    }

    @Test func mappingsAreCurrentOrStaleByFileIdentity() throws {
        let guest = try Guest()
        let path = guest.root.appendingPathComponent("usr/lib/libcamfix.dylib").path
        let old = try #require(EnvironmentTransaction.identity(atPath: path))
        let entries = try guest.transaction.validate([try guest.stage("libcamfix.dylib", "new camfix")])
        var journal = try guest.transaction.prepare(entries)
        guest.transaction.apply(&journal, replace: guest.install)
        let new = try #require(EnvironmentTransaction.identity(atPath: path))
        #expect(new.inode != old.inode)
        let location = try #require(EnvironmentTransaction.identity(
            atPath: guest.root.appendingPathComponent("usr/lib/libvlocation.dylib").path))
        let regions = [
            EnvironmentMapping(path: path, device: new.device, inode: new.inode),
            // The kernel may report an unlinked vnode without its old path.
            EnvironmentMapping(path: "", device: old.device, inode: old.inode),
            EnvironmentMapping(path: guest.root.appendingPathComponent("usr/lib/libvlocation.dylib").path,
                               device: location.device, inode: location.inode &+ 99_999),
            EnvironmentMapping(path: "/usr/lib/libSystem.B.dylib", device: 1, inode: 2),
        ]
        let rows = guest.transaction.classify(regions, current: guest.transaction.identities(),
                                              previous: guest.transaction.previousIdentities())
        #expect(rows.count == 3)
        #expect(rows[0]["library"] as? String == "libcamfix.dylib" && rows[0]["state"] as? String == "current")
        #expect(rows[1]["library"] as? String == "libcamfix.dylib" && rows[1]["state"] as? String == "stale")
        #expect(rows[1]["transaction"] as? String == journal.id)
        #expect(rows[2]["library"] as? String == "libvlocation.dylib" && rows[2]["state"] as? String == "stale")
    }

    @Test func retentionKeepsIncompleteTransactions() throws {
        let guest = try Guest()
        var transaction = guest.transaction
        transaction.retained = 2
        var incomplete = try transaction.prepare(try transaction.validate([try guest.stage("libcamfix.dylib", "a")]))
        transaction.apply(&incomplete) { _, _ in throw EnvironmentTransaction.Failure.io("no") }
        var ids: [String] = []
        for index in 0..<3 {
            var journal = try transaction.prepare(try transaction.validate([try guest.stage("libcamfix.dylib", "v\(index)")]))
            transaction.apply(&journal, replace: guest.install)
            ids.append(journal.id)
        }
        let kept = Set(transaction.transactions().compactMap { $0["id"] as? String })
        #expect(kept.contains(incomplete.id))
        #expect(kept.contains(ids[2]) && kept.contains(ids[1]))
        #expect(!kept.contains(ids[0]))
    }
}

import CryptoKit
import Darwin
import Foundation
import Testing
import VPhoneArchiveKit
@testable import VPhoneBundleStore

private final class BundleFixture {
    let directory: URL
    let source: URL
    let archive: URL
    let store: VPhoneCoreBundleStore
    var installed: URL { store.root.appendingPathComponent("2.2.3-local") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-store-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        source = directory.appendingPathComponent("VPhone.bundle")
        archive = directory.appendingPathComponent("input.tar")
        store = VPhoneCoreBundleStore(testRoot: directory.appendingPathComponent("store"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": "com.vphone.store-test", "CFBundleName": "VPhone",
            "CFBundleExecutable": "vphone-cli", "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "2.2.3"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Contents/Info.plist"))
        for name in ["vphone-cli", "vphone-vm", "vphone-escalator"] {
            let executable = source.appendingPathComponent("Contents/MacOS/\(name)")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        }
        try Data("resource".utf8).write(to: source.appendingPathComponent("Contents/Resources/data"))
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        guard process.terminationStatus == 0 else { throw VPhoneBundleStoreError("Fixture tool failed: \(tool)") }
    }

    func pack(sign: Bool = true) throws -> String {
        if sign {
            // Sign after the final Info.plist edits, matching StageBundle.sh.
            for name in ["vphone-cli", "vphone-vm", "vphone-escalator"] {
                try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "com.vphone.test.\(name)",
                                                  source.appendingPathComponent("Contents/MacOS/\(name)").path])
            }
            try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", source.path])
        }
        try VPhoneArchiveWriter.create(archive: archive, from: source, topLevel: "VPhone.bundle")
        return SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    func install(digest: String? = nil, version: String = "2.2.3-local") throws -> VPhoneBundleReceipt {
        let expected = try digest ?? pack()
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        return try store.install(version: version, archive: input, sha256: expected)
    }

    /// mode, owner, group, link count and size of every entry under the store,
    /// read with lstat. A refused request must leave this unchanged.
    func snapshot() -> [String: [Int64]] {
        var result: [String: [Int64]] = [:]
        let root = store.root.path
        var info = stat()
        guard lstat(root, &info) == 0 else { return [:] }
        result["."] = [Int64(info.st_mode), Int64(info.st_uid), Int64(info.st_gid), Int64(info.st_nlink), info.st_size]
        let enumerator = FileManager.default.enumerator(atPath: root)
        while let relative = enumerator?.nextObject() as? String {
            guard lstat(root + "/" + relative, &info) == 0 else { continue }
            result[relative] = [Int64(info.st_mode), Int64(info.st_uid), Int64(info.st_gid), Int64(info.st_nlink), info.st_size]
        }
        return result
    }

    static func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return error.localizedDescription }
    }
}

@Suite(.serialized)
struct CoreBundleStoreTests {
    @Test func installsSignedBundleAndVerifiesReceipt() throws {
        let fixture = try BundleFixture()
        // Framework-style relative links remain supported.
        try FileManager.default.createSymbolicLink(atPath: fixture.source.appendingPathComponent("Contents/Resources/link").path,
                                                  withDestinationPath: "data")
        let receipt = try fixture.install()
        let verified = try fixture.store.verify(version: "2.2.3-local")
        #expect(receipt.sha256 == verified.sha256)
        #expect(verified.cdhashes.count == 2)
        for file in [fixture.installed.appendingPathComponent("receipt.json"), fixture.store.root.appendingPathComponent(".store.lock")] {
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o644)
        }
        try fixture.store.withVerifiedExecutable(version: "2.2.3-local", executable: .cli) { url in
            #expect(url.lastPathComponent == "vphone-cli")
            #expect(url.path.hasPrefix(fixture.installed.path + "/"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.root.path).sorted() == [".store.lock", "2.2.3-local"])
    }

    @Test func acceptsUpstreamResourceBundleLayout() throws {
        let fixture = try BundleFixture()
        let plist = fixture.source.appendingPathComponent("Contents/Info.plist")
        var value = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: String])
        value.removeValue(forKey: "CFBundleExecutable")
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: plist)
        _ = try fixture.install()
        _ = try fixture.store.verify(version: "2.2.3-local")
    }

    @Test(arguments: [("../2.0.8", "Invalid Core Bundle version"), ("2.0.8/other", "Invalid Core Bundle version"),
                      ("2.0.8\n", "Invalid Core Bundle version \"2.0.8\\n\""), ("2.0.8-local/", "Invalid Core Bundle version"),
                      ("-2.0.8", "Invalid Core Bundle version"), ("9999999999999999999999.0.0", "Invalid Core Bundle version"),
                      ("2.2.3-ci.XYZ1234", "Invalid Core Bundle version"), ("2.2.3-ci.abc", "Invalid Core Bundle version"),
                      ("2.2.3-beta", "Invalid Core Bundle version"),
                      ("2.0.8", "older than the minimum supported version 2.2.0"),
                      ("2.1.9-local", "older than the minimum supported version 2.2.0"),
                      ("2.1.7-ci.0123abc", "older than the minimum supported version 2.2.0")])
    func invalidVersionRefusedBeforeStoreCreation(_ version: String, _ reason: String) throws {
        let fixture = try BundleFixture()
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/usr/bin/true"))
        defer { try? input.close() }
        let message = BundleFixture.message {
            _ = try fixture.store.install(version: version, archive: input, sha256: String(repeating: "0", count: 64))
        }
        #expect(message?.contains(reason) == true, "\(message ?? "accepted")")
        #expect(BundleFixture.message { _ = try fixture.store.verify(version: version) }?.contains(reason) == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.root.path))
    }

    @Test func versionNamesFollowUpstreamStoreSuffixes() throws {
        #expect(VPhoneBundleVersion.release(of: "2.2.3") == "2.2.3")
        #expect(VPhoneBundleVersion.release(of: "2.2.3-local") == "2.2.3")
        #expect(VPhoneBundleVersion.release(of: "2.2.3-ci.0123abcd") == "2.2.3")
        for version in ["2.2.0", "2.2.3-local", "2.2.3-ci.0123abc", "3.0.0-ci." + String(repeating: "f", count: 40)] {
            try VPhoneBundleVersion.require(version)
        }
    }

    @Test func ciArtifactNameInstallsAgainstReleaseInfoPlist() throws {
        let fixture = try BundleFixture()
        let receipt = try fixture.install(version: "2.2.3-ci.0123abc")
        #expect(receipt.version == "2.2.3-ci.0123abc")
        let verified = try fixture.store.verify(version: "2.2.3-ci.0123abc")
        #expect(verified.sha256 == receipt.sha256 && verified.cdhashes == receipt.cdhashes)
    }

    @Test func digestMismatchLeavesNoPublishedVersion() throws {
        let fixture = try BundleFixture()
        _ = try fixture.pack()
        let message = BundleFixture.message { try fixture.install(digest: String(repeating: "0", count: 64)) }
        #expect(message == "Core Bundle archive SHA-256 mismatch.")
        #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.root.path) == [".store.lock"])
    }

    @Test func duplicateInstallPreservesOriginalReceiptAndModes() throws {
        let fixture = try BundleFixture()
        let receipt = try fixture.install()
        let receiptURL = fixture.installed.appendingPathComponent("receipt.json")
        let before = try Data(contentsOf: receiptURL)
        let tree = fixture.snapshot()
        let message = BundleFixture.message { try fixture.install(digest: receipt.sha256) }
        #expect(message?.contains("Core Bundle version already exists: 2.2.3-local") == true)
        #expect(try Data(contentsOf: receiptURL) == before)
        #expect(fixture.snapshot() == tree)
        _ = try fixture.store.verify(version: "2.2.3-local")
    }

    /// Refusals after a successful install change neither contents nor any mode or owner.
    @Test(arguments: ["digest", "old-version", "plist-version", "x86_64", "non-regular"])
    func refusedInstallLeavesExistingStoreUnchanged(_ mutation: String) throws {
        let fixture = try BundleFixture()
        let receipt = try fixture.install()
        let tree = fixture.snapshot()
        let message: String?
        switch mutation {
        case "digest": message = BundleFixture.message { try fixture.install(digest: String(repeating: "1", count: 64), version: "2.2.4") }
        case "old-version": message = BundleFixture.message { try fixture.install(digest: receipt.sha256, version: "2.1.9") }
        case "plist-version": message = BundleFixture.message { try fixture.install(digest: receipt.sha256, version: "2.2.4") }
        case "x86_64":
            try BundleFixture.run("/usr/bin/lipo", [fixture.source.appendingPathComponent("Contents/MacOS/vphone-vm").path,
                                                   "-thin", "x86_64", "-output", fixture.directory.appendingPathComponent("thin").path])
            try FileManager.default.removeItem(at: fixture.source.appendingPathComponent("Contents/MacOS/vphone-vm"))
            try FileManager.default.moveItem(at: fixture.directory.appendingPathComponent("thin"),
                                             to: fixture.source.appendingPathComponent("Contents/MacOS/vphone-vm"))
            try FileManager.default.removeItem(at: fixture.archive)
            let digest = try fixture.pack()
            message = BundleFixture.message { try fixture.install(digest: digest, version: "2.2.3-ci.0123abc") }
        default:
            let pipe = Pipe()
            message = BundleFixture.message {
                _ = try fixture.store.install(version: "2.2.4", archive: pipe.fileHandleForReading, sha256: receipt.sha256)
            }
        }
        let expected = switch mutation {
        case "digest": "Core Bundle archive SHA-256 mismatch."
        case "old-version": "older than the minimum supported version 2.2.0"
        case "plist-version": "CFBundleShortVersionString \"2.2.3\", requested 2.2.4"
        case "x86_64": "has no arm64 slice (found: x86_64)"
        default: "Archive must be a nonempty regular file"
        }
        #expect(message?.contains(expected) == true, "\(message ?? "accepted")")
        #expect(fixture.snapshot() == tree)
        _ = try fixture.store.verify(version: "2.2.3-local")
    }

    @Test(.enabled(if: geteuid() != 0, "Only a non-root caller exercises the refusal"))
    func productionStoreRefusesNonRootBeforeAnyHostAccess() throws {
        let root = VPhoneCoreBundleStore.root.path
        var info = stat()
        let existed = lstat(root, &info) == 0
        let before = existed ? [info.st_mode, mode_t(info.st_uid), mode_t(info.st_gid)] : []
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/usr/bin/true"))
        defer { try? input.close() }
        let message = BundleFixture.message {
            _ = try VPhoneCoreBundleStore().install(version: "2.2.3", archive: input, sha256: String(repeating: "0", count: 64))
        }
        #expect(message == "Core Bundle installation requires root (sudo).")
        #expect((lstat(root, &info) == 0) == existed)
        if existed { #expect([info.st_mode, mode_t(info.st_uid), mode_t(info.st_gid)] == before) }
    }

    @Test func receiptFieldsAreRefusedWithSeparateReasons() throws {
        let valid = VPhoneBundleReceipt(version: "2.2.3", sha256: String(repeating: "a", count: 64), installedAt: Date(),
                                        cdhashes: ["vphone-cli": String(repeating: "b", count: 40), "vphone-vm": String(repeating: "c", count: 40)])
        try VPhoneCoreBundleStore.requireReceipt(valid, version: "2.2.3")
        let cases: [(VPhoneBundleReceipt, String)] = [
            (.init(version: "2.2.4", sha256: valid.sha256, installedAt: valid.installedAt, cdhashes: valid.cdhashes),
             "receipt version \"2.2.4\" does not match installed version 2.2.3"),
            (.init(version: "2.2.3", sha256: valid.sha256, installedAt: valid.installedAt, cdhashes: ["vphone-cli": valid.cdhashes["vphone-cli"]!]),
             "cdhashes must name exactly vphone-cli, vphone-vm; found: \"vphone-cli\""),
            (.init(version: "2.2.3", sha256: valid.sha256, installedAt: valid.installedAt,
                   cdhashes: valid.cdhashes.merging(["vphone-escalator": String(repeating: "d", count: 40)]) { $1 }),
             "found: \"vphone-cli\", \"vphone-escalator\", \"vphone-vm\""),
            (.init(version: "2.2.3", sha256: String(repeating: "A", count: 64), installedAt: valid.installedAt, cdhashes: valid.cdhashes),
             "receipt sha256 is not 64 lowercase hexadecimal digits"),
            (.init(version: "2.2.3", sha256: valid.sha256, installedAt: valid.installedAt,
                   cdhashes: valid.cdhashes.merging(["vphone-vm": "00"]) { $1 }),
             "receipt cdhash for vphone-vm is not 40 lowercase hexadecimal digits"),
        ]
        for (receipt, reason) in cases {
            let message = BundleFixture.message { try VPhoneCoreBundleStore.requireReceipt(receipt, version: "2.2.3") }
            #expect(message?.contains(reason) == true, "\(message ?? "accepted")")
        }
    }

    @Test func machOReaderReportsSlices() throws {
        #expect(try VPhoneMachOArchitectures.cpuTypes(URL(fileURLWithPath: "/usr/bin/true")).contains(VPhoneMachOArchitectures.arm64))
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("macho-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: text) }
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: text)
        #expect(BundleFixture.message { try VPhoneMachOArchitectures.requireAppleSilicon(text) }?.contains("is not a Mach-O file") == true)
    }

    @Test(arguments: ["receipt", "receipt-version", "cdhash", "resource", "binary", "writable", "acl", "hardlink", "symlink", "resigned"])
    func refusesModifiedInstallation(_ mutation: String) throws {
        let fixture = try BundleFixture()
        _ = try fixture.install()
        let receiptURL = fixture.installed.appendingPathComponent("receipt.json")
        let bundle = fixture.installed.appendingPathComponent("VPhone.bundle")
        let binary = bundle.appendingPathComponent("Contents/MacOS/vphone-vm")
        let resource = bundle.appendingPathComponent("Contents/Resources/data")
        switch mutation {
        case "receipt": try Data("{}".utf8).write(to: receiptURL)
        case "receipt-version", "cdhash":
            var value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
            if mutation == "receipt-version" { value["version"] = "2.2.4" }
            else { value["cdhashes"] = ["vphone-cli": String(repeating: "0", count: 40), "vphone-vm": String(repeating: "0", count: 40)] }
            try JSONSerialization.data(withJSONObject: value).write(to: receiptURL)
        case "resource": try Data("changed".utf8).write(to: resource)
        case "binary":
            var data = try Data(contentsOf: binary)
            data[4096] ^= 1
            try data.write(to: binary)
        case "writable": #expect(chmod(resource.path, 0o666) == 0)
        case "acl": try BundleFixture.run("/bin/chmod", ["+a", "everyone allow write", resource.path])
        case "hardlink": #expect(link(resource.path, fixture.directory.appendingPathComponent("outside-link").path) == 0)
        case "symlink":
            try FileManager.default.removeItem(at: receiptURL)
            try FileManager.default.createSymbolicLink(atPath: receiptURL.path, withDestinationPath: resource.path)
        case "resigned":
            try BundleFixture.run("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "different.binary", binary.path])
            try BundleFixture.run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        default: break
        }
        let tree = fixture.snapshot()
        var called = false
        let message = BundleFixture.message {
            try fixture.store.withVerifiedExecutable(version: "2.2.3-local", executable: .vm) { _ in called = true }
        }
        #expect(!called)
        let expected = switch mutation {
        case "receipt": "Invalid Core Bundle receipt: expected JSON"
        case "receipt-version": "receipt version \"2.2.4\" does not match installed version 2.2.3-local"
        case "cdhash": "Installed vphone-cli cdhash"
        case "resource", "binary": "Invalid code signature"
        case "writable": "mode 666"
        case "acl": "Extended ACLs are not accepted"
        case "hardlink": "2 hard links, expected 1"
        case "symlink": "Unsafe bundle symbolic link"
        default: "differs from its receipt" // Re-signing the bundle also re-signs its main executable, vphone-cli.
        }
        #expect(message?.contains(expected) == true, "\(message ?? "accepted")")
        // Verification never repairs: modes, owners and links stay as found.
        #expect(fixture.snapshot() == tree)
    }

    @Test(arguments: ["absolute", "climb", "indirect-climb", "hardlink", "setuid", "fifo", "wrong-version", "unsigned"])
    func rejectsUnsafeArchive(_ mutation: String) throws {
        let fixture = try BundleFixture()
        let resource = fixture.source.appendingPathComponent("Contents/Resources/data")
        let extra = fixture.source.appendingPathComponent("Contents/Resources/extra")
        switch mutation {
        case "absolute", "climb", "indirect-climb":
            let target = mutation == "absolute" ? "/tmp/outside" : mutation == "climb" ? "../../../outside" : "sub/../../outside"
            try FileManager.default.createSymbolicLink(atPath: extra.path, withDestinationPath: target)
        case "hardlink": #expect(link(resource.path, extra.path) == 0)
        case "setuid": #expect(chmod(resource.path, 0o4755) == 0)
        case "fifo": #expect(mkfifo(extra.path, 0o600) == 0)
        case "wrong-version":
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.2.4"], format: .xml, options: 0)
                .write(to: fixture.source.appendingPathComponent("Contents/Info.plist"))
        default: break
        }
        let digest = try fixture.pack(sign: false)
        do {
            try fixture.install(digest: digest)
            Issue.record("Unsafe archive was accepted: \(mutation)")
        } catch {
            let expected: String
            switch mutation {
            case "absolute", "climb", "indirect-climb": expected = "Unsafe symbolic link"
            case "hardlink", "setuid", "fifo": expected = "Unsafe or oversized archive member"
            case "wrong-version": expected = "Info.plist version mismatch"
            default: expected = "Invalid code signature"
            }
            #expect(error.localizedDescription.contains(expected))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
    }

    @Test(arguments: ["symlink", "writable", "acl", "lock-symlink"])
    func rejectsUnsafeStore(_ mutation: String) throws {
        let fixture = try BundleFixture()
        let digest = try fixture.pack()
        if mutation == "symlink" {
            try FileManager.default.createSymbolicLink(atPath: fixture.store.root.path, withDestinationPath: fixture.source.path)
        } else {
            try FileManager.default.createDirectory(at: fixture.store.root, withIntermediateDirectories: false)
            if mutation == "writable" { #expect(chmod(fixture.store.root.path, 0o777) == 0) }
            if mutation == "acl" { try BundleFixture.run("/bin/chmod", ["+a", "everyone allow add_file", fixture.store.root.path]) }
            if mutation == "lock-symlink" {
                try FileManager.default.createSymbolicLink(atPath: fixture.store.root.appendingPathComponent(".store.lock").path,
                                                          withDestinationPath: fixture.archive.path)
            }
        }
        #expect(throws: (any Error).self) { try fixture.install(digest: digest) }
        #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
    }

    @Test func heldLeaseRefusesConcurrentInstall() throws {
        let fixture = try BundleFixture()
        let receipt = try fixture.install()
        _ = try fixture.store.withVerifiedExecutable(version: "2.2.3-local", executable: .cli) { _ in
            #expect(throws: (any Error).self) {
                do { try fixture.install(digest: receipt.sha256) }
                catch {
                    #expect(error.localizedDescription == "Core Bundle store is busy.")
                    throw error
                }
            }
        }
    }

    @Test func descriptorCopyIgnoresSharedSeekOffset() throws {
        let fixture = try BundleFixture()
        let digest = try fixture.pack()
        let input = try FileHandle(forReadingFrom: fixture.archive)
        defer { try? input.close() }
        try input.seek(toOffset: 37)
        _ = try fixture.store.install(version: "2.2.3-local", archive: input, sha256: digest)
        #expect(try input.offset() == 37)
    }

    @Test func rejectsNonRegularDescriptor() throws {
        let fixture = try BundleFixture()
        let pipe = Pipe()
        #expect(throws: (any Error).self) {
            try fixture.store.install(version: "2.2.3-local", archive: pipe.fileHandleForReading, sha256: String(repeating: "0", count: 64))
        }
    }

    @Test func archiveReaderEntryLimit() throws {
        let fixture = try BundleFixture()
        _ = try fixture.pack()
        #expect(throws: (any Error).self) { try VPhoneArchiveReader.entries(of: fixture.archive, maximumEntries: 1) }
    }
}

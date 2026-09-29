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
    var installed: URL { store.root.appendingPathComponent("2.0.8-local") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bundle-store-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        source = directory.appendingPathComponent("VPhone.bundle")
        archive = directory.appendingPathComponent("input.tar")
        store = VPhoneCoreBundleStore(testRoot: directory.appendingPathComponent("store"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": "com.vphone.store-test", "CFBundleName": "VPhone",
            "CFBundleExecutable": "vphone-cli", "CFBundlePackageType": "BNDL", "CFBundleShortVersionString": "2.0.8"]
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
    func install(digest: String? = nil) throws -> VPhoneBundleReceipt {
        let expected = try digest ?? pack()
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        return try store.install(version: "2.0.8-local", archive: input, sha256: expected)
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
        let verified = try fixture.store.verify(version: "2.0.8-local")
        #expect(receipt.sha256 == verified.sha256)
        #expect(verified.cdhashes.count == 2)
        for file in [fixture.installed.appendingPathComponent("receipt.json"), fixture.store.root.appendingPathComponent(".store.lock")] {
            #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o644)
        }
        try fixture.store.withVerifiedExecutable(version: "2.0.8-local", executable: .cli) { url in
            #expect(url.lastPathComponent == "vphone-cli")
            #expect(url.path.hasPrefix(fixture.installed.path + "/"))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.root.path).sorted() == [".store.lock", "2.0.8-local"])
    }

    @Test func acceptsUpstreamResourceBundleLayout() throws {
        let fixture = try BundleFixture()
        let plist = fixture.source.appendingPathComponent("Contents/Info.plist")
        var value = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: String])
        value.removeValue(forKey: "CFBundleExecutable")
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: plist)
        _ = try fixture.install()
        _ = try fixture.store.verify(version: "2.0.8-local")
    }

    @Test(arguments: ["../2.0.8", "2.0.8/other", "2.0.7", "2.0.8\n", "2.0.8-local/", "-2.0.8", "9999999999999999999999.0.0"])
    func invalidVersionRefusedBeforeStoreCreation(_ version: String) throws {
        let fixture = try BundleFixture()
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/usr/bin/true"))
        defer { try? input.close() }
        #expect(throws: (any Error).self) {
            try fixture.store.install(version: version, archive: input, sha256: String(repeating: "0", count: 64))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.root.path))
    }

    @Test func digestMismatchLeavesNoPublishedVersion() throws {
        let fixture = try BundleFixture()
        _ = try fixture.pack()
        #expect(throws: (any Error).self) { try fixture.install(digest: String(repeating: "0", count: 64)) }
        #expect(!FileManager.default.fileExists(atPath: fixture.installed.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.store.root.path) == [".store.lock"])
    }

    @Test func duplicateInstallPreservesOriginalReceiptAndModes() throws {
        let fixture = try BundleFixture()
        let receipt = try fixture.install()
        let receiptURL = fixture.installed.appendingPathComponent("receipt.json")
        let before = try Data(contentsOf: receiptURL)
        let attrs = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
        #expect(throws: (any Error).self) { try fixture.install(digest: receipt.sha256) }
        #expect(try Data(contentsOf: receiptURL) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: receiptURL.path)[.posixPermissions] as? Int == attrs[.posixPermissions] as? Int)
        _ = try fixture.store.verify(version: "2.0.8-local")
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
            if mutation == "receipt-version" { value["version"] = "2.0.9" }
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
        var called = false
        #expect(throws: (any Error).self) {
            try fixture.store.withVerifiedExecutable(version: "2.0.8-local", executable: .vm) { _ in called = true }
        }
        #expect(!called)
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
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "2.0.9"], format: .xml, options: 0)
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
        _ = try fixture.store.withVerifiedExecutable(version: "2.0.8-local", executable: .cli) { _ in
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
        _ = try fixture.store.install(version: "2.0.8-local", archive: input, sha256: digest)
        #expect(try input.offset() == 37)
    }

    @Test func rejectsNonRegularDescriptor() throws {
        let fixture = try BundleFixture()
        let pipe = Pipe()
        #expect(throws: (any Error).self) {
            try fixture.store.install(version: "2.0.8-local", archive: pipe.fileHandleForReading, sha256: String(repeating: "0", count: 64))
        }
    }

    @Test func archiveReaderEntryLimit() throws {
        let fixture = try BundleFixture()
        _ = try fixture.pack()
        #expect(throws: (any Error).self) { try VPhoneArchiveReader.entries(of: fixture.archive, maximumEntries: 1) }
    }
}

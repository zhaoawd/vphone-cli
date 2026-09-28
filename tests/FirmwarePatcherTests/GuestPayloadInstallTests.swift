import Foundation
import Testing
import VPhoneCore
@testable import FirmwarePatcher

struct GuestPayloadInstallTests {
    @Test func lessInstallCopiesItsOwnPresignedPayload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = VPhoneResources(base: root)
        let target = root.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: resources.guestResources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("usr/bin"), withIntermediateDirectories: true)
        try Data("regular".utf8).write(to: resources.vphoned)
        let bytes = Data("less signed fixture".utf8)
        try bytes.write(to: resources.vphonedLess)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: resources.vphonedLess.path)
        let patcher = CryptexFilesystemPatcher(buildManiest: Data(), restoreDir: root, resources: resources)
        try patcher.addVphoned(targetMount: target.path, cfwInput: root)
        let installed = target.appendingPathComponent("usr/bin/vphoned")
        #expect(try Data(contentsOf: installed) == bytes)
        try patcher.addVphoned(targetMount: target.path, cfwInput: root)
        #expect(try Data(contentsOf: installed) == bytes)
        try FileManager.default.removeItem(at: resources.vphonedLess)
        #expect(throws: PatcherError.self) { try patcher.addVphoned(targetMount: target.path, cfwInput: root) }
        #expect(try Data(contentsOf: installed) == bytes)
    }
}

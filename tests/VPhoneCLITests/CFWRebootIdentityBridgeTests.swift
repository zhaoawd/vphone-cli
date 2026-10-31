import CryptoKit
import Foundation
import Testing
import VPhoneCore
@testable import FirmwarePatcher
@testable import vphone_cli

@Suite struct CFWRebootIdentityBridgeTests {
    @Test func mixedHistoricalAndNativeChildJournalsPreserveFullAncestryChecks() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Foundation resolves /private/tmp to /tmp, while directory enumeration
        // returns /private/tmp. Use an isolated checkout-local fixture so both
        // languages compare exactly the same namespace as the production VM.
        let f = try CFWOriginIdentityBridgeTests.FirmwareGenerationTestsFixture(parent: root.appendingPathComponent(".build"))
        let context = try VPhoneCFWFrozenContext.prepare(in: f.vm, requestedVariant: nil,
            guestEnvironment: "classic", spoofBuild: "")
        let verifier = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VPHONE_TEST_CLI"] ?? root.appendingPathComponent(".build/debug/vphone-cli").path)
        var object = try #require(JSONSerialization.jsonObject(with: Data(context.json.utf8)) as? [String: Any])
        object["verifierPath"] = verifier.path
        object["verifierSHA256"] = SHA256.hash(data: try Data(contentsOf: verifier)).map { String(format: "%02x", $0) }.joined()
        var env = ProcessInfo.processInfo.environment.merging(try context.environment) { _, new in new }
        env["VPHONE_FROZEN_CONTEXT"] = String(decoding: try JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let python = root.appendingPathComponent(".venv/bin/python3")
        let result = try VPhoneProcessRunner.runCapturing(python, [root.appendingPathComponent("scripts/vm_lock.py").path,
            f.vm.path, "cfw-record", "--", python.path,
            root.appendingPathComponent("tests/cfw_reboot_mixed_identity_fixture.py").path, f.vm.path], env: env)
        try #require(result.succeeded, Comment(rawValue: result.stdout + result.stderr))
        struct Replay: Decodable { let members: [FirmwareRebootIdentity.Member]; let postimage: String }
        let replay = try JSONDecoder().decode(Replay.self, from: Data(contentsOf: f.vm.appendingPathComponent("mixed-reboot-fixture.json")))
        let expected = try JSONDecoder().decode(VPhoneFirmwareIdentity.self,
            from: JSONSerialization.data(withJSONObject: try #require(object["identity"])))
        #expect(try FirmwareGuestDiskIdentity.matches(expected, generationID: context.generationID, in: f.vm) == false)
        let binding = try FirmwareRebootIdentity.Binding(root: f.vm, members: replay.members)
        try FirmwareRebootIdentity.$active.withValue(binding) {
            let archives = try FileManager.default.contentsOfDirectory(at: f.vm.appendingPathComponent(".cfw-history"), includingPropertiesForKeys: nil)
            for archive in archives {
                let journal = try JSONDecoder().decode(FirmwareGuestDiskIdentity.Journal.self,
                    from: Data(contentsOf: archive.appendingPathComponent("transaction.json")))
                let images = [f.vm.appendingPathComponent("Disk.img")] + archives.map { $0.appendingPathComponent("Disk.img") }
                let image = try #require(images.first {
                    guard let info = try? FirmwareGuestDiskIdentity.fileInfo($0, expectedDevice: journal.staged.dev) else { return false }
                    return journal.staged.dev == Int64(info.st_dev) && journal.staged.ino == UInt64(info.st_ino)
                }, Comment(rawValue: "No image for fixture journal " + journal.id))
                _ = try FirmwareGuestDiskIdentity.verify(archive: archive, journal: journal, image: image,
                    expected: expected, generationID: context.generationID)
                let original = try FirmwareGuestDiskIdentity.fileInfo(archive.appendingPathComponent("Disk.img"), expectedDevice: journal.original.dev)
                #expect(journal.original.matches(original), Comment(rawValue: "Original differs for " + journal.id))
            }
            #expect(try FirmwareGuestDiskIdentity.matchesRegistered(expected, generationID: context.generationID, in: f.vm))
            // Identity requalification never bypasses the sealed postimage hash.
            let image = URL(fileURLWithPath: replay.postimage)
            let data = try Data(contentsOf: image)
            try Data(repeating: 1, count: data.count).write(to: image)
            #expect(throws: (any Error).self) {
                try FirmwareGuestDiskIdentity.matchesRegistered(expected, generationID: context.generationID, in: f.vm)
            }
        }
    }
}

import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhoneCoreKit
import VPhonePatchKit
import VPhoneSign

@Suite("Duo standalone patch artifacts", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["VPHONE_PORT_SYSTEM_ROOT"] != nil, "requires copied guest inputs"))
struct DuoStandalonePatchArtifactTests {
    static var root: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["VPHONE_PORT_SYSTEM_ROOT"]!) }
    static var output: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["VPHONE_PORT_REPORT_ROOT"]!) }

    static func command(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PatcherError.invalidFormat("\(executable) failed: \(String(decoding: data, as: UTF8.self))")
        }
    }

    static func save(_ name: String, _ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try (data + Data("\n".utf8)).write(to: output.appendingPathComponent(name))
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func `all 36 real accessibility backups convert repeat and revert without residual X1`() throws {
        let images = FirmwareGuestSystemPatchSet.arm64eX1AccessibilityImages + [
            (identifier: FirmwareGuestSystemPatchSet.arm64eX1HomePopAccessibility,
             path: FirmwareGuestSystemPatchSet.homePopAccessibilityExecutablePath,
             bundle: Optional(FirmwareGuestSystemPatchSet.homePopAccessibilityBundlePath)),
        ]
        var reports: [[String: Any]] = []
        for image in images {
            let bundle = try #require(image.bundle)
            let inputURL = Self.root.appendingPathComponent(image.path + ".bak")
            let pristine = try Data(contentsOf: inputURL)
            let signedIdentifier = try VPhoneSigner.identifier(in: pristine)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let system = try VPhoneConfinedDirectory(root: folder.path)
            let targetBundle = folder.appendingPathComponent(bundle)
            try FileManager.default.createDirectory(at: targetBundle.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: Self.root.appendingPathComponent(bundle), to: targetBundle)
            // Exercise ownership transfer from the aggregate's existing backup.
            let before = try system.readData(image.path + ".bak")
            var planned = pristine
            let plan = try CustomFirmwareArm64eX1.lowerCompletelyAndReattest(&planned, identifier: image.identifier)
            #expect(!plan.result.records.isEmpty)
            let seal: (String) throws -> Void = { bundle in
                try Self.command("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", "--preserve-metadata=entitlements", folder.appendingPathComponent(bundle).path])
            }
            let apply = try CustomFirmwareArm64eX1Installation.update(
                system: system, identifier: image.identifier, path: image.path, bundle: bundle,
                enabled: true, priorApplied: true, sealBundle: seal, log: { _ in },
            )
            guard case .applied = apply else { Issue.record("\(image.identifier): did not apply"); continue }
            try Self.command("/usr/bin/codesign", ["--verify", "--strict", targetBundle.path])
            let lowered = try system.readData(image.path)
            #expect(try VPhoneSigner.identifier(in: lowered) == signedIdentifier)
            var inspected = lowered
            #expect(try CustomFirmwareArm64eX1.lowerCompletelyAndReattest(&inspected, identifier: image.identifier).result.records.isEmpty)
            #expect(try system.readData(image.path + ".bak") == before)
            let repeated = try CustomFirmwareArm64eX1Installation.update(
                system: system, identifier: image.identifier, path: image.path, bundle: bundle,
                enabled: true, priorApplied: true, sealBundle: seal, log: { _ in },
            )
            guard case .applied = repeated else { Issue.record("\(image.identifier): did not reapply"); continue }
            #expect(try system.readData(image.path) == lowered)
            let revert = try CustomFirmwareArm64eX1Installation.update(
                system: system, identifier: image.identifier, path: image.path, bundle: bundle,
                enabled: false, priorApplied: true, sealBundle: seal, log: { _ in },
            )
            guard case .inactive = revert else { Issue.record("\(image.identifier): did not revert"); continue }
            let restored = try system.readData(image.path)
            let sections = MachOParser.parseSections(from: pristine)
            for section in sections.values where section.flags & 0x8000_0400 != 0 {
                let range = Int(section.fileOffset)..<(Int(section.fileOffset) + Int(section.size))
                #expect(restored.subdata(in: range) == pristine.subdata(in: range))
            }
            #expect(try !system.exists(image.path + ".bak"))
            try Self.command("/usr/bin/codesign", ["--verify", "--strict", targetBundle.path])
            #expect(try Data(contentsOf: inputURL) == pristine)
            reports.append(["identifier": image.identifier, "path": image.path, "pristine_sha256": Self.digest(pristine),
                            "lowered_sha256": Self.digest(lowered), "instructions": plan.result.records.count,
                            "unvisited": plan.result.unvisitedCandidates, "signature_repeat_revert": true])
        }
        #expect(reports.count == 36)
        try Self.save("real-accessibility.json", reports)
    }

    @Test func `real local pairing changes three gates and remains idempotent after signing`() throws {
        let source = Self.root.appendingPathComponent("usr/libexec/remotepairingdeviced")
        let original = try Data(contentsOf: source)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try original.write(to: url)
        let records = try CustomFirmwareRemotePairing.patch(fileAt: url)
        #expect(records.count == 3)
        let patched = try Data(contentsOf: url)
        var expected = original
        for record in records { expected.replaceSubrange(record.fileOffset..<record.fileOffset + 4, with: ARM64.movW0_0) }
        #expect(patched == expected)
        let identifier = try VPhoneSigner.identifier(in: original) ?? "remotepairingdeviced"
        let entitlements = try VPhoneSigner.entitlements(in: original).first { !$0.isEmpty }
        let signed = try VPhoneSigner.sign(patched, options: .init(identifier: identifier, entitlements: entitlements, mergesExisting: true, style: .appleAdHoc))
        try signed.write(to: url)
        try Self.command("/usr/bin/codesign", ["--verify", "--strict", url.path])
        #expect(try CustomFirmwareRemotePairing.patch(fileAt: url).isEmpty)
        #expect(try Data(contentsOf: url) == signed)
        #expect(try Data(contentsOf: source) == original)
        try Self.save("real-pairing.json", ["source_sha256": Self.digest(original), "signed_sha256": Self.digest(signed),
                                          "offsets": records.map(\.fileOffset), "repeat": true])
    }
}

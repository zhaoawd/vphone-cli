@testable import FirmwarePatcher
import Foundation
import Testing

struct IM4PPayloadParityTests {
    @Test func ibssIM4PPayloadMatchesRawAndJBPatcherFindsNoncePatch() throws {
        let baseDir = firmwareFixtureDirectory

        let rawIBSS = try Data(contentsOf: baseDir.appendingPathComponent("raw_payloads/ibss.bin"))
        let (im4pPayload, _) = try IM4PHandler.load(contentsOf: baseDir.appendingPathComponent("Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"))

        #expect(im4pPayload == rawIBSS)

        let patcher = IBootJBPatcher(data: im4pPayload, mode: .ibss, verbose: false)
        let records = try patcher.findAll()
        #expect(records.count == 1)
    }

    @Test func savingIBSSIM4PRoundTripsPayload() throws {
        let baseDir = firmwareFixtureDirectory

        let sourceURL = baseDir.appendingPathComponent("Firmware/dfu/iBSS.vresearch101.RELEASE.im4p")
        let originalFile = try Data(contentsOf: sourceURL)
        let (payload, im4p) = try IM4PHandler.load(contentsOf: sourceURL)

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("im4p")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try IM4PHandler.save(patchedData: payload, originalIM4P: im4p, to: tempURL)

        let (roundTripPayload, _) = try IM4PHandler.load(contentsOf: tempURL)
        #expect(roundTripPayload == payload)
        #expect((try Data(contentsOf: tempURL)).count > originalFile.count)
    }

    @Test func savingTXMIM4PPreservesPAYPTrailer() throws {
        let baseDir = firmwareFixtureDirectory

        let sourceURL = baseDir.appendingPathComponent("Firmware/txm.iphoneos.research.im4p")
        let originalFile = try Data(contentsOf: sourceURL)
        let (payload, im4p) = try IM4PHandler.load(contentsOf: sourceURL)

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("im4p")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try IM4PHandler.save(patchedData: payload, originalIM4P: im4p, to: tempURL)

        let savedFile = try Data(contentsOf: tempURL)
        #expect(originalFile.range(of: Data("PAYP".utf8)) != nil)
        #expect(savedFile.range(of: Data("PAYP".utf8)) != nil)

        let (roundTripPayload, _) = try IM4PHandler.load(contentsOf: tempURL)
        #expect(roundTripPayload == payload)
    }
}


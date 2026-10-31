import Foundation
import Testing
import VPhoneCore
@testable import FirmwarePatcher

@Suite struct FirmwareGuestDiskIdentityReplayTests {
    struct Row: Decodable {
        let transactionID: String
        let path: String
        let runtime: FirmwareGuestDiskIdentity.RuntimeDisk?
        let disk: FirmwareGuestDiskIdentity.Disk?
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_IDENTITY_METADATA_REPLAY"] != nil))
    func actualArchivedMetadataMatchesRetainedFiles() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_IDENTITY_METADATA_REPLAY"])
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(!rows.isEmpty)
        for row in rows {
            let info = try FirmwareGuestDiskIdentity.fileInfo(URL(fileURLWithPath: row.path))
            if let runtime = row.runtime {
                #expect(runtime.matches(info), Comment(rawValue: row.transactionID + " runtime identity"))
            }
            if let disk = row.disk {
                #expect(disk.matches(info), Comment(rawValue: row.transactionID + " original identity"))
            }
        }
    }
}

extension FirmwareGuestDiskIdentityReplayTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_IDENTITY_CHECKPOINT_REPLAY"] != nil))
    func actualV4AncestorCheckpointReplaysIdentityRefusal() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VPHONE_IDENTITY_CHECKPOINT_REPLAY"])
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: String])
        let archive = URL(fileURLWithPath: try #require(object["archive"]))
        let journal = try JSONDecoder().decode(FirmwareGuestDiskIdentity.Journal.self,
            from: Data(contentsOf: archive.appendingPathComponent("transaction.json")))
        let identity = try JSONDecoder().decode(VPhoneFirmwareIdentity.self,
            from: Data(contentsOf: URL(fileURLWithPath: try #require(object["identity"]))))
        do {
            _ = try FirmwareGuestDiskIdentity.verify(archive: archive, journal: journal,
                image: URL(fileURLWithPath: try #require(object["image"])),expected: identity,
                generationID: try #require(object["generationID"]))
            Issue.record("The incomplete historical checkpoint unexpectedly gained identity qualification")
        } catch let error as FirmwareGeneration.Failure {
            #expect(error.message == "CFW identity input is missing, linked or shared")
        }
    }
}

import Foundation
import VPhoneCore

/// Producer evidence consumed by the transaction receipt integration. This file
/// is not a second commit ledger and records no installed/activated state.
struct FirmwareFilesystemEvidence: Codable, Equatable {
    static let filename = "filesystem-output-proof.json"
    static let treeFilename = "filesystem-tree-proof.json"
    let schemaVersion: Int
    let generationID: String
    let planSHA256: String
    let desiredSHA256: String
    let imagePath: String
    let imageSHA256: String
    let treeProofSHA256: String
    let operationsSHA256: String

    static func capture(image: URL, transaction: FirmwareTransaction) throws -> Self {
        guard let generation = transaction.journalSnapshot.options["generationID"],
              let desired = transaction.journalSnapshot.options["desiredSHA256"],
              let plan = transaction.journalSnapshot.planBinding?.planSHA256 else {
            throw FirmwareGeneration.fail("Unqualified filesystem producer")
        }
        let digest = try FirmwareGeneration.fileSHA256(image)
        _ = try FirmwareFilesystemReadback(image: image, expectedSHA256: digest, transaction: transaction)
        return Self(schemaVersion: 1, generationID: generation, planSHA256: plan, desiredSHA256: desired,
            imagePath: try FirmwareComponentReceipt.relative(image, in: transaction.stage), imageSHA256: digest,
            treeProofSHA256: try FirmwareGeneration.fileSHA256(transaction.root.appendingPathComponent(treeFilename)),
            operationsSHA256: try FirmwareGeneration.fileSHA256(transaction.root.appendingPathComponent("guest-changes.jsonl")))
    }

    func verify(image: URL, transaction: FirmwareTransaction, environment: [String: String]?) throws {
        let journal = transaction.journalSnapshot
        guard schemaVersion == 1, journal.options["generationID"] == generationID,
              journal.options["desiredSHA256"] == desiredSHA256,
              journal.planBinding?.planSHA256 == planSHA256,
              image == transaction.stage.appendingPathComponent(imagePath) || image == transaction.vmDirectory.appendingPathComponent(imagePath),
              try FirmwareGeneration.fileSHA256(transaction.root.appendingPathComponent(Self.treeFilename)) == treeProofSHA256,
              try FirmwareGeneration.fileSHA256(transaction.root.appendingPathComponent("guest-changes.jsonl")) == operationsSHA256 else {
            throw FirmwareGeneration.fail("Filesystem producer evidence differs")
        }
        let reader = try FirmwareFilesystemReadback(image: image, expectedSHA256: imageSHA256, transaction: transaction)
        try reader.withReadOnlyFilesystem(at: image, transaction: transaction) { mount in
            try Self.runProof("verify", mount: mount, transaction: transaction, environment: environment)
        }
    }

    func persist(in transaction: FirmwareTransaction) throws {
        try FirmwareGeneration.write(FirmwareGeneration.encode(self), to: transaction.root.appendingPathComponent(Self.filename))
    }

    static func runProof(_ mode: String, mount: URL, transaction: FirmwareTransaction, environment: [String: String]?) throws {
        guard let environment,
              environment["VPHONE_GUEST_EVIDENCE"] == transaction.root.appendingPathComponent("guest-changes.jsonl").path else {
            throw FirmwareGeneration.fail("Missing qualified filesystem proof context")
        }
        let resources = VPhoneResources.resolve()
        let python = try resources.pythonExecutable()
        let script = resources.scriptsDir.appendingPathComponent("verify_component_effects.py")
        _ = try transaction.runTool("/usr/bin/env", environment.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }
            + [python.path, script.path, mode, mount.path, transaction.root.appendingPathComponent(treeFilename).path])
    }
}

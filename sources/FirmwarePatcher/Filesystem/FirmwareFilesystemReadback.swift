import Foundation

/// Internal scoped readback of a final encrypted image. The qualification is
/// rechecked at each use; storing this value does not authorize a later write.
struct FirmwareFilesystemReadback {
    struct Attachment {
        let image: URL
        let device: String
        let mount: URL
        let readOnly: Bool
    }
    struct Operations {
        let decrypt: (URL) throws -> URL
        let attach: (URL) throws -> Attachment
        let detach: (Attachment) throws -> Void
    }
    let image: URL
    let expectedSHA256: String

    init(image: URL, expectedSHA256: String, transaction: FirmwareTransaction) throws {
        self.image = image
        self.expectedSHA256 = expectedSHA256
        try qualify(transaction)
    }

    func withReadOnlyFilesystem<T>(at image: URL, transaction: FirmwareTransaction,
                                   body: (URL) throws -> T) throws -> T {
        let patcher = CryptexFilesystemPatcher(buildManiest: Data(), restoreDir: image.deletingLastPathComponent(), verbose: false)
        patcher.transaction = transaction
        return try withReadOnlyFilesystem(at: image, transaction: transaction, operations: Operations(
            decrypt: { try patcher.decryptAeaFile($0) },
            attach: { decrypted in
                let (device, mount) = try patcher.attachImage(path: decrypted, readonly: true)
                do {
                    let mountURL = URL(fileURLWithPath: mount)
                    let readOnly = try mountURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true
                    let attachment = Attachment(image: decrypted, device: device, mount: mountURL, readOnly: readOnly)
                    let data = try transaction.runTool("/usr/bin/hdiutil", ["info", "-plist"])
                    try Self.verifyAssociation(attachment, info: data)
                    return attachment
                } catch {
                    // If association validation fails, only the just-returned
                    // device is eligible for detach; never infer another disk.
                    try patcher.detachImage(deviceNode: device)
                    throw error
                }
            },
            detach: { try patcher.detachImage(deviceNode: $0.device) }), body: body)
    }

    func withReadOnlyFilesystem<T>(at image: URL, transaction: FirmwareTransaction,
                                   operations: Operations, body: (URL) throws -> T) throws -> T {
        guard image.standardizedFileURL == self.image.standardizedFileURL else {
            throw FirmwareGeneration.fail("Final filesystem image association differs")
        }
        try qualify(transaction)
        let decrypted = try operations.decrypt(image)
        _ = try FirmwareComponentReceipt.relative(decrypted, in: transaction.work)
        _ = try FirmwareGeneration.fileSHA256(decrypted)
        let attachment = try operations.attach(decrypted)
        let value: T
        do {
            guard attachment.image == decrypted, attachment.readOnly, !attachment.device.isEmpty else {
                throw FirmwareGeneration.fail("Invalid read-only filesystem attachment")
            }
            _ = try FirmwareComponentReceipt.relative(attachment.mount, in: transaction.work)
            try FirmwareGeneration.ensureDirectory(attachment.mount, create: false)
            value = try body(attachment.mount)
        } catch {
            try operations.detach(attachment)
            throw error
        }
        // Detach failure is a failed proof, with work retained for recovery.
        try operations.detach(attachment)
        try qualify(transaction)
        return value
    }

    static func verifyAssociation(_ attachment: Attachment, info data: Data) throws {
        guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = object["images"] as? [[String: Any]] else { throw FirmwareGeneration.fail("Missing filesystem image association") }
        let matches = images.filter { ($0["image-path"] as? String) == attachment.image.path }
        guard matches.count == 1, let image = matches.first,
              attachment.readOnly,
              let entities = image["system-entities"] as? [[String: Any]],
              entities.filter({ ($0["dev-entry"] as? String) == attachment.device &&
                                ($0["mount-point"] as? String) == attachment.mount.path }).count == 1 else {
            throw FirmwareGeneration.fail("Filesystem mount is not the unique read-only image association")
        }
    }

    private func qualify(_ transaction: FirmwareTransaction) throws {
        let journal = transaction.journalSnapshot
        guard let binding = journal.planBinding,
              let generationID = journal.options["generationID"],
              case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: transaction.vmDirectory),
              desired.generationID == generationID, desired.plan == journal.plan,
              try desired.sha256 == journal.options["desiredSHA256"] else {
            throw FirmwareGeneration.fail("Filesystem reader requires bound generation and desired plan")
        }
        try binding.validate(journal: journal, directory: transaction.vmDirectory, currentCatalog: true)
        let root = image.path.hasPrefix(transaction.stage.path + "/") ? transaction.stage : transaction.vmDirectory
        let relative = try FirmwareComponentReceipt.relative(image, in: root)
        guard let first = relative.split(separator: "/").first,
              journal.entries.contains(where: { $0.name == first }),
              try FirmwareGeneration.fileSHA256(image) == expectedSHA256 else {
            throw FirmwareGeneration.fail("Final filesystem image differs from qualified candidate")
        }
    }
}

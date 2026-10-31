import Darwin
import Foundation
import VPhoneCore

/// A committed CFW swap can preserve a generation's machine association while
/// replacing the physical disk inode. This checks only that continuity; it
/// never grants component effects, Undo permission or installed origin trust.
enum FirmwareGuestDiskIdentity {
    struct Disk: Decodable, Equatable {
        let dev: Int64
        let ino: UInt64
        let size: Int64
        let mtime_ns: Int64
        func matches(_ info: stat) -> Bool {
            dev == Int64(info.st_dev) && ino == UInt64(info.st_ino) && size == Int64(info.st_size) &&
                mtime_ns == Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        }
    }
    struct RuntimeDisk: Decodable {
        let dev: Int64
        let ino: UInt64
        let size: Int64
        let birthtime: Double
        func matches(_ info: stat) -> Bool {
            dev == Int64(info.st_dev) && ino == UInt64(info.st_ino) && size == Int64(info.st_size) &&
                birthtime == Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) * 1e-9
        }
    }
    struct Journal: Decodable {
        struct Check: Decodable { let unchanged: Bool }
        struct Undo: Decodable { let indexSHA256: String; let finalProofSHA256: String; let operationsSHA256: String }
        let version: Int
        let id: String
        let vm: String
        let status: String
        let provenanceMode: String
        let runtimeImageEvidenceRequired: Bool?
        let guestEvidenceRequired: Bool
        let guestEvidenceSHA256: String
        let original: Disk
        let staged: Disk
        let original_check: Check
        let undoProvenance: Undo
        let operation: String?
        let guestUndoRequestSHA256: String?
        let fileOriginalsSHA256: String?
        let guestOriginSourceSHA256: String?
        let guestOriginTransitionSHA256: String?
        let guestOriginAttestationSHA256: String?
        let guestOriginInvalidationSHA256: String?
    }
    struct Checkpoint: Decodable {
        let schemaVersion: Int
        let transactionID: String
        let vmDirectory: String
        let generationID: String
        let planDigest: String
        let desiredSHA256: String
        let imageIdentity: Disk
        let runtimeIdentity: RuntimeDisk?
        let postimageIdentity: Disk?
        let imageSHA256: String
        let files: [String: String]
        let blobs: [String: Int64]
    }
    struct Context: Decodable {
        let schemaVersion: Int
        let vmDirectory: String
        let generationID: String
        let identity: VPhoneFirmwareIdentity
        let planSHA256: String
        let catalogSHA256: String
        let upstreamTarget: String
    }
    struct Final: Decodable {
        struct Output: Decodable { let target: String }
        let schemaVersion: Int
        let transactionID: String
        let generationID: String
        let planDigest: String
        let desiredSHA256: String
        let stagedIdentity: Disk
        let operationsSHA256: String
        let undoProvenanceSHA256: String
        let outputs: [Output]
    }
    struct Index: Decodable {
        let schemaVersion: Int
        let state: String
        let generationID: String
        let planSHA256: String
        let desiredSHA256: String
        let fileOriginalsSHA256: String?
    }
    struct Row: Decodable {
        let schemaVersion: Int
        let generationID: String
        let planDigest: String
        let desiredSHA256: String
    }
    struct Request: Decodable {
        struct Selection: Decodable {
            struct Entry: Decodable { let kind: String? }
            let entries: [Entry]
        }
        let schemaVersion: Int
        let transactionID: String
        let vmDirectory: String
        let parentTransactionID: String
        let parentCheckpointSHA256: String
        let selection: Selection?
    }

    static func matches(_ expected: VPhoneFirmwareIdentity, generationID: String, in directory: URL) throws -> Bool {
        let registration = try FirmwareRebootIdentity.load(in: directory, generationID: generationID)
        return try FirmwareRebootIdentity.$active.withValue(registration) {
            try matchesRegistered(expected, generationID: generationID, in: directory)
        }
    }

    static func matchesRegistered(_ expected: VPhoneFirmwareIdentity, generationID: String, in directory: URL) throws -> Bool {
        let actual = try VPhoneFirmwareIdentity.read(in: directory)
        if actual == expected { return true }
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard actual.machineIdentifierSHA256 == expected.machineIdentifierSHA256,
              actual.diskName == expected.diskName, actual.diskName == "Disk.img" else { return false }
        let history = directory.appendingPathComponent(".cfw-history")
        var info = stat()
        if lstat(history.path, &info) != 0, errno == ENOENT { return false }
        try FirmwareGeneration.ensureDirectory(history, create: false)
        var nodes: [(URL, Journal)] = []
        for archive in try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil) {
            try FirmwareGeneration.ensureDirectory(archive, create: false)
            let raw = try bytes(archive.appendingPathComponent("transaction.json"))
            let header = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
            if let version = header?["version"] as? Int, version == 1 || version == 2 { continue }
            if header?["status"] as? String != "published" { continue }
            let journal = try JSONDecoder().decode(Journal.self, from: raw)
            guard [3, 4, 5].contains(journal.version),
                  (journal.version >= 4 ? journal.runtimeImageEvidenceRequired == true : journal.runtimeImageEvidenceRequired == nil), journal.id == archive.lastPathComponent, journal.vm == directory.path,
                  journal.provenanceMode == "required", journal.guestEvidenceRequired else {
                throw FirmwareGeneration.fail("CFW identity journal differs from this machine")
            }
            if journal.status == "published", journal.original_check.unchanged { nodes.append((archive, journal)) }
        }
        var cursor = directory.appendingPathComponent("Disk.img")
        var visited: Set<String> = []
        var parent: (id: String, sha256: String)?
        for _ in 0..<64 {
            let current = try fileInfo(cursor, expectedDevice: expected.diskDevice)
            if matchesPhysical(expected, current) {
                guard parent == nil else { return false }
                return try VPhoneFirmwareIdentity.read(in: directory) == actual
            }
            let candidates = try nodes.filter { node in
                let info = try fileInfo(cursor, expectedDevice: node.1.staged.dev)
                return node.1.staged.dev == Int64(info.st_dev) && node.1.staged.ino == UInt64(info.st_ino)
            }
            guard candidates.count == 1, let (archive, journal) = candidates.first,
                  visited.insert(journal.id).inserted,
                  parent == nil || (parent?.id == journal.id && parent?.sha256 == journal.guestEvidenceSHA256) else { return false }
            let request = try verify(archive: archive, journal: journal, image: cursor,
                                     expected: expected, generationID: generationID)
            let originals = ["Disk.img", "Disk.img.previous"].map { archive.appendingPathComponent($0) }.filter {
                guard let info = try? fileInfo($0, expectedDevice: journal.original.dev) else { return false }
                return journal.original.matches(info)
            }
            guard originals.count == 1 else { return false }
            cursor = originals[0]
            parent = request.map { ($0.parentTransactionID, $0.parentCheckpointSHA256) }
        }
        throw FirmwareGeneration.fail("CFW identity ancestry is cyclic or exceeds 64 publications")
    }

    static func verify(archive: URL, journal: Journal, image: URL,
                       expected: VPhoneFirmwareIdentity, generationID: String) throws -> Request? {
        let raw = try bytes(archive.appendingPathComponent("guest-publication.json"))
        guard VPhoneCreateDigest.sha256(raw) == journal.guestEvidenceSHA256 else {
            throw FirmwareGeneration.fail("CFW checkpoint differs from identity journal")
        }
        let checkpoint = try JSONDecoder().decode(Checkpoint.self, from: raw)
        var names: Set<String> = ["guest-plan.json", "guest-context.json", "guest-changes.jsonl", "guest-effects-final.json", "guest-undo-provenance.json"]
        if let operation = journal.operation {
            guard operation == (journal.version == 5 ? "guest-component-undo-v2" : "guest-dsc-undo-v1") else {
                throw FirmwareGeneration.fail("Unknown CFW identity operation")
            }
            names.formUnion(["guest-undo-request.json", "guest-undo-applied.json", "guest-component-receipts.json"])
        } else if journal.version == 5 {
            names.insert("guest-install-receipts.json")
        }
        if let originals = journal.fileOriginalsSHA256 {
            guard journal.version == 5, FirmwareGeneration.validDigest(originals),
                  checkpoint.files["guest-file-originals.json"] == originals else {
                throw FirmwareGeneration.fail("CFW file original catalog differs from identity journal")
            }
            names.insert("guest-file-originals.json")
        }
        names.formUnion(try originEvidenceFiles(journal: journal, files: checkpoint.files))
        let current = try fileInfo(image, expectedDevice: journal.staged.dev)
        let validImage: Bool
        if journal.version >= 4 {
            // The sealed postimage proves the historical publication. Physical
            // continuity only associates the running image with this generation.
            // Actual Undo still verifies current target bytes and code pages.
            let postimage = archive.appendingPathComponent("guest-postimage.img")
            let postInfo = try fileInfo(postimage, expectedDevice: checkpoint.postimageIdentity?.dev)
            let postDigest = try FirmwareGeneration.fileSHA256(postimage)
            validImage = checkpoint.schemaVersion == (journal.version == 5 ? 3 : 2) && checkpoint.runtimeIdentity?.matches(current) == true &&
                checkpoint.runtimeIdentity?.dev == checkpoint.imageIdentity.dev &&
                checkpoint.runtimeIdentity?.ino == checkpoint.imageIdentity.ino &&
                checkpoint.runtimeIdentity?.size == checkpoint.imageIdentity.size &&
                checkpoint.postimageIdentity?.matches(postInfo) == true && postDigest == checkpoint.imageSHA256
        } else {
            let digest = try FirmwareGeneration.fileSHA256(image)
            validImage = checkpoint.schemaVersion == 1 && checkpoint.imageIdentity.matches(current) &&
                digest == checkpoint.imageSHA256
        }
        guard validImage, checkpoint.transactionID == journal.id,
              checkpoint.vmDirectory == journal.vm, checkpoint.generationID == generationID,
              journal.staged.dev == Int64(current.st_dev), journal.staged.ino == UInt64(current.st_ino),
              Set(checkpoint.files.keys) == names else {
            throw FirmwareGeneration.fail("CFW disk identity has no matching complete checkpoint")
        }
        var contents: [String: Data] = [:]
        for (name, digest) in checkpoint.files {
            let data = try bytes(archive.appendingPathComponent(name))
            guard VPhoneCreateDigest.sha256(data) == digest else { throw FirmwareGeneration.fail("CFW identity evidence changed: \(name)") }
            contents[name] = data
        }
        let plan = try JSONDecoder().decode(FirmwareDesiredPlanStore.Record.self, from: contents["guest-plan.json"]!)
        let context = try JSONDecoder().decode(Context.self, from: contents["guest-context.json"]!)
        let final = try JSONDecoder().decode(Final.self, from: contents["guest-effects-final.json"]!)
        let index = try JSONDecoder().decode(Index.self, from: contents["guest-undo-provenance.json"]!)
        guard plan.identity == expected, plan.generationID == generationID,
              try plan.sha256 == checkpoint.desiredSHA256, checkpoint.files["guest-plan.json"] == checkpoint.desiredSHA256,
              try FirmwareGeneration.planDigest(plan.plan) == checkpoint.planDigest, plan.planSHA256 == checkpoint.planDigest,
              context.schemaVersion == 1, context.identity == expected, context.generationID == generationID,
              context.vmDirectory == journal.vm, context.planSHA256 == plan.planSHA256,
              context.catalogSHA256 == plan.catalogSHA256, context.upstreamTarget == plan.upstreamTarget,
              final.schemaVersion == 1, final.transactionID == journal.id, final.generationID == generationID,
              final.planDigest == plan.planSHA256, final.desiredSHA256 == checkpoint.desiredSHA256,
              final.stagedIdentity == checkpoint.imageIdentity, !final.outputs.isEmpty,
              final.operationsSHA256 == checkpoint.files["guest-changes.jsonl"],
              final.undoProvenanceSHA256 == checkpoint.files["guest-undo-provenance.json"],
              journal.undoProvenance.indexSHA256 == final.undoProvenanceSHA256,
              journal.undoProvenance.finalProofSHA256 == checkpoint.files["guest-effects-final.json"],
              journal.undoProvenance.operationsSHA256 == final.operationsSHA256,
              index.schemaVersion == (journal.fileOriginalsSHA256 == nil ? 1 : 2),
              index.fileOriginalsSHA256 == journal.fileOriginalsSHA256,
              index.state == "qualified-preimages-not-migration-authority",
              index.generationID == generationID, index.planSHA256 == plan.planSHA256,
              index.desiredSHA256 == checkpoint.desiredSHA256 else {
            throw FirmwareGeneration.fail("CFW identity qualification differs from the saved generation/plan")
        }
        if journal.version == 5 && journal.operation == nil {
            let receipt = try JSONSerialization.jsonObject(with: contents["guest-install-receipts.json"]!) as? [String: Any]
            guard receipt?["schemaVersion"] as? Int == 1, receipt?["component"] as? String == "Guest",
                  receipt?["scope"] as? String == "installed-component-effects", receipt?["state"] as? String == "committed",
                  receipt?["transactionID"] as? String == journal.id, receipt?["generationID"] as? String == generationID,
                  receipt?["planDigest"] as? String == checkpoint.planDigest,
                  receipt?["desiredSHA256"] as? String == checkpoint.desiredSHA256,
                  receipt?["imageSHA256"] as? String == checkpoint.imageSHA256 else {
                throw FirmwareGeneration.fail("CFW ordinary receipt differs from identity qualification")
            }
        }
        if journal.fileOriginalsSHA256 != nil {
            let originals = try JSONSerialization.jsonObject(with: contents["guest-file-originals.json"]!) as? [String: Any]
            guard originals?["schemaVersion"] as? Int == 1, originals?["transactionID"] as? String == journal.id,
                  originals?["vmDirectory"] as? String == journal.vm,
                  originals?["generationID"] as? String == generationID,
                  originals?["planSHA256"] as? String == checkpoint.planDigest,
                  originals?["desiredSHA256"] as? String == checkpoint.desiredSHA256 else {
                throw FirmwareGeneration.fail("CFW file originals differ from identity qualification")
            }
        }
        let rows = contents["guest-changes.jsonl"]!.split(separator: 10)
        if rows.isEmpty {
            let request = try contents["guest-undo-request.json"].map { try JSONDecoder().decode(Request.self, from: $0) }
            guard journal.version == 5, journal.operation == "guest-component-undo-v2",
                  let entries = request?.selection?.entries, !entries.isEmpty,
                  entries.allSatisfy({ ["macho", "data"].contains($0.kind ?? "") }) else {
                throw FirmwareGeneration.fail("CFW identity journal has no effects")
            }
        }
        for raw in rows {
            let row = try JSONDecoder().decode(Row.self, from: Data(raw))
            guard row.schemaVersion == 1, row.generationID == generationID, row.planDigest == plan.planSHA256,
                  row.desiredSHA256 == checkpoint.desiredSHA256 else { throw FirmwareGeneration.fail("CFW identity effect qualification differs") }
        }
        let store = archive.appendingPathComponent("effect-blobs")
        try FirmwareGeneration.ensureDirectory(store, create: false)
        guard Set(try FileManager.default.contentsOfDirectory(atPath: store.path)) == Set(checkpoint.blobs.keys) else {
            throw FirmwareGeneration.fail("CFW identity blob set differs")
        }
        for (digest, size) in checkpoint.blobs {
            let file = store.appendingPathComponent(digest)
            guard FirmwareGeneration.validDigest(digest), try fileInfo(file).st_size == size,
                  try FirmwareGeneration.fileSHA256(file) == digest else { throw FirmwareGeneration.fail("CFW identity blob differs") }
        }
        guard VPhoneCreateDigest.sha256(try bytes(archive.appendingPathComponent("guest-publication.json"))) == journal.guestEvidenceSHA256 else {
            throw FirmwareGeneration.fail("CFW identity checkpoint changed during verification")
        }
        if journal.operation != nil {
            let data = contents["guest-undo-request.json"]!
            let request = try JSONDecoder().decode(Request.self, from: data)
            guard VPhoneCreateDigest.sha256(data) == journal.guestUndoRequestSHA256,
                  request.schemaVersion == 1, request.transactionID == journal.id, request.vmDirectory == journal.vm else {
                throw FirmwareGeneration.fail("CFW identity Undo parent differs")
            }
            return request
        }
        return nil
    }

    /// Bind the additional source records to this checkpoint without granting
    /// producer trust. Store qualification remains the native producer's job.
    static func originEvidenceFiles(journal: Journal, files: [String: String]) throws -> Set<String> {
        let source: [(String, String?)] = [
            ("guest-origin-source.json", journal.guestOriginSourceSHA256),
            ("guest-origin-transition.json", journal.guestOriginTransitionSHA256),
            ("guest-origin-attestation.json", journal.guestOriginAttestationSHA256),
        ]
        let present = source.filter { $0.1 != nil }
        var bindings = present
        if !present.isEmpty {
            guard present.count == source.count, journal.guestOriginInvalidationSHA256 == nil else {
                throw FirmwareGeneration.fail("CFW identity source journal is incomplete or conflicting")
            }
        }
        if let invalidation = journal.guestOriginInvalidationSHA256 {
            bindings.append(("guest-origin-invalidation.json", invalidation))
        }
        if !bindings.isEmpty {
            guard journal.version == 5, journal.operation == nil else {
                throw FirmwareGeneration.fail("CFW identity source belongs to another operation")
            }
        }
        for (name, digest) in bindings {
            guard let digest, FirmwareGeneration.validDigest(digest), files[name] == digest else {
                throw FirmwareGeneration.fail("CFW identity source differs from sealed journal: \(name)")
            }
        }
        return Set(bindings.map { $0.0 })
    }

    static func fileInfo(_ file: URL, expectedDevice: Int64? = nil) throws -> stat {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
            throw FirmwareGeneration.fail("CFW identity input is missing, linked or shared")
        }
        // New journals retain the actual device number. Apply a registered
        // historical association only for a comparison that expects it.
        guard let expectedDevice, expectedDevice != Int64(info.st_dev),
              let translated = try FirmwareRebootIdentity.active?.translate(info, at: file),
              Int64(translated.st_dev) == expectedDevice else { return info }
        return translated
    }
    static func bytes(_ file: URL) throws -> Data {
        _ = try fileInfo(file)
        return try VPhoneCreateDigest.strictFileData(file, maximumBytes: 64 << 20)
    }
    static func matchesPhysical(_ expected: VPhoneFirmwareIdentity, _ info: stat) -> Bool {
        expected.diskDevice == Int64(info.st_dev) && expected.diskInode == UInt64(info.st_ino) &&
            expected.diskBirthSeconds == Int64(info.st_birthtimespec.tv_sec) &&
            expected.diskBirthNanoseconds == Int64(info.st_birthtimespec.tv_nsec)
    }
}

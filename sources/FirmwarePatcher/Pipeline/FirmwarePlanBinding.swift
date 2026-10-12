import CryptoKit
import Darwin
import Foundation
import VPhoneCore

/// Context of one resolved transaction, stored inside its existing journal.
/// This is evidence for commit/recovery, not a loadable desired configuration.
struct FirmwarePlanBinding: Codable, Equatable {
    struct Source: Codable, Equatable {
        let name: String
        let originalSHA256: String
    }
    struct Payload: Codable, Equatable {
        let vmDirectoryId: String
        var stableIdentity: VPhoneFirmwareIdentity? = nil
        var generationID: String? = nil
        let configSHA256: String?
        let upstreamTarget: String
        let catalogRevision: String
        let catalogSHA256: String
        let plan: VariantPlanResolver.VariantPlan
        let versionInputs: FirmwareVersionInputs
        let sources: [Source]
        let options: [String: String]
    }
    let schemaVersion: Int
    let planSHA256: String
    let contextSHA256: String
    let payload: Payload

    static func capture(directory: URL, plan: VariantPlanResolver.VariantPlan,
                        versions: FirmwareVersionInputs, entries: [FirmwareTransaction.Entry],
                        options: [String: String]) throws -> Self {
        guard options["variant"] == plan.variant, plan.gates.variant == plan.variant else {
            throw FirmwareTransaction.RecordFailure.bindingMismatch("variant")
        }
        if let id = options["generationID"] {
            let generation = try FirmwareGeneration.loadVerified(in: directory, id: id)
            guard generation.content.originals.map({ Source(name: $0.name, originalSHA256: $0.sha256) }) == sources(entries) else {
                throw FirmwareTransaction.RecordFailure.bindingMismatch("generation original set")
            }
        }
        let payload = Payload(vmDirectoryId: "", stableIdentity: try VPhoneFirmwareIdentity.read(in: directory), generationID: options["generationID"],
            configSHA256: nil,
            upstreamTarget: "2d21d21fbdd4f51f013616273ceda9b35a3e0789",
            catalogRevision: PatchDeclarationCatalog.upstreamTag,
            catalogSHA256: try catalogDigest(), plan: plan, versionInputs: versions,
            sources: sources(entries), options: options)
        return Self(schemaVersion: 2, planSHA256: try digest(plan), contextSHA256: try Self.digest(payload), payload: payload)
    }

    func validate(journal: FirmwareTransaction.Journal, directory: URL, currentCatalog: Bool) throws {
        guard schemaVersion == 1 || schemaVersion == 2 else { throw FirmwareTransaction.RecordFailure.unsupportedBinding(schemaVersion) }
        guard try Self.digest(payload) == contextSHA256, try Self.digest(payload.plan) == planSHA256,
              payload.plan == journal.plan, payload.versionInputs == journal.versionInputs,
              payload.options == journal.options, payload.sources == Self.sources(journal.entries),
              payload.options["variant"] == payload.plan.variant,
              payload.plan.gates.variant == payload.plan.variant else {
            throw FirmwareTransaction.RecordFailure.bindingMismatch("record content")
        }
        if schemaVersion == 1 {
            guard !currentCatalog else {
                throw FirmwareTransaction.RecordFailure.bindingMismatch("legacy binding is recovery-only")
            }
            guard payload.stableIdentity == nil, payload.generationID == nil,
                  try Self.directoryIdentity(directory) == payload.vmDirectoryId,
                  try Self.configDigest(directory) == payload.configSHA256 else {
                throw FirmwareTransaction.RecordFailure.bindingMismatch("legacy VM identity/configuration")
            }
        } else {
            guard let identity = payload.stableIdentity,
                  try VPhoneFirmwareIdentity.read(in: directory) == identity else {
                throw FirmwareTransaction.RecordFailure.bindingMismatch("stable VM identity/disk")
            }
        }
        if schemaVersion == 2 {
            guard payload.generationID == payload.options["generationID"] else {
                throw FirmwareTransaction.RecordFailure.bindingMismatch("generation association")
            }
            if let id = payload.generationID {
                let generation = try FirmwareGeneration.loadVerified(in: directory, id: id)
                guard generation.content.originals.map({ Source(name: $0.name, originalSHA256: $0.sha256) }) == payload.sources else {
                    throw FirmwareTransaction.RecordFailure.bindingMismatch("generation originals")
                }
            }
        }
        if currentCatalog {
            guard payload.catalogRevision == PatchDeclarationCatalog.upstreamTag,
                  try Self.catalogDigest() == payload.catalogSHA256 else {
                throw FirmwareTransaction.RecordFailure.bindingMismatch("catalog")
            }
        }
    }

    private static func sources(_ entries: [FirmwareTransaction.Entry]) -> [Source] {
        entries.map { Source(name: $0.name, originalSHA256: $0.original) }.sorted { $0.name < $1.name }
    }

    private static func directoryIdentity(_ directory: URL) throws -> String {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw FirmwareTransaction.RecordFailure.bindingMismatch("VM directory") }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private static func configDigest(_ directory: URL) throws -> String? {
        let file = directory.appendingPathComponent("config.plist")
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= 8 << 20 else {
            throw FirmwareTransaction.RecordFailure.bindingMismatch("VM configuration file")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: Int(before.st_size) + 1) ?? Data()
        guard data.count == before.st_size, fstat(fd, &after) == 0,
              before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw FirmwareTransaction.RecordFailure.bindingMismatch("VM configuration changed while reading")
        }
        return sha(data)
    }

    /// Declaration variants are sets. Normalize them before catalog hashing.
    static func catalogDigest() throws -> String {
        let encoder = JSONEncoder()
        var objects: [[String: Any]] = []
        for declaration in PatchDeclarationCatalog.all.sorted(by: { $0.id < $1.id }) {
            guard var value = try JSONSerialization.jsonObject(with: encoder.encode(declaration)) as? [String: Any] else {
                throw FirmwareTransaction.RecordFailure.corrupt
            }
            value["variants"] = declaration.variants.sorted()
            objects.append(value)
        }
        return sha(try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha(try encoder.encode(value))
    }
    private static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

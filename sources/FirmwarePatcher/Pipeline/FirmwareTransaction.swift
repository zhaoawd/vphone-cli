import CryptoKit
import Darwin
import Foundation
import VPhoneCore

/// Owns the staged firmware tree, durable publication journal and recovery.
/// Callers hold the VM bundle lock throughout creation, execution or recovery.
final class FirmwareTransaction {
    enum Phase: String, Codable { case building, ready, publishing, rollingBack, committed }
    struct Entry: Codable, Equatable {
        let name: String
        let original: String
        var output: String?
    }
    /// Exact optional metadata targets. nil original means observed ENOENT,
    /// never an unreadable file. The old bytes remain in the same backup tree.
    struct MetadataEntry: Codable, Equatable {
        let name: String
        let original: String?
        let output: String
    }
    struct ComponentPublication: Codable, Equatable {
        static let filename = ".firmware-component-receipts.json"
        let schemaVersion: Int
        let transactionID: String
        let records: [FirmwareComponentReceipt.Record]
        let filesystem: FirmwareFilesystemEvidence?
        let filesystemProofSHA256: String?
        var installed: FirmwareComponentReceipt.Record? = nil
        var originLayer: VPhoneMachineBinding.Layer? = nil
        var originProofSHA256: String? = nil
    }
    struct Journal: Codable, Equatable {
        var version = 1
        let id: String
        let vmPath: String
        let options: [String: String]
        /// Resolution for this transaction; absent in historical journals.
        let plan: VariantPlanResolver.VariantPlan?
        let versionInputs: FirmwareVersionInputs?
        let planBinding: FirmwarePlanBinding?
        /// Exact saved run report bytes; absent in historical/manual transactions.
        var reportSHA256: String? = nil
        var componentReceiptsSHA256: String? = nil
        var metadata: [MetadataEntry]? = nil
        var phase: Phase = .building
        var entries: [Entry]
        var failure: String?
    }
    enum RecordFailure: Error, Equatable, LocalizedError {
        case missing
        case unreadable(Int32)
        case corrupt
        case unsupportedSchema(Int)
        case unsupportedBinding(Int)
        case bindingMismatch(String)
        var errorDescription: String? {
            switch self {
            case .missing: "Firmware journal is missing"
            case let .unreadable(code): "Firmware journal is unreadable (errno \(code))"
            case .corrupt: "Firmware journal is corrupt"
            case let .unsupportedSchema(version): "Unsupported firmware journal schema \(version)"
            case let .unsupportedBinding(version): "Unsupported plan binding schema \(version)"
            case let .bindingMismatch(field): "Firmware plan binding differs: \(field)"
            }
        }
    }
    enum Event: Equatable {
        case beforeCopy(String), beforeReady, beforeBackup(String), afterBackup(String)
        case afterPublish(String), afterRestore(String), beforeArchive
        case beforeMetadataWrite(String), beforeMetadataSync(String), beforeCommitted, beforeJournalSync(Phase)
        case afterToolStart
    }
    /// C constructs this only inside its live trusted-source callback. It is
    /// deliberately non-Codable; its verifier must requalify actual installed
    /// bytes and source association on every call, including after publication.
    struct InstalledOrigin {
        enum Point { case candidate, published }
        let transactionID: String
        let layer: VPhoneMachineBinding.Layer
        let expected: VPhoneMachineBinding.Snapshot
        let binding: VPhoneMachineBinding
        let receipt: FirmwareComponentReceipt.Record
        let proof: Data
        let recheck: (Point) throws -> Void
    }

    /// Internal C seam. The caller must keep the trusted-store qualification
    /// scope live for this entire synchronous call. No public version setter or
    /// decoded receipt enters this path; C supplies the actual installed adapter.
    func commit(origin: InstalledOrigin) throws -> URL {
        try verifyOrigin(origin, point: .candidate, bindingPublished: false, prepared: false)
        guard journal.phase == .building, var publication = try readPublication(), publication.installed == nil else {
            throw Self.error("Installed origin requires this transaction's prepared receipts")
        }
        publication.installed = origin.receipt
        publication.originLayer = origin.layer
        publication.originProofSHA256 = Self.sha256(origin.proof)
        try Self.writeDurably(origin.proof, to: root.appendingPathComponent("installed-component-proof.json"))
        let bytes = try Self.encoder.encode(publication)
        try Self.writeDurably(bytes, to: root.appendingPathComponent("component-receipts.json"))
        journal.componentReceiptsSHA256 = Self.sha256(bytes)
        guard let index = journal.metadata?.firstIndex(where: { $0.name == ComponentPublication.filename }),
              let original = journal.metadata?[index] else { throw Self.error("Missing receipt metadata entry") }
        journal.metadata?[index] = MetadataEntry(name: original.name, original: original.original, output: Self.sha256(bytes))
        try saveJournal()
        try Self.writeDurably(bytes, to: stage.appendingPathComponent(ComponentPublication.filename))
        try prepareMetadata(name: "launchpad.json", bytes: Self.encoder.encode(origin.binding))
        return try commit(qualifiedOrigin: origin)
    }

    private func verifyOrigin(_ origin: InstalledOrigin, point: InstalledOrigin.Point,
                              bindingPublished: Bool, bindingBackedUp: Bool = false, prepared: Bool = true) throws {
        let receipt = origin.receipt
        guard origin.transactionID == journal.id, origin.layer != .host,
              receipt.schemaVersion == 1, receipt.scope == .installedComponent, receipt.state == .committed,
              receipt.generationID == journal.options["generationID"],
              receipt.planSHA256 == journal.planBinding?.planSHA256,
              receipt.desiredSHA256 == journal.options["desiredSHA256"],
              !receipt.outputs.isEmpty, !receipt.effects.isEmpty, !origin.proof.isEmpty else {
            throw Self.error("Missing live installed-component origin qualification")
        }
        // Generated Restore/AVP outputs cannot become installed evidence by
        // changing a Codable scope value. C must identify a separate real target.
        for output in receipt.outputs {
            let file = vmDirectory.appendingPathComponent(output.path)
            guard try FirmwareComponentReceipt.relative(file, in: vmDirectory) == output.path,
                  !journal.entries.contains(where: { $0.name == output.path.split(separator: "/").first.map(String.init) }),
                  try FirmwareGeneration.fileSHA256(file) == output.sha256 else { throw Self.error("Installed origin target differs") }
        }
        let paths = Set(receipt.outputs.map(\.path))
        guard receipt.effects.allSatisfy({ paths.contains($0.outputPath) }),
              Set(receipt.outputs.map(\.path)).count == receipt.outputs.count else { throw Self.error("Installed proof target association differs") }
        let version: String?
        let components: Set<String>
        switch origin.layer {
        case .kernel: version = origin.binding.kernel; components = ["kernelcache"]
        case .guestEnvironment: version = origin.binding.guestEnvironment; components = ["guestenvironment"]
        case .bootChain: version = origin.binding.bootChain; components = ["bootchain", "ibss", "ibec", "llb", "txm", "avpbooter", "devicetree"]
        case .host: version = nil; components = []
        }
        guard components.contains(receipt.component.lowercased()) else { throw Self.error("Installed receipt layer differs") }
        guard let version, try origin.expected.binding.replacingOrigin(origin.layer, with: version) == origin.binding else {
            throw Self.error("Origin publication would change unrelated layers")
        }
        if prepared {
            guard let publication = try readPublication(), publication.installed == receipt,
                  publication.originLayer == origin.layer,
                  publication.originProofSHA256 == Self.sha256(origin.proof),
                  try FirmwareGeneration.fileSHA256(root.appendingPathComponent("installed-component-proof.json")) == publication.originProofSHA256 else {
                throw Self.error("Installed proof differs from this journal")
            }
        }
        try origin.recheck(point)
        if prepared {
            guard try FirmwareGeneration.fileSHA256(root.appendingPathComponent("installed-component-proof.json")) == Self.sha256(origin.proof) else {
                throw Self.error("Installed proof changed during qualification")
            }
        }
        try journal.planBinding?.validate(journal: journal, directory: vmDirectory, currentCatalog: true)
        try validateReport(forCommit: true)
        if bindingBackedUp {
            guard try Self.metadataDigest(vmDirectory.appendingPathComponent("launchpad.json")) == nil,
                  try Self.metadataDigest(backup.appendingPathComponent("launchpad.json")) == origin.expected.sha256 else {
                throw Self.error("VM origin backup changed during publication")
            }
        } else {
            let binding = try VPhoneMachineBinding.snapshot(vmDirectory)
            guard bindingPublished ? binding?.binding == origin.binding : binding == origin.expected else {
                throw Self.error("VM origin binding changed during publication")
            }
        }
        for output in receipt.outputs {
            guard try FirmwareGeneration.fileSHA256(vmDirectory.appendingPathComponent(output.path)) == output.sha256 else {
                throw Self.error("Installed target changed during qualification")
            }
        }
    }

    struct TransactionError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let vmDirectory: URL
    let root: URL
    var stage: URL { root.appendingPathComponent("stage") }
    var work: URL { root.appendingPathComponent("work") }
    private var backup: URL { root.appendingPathComponent("backup") }
    private var journal: Journal
    /// Read-only views for experiment records (C5); the journal stays the source of truth.
    var journalSnapshot: Journal { journal }
    private(set) var archiveURL: URL?
    private let inject: (Event) throws -> Void
    private let mounts: (URL, Bool) throws -> Void
    private let filesystemReadback: (FirmwareFilesystemEvidence, URL, FirmwareTransaction, [String: String]) throws -> Void
    private let fm = FileManager.default
    private var workerLockFD: Int32?

    init(vmDirectory: URL, inputs: [URL], options: [String: String],
         plan: VariantPlanResolver.VariantPlan? = nil,
         versionInputs: FirmwareVersionInputs? = nil,
         inject: @escaping (Event) throws -> Void = { _ in },
         mounts: @escaping (URL, Bool) throws -> Void = FirmwareTransaction.checkMounts,
         filesystemReadback: @escaping (FirmwareFilesystemEvidence, URL, FirmwareTransaction, [String: String]) throws -> Void = {
             try $0.verify(image: $1, transaction: $2, environment: $3)
         }) throws {
        self.vmDirectory = vmDirectory.standardizedFileURL.resolvingSymlinksInPath()
        root = self.vmDirectory.appendingPathComponent(".firmware-transaction")
        self.inject = inject
        self.mounts = mounts
        self.filesystemReadback = filesystemReadback
        guard !Self.exists(root) else { throw Self.error("Pending firmware transaction; run patch-firmware --recover first") }
        var entries: [Entry] = []
        for input in inputs {
            guard input.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == self.vmDirectory else {
                throw Self.error("Firmware input must be directly inside the VM directory")
            }
            try Self.validateName(input.lastPathComponent)
            entries.append(Entry(name: input.lastPathComponent, original: try Self.digest(input)))
        }
        guard !entries.isEmpty, Set(entries.map(\.name)).count == entries.count else {
            throw Self.error("Firmware transaction requires distinct inputs")
        }
        let binding: FirmwarePlanBinding?
        if let plan, let versionInputs {
            binding = try FirmwarePlanBinding.capture(directory: self.vmDirectory, plan: plan,
                versions: versionInputs, entries: entries, options: options)
        } else {
            guard plan == nil, versionInputs == nil else { throw RecordFailure.bindingMismatch("incomplete plan inputs") }
            binding = nil
        }
        journal = Journal(version: binding == nil ? 1 : 2, id: UUID().uuidString.lowercased(), vmPath: self.vmDirectory.path,
                          options: options, plan: plan, versionInputs: versionInputs, planBinding: binding, entries: entries)
        // mkdir is exclusive. Never reuse another run's transaction directory.
        guard mkdir(root.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try Self.syncDirectory(self.vmDirectory)
        try saveJournal()
        for directory in [stage, backup, work] { try fm.createDirectory(at: directory, withIntermediateDirectories: false) }
        do {
            for entry in entries {
                try inject(.beforeCopy(entry.name))
                let source = self.vmDirectory.appendingPathComponent(entry.name)
                let target = stage.appendingPathComponent(entry.name)
                try Self.copyTree(source, to: target)
                guard try Self.digest(target) == entry.original, try Self.digest(source) == entry.original else {
                    throw Self.error("Firmware input changed during staging: \(entry.name)")
                }
            }
        } catch { recordFailure(error); throw error }
    }

    private init(vmDirectory: URL, inject: @escaping (Event) throws -> Void,
                 mounts: @escaping (URL, Bool) throws -> Void) throws {
        self.vmDirectory = vmDirectory.standardizedFileURL.resolvingSymlinksInPath()
        root = self.vmDirectory.appendingPathComponent(".firmware-transaction")
        self.inject = inject
        self.mounts = mounts
        self.filesystemReadback = { try $0.verify(image: $1, transaction: $2, environment: $3) }
        try Self.requireDirectory(root)
        let url = root.appendingPathComponent("journal.json")
        try Self.requireRegularFile(url)
        journal = try Self.readJournal(at: url)
        try journal.planBinding?.validate(journal: journal, directory: self.vmDirectory, currentCatalog: false)
        guard (journal.version == 1 || journal.version == 2), (journal.planBinding?.schemaVersion == 2 || journal.vmPath == self.vmDirectory.path),
              UUID(uuidString: journal.id) != nil, !journal.entries.isEmpty,
              Set(journal.entries.map(\.name)).count == journal.entries.count else {
            throw Self.error("Invalid firmware transaction journal")
        }
        for entry in journal.entries { try Self.validateName(entry.name) }
        try validateMetadataNames()
        for directory in [stage, backup, work] where Self.exists(directory) { try Self.requireDirectory(directory) }
    }

    /// Version 1 is recognized recovery-only history; it is never upgraded by loading.
    static func readJournal(at url: URL) throws -> Journal {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? RecordFailure.missing : RecordFailure.unreadable(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw RecordFailure.unreadable(errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= 16 << 20 else { throw RecordFailure.corrupt }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data: Data
        do { data = try handle.read(upToCount: Int(info.st_size) + 1) ?? Data() } catch { throw RecordFailure.unreadable(EIO) }
        guard data.count == info.st_size else { throw RecordFailure.corrupt }
        struct Header: Decodable { let version: Int }
        let version: Int
        do { version = try JSONDecoder().decode(Header.self, from: data).version } catch { throw RecordFailure.corrupt }
        guard version == 1 || version == 2 else { throw RecordFailure.unsupportedSchema(version) }
        let result: Journal
        do { result = try JSONDecoder().decode(Journal.self, from: data) } catch { throw RecordFailure.corrupt }
        guard (version == 2) == (result.planBinding != nil) else { throw RecordFailure.bindingMismatch("journal schema/binding") }
        return result
    }

    func recordFailure(_ error: Error) {
        journal.failure = String(describing: error)
        do { try saveJournal() } catch { print("[firmware] could not record failure: \(error)") }
    }

    func saveReport(_ report: PatchRunReport) throws {
        let bytes = try Self.encoder.encode(report)
        guard bytes.count <= 64 << 20 else { throw Self.error("Firmware report exceeds 64 MiB") }
        try Self.writeDurably(bytes, to: root.appendingPathComponent("report.json"))
        journal.reportSHA256 = Self.sha256(bytes)
        try validateReport(forCommit: false)
        try saveJournal()
    }

    /// Reads the existing report; no applied set is inferred from enabled steps.
    private func validateReport(forCommit: Bool) throws {
        if forCommit, let expected = journal.options["desiredSHA256"] {
            guard case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: vmDirectory),
                  try desired.sha256 == expected, desired.plan == journal.plan,
                  desired.generationID == journal.options["generationID"] else {
                throw RecordFailure.bindingMismatch("desired plan changed")
            }
        }
        guard let expected = journal.reportSHA256 else { return }
        let path = root.appendingPathComponent("report.json")
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Self.error("Recorded firmware report is unavailable") }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= 64 << 20 else { throw Self.error("Invalid firmware report file") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let bytes = try handle.read(upToCount: Int(before.st_size) + 1) ?? Data()
        guard bytes.count == before.st_size, fstat(fd, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              Self.sha256(bytes) == expected else { throw Self.error("Firmware report differs from journal") }
        let report = try JSONDecoder().decode(PatchRunReport.self, from: bytes)
        if forCommit {
            guard report.failedRequired.isEmpty else { throw Self.error("Required patch failure in recorded report") }
            if let plan = journal.plan { try PatchDeclarationGate.enforce(report: report, plan: plan) }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Collects actual records only after all writers have finished. Neither a
    /// decoded report nor an enabled declaration substitutes for final readback.
    func prepareComponentReceipts(report: PatchRunReport, outputs: [String: URL]) throws {
        guard journal.phase == .building, journal.componentReceiptsSHA256 == nil,
              let plan = journal.plan, let id = journal.options["generationID"],
              let reportSHA = journal.reportSHA256,
              try Self.sha256(Self.encoder.encode(report)) == reportSHA else {
            throw Self.error("Component publication requires the saved bound report")
        }
        try journal.planBinding?.validate(journal: journal, directory: vmDirectory, currentCatalog: true)
        try PatchDeclarationGate.enforce(report: report, plan: plan)
        let generation = try FirmwareGeneration.loadVerified(in: vmDirectory, id: id)
        let groups = Dictionary(grouping: report.allRecords, by: { $0.component.lowercased() })
        guard !groups.isEmpty else { throw Self.error("Missing component records") }
        var records: [FirmwareComponentReceipt.Record] = []
        for component in groups.keys.sorted() {
            guard let output = outputs[component] else { throw Self.error("Missing output for \(component)") }
            let path = try FirmwareComponentReceipt.relative(output, in: stage)
            guard journal.entries.contains(where: { $0.name == path.split(separator: "/").first.map(String.init) }) else {
                throw Self.error("Component output is outside published roots")
            }
            var record = try FirmwareComponentReceipt.capture(component: component, plan: plan,
                generation: generation, records: groups[component]!, outputs: [output], root: stage, machine: vmDirectory)
            // This is the prepared publication state; only the enclosing
            // committed journal authorizes consumers to regard it as committed.
            record.state = .committed
            records.append(record)
        }
        let filesystem: FirmwareFilesystemEvidence?
        let filesystemSHA: String?
        if groups["filesystem"] != nil {
            let proof = root.appendingPathComponent(FirmwareFilesystemEvidence.filename)
            filesystemSHA = try FirmwareGeneration.fileSHA256(proof)
            let proofBytes = try Self.readBytes(proof)
            guard Self.sha256(proofBytes) == filesystemSHA else { throw Self.error("Filesystem proof changed during capture") }
            filesystem = try JSONDecoder().decode(FirmwareFilesystemEvidence.self, from: proofBytes)
        } else { filesystem = nil; filesystemSHA = nil }
        let publication = ComponentPublication(schemaVersion: 1, transactionID: journal.id, records: records,
            filesystem: filesystem, filesystemProofSHA256: filesystemSHA)
        try verifyPublication(publication, in: stage)
        let bytes = try Self.encoder.encode(publication)
        try Self.writeDurably(bytes, to: root.appendingPathComponent("component-receipts.json"))
        try prepareMetadata(name: ComponentPublication.filename, bytes: bytes)
    }

    private func prepareMetadata(name: String, bytes: Data) throws {
        guard journal.phase == .building,
              !(journal.metadata ?? []).contains(where: { $0.name == name }),
              [ComponentPublication.filename, "launchpad.json"].contains(name) else {
            throw Self.error("Invalid or repeated publication metadata")
        }
        let destination = vmDirectory.appendingPathComponent(name)
        let original = try Self.metadataDigest(destination)
        journal.metadata = (journal.metadata ?? []) + [MetadataEntry(name: name, original: original,
            output: Self.sha256(bytes))]
        if name == ComponentPublication.filename { journal.componentReceiptsSHA256 = Self.sha256(bytes) }
        try saveJournal()
        try inject(.beforeMetadataWrite(name))
        try Self.writeDurably(bytes, to: stage.appendingPathComponent(name), beforeSync: {
            try self.inject(.beforeMetadataSync(name))
        })
    }

    private func validateMetadataNames() throws {
        let entries = journal.metadata ?? []
        guard Set(entries.map(\.name)).count == entries.count,
              entries.allSatisfy({ [ComponentPublication.filename, "launchpad.json"].contains($0.name) }),
              (journal.componentReceiptsSHA256 != nil) == entries.contains(where: { $0.name == ComponentPublication.filename }) else {
            throw Self.error("Invalid publication metadata journal")
        }
    }

    private func readPublication(required: Bool = true) throws -> ComponentPublication? {
        guard let expected = journal.componentReceiptsSHA256 else {
            guard !required || journal.options["generationID"] == nil else { throw Self.error("Missing required component receipts") }
            return nil
        }
        let file = root.appendingPathComponent("component-receipts.json")
        let bytes = try Self.readBytes(file)
        guard Self.sha256(bytes) == expected else { throw Self.error("Component receipts differ from journal") }
        let publication = try JSONDecoder().decode(ComponentPublication.self, from: bytes)
        guard publication.schemaVersion == 1, publication.transactionID == journal.id,
              !publication.records.isEmpty,
              Set(publication.records.map { $0.component.lowercased() }).count == publication.records.count,
              journal.metadata?.first(where: { $0.name == ComponentPublication.filename })?.output == expected else {
            throw Self.error("Invalid component receipt publication")
        }
        guard let reportSHA = journal.reportSHA256 else { throw Self.error("Component receipts have no saved report") }
        let reportBytes = try Self.readBytes(root.appendingPathComponent("report.json"))
        guard Self.sha256(reportBytes) == reportSHA else { throw Self.error("Receipt report differs from journal") }
        let report = try JSONDecoder().decode(PatchRunReport.self, from: reportBytes)
        let groups = Dictionary(grouping: report.allRecords, by: { $0.component.lowercased() })
        guard groups == Dictionary(uniqueKeysWithValues: publication.records.map { ($0.component.lowercased(), $0.effects.map(\.record)) }),
              (publication.filesystem != nil) == publication.records.contains(where: { $0.component.lowercased() == "filesystem" }),
              (publication.filesystem != nil) == (publication.filesystemProofSHA256 != nil),
              (publication.installed != nil) == (publication.originLayer != nil),
              (publication.installed != nil) == (publication.originProofSHA256 != nil) else {
            throw Self.error("Component receipts do not cover the exact saved records")
        }
        return publication
    }

    private static func readBytes(_ file: URL) throws -> Data {
        var bytes = Data()
        try FirmwareGeneration.readFile(file) { chunk in
            guard bytes.count + chunk.count <= 64 << 20 else { throw Self.error("Publication evidence exceeds 64 MiB") }
            bytes.append(chunk)
        }
        return bytes
    }

    private func verifyPublication(_ publication: ComponentPublication, in directory: URL, rootName: String? = nil) throws {
        for record in publication.records where rootName == nil || record.outputs.contains(where: { $0.path.split(separator: "/").first.map(String.init) == rootName }) {
            try FirmwareComponentReceipt.verify(record, root: directory, machine: vmDirectory)
        }
        if let evidence = publication.filesystem,
           rootName == nil || evidence.imagePath.split(separator: "/").first.map(String.init) == rootName {
            guard try FirmwareGeneration.fileSHA256(root.appendingPathComponent(FirmwareFilesystemEvidence.filename)) == publication.filesystemProofSHA256,
                  case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: vmDirectory) else {
                throw Self.error("Filesystem proof differs from journal")
            }
            let environment = try FirmwareGuestWriteContext.environment(record: desired, directory: vmDirectory, transaction: root)
            try filesystemReadback(evidence, directory.appendingPathComponent(evidence.imagePath), self, environment)
        }
    }

    /// Reads exactly a regular metadata file, preserving missing vs unreadable.
    private static func metadataDigest(_ url: URL, sync: Bool = false) throws -> String? {
        var value = stat()
        if lstat(url.path, &value) != 0 {
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return nil
        }
        let digest = try FirmwareGeneration.fileSHA256(url)
        if sync {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return digest
    }

    @discardableResult
    func commit() throws -> URL { try commit(qualifiedOrigin: nil) }

    private func commit(qualifiedOrigin: InstalledOrigin?) throws -> URL {
        try withWorkerLock {
            try mounts(root, false)
            try inject(.beforeReady)
            try validateReport(forCommit: true)
            try validateMetadataNames()
            let publication = try readPublication()
            guard (publication?.installed != nil) == (qualifiedOrigin != nil),
                  !(journal.metadata ?? []).contains(where: { $0.name == "launchpad.json" }) || qualifiedOrigin != nil else {
                throw Self.error("Origin publication requires its live qualifier")
            }
            if let qualifiedOrigin { try verifyOrigin(qualifiedOrigin, point: .candidate, bindingPublished: false) }
            if let publication { try verifyPublication(publication, in: stage) }
            for entry in journal.metadata ?? [] {
                guard try Self.metadataDigest(vmDirectory.appendingPathComponent(entry.name)) == entry.original,
                      try Self.metadataDigest(stage.appendingPathComponent(entry.name), sync: true) == entry.output else {
                    throw Self.error("Publication metadata changed before commit")
                }
            }
            try journal.planBinding?.validate(journal: journal, directory: vmDirectory, currentCatalog: true)
            for index in journal.entries.indices {
                let entry = journal.entries[index]
                guard try Self.digest(vmDirectory.appendingPathComponent(entry.name)) == entry.original else {
                    throw Self.error("Original firmware changed before commit: \(entry.name)")
                }
                journal.entries[index].output = try Self.digest(stage.appendingPathComponent(entry.name), sync: true)
            }
            journal.phase = .ready
            try saveJournal()
            journal.phase = .publishing
            try saveJournal()
            for entry in journal.entries where entry.original != entry.output {
                try inject(.beforeBackup(entry.name))
                try journal.planBinding?.validate(journal: journal, directory: vmDirectory, currentCatalog: true)
                let destination = vmDirectory.appendingPathComponent(entry.name)
                let staged = stage.appendingPathComponent(entry.name)
                let saved = backup.appendingPathComponent(entry.name)
                guard try Self.digest(destination) == entry.original,
                      try Self.digest(staged) == entry.output else {
                    throw Self.error("Firmware changed in publication window: \(entry.name)")
                }
                try Self.move(destination, to: saved)
                try inject(.afterBackup(entry.name))
                guard try Self.digest(saved) == entry.original,
                      try Self.digest(staged) == entry.output else {
                    throw Self.error("Firmware changed after backup: \(entry.name)")
                }
                try Self.move(staged, to: destination)
                try inject(.afterPublish(entry.name))
                guard try Self.digest(destination, sync: true) == entry.output else { throw Self.error("Published root differs") }
                if let publication { try verifyPublication(publication, in: vmDirectory, rootName: entry.name) }
            }
            // Include unchanged entries: a no-op is evidence only after readback.
            for entry in journal.entries {
                guard try Self.digest(vmDirectory.appendingPathComponent(entry.name), sync: true) == entry.output else {
                    throw Self.error("Published firmware differs from journal: \(entry.name)")
                }
            }
            try journal.planBinding?.validate(journal: journal, directory: vmDirectory, currentCatalog: true)
            try mounts(root, false)
            try validateReport(forCommit: true)
            if let publication { try verifyPublication(publication, in: vmDirectory) }
            for entry in journal.metadata ?? [] {
                try inject(.beforeBackup(entry.name))
                if let qualifiedOrigin { try verifyOrigin(qualifiedOrigin, point: .published, bindingPublished: false) }
                try validateReport(forCommit: true)
                try journal.planBinding?.validate(journal: journal, directory: vmDirectory, currentCatalog: true)
                let destination = vmDirectory.appendingPathComponent(entry.name)
                let staged = stage.appendingPathComponent(entry.name)
                guard try Self.metadataDigest(destination) == entry.original,
                      try Self.metadataDigest(staged) == entry.output else { throw Self.error("Metadata changed during publication") }
                if entry.original != nil { try Self.move(destination, to: backup.appendingPathComponent(entry.name)) }
                try inject(.afterBackup(entry.name))
                guard try Self.metadataDigest(destination) == nil,
                      try Self.metadataDigest(staged) == entry.output else { throw Self.error("Metadata changed after backup") }
                if let qualifiedOrigin {
                    try verifyOrigin(qualifiedOrigin, point: .published, bindingPublished: false,
                                     bindingBackedUp: entry.name == "launchpad.json")
                }
                try Self.move(staged, to: destination)
                try inject(.afterPublish(entry.name))
                guard try Self.metadataDigest(destination, sync: true) == entry.output else { throw Self.error("Published metadata differs") }
            }
            try inject(.beforeCommitted)
            if let qualifiedOrigin { try verifyOrigin(qualifiedOrigin, point: .published, bindingPublished: true) }
            try validateReport(forCommit: true)
            try journal.planBinding?.validate(journal: journal, directory: vmDirectory, currentCatalog: true)
            if let publication = try readPublication() { try verifyPublication(publication, in: vmDirectory) }
            for entry in journal.metadata ?? [] {
                guard try Self.metadataDigest(vmDirectory.appendingPathComponent(entry.name), sync: true) == entry.output else {
                    throw Self.error("Final metadata differs")
                }
            }
            // Callbacks and final effect readers may run after the earlier root
            // check. Bind every member, including unchanged/unreceipted files,
            // to the output digest immediately before committing the journal.
            for entry in journal.entries {
                guard try Self.digest(vmDirectory.appendingPathComponent(entry.name), sync: true) == entry.output else {
                    throw Self.error("Final firmware root differs from journal: \(entry.name)")
                }
            }
            journal.phase = .committed
            do { try saveJournal() }
            catch {
                // The caller observes uncertainty, never a successful commit.
                // Recovery inspects the durable journal and actual files.
                journal.phase = .publishing
                throw error
            }
            return try archive()
        }
    }

    /// Explicit recovery never reruns patching. Uncommitted publication rolls back;
    /// a committed transaction only verifies its outputs and archives its receipt.
    static func recover(vmDirectory: URL, inject: @escaping (Event) throws -> Void = { _ in },
                        mounts: @escaping (URL, Bool) throws -> Void = checkMounts) throws -> URL? {
        let root = vmDirectory.appendingPathComponent(".firmware-transaction")
        guard exists(root) else { return nil }
        // A kill or ENOSPC before the first journal rename cannot have modified
        // inputs. Only an otherwise empty initialization directory is recoverable.
        if !exists(root.appendingPathComponent("journal.json")) {
            try requireDirectory(root)
            let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
            guard names.allSatisfy({ $0.hasPrefix(".write-") }) else {
                throw error("Missing firmware journal; retaining unrecognized transaction data")
            }
            let history = vmDirectory.appendingPathComponent(".firmware-history")
            if exists(history) { try requireDirectory(history) }
            else { try FileManager.default.createDirectory(at: history, withIntermediateDirectories: false) }
            let archived = history.appendingPathComponent("initializing-" + UUID().uuidString)
            try move(root, to: archived)
            return archived
        }
        let transaction = try FirmwareTransaction(vmDirectory: vmDirectory, inject: inject, mounts: mounts)
        return try transaction.withWorkerLock {
            try mounts(transaction.root, true)
            if transaction.journal.phase == .committed { try transaction.validateReport(forCommit: false) }
            try transaction.restoreOrVerify()
            return try transaction.archive()
        }
    }

    private func restoreOrVerify() throws {
        // Validate every entry before changing any entry. Preserve unknown external edits.
        for entry in journal.entries {
            let destination = vmDirectory.appendingPathComponent(entry.name)
            let saved = backup.appendingPathComponent(entry.name)
            if journal.phase == .committed {
                guard let output = entry.output, try Self.digest(destination) == output else {
                    throw Self.error("Committed firmware differs from journal: \(entry.name)")
                }
            } else if Self.exists(saved) {
                guard journal.phase == .publishing || journal.phase == .rollingBack,
                      try Self.digest(saved) == entry.original else { throw Self.error("Invalid backup: \(entry.name)") }
                if Self.exists(destination) {
                    guard let output = entry.output, try Self.digest(destination) == output,
                          !Self.exists(stage.appendingPathComponent(entry.name)) else {
                        throw Self.error("Recovery would overwrite unknown firmware: \(entry.name)")
                    }
                }
            } else {
                guard try Self.digest(destination) == entry.original else {
                    throw Self.error("Original firmware unavailable for recovery: \(entry.name)")
                }
            }
        }
        for entry in journal.metadata ?? [] {
            let actual = try Self.metadataDigest(vmDirectory.appendingPathComponent(entry.name))
            let saved = try Self.metadataDigest(backup.appendingPathComponent(entry.name))
            if journal.phase == .committed {
                guard actual == entry.output else { throw Self.error("Committed metadata differs: \(entry.name)") }
            } else if let saved {
                guard saved == entry.original, journal.phase == .publishing || journal.phase == .rollingBack,
                      actual == nil || actual == entry.output else { throw Self.error("Unknown metadata during recovery") }
            } else if entry.original == nil {
                guard actual == nil || ((journal.phase == .publishing || journal.phase == .rollingBack) && actual == entry.output) else {
                    throw Self.error("Unknown newly published metadata")
                }
            } else {
                guard actual == entry.original else { throw Self.error("Original metadata unavailable") }
            }
        }
        if journal.phase == .committed {
            if let publication = try readPublication(required: false) {
                if let proof = publication.originProofSHA256 {
                    guard try FirmwareGeneration.fileSHA256(root.appendingPathComponent("installed-component-proof.json")) == proof else {
                        throw Self.error("Committed installed proof differs")
                    }
                }
                for record in publication.records + (publication.installed.map { [$0] } ?? []) {
                    for output in record.outputs {
                        let file = vmDirectory.appendingPathComponent(output.path)
                        _ = try FirmwareComponentReceipt.relative(file, in: vmDirectory)
                        guard try FirmwareGeneration.fileSHA256(file) == output.sha256 else { throw Self.error("Committed receipt output differs") }
                    }
                }
            }
            return
        }
        journal.phase = .rollingBack
        try saveJournal()
        // Restore metadata first; the same journal remains noncommitted until all
        // original roots and metadata have been restored and archived.
        for entry in (journal.metadata ?? []).reversed() {
            let destination = vmDirectory.appendingPathComponent(entry.name)
            let saved = backup.appendingPathComponent(entry.name)
            if try Self.metadataDigest(saved) != nil || entry.original == nil {
                if Self.exists(destination) {
                    let staged = stage.appendingPathComponent(entry.name)
                    guard !Self.exists(staged) else { throw Self.error("Ambiguous metadata rollback staging") }
                    try Self.move(destination, to: staged)
                }
                if Self.exists(saved) { try Self.move(saved, to: destination) }
                try inject(.afterRestore(entry.name))
            }
        }
        for entry in journal.entries {
            let saved = backup.appendingPathComponent(entry.name)
            guard Self.exists(saved) else { continue }
            let destination = vmDirectory.appendingPathComponent(entry.name)
            if Self.exists(destination) { try Self.move(destination, to: stage.appendingPathComponent(entry.name)) }
            try Self.move(saved, to: destination)
            try inject(.afterRestore(entry.name))
        }
    }

    private func archive() throws -> URL {
        try inject(.beforeArchive)
        let history = vmDirectory.appendingPathComponent(".firmware-history")
        if Self.exists(history) { try Self.requireDirectory(history) }
        else { try fm.createDirectory(at: history, withIntermediateDirectories: false) }
        let destination = history.appendingPathComponent(journal.id)
        guard !Self.exists(destination) else { throw Self.error("Firmware archive already exists") }
        try Self.move(root, to: destination)
        archiveURL = destination
        return destination
    }

    private func withWorkerLock<T>(_ body: () throws -> T) throws -> T {
        // Like the bundle lease, lock the directory inode rather than a removable file.
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Self.error("Firmware tool is still running; retry recovery after it exits") }
        workerLockFD = fd
        defer { workerLockFD = nil; flock(fd, LOCK_UN) }
        return try body()
    }

    func temporaryDirectory() throws -> URL {
        let directory = work.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func runTool(_ executable: String, _ arguments: [String], output: URL? = nil) throws -> Data {
        let resources = VPhoneResources.resolve()
        let python = try resources.pythonExecutable()
        let worker = resources.scriptsDir.appendingPathComponent("firmware_worker.py")
        try Self.requireDirectory(root)
        // Foundation may retain the system /var alias in a file URL. Pass the
        // actual canonical pathname so the worker can reject every symlink.
        guard let resolved = realpath(root.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        let workerRoot = String(cString: resolved)
        if let workerLockFD {
            // Python rejects a directory stdin before its script starts. A fixed
            // shell bootstrap duplicates the same open description onto fd 3;
            // every tool argument remains a positional argument, never shell code.
            return try Self.run("/bin/sh", ["-c", "exec 3<&0; exec 0</dev/null; exec \"$@\"", "firmware-worker",
                python.path, worker.path, workerRoot, "--lock-fd", "3", executable] + arguments,
                output: output, lockInput: workerLockFD, afterStart: { try self.inject(.afterToolStart) })
        }
        return try Self.run(python.path, [worker.path, workerRoot, executable] + arguments, output: output,
                            afterStart: { try self.inject(.afterToolStart) })
    }

    private func saveJournal() throws {
        try Self.writeDurably(try Self.encoder.encode(journal), to: root.appendingPathComponent("journal.json"), beforeSync: {
            try self.inject(.beforeJournalSync(self.journal.phase))
        })
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder
    }
    private static func error(_ message: String) -> TransactionError { TransactionError(message: message) }
    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.hasPrefix("."),
              name.contains("Restore") || name.hasPrefix("AVPBooter") else { throw error("Invalid firmware root: \(name)") }
    }
    private static func info(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return value
    }
    static func exists(_ url: URL) -> Bool { (try? info(url)) != nil }
    private static func requireDirectory(_ url: URL) throws {
        guard try info(url).st_mode & S_IFMT == S_IFDIR else { throw error("Expected a real directory: \(url.path)") }
    }
    private static func requireRegularFile(_ url: URL) throws {
        guard try info(url).st_mode & S_IFMT == S_IFREG else { throw error("Expected a regular file: \(url.path)") }
    }
    private static func copyTree(_ source: URL, to destination: URL) throws {
        let value = try info(source)
        switch value.st_mode & S_IFMT {
        case S_IFDIR:
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
                try copyTree(source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
        case S_IFREG:
            if clonefile(source.path, destination.path, 0) != 0 {
                guard [EXDEV, ENOTSUP, EINVAL].contains(errno) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try FileManager.default.copyItem(at: source, to: destination)
            }
        default: throw error("Symlinks and special firmware files are not supported: \(source.path)")
        }
    }

    /// Streaming tree digest includes names, node kinds and empty directories.
    static func digest(_ url: URL, sync: Bool = false) throws -> String {
        let value = try info(url)
        var hash = SHA256()
        switch value.st_mode & S_IFMT {
        case S_IFDIR:
            hash.update(data: Data("directory\0".utf8))
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                hash.update(data: Data((name + "\0" + (try digest(url.appendingPathComponent(name), sync: sync)) + "\0").utf8))
            }
            if sync { try syncDirectory(url) }
        case S_IFREG:
            hash.update(data: Data("file\0".utf8))
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            while try autoreleasepool(invoking: { () throws -> Bool in
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
                hash.update(data: data)
                return true
            }) {}
            if sync, fsync(handle.fileDescriptor) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        default: throw error("Symlinks and special firmware files are not supported: \(url.path)")
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func writeDurably(_ data: Data, to url: URL, beforeSync: () throws -> Void = {}) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try beforeSync()
        try handle.synchronize()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try syncDirectory(url.deletingLastPathComponent())
    }
    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    private static func move(_ source: URL, to destination: URL) throws {
        guard !exists(destination) else { throw error("Refusing to replace existing transaction path: \(destination.path)") }
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try syncDirectory(source.deletingLastPathComponent())
        try syncDirectory(destination.deletingLastPathComponent())
    }

    static func run(_ executable: String, _ arguments: [String], output: URL? = nil, lockInput: Int32? = nil,
                    afterStart: () throws -> Void = {}) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        // Own pipe descriptors explicitly: Foundation's throwing close after
        // spawn must not bypass wait or leave our writer holding the reader open.
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { for fd in descriptors where fd >= 0 { close(fd) } }
        for fd in descriptors {
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let writer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: false)
        var file: FileHandle?
        if let output { file = try FileHandle(forWritingTo: output) }
        defer { try? file?.close() }
        if let lockInput { process.standardInput = FileHandle(fileDescriptor: lockInput, closeOnDealloc: false) }
        process.standardOutput = file ?? writer
        process.standardError = file ?? writer
        try process.run()
        // Never leave the shared-lock scope while a started worker can still
        // write. Retain an I/O failure until output handling and wait complete.
        defer { process.waitUntilExit() }
        var ioFailure: Error?
        do { try afterStart() } catch { ioFailure = error }
        if close(descriptors[1]) != 0 {
            if ioFailure == nil { ioFailure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // If parent-writer closure is uncertain, EOF is not a safe wait
            // condition. Close the reader so the child cannot block on a full pipe.
            close(descriptors[0]); descriptors[0] = -1
        }
        descriptors[1] = -1
        var data = Data()
        if file == nil, descriptors[0] >= 0 {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(descriptors[0], &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    if ioFailure == nil { ioFailure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    close(descriptors[0]); descriptors[0] = -1
                    break
                }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        process.waitUntilExit()
        if let ioFailure { throw ioFailure }
        guard process.terminationStatus == 0 else {
            throw ProcessError.failed(process.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    static func detachDevice(entries: [[String: Any]],
                             inspect: (String) throws -> [String: Any] = { device in
        let data = try run("/usr/sbin/diskutil", ["info", "-plist", device])
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw error("Cannot inspect firmware image device")
        }
        return info
    }) throws -> String {
        let partitions = entries.filter { ["GUID_partition_scheme", "FDisk_partition_scheme", "Apple_partition_scheme"].contains($0["content-hint"] as? String ?? "") }
        let candidates = Set((partitions.isEmpty ? entries : partitions).compactMap { $0["dev-entry"] as? String }
            .filter { $0.range(of: "^/dev/disk[0-9]+$", options: .regularExpression) != nil })
        if candidates.count == 1, let device = candidates.first { return device }
        // Bare APFS images expose both a backing device and a synthesized
        // container. Resolve the relation from diskutil, retaining the image's
        // hdiutil candidate set as the boundary for any detach operation.
        var backing = Set<String>()
        for device in candidates {
            let info = try inspect(device)
            guard info["DeviceNode"] as? String == device, info["BusProtocol"] as? String == "Disk Image" else {
                throw error("Firmware device identity changed")
            }
            if let stores = info["APFSPhysicalStores"] as? [[String: Any]] {
                guard stores.count == 1, let identifier = stores[0]["APFSPhysicalStore"] as? String,
                      candidates.contains("/dev/" + identifier) else {
                    throw error("APFS physical store is not a unique member of this firmware image")
                }
                backing.insert("/dev/" + identifier)
            } else { backing.insert(device) }
        }
        guard backing.count == 1, let device = backing.first else { throw error("Ambiguous firmware image device") }
        return device
    }

    /// hdiutil image paths, rather than saved device numbers, identify our mounts.
    static func checkMounts(_ root: URL, detach: Bool) throws {
        let data = try run("/usr/bin/hdiutil", ["info", "-plist"])
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { throw error("Cannot inspect attached firmware images") }
        let prefix = root.resolvingSymlinksInPath().path + "/"
        for image in images {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(prefix) else { continue }
            guard detach else { throw error("Firmware transaction still has an attached image: \(path)") }
            let entries = image["system-entities"] as? [[String: Any]] ?? []
            let device = try detachDevice(entries: entries)
            _ = try run("/usr/bin/hdiutil", ["detach", device])
        }
        if detach { try checkMounts(root, detach: false) }
    }
}

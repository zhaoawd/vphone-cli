import Darwin
import Foundation

// MARK: - Snapshot

/// One saved disk snapshot of a machine, in `<machine>/Snapshots/<name>/`.
public struct VPhoneMachineSnapshot: Equatable, Sendable {
    public let name: String
    public let created: Date
    public let note: String?
    /// The state files copied into the snapshot, by their names in the
    /// machine folder.
    public let files: [String]
    /// State files the machine did not have when the snapshot was taken.
    /// Revert removes them, so the restored set describes the same moment.
    public let absentFiles: [String]

    fileprivate struct Metadata: Codable {
        let created: Date
        let note: String?
        let files: [String]
        let absentFiles: [String]

        enum CodingKeys: String, CodingKey {
            case created = "Created"
            case note = "Note"
            case files = "Files"
            case absentFiles = "AbsentFiles"
        }
    }

    fileprivate init(_ metadata: Metadata, name: String) {
        self.name = name
        created = metadata.created
        note = metadata.note
        files = metadata.files
        absentFiles = metadata.absentFiles
    }
}

// MARK: - Snapshots

/// Machine disk snapshots: APFS clones of the files that describe the guest,
/// taken and put back only while the machine is stopped.
public enum VPhoneMachineSnapshots {
    public static let directoryName = "Snapshots"
    public static let metadataFileName = "Snapshot.plist"
    public static let revertJournalFileName = "SnapshotRevertJournal.plist"
    public static let optionalStateFileNames = ["PatchReceipt.plist", "restore-info.json"]

    struct RevertJournal: Codable, Equatable {
        let snapshotName: String
        let files: [String]
        let absentFiles: [String]
        let existedBeforeRevert: [String]
    }

    public static func directory(of bundle: VPhoneBundle) -> URL {
        bundle.url.appendingPathComponent(directoryName, isDirectory: true)
    }

    // MARK: Names

    public static func requireValidName(_ name: String) throws {
        guard !name.isEmpty,
              !name.contains("/"),
              !name.hasPrefix("."),
              VPhoneVirtualMachineManifest.isPlainFileName(name)
        else {
            throw VPhoneMachineSnapshotError.invalidName(name)
        }
    }

    public static func folder(named name: String, of bundle: VPhoneBundle) throws -> URL {
        try requireValidName(name)
        let folder = directory(of: bundle).appendingPathComponent(name, isDirectory: true)
        guard isDirectory(folder) else {
            throw VPhoneMachineSnapshotError.notFound(machine: bundle.name, name: name)
        }
        return folder
    }

    // MARK: List

    public static func list(of bundle: VPhoneBundle) throws -> [VPhoneMachineSnapshot] {
        let root = directory(of: bundle)
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let names = try fm.contentsOfDirectory(atPath: root.path)
        return names
            .filter { !$0.hasPrefix(".") }
            .compactMap { try? readMetadata(named: $0, in: root) }
            .sorted { ($0.created, $0.name) < ($1.created, $1.name) }
    }

    public static func snapshot(named name: String, of bundle: VPhoneBundle) throws -> VPhoneMachineSnapshot {
        _ = try folder(named: name, of: bundle)
        return try readMetadata(named: name, in: directory(of: bundle))
    }

    // MARK: Create

    @discardableResult
    public static func create(
        _ name: String,
        note: String? = nil,
        of bundle: VPhoneBundle,
        now: Date = Date()
    ) throws -> VPhoneMachineSnapshot {
        try create(name, note: note, of: bundle, now: now, afterClone: nil)
    }

    @discardableResult
    static func create(
        _ name: String,
        note: String? = nil,
        of bundle: VPhoneBundle,
        now: Date = Date(),
        afterClone: (() throws -> Void)?
    ) throws -> VPhoneMachineSnapshot {
        try requireValidName(name)
        let root = directory(of: bundle)
        let destination = root.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw VPhoneMachineSnapshotError.alreadyExists(machine: bundle.name, name: name)
        }
        defer { VPhoneVMLock.removeRecord(directory: bundle.url, operation: VPhoneVMOperation.snapshot) }
        return try VPhoneBundleGuard.withBundleLock(
            directory: bundle.url, operation: VPhoneVMOperation.snapshot
        ) { _ in
            try recoverLocked(of: bundle)
            if FileManager.default.fileExists(atPath: destination.path) {
                throw VPhoneMachineSnapshotError.alreadyExists(machine: bundle.name, name: name)
            }
            try VPhoneBundleActivity.requireStopped(bundle)
            let stateBefore = try VPhoneBundleActivity.stateSignature(of: bundle)

            var files: [String] = []
            var absent: [String] = []
            for file in VPhoneBundleActivity.stateFileNames(of: bundle) {
                guard isRegularFile(bundle.url.appendingPathComponent(file)) else {
                    throw VPhoneMachineSnapshotError.missingStateFile(machine: bundle.name, file: file)
                }
                files.append(file)
            }
            for file in optionalStateFileNames {
                if isRegularFile(bundle.url.appendingPathComponent(file)) {
                    files.append(file)
                } else {
                    absent.append(file)
                }
            }

            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let staging = root.appendingPathComponent(".creating-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            do {
                for file in files {
                    try cloneFile(
                        bundle.url.appendingPathComponent(file),
                        to: staging.appendingPathComponent(file)
                    )
                }
                let metadata = VPhoneMachineSnapshot.Metadata(
                    created: now,
                    note: note.flatMap { $0.isEmpty ? nil : $0 },
                    files: files,
                    absentFiles: absent
                )
                let encoder = PropertyListEncoder()
                encoder.outputFormat = .xml
                try encoder.encode(metadata).write(to: staging.appendingPathComponent(metadataFileName))
                try afterClone?()
                try VPhoneBundleActivity.requireStopped(bundle)
                guard try VPhoneBundleActivity.stateSignature(of: bundle) == stateBefore else {
                    throw VPhoneBundleActivityError.stateChanged(name: bundle.name)
                }
                guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                    if errno == EEXIST {
                        throw VPhoneMachineSnapshotError.alreadyExists(machine: bundle.name, name: name)
                    }
                    throw VPhoneMachineSnapshotError.failed(path: destination.path, reason: currentErrorText())
                }
                return VPhoneMachineSnapshot(metadata, name: name)
            } catch {
                try? fm.removeItem(at: staging)
                removeIfEmpty(root)
                throw error
            }
        }
    }

    // MARK: Revert

    @discardableResult
    public static func revert(to name: String, of bundle: VPhoneBundle) throws -> VPhoneMachineSnapshot {
        try revert(to: name, of: bundle, afterStageClone: nil, afterMoveAside: nil)
    }

    @discardableResult
    static func revert(
        to name: String,
        of bundle: VPhoneBundle,
        afterStageClone: (() throws -> Void)? = nil,
        afterMoveAside: ((String) throws -> Void)? = nil
    ) throws -> VPhoneMachineSnapshot {
        defer { VPhoneVMLock.removeRecord(directory: bundle.url, operation: VPhoneVMOperation.snapshot) }
        return try VPhoneBundleGuard.withBundleLock(
            directory: bundle.url, operation: VPhoneVMOperation.snapshot
        ) { _ in
            try recoverLocked(of: bundle)
            let snapshot = try Self.snapshot(named: name, of: bundle)
            let source = directory(of: bundle).appendingPathComponent(name, isDirectory: true)
            try requireValidFileLists(of: snapshot, bundle: bundle)
            try VPhoneBundleActivity.requireStopped(bundle)
            let stateBefore = try VPhoneBundleActivity.stateSignature(of: bundle)

            let fm = FileManager.default
            let staging = bundle.url.appendingPathComponent(".snapshot-revert-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            var preserveStagingForRecovery = false
            defer {
                if !preserveStagingForRecovery {
                    try? fm.removeItem(at: staging)
                }
            }

            for file in snapshot.files {
                let from = source.appendingPathComponent(file)
                guard isRegularFile(from) else {
                    throw VPhoneMachineSnapshotError.damaged(
                        name: name,
                        reason: "\(file) is missing from the snapshot"
                    )
                }
                try cloneFile(from, to: staging.appendingPathComponent(file))
            }
            try afterStageClone?()
            try VPhoneBundleActivity.requireStopped(bundle)
            guard try VPhoneBundleActivity.stateSignature(of: bundle) == stateBefore else {
                throw VPhoneBundleActivityError.stateChanged(name: bundle.name)
            }
            do {
                try replaceLiveFiles(
                    with: snapshot,
                    staged: staging,
                    in: bundle,
                    afterMoveAside: afterMoveAside
                )
            } catch let error as VPhoneMachineSnapshotError {
                if case .revertIncomplete = error {
                    preserveStagingForRecovery = true
                }
                throw error
            }
            VPhoneMachineBinding.reconcileAfterSnapshotRevert(machine: bundle.url, snapshot: name)
            return snapshot
        }
    }

    /// Recovers any interrupted `.snapshot-revert-*` transaction in `bundle`,
    /// restoring the pre-revert live file set before removing the staging folder.
    public static func recover(of bundle: VPhoneBundle) throws {
        defer { VPhoneVMLock.removeRecord(directory: bundle.url, operation: VPhoneVMOperation.snapshot) }
        try VPhoneBundleGuard.withBundleLock(
            directory: bundle.url, operation: VPhoneVMOperation.snapshot
        ) { _ in
            try VPhoneBundleActivity.requireStopped(bundle)
            try recoverLocked(of: bundle)
        }
    }

    private static func recoverLocked(of bundle: VPhoneBundle) throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: bundle.url.path)) ?? []
        for entry in entries.sorted() where entry.hasPrefix(".snapshot-revert-") {
            let staging = bundle.url.appendingPathComponent(entry, isDirectory: true)
            guard isDirectory(staging) else { continue }
            let journalURL = staging.appendingPathComponent(revertJournalFileName)
            guard isRegularFile(journalURL) else {
                try? fm.removeItem(at: staging)
                continue
            }
            let journal: RevertJournal
            do {
                journal = try PropertyListDecoder().decode(RevertJournal.self, from: Data(contentsOf: journalURL))
            } catch {
                throw VPhoneMachineSnapshotError.revertIncomplete(
                    machine: bundle.name,
                    reason: "unreadable \(revertJournalFileName)",
                    files: VPhoneBundleActivity.stateFileNames(of: bundle)
                )
            }
            let existed = Set(journal.existedBeforeRevert)
            var notRestored: [String] = []
            for file in (journal.files + journal.absentFiles).reversed() {
                let live = bundle.url.appendingPathComponent(file)
                let aside = staging.appendingPathComponent("old-\(file)")
                if existed.contains(file) {
                    if isRegularFile(aside) {
                        if rename(aside.path, live.path) != 0 {
                            notRestored.append(file)
                        }
                    } else if !isRegularFile(live) {
                        notRestored.append(file)
                    }
                } else if isRegularFile(live) {
                    if unlink(live.path) != 0, errno != ENOENT {
                        notRestored.append(file)
                    }
                }
            }
            guard notRestored.isEmpty else {
                throw VPhoneMachineSnapshotError.revertIncomplete(
                    machine: bundle.name,
                    reason: "interrupted snapshot revert could not restore pre-revert files",
                    files: notRestored.reversed()
                )
            }
            try? fm.removeItem(at: staging)
        }
    }

    private struct SwapStep {
        let file: String
        let movedAside: Bool
        var placed = false
    }

    private static func replaceLiveFiles(
        with snapshot: VPhoneMachineSnapshot,
        staged staging: URL,
        in bundle: VPhoneBundle,
        afterMoveAside: ((String) throws -> Void)?
    ) throws {
        let allFiles = snapshot.files + snapshot.absentFiles
        let existed = allFiles.filter { isRegularFile(bundle.url.appendingPathComponent($0)) }
        let journal = RevertJournal(
            snapshotName: snapshot.name,
            files: snapshot.files,
            absentFiles: snapshot.absentFiles,
            existedBeforeRevert: existed
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let journalURL = staging.appendingPathComponent(revertJournalFileName)
        try encoder.encode(journal).write(to: journalURL, options: .atomic)

        let absent = Set(snapshot.absentFiles)
        var steps: [SwapStep] = []
        do {
            for file in allFiles {
                let live = bundle.url.appendingPathComponent(file).path
                let aside = staging.appendingPathComponent("old-\(file)").path
                let movedAside = rename(live, aside) == 0
                if !movedAside, errno != ENOENT {
                    throw VPhoneMachineSnapshotError.failed(path: live, reason: currentErrorText())
                }
                steps.append(SwapStep(file: file, movedAside: movedAside))
                if absent.contains(file) {
                    try afterMoveAside?(file)
                    continue
                }
                guard rename(staging.appendingPathComponent(file).path, live) == 0 else {
                    throw VPhoneMachineSnapshotError.failed(path: live, reason: currentErrorText())
                }
                steps[steps.count - 1].placed = true
                try afterMoveAside?(file)
            }
        } catch {
            let notRestored = undo(steps, staging: staging, bundle: bundle)
            guard notRestored.isEmpty else {
                throw VPhoneMachineSnapshotError.revertIncomplete(
                    machine: bundle.name,
                    reason: "\(error)",
                    files: notRestored
                )
            }
            throw error
        }
    }

    private static func undo(_ steps: [SwapStep], staging: URL, bundle: VPhoneBundle) -> [String] {
        var notRestored: [String] = []
        for step in steps.reversed() {
            let live = bundle.url.appendingPathComponent(step.file).path
            if step.movedAside {
                if rename(staging.appendingPathComponent("old-\(step.file)").path, live) != 0 {
                    notRestored.append(step.file)
                }
            } else if step.placed, unlink(live) != 0, errno != ENOENT {
                notRestored.append(step.file)
            }
        }
        return notRestored.reversed()
    }

    // MARK: Delete

    public static func delete(_ name: String, of bundle: VPhoneBundle) throws {
        try FileManager.default.removeItem(at: folder(named: name, of: bundle))
        removeIfEmpty(directory(of: bundle))
    }

    // MARK: - Files

    private static func readMetadata(named name: String, in root: URL) throws -> VPhoneMachineSnapshot {
        let url = root.appendingPathComponent(name).appendingPathComponent(metadataFileName)
        do {
            let metadata = try PropertyListDecoder().decode(VPhoneMachineSnapshot.Metadata.self, from: Data(contentsOf: url))
            return VPhoneMachineSnapshot(metadata, name: name)
        } catch {
            throw VPhoneMachineSnapshotError.damaged(name: name, reason: "\(metadataFileName) is unreadable")
        }
    }

    private static func requireValidFileLists(of snapshot: VPhoneMachineSnapshot, bundle: VPhoneBundle) throws {
        func damaged(_ reason: String) -> VPhoneMachineSnapshotError {
            .damaged(name: snapshot.name, reason: reason)
        }
        let required = VPhoneBundleActivity.stateFileNames(of: bundle)
        let known = Set(required + optionalStateFileNames)
        let listed = snapshot.files + snapshot.absentFiles
        if let unknown = listed.first(where: { !known.contains($0) }) {
            throw damaged("it names '\(unknown)', which is not a state file")
        }
        if let missing = required.first(where: { !snapshot.files.contains($0) }) {
            throw damaged("it does not hold \(missing), which must be restored with the other state files")
        }
        if let both = snapshot.files.first(where: { snapshot.absentFiles.contains($0) }) {
            throw damaged("it lists \(both) as both captured and absent")
        }
        if Set(listed).count != listed.count {
            throw damaged("it lists a state file more than once")
        }
    }

    private static func cloneFile(_ source: URL, to destination: URL) throws {
        guard clonefile(source.path, destination.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
            let code = errno
            if code == ENOTSUP || code == EXDEV {
                throw VPhoneMachineSnapshotError.notCloneable(path: source.path)
            }
            throw VPhoneMachineSnapshotError.failed(path: source.path, reason: String(cString: strerror(code)))
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        VPhoneVirtualMachineManifest.fileKind(at: url) == .regularFile
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func removeIfEmpty(_ url: URL) {
        rmdir(url.path)
    }

    private static func currentErrorText() -> String {
        String(cString: strerror(errno))
    }
}

// MARK: - Error

public enum VPhoneMachineSnapshotError: Error, Equatable {
    case invalidName(String)
    case alreadyExists(machine: String, name: String)
    case notFound(machine: String, name: String)
    case missingStateFile(machine: String, file: String)
    case notCloneable(path: String)
    case damaged(name: String, reason: String)
    case failed(path: String, reason: String)
    case revertIncomplete(machine: String, reason: String, files: [String])
}

extension VPhoneMachineSnapshotError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .invalidName(name):
            "Invalid snapshot name '\(name)'. Use a name that is not empty, has no '/', and does not start with '.'."
        case let .alreadyExists(machine, name):
            "VM '\(machine)' already has a snapshot named '\(name)'. Choose a different name."
        case let .notFound(machine, name):
            "VM '\(machine)' has no snapshot named '\(name)'. List them with vm snapshot list."
        case let .missingStateFile(machine, file):
            "VM '\(machine)' has no \(file) yet. Boot it once, then take the snapshot."
        case let .notCloneable(path):
            "Cannot clone \(path): snapshots need the VM on an APFS volume, and a full copy is not made."
        case let .damaged(name, reason):
            "Snapshot '\(name)' is damaged: \(reason). Delete it."
        case let .failed(path, reason):
            "Snapshot operation failed at \(path): \(reason)."
        case let .revertIncomplete(machine, reason, files):
            "Reverting VM '\(machine)' failed (\(reason)), and its previous "
                + "\(files.joined(separator: ", ")) could not be put back. Its state files may be "
                + "inconsistent: revert to a snapshot again before starting it."
        }
    }

    public var errorDescription: String? {
        description
    }
}

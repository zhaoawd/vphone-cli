import CryptoKit
import Darwin
import Foundation
import VPhoneCore

/// Owns the staged firmware tree, durable publication journal and recovery.
/// Callers hold the VM bundle lock throughout creation, execution or recovery.
final class FirmwareTransaction {
    enum Phase: String, Codable { case building, ready, publishing, rollingBack, committed }
    struct Entry: Codable {
        let name: String
        let original: String
        var output: String?
    }
    struct Journal: Codable {
        var version = 1
        let id: String
        let vmPath: String
        let options: [String: String]
        var phase: Phase = .building
        var entries: [Entry]
        var failure: String?
    }
    enum Event: Equatable {
        case beforeCopy(String), beforeReady, beforeBackup(String), afterBackup(String)
        case afterPublish(String), afterRestore(String), beforeArchive
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
    private let inject: (Event) throws -> Void
    private let mounts: (URL, Bool) throws -> Void
    private let fm = FileManager.default

    init(vmDirectory: URL, inputs: [URL], options: [String: String],
         inject: @escaping (Event) throws -> Void = { _ in },
         mounts: @escaping (URL, Bool) throws -> Void = FirmwareTransaction.checkMounts) throws {
        self.vmDirectory = vmDirectory.standardizedFileURL.resolvingSymlinksInPath()
        root = self.vmDirectory.appendingPathComponent(".firmware-transaction")
        self.inject = inject
        self.mounts = mounts
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
        journal = Journal(id: UUID().uuidString.lowercased(), vmPath: self.vmDirectory.path,
                          options: options, entries: entries)
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
        try Self.requireDirectory(root)
        let url = root.appendingPathComponent("journal.json")
        try Self.requireRegularFile(url)
        journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
        guard journal.version == 1, journal.vmPath == self.vmDirectory.path,
              UUID(uuidString: journal.id) != nil, !journal.entries.isEmpty,
              Set(journal.entries.map(\.name)).count == journal.entries.count else {
            throw Self.error("Invalid firmware transaction journal")
        }
        for entry in journal.entries { try Self.validateName(entry.name) }
        for directory in [stage, backup, work] where Self.exists(directory) { try Self.requireDirectory(directory) }
    }

    func recordFailure(_ error: Error) {
        journal.failure = String(describing: error)
        do { try saveJournal() } catch { print("[firmware] could not record failure: \(error)") }
    }

    func saveReport(_ report: PatchRunReport) throws {
        try Self.writeDurably(try Self.encoder.encode(report), to: root.appendingPathComponent("report.json"))
    }

    @discardableResult
    func commit() throws -> URL {
        try withWorkerLock {
            try mounts(root, false)
            try inject(.beforeReady)
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
                try Self.move(vmDirectory.appendingPathComponent(entry.name), to: backup.appendingPathComponent(entry.name))
                try inject(.afterBackup(entry.name))
                try Self.move(stage.appendingPathComponent(entry.name), to: vmDirectory.appendingPathComponent(entry.name))
                try inject(.afterPublish(entry.name))
            }
            journal.phase = .committed
            try saveJournal()
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
        guard journal.phase != .committed else { return }
        journal.phase = .rollingBack
        try saveJournal()
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
        return destination
    }

    private func withWorkerLock<T>(_ body: () throws -> T) throws -> T {
        // Like the bundle lease, lock the directory inode rather than a removable file.
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Self.error("Firmware tool is still running; retry recovery after it exits") }
        defer { flock(fd, LOCK_UN) }
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
        return try Self.run(python.path, [worker.path, root.path, executable] + arguments, output: output)
    }

    private func saveJournal() throws {
        try Self.writeDurably(try Self.encoder.encode(journal), to: root.appendingPathComponent("journal.json"))
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
    private static func writeDurably(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
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
        guard rename(source.path, destination.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try syncDirectory(source.deletingLastPathComponent())
        try syncDirectory(destination.deletingLastPathComponent())
    }

    static func run(_ executable: String, _ arguments: [String], output: URL? = nil) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe()
        var file: FileHandle?
        if let output { file = try FileHandle(forWritingTo: output) }
        defer { try? file?.close() }
        process.standardOutput = file ?? pipe.fileHandleForWriting
        process.standardError = file ?? pipe.fileHandleForWriting
        try process.run()
        if file == nil { try pipe.fileHandleForWriting.close() }
        // Drain while the child runs; waiting first can deadlock on a full pipe.
        let data = file == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
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

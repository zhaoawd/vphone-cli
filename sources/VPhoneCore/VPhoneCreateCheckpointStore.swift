import Darwin
import Foundation

// MARK: - VPhoneCreateCheckpointStore

/// Owns `<bundle>/.create-checkpoint/` for one create or resume run.
///
/// Two locks, because the bundle lock cannot be held for a whole run: every
/// stage hands the bundle to a child that takes that lock itself (fw prepare,
/// the DFU boot, the CFW script, the boots).
///
/// - The *run lock* is a flock on the checkpoint directory inode, held for the
///   whole run. A second create/resume of the same bundle fails to take it and
///   never writes.
/// - Each write additionally takes the bundle lock (operation
///   `create-checkpoint`) between stages, so the checkpoint never changes while
///   another bundle operation holds the bundle.
///
/// A write is: temporary file, fsync, rename, fsync of the directory. That
/// makes the checkpoint file durable; it does not make the VM create atomic.
public final class VPhoneCreateCheckpointStore {
    public static let directoryName = ".create-checkpoint"
    public static let fileName = "checkpoint.json"
    public static let attemptsDirectoryName = "attempts"

    public enum WriteStep: String, Sendable {
        case writeTemporary, syncFile, rename, syncDirectory
    }

    /// Test seams. `inject` runs before each write step with the checkpoint
    /// being written; throwing aborts the write at that step.
    public struct Hooks {
        public var inject: (WriteStep, VPhoneCreateCheckpoint) throws -> Void
        public var acquireBundleLock: (URL) throws -> AnyObject

        public init(
            inject: @escaping (WriteStep, VPhoneCreateCheckpoint) throws -> Void = { _, _ in },
            acquireBundleLock: @escaping (URL) throws -> AnyObject = VPhoneCreateCheckpointStore.acquireBundleLock
        ) {
            self.inject = inject
            self.acquireBundleLock = acquireBundleLock
        }
    }

    public let bundleURL: URL
    public let directory: URL
    private let runLockDescriptor: Int32
    private let hooks: Hooks

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    private init(bundleURL: URL, descriptor: Int32, hooks: Hooks) {
        self.bundleURL = bundleURL
        directory = bundleURL.appendingPathComponent(Self.directoryName)
        runLockDescriptor = descriptor
        self.hooks = hooks
    }

    deinit {
        _ = flock(runLockDescriptor, LOCK_UN)
        close(runLockDescriptor)
    }

    /// Creates the checkpoint directory (exclusively) and takes its run lock.
    public static func initialize(bundleURL: URL, hooks: Hooks = Hooks()) throws -> VPhoneCreateCheckpointStore {
        let bundleURL = bundleURL.standardizedFileURL
        let directory = bundleURL.appendingPathComponent(directoryName)
        guard mkdir(directory.path, 0o755) == 0 else {
            throw VPhoneCreateRunError.io("create \(directory.path)", errno)
        }
        guard mkdir(directory.appendingPathComponent(attemptsDirectoryName).path, 0o755) == 0 else {
            throw VPhoneCreateRunError.io("create attempts directory", errno)
        }
        try syncDirectory(bundleURL)
        return try open(bundleURL: bundleURL, hooks: hooks)
    }

    /// Takes the run lock of an existing checkpoint directory without waiting.
    public static func open(bundleURL: URL, hooks: Hooks = Hooks()) throws -> VPhoneCreateCheckpointStore {
        let bundleURL = bundleURL.standardizedFileURL
        let directory = bundleURL.appendingPathComponent(directoryName)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            throw VPhoneCreateCheckpointError.missing(directory.path)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            throw VPhoneCreateCheckpointError.invalid("\(directory.path) is not a real directory")
        }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw VPhoneCreateRunError.io("open \(directory.path)", errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { throw VPhoneCreateRunError.runInProgress(bundleURL.path) }
            throw VPhoneCreateRunError.io("lock \(directory.path)", code)
        }
        return VPhoneCreateCheckpointStore(bundleURL: bundleURL, descriptor: fd, hooks: hooks)
    }

    /// True when another process holds the run lock. Read-only.
    public static func isRunLockHeld(bundleURL: URL) -> Bool {
        let path = bundleURL.appendingPathComponent(directoryName).path
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        _ = flock(fd, LOCK_UN)
        return false
    }

    // MARK: Read

    /// Reads and validates the checkpoint of a bundle without taking any lock.
    public static func load(bundleURL: URL) throws -> (checkpoint: VPhoneCreateCheckpoint, data: Data) {
        let url = bundleURL.appendingPathComponent(directoryName).appendingPathComponent(fileName)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw VPhoneCreateCheckpointError.missing(url.path) }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw VPhoneCreateCheckpointError.invalid("\(url.path) is not a regular file")
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw VPhoneCreateCheckpointError.unreadable("\(error)")
        }
        struct Version: Decodable { let schemaVersion: Int }
        let version: Version
        do { version = try VPhoneCreateJSON.decoder.decode(Version.self, from: data) } catch {
            throw VPhoneCreateCheckpointError.unreadable("not a checkpoint JSON object (\(error))")
        }
        guard version.schemaVersion == VPhoneCreateCheckpoint.currentSchemaVersion else {
            throw VPhoneCreateCheckpointError.unsupportedSchema(version.schemaVersion)
        }
        let checkpoint: VPhoneCreateCheckpoint
        do { checkpoint = try VPhoneCreateJSON.decoder.decode(VPhoneCreateCheckpoint.self, from: data) } catch {
            throw VPhoneCreateCheckpointError.unreadable("\(error)")
        }
        try checkpoint.validate()
        return (checkpoint, data)
    }

    // MARK: Write

    public func commit(_ checkpoint: VPhoneCreateCheckpoint) throws {
        let data = try VPhoneCreateJSON.encoder.encode(checkpoint)
        let lock = try hooks.acquireBundleLock(bundleURL)
        defer { withExtendedLifetime(lock) {} }
        try writeDurably(data, to: fileURL, checkpoint: checkpoint)
    }

    /// Keeps the previous checkpoint bytes before a new attempt replaces them.
    /// Never overwrites an existing archive.
    public func archive(previous data: Data, attemptId: String, checkpoint: VPhoneCreateCheckpoint) throws -> String {
        let relative = Self.attemptsDirectoryName + "/" + attemptId + "-" + VPhoneCreateDigest.sha256(data).prefix(12) + ".json"
        let url = directory.appendingPathComponent(relative)
        if let existing = try? Data(contentsOf: url) {
            guard existing == data else { throw VPhoneCreateCheckpointError.invalid("attempt archive \(relative) differs") }
            return relative
        }
        let lock = try hooks.acquireBundleLock(bundleURL)
        defer { withExtendedLifetime(lock) {} }
        try writeDurably(data, to: url, checkpoint: checkpoint)
        return relative
    }

    private func writeDurably(_ data: Data, to url: URL, checkpoint: VPhoneCreateCheckpoint) throws {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".write-" + UUID().uuidString)
        defer { unlink(temporary.path) }
        try hooks.inject(.writeTemporary, checkpoint)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw VPhoneCreateRunError.io("create \(temporary.path)", errno) }
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw VPhoneCreateRunError.io("write \(temporary.path)", errno)
                    }
                    offset += n
                }
            }
            try hooks.inject(.syncFile, checkpoint)
            guard fsync(fd) == 0 else { throw VPhoneCreateRunError.io("fsync \(temporary.path)", errno) }
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        try hooks.inject(.rename, checkpoint)
        guard rename(temporary.path, url.path) == 0 else { throw VPhoneCreateRunError.io("rename \(url.path)", errno) }
        try hooks.inject(.syncDirectory, checkpoint)
        try Self.syncDirectory(parent)
    }

    static func syncDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw VPhoneCreateRunError.io("open \(url.path)", errno) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw VPhoneCreateRunError.io("fsync \(url.path)", errno) }
    }

    // MARK: Bundle lock

    /// How long production code waits for a stage's child to release the
    /// bundle lock: checkpoint writes retry for this long, and the live
    /// verifier polls for this long before it rejects a stage whose lock is
    /// still held.
    public static let bundleLockRetryTimeout: TimeInterval = 30

    /// Production bundle-lock acquisition for a checkpoint write. Retries
    /// briefly: a stage's child (DFU boot, CFW script) releases the lock when
    /// it exits, which can trail the parent's return by a moment.
    public static func acquireBundleLock(_ bundleURL: URL) throws -> AnyObject {
        let deadline = Date().addingTimeInterval(bundleLockRetryTimeout)
        while true {
            do {
                return try VPhoneVMLock(directory: bundleURL, operation: VPhoneVMOperation.createCheckpoint)
            } catch {
                guard Date() < deadline else { throw VPhoneCreateRunError.bundleBusy("\(error)") }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
}

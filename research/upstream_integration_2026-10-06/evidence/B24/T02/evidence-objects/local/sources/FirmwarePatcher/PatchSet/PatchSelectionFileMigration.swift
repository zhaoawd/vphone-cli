import CryptoKit
import Darwin
import Foundation

/// Explicit migration of the upstream XML selection format. Does not create
/// missing selections, resolve a preset, write firmware, or grant C2 plan authority.
public enum PatchSelectionFileMigration {
    public static let filename = "PatchSelection.plist"
    static let maximumSize = 1_048_576

    public struct Preview: Encodable, Sendable {
        public let sourcePath: String
        public let sourceSHA256: String
        public let outputSHA256: String
        public let changed: Bool
        public let originalPreset: String
        public let migratedPreset: String
        public let selection: PatchSelectionMigration.Preview
    }

    public struct Prepared: Sendable {
        public let preview: Preview
        fileprivate let directory: URL
        fileprivate let directoryDevice: dev_t
        fileprivate let directoryInode: ino_t
        fileprivate let sourceInfo: FileIdentity
        fileprivate let source: Data
        fileprivate let output: Data
    }

    public struct Result: Encodable, Sendable {
        public let changed: Bool
        public let backupPath: String?
        public let outputSHA256: String
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case invalidFilename
        case invalidPlist
        case unsupportedFormat
        case invalidFields
        case unsafeFile
        case changedSincePreview
        case busy
        case pendingTransaction
        case backupConflict
        case io(String, Int32)
        case publicationUncertain(backup: String)

        public var errorDescription: String? {
            switch self {
            case .invalidFilename: "Migration requires an explicit PatchSelection.plist file"
            case .invalidPlist: "Selection plist is corrupt or contains repeated keys/entities"
            case .unsupportedFormat: "Only the reviewed upstream XML selection format is supported"
            case .invalidFields: "Selection requires exactly Preset, AllowedPatches and BlockedPatches with valid types"
            case .unsafeFile: "Selection must be a bounded regular file owned by the caller, without links"
            case .changedSincePreview: "Selection or its directory changed since the preview; preview again"
            case .busy: "Selection directory is locked; stop the VM or wait for its operation"
            case .pendingTransaction: "Pending firmware transaction; selection migration refused"
            case .backupConflict: "Existing selection backup differs from the original; preserved without overwriting"
            case let .io(operation, code): "Selection migration \(operation): \(String(cString: strerror(code)))"
            case let .publicationUncertain(backup): "Publication may have completed; inspect the selection before retrying. Original backup: \(backup)"
            }
        }
    }

    fileprivate struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let owner: uid_t
        let group: gid_t
        let links: nlink_t
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            mode = info.st_mode; owner = info.st_uid; group = info.st_gid; links = info.st_nlink
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }

    // MARK: - Preview

    public static func prepare(file: URL) throws -> Prepared {
        guard file.isFileURL, file.lastPathComponent == filename else { throw Failure.invalidFilename }
        let directory = file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let fd = try openDirectory(directory); defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.io("stat directory", errno) }
        let (source, identity) = try readFile(directory: fd, name: filename)
        guard !source.starts(with: Data("bplist".utf8)) else { throw Failure.unsupportedFormat }
        let validator = SelectionXMLValidator()
        let parser = XMLParser(data: source)
        parser.shouldResolveExternalEntities = false
        parser.delegate = validator
        guard parser.parse(), validator.valid else { throw Failure.invalidPlist }
        var format = PropertyListSerialization.PropertyListFormat.xml
        let value: Any
        do { value = try PropertyListSerialization.propertyList(from: source, options: [], format: &format) }
        catch { throw Failure.invalidPlist }
        guard format == .xml else { throw Failure.unsupportedFormat }
        guard let fields = value as? [String: Any], Set(fields.keys) == ["Preset", "AllowedPatches", "BlockedPatches"],
              let preset = fields["Preset"] as? String,
              let allowed = fields["AllowedPatches"] as? [String],
              let blocked = fields["BlockedPatches"] as? [String] else { throw Failure.invalidFields }
        let migratedPreset = try PatchSelectionMigration.migrateBundledPreset(preset)
        let selection = try PatchSelectionMigration.preview(select: allowed, block: blocked)
        let changed = preset != migratedPreset || !selection.renames.isEmpty
        let output = changed ? try PropertyListSerialization.data(fromPropertyList: [
            "Preset": migratedPreset, "AllowedPatches": selection.selected, "BlockedPatches": selection.blocked,
        ], format: .xml, options: 0) : source
        let preview = Preview(sourcePath: directory.appendingPathComponent(filename).path,
            sourceSHA256: digest(source), outputSHA256: digest(output), changed: changed,
            originalPreset: preset, migratedPreset: migratedPreset, selection: selection)
        return Prepared(preview: preview, directory: directory,
            directoryDevice: info.st_dev, directoryInode: info.st_ino,
            sourceInfo: identity, source: source, output: output)
    }

    // MARK: - Atomic application

    public static func apply(_ prepared: Prepared, expectedSourceSHA256: String) throws -> Result {
        try apply(prepared, expectedSourceSHA256: expectedSourceSHA256, inject: { _ in })
    }

    /// Publication boundaries also support the transaction fault tests.
    enum Event { case beforeBackup, afterBackup, beforePublish, afterPublish }

    static func apply(_ prepared: Prepared, expectedSourceSHA256: String,
                      inject: (Event) throws -> Void) throws -> Result {
        guard expectedSourceSHA256 == prepared.preview.sourceSHA256 else { throw Failure.changedSincePreview }
        let fd = try openDirectory(prepared.directory); defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.io("stat directory", errno) }
        guard info.st_dev == prepared.directoryDevice, info.st_ino == prepared.directoryInode else {
            throw Failure.changedSincePreview
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.busy }
        defer { flock(fd, LOCK_UN) }
        var transaction = stat()
        if fstatat(fd, ".firmware-transaction", &transaction, AT_SYMLINK_NOFOLLOW) == 0 { throw Failure.pendingTransaction }
        guard errno == ENOENT else { throw Failure.io("check firmware transaction", errno) }
        try verifySource(prepared, directory: fd)
        guard prepared.preview.changed else {
            return Result(changed: false, backupPath: nil, outputSHA256: prepared.preview.sourceSHA256)
        }
        let backupName = "\(filename).before-id-migration-\(prepared.preview.sourceSHA256).bak"
        let backupPath = prepared.directory.appendingPathComponent(backupName).path
        try inject(.beforeBackup)
        var existing = stat()
        if fstatat(fd, backupName, &existing, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw Failure.io("check backup", errno) }
            try writeExclusive(prepared.source, directory: fd, name: backupName, mode: 0o600)
        }
        try verifyBackup(prepared, directory: fd, name: backupName)
        guard fsync(fd) == 0 else { throw Failure.io("sync backup directory", errno) }
        try inject(.afterBackup)
        let temporary = ".\(filename).migrate-\(UUID().uuidString.lowercased())"
        let temporaryIdentity = try writeExclusive(prepared.output, directory: fd, name: temporary,
            mode: prepared.sourceInfo.mode & 0o777, owner: prepared.sourceInfo.owner, group: prepared.sourceInfo.group)
        defer { removeOwnedFile(directory: fd, name: temporary, identity: temporaryIdentity) }
        try inject(.beforePublish)
        try verifySource(prepared, directory: fd)
        try verifyBackup(prepared, directory: fd, name: backupName)
        let (stagedBytes, stagedIdentity) = try readFile(directory: fd, name: temporary)
        guard stagedIdentity == temporaryIdentity, stagedBytes == prepared.output else { throw Failure.changedSincePreview }
        guard renameat(fd, temporary, fd, filename) == 0 else { throw Failure.io("publish selection", errno) }
        // Errors after rename do not establish rollback. Preserve the backup and
        // tell the caller to read back the actual file before deciding to retry.
        do {
            try inject(.afterPublish)
            guard fsync(fd) == 0 else { throw Failure.io("sync selection directory", errno) }
            let (readback, _) = try readFile(directory: fd, name: filename)
            guard readback == prepared.output else { throw Failure.changedSincePreview }
        } catch { throw Failure.publicationUncertain(backup: backupPath) }
        return Result(changed: true, backupPath: backupPath, outputSHA256: prepared.preview.outputSHA256)
    }

    // MARK: - Confined file operations

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func openDirectory(_ directory: URL) throws -> Int32 {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io("open directory", errno) }
        return fd
    }

    private static func readFile(directory: Int32, name: String, synchronize: Bool = false) throws -> (Data, FileIdentity) {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io("open \(name)", errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.io("stat \(name)", errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid(),
              info.st_size >= 0, info.st_size <= maximumSize else { throw Failure.unsafeFile }
        let identity = FileIdentity(info)
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.io("read \(name)", errno)
            }
            if count == 0 { break }
            guard data.count + count <= maximumSize else { throw Failure.unsafeFile }
            data.append(contentsOf: buffer.prefix(count))
        }
        if synchronize, fsync(fd) != 0 { throw Failure.io("sync readback \(name)", errno) }
        guard fstat(fd, &info) == 0 else { throw Failure.io("stat readback \(name)", errno) }
        guard FileIdentity(info) == identity, data.count == identity.size else { throw Failure.changedSincePreview }
        return (data, identity)
    }

    private static func verifySource(_ prepared: Prepared, directory: Int32) throws {
        let (data, info) = try readFile(directory: directory, name: filename)
        guard info == prepared.sourceInfo, data == prepared.source else { throw Failure.changedSincePreview }
    }

    private static func verifyBackup(_ prepared: Prepared, directory: Int32, name: String) throws {
        let (data, _) = try readFile(directory: directory, name: name, synchronize: true)
        guard data == prepared.source else { throw Failure.backupConflict }
    }

    private static func removeOwnedFile(directory: Int32, name: String, identity: FileIdentity) {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
              info.st_dev == identity.device, info.st_ino == identity.inode else { return }
        unlinkat(directory, name, 0)
    }

    @discardableResult
    private static func writeExclusive(_ data: Data, directory: Int32, name: String, mode: mode_t,
                                       owner: uid_t? = nil, group: gid_t? = nil) throws -> FileIdentity {
        let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.io("create \(name)", errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.io("stat created \(name)", errno) }
        let createdIdentity = FileIdentity(info)
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Failure.io("write \(name)", count == 0 ? EIO : errno) }
                    offset += count
                }
            }
            if let owner, let group {
                guard fchown(fd, owner, group) == 0 else { throw Failure.io("retain owner/group", errno) }
            }
            guard fchmod(fd, mode) == 0 else { throw Failure.io("retain permissions", errno) }
            guard fsync(fd) == 0 else { throw Failure.io("sync \(name)", errno) }
            guard fstat(fd, &info) == 0 else { throw Failure.io("stat completed \(name)", errno) }
            return FileIdentity(info)
        } catch {
            // A same-name replacement belongs to its writer, even on failure.
            removeOwnedFile(directory: directory, name: name, identity: createdIdentity)
            throw error
        }
    }
}

/// PropertyListSerialization accepts repeated XML keys by keeping one value.
/// Reject that ambiguity and custom entities before decoding the reviewed shape.
private final class SelectionXMLValidator: NSObject, XMLParserDelegate {
    var valid = true
    var dictionaries: [Set<String>] = []
    var key: String?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "dict" { dictionaries.append([]) }
        if name == "key" { key = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if key != nil { key! += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "key" {
            guard let key, !dictionaries.isEmpty, dictionaries[dictionaries.count - 1].insert(key).inserted else {
                valid = false; parser.abortParsing(); return
            }
            self.key = nil
        }
        if name == "dict", !dictionaries.isEmpty { dictionaries.removeLast() }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        valid = false; parser.abortParsing()
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                publicID: String?, systemID: String?) {
        valid = false; parser.abortParsing()
    }
}

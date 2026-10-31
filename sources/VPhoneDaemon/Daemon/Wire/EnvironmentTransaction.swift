import CryptoKit
import Darwin
import Foundation

// MARK: - Environment Transaction

/// File side of `environment.install`, `environment.restore` and
/// `environment.loaded` (T17). The daemon passes /usr/lib and its staging
/// directory; firmware-free tests pass temporary directories.
///
/// Each install keeps a copy of every library it replaces and a journal under
/// `<staging>/transactions/<id>`, so a partial failure states which files
/// changed and where the previous bytes are. Replacement stops at the first
/// failure; nothing is rolled back automatically.
struct EnvironmentTransaction {
    enum Failure: Error, CustomStringConvertible {
        case invalid(String)
        case io(String)

        var description: String {
            switch self {
            case let .invalid(message), let .io(message): message
            }
        }
    }

    struct Identity: Equatable, Hashable {
        let device: UInt32
        let inode: UInt64
    }

    let libraries: [String]
    let libraryDirectory: String
    let stagingDirectory: String
    /// Complete or restored transactions kept besides every incomplete one.
    var retained = 5

    var stateDirectory: String { stagingDirectory + "/transactions" }

    func target(_ name: String) -> String { libraryDirectory + "/" + name }
    func staged(_ name: String) -> String { stagingDirectory + "/" + name }

    // MARK: Files

    static func sha256(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Identity of a regular file, without following a final symlink.
    static func identity(atPath path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Identity(device: UInt32(bitPattern: info.st_dev), inode: UInt64(info.st_ino))
    }

    func status() -> [[String: Any]] {
        libraries.map { name in
            var row: [String: Any] = ["name": name,
                                      "sha256": Self.sha256(atPath: target(name)) ?? NSNull(),
                                      "staged_sha256": Self.sha256(atPath: staged(name)) ?? NSNull()]
            if let identity = Self.identity(atPath: target(name)) {
                row["device"] = Int(identity.device)
                row["inode"] = Int(identity.inode)
            }
            return row
        }
    }

    func identities() -> [String: Identity] {
        var result: [String: Identity] = [:]
        for name in libraries { result[name] = Self.identity(atPath: target(name)) }
        return result
    }

    // MARK: Validation

    /// Checks the requested set before anything is written: known and unique
    /// names, a staged copy with the stated SHA-256, and an installed regular
    /// file to replace. The online update never adds a library.
    func validate(_ requested: Any?) throws -> [(name: String, sha256: String)] {
        guard let rows = requested as? [[String: Any]], !rows.isEmpty else {
            throw Failure.invalid("libraries must list the uploaded libraries")
        }
        var result: [(name: String, sha256: String)] = []
        for row in rows {
            guard let name = row["name"] as? String, libraries.contains(name) else {
                throw Failure.invalid("\(row["name"] ?? "<missing>") is not part of the vphone environment")
            }
            guard !result.contains(where: { $0.name == name }) else { throw Failure.invalid("\(name) is listed twice") }
            guard let sha = row["sha256"] as? String, sha.count == 64,
                  sha.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
                throw Failure.invalid("\(name) needs a lowercase hex sha256")
            }
            guard Self.identity(atPath: staged(name)) != nil else {
                throw Failure.invalid("Upload \(name) to \(stagingDirectory) first")
            }
            guard Self.sha256(atPath: staged(name)) == sha else {
                throw Failure.invalid("\(name) does not match its SHA-256")
            }
            guard Self.identity(atPath: target(name)) != nil else {
                throw Failure.invalid("\(target(name)) is not installed; the online update replaces existing libraries only")
            }
            result.append((name, sha))
        }
        return result
    }

    // MARK: Install

    /// Copies each current library to the transaction's backup directory and
    /// writes the journal. The library directory is not changed.
    func prepare(_ entries: [(name: String, sha256: String)]) throws -> EnvironmentJournal {
        let id = Self.newID()
        let directory = stateDirectory + "/" + id
        let backups = directory + "/backup"
        do {
            try FileManager.default.createDirectory(atPath: backups, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw Failure.io("Could not create \(backups): \(error.localizedDescription)") }
        var journal = EnvironmentJournal(id: id, created: Self.timestamp(), state: "prepared", libraries: [])
        for entry in entries {
            let source = target(entry.name)
            let backup = backups + "/" + entry.name
            guard let identity = Self.identity(atPath: source) else {
                throw Failure.invalid("\(source) is not installed")
            }
            do { try FileManager.default.copyItem(atPath: source, toPath: backup) } catch {
                try? FileManager.default.removeItem(atPath: directory)
                throw Failure.io("Could not back up \(source): \(error.localizedDescription)")
            }
            guard let previous = Self.sha256(atPath: backup), Self.sha256(atPath: source) == previous else {
                try? FileManager.default.removeItem(atPath: directory)
                throw Failure.io("\(source) changed while it was backed up")
            }
            journal.libraries.append(.init(name: entry.name, sha256: entry.sha256, previousSHA256: previous,
                                           previousDevice: identity.device, previousInode: identity.inode,
                                           backup: backup, state: "pending"))
        }
        try save(journal)
        return journal
    }

    /// Replaces the journal's libraries in order and stops at the first
    /// failure. The journal is saved after every step.
    func apply(_ journal: inout EnvironmentJournal, replace: (String, String) throws -> Void) {
        var failed = false
        for index in journal.libraries.indices {
            let name = journal.libraries[index].name
            if failed {
                journal.libraries[index].state = "not_attempted"
                continue
            }
            do {
                try replace(staged(name), target(name))
                journal.libraries[index].state = "replaced"
                unlink(staged(name))
            } catch {
                journal.libraries[index].state = "failed"
                journal.libraries[index].error = String(describing: error)
                failed = true
            }
            try? save(journal)
        }
        journal.state = failed ? "incomplete" : "complete"
        try? save(journal)
        prune()
    }

    /// Marks a prepared journal whose replacement never started.
    func abandon(_ journal: inout EnvironmentJournal, reason: String) {
        journal.state = "aborted"
        for index in journal.libraries.indices {
            journal.libraries[index].state = "not_attempted"
            journal.libraries[index].error = reason
        }
        try? save(journal)
    }

    // MARK: Restore

    /// Checks that each replaced library still has the bytes this transaction
    /// installed and that its backup still has the previous bytes.
    func prepareRestore(id: String) throws -> EnvironmentJournal {
        guard let journal = try journal(id: id) else { throw Failure.invalid("No environment transaction \(id)") }
        let replaced = journal.libraries.filter { $0.state == "replaced" }
        guard !replaced.isEmpty else { throw Failure.invalid("Transaction \(id) replaced no library") }
        for entry in replaced {
            guard Self.sha256(atPath: target(entry.name)) == entry.sha256 else {
                throw Failure.invalid("\(target(entry.name)) changed after transaction \(id); not restoring it")
            }
            guard Self.sha256(atPath: entry.backup) == entry.previousSHA256 else {
                throw Failure.invalid("Backup \(entry.backup) does not match its recorded SHA-256")
            }
        }
        return journal
    }

    func applyRestore(_ journal: inout EnvironmentJournal, replace: (String, String) throws -> Void) {
        var failed = false
        for index in journal.libraries.indices where journal.libraries[index].state == "replaced" {
            guard !failed else { continue }
            let entry = journal.libraries[index]
            do {
                try replace(entry.backup, target(entry.name))
                journal.libraries[index].state = "restored"
            } catch {
                journal.libraries[index].state = "restore_failed"
                journal.libraries[index].error = String(describing: error)
                failed = true
            }
            try? save(journal)
        }
        journal.state = failed ? "restore_incomplete" : "restored"
        try? save(journal)
    }

    // MARK: Journals

    func journal(id: String) throws -> EnvironmentJournal? {
        guard Self.isTransactionID(id) else { throw Failure.invalid("Invalid transaction id") }
        let path = stateDirectory + "/" + id + "/journal.json"
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        do { return try JSONDecoder().decode(EnvironmentJournal.self, from: data) } catch {
            throw Failure.io("Could not read \(path): \(error.localizedDescription)")
        }
    }

    /// Newest first.
    func journals() -> [EnvironmentJournal] {
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: stateDirectory)) ?? [])
            .filter(Self.isTransactionID).sorted(by: >)
        return ids.compactMap { try? journal(id: $0) }
    }

    func transactions() -> [[String: Any]] {
        journals().map { ["id": $0.id, "state": $0.state, "created": $0.created,
                          "journal": stateDirectory + "/" + $0.id + "/journal.json"] }
    }

    /// Identities of library copies replaced by recorded transactions.
    func previousIdentities() -> [Identity: (library: String, transaction: String)] {
        var result: [Identity: (library: String, transaction: String)] = [:]
        for journal in journals() {
            for entry in journal.libraries where ["replaced", "restored", "restore_failed"].contains(entry.state) {
                result[Identity(device: entry.previousDevice, inode: entry.previousInode)] = (entry.name, journal.id)
            }
        }
        return result
    }

    private func save(_ journal: EnvironmentJournal) throws {
        let directory = stateDirectory + "/" + journal.id
        let path = directory + "/journal.json"
        let temporary = path + ".tmp"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(journal)
            guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw Failure.io("Could not write \(temporary)")
            }
            let fd = open(temporary, O_RDONLY | O_CLOEXEC)
            if fd >= 0 { fsync(fd); close(fd) }
            guard rename(temporary, path) == 0 else { throw Failure.io("Could not write \(path)") }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.io("Could not encode the journal: \(error.localizedDescription)")
        }
    }

    /// Keeps every incomplete or aborted transaction and the newest `retained` others.
    private func prune() {
        let finished = journals().filter { ["complete", "restored"].contains($0.state) }
        for journal in finished.dropFirst(retained) {
            try? FileManager.default.removeItem(atPath: stateDirectory + "/" + journal.id)
        }
    }

    static func isTransactionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdefABCDEF-").contains($0)
        }
    }

    /// Sorts by creation time: 16 hex digits of wall-clock nanoseconds, then a random suffix.
    private static func newID() -> String {
        let nanoseconds = clock_gettime_nsec_np(CLOCK_REALTIME)
        return String(format: "%016llx", nanoseconds) + "-" + UUID().uuidString.prefix(8).lowercased()
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: Mappings

    /// Environment library mappings of one process. A region is `current`
    /// when it maps the installed file, and `stale` when it maps a copy a
    /// recorded transaction replaced or a different file under the library
    /// path (the kernel may report an unlinked file with its old path).
    func classify(_ regions: [EnvironmentMapping], current: [String: Identity],
                  previous: [Identity: (library: String, transaction: String)]) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var seen = Set<Identity>()
        for region in regions {
            let identity = Identity(device: region.device, inode: region.inode)
            guard !seen.contains(identity) else { continue }
            var row: [String: Any] = ["path": region.path, "device": Int(region.device), "inode": Int(region.inode)]
            if let name = current.first(where: { $0.value == identity })?.key {
                row["library"] = name
                row["state"] = "current"
            } else if let earlier = previous[identity] {
                row["library"] = earlier.library
                row["state"] = "stale"
                row["transaction"] = earlier.transaction
            } else if let name = libraries.first(where: { region.path == target($0) }) {
                row["library"] = name
                row["state"] = "stale"
            } else {
                continue
            }
            seen.insert(identity)
            rows.append(row)
        }
        return rows
    }
}

/// One vnode-backed region reported for a process.
struct EnvironmentMapping {
    let path: String
    let device: UInt32
    let inode: UInt64
}

// MARK: - Journal

struct EnvironmentJournal: Codable {
    struct Entry: Codable {
        var name: String
        /// SHA-256 of the library this transaction installs.
        var sha256: String
        var previousSHA256: String
        var previousDevice: UInt32
        var previousInode: UInt64
        var backup: String
        /// pending, replaced, failed, not_attempted, restored, restore_failed
        var state: String
        var error: String?

        enum CodingKeys: String, CodingKey {
            case name, sha256, backup, state, error
            case previousSHA256 = "previous_sha256"
            case previousDevice = "previous_device"
            case previousInode = "previous_inode"
        }
    }

    var id: String
    var created: String
    /// prepared, complete, incomplete, aborted, restored, restore_incomplete
    var state: String
    var libraries: [Entry]

    var dictionary: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
}

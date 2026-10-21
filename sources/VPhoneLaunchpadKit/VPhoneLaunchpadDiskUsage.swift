import Darwin
import Foundation
import VPhoneCore

/// What a machine or template folder takes on disk.
///
/// `allocated` counts every block its files hold (`st_blocks`), shared or
/// not. `exclusive` counts the blocks no other measured folder holds: what
/// deleting the folder frees once nothing else keeps them. A machine cloned
/// from a template shares every block it has not written with the template
/// and its other clones, so its exclusive size is a fraction of what is
/// allocated.
///
/// It is measured by comparing physical extents (`VPhoneLaunchpadDiskExtents`),
/// not with APFS's private size (`ATTR_CMNEXT_PRIVATESIZE`): a Time Machine
/// local snapshot shares every block that existed when it was taken, so
/// after each hourly snapshot the private size of every machine is 0 until
/// it writes again. The blocks a snapshot holds are still freed when it
/// expires, and the comparison counts them as the folder's own.
public struct VPhoneLaunchpadDiskUsage: Hashable, Sendable {
    public var allocated: Int64
    /// Nil when it could not be measured (the volume maps no extents, or the
    /// measurement ran out of time).
    public var exclusive: Int64?
    public var isCurrent = true
    public var allocationKnown = true

    /// `17.58 GB`, decimal as the Finder counts.
    public static func format(_ bytes: Int64, locale: Locale = .current) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }

}

// MARK: - Opening

/// Whether the meter may open a machine's files, from what Launchpad knows
/// of the machine.
///
/// Mapping opens the file; CFW refuses a disk held by another operation.
/// A shared directory lease excludes cooperating writers. The meter opens
/// only the files of a machine that nothing runs, nothing holds and nothing
/// works on; any other machine keeps the extents last mapped.
struct VPhoneLaunchpadDiskAccess: Hashable, Sendable {
    /// Launchpad's `vm launch` for the machine has not exited: starting,
    /// running, stopping, or panicked and not yet ended.
    var isLaunched = false
    /// `lsof` listed a process other than Launchpad for its disk image: a
    /// machine started elsewhere, or anything else holding it.
    var isHeld = false
    /// Launchpad has an operation on the machine: a creation or the template
    /// build in it, an export (queued or running), a CFW install, an
    /// environment or kernel update, a shutdown, a stop, a rename.
    var isBusy = false
    /// Launchpad has an operation on a whole library (an import, a template
    /// deletion), which can write any folder in it.
    var isLibraryBusy = false

    var mayOpen: Bool {
        !isLaunched && !isHeld && !isBusy && !isLibraryBusy
    }

}

// MARK: - Measuring

/// Measures machine and template folders against each other, keeping each
/// file's extents between passes.
///
/// A file is mapped again only when its size, modification or change time
/// is different, so a stopped machine's 20 GB image is opened once after it
/// changes, not on every pass. Mapping holds a shared directory lease and
/// is refused while a writer holds the directory. A folder is opened only
/// while `VPhoneLaunchpadDiskAccess` allows
/// it (`Folder.mayOpen`, asked again right before each file is mapped), and
/// Launchpad leaves its own process out when it asks `lsof` which machines
/// run.
actor VPhoneLaunchpadDiskMeter {
    struct Folder: Hashable, Sendable {
        var path: String
        /// False while something runs, holds or works on the folder: its
        /// files' last extents are used, and a file never mapped leaves it
        /// unknown.
        var mayOpen = true
    }

    /// What a pass does with one file.
    enum FileUse: Equatable, Sendable {
        /// The extents mapped last are current: nothing is opened.
        case current
        /// The file changed (or was never mapped) and may be opened.
        case map
        /// The file may not be opened: the extents mapped last stand in.
        case last
        /// Nothing to go on: the folder's exclusive size is unknown.
        case unknown
    }

    /// The decision for one file. Only a changed file is ever opened, and
    /// only when its folder may be opened and the pass has time left.
    nonisolated static func use(isCurrent: Bool, hasLast: Bool, mayOpen: Bool, hasTime: Bool) -> FileUse {
        if isCurrent {
            return .current
        }
        guard mayOpen else {
            return hasLast ? .last : .unknown
        }
        // A changed file the budget leaves out is unknown, not stale, so a
        // folder that is still being written does not show a wrong size.
        return hasTime ? .map : .unknown
    }

    private struct FileKey: Hashable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var modified: Int
        var modifiedNanoseconds: Int
        var changed: Int
        var changedNanoseconds: Int
    }

    private struct Mapped {
        var key: FileKey
        /// Nil when physical ownership is unknown. Allocated bytes alone do
        /// not establish that no other measured folder shares these blocks.
        var extents: VPhoneLaunchpadDiskExtents?
    }

    private var cache: [String: Mapped] = [:]
    private let budget: Duration
    private let mapper: @Sendable (String, ContinuousClock.Instant) -> Result<VPhoneLaunchpadDiskExtents, VPhoneLaunchpadDiskExtents.MapError>

    /// `budget` bounds the mapping of one pass. Files left over are mapped
    /// on a later pass, and their folders are unknown meanwhile.
    init(budget: Duration = .seconds(15),
         mapper: @escaping @Sendable (String, ContinuousClock.Instant) -> Result<VPhoneLaunchpadDiskExtents, VPhoneLaunchpadDiskExtents.MapError> = { path, deadline in
             VPhoneLaunchpadDiskExtents.map(path, deadline: deadline)
         }) {
        self.budget = budget
        self.mapper = mapper
    }

    /// Each folder's usage, by `Folder.path`. Files are not followed through
    /// links.
    ///
    /// `mayOpenNow` checks external holders once per folder, after acquiring
    /// a shared directory lease that excludes cooperating writers for the
    /// whole pass. `mayMapNow` rechecks local activity before each changed
    /// file is opened. The meter has one caller at a time; a
    /// second pass running while this one waits on `mayOpenNow` would only
    /// leave the cache less complete.
    func measure(
        _ folders: [Folder],
        mayOpenNow: (@Sendable (String) async -> Bool)? = nil,
        mayMapNow: (@Sendable (String, String) async -> Bool)? = nil,
    ) async -> [String: VPhoneLaunchpadDiskUsage] {
        let deadline = ContinuousClock.now + budget
        var seen: Set<String> = []
        var owners: [[VPhoneLaunchpadDiskExtents]] = []
        var usages: [VPhoneLaunchpadDiskUsage] = []
        for folder in folders {
            var mayOpen = folder.mayOpen
            var usage = VPhoneLaunchpadDiskUsage(allocated: 0, exclusive: 0, isCurrent: folder.mayOpen)
            var extents: [VPhoneLaunchpadDiskExtents] = []
            // Metadata inventory has its own bound. Exhausting the mapping
            // budget must not discard the next folder's allocated byte count.
            guard let files = try? Self.files(in: folder.path, deadline: .now + .seconds(15)) else {
                usage.exclusive = nil
                usage.allocationKnown = false
                usage.isCurrent = false
                owners.append([])
                usages.append(usage)
                continue
            }
            var lease: Int32 = -1
            defer { if lease >= 0 { close(lease) } }
            var checkedHolders = false
            for file in files {
                var status = stat()
                guard lstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    continue
                }
                seen.insert(file)
                let allocated = Int64(status.st_blocks) * 512
                usage.allocated += allocated
                guard allocated > 0 else {
                    continue
                }
                let key = FileKey(
                    device: Int64(status.st_dev), inode: status.st_ino, size: status.st_size,
                    modified: status.st_mtimespec.tv_sec, modifiedNanoseconds: status.st_mtimespec.tv_nsec,
                    changed: status.st_ctimespec.tv_sec, changedNanoseconds: status.st_ctimespec.tv_nsec,
                )
                let last = cache[file]
                func decide() -> FileUse {
                    Self.use(isCurrent: last?.key == key, hasLast: last != nil, mayOpen: mayOpen, hasTime: ContinuousClock.now < deadline)
                }
                var decision = decide()
                if decision == .map {
                    if !checkedHolders {
                        checkedHolders = true
                        lease = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        if lease < 0 || flock(lease, LOCK_SH | LOCK_NB) != 0 { mayOpen = false }
                        if mayOpen, let mayOpenNow, await !mayOpenNow(folder.path) { mayOpen = false }
                    }
                    if mayOpen, let mayMapNow, await !mayMapNow(folder.path, file) { mayOpen = false }
                    if !mayOpen { usage.isCurrent = false }
                    decision = decide()
                }
                var found: Mapped?
                switch decision {
                case .current, .last:
                    if decision == .last { usage.isCurrent = false; usage.exclusive = nil }
                    // A folder that may not be opened keeps what was last
                    // mapped, which is close: its blocks rarely move.
                    found = last
                case .map:
                    let mapped = VPhoneBundleGuard.withMeasurementLock(directory: URL(fileURLWithPath: folder.path)) {
                        mapper(file, deadline)
                    }
                    guard let mapped else { usage.isCurrent = false; usage.exclusive = nil; continue }
                    switch mapped {
                    case let .success(result):
                        found = Mapped(key: key, extents: result)
                    case .failure(.unsupported):
                        found = Mapped(key: key, extents: nil)
                    case .failure(.tooLarge):
                        break
                    }
                    if let found {
                        cache[file] = found
                    }
                case .unknown:
                    break
                }
                guard let found else {
                    usage.exclusive = nil
                    continue
                }
                if let result = found.extents {
                    extents.append(result)
                } else {
                    usage.exclusive = nil
                }
            }
            owners.append(extents)
            usages.append(usage)
        }
        cache = cache.filter { seen.contains($0.key) }
        let exclusive = VPhoneLaunchpadDiskExtents.exclusiveBytes(of: owners)
        let complete = usages.allSatisfy { $0.exclusive != nil && $0.isCurrent }
        var result: [String: VPhoneLaunchpadDiskUsage] = [:]
        for (index, folder) in folders.enumerated() {
            var usage = usages[index]
            // Rounding to whole blocks can only add to what st_blocks says.
            usage.exclusive = complete ? min(usage.allocated, exclusive[index]) : nil
            result[folder.path] = usage
        }
        return result
    }

    /// Every entry under `path`, not through links. The walk does not
    /// descend into a linked directory, and `lstat` rejects a linked file.
    private nonisolated static func files(in path: String, deadline: ContinuousClock.Instant) throws -> [String] {
        var files: [String] = []
        func visit(_ directory: String, depth: Int) throws {
            guard depth < 128, files.count < 4_000_000, ContinuousClock.now < deadline, !Task.isCancelled else {
                throw VPhoneLaunchpadDiskExtents.MapError.tooLarge
            }
            var root = stat()
            guard lstat(directory, &root) == 0, root.st_mode & S_IFMT == S_IFDIR else {
                throw VPhoneLaunchpadDiskExtents.MapError.unsupported
            }
            for name in try FileManager.default.contentsOfDirectory(atPath: directory) {
                let file = (directory as NSString).appendingPathComponent(name)
                var info = stat()
                guard lstat(file, &info) == 0 else { throw VPhoneLaunchpadDiskExtents.MapError.unsupported }
                if info.st_mode & S_IFMT == S_IFDIR {
                    try visit(file, depth: depth + 1)
                } else if info.st_mode & S_IFMT == S_IFREG {
                    files.append(file)
                }
            }
        }
        try visit(path, depth: 0)
        return files
    }

}

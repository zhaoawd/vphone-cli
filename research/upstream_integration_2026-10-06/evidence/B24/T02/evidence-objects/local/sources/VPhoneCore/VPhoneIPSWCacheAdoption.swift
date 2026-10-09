import CryptoKit
import Darwin
import Foundation
import VPhoneArchiveKit

/// Explicit adoption of cache entries that have no completion marker, such as
/// IPSWs downloaded before T14. Only `vphone-cli fw cache adopt` calls this;
/// nothing scans or adopts on its own, and nothing is deleted.
///
/// Adoption writes the same `vphone-ipsw-cache/1` marker a download writes
/// (`scripts/ipsw_cache_entry.py`), under the same cache directory lock, with
/// the published file's size, inode, mtime and full SHA-256. The marker also
/// carries `"adopted": true` and `"source_verified": false`: the content was
/// hashed in place and was not checked against a transfer from the source.
/// `fw_prepare.sh` treats an adopted entry as usable and says so.
///
/// A directory (an extraction cache) can be adopted only when the IPSW it was
/// extracted from is itself a usable entry; its marker names that IPSW's size
/// and SHA-256, and every member of the IPSW must be present with its size.
extension VPhoneIPSWCache {
    public struct Adoption: Sendable, Codable {
        public enum Outcome: String, Sendable, Codable {
            /// A marker was written now.
            case adopted
            /// The entry already had a usable marker; nothing was written.
            case alreadyUsable
        }

        public let entry: URL
        public let isDirectory: Bool
        public let outcome: Outcome
        /// Whether the usable marker (written now or found) is an adoption.
        public let adopted: Bool
        /// The source the marker names; nil for a directory.
        public let source: String?
        public let sourceFromCatalog: Bool
        /// The file's size and SHA-256, or for a directory those of its IPSW.
        public let size: Int64
        public let sha256: String
        public let version: String?
        public let build: String?
        public let productTypes: [String]
        /// Checks performed in addition to hashing.
        public let checks: [String]
    }

    enum AdoptionError: Swift.Error, LocalizedError {
        case cacheDirectoryMissing(URL)
        case missing(URL)
        case outsideCache(URL, cache: URL)
        case symlink(URL)
        case internalName(URL)
        case notFileOrDirectory(URL)
        case sourceRequired(String)
        case ambiguousSource(String, [String])
        case unsupportedSource(String)
        case localSourceIsNotEntry(String, entry: URL)
        case nameMismatch(String, source: String, expected: [String])
        case notIPSW(URL)
        case manifestMismatch(String, detail: String)
        case invalidExpectedDigest(String)
        case digestMismatch(URL, expected: String, actual: String, origin: String)
        case changedWhileHashing(URL)
        case markedForOtherSource(URL, recorded: String)
        case parentNotUsable(URL, parent: URL, reason: String)
        case extractedFromOtherIPSW(URL)
        case extractionMismatch(URL, detail: String)

        public var errorDescription: String? {
            switch self {
            case let .cacheDirectoryMissing(cache):
                "The IPSW cache \(cache.path) does not exist."
            case let .missing(entry):
                "\(entry.path) does not exist."
            case let .outsideCache(entry, cache):
                "\(entry.path) is not an entry of the IPSW cache \(cache.path). Only files and directories directly inside the cache can be adopted."
            case let .symlink(entry):
                "\(entry.path) is a symbolic link. Only regular files and directories can be adopted."
            case let .internalName(entry):
                entry.lastPathComponent.contains(".partial.")
                    ? "\(entry.lastPathComponent) is a partial download or extraction, not a cache entry. It cannot be adopted."
                    : "\(entry.lastPathComponent) is a hidden cache file (a marker or partial), not a cache entry. It cannot be adopted."
            case let .notFileOrDirectory(entry):
                "\(entry.path) is neither a regular file nor a directory."
            case let .sourceRequired(name):
                "No catalog source is cached as \(name). Pass the URL fw prepare uses for it with --source <url>, or --source <path of this file> when fw prepare is given this file as a local path."
            case let .ambiguousSource(name, sources):
                "\(name) matches several catalog sources (\(sources.joined(separator: ", "))). Pass one with --source."
            case let .unsupportedSource(source):
                "Unsupported source \(source). Use an HTTP(S) URL or the path of the entry itself."
            case let .localSourceIsNotEntry(source, entry):
                "The local source \(source) is not \(entry.path). A local source can be adopted only as the entry itself; for another local file, let fw prepare copy it."
            case let .nameMismatch(name, source, expected):
                "fw prepare does not cache \(source) as \(name) (it uses \(expected.joined(separator: " or "))). Check the --source URL."
            case let .notIPSW(entry):
                "\(entry.lastPathComponent) is not a readable IPSW (no BuildManifest.plist with ProductVersion and ProductBuildVersion). It was not adopted."
            case let .manifestMismatch(name, detail):
                "\(name) does not match its source: \(detail). It was not adopted."
            case let .invalidExpectedDigest(value):
                "--expect-sha256 \(value) is not a 64-digit hexadecimal SHA-256."
            case let .digestMismatch(entry, expected, actual, origin):
                "The SHA-256 of \(entry.lastPathComponent) is \(actual), not \(expected) (\(origin)). It was not adopted."
            case let .changedWhileHashing(entry):
                "\(entry.lastPathComponent) changed while it was hashed. It was not adopted; try again when nothing writes it."
            case let .markedForOtherSource(entry, recorded):
                "\(entry.lastPathComponent) already has a completion marker for \(recorded). The marker was not changed."
            case let .parentNotUsable(directory, parent, reason):
                "\(directory.lastPathComponent) can be adopted only after \(parent.lastPathComponent) is a usable cache entry (\(reason)). Adopt \(parent.lastPathComponent) first."
            case let .extractedFromOtherIPSW(directory):
                "\(directory.lastPathComponent) has a completion marker naming another IPSW. The marker was not changed."
            case let .extractionMismatch(directory, detail):
                "\(directory.lastPathComponent) is not a complete extraction of its IPSW: \(detail). It was not adopted."
            }
        }
    }

    /// How long adoption waits for another run holding the cache lock.
    static let adoptionLockTimeout: TimeInterval = 600

    /// Adopts `path` (an entry of `cacheDirectory`, or a bare entry name).
    /// `progress` receives (hashed bytes, total bytes) while a file is hashed.
    public static func adopt(
        _ path: String,
        in cacheDirectory: URL,
        source: String? = nil,
        expectedSHA256: String? = nil,
        progress: ((Int64, Int64) -> Void)? = nil,
    ) throws -> Adoption {
        let cache = try existingCacheDirectory(cacheDirectory)
        let entry = try adoptableEntry(path, in: cache)
        var info = stat()
        guard lstat(entry.path, &info) == 0 else { throw AdoptionError.missing(entry) }
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            let expected = try expectedSHA256.map(normalizedDigest)
            return try adoptFile(entry, cache: cache, source: source, expectedSHA256: expected, progress: progress)
        case S_IFDIR:
            return try adoptDirectory(entry, cache: cache)
        case S_IFLNK:
            throw AdoptionError.symlink(entry)
        default:
            throw AdoptionError.notFileOrDirectory(entry)
        }
    }

    // MARK: - Entry location

    private static func existingCacheDirectory(_ cacheDirectory: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cacheDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw AdoptionError.cacheDirectoryMissing(cacheDirectory) }
        return URL(fileURLWithPath: realPath(cacheDirectory.path) ?? cacheDirectory.path, isDirectory: true)
    }

    /// A direct child of the cache with an entry name. The parent directory
    /// is resolved; the entry itself is not, so a symlink stays a symlink.
    private static func adoptableEntry(_ path: String, in cache: URL) throws -> URL {
        let given = path.contains("/")
            ? URL(fileURLWithPath: path).standardizedFileURL
            : cache.appendingPathComponent(path)
        let name = given.lastPathComponent
        guard let parent = realPath(given.deletingLastPathComponent().path) else {
            throw AdoptionError.missing(given)
        }
        guard parent == cache.path, !name.isEmpty, name != ".", name != ".." else {
            throw AdoptionError.outsideCache(given, cache: cache)
        }
        let entry = cache.appendingPathComponent(name)
        if name.hasPrefix(".") { throw AdoptionError.internalName(entry) }
        var info = stat()
        guard lstat(entry.path, &info) == 0 else { throw AdoptionError.missing(entry) }
        if info.st_mode & S_IFMT == S_IFLNK { throw AdoptionError.symlink(entry) }
        return entry
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func normalizedDigest(_ value: String) throws -> String {
        let digest = value.lowercased()
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
            throw AdoptionError.invalidExpectedDigest(value)
        }
        return digest
    }

    // MARK: - Sources

    private enum Source {
        case url(URL)
        /// The entry itself, given to fw prepare as a local path.
        case local(String)

        var display: String {
            switch self {
            case let .url(url): url.absoluteString
            case let .local(path): path
            }
        }
    }

    /// Every source `VPhoneFirmwareCatalog` (and so `fw_prepare.sh`'s defaults) names.
    static var catalogSources: [String] {
        var seen = Set<String>()
        return VPhoneFirmwareCatalog.pairings.flatMap { [$0.iosURL, $0.cloudosURL] }
            .filter { seen.insert($0).inserted }
    }

    /// The names under which a cache stores `source`: `fw_prepare.sh` keeps an
    /// iPhone IPSW under the URL's last component and a cloudOS IPSW under
    /// `derive_cache_ipsw_name`; `resolve` uses `cacheName(for:)`.
    static func cacheNames(for source: String) -> [String] {
        var names: [String] = []
        let base = source.components(separatedBy: "/").last ?? ""
        if !base.isEmpty { names.append(base) }
        names.append(scriptCacheName(for: source))
        if let url = URL(string: source) { names.append(cacheName(for: url)) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// `derive_cache_ipsw_name` in `scripts/fw_prepare.sh`.
    static func scriptCacheName(for source: String, fallbackStem: String = "pcc-base") -> String {
        var base = source.components(separatedBy: "/").last ?? ""
        base = String(base.prefix { $0 != "?" })
        base = String(base.prefix { $0 != "#" })
        if base.hasSuffix(".ipsw") { return base }
        var stem = base
        if let dot = stem.lastIndex(of: ".") { stem = String(stem[..<dot]) }
        if stem.isEmpty { stem = fallbackStem }
        // tr -cs '[:alnum:]_.-' '_': other characters become '_', and runs of
        // '_' collapse to one.
        var translated = ""
        for scalar in stem.unicodeScalars {
            let kept = CharacterSet.alphanumerics.contains(scalar) || "_.-".unicodeScalars.contains(scalar)
            let character: Character = kept ? Character(scalar) : "_"
            if character == "_", translated.last == "_" { continue }
            translated.append(character)
        }
        stem = translated.isEmpty ? fallbackStem : String(translated.prefix(48))
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(stem)-\(digest.prefix(12)).ipsw"
    }

    private static func resolveSource(_ given: String?, for entry: URL) throws -> (Source, fromCatalog: Bool) {
        let name = entry.lastPathComponent
        guard let given else {
            let matches = catalogSources.filter { cacheNames(for: $0).contains(name) }
            guard let only = matches.first, let url = URL(string: only) else {
                throw AdoptionError.sourceRequired(name)
            }
            guard matches.count == 1 else { throw AdoptionError.ambiguousSource(name, matches) }
            return (.url(url), true)
        }
        if let url = URL(string: given), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                let expected = cacheNames(for: given)
                guard expected.contains(name) else {
                    throw AdoptionError.nameMismatch(name, source: given, expected: expected)
                }
                return (.url(url), false)
            }
            guard scheme == "file" else { throw AdoptionError.unsupportedSource(given) }
        }
        let path = given.hasPrefix("file://") ? (URL(string: given)?.path ?? given) : given
        guard let resolved = realPath(path), resolved == entry.path else {
            throw AdoptionError.localSourceIsNotEntry(given, entry: entry)
        }
        return (.local(resolved), false)
    }

    /// `source_identity` in `scripts/ipsw_cache_entry.py`.
    private static func sourceIdentity(_ source: Source) throws -> [String: Any] {
        switch source {
        case let .url(url):
            return ["url": url.absoluteString]
        case let .local(path):
            var info = stat()
            guard stat(path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return ["path": path, "device": Int64(info.st_dev), "inode": UInt64(info.st_ino),
                    "size": Int64(info.st_size), "mtime_ns": mtimeNanoseconds(info)]
        }
    }

    // MARK: - Files

    private static func adoptFile(
        _ entry: URL, cache: URL, source given: String?, expectedSHA256: String?,
        progress: ((Int64, Int64) -> Void)?,
    ) throws -> Adoption {
        let (source, fromCatalog) = try resolveSource(given, for: entry)
        return try VPhoneBundleGuard.withLibraryLock(root: cache, timeout: adoptionLockTimeout) { _ in
            var before = stat()
            guard lstat(entry.path, &before) == 0 else { throw AdoptionError.missing(entry) }
            guard before.st_mode & S_IFMT == S_IFREG else { throw AdoptionError.notFileOrDirectory(entry) }
            let identity = try sourceIdentity(source)

            if let existing = readMarker(markerURL(for: entry), kind: "file"),
               markerMatchesFile(existing, info: before)
            {
                guard sameJSON(existing["source"], identity) else {
                    throw AdoptionError.markedForOtherSource(entry, recorded: describeSource(existing["source"]))
                }
                let digest = existing["sha256"] as? String ?? ""
                if let expectedSHA256, digest != expectedSHA256 {
                    throw AdoptionError.digestMismatch(entry, expected: expectedSHA256, actual: digest, origin: "--expect-sha256")
                }
                let manifest = existing["manifest"] as? [String: Any]
                return Adoption(
                    entry: entry, isDirectory: false, outcome: .alreadyUsable,
                    adopted: existing["adopted"] as? Bool == true, source: source.display,
                    sourceFromCatalog: fromCatalog, size: Int64(before.st_size), sha256: digest,
                    version: manifest?["version"] as? String, build: manifest?["build"] as? String,
                    productTypes: manifest?["product_types"] as? [String] ?? [], checks: [])
            }

            // Readable BuildManifest, the same check `fw inspect` makes.
            guard let archive = try? inspect(entry) else { throw AdoptionError.notIPSW(entry) }
            var checks = ["build-manifest"]
            if try checkAppleFileName(source, archive: archive, name: entry.lastPathComponent) {
                checks.append("file-name-version-build")
            }

            let (digest, hashed) = try sha256(of: entry, expected: before, progress: progress)
            var after = stat()
            guard lstat(entry.path, &after) == 0, hashed == Int64(after.st_size),
                  after.st_ino == before.st_ino, after.st_size == before.st_size,
                  mtimeNanoseconds(after) == mtimeNanoseconds(before)
            else { throw AdoptionError.changedWhileHashing(entry) }

            if let expectedSHA256 {
                guard digest == expectedSHA256 else {
                    throw AdoptionError.digestMismatch(entry, expected: expectedSHA256, actual: digest, origin: "--expect-sha256")
                }
                checks.append("expected-sha256")
            }
            if case let .url(url) = source, let named = urlDigest(url) {
                guard digest == named else {
                    throw AdoptionError.digestMismatch(entry, expected: named, actual: digest, origin: "the digest in the source URL")
                }
                checks.append("url-digest")
            }

            let marker: [String: Any] = [
                "format": markerFormat, "kind": "file", "source": identity,
                "size": hashed, "sha256": digest,
                "file": ["inode": UInt64(after.st_ino), "mtime_ns": mtimeNanoseconds(after)],
                "adopted": true, "source_verified": false,
                "adoption": [
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "source_from": fromCatalog ? "catalog" : "argument",
                    "checks": checks,
                    "note": "content hashed in place; not verified against a transfer from the source",
                ],
                "manifest": [
                    "version": archive.version, "build": archive.build,
                    "product_types": archive.productTypes,
                    "device_classes": archive.deviceClasses.sorted(),
                ],
            ]
            try writeMarkerJSON(marker, to: markerURL(for: entry))
            return Adoption(
                entry: entry, isDirectory: false, outcome: .adopted, adopted: true,
                source: source.display, sourceFromCatalog: fromCatalog, size: hashed, sha256: digest,
                version: archive.version, build: archive.build, productTypes: archive.productTypes,
                checks: checks)
        }
    }

    /// Apple restore names carry `<product>_<version>_<build>_Restore.ipsw`;
    /// when the source has such a name, the BuildManifest must agree.
    private static func checkAppleFileName(_ source: Source, archive: Archive, name: String) throws -> Bool {
        let base: String = switch source {
        case let .url(url): url.lastPathComponent
        case let .local(path): URL(fileURLWithPath: path).lastPathComponent
        }
        let parts = base.components(separatedBy: "_")
        guard parts.count == 4, parts[3] == "Restore.ipsw", parts[0].contains(",") else { return false }
        var problems: [String] = []
        if !archive.productTypes.contains(parts[0]) {
            problems.append("products \(archive.productTypes.joined(separator: ", ")) do not include \(parts[0])")
        }
        if archive.version != parts[1] { problems.append("version \(archive.version), not \(parts[1])") }
        if archive.build != parts[2] { problems.append("build \(archive.build), not \(parts[2])") }
        guard problems.isEmpty else {
            throw AdoptionError.manifestMismatch(name, detail: "its BuildManifest has " + problems.joined(separator: "; "))
        }
        return true
    }

    /// A 64-digit hexadecimal path component, as in the PCC cloudOS URLs.
    static func urlDigest(_ url: URL) -> String? {
        url.pathComponents.lazy.map { $0.lowercased().hasSuffix(".ipsw") ? String($0.dropLast(5)) : $0 }
            .first { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }?.lowercased()
    }

    private static func sha256(of entry: URL, expected: stat, progress: ((Int64, Int64) -> Void)?) throws -> (String, Int64) {
        let fd = open(entry.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == expected.st_ino, opened.st_dev == expected.st_dev else {
            throw AdoptionError.changedWhileHashing(entry)
        }
        _ = fcntl(fd, F_NOCACHE, 1)
        let total = Int64(expected.st_size)
        let chunk = 8 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buffer.deallocate() }
        var hasher = SHA256()
        var hashed: Int64 = 0
        progress?(0, total)
        while true {
            let count = read(fd, buffer.baseAddress, chunk)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0 ..< count]))
            hashed += Int64(count)
            progress?(hashed, total)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), hashed)
    }

    // MARK: - Directories

    static let directoryMarkerName = ".vphone-extract-complete"

    /// `parent_identity` in `scripts/ipsw_cache_entry.py`: the IPSW's marker
    /// size and SHA-256 while the file still matches the marker.
    static func parentIdentity(_ parent: URL) throws -> (size: Int64, sha256: String, adopted: Bool) {
        guard let marker = readMarker(markerURL(for: parent), kind: "file") else {
            throw AdoptionError.parentNotUsable(parent, parent: parent, reason: "it has no completion marker")
        }
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AdoptionError.parentNotUsable(parent, parent: parent, reason: "it is absent")
        }
        guard markerMatchesFile(marker, info: info), let digest = marker["sha256"] as? String, digest.count == 64,
              let size = (marker["size"] as? NSNumber)?.int64Value
        else {
            throw AdoptionError.parentNotUsable(parent, parent: parent, reason: "it changed after its completion marker was written")
        }
        return (size, digest, marker["adopted"] as? Bool == true)
    }

    private static func adoptDirectory(_ directory: URL, cache: URL) throws -> Adoption {
        let parent = cache.appendingPathComponent(directory.lastPathComponent + ".ipsw")
        return try VPhoneBundleGuard.withLibraryLock(root: cache, timeout: adoptionLockTimeout) { _ in
            let identity: (size: Int64, sha256: String, adopted: Bool)
            do {
                identity = try parentIdentity(parent)
            } catch let AdoptionError.parentNotUsable(_, _, reason) {
                throw AdoptionError.parentNotUsable(directory, parent: parent, reason: reason)
            }
            let expectedParent: [String: Any] = ["size": identity.size, "sha256": identity.sha256]
            let markerURL = directory.appendingPathComponent(directoryMarkerName)
            if let existing = readMarker(markerURL, kind: "directory") {
                guard sameJSON(existing["parent"], expectedParent) else {
                    throw AdoptionError.extractedFromOtherIPSW(directory)
                }
                return Adoption(
                    entry: directory, isDirectory: true, outcome: .alreadyUsable,
                    adopted: existing["adopted"] as? Bool == true, source: nil, sourceFromCatalog: false,
                    size: identity.size, sha256: identity.sha256, version: nil, build: nil, productTypes: [], checks: [])
            }
            let checks = try verifyExtraction(directory, of: parent)
            try writeMarkerJSON([
                "format": markerFormat, "kind": "directory", "parent": expectedParent,
                "adopted": true, "source_verified": false,
                "adoption": [
                    "at": ISO8601DateFormatter().string(from: Date()),
                    "checks": checks,
                    "note": "member names, types and sizes compared with the IPSW; contents not hashed",
                ],
            ], to: markerURL)
            return Adoption(
                entry: directory, isDirectory: true, outcome: .adopted, adopted: true, source: nil,
                sourceFromCatalog: false, size: identity.size, sha256: identity.sha256,
                version: nil, build: nil, productTypes: [], checks: checks)
        }
    }

    /// Every member of the IPSW is present with its type and size, and the
    /// directory holds nothing else (Finder's `.DS_Store` aside). Catches an
    /// interrupted unzip; contents are not compared.
    private static func verifyExtraction(_ directory: URL, of parent: URL) throws -> [String] {
        let members: [VPhoneArchiveReader.Entry]
        do {
            members = try VPhoneArchiveReader.entries(of: parent)
        } catch {
            throw AdoptionError.extractionMismatch(directory, detail: "cannot list \(parent.lastPathComponent): \(error.localizedDescription)")
        }
        var expected: [String: VPhoneArchiveReader.Entry] = [:]
        var implied = Set<String>()
        for member in members {
            var path = member.path
            while path.hasPrefix("./") { path.removeFirst(2) }
            while path.hasSuffix("/") { path.removeLast() }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.hasPrefix("/"), !components.contains(where: { $0 == ".." || $0.isEmpty }) else {
                throw AdoptionError.extractionMismatch(directory, detail: "the IPSW has an unsafe member name \(member.path)")
            }
            expected[path] = member
            for depth in 1 ..< components.count {
                implied.insert(components[..<depth].joined(separator: "/"))
            }
        }
        for (path, member) in expected.sorted(by: { $0.key < $1.key }) {
            var info = stat()
            let file = directory.appendingPathComponent(path)
            guard lstat(file.path, &info) == 0 else {
                throw AdoptionError.extractionMismatch(directory, detail: "\(path) is missing")
            }
            let type = info.st_mode & S_IFMT
            if member.isDirectory {
                guard type == S_IFDIR else { throw AdoptionError.extractionMismatch(directory, detail: "\(path) is not a directory") }
            } else if member.isSymlink {
                guard type == S_IFLNK else { throw AdoptionError.extractionMismatch(directory, detail: "\(path) is not a symbolic link") }
            } else {
                guard type == S_IFREG else { throw AdoptionError.extractionMismatch(directory, detail: "\(path) is not a regular file") }
                guard Int64(info.st_size) == member.size else {
                    throw AdoptionError.extractionMismatch(
                        directory, detail: "\(path) has \(info.st_size) bytes, the IPSW member has \(member.size)")
                }
            }
        }
        guard let walker = FileManager.default.enumerator(atPath: directory.path) else {
            throw AdoptionError.extractionMismatch(directory, detail: "cannot list the directory")
        }
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if relative == directoryMarkerName || name == ".DS_Store" { continue }
            if expected[relative] == nil, !implied.contains(relative) {
                throw AdoptionError.extractionMismatch(directory, detail: "\(relative) is not a member of the IPSW")
            }
        }
        return ["member-names-types-sizes"]
    }

    // MARK: - Listing

    public struct ListedEntry: Sendable, Codable, Equatable {
        public let name: String
        /// file, directory, partial, symlink, marker or other.
        public let kind: String
        /// downloaded, copied, adopted, stale, unmarked, foreign-marker
        /// (file); extracted, adopted, stale, unmarked (directory); partial,
        /// orphan-marker, symlink, other.
        public let state: String
        public let size: Int64?
        public let source: String?
        public let sha256: String?
        public let version: String?
        public let build: String?
        public let detail: String?
    }

    /// Reads the cache without changing it: no lock, no hashing, no removal.
    public static func list(_ cacheDirectory: URL) throws -> [ListedEntry] {
        let names = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).sorted()
        var rows: [ListedEntry] = []
        for name in names {
            let path = cacheDirectory.appendingPathComponent(name)
            var info = stat()
            guard lstat(path.path, &info) == 0 else { continue }
            if name.hasPrefix(".") {
                if name.contains(".partial.") {
                    let pid = name.replacingOccurrences(of: ".aria2", with: "").split(separator: ".").last.flatMap { pid_t($0) }
                    let alive = pid.map { kill($0, 0) == 0 || errno == EPERM } ?? false
                    rows.append(ListedEntry(
                        name: name, kind: "partial", state: "partial", size: Int64(info.st_size), source: nil,
                        sha256: nil, version: nil, build: nil,
                        detail: pid.map { alive ? "writer pid \($0) is running" : "writer pid \($0) has exited; the next fw prepare removes it" }))
                } else if name.hasSuffix(".vphone-complete") {
                    let entryName = String(name.dropFirst().dropLast(".vphone-complete".count))
                    if !FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(entryName).path) {
                        rows.append(ListedEntry(name: name, kind: "marker", state: "orphan-marker", size: nil, source: nil,
                                                sha256: nil, version: nil, build: nil, detail: "no entry \(entryName)"))
                    }
                }
                continue
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG: rows.append(listFile(path, info: info))
            case S_IFDIR: rows.append(listDirectory(path))
            case S_IFLNK:
                rows.append(ListedEntry(name: name, kind: "symlink", state: "symlink", size: nil, source: nil, sha256: nil,
                                        version: nil, build: nil, detail: "not a cache entry"))
            default:
                rows.append(ListedEntry(name: name, kind: "other", state: "other", size: nil, source: nil, sha256: nil,
                                        version: nil, build: nil, detail: nil))
            }
        }
        return rows
    }

    private static func listFile(_ entry: URL, info: stat) -> ListedEntry {
        let size = Int64(info.st_size)
        let row = { (state: String, marker: [String: Any]?, detail: String?) in
            let manifest = marker?["manifest"] as? [String: Any]
            return ListedEntry(
                name: entry.lastPathComponent, kind: "file", state: state, size: size,
                source: marker.map { describeSource($0["source"]) }, sha256: marker?["sha256"] as? String,
                version: manifest?["version"] as? String, build: manifest?["build"] as? String, detail: detail)
        }
        guard FileManager.default.fileExists(atPath: markerURL(for: entry).path) else {
            return row("unmarked", nil, "no completion marker; fw prepare discards it and fetches the source again")
        }
        guard let marker = readMarker(markerURL(for: entry), kind: "file") else {
            return row("foreign-marker", nil, "marker of another format; fw prepare discards the entry")
        }
        guard markerMatchesFile(marker, info: info) else {
            return row("stale", marker, "file changed after its completion marker was written")
        }
        if marker["adopted"] as? Bool == true {
            return row("adopted", marker, "adopted; source not verified by download")
        }
        let source = marker["source"] as? [String: Any]
        return row(source?["url"] != nil ? "downloaded" : "copied", marker, nil)
    }

    private static func listDirectory(_ directory: URL) -> ListedEntry {
        let parent = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".ipsw")
        let row = { (state: String, detail: String?, digest: String?) in
            ListedEntry(name: directory.lastPathComponent, kind: "directory", state: state, size: nil,
                        source: digest == nil ? nil : parent.lastPathComponent, sha256: digest,
                        version: nil, build: nil, detail: detail)
        }
        let markerURL = directory.appendingPathComponent(directoryMarkerName)
        guard let marker = readMarker(markerURL, kind: "directory") else {
            return row("unmarked", "no completion marker; fw prepare discards it and extracts again", nil)
        }
        let recorded = marker["parent"] as? [String: Any]
        let digest = recorded?["sha256"] as? String
        guard let identity = try? parentIdentity(parent) else {
            return row("stale", "\(parent.lastPathComponent) is not a usable entry", digest)
        }
        guard sameJSON(recorded, ["size": identity.size, "sha256": identity.sha256] as [String: Any]) else {
            return row("stale", "extracted from another IPSW", digest)
        }
        return marker["adopted"] as? Bool == true
            ? row("adopted", "adopted; contents not hashed", digest)
            : row("extracted", nil, digest)
    }

    // MARK: - Marker helpers

    static func readMarker(_ url: URL, kind: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["format"] as? String == markerFormat, marker["kind"] as? String == kind
        else { return nil }
        return marker
    }

    /// Size, inode and mtime as recorded (rule 4 in `ipsw_cache_entry.py`).
    static func markerMatchesFile(_ marker: [String: Any], info: stat) -> Bool {
        let file = marker["file"] as? [String: Any]
        return (marker["size"] as? NSNumber)?.int64Value == Int64(info.st_size)
            && (file?["inode"] as? NSNumber)?.uint64Value == UInt64(info.st_ino)
            && (file?["mtime_ns"] as? NSNumber)?.int64Value == mtimeNanoseconds(info)
    }

    private static func sameJSON(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return (lhs as AnyObject).isEqual(rhs)
    }

    private static func describeSource(_ source: Any?) -> String {
        guard let source = source as? [String: Any] else { return "an unknown source" }
        if let url = source["url"] as? String { return url }
        if let path = source["path"] as? String { return path }
        return "an unknown source"
    }
}

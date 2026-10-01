import CryptoKit
import Darwin
import Foundation
import VPhoneArchiveKit

/// Resolves a local IPSW or downloads one into a shared, content-identified
/// cache. Source archives are never rewritten.
///
/// The cache follows the one rule `scripts/ipsw_cache_entry.py` documents and
/// `fw_prepare.sh` applies:
/// - writes go to `.<name>.partial.[<tag>.]<pid>` and are published with
///   `renamex_np(RENAME_EXCL)`; a partial whose pid is gone is removed;
/// - an entry is usable only with its completion marker `.<name>.vphone-complete`,
///   written last under the cache directory lock. The marker names the source
///   URL, the content size and SHA-256, and the published file's inode and
///   mtime;
/// - an entry without a marker, with another source, or changed since the
///   marker was written is removed and downloaded again. Nothing is reused by
///   its file name alone;
/// - `vphone-cli fw cache adopt` writes the same marker for an existing entry
///   when a user runs it (VPhoneIPSWCacheAdoption.swift), flagged `adopted`.
///
/// Downloads stream chunk by chunk into the partial file (upstream cb924c91).
/// A transfer that fails part way resumes with `Range` and `If-Range` when the
/// server gave a strong ETag or a Last-Modified date and the full length;
/// otherwise the next attempt starts over. Cancelling the task stops the
/// transfer and removes the partial.
public enum VPhoneIPSWCache {
    public struct Archive: Sendable, Codable {
        public let file: URL
        public let version: String
        public let build: String
        /// `SupportedProductTypes`, such as `iPhone17,3`.
        public let productTypes: [String]
        /// Every build identity's `Info.DeviceClass`, such as `vresearch101ap`.
        public let deviceClasses: Set<String>
    }

    public enum Error: Swift.Error, LocalizedError {
        case unsupportedSource(String)
        case missingFile(URL)
        case invalidManifest(URL)
        case unexpectedHTTP(URL, Int)
        case incompleteDownload(URL, expected: Int64, actual: Int64)
        case downloadFailed(URL, attempts: Int, reason: String, retryable: Bool)
        case swappedSources(iPhone: URL, cloudOS: URL)
        case notIPhoneSource(URL, productTypes: [String])
        case notCloudOSSource(URL)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedSource(source): "Unsupported IPSW source: \(source). Use a local file path or an HTTP(S) URL."
            case let .missingFile(file): "IPSW not found at \(file.path). Check the path and try again."
            case let .invalidManifest(file): "\(file.path) is not a valid IPSW. Choose a different file."
            case let .unexpectedHTTP(url, status): "Unable to download the IPSW from \(url) (HTTP \(status)). Try again later."
            case let .incompleteDownload(url, expected, actual):
                "The IPSW download from \(url) is incomplete (\(actual) of \(expected) bytes). Try again."
            case let .downloadFailed(url, attempts, reason, retryable):
                "Unable to download the IPSW from \(url) after \(attempts) attempt\(attempts == 1 ? "" : "s"): \(reason)."
                    + (retryable ? " Try again later." : "")
            case let .swappedSources(iPhone, cloudOS):
                "The iPhone and cloudOS IPSWs are swapped: \(iPhone.lastPathComponent) is a cloudOS IPSW and \(cloudOS.lastPathComponent) is an iPhone IPSW. Swap the two sources, then try again."
            case let .notIPhoneSource(file, productTypes):
                "\(file.lastPathComponent) is not an \(VPhoneIPSWCache.iPhoneProductType) IPSW; it is for \(productTypes.isEmpty ? "no listed product" : productTypes.joined(separator: ", ")). Choose an \(VPhoneIPSWCache.iPhoneProductType) IPSW as the iPhone source."
            case let .notCloudOSSource(file):
                "\(file.lastPathComponent) is not a cloudOS IPSW: it has no \(VPhoneIPSWCache.cloudOSDeviceClass) build identity. Choose a cloudOS IPSW as the cloudOS source."
            }
        }

        /// Whether running the same request again later can succeed: network
        /// failures, server-side HTTP errors and short bodies. Wrong or damaged
        /// content and client-side HTTP errors are not retryable.
        public var isRetryable: Bool {
            switch self {
            case let .unexpectedHTTP(_, status): VPhoneIPSWCache.isRetryableStatus(status)
            case .incompleteDownload: true
            case let .downloadFailed(_, _, _, retryable): retryable
            default: false
            }
        }
    }

    public struct DownloadPolicy: Sendable {
        /// Requests per resolve, counting the first one.
        public var maximumAttempts: Int
        /// Waited before attempt n+1, multiplied by n.
        public var retryDelay: Duration
        public var requestTimeout: TimeInterval

        public init(maximumAttempts: Int = 5, retryDelay: Duration = .seconds(2), requestTimeout: TimeInterval = 60) {
            self.maximumAttempts = max(1, maximumAttempts)
            self.retryDelay = retryDelay
            self.requestTimeout = requestTimeout
        }
    }

    public static func resolve(
        _ source: String,
        in cacheDirectory: URL,
        session: URLSession = URLSession(configuration: .ephemeral),
        policy: DownloadPolicy = DownloadPolicy(),
    ) async throws -> Archive {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            return try inspect(URL(fileURLWithPath: source))
        }
        if scheme == "file" {
            return try inspect(url)
        }
        guard scheme == "http" || scheme == "https" else {
            throw Error.unsupportedSource(source)
        }

        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let cache = cacheDirectory.appendingPathComponent(cacheName(for: url))
        try requireRegularCachePath(cache)
        removeAbandonedPartials(of: cache)
        if let valid = usableEntry(cache, source: url) { return valid }
        // Not usable: removed before downloading, so the volume never needs
        // room for both. A concurrent publisher holds the same lock.
        let published = try VPhoneBundleGuard.withLibraryLock(root: cacheDirectory) { _ -> Archive? in
            try requireRegularCachePath(cache)
            if let valid = usableEntry(cache, source: url) { return valid }
            try removeEntry(cache)
            return nil
        }
        if let published { return published }

        let partial = cacheDirectory.appendingPathComponent(
            ".\(cache.lastPathComponent).partial.\(UUID().uuidString.prefix(8).lowercased()).\(getpid())")
        let fd = open(partial.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? output.close()
            unlink(partial.path)
        }
        let transfer = try await download(url, into: output, session: session, policy: policy)
        try output.synchronize()
        try Task.checkCancellation()
        let metadata = try inspect(partial)

        return try VPhoneBundleGuard.withLibraryLock(root: cacheDirectory) { _ in
            try Task.checkCancellation()
            try requireRegularCachePath(cache)
            // A concurrent download of the same source wins; this one is dropped.
            if let winner = usableEntry(cache, source: url) { return winner }
            try removeEntry(cache)
            guard renamex_np(partial.path, cache.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try writeMarker(for: cache, source: url, size: transfer.size, sha256: transfer.sha256)
            return Archive(file: cache, version: metadata.version, build: metadata.build,
                           productTypes: metadata.productTypes, deviceClasses: metadata.deviceClasses)
        }
    }

    private static func requireRegularCachePath(_ file: URL) throws {
        var info = stat()
        if lstat(file.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw Error.invalidManifest(file) }
        } else if errno != ENOENT {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    public static func inspect(_ file: URL) throws -> Archive {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Error.missingFile(file)
        }
        guard let data = try? VPhoneArchiveReader.readMember("BuildManifest.plist", from: file, maximumBytes: 32 << 20),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
              let version = plist["ProductVersion"] as? String, !version.isEmpty,
              let build = plist["ProductBuildVersion"] as? String, !build.isEmpty
        else {
            throw Error.invalidManifest(file)
        }
        let identities = plist["BuildIdentities"] as? [[String: Any]] ?? []
        let deviceClasses = identities.compactMap { identity in
            ((identity["Info"] as? [String: Any])?["DeviceClass"] as? String)?.lowercased()
        }
        return Archive(
            file: file,
            version: version,
            build: build,
            productTypes: plist["SupportedProductTypes"] as? [String] ?? [],
            deviceClasses: Set(deviceClasses),
        )
    }

    // MARK: - Completion marker

    /// Shared with `scripts/ipsw_cache_entry.py` (`MARKER_FORMAT`).
    static let markerFormat = "vphone-ipsw-cache/1"

    static func markerURL(for entry: URL) -> URL {
        entry.deletingLastPathComponent().appendingPathComponent(".\(entry.lastPathComponent).vphone-complete")
    }

    /// Why `entry` is not a usable cache entry for `source`, or nil when it is.
    static func entryProblem(_ entry: URL, source: URL) -> String? {
        var info = stat()
        guard lstat(entry.path, &info) == 0 else { return "absent" }
        guard info.st_mode & S_IFMT == S_IFREG else { return "not a regular file" }
        guard let data = FileManager.default.contents(atPath: markerURL(for: entry).path),
              let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              marker["format"] as? String == markerFormat, marker["kind"] as? String == "file"
        else { return "no completion marker" }
        guard let recorded = marker["source"] as? [String: Any], recorded.count == 1,
              recorded["url"] as? String == source.absoluteString
        else { return "completion marker names another source" }
        let file = marker["file"] as? [String: Any]
        guard (marker["size"] as? NSNumber)?.int64Value == Int64(info.st_size),
              (file?["inode"] as? NSNumber)?.uint64Value == UInt64(info.st_ino),
              (file?["mtime_ns"] as? NSNumber)?.int64Value == mtimeNanoseconds(info)
        else { return "file changed after its completion marker was written" }
        guard let digest = marker["sha256"] as? String, digest.count == 64 else {
            return "completion marker has no content digest"
        }
        return nil
    }

    private static func usableEntry(_ entry: URL, source: URL) -> Archive? {
        guard entryProblem(entry, source: source) == nil else { return nil }
        return try? inspect(entry)
    }

    private static func removeEntry(_ entry: URL) throws {
        for path in [entry.path, markerURL(for: entry).path] {
            guard unlink(path) == 0 || errno == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private static func writeMarker(for entry: URL, source: URL, size: Int64, sha256: String) throws {
        var info = stat()
        guard lstat(entry.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let marker: [String: Any] = [
            "format": markerFormat, "kind": "file",
            "source": ["url": source.absoluteString],
            "size": size, "sha256": sha256,
            "file": ["inode": UInt64(info.st_ino), "mtime_ns": mtimeNanoseconds(info)],
        ]
        try writeMarkerJSON(marker, to: markerURL(for: entry))
    }

    /// Writes a marker to a temporary name next to `destination`, syncs it and
    /// renames it into place. The caller holds the cache directory lock.
    static func writeMarkerJSON(_ marker: [String: Any], to destination: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent("\(destination.lastPathComponent).partial.\(getpid())")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data + Data("\n".utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(temporary.path)
            throw error
        }
        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    static func mtimeNanoseconds(_ info: stat) -> Int64 {
        Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    /// `.<name>.partial.[<tag>.]<pid>[.aria2]` whose pid no longer exists.
    static func removeAbandonedPartials(of entry: URL) {
        let directory = entry.deletingLastPathComponent()
        let prefix = ".\(entry.lastPathComponent).partial."
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            var components = name.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
            if components.last == "aria2" { components.removeLast() }
            guard let last = components.last, let pid = pid_t(last), pid > 0 else { continue }
            if kill(pid, 0) == 0 || errno == EPERM { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Download

    struct Transfer {
        var size: Int64
        var sha256: String
    }

    static func isRetryableStatus(_ status: Int) -> Bool {
        status >= 500 || status == 408 || status == 429
    }

    private static let retryableURLErrors: Set<URLError.Code> = [
        .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
        .cannotLoadFromNetwork, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        .backgroundSessionWasDisconnected, .secureConnectionFailed, .badServerResponse,
    ]

    private static func download(
        _ url: URL,
        into output: FileHandle,
        session: URLSession,
        policy: DownloadPolicy,
    ) async throws -> Transfer {
        let state = DownloadState(output: output)
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = policy.requestTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let offset = state.resumeOffset, let validator = state.validator {
                request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            } else {
                try state.restart()
            }

            let reason: String
            switch try await state.run(request, session: session) {
            case .finished:
                guard let total = state.total else {
                    return Transfer(size: state.written, sha256: state.digest())
                }
                if state.written == total {
                    return Transfer(size: state.written, sha256: state.digest())
                }
                if state.written > total { state.discardProgress() }
                reason = "body ended at \(state.written) of \(total) bytes"
            case let .status(code):
                guard isRetryableStatus(code) else { throw Error.unexpectedHTTP(url, code) }
                reason = "HTTP \(code)"
            case let .rangeRejected(detail):
                state.discardProgress()
                reason = detail
            case let .transport(error):
                guard retryableURLErrors.contains(error.code) else {
                    throw Error.downloadFailed(url, attempts: attempt, reason: error.localizedDescription, retryable: false)
                }
                if state.total == nil { state.discardProgress() }
                reason = error.localizedDescription
            }
            guard attempt < policy.maximumAttempts else {
                if let total = state.total, state.written > 0, state.written < total {
                    throw Error.incompleteDownload(url, expected: total, actual: state.written)
                }
                throw Error.downloadFailed(url, attempts: attempt, reason: reason, retryable: true)
            }
            try await Task.sleep(for: policy.retryDelay * attempt)
        }
    }

    /// One transfer across attempts: the partial file's length, the running
    /// SHA-256 of what it holds, and what the server said about the entity.
    /// Attempts run one after another, and URLSession calls a task's delegate
    /// serially, so the mutable state is never touched concurrently.
    private final class DownloadState: @unchecked Sendable {
        enum Outcome {
            case finished
            case status(Int)
            case rangeRejected(String)
            case transport(URLError)
        }

        let output: FileHandle
        private(set) var written: Int64 = 0
        private(set) var total: Int64?
        private(set) var validator: String?
        private var hasher = SHA256()

        init(output: FileHandle) {
            self.output = output
        }

        /// Where the next request continues, when continuing is safe.
        var resumeOffset: Int64? {
            guard written > 0, let total, written < total, validator != nil else { return nil }
            return written
        }

        func restart() throws {
            try output.truncate(atOffset: 0)
            written = 0
            hasher = SHA256()
        }

        /// The next attempt starts from byte 0 with a fresh entity.
        func discardProgress() {
            total = nil
            validator = nil
        }

        func digest() -> String {
            hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        func run(_ request: URLRequest, session: URLSession) async throws -> Outcome {
            let task = session.dataTask(with: request)
            let attempt = Attempt(state: self, ranged: request.value(forHTTPHeaderField: "Range") != nil)
            task.delegate = attempt
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    attempt.continuation = continuation
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }

        /// Decides on the response before any body byte is written.
        fileprivate func accept(_ response: HTTPURLResponse, ranged: Bool) -> Outcome? {
            switch response.statusCode {
            case 200:
                // The full entity: a first request, a server without ranges, or
                // an If-Range validator that no longer matches.
                if written > 0 {
                    do { try restart() } catch { return .rangeRejected("cannot restart: \(error)") }
                }
                total = response.expectedContentLength > 0 ? response.expectedContentLength : nil
                validator = Self.validator(of: response)
                return nil
            case 206 where ranged:
                guard let range = Self.contentRange(response),
                      range.start == written, total == nil || range.total == total
                else {
                    return .rangeRejected("server returned a different range (\(response.value(forHTTPHeaderField: "Content-Range") ?? "none"))")
                }
                return nil
            case 416 where ranged:
                return .rangeRejected("server refused the range")
            default:
                return .status(response.statusCode)
            }
        }

        fileprivate func append(_ data: Data) throws {
            try output.write(contentsOf: data)
            hasher.update(data: data)
            written += Int64(data.count)
        }

        /// A strong ETag, else Last-Modified. Weak ETags cannot be used with If-Range.
        private static func validator(of response: HTTPURLResponse) -> String? {
            if let tag = response.value(forHTTPHeaderField: "ETag"), !tag.hasPrefix("W/"), !tag.isEmpty {
                return tag
            }
            return response.value(forHTTPHeaderField: "Last-Modified")
        }

        /// `bytes start-end/total`.
        private static func contentRange(_ response: HTTPURLResponse) -> (start: Int64, total: Int64)? {
            guard let value = response.value(forHTTPHeaderField: "Content-Range"), value.hasPrefix("bytes ") else {
                return nil
            }
            let parts = value.dropFirst(6).split(separator: "/")
            guard parts.count == 2, let start = parts[0].split(separator: "-").first.flatMap({ Int64($0) }),
                  let total = Int64(parts[1])
            else { return nil }
            return (start, total)
        }
    }

    private final class Attempt: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let state: DownloadState
        let ranged: Bool
        var continuation: CheckedContinuation<DownloadState.Outcome, Swift.Error>?
        private var rejected: DownloadState.Outcome?
        private var writeError: Swift.Error?

        init(state: DownloadState, ranged: Bool) {
            self.state = state
            self.ranged = ranged
        }

        func urlSession(
            _: URLSession,
            dataTask _: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void,
        ) {
            guard let http = response as? HTTPURLResponse else {
                rejected = .status(0)
                completionHandler(.cancel)
                return
            }
            rejected = state.accept(http, ranged: ranged)
            completionHandler(rejected == nil ? .allow : .cancel)
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard writeError == nil else { return }
            do {
                try state.append(data)
            } catch {
                writeError = error
                dataTask.cancel()
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Swift.Error?) {
            defer { continuation = nil }
            if let writeError {
                continuation?.resume(throwing: writeError)
            } else if let rejected {
                continuation?.resume(returning: rejected)
            } else if let error = error as? URLError {
                if error.code == .cancelled {
                    continuation?.resume(throwing: CancellationError())
                } else {
                    continuation?.resume(returning: .transport(error))
                }
            } else if let error {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume(returning: .finished)
            }
        }
    }

    // MARK: - Pairing

    /// The iPhone IPSW's product, and the cloudOS device class whose boot
    /// chain matches the VM's DFU hardware. The restore tree needs both.
    public static let iPhoneProductType = VPhoneFirmwareCatalog.device
    public static let cloudOSDeviceClass = "vresearch101ap"

    /// Checks each BuildManifest before anything is extracted, so a swapped
    /// or wrong IPSW fails at once with the fix instead of deep in the merge.
    public static func checkPair(iPhone: Archive, cloudOS: Archive) throws {
        let iPhoneIsPhone = iPhone.productTypes.contains(iPhoneProductType)
        let cloudOSIsCloudOS = cloudOS.deviceClasses.contains(cloudOSDeviceClass)
        if !iPhoneIsPhone, !cloudOSIsCloudOS,
           iPhone.deviceClasses.contains(cloudOSDeviceClass),
           cloudOS.productTypes.contains(iPhoneProductType)
        {
            throw Error.swappedSources(iPhone: iPhone.file, cloudOS: cloudOS.file)
        }
        guard iPhoneIsPhone else {
            throw Error.notIPhoneSource(iPhone.file, productTypes: iPhone.productTypes)
        }
        guard cloudOSIsCloudOS else {
            throw Error.notCloudOSSource(cloudOS.file)
        }
    }

    static func cacheName(for url: URL) -> String {
        let base = url.lastPathComponent
        let stem = base.lowercased().hasSuffix(".ipsw") ? String(base.dropLast(5)) : base
        let safe = String(stem.prefix(48).unicodeScalars.map { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57) || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122) || value == 45 || value == 46 || value == 95
                ? Character(scalar) : "_"
        })
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(safe.isEmpty ? "firmware" : safe)-\(suffix).ipsw"
    }
}

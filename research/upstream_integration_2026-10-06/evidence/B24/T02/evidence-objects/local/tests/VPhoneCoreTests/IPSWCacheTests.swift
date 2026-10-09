import CryptoKit
import Darwin
import Foundation
import Testing
import VPhoneArchiveKit
@testable import VPhoneCore

/// Downloads go to `LocalIPSWServer` on 127.0.0.1; no test reaches the network.
@Suite("IPSW cache", .serialized)
struct IPSWCacheTests {
    private static let policy = VPhoneIPSWCache.DownloadPolicy(maximumAttempts: 3, retryDelay: .zero, requestTimeout: 10)

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ipsw-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// An archive with a BuildManifest and `padding` bytes of other content,
    /// so a transfer spans many chunks.
    private func fixture(in root: URL, name: String = "input", build: String = "23G90", padding: Int = 0) throws -> URL {
        let files = root.appendingPathComponent("files-\(name)")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["ProductVersion": "26.6.2", "ProductBuildVersion": build]
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try data.write(to: files.appendingPathComponent("BuildManifest.plist"))
        if padding > 0 {
            var generator = SystemRandomNumberGenerator()
            try Data((0 ..< padding).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
                .write(to: files.appendingPathComponent("payload.bin"))
        }
        let archive = root.appendingPathComponent("\(name).ipsw")
        try VPhoneArchiveWriter.create(archive: archive, from: files)
        return archive
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }

    private func names(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func marker(_ entry: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: VPhoneIPSWCache.markerURL(for: entry))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func resolve(_ server: LocalIPSWServer, in cache: URL, _ session: URLSession,
                         policy: VPhoneIPSWCache.DownloadPolicy = Self.policy) async throws -> VPhoneIPSWCache.Archive {
        try await VPhoneIPSWCache.resolve(server.url.absoluteString, in: cache, session: session, policy: policy)
    }

    // MARK: - Local sources

    @Test func `local source reads manifest without copying`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        let result = try await VPhoneIPSWCache.resolve(source.path, in: root.appendingPathComponent("cache"))
        #expect(result.file == source)
        #expect(result.version == "26.6.2")
        #expect(result.build == "23G90")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cache").path))
    }

    // MARK: - Identity

    @Test func `chunked download publishes the entry with a content marker`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try Data(contentsOf: fixture(in: root, padding: 3 << 20))
        let server = try LocalIPSWServer(payload: payload)
        defer { server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("cache")

        let result = try await resolve(server, in: cache, session)
        let entry = cache.appendingPathComponent(VPhoneIPSWCache.cacheName(for: server.url))
        #expect(result.file == entry)
        #expect(result.build == "23G90")
        #expect(try Data(contentsOf: entry) == payload)
        #expect(try names(cache) == [VPhoneIPSWCache.markerURL(for: entry).lastPathComponent, entry.lastPathComponent].sorted())
        let recorded = try marker(entry)
        #expect(recorded["format"] as? String == "vphone-ipsw-cache/1")
        #expect(recorded["kind"] as? String == "file")
        #expect(recorded["source"] as? [String: String] == ["url": server.url.absoluteString])
        #expect((recorded["size"] as? NSNumber)?.intValue == payload.count)
        #expect(recorded["sha256"] as? String == sha256(payload))
        var info = stat()
        try #require(lstat(entry.path, &info) == 0)
        #expect(((recorded["file"] as? [String: Any])?["inode"] as? NSNumber)?.uint64Value == UInt64(info.st_ino))
        #expect(info.st_mode & 0o777 == 0o600)
        var directory = stat()
        try #require(lstat(cache.path, &directory) == 0)
        #expect(directory.st_mode & 0o777 == 0o700)

        // The same URL again: identified by its marker, no request.
        let again = try await resolve(server, in: cache, session)
        #expect(again.file == entry)
        #expect(server.requests.count == 1)
    }

    @Test(arguments: ["no-marker", "other-source", "modified-after-marker", "marker-from-before-t14"])
    func entryThatCannotBeIdentifiedIsDownloadedAgain(kind: String) async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try Data(contentsOf: fixture(in: root))
        let server = try LocalIPSWServer(payload: payload)
        defer { server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("cache")
        let entry = cache.appendingPathComponent(VPhoneIPSWCache.cacheName(for: server.url))
        let markerURL = VPhoneIPSWCache.markerURL(for: entry)

        switch kind {
        case "no-marker":
            // What every cache before T14 holds: a readable IPSW under its name.
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data(contentsOf: fixture(in: root, name: "stale", build: "STALE1")).write(to: entry)
        case "other-source":
            _ = try await resolve(server, in: cache, session)
            var recorded = try marker(entry)
            recorded["source"] = ["url": "https://example.invalid/other.ipsw"]
            try JSONSerialization.data(withJSONObject: recorded).write(to: markerURL)
        case "modified-after-marker":
            _ = try await resolve(server, in: cache, session)
            let handle = try FileHandle(forWritingTo: entry)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("appended".utf8))
            try handle.close()
        default:
            _ = try await resolve(server, in: cache, session)
            try Data().write(to: markerURL)
        }
        let before = server.requests.count
        #expect(VPhoneIPSWCache.entryProblem(entry, source: server.url) != nil)

        let result = try await resolve(server, in: cache, session)
        #expect(server.requests.count == before + 1)
        #expect(result.build == "23G90")
        #expect(try Data(contentsOf: entry) == payload)
        #expect(VPhoneIPSWCache.entryProblem(entry, source: server.url) == nil)
    }

    @Test func `marker is the same rule the fw_prepare helper applies`() async throws {
        let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/ipsw_cache_entry.py").standardizedFileURL
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: helper.path) else { return }
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LocalIPSWServer(payload: Data(contentsOf: fixture(in: root)))
        defer { server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("cache")
        let result = try await resolve(server, in: cache, session)

        let check = { (source: String) throws -> Int32 in
            try VPhoneProcessRunner.runCapturing(python, ["-B", helper.path, "check", result.file.path, "--source", source], timeout: 30).exitCode
        }
        #expect(try check(server.url.absoluteString) == 0)
        #expect(try check("https://example.invalid/other.ipsw") == 1)
        let handle = try FileHandle(forWritingTo: result.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        #expect(try check(server.url.absoluteString) == 1)
    }

    // MARK: - Resume and retry

    @Test func `dropped transfer resumes with Range and If-Range`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try Data(contentsOf: fixture(in: root, padding: 2 << 20))
        let server = try LocalIPSWServer(payload: payload, faults: [.drop(after: 700_000)])
        defer { server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("cache")

        let result = try await resolve(server, in: cache, session)
        #expect(try Data(contentsOf: result.file) == payload)
        let requests = server.requests
        try #require(requests.count == 2)
        #expect(requests[0].range == nil)
        let resumed = try #require(requests[1].range)
        let offset = try #require(Int(resumed.dropFirst("bytes=".count).dropLast()))
        #expect(offset > 0 && offset <= 700_000)
        #expect(requests[1].ifRange == server.etag)
        #expect(requests[1].status == 206)
        #expect(try marker(result.file)["sha256"] as? String == sha256(payload))
    }

    @Test func `a changed entity or a server without ranges restarts from byte zero`() async throws {
        for ranges in [true, false] {
            let root = try scratch()
            defer { try? FileManager.default.removeItem(at: root) }
            let first = try Data(contentsOf: fixture(in: root, name: "first", padding: 1 << 20))
            let second = try Data(contentsOf: fixture(in: root, name: "second", build: "23G91", padding: 1 << 20))
            // With ranges, the entity is published again between the attempts,
            // so If-Range no longer matches; without, the Range is ignored.
            let fault: LocalIPSWServer.Fault = ranges ? .dropThenReplace(after: 300_000, payload: second) : .drop(after: 300_000)
            let server = try LocalIPSWServer(payload: first, faults: [fault], ranges: ranges)
            defer { server.stop() }
            let session = session()
            defer { session.invalidateAndCancel() }
            let cache = root.appendingPathComponent("cache")
            let result = try await resolve(server, in: cache, session)
            let expected = ranges ? second : first
            #expect(try Data(contentsOf: result.file) == expected)
            #expect(try marker(result.file)["sha256"] as? String == sha256(expected))
            #expect(server.requests.count == 2)
            #expect(server.requests.last?.range != nil)
            #expect(server.requests.last?.status == 200)
        }
    }

    @Test func `server errors are retried and end in a retryable result`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LocalIPSWServer(payload: Data(), faults: Array(repeating: .status(503), count: 10))
        defer { server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("cache")
        do {
            _ = try await resolve(server, in: cache, session)
            Issue.record("expected an error")
        } catch let error as VPhoneIPSWCache.Error {
            #expect(error.isRetryable)
            guard case let .downloadFailed(_, attempts, reason, _) = error else {
                Issue.record("unexpected \(error)"); return
            }
            #expect(attempts == 3)
            #expect(reason == "HTTP 503")
        }
        #expect(server.requests.count == 3)
        #expect(try names(cache) == [])
    }

    @Test func `a client error is final`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LocalIPSWServer(payload: Data(), faults: Array(repeating: .status(404), count: 10))
        defer { server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("cache")
        do {
            _ = try await resolve(server, in: cache, session)
            Issue.record("expected an error")
        } catch let error as VPhoneIPSWCache.Error {
            #expect(!error.isRetryable)
            guard case .unexpectedHTTP(_, 404) = error else { Issue.record("unexpected \(error)"); return }
        }
        #expect(server.requests.count == 1)
        #expect(try names(cache) == [])
    }

    @Test func `refused connections and short bodies end retryable with nothing published`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = session()
        defer { session.invalidateAndCancel() }

        let closed = try LocalIPSWServer(payload: Data())
        closed.stop()
        let refusedCache = root.appendingPathComponent("refused")
        do {
            _ = try await resolve(closed, in: refusedCache, session)
            Issue.record("expected an error")
        } catch let error as VPhoneIPSWCache.Error {
            #expect(error.isRetryable, "\(error)")
        }
        #expect(try names(refusedCache) == [])

        let payload = try Data(contentsOf: fixture(in: root, padding: 1 << 20))
        let server = try LocalIPSWServer(payload: payload, faults: Array(repeating: .drop(after: 1000), count: 10), ranges: false)
        defer { server.stop() }
        let shortCache = root.appendingPathComponent("short")
        do {
            _ = try await resolve(server, in: shortCache, session)
            Issue.record("expected an error")
        } catch let error as VPhoneIPSWCache.Error {
            #expect(error.isRetryable, "\(error)")
        }
        #expect(server.requests.count == 3)
        #expect(try names(shortCache) == [])
    }

    @Test func `content that is not an IPSW is not published`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LocalIPSWServer(payload: Data("not an archive".utf8))
        defer { server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("cache")
        await #expect(throws: VPhoneIPSWCache.Error.self) {
            _ = try await resolve(server, in: cache, session)
        }
        #expect(try names(cache) == [])
    }

    // MARK: - Cancellation, concurrency, leftovers

    @Test func `cancelling a transfer stops it and removes the partial`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try Data(contentsOf: fixture(in: root, padding: 1 << 20))
        let server = try LocalIPSWServer(payload: payload, faults: [.slow])
        defer { server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("cache")
        let url = server.url.absoluteString
        let task = Task { try await VPhoneIPSWCache.resolve(url, in: cache, session: session, policy: Self.policy) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let partial = (try? names(cache))?.first { $0.contains(".partial.") }
            if let partial,
               let size = try? FileManager.default.attributesOfItem(atPath: cache.appendingPathComponent(partial).path)[.size] as? NSNumber,
               size.intValue > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try names(cache) == [])
        #expect(server.requests.count == 1)
    }

    @Test func `cancelled before starting and a symlinked entry publish nothing`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "http://127.0.0.1:9/input.ipsw")!
        let entry = root.appendingPathComponent(VPhoneIPSWCache.cacheName(for: url))
        try FileManager.default.createSymbolicLink(atPath: entry.path, withDestinationPath: "missing")
        await #expect(throws: VPhoneIPSWCache.Error.self) {
            try await VPhoneIPSWCache.resolve(url.absoluteString, in: root)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: entry.path) == "missing")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VPhoneIPSWCache.resolve(url.absoluteString, in: root.appendingPathComponent("cancelled"))
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled").path))
    }

    @Test func `concurrent downloads publish one entry`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = try Data(contentsOf: fixture(in: root, padding: 1 << 20))
        let server = try LocalIPSWServer(payload: payload)
        defer { server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = server.url.absoluteString
        async let first = VPhoneIPSWCache.resolve(url, in: cache, session: session, policy: Self.policy)
        async let second = VPhoneIPSWCache.resolve(url, in: cache, session: session, policy: Self.policy)
        let (a, b) = try await (first, second)
        #expect(a.file == b.file)
        #expect(try Data(contentsOf: a.file) == payload)
        #expect(try names(cache) == [VPhoneIPSWCache.markerURL(for: a.file).lastPathComponent, a.file.lastPathComponent].sorted())
        #expect(VPhoneIPSWCache.entryProblem(a.file, source: server.url) == nil)
    }

    @Test func `partials of ended processes are removed and live ones kept`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LocalIPSWServer(payload: Data(contentsOf: fixture(in: root)))
        defer { server.stop() }
        let session = session()
        defer { session.invalidateAndCancel() }
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let name = VPhoneIPSWCache.cacheName(for: server.url)
        let abandoned = [".\(name).partial.\(ended.processIdentifier)", ".\(name).partial.abc123.\(ended.processIdentifier)",
                         ".\(name).partial.\(ended.processIdentifier).aria2"]
        let live = ".\(name).partial.def456.\(getpid())"
        for item in abandoned + [live] {
            try Data("partial".utf8).write(to: cache.appendingPathComponent(item))
        }
        _ = try await resolve(server, in: cache, session)
        let remaining = try names(cache)
        for item in abandoned { #expect(!remaining.contains(item)) }
        #expect(remaining.contains(live))
    }

    @Test func boundedMemberReadAndUnsupportedSourceAreRejected() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try fixture(in: root)
        #expect(throws: VPhoneArchiveError.self) {
            try VPhoneArchiveReader.readMember("BuildManifest.plist", from: source, maximumBytes: 1)
        }
        await #expect(throws: VPhoneIPSWCache.Error.self) {
            try await VPhoneIPSWCache.resolve("ftp://example.invalid/firmware.ipsw", in: root)
        }
        let result = try await VPhoneIPSWCache.resolve(source.absoluteString, in: root)
        #expect(result.build == "23G90")
    }

    // MARK: - Pairing

    @Test func zipIPSWIsInspectedWithoutExtractionOrSourceChanges() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try fixture(in: root)
        let archive = root.appendingPathComponent("zipped.ipsw")
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/zip"),
            ["-q", archive.path, "BuildManifest.plist"], cwd: root.appendingPathComponent("files-input"))
        try #require(result.succeeded)
        let before = try Data(contentsOf: archive)
        let metadata = try VPhoneIPSWCache.inspect(archive)
        #expect(metadata.version == "26.6.2")
        #expect(try Data(contentsOf: archive) == before)
    }

    private func ipsw(in root: URL, _ name: String, productTypes: [String], deviceClasses: [String]) throws -> VPhoneIPSWCache.Archive {
        let files = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "ProductVersion": "27.0", "ProductBuildVersion": "24A435",
            "SupportedProductTypes": productTypes,
            "BuildIdentities": deviceClasses.map { ["Info": ["DeviceClass": $0]] },
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
        try data.write(to: files.appendingPathComponent("BuildManifest.plist"))
        let archive = root.appendingPathComponent("\(name).ipsw")
        try VPhoneArchiveWriter.create(archive: archive, from: files)
        return try VPhoneIPSWCache.inspect(archive)
    }

    @Test func `pair check reads each manifest and names the mistake`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = try ipsw(in: root, "phone", productTypes: ["iPhone17,3"], deviceClasses: ["D47AP", "D47AP"])
        let cloud = try ipsw(in: root, "cloud", productTypes: ["iProd99,1"], deviceClasses: ["vresearch101ap", "vphone600ap"])
        let other = try ipsw(in: root, "other", productTypes: ["iPhone16,1"], deviceClasses: ["d83ap"])

        #expect(phone.productTypes == ["iPhone17,3"])
        #expect(phone.deviceClasses == ["d47ap"])
        #expect(cloud.deviceClasses == ["vresearch101ap", "vphone600ap"])

        try VPhoneIPSWCache.checkPair(iPhone: phone, cloudOS: cloud)
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: cloud, cloudOS: phone)
        } throws: { error in
            if case .swappedSources? = error as? VPhoneIPSWCache.Error { true } else { false }
        }
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: other, cloudOS: cloud)
        } throws: { error in
            if case .notIPhoneSource? = error as? VPhoneIPSWCache.Error { true } else { false }
        }
        #expect {
            try VPhoneIPSWCache.checkPair(iPhone: phone, cloudOS: phone)
        } throws: { error in
            if case .notCloudOSSource? = error as? VPhoneIPSWCache.Error { true } else { false }
        }
    }
}

import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VPhoneCore

/// `vphone-cli fw cache adopt` / `fw cache list` on synthetic caches in a
/// temporary directory. No test reads ~/.vphone or reaches the network; the
/// one download check uses `LocalIPSWServer` on 127.0.0.1.
@Suite("IPSW cache adoption", .serialized)
struct IPSWCacheAdoptionTests {
    private static let localURL = "http://127.0.0.1:9/iPhone17,3_26.1_23B85_Restore.ipsw"

    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ipsw-adopt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
        return URL(fileURLWithPath: VPhoneIPSWCache.realPath(root.path)!, isDirectory: true)
    }

    /// A zip IPSW with a BuildManifest and one firmware member, written to `destination`.
    @discardableResult
    private func zipIPSW(at destination: URL, version: String = "26.1", build: String = "23B85",
                         products: [String] = ["iPhone17,3"], payload: String = "iboot") throws -> Data {
        let files = destination.deletingLastPathComponent().appendingPathComponent(".files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: files.appendingPathComponent("Firmware/all_flash"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: files) }
        let manifest: [String: Any] = [
            "ProductVersion": version, "ProductBuildVersion": build, "SupportedProductTypes": products,
            "BuildIdentities": [["Info": ["DeviceClass": "d47ap"]]],
        ]
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
            .write(to: files.appendingPathComponent("BuildManifest.plist"))
        try Data(String(repeating: payload, count: 4096).utf8).write(to: files.appendingPathComponent("Firmware/all_flash/iBoot.im4p"))
        let result = try VPhoneProcessRunner.runCapturing(
            URL(fileURLWithPath: "/usr/bin/zip"), ["-qr", destination.path, "."], cwd: files)
        try #require(result.succeeded)
        return try Data(contentsOf: destination)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func marker(_ entry: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: VPhoneIPSWCache.markerURL(for: entry))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func names(_ directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func adoptionError(_ body: () throws -> Void) -> VPhoneIPSWCache.AdoptionError? {
        do {
            try body()
            return nil
        } catch {
            return error as? VPhoneIPSWCache.AdoptionError
        }
    }

    /// Runs `scripts/ipsw_cache_entry.py`, the helper fw_prepare.sh uses.
    private func helper(_ arguments: [String]) throws -> VPhoneProcessResult? {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../scripts/ipsw_cache_entry.py").standardizedFileURL
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path) else { return nil }
        return try VPhoneProcessRunner.runCapturing(python, ["-B", script.path] + arguments, timeout: 30)
    }

    // MARK: - Files

    @Test func `adopting a file writes the download marker with adoption fields`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let entry = cache.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        let payload = try zipIPSW(at: entry)
        var reports: [(Int64, Int64)] = []

        let result = try VPhoneIPSWCache.adopt(entry.path, in: cache, source: Self.localURL,
                                               expectedSHA256: sha256(payload).uppercased()) { reports.append(($0, $1)) }
        #expect(result.outcome == .adopted)
        #expect(result.adopted)
        #expect(result.sha256 == sha256(payload))
        #expect(result.version == "26.1" && result.build == "23B85")
        #expect(result.checks == ["build-manifest", "file-name-version-build", "expected-sha256"])
        #expect(reports.first?.0 == 0)
        #expect(reports.last.map { $0.0 == Int64(payload.count) && $0.1 == Int64(payload.count) } == true)

        let recorded = try marker(entry)
        #expect(recorded["format"] as? String == "vphone-ipsw-cache/1")
        #expect(recorded["kind"] as? String == "file")
        #expect(recorded["source"] as? [String: String] == ["url": Self.localURL])
        #expect((recorded["size"] as? NSNumber)?.intValue == payload.count)
        #expect(recorded["sha256"] as? String == sha256(payload))
        #expect(recorded["adopted"] as? Bool == true)
        #expect(recorded["source_verified"] as? Bool == false)
        let manifest = try #require(recorded["manifest"] as? [String: Any])
        #expect(manifest["version"] as? String == "26.1")
        #expect(manifest["build"] as? String == "23B85")
        #expect(manifest["product_types"] as? [String] == ["iPhone17,3"])
        var info = stat()
        try #require(lstat(entry.path, &info) == 0)
        #expect(((recorded["file"] as? [String: Any])?["inode"] as? NSNumber)?.uint64Value == UInt64(info.st_ino))
        // Adoption writes only the marker; the entry is not moved or rewritten.
        #expect(try Data(contentsOf: entry) == payload)
        #expect(try names(cache) == [".iPhone17,3_26.1_23B85_Restore.ipsw.vphone-complete", "iPhone17,3_26.1_23B85_Restore.ipsw"])

        // The same rule fw_prepare.sh applies accepts it and reports the adoption.
        #expect(VPhoneIPSWCache.entryProblem(entry, source: URL(string: Self.localURL)!) == nil)
        if let check = try helper(["check", entry.path, "--source", Self.localURL]) {
            #expect(check.exitCode == 0)
            #expect(check.stdout.contains("adopted; source not verified by download"))
        }
    }

    @Test func `adopted entry is used by resolve without a request`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let payload = try zipIPSW(at: root.appendingPathComponent("served.ipsw"))
        let server = try LocalIPSWServer(payload: payload)
        defer { server.stop() }
        let entry = cache.appendingPathComponent(VPhoneIPSWCache.cacheName(for: server.url))
        try payload.write(to: entry)

        _ = try VPhoneIPSWCache.adopt(entry.lastPathComponent, in: cache, source: server.url.absoluteString)
        let archive = try await VPhoneIPSWCache.resolve(server.url.absoluteString, in: cache)
        #expect(archive.file == entry)
        #expect(archive.build == "23B85")
        #expect(server.requests.isEmpty)
    }

    @Test func `repeated adoption leaves the marker unchanged and does not hash again`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let entry = cache.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        let payload = try zipIPSW(at: entry)
        _ = try VPhoneIPSWCache.adopt(entry.path, in: cache, source: Self.localURL)
        let first = try Data(contentsOf: VPhoneIPSWCache.markerURL(for: entry))

        var hashed = false
        let again = try VPhoneIPSWCache.adopt(entry.path, in: cache, source: Self.localURL,
                                              expectedSHA256: sha256(payload)) { _, _ in hashed = true }
        #expect(again.outcome == .alreadyUsable)
        #expect(again.adopted)
        #expect(!hashed)
        #expect(try Data(contentsOf: VPhoneIPSWCache.markerURL(for: entry)) == first)

        // A different expected digest is still refused.
        let error = adoptionError {
            _ = try VPhoneIPSWCache.adopt(entry.path, in: cache, source: Self.localURL,
                                          expectedSHA256: String(repeating: "0", count: 64))
        }
        guard case .digestMismatch? = error else { Issue.record("expected digestMismatch, got \(String(describing: error))"); return }
        #expect(try Data(contentsOf: VPhoneIPSWCache.markerURL(for: entry)) == first)

        // Another URL cached under the same name: the existing marker stays.
        let other = adoptionError {
            _ = try VPhoneIPSWCache.adopt(entry.path, in: cache, source: "http://127.0.0.1:9/other/\(entry.lastPathComponent)")
        }
        guard case .markedForOtherSource? = other else { Issue.record("expected markedForOtherSource, got \(String(describing: other))"); return }
        #expect(try Data(contentsOf: VPhoneIPSWCache.markerURL(for: entry)) == first)
    }

    @Test func `a marker written by a download is kept and reported`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let payload = try zipIPSW(at: root.appendingPathComponent("served.ipsw"))
        let server = try LocalIPSWServer(payload: payload)
        defer { server.stop() }
        let downloaded = try await VPhoneIPSWCache.resolve(server.url.absoluteString, in: cache)
        let before = try Data(contentsOf: VPhoneIPSWCache.markerURL(for: downloaded.file))

        let result = try VPhoneIPSWCache.adopt(downloaded.file.path, in: cache, source: server.url.absoluteString)
        #expect(result.outcome == .alreadyUsable)
        #expect(!result.adopted)
        #expect(try Data(contentsOf: VPhoneIPSWCache.markerURL(for: downloaded.file)) == before)

        // A source that fw prepare would not cache under this name is refused; the marker stays.
        let other = "http://127.0.0.1:9/elsewhere/\(server.url.lastPathComponent)"
        let error = adoptionError { _ = try VPhoneIPSWCache.adopt(downloaded.file.path, in: cache, source: other) }
        guard case .nameMismatch? = error else { Issue.record("expected nameMismatch, got \(String(describing: error))"); return }
        #expect(try Data(contentsOf: VPhoneIPSWCache.markerURL(for: downloaded.file)) == before)
    }

    @Test func `digest mismatch is refused without a marker`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let entry = cache.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        try zipIPSW(at: entry)
        let error = adoptionError {
            _ = try VPhoneIPSWCache.adopt(entry.path, in: cache, source: Self.localURL,
                                          expectedSHA256: String(repeating: "ab", count: 32))
        }
        guard case .digestMismatch? = error else { Issue.record("expected digestMismatch, got \(String(describing: error))"); return }
        #expect(!FileManager.default.fileExists(atPath: VPhoneIPSWCache.markerURL(for: entry).path))

        let invalid = adoptionError {
            _ = try VPhoneIPSWCache.adopt(entry.path, in: cache, source: Self.localURL, expectedSHA256: "abc")
        }
        guard case .invalidExpectedDigest? = invalid else { Issue.record("expected invalidExpectedDigest"); return }
    }

    @Test func `digest in a PCC URL must match`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let staging = root.appendingPathComponent("cloud.ipsw")
        let payload = try zipIPSW(at: staging, version: "26.1", build: "23B85", products: ["iProd99,1"])

        let wrong = "https://updates.cdn-apple.invalid/private-cloud-compute/\(String(repeating: "0f", count: 32))"
        let wrongEntry = cache.appendingPathComponent(VPhoneIPSWCache.scriptCacheName(for: wrong))
        try FileManager.default.copyItem(at: staging, to: wrongEntry)
        let error = adoptionError { _ = try VPhoneIPSWCache.adopt(wrongEntry.path, in: cache, source: wrong) }
        guard case .digestMismatch? = error else { Issue.record("expected digestMismatch, got \(String(describing: error))"); return }
        #expect(!FileManager.default.fileExists(atPath: VPhoneIPSWCache.markerURL(for: wrongEntry).path))

        let right = "https://updates.cdn-apple.invalid/private-cloud-compute/\(sha256(payload))"
        let rightEntry = cache.appendingPathComponent(VPhoneIPSWCache.scriptCacheName(for: right))
        try FileManager.default.copyItem(at: staging, to: rightEntry)
        let result = try VPhoneIPSWCache.adopt(rightEntry.path, in: cache, source: right)
        #expect(result.checks.contains("url-digest"))
    }

    @Test func `file that is not an IPSW is refused`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let entry = cache.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        try Data(repeating: 7, count: 1 << 16).write(to: entry)
        let error = adoptionError { _ = try VPhoneIPSWCache.adopt(entry.path, in: cache, source: Self.localURL) }
        guard case .notIPSW? = error else { Issue.record("expected notIPSW, got \(String(describing: error))"); return }
        #expect(try names(cache) == ["iPhone17,3_26.1_23B85_Restore.ipsw"])

        // A readable IPSW whose manifest disagrees with the Apple file name.
        try FileManager.default.removeItem(at: entry)
        try zipIPSW(at: entry, version: "26.6.2", build: "23G90")
        let mismatch = adoptionError { _ = try VPhoneIPSWCache.adopt(entry.path, in: cache, source: Self.localURL) }
        guard case .manifestMismatch? = mismatch else { Issue.record("expected manifestMismatch, got \(String(describing: mismatch))"); return }
        #expect(try names(cache) == ["iPhone17,3_26.1_23B85_Restore.ipsw"])
    }

    @Test func `symlinks, partials and paths outside the cache are refused`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let outside = root.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        try zipIPSW(at: outside)
        let link = cache.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let partial = cache.appendingPathComponent(".iPhone17,3_26.1_23B85_Restore.ipsw.partial.12345")
        try FileManager.default.copyItem(at: outside, to: partial)
        let nested = cache.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: outside, to: nested.appendingPathComponent(outside.lastPathComponent))
        let listed = try names(cache)

        let cases: [(String, (VPhoneIPSWCache.AdoptionError) -> Bool)] = [
            (link.path, { if case .symlink = $0 { true } else { false } }),
            (link.lastPathComponent, { if case .symlink = $0 { true } else { false } }),
            (partial.path, { if case .internalName = $0 { true } else { false } }),
            (outside.path, { if case .outsideCache = $0 { true } else { false } }),
            (cache.path + "/../" + outside.lastPathComponent, { if case .outsideCache = $0 { true } else { false } }),
            (nested.appendingPathComponent(outside.lastPathComponent).path, { if case .outsideCache = $0 { true } else { false } }),
            (cache.path, { if case .outsideCache = $0 { true } else { false } }),
        ]
        for (path, matches) in cases {
            let error = adoptionError { _ = try VPhoneIPSWCache.adopt(path, in: cache, source: Self.localURL) }
            #expect(error.map(matches) == true, "\(path): \(String(describing: error))")
        }
        #expect(try names(cache) == listed)
        #expect(!FileManager.default.fileExists(atPath: VPhoneIPSWCache.markerURL(for: outside).path))
    }

    @Test func `source comes from the catalog or must be given`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let catalogEntry = cache.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        try zipIPSW(at: catalogEntry)
        let result = try VPhoneIPSWCache.adopt(catalogEntry.path, in: cache)
        #expect(result.sourceFromCatalog)
        #expect(result.source == "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw")
        #expect((try marker(catalogEntry)["adoption"] as? [String: Any])?["source_from"] as? String == "catalog")

        // 23G82 is not in the catalog (the catalog has 23G83).
        let other = cache.appendingPathComponent("iPhone17,3_26.6.1_23G82_Restore.ipsw")
        try zipIPSW(at: other, version: "26.6.1", build: "23G82")
        let error = adoptionError { _ = try VPhoneIPSWCache.adopt(other.path, in: cache) }
        guard case .sourceRequired? = error else { Issue.record("expected sourceRequired, got \(String(describing: error))"); return }

        // The file as its own local source, as fw prepare receives it by path.
        let local = try VPhoneIPSWCache.adopt(other.path, in: cache, source: other.path)
        #expect(local.source == other.path)
        let source = try #require(try marker(other)["source"] as? [String: Any])
        #expect(source["path"] as? String == other.path)
        if let check = try helper(["check", other.path, "--source", other.path]) {
            #expect(check.exitCode == 0, "\(check.stderr)")
            #expect(check.stdout.contains("adopted"))
        }
        // Another local file is not accepted as the source.
        let elsewhere = root.appendingPathComponent("copy.ipsw")
        try FileManager.default.copyItem(at: other, to: elsewhere)
        let foreign = adoptionError { _ = try VPhoneIPSWCache.adopt(catalogEntry.path, in: cache, source: elsewhere.path) }
        guard case .localSourceIsNotEntry? = foreign else { Issue.record("expected localSourceIsNotEntry"); return }
    }

    @Test func `cache names follow fw_prepare naming`() {
        // The names the shared cache holds for the catalog cloudOS 26.1 and 26.4 URLs.
        #expect(VPhoneIPSWCache.scriptCacheName(for: VPhoneFirmwareCatalog.cloud261)
            == "399b664dd623358c3de118ffc114e42dcd51c9309e751d43-727c4f5e2432.ipsw")
        #expect(VPhoneIPSWCache.scriptCacheName(for: VPhoneFirmwareCatalog.cloud264)
            == "c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ad-b80d96a0b616.ipsw")
        #expect(VPhoneIPSWCache.urlDigest(URL(string: VPhoneFirmwareCatalog.cloud261)!)
            == "399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349")
        #expect(VPhoneIPSWCache.urlDigest(URL(string: Self.localURL)!) == nil)
        #expect(VPhoneIPSWCache.cacheNames(for: Self.localURL).first == "iPhone17,3_26.1_23B85_Restore.ipsw")
    }

    // MARK: - Directories

    @Test func `extraction is adopted only after its IPSW is usable`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let zip = cache.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        let payload = try zipIPSW(at: zip)
        let directory = cache.appendingPathComponent("iPhone17,3_26.1_23B85_Restore", isDirectory: true)
        let unzip = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", zip.path, "-d", directory.path])
        try #require(unzip.succeeded)
        let directoryMarker = directory.appendingPathComponent(".vphone-extract-complete")

        let early = adoptionError { _ = try VPhoneIPSWCache.adopt(directory.path, in: cache) }
        guard case .parentNotUsable? = early else { Issue.record("expected parentNotUsable, got \(String(describing: early))"); return }
        #expect(!FileManager.default.fileExists(atPath: directoryMarker.path))

        _ = try VPhoneIPSWCache.adopt(zip.path, in: cache, source: Self.localURL)
        // An interrupted unzip: a member is short.
        let member = directory.appendingPathComponent("Firmware/all_flash/iBoot.im4p")
        let original = try Data(contentsOf: member)
        try original.prefix(10).write(to: member)
        let short = adoptionError { _ = try VPhoneIPSWCache.adopt(directory.path, in: cache) }
        guard case .extractionMismatch? = short else { Issue.record("expected extractionMismatch, got \(String(describing: short))"); return }
        try original.write(to: member)
        try Data("x".utf8).write(to: directory.appendingPathComponent("extra.bin"))
        let extra = adoptionError { _ = try VPhoneIPSWCache.adopt(directory.path, in: cache) }
        guard case .extractionMismatch? = extra else { Issue.record("expected extractionMismatch for an extra file"); return }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("extra.bin"))

        let result = try VPhoneIPSWCache.adopt(directory.lastPathComponent, in: cache)
        #expect(result.outcome == .adopted && result.isDirectory)
        #expect(result.sha256 == sha256(payload))
        let recorded = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: directoryMarker)) as? [String: Any])
        #expect(recorded["kind"] as? String == "directory")
        #expect(recorded["adopted"] as? Bool == true)
        #expect((recorded["parent"] as? [String: Any])?["sha256"] as? String == sha256(payload))
        #expect(try VPhoneIPSWCache.adopt(directory.path, in: cache).outcome == .alreadyUsable)
        if let check = try helper(["check-dir", directory.path, "--parent", zip.path]) {
            #expect(check.exitCode == 0, "\(check.stderr)")
            #expect(check.stdout.contains("adopted; source not verified by download"))
        }
    }

    // MARK: - Listing

    @Test func `list reports each state and changes nothing`() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("cache")
        let payload = try zipIPSW(at: root.appendingPathComponent("served.ipsw"))
        let server = try LocalIPSWServer(payload: payload)
        defer { server.stop() }
        let downloaded = try await VPhoneIPSWCache.resolve(server.url.absoluteString, in: cache)
        let adopted = cache.appendingPathComponent("iPhone17,3_26.1_23B85_Restore.ipsw")
        try payload.write(to: adopted)
        _ = try VPhoneIPSWCache.adopt(adopted.path, in: cache, source: Self.localURL)
        try payload.write(to: cache.appendingPathComponent("legacy.ipsw"))
        try payload.write(to: cache.appendingPathComponent(".legacy.ipsw.partial.999999"))
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("legacy"), withIntermediateDirectories: true)
        let before = try names(cache)
        let mtimes = try before.map { try FileManager.default.attributesOfItem(atPath: cache.appendingPathComponent($0).path)[.modificationDate] as? Date }

        let rows = try VPhoneIPSWCache.list(cache)
        let states = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0.state) })
        #expect(states[downloaded.file.lastPathComponent] == "downloaded")
        #expect(states[adopted.lastPathComponent] == "adopted")
        #expect(states["legacy.ipsw"] == "unmarked")
        #expect(states["legacy"] == "unmarked")
        #expect(states[".legacy.ipsw.partial.999999"] == "partial")
        #expect(rows.first { $0.name == adopted.lastPathComponent }?.build == "23B85")

        #expect(try names(cache) == before)
        #expect(try before.map { try FileManager.default.attributesOfItem(atPath: cache.appendingPathComponent($0).path)[.modificationDate] as? Date } == mtimes)

        // Changed after adoption: listed as stale.
        let handle = try FileHandle(forWritingTo: adopted)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        #expect(try VPhoneIPSWCache.list(cache).first { $0.name == adopted.lastPathComponent }?.state == "stale")
    }
}

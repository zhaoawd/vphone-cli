import CryptoKit
import Darwin
import Foundation
import VPhoneCore
import VPhoneKernelIOTrace

/// Content-addressed originals produced by a fresh, verified preparation.
/// A manifest is recovery evidence, not a signature or an applied-patch receipt.
public enum FirmwareGeneration {
    public struct Failure: Error, LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public struct Original: Codable, Equatable, Sendable {
        public let name: String
        public let sha256: String
    }

    public struct Provenance: Codable, Equatable, Sendable {
        public let recognition: String
        public let inputManifestSHA256: [String: String]
        public let archiveSHA256: [String: String]
        public let builds: [String: String]
        public let device: String
        /// Concrete AGX input names. This does not assert host GPU compatibility.
        public let gpuInputs: [String]
        public let bootROMSHA256: String
    }

    /// Opaque capability. Only the module's fresh archive producer constructs it;
    /// JSON records and pre-existing restore trees cannot be decoded into a Source.
    public struct Source: Sendable {
        public let provenance: Provenance
        public let originals: [Original]
        let directory: URL
        init(provenance: Provenance, originals: [Original], directory: URL) {
            self.provenance = provenance
            self.originals = originals
            self.directory = directory
        }
    }

    public struct Content: Codable, Equatable, Sendable {
        public let identity: VPhoneFirmwareIdentity
        public let source: Provenance
        public let originals: [Original]
    }

    public struct Manifest: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let id: String
        public let content: Content
    }

    /// Opaque unpublished snapshot. A cancelled/abandoned snapshot never replaces
    /// an existing generation. `discard` can remove it explicitly.
    public struct Prepared: Sendable {
        public let manifest: Manifest
        let directory: URL
        let staging: URL
    }

    /// A plan association records selection only; execution receipts are separate.
    public struct PlanAssociation: Codable, Equatable {
        public let schemaVersion: Int
        public let generationID: String
        public let planSHA256: String
        public let state: String
    }

    /// Call under the VM bundle lock, as the create path does.
    public static func prepare(in directory: URL, inputs: [URL], source: Source) throws -> Prepared {
        try capture(in: directory, sourceDirectory: directory, inputs: inputs, source: source)
    }

    /// Only the fresh archive preparation adapter uses a separate producer tree.
    /// The public capture API continues to require originals in the target VM.
    static func prepareFreshSource(in directory: URL, sourceDirectory: URL, source: Source) throws -> Prepared {
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let scratch = sourceDirectory.standardizedFileURL
        guard scratch == scratch.resolvingSymlinksInPath(), scratch.deletingLastPathComponent() == directory,
              scratch.lastPathComponent.hasPrefix(".firmware-generation-prepare-") else {
            throw fail("fresh source must belong to the private VM preparation directory")
        }
        return try capture(in: directory, sourceDirectory: scratch,
            inputs: source.originals.map { scratch.appendingPathComponent($0.name) }, source: source)
    }

    private static func capture(in directory: URL, sourceDirectory: URL, inputs: [URL], source: Source) throws -> Prepared {
        try checkCancellation()
        let directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        let sourceDirectory = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard source.directory == sourceDirectory, !inputs.isEmpty else { throw fail("source belongs to another preparation") }
        let names = inputs.map(\.lastPathComponent).sorted()
        guard names == source.originals.map(\.name), Set(names).count == names.count else {
            throw fail("original set differs from verified preparation")
        }
        for input in inputs {
            // Directory URL hints can add a trailing slash without changing
            // the filesystem path (notably for VPhoneLibrary URLs).
            guard input.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path == sourceDirectory.path else {
                throw fail("original is outside the VM directory")
            }
        }
        var required: Int64 = 10 << 30
        for input in inputs {
            let (sum, overflow) = required.addingReportingOverflow(try logicalBytes(input))
            guard !overflow else { throw fail("generation size overflow") }
            required = sum
        }
        let free = try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber
        guard let free, free.int64Value >= required else {
            throw fail("insufficient space for generation originals plus a 10 GiB reserve")
        }
        let content = Content(identity: try VPhoneFirmwareIdentity.read(in: directory),
                              source: source.provenance, originals: source.originals)
        let manifest = Manifest(schemaVersion: 1, id: try digest(content), content: content)
        let root = try storage(in: directory, create: true)
        let staging = root.appendingPathComponent(".pending-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: staging) } }
        let originals = staging.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
        for original in source.originals {
            try checkCancellation()
            let input = sourceDirectory.appendingPathComponent(original.name)
            guard try treeDigest(input) == original.sha256 else { throw fail("prepared original changed: \(original.name)") }
            try copy(input, to: originals.appendingPathComponent(original.name))
            guard try treeDigest(input) == original.sha256,
                  try treeDigest(originals.appendingPathComponent(original.name)) == original.sha256 else {
                throw fail("original changed during generation capture: \(original.name)")
            }
        }
        try write(try encode(manifest), to: staging.appendingPathComponent("manifest.json"))
        guard try VPhoneFirmwareIdentity.read(in: directory) == content.identity else { throw fail("VM identity changed during capture") }
        try verifyOriginals(manifest, at: staging)
        try sync(staging)
        keep = true
        return Prepared(manifest: manifest, directory: directory, staging: staging)
    }

    /// Call under the same bundle lock used for capture and plan resolution.
    public static func publish(_ prepared: Prepared, planSHA256: String) throws -> Manifest {
        try checkCancellation()
        guard validDigest(planSHA256) else { throw fail("invalid plan digest") }
        let manifest = prepared.manifest
        guard try VPhoneFirmwareIdentity.read(in: prepared.directory) == manifest.content.identity else {
            throw fail("VM identity changed before generation publication")
        }
        let root = try storage(in: prepared.directory, create: false)
        guard prepared.staging.deletingLastPathComponent() == root else { throw fail("invalid pending generation") }
        let stored = try readManifest(prepared.staging.appendingPathComponent("manifest.json"))
        guard stored == manifest else { throw fail("pending manifest changed") }
        try verifyOriginals(manifest, at: prepared.staging)
        try checkCancellation()
        let destination = root.appendingPathComponent(manifest.id)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try loadVerified(in: prepared.directory, id: manifest.id) == manifest else { throw fail("generation collision") }
            try discard(prepared)
        } else {
            guard renamex_np(prepared.staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try sync(root)
        }
        let associations = destination.appendingPathComponent("plans")
        try ensureDirectory(associations, create: true)
        let association = PlanAssociation(schemaVersion: 1, generationID: manifest.id,
                                          planSHA256: planSHA256, state: "prepared")
        let associationURL = associations.appendingPathComponent(planSHA256 + ".json")
        let data = try encode(association)
        if FileManager.default.fileExists(atPath: associationURL.path) {
            guard try VPhoneCreateDigest.strictFileData(associationURL, maximumBytes: 1 << 20) == data else {
                throw fail("plan association changed")
            }
        } else { try write(data, to: associationURL) }
        return try loadVerified(in: prepared.directory, id: manifest.id)
    }

    public static func loadVerified(in directory: URL, id: String, file: String = #fileID, line: Int = #line, function: String = #function) throws -> Manifest {
        return try KernelIOTrace.measure("generation.loadVerified", file: file, line: line, function: function) { span in
            guard validDigest(id) else { throw fail("invalid generation ID") }
            let root = try storage(in: directory, create: false).appendingPathComponent(id)
            try ensureDirectory(root, create: false)
            let manifest = try readManifest(root.appendingPathComponent("manifest.json"))
            guard manifest.schemaVersion == 1, manifest.id == id,
                  try digest(manifest.content) == id,
                  manifest.content.source.recognition == "fresh-local-ipsw-prepare-v1",
                  try VPhoneFirmwareIdentity.read(in: directory) == manifest.content.identity else {
                throw fail("generation manifest or VM identity differs")
            }
            try verifyOriginals(manifest, at: root)
            return manifest
        }
    }

    /// Returned paths remain subject to the caller's transaction lock and readback.
    public static func originalURLs(in directory: URL, id: String) throws -> [URL] {
        let manifest = try loadVerified(in: directory, id: id)
        return manifest.content.originals.map {
            directory.appendingPathComponent(".firmware-generations/\(id)/originals/\($0.name)")
        }
    }

    public static func discard(_ prepared: Prepared) throws {
        try ensureDirectory(prepared.staging, create: false)
        try FileManager.default.removeItem(at: prepared.staging)
    }

    public static func planDigest(_ plan: VariantPlanResolver.VariantPlan) throws -> String { try digest(plan) }

    // MARK: - Content and filesystem verification

    static func checkCancellation() throws {
        try Task.checkCancellation()
        try VPhoneChildCancellation.current?.throwIfRequested()
    }
    static func fail(_ message: String) -> Failure { Failure(message: message) }
    static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func digest<T: Encodable>(_ value: T) throws -> String { VPhoneCreateDigest.sha256(try encode(value)) }
    static func readManifest(_ url: URL) throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: VPhoneCreateDigest.strictFileData(url, maximumBytes: 8 << 20))
    }
    static func storage(in directory: URL, create: Bool) throws -> URL {
        try ensureDirectory(directory, create: false)
        let root = directory.appendingPathComponent(".firmware-generations")
        try ensureDirectory(root, create: create)
        return root
    }
    static func ensureDirectory(_ directory: URL, create: Bool) throws {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard create, errno == ENOENT else { throw fail("missing generation directory") }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(directory.path, &info) == 0 else { throw fail("directory disappeared") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw fail("linked or invalid generation directory") }
    }
    static func verifyOriginals(_ manifest: Manifest, at directory: URL, file: String = #fileID, line: Int = #line, function: String = #function) throws {
        try KernelIOTrace.measure("generation.verifyOriginals", file: file, line: line, function: function) { span in
            let originals = directory.appendingPathComponent("originals")
            try ensureDirectory(originals, create: false)
            let names = manifest.content.originals.map(\.name)
            guard !names.isEmpty, names == names.sorted(), Set(names).count == names.count,
                  names.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") && $0 != "." && $0 != ".." }),
                  try FileManager.default.contentsOfDirectory(atPath: originals.path).sorted() == names else {
                throw fail("invalid original set")
            }
            for original in manifest.content.originals {
                try checkCancellation()
                guard validDigest(original.sha256), try treeDigest(originals.appendingPathComponent(original.name)) == original.sha256 else {
                    throw fail("generation original differs: \(original.name)")
                }
            }
        }
    }

    /// Includes every byte, relative name, type and empty directory. Opened files
    /// reject symlinks/hardlinks and are checked again after the streaming read.
    static func treeDigest(_ url: URL, file: String = #fileID, line: Int = #line, function: String = #function) throws -> String {
        return try KernelIOTrace.measure("generation.treeDigest", labels: KernelIOTrace.labels(url, byteSemantics: "descendants_only"), file: file, line: line, function: function) { span in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw fail("missing input: \(url.lastPathComponent)") }
            var hash = SHA256()
            if info.st_mode & S_IFMT == S_IFDIR {
                hash.update(data: Data("directory\0".utf8))
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                for name in names {
                    hash.update(data: Data((name + "\0" + (try treeDigest(url.appendingPathComponent(name))) + "\0").utf8))
                }
                var after = stat()
                guard lstat(url.path, &after) == 0, after.st_mode & S_IFMT == S_IFDIR,
                      info.st_dev == after.st_dev, info.st_ino == after.st_ino,
                      names == (try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()) else {
                    throw fail("directory changed while hashing")
                }
            } else {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw fail("linked or special input") }
                hash.update(data: Data("file\0".utf8))
                try readFile(url) { hash.update(data: $0) }
            }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    static func fileSHA256(_ url: URL, file: String = #fileID, line: Int = #line, function: String = #function) throws -> String {
        return try KernelIOTrace.measure("generation.fileSHA256", labels: KernelIOTrace.labels(url, byteSemantics: "consumer_actual"), file: file, line: line, function: function) { span in
            var consumed: Int64 = 0
            defer { span?.set("bytes", consumed) }
            var hash = SHA256()
            try readFile(url) { consumed += Int64($0.count); hash.update(data: $0) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    static func readFile(_ url: URL, file: String = #fileID, line: Int = #line, function: String = #function, consume: (Data) throws -> Void) throws {
        try KernelIOTrace.measure("generation.readFile", labels: KernelIOTrace.labels(url, byteSemantics: "stream_read_actual"), file: file, line: line, function: function) { span in
            var readCalls: Int64 = 0, actualBytes: Int64 = 0
            defer { span?.set("read_calls", readCalls); span?.set("bytes", actualBytes) }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw fail("unreadable or linked input") }
            defer { close(fd) }
            var before = stat(), after = stat(), named = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw fail("invalid input type") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            var count: Int64 = 0
            while try autoreleasepool(invoking: { () throws -> Bool in
                try checkCancellation()
                readCalls += 1
                let read = try handle.read(upToCount: 1 << 20)
                actualBytes += Int64(read?.count ?? 0)
                guard let bytes = read, !bytes.isEmpty else { return false }
                count += Int64(bytes.count)
                try consume(bytes)
                return true
            }) {}
            guard fstat(fd, &after) == 0, lstat(url.path, &named) == 0,
                  named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1,
                  before.st_dev == named.st_dev, before.st_ino == named.st_ino, before.st_size == count,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw fail("input changed while hashing") }
        }
    }

    static func logicalBytes(_ url: URL) throws -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw fail("missing original") }
        if info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 { return info.st_size }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw fail("linked or special original") }
        var total: Int64 = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
            let (sum, overflow) = total.addingReportingOverflow(try logicalBytes(url.appendingPathComponent(name)))
            guard !overflow else { throw fail("generation size overflow") }
            total = sum
        }
        return total
    }

    static func copy(_ source: URL, to destination: URL) throws {
        var info = stat()
        guard lstat(source.path, &info) == 0 else { throw fail("missing original") }
        if info.st_mode & S_IFMT == S_IFDIR {
            try ensureDirectory(destination, create: true)
            for name in try FileManager.default.contentsOfDirectory(atPath: source.path).sorted() {
                try copy(source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
            }
            try sync(destination)
        } else {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw fail("linked original") }
            let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw fail("cannot create original snapshot") }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? output.close() }
            try readFile(source) { try output.write(contentsOf: $0) }
            try KernelIOTrace.measure("generation.fileHandleSynchronize", aggregate: true) { _ in try output.synchronize() }
        }
    }
    static func sync(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw fail("cannot synchronize directory") }
        defer { close(fd) }
        guard KernelIOTrace.synchronize(fd, phase: "generation.fsync") == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: temporary)
        defer { try? handle.close() }
        try KernelIOTrace.measure("generation.fileHandleSynchronize", aggregate: true) { _ in try handle.synchronize() }
        guard renamex_np(temporary.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try sync(url.deletingLastPathComponent())
    }
}

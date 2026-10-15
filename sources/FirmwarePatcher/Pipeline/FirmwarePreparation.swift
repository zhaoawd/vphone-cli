// Adapted from upstream 2.0.8 VPhoneFirmwarePreparer for the local classic layout.
import Darwin
import Foundation
import VPhoneArchiveKit
import VPhoneCore

public enum FirmwarePreparation {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    public static func localSources(iphoneSource: String?, cloudosSource: String?, isLess: Bool,
                             relativeTo directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) throws -> (iphone: URL, cloudos: URL) {
        guard !isLess, let iphoneSource, let cloudosSource,
              !iphoneSource.isEmpty, !cloudosSource.isEmpty,
              !iphoneSource.contains("://"), !cloudosSource.contains("://") else {
            throw Failure(message: "Native prepare requires two local IPSW paths; selectors, downloads and less are not supported.")
        }
        // Resolve relative paths before recording them; resume can use a different cwd.
        return (URL(fileURLWithPath: iphoneSource, relativeTo: directory).absoluteURL.standardizedFileURL,
                URL(fileURLWithPath: cloudosSource, relativeTo: directory).absoluteURL.standardizedFileURL)
    }

    public static func prepare(iPhone: URL, cloudOS: URL, bundle: URL,
                               preserveExistingRestore: Bool = false,
                               isCancelled: @escaping () -> Bool = { Task.isCancelled || VPhoneChildCancellation.current?.isRequested == true }) throws -> URL {
        try prepare(iPhone: iPhone, cloudOS: cloudOS, bundle: bundle,
                    preserveExistingRestore: preserveExistingRestore, isCancelled: isCancelled,
                    generateManifest: { try FirmwareManifest.generate(iPhoneDir: $0, cloudOSDir: $1, verbose: false) })
    }

    /// Runs fresh extraction, then captures only the bytes this producer verified.
    /// Local IPSW provenance does not assert Apple signature authenticity.
    public static func prepareWithSource(iPhone: URL, cloudOS: URL, bundle: URL, bootROMSource: URL,
                                         preserveExistingRestore: Bool = false,
                                         isCancelled: @escaping () -> Bool = { Task.isCancelled || VPhoneChildCancellation.current?.isRequested == true }) throws -> (tree: URL, source: FirmwareGeneration.Source) {
        try requireIndependentROM(bootROMSource, bundle: bundle)
        var captured: FirmwareGeneration.Source?
        let tree = try prepare(iPhone: iPhone, cloudOS: cloudOS, bundle: bundle,
            preserveExistingRestore: preserveExistingRestore, isCancelled: isCancelled,
            generateManifest: { try FirmwareManifest.generate(iPhoneDir: $0, cloudOSDir: $1, verbose: false) },
            captureSource: { staging, destination, phoneManifest, cloudManifest, archives in
                let rom = bundle.appendingPathComponent("AVPBooter.vresearch1.bin")
                let romSHA = try FirmwareGeneration.fileSHA256(bootROMSource)
                guard try FirmwareGeneration.fileSHA256(rom) == romSHA else {
                    throw FirmwareGeneration.fail("boot ROM differs from the prepare resource")
                }
                func build(_ data: Data) throws -> String {
                    guard let p = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                          let b = p["ProductBuildVersion"] as? String, !b.isEmpty else {
                        throw FirmwareGeneration.fail("source build is missing")
                    }
                    return b
                }
                let gpu = try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("Firmware/agx").path).sorted()
                guard !gpu.isEmpty else { throw FirmwareGeneration.fail("GPU input set is missing") }
                let provenance = FirmwareGeneration.Provenance(recognition: "fresh-local-ipsw-prepare-v1",
                    inputManifestSHA256: ["iPhone": VPhoneCreateDigest.sha256(phoneManifest), "cloudOS": VPhoneCreateDigest.sha256(cloudManifest)],
                    archiveSHA256: archives, builds: ["iPhone": try build(phoneManifest), "cloudOS": try build(cloudManifest)],
                    device: "vresearch101ap/vphone600ap", gpuInputs: gpu, bootROMSHA256: romSHA)
                captured = FirmwareGeneration.Source(provenance: provenance, originals: [
                    .init(name: rom.lastPathComponent, sha256: try FirmwareGeneration.treeDigest(rom)),
                    .init(name: destination.lastPathComponent, sha256: try FirmwareGeneration.treeDigest(staging)),
                ].sorted { $0.name < $1.name }, directory: bundle.standardizedFileURL.resolvingSymlinksInPath())
            })
        guard let source = captured else { throw FirmwareGeneration.fail("prepare produced no source") }
        return (tree, source)
    }

    /// Explicit recognition route for script/less or a legacy tree: reproduce
    /// preparation from the named IPSWs and compare every byte before qualification.
    /// The existing tree is never taken as its own reference.
    public static func verifyPreparedSource(iPhone: URL, cloudOS: URL, bundle: URL,
                                            bootROMSource: URL,
                                            isCancelled: @escaping () -> Bool = { Task.isCancelled || VPhoneChildCancellation.current?.isRequested == true }) throws -> FirmwareGeneration.Source {
        try requireIndependentROM(bootROMSource, bundle: bundle)
        let reference = bundle.appendingPathComponent(".firmware-reference-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: reference) }
        try FirmwareGeneration.copy(bootROMSource, to: reference.appendingPathComponent("AVPBooter.vresearch1.bin"))
        let result = try prepareWithSource(iPhone: iPhone, cloudOS: cloudOS, bundle: reference,
                                          bootROMSource: bootROMSource, isCancelled: isCancelled)
        for original in result.source.originals {
            guard try FirmwareGeneration.treeDigest(bundle.appendingPathComponent(original.name)) == original.sha256 else {
                throw FirmwareGeneration.fail("existing tree differs from fresh IPSW preparation: \(original.name)")
            }
        }
        return FirmwareGeneration.Source(provenance: result.source.provenance, originals: result.source.originals,
                                         directory: bundle.standardizedFileURL.resolvingSymlinksInPath())
    }

    private static func requireIndependentROM(_ source: URL, bundle: URL) throws {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let directory = bundle.standardizedFileURL.resolvingSymlinksInPath()
        guard !source.path.hasPrefix(directory.path + "/") else {
            throw FirmwareGeneration.fail("VM originals cannot serve as their own boot ROM source")
        }
    }

    /// Local inputs only. Holds the same VM lock as the script backend; never
    /// removes an existing restore tree or writes back to either source IPSW.
    static func prepare(iPhone: URL, cloudOS: URL, bundle: URL,
                        preserveExistingRestore: Bool = false,
                        isCancelled: @escaping () -> Bool = { Task.isCancelled || VPhoneChildCancellation.current?.isRequested == true },
                        generateManifest: (URL, URL) throws -> Void = {
                            try FirmwareManifest.generate(iPhoneDir: $0, cloudOSDir: $1, verbose: false)
                        },
                        captureSource: ((URL, URL, Data, Data, [String: String]) throws -> Void)? = nil) throws -> URL {
        try VPhoneBundleGuard.withBundleLock(directory: bundle, operation: VPhoneVMOperation.fwPrepare) { _ in
            let previous = try existingRestore(in: bundle, allowPreservation: preserveExistingRestore)
            let phoneState = try sourceState(iPhone)
            let cloudState = try sourceState(cloudOS)
            let archiveHashes: [String: String] = captureSource == nil ? [:] : [
                "iPhone": try FirmwareGeneration.fileSHA256(iPhone), "cloudOS": try FirmwareGeneration.fileSHA256(cloudOS),
            ]
            let phone = try VPhoneIPSWCache.inspect(iPhone)
            let cloud = try VPhoneIPSWCache.inspect(cloudOS)
            try VPhoneIPSWCache.checkPair(iPhone: phone, cloudOS: cloud)
            // Manifest values become one path component, never a path supplied
            // by an untrusted archive.
            for value in [phone.version, phone.build] {
                guard !value.isEmpty, value.utf8.allSatisfy({
                    (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 46
                }), value != ".", value != ".." else {
                    throw Failure(message: "Unsafe IPSW version or build: \(value)")
                }
            }
            let phoneEntries = try validateArchive(iPhone)
            let cloudEntries = try validateArchive(cloudOS)
            // Account for both extracted trees and copies on non-cloning filesystems.
            let required = try requiredBytes(phoneEntries + cloudEntries + cloudEntries)
            let free = try FileManager.default.attributesOfFileSystem(forPath: bundle.path)[.systemFreeSize] as? NSNumber
            guard let free, free.int64Value >= required else {
                throw Failure(message: "Insufficient space for native prepare: requires \(required) bytes including a 10 GiB reserve.")
            }
            if isCancelled() { throw CancellationError() }
            let fm = FileManager.default
            let staging = bundle.appendingPathComponent(".firmware-prepare-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            let phoneTree = staging.appendingPathComponent("phone")
            let cloudTree = staging.appendingPathComponent("cloud")
            for tree in [phoneTree, cloudTree] {
                try fm.createDirectory(at: tree, withIntermediateDirectories: false)
            }
            print("[*] Extracting local iPhone IPSW...")
            try VPhoneArchiveExtractor.extract(iPhone, into: phoneTree, options: .intoHostDirectory, isCancelled: isCancelled)
            print("[*] Extracting local cloudOS IPSW...")
            try VPhoneArchiveExtractor.extract(cloudOS, into: cloudTree, options: .intoHostDirectory, isCancelled: isCancelled)
            guard try sourceState(iPhone) == phoneState, try sourceState(cloudOS) == cloudState else {
                throw Failure(message: "An IPSW changed during preparation; no restore tree was published.")
            }
            let phoneManifest = try VPhoneCreateDigest.strictFileData(phoneTree.appendingPathComponent("BuildManifest.plist"), maximumBytes: 32 << 20)
            let cloudManifest = try VPhoneCreateDigest.strictFileData(cloudTree.appendingPathComponent("BuildManifest.plist"), maximumBytes: 32 << 20)
            if captureSource != nil {
                guard try FirmwareGeneration.fileSHA256(iPhone) == archiveHashes["iPhone"],
                      try FirmwareGeneration.fileSHA256(cloudOS) == archiveHashes["cloudOS"] else {
                    throw FirmwareGeneration.fail("IPSW content changed during extraction")
                }
            }
            try makeWritable(phoneTree)
            try merge(cloudTree, into: phoneTree)
            try fm.copyItem(at: phoneTree.appendingPathComponent("BuildManifest.plist"),
                            to: phoneTree.appendingPathComponent("iPhone-BuildManifest.plist"))
            try generateManifest(phoneTree, cloudTree)
            try validatePreparedTree(phoneTree)
            if isCancelled() { throw CancellationError() }
            let destination = bundle.appendingPathComponent("iPhone17,3_\(phone.version)_\(phone.build)_Restore")
            try captureSource?(phoneTree, destination, phoneManifest, cloudManifest, archiveHashes)
            if isCancelled() { throw CancellationError() }
            try publish(phoneTree, to: destination, previous: previous, bundle: bundle)
            return destination
        }
    }

    // MARK: - Input and publication checks

    static func rejectExistingRestore(in bundle: URL) throws {
        _ = try existingRestore(in: bundle, allowPreservation: false)
    }

    struct ExistingRestore: Equatable {
        let url: URL
        let directoryId: String
    }

    static func existingRestore(in bundle: URL, allowPreservation: Bool) throws -> ExistingRestore? {
        let names = try FileManager.default.contentsOfDirectory(atPath: bundle.path).filter { $0.contains("Restore") }
        guard !names.isEmpty else { return nil }
        guard allowPreservation, names.count == 1, let name = names.first,
              name.hasPrefix("iPhone"), name.hasSuffix("_Restore") else {
            throw Failure(message: "Existing restore paths: \(names.sorted().joined(separator: ", ")). Preserve or explicitly remove them before native prepare.")
        }
        let url = bundle.appendingPathComponent(name)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw Failure(message: "Existing restore path is not a regular directory: \(name).")
        }
        return ExistingRestore(url: url, directoryId: "\(info.st_dev):\(info.st_ino)")
    }

    /// The checkpointed prepare rerun preserves the old tree only after the new
    /// manifests are ready. Standalone fw prepare always refuses existing trees.
    static func publish(_ tree: URL, to destination: URL, previous: ExistingRestore?, bundle: URL) throws {
        guard try existingRestore(in: bundle, allowPreservation: previous != nil) == previous else {
            throw Failure(message: "Restore paths changed during preparation; no new tree was published.")
        }
        var backup: URL?
        if let previous {
            let directory = bundle.appendingPathComponent(".firmware-prepare-backup-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let saved = directory.appendingPathComponent(previous.url.lastPathComponent)
            guard renamex_np(previous.url.path, saved.path, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(at: directory)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            backup = saved
        }
        guard renamex_np(tree.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            let code = errno
            // A competing destination is never overwritten. If rollback is
            // blocked, leave the preserved tree and report its exact location.
            if let previous, let backup {
                guard renamex_np(backup.path, previous.url.path, UInt32(RENAME_EXCL)) == 0 else {
                    throw Failure(message: "Native prepare publication failed (errno \(code)); previous restore tree preserved at \(backup.path), rollback blocked (errno \(errno)).")
                }
                try? FileManager.default.removeItem(at: backup.deletingLastPathComponent())
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        if let backup {
            print("[+] Previous restore tree preserved: \(backup.path)")
        }
    }

    /// Presence and path checks for the classic generated identity. Component
    /// digests, GPU compatibility and boot behavior require separate validation.
    static func validatePreparedTree(_ tree: URL) throws {
        let bytes = try Data(contentsOf: tree.appendingPathComponent("BuildManifest.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let identities = plist["BuildIdentities"] as? [[String: Any]], identities.count == 1,
              (identities[0]["Info"] as? [String: Any])?["DeviceClass"] as? String == "vresearch101ap",
              let components = identities[0]["Manifest"] as? [String: [String: Any]], !components.isEmpty else {
            throw Failure(message: "Invalid prepared classic BuildManifest.")
        }
        for (name, component) in components {
            guard let info = component["Info"] as? [String: Any], let path = info["Path"] as? String else {
                throw Failure(message: "Missing prepared component path: \(name)")
            }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
                throw Failure(message: "Unsafe prepared component path: \(name)")
            }
            var file = tree
            for (index, part) in parts.enumerated() {
                file.appendPathComponent(String(part))
                var value = stat()
                guard lstat(file.path, &value) == 0,
                      value.st_mode & S_IFMT == (index == parts.count - 1 ? S_IFREG : S_IFDIR) else {
                    throw Failure(message: "Missing or linked prepared component: \(name) at \(path)")
                }
            }
        }
    }

    static func validateArchive(_ archive: URL) throws -> [VPhoneArchiveReader.Entry] {
        let entries = try VPhoneArchiveReader.entries(of: archive, maximumEntries: 100_000)
        var names = Set<String>()
        for entry in entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            let cleanParts = entry.isDirectory && parts.last == "" ? parts.dropLast() : parts[...]
            guard !cleanParts.isEmpty, cleanParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  names.insert(cleanParts.joined(separator: "/")).inserted,
                  entry.hardlinkTarget == nil, !entry.isSymlink,
                  entry.fileType == S_IFREG || entry.fileType == S_IFDIR,
                  entry.size >= 0, entry.mode & 0o7000 == 0 else {
                throw Failure(message: "Unsupported or ambiguous IPSW member: \(entry.path)")
            }
        }
        for required in ["BuildManifest.plist", "Restore.plist"] {
            guard entries.contains(where: { $0.path == required && $0.fileType == S_IFREG }) else {
                throw Failure(message: "Missing regular IPSW member: \(required)")
            }
        }
        return entries
    }

    static func requiredBytes(_ entries: [VPhoneArchiveReader.Entry]) throws -> Int64 {
        var total: Int64 = 10 * 1024 * 1024 * 1024
        for entry in entries where entry.fileType == S_IFREG {
            let (sum, overflow) = total.addingReportingOverflow(entry.size)
            guard !overflow else { throw Failure(message: "IPSW declared size overflow.") }
            total = sum
        }
        return total
    }

    static func sourceState(_ source: URL) throws -> [Int64] {
        var info = stat()
        guard lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw Failure(message: "Native prepare requires a regular local IPSW, not a link: \(source.path)")
        }
        return [Int64(info.st_dev), Int64(info.st_ino), info.st_size,
                Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }

    // MARK: - Classic component merge

    static func merge(_ cloud: URL, into phone: URL) throws {
        try copyMatching(cloud, to: phone, required: true) { $0.hasPrefix("kernelcache.") }
        for name in ["agx", "all_flash", "ane", "dfu", "pmp"] {
            try copyMatching(cloud.appendingPathComponent("Firmware/\(name)"),
                             to: phone.appendingPathComponent("Firmware/\(name)"), required: true) { _ in true }
        }
        try copyMatching(cloud.appendingPathComponent("Firmware"), to: phone.appendingPathComponent("Firmware"), required: true) { $0.hasSuffix(".im4p") }
        try copyMatching(cloud, to: phone, overwrite: false) { $0.hasSuffix(".dmg") }
        try copyMatching(cloud.appendingPathComponent("Firmware"), to: phone.appendingPathComponent("Firmware"), overwrite: false) { $0.hasSuffix(".dmg.trustcache") }
    }

    static func copyMatching(_ source: URL, to destination: URL, overwrite: Bool = true,
                             required: Bool = false, predicate: (String) -> Bool) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: source.path).filter(predicate).sorted()
        guard !required || !names.isEmpty else { throw Failure(message: "Missing cloudOS components at \(source.path)") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in names {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            if fm.fileExists(atPath: to.path) {
                if !overwrite { continue }
                try fm.removeItem(at: to)
            }
            if clonefile(from.path, to.path, 0) != 0 { try fm.copyItem(at: from, to: to) }
        }
    }

    static func makeWritable(_ root: URL) throws {
        let fm = FileManager.default
        guard let entries = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw Failure(message: "Unable to enumerate extracted firmware.")
        }
        for case let path as URL in entries {
            let attributes = try fm.attributesOfItem(atPath: path.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
            try fm.setAttributes([.posixPermissions: mode | 0o200], ofItemAtPath: path.path)
        }
    }
}

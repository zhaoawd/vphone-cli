import Darwin
import Foundation

public enum VPhoneBundleOpsError: Error, Equatable {
    case tarFailed(String)
    case badArchive(String)
}

public enum VPhoneBundleOps {
    public struct NewBundleSpec: Sendable {
        public var name: String
        public var cpuCount: UInt
        public var memoryMB: UInt64
        public var diskSizeGB: UInt64
        public var romSource: URL
        public var sepromSource: URL

        public init(name: String, cpuCount: UInt, memoryMB: UInt64, diskSizeGB: UInt64,
                    romSource: URL, sepromSource: URL) {
            self.name = name; self.cpuCount = cpuCount; self.memoryMB = memoryMB
            self.diskSizeGB = diskSizeGB; self.romSource = romSource; self.sepromSource = sepromSource
        }
    }

    private static let frameworkResources = URL(fileURLWithPath:
        "/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources")

    public static func defaultROMSource() -> URL {
        frameworkResources.appendingPathComponent("AVPBooter.vresearch1.bin")
    }
    public static func defaultSEPROMSource() -> URL {
        frameworkResources.appendingPathComponent("AVPSEPBooter.vresearch1.bin")
    }

    private static func requireValidName(_ name: String) throws {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw VPhoneLibraryError.invalidName(name)
        }
    }

    public static func create(_ spec: NewBundleSpec, in library: VPhoneLibrary) throws -> VPhoneBundle {
        try create(spec, in: library, afterNameCheck: nil)
    }

    /// The bundle directory does not exist when the name is checked, so there is
    /// nothing to take a bundle lock on: `create` runs under the library-root
    /// lock instead, from the existence check through the last write.
    ///
    /// `afterNameCheck` is a testing seam that runs between the check and the
    /// directory creation, so a test can prove the two are one lock lifetime.
    static func create(
        _ spec: NewBundleSpec, in library: VPhoneLibrary, afterNameCheck: (() -> Void)?
    ) throws -> VPhoneBundle {
        try requireValidName(spec.name)
        let fm = FileManager.default
        let dir = library.url(forName: spec.name)
        return try VPhoneBundleGuard.withLibraryLock(root: library.root) { _ in
            if fm.fileExists(atPath: dir.path) {
                throw VPhoneLibraryError.alreadyExists(name: spec.name)
            }
            afterNameCheck?()
            // No intermediate directories: creating the bundle directory then
            // fails on an existing name instead of adopting it, so the rollback
            // below can only ever remove a directory this call made.
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: false)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError
            {
                throw VPhoneLibraryError.alreadyExists(name: spec.name)
            }
            // Roll back the partial bundle on any failure after the dir is created,
            // so a retry with the same name isn't permanently blocked by the
            // alreadyExists check.
            do {
                // Sparse disk image: create then truncate to size (no bytes written).
                let disk = dir.appendingPathComponent("Disk.img")
                fm.createFile(atPath: disk.path, contents: nil)
                let handle = try FileHandle(forWritingTo: disk)
                do {
                    try handle.truncate(atOffset: spec.diskSizeGB * 1024 * 1024 * 1024)
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }

                // SEP storage: 512 KB of zeros (real bytes, matches vm_create.sh).
                try Data(count: 512 * 1024).write(to: dir.appendingPathComponent("SEPStorage"))

                // ROMs.
                try fm.copyItem(at: spec.romSource, to: dir.appendingPathComponent("AVPBooter.vresearch1.bin"))
                try fm.copyItem(at: spec.sepromSource, to: dir.appendingPathComponent("AVPSEPBooter.vresearch1.bin"))

                // Manifest.
                let manifest = VPhoneVirtualMachineManifest(
                    cpuCount: spec.cpuCount,
                    memorySize: spec.memoryMB * 1024 * 1024,
                    romImages: .init(avpBooter: "AVPBooter.vresearch1.bin",
                                     avpSEPBooter: "AVPSEPBooter.vresearch1.bin"))
                try manifest.write(to: dir.appendingPathComponent("config.plist"))

                return VPhoneBundle(url: dir, manifest: manifest)
            } catch {
                try? fm.removeItem(at: dir)
                throw error
            }
        }
    }

    // MARK: - Config editing

    public static func updateConfig(
        bundleNamed name: String, in library: VPhoneLibrary,
        cpuCount: UInt?, memoryMB: UInt64?,
        networkMode: VPhoneVirtualMachineManifest.NetworkConfig.NetworkMode? = nil,
        bridgeInterface: String? = nil
    ) throws -> VPhoneBundle {
        let directory = try library.bundle(named: name).url
        // Editing the config of a running VM is refused, not queued: the boot
        // process read the manifest at start and would not see the change.
        return try VPhoneBundleGuard.withBundleLock(
            directory: directory, operation: VPhoneVMOperation.config
        ) { _ in
            let bundle = try library.bundle(named: name)
            let editsNetwork = networkMode != nil || bridgeInterface != nil
            let network = editsNetwork
                ? try VPhoneNetworking.merge(
                    into: bundle.manifest.networkConfig,
                    mode: networkMode, bridgeInterface: bridgeInterface)
                : nil
            let updated = bundle.manifest.updating(
                cpuCount: cpuCount,
                memorySize: memoryMB.map { $0 * 1024 * 1024 },
                screenConfig: nil,
                networkConfig: network)
            try updated.write(to: bundle.configURL)
            return VPhoneBundle(url: bundle.url, manifest: updated)
        }
    }

    // MARK: - Rename / delete

    public static func rename(
        bundleNamed name: String, to newName: String, in library: VPhoneLibrary
    ) throws -> VPhoneBundle {
        try requireValidName(newName)
        let src = try library.bundle(named: name).url
        return try VPhoneBundleGuard.withBundleLock(
            directory: src, operation: VPhoneVMOperation.rename
        ) { _ in
            let dst = library.url(forName: newName)
            // The destination name is a library-wide resource: the check and the
            // move are one library-lock lifetime, so a concurrent create/import
            // of the same name cannot slip in between them.
            try VPhoneBundleGuard.withLibraryLock(root: library.root) { _ in
                if FileManager.default.fileExists(atPath: dst.path) {
                    throw VPhoneLibraryError.alreadyExists(name: newName)
                }
                try FileManager.default.moveItem(at: src, to: dst)
            }
            // The record written when this lock was taken travelled with the
            // directory and still names the old path. It is diagnostic only and
            // this operation is over, so drop it rather than leave a stale path.
            try? FileManager.default.removeItem(
                at: dst.appendingPathComponent(VPhoneVMRuntimeState.filename))
            return try VPhoneBundle.load(at: dst)
        }
    }

    public static func delete(bundleNamed name: String, in library: VPhoneLibrary) throws {
        let url = try library.bundle(named: name).url
        try VPhoneBundleGuard.withBundleLock(
            directory: url, operation: VPhoneVMOperation.delete
        ) { _ in
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Clone

    /// Clone a bundle with a fast APFS copy-on-write clone (fallback: recursive
    /// copy), then reset the boot-identity artifacts so the clone comes up as a
    /// fresh device on next boot. NOTE: SEPStorage is copied as-is — cloning an
    /// already-restored VM may need a re-restore for a fully clean identity.
    public static func clone(
        bundleNamed name: String, to newName: String, in library: VPhoneLibrary
    ) throws -> VPhoneBundle {
        try requireValidName(newName)
        let src = try library.bundle(named: name).url
        // Cloning a running VM is refused: `Disk.img` would be copied mid-write.
        // There is no verified consistent-snapshot path, so there is no opt-out.
        return try VPhoneBundleGuard.withBundleLock(
            directory: src, operation: VPhoneVMOperation.clone
        ) { _ in
            let dst = library.url(forName: newName)
            let fm = FileManager.default
            if fm.fileExists(atPath: dst.path) { throw VPhoneLibraryError.alreadyExists(name: newName) }

            // APFS CoW clone; fall back to a plain recursive copy off-APFS.
            if clonefile(src.path, dst.path, 0) != 0 {
                // EEXIST means the name was taken between the check and here, by
                // somebody else's bundle — never delete it, report the collision.
                guard errno != EEXIST else { throw VPhoneLibraryError.alreadyExists(name: newName) }
                try? fm.removeItem(at: dst)  // clear this call's partial clonefile output
                try fm.copyItem(at: src, to: dst)
            }
            try resetIdentity(inBundleAt: dst)
            return try VPhoneBundle.load(at: dst)
        }
    }

    private static func resetIdentity(inBundleAt dir: URL) throws {
        let fm = FileManager.default
        for name in ["nvram.bin", "udid-prediction.txt", VPhoneVMRuntimeState.filename] {
            let u = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
        let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        for u in entries where u.pathExtension == "shsh" { try fm.removeItem(at: u) }
        let configURL = dir.appendingPathComponent("config.plist")
        let manifest = try VPhoneVirtualMachineManifest.load(from: configURL)
        try manifest.updating(machineIdentifier: Data()).write(to: configURL)
    }

    // MARK: - Export / Import

    /// Compression preset for `export`. Both import transparently — `importArchive`
    /// auto-detects the compressor when it extracts. `threads=0` → all cores.
    public enum ExportCompression: String, CaseIterable, Sendable {
        case fast, max

        var tarArgs: [String] {
            switch self {
            case .fast: ["--zstd", "--options", "zstd:compression-level=3,zstd:threads=0"]
            case .max:  ["-J", "--options", "xz:compression-level=9,xz:threads=0"]
            }
        }

        /// Extension for auto-named output when `export`'s destination is a directory.
        public var fileExtension: String {
            switch self {
            case .fast: "tzst"
            case .max:  "txz"
            }
        }
    }

    /// Regenerable staging artifacts that never need to travel in an export:
    /// `.vphoned.signed` is re-staged on the next launch, and the CFW install
    /// inputs/temp are consumed at install time (the result already lives in
    /// `Disk.img`). Always excluded.
    static let exportExcludePatterns = ["*.vphoned.signed", "*cfw_input*", "*cfw_jb_input*", "*.cfw_temp*", "*.cfw_mount.*", "*.vphone-runtime.json"]

    /// When `to` is an existing directory, the archive is written inside it as
    /// `<name>.<compression.fileExtension>`. Returns the resolved output URL.
    ///
    /// Runs as a two-stage `tar` pipeline (uncompressed producer → compressing
    /// consumer via bsdtar's `@-`) so `progress` can be driven off the
    /// uncompressed byte stream: it is called with `(bytesDone, totalBytes)`,
    /// where `totalBytes` is the bundle's on-disk logical size (minus excludes).
    @discardableResult
    public static func export(
        bundleNamed name: String, to outFile: URL, includeIPSW: Bool,
        compression: ExportCompression = .fast, in library: VPhoneLibrary,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> URL {
        let bundle = try library.bundle(named: name)
        // Exporting a running VM is refused for the same reason as cloning: the
        // archive would contain a `Disk.img` captured mid-write.
        return try VPhoneBundleGuard.withBundleLock(
            directory: bundle.url, operation: VPhoneVMOperation.export
        ) { _ in
            try exportLocked(
                bundle: bundle, name: name, to: outFile, includeIPSW: includeIPSW,
                compression: compression, in: library, progress: progress)
        }
    }

    private static func exportLocked(
        bundle: VPhoneBundle, name: String, to outFile: URL, includeIPSW: Bool,
        compression: ExportCompression, in library: VPhoneLibrary,
        progress: ((Int64, Int64) -> Void)?
    ) throws -> URL {
        var isDir: ObjCBool = false
        let outFile = FileManager.default.fileExists(atPath: outFile.path, isDirectory: &isDir) && isDir.boolValue
            ? outFile.appendingPathComponent("\(name).\(compression.fileExtension)")
            : outFile

        // gnutar (not the bsdtar-default pax): pax extended headers make the
        // consumer's `@-` reader misbid the stream as mtree ("Line too long")
        // on large members; gnutar also carries files >8 GB (ustar cannot).
        var producer = ["--format", "gnutar", "-cf", "-"]
        if !includeIPSW { producer += ["--exclude", "*_Restore*"] }
        for pattern in exportExcludePatterns { producer += ["--exclude", pattern] }
        producer += ["-C", library.root.path, name]
        let consumer = ["-cf", outFile.path] + compression.tarArgs + ["@-"]

        let total = progress != nil
            ? archivedLogicalSize(bundleDir: library.url(forName: name), libraryRoot: library.root, includeIPSW: includeIPSW)
            : 0
        let err = try VPhoneProcessRunner.runCountingTarPipe(
            producerArgs: producer, sourceFile: nil, consumerArgs: consumer
        ) { done in progress?(done, total) }
        if let err { throw VPhoneBundleOpsError.tarFailed(err) }
        return outFile
    }

    /// On-disk logical size of the members `export` will archive, mirroring the
    /// tar `--exclude` patterns so the progress total matches the streamed bytes.
    private static func archivedLogicalSize(
        bundleDir: URL, libraryRoot: URL, includeIPSW: Bool
    ) -> Int64 {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: bundleDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        let prefix = libraryRoot.path.count + 1  // members are "<name>/..."
        var total: Int64 = 0
        for case let url as URL in en {
            let rel = String(url.path.dropFirst(prefix))
            if !includeIPSW, rel.contains("_Restore") { en.skipDescendants(); continue }
            if exportExcludePatterns.contains(where: { fnmatch($0, rel, 0) == 0 }) { continue }
            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  vals.isRegularFile == true else { continue }
            total += Int64(vals.fileSize ?? 0)
        }
        return total
    }

    /// Extracts (auto-detecting gzip/zstd/xz) into a private staging dir, then
    /// promotes the single top-level bundle to the library. Extracting first
    /// means the archive is decompressed once; `progress` is called with
    /// `(bytesDone, totalBytes)` as the compressed file is fed into `tar -x`,
    /// where `totalBytes` is the archive's size on disk.
    public static func importArchive(
        from inFile: URL, name: String?, in library: VPhoneLibrary,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> VPhoneBundle {
        try importArchive(from: inFile, name: name, in: library, progress: progress, afterNameCheck: nil)
    }

    /// `afterNameCheck` is a testing seam: it runs between the destination-name
    /// check and the move that places the bundle, which must be one
    /// library-lock lifetime.
    static func importArchive(
        from inFile: URL, name: String?, in library: VPhoneLibrary,
        progress: ((Int64, Int64) -> Void)?, afterNameCheck: (() -> Void)?
    ) throws -> VPhoneBundle {
        let fm = FileManager.default
        // Fail fast when the destination name is already known (explicit rename).
        if let name {
            try requireValidName(name)
            if fm.fileExists(atPath: library.url(forName: name).path) {
                throw VPhoneLibraryError.alreadyExists(name: name)
            }
        }

        // Extract into a private staging dir so the archive's OWN top-level name
        // can never clobber/merge into an existing bundle of that name; only the
        // validated destination name is ever placed into the library.
        try fm.createDirectory(at: library.root, withIntermediateDirectories: true)
        let staging = library.root.appendingPathComponent(".import-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let total = progress != nil ? fileByteSize(inFile) : 0
        let err = try VPhoneProcessRunner.runCountingTarPipe(
            producerArgs: nil, sourceFile: inFile, consumerArgs: ["-xf", "-", "-C", staging.path]
        ) { done in progress?(done, total) }
        if let err { throw VPhoneBundleOpsError.tarFailed(err) }

        let entries = try fm.contentsOfDirectory(atPath: staging.path)
        guard entries.count == 1, let archived = entries.first else {
            throw VPhoneBundleOpsError.badArchive(
                "expected a single top-level bundle directory, found \(entries.sorted())")
        }
        let finalName = name ?? archived
        try requireValidName(finalName)
        let dst = library.url(forName: finalName)
        let extracted = staging.appendingPathComponent(archived)
        guard fm.fileExists(atPath: extracted.appendingPathComponent("config.plist").path) else {
            throw VPhoneBundleOpsError.badArchive(
                "archive did not contain a valid bundle (\(archived)/config.plist)")
        }
        // Extraction ran outside the lock (it only writes into the private
        // staging dir); the name check and the placement are one lock lifetime.
        try VPhoneBundleGuard.withLibraryLock(root: library.root) { _ in
            if fm.fileExists(atPath: dst.path) { throw VPhoneLibraryError.alreadyExists(name: finalName) }
            afterNameCheck?()
            try fm.moveItem(at: extracted, to: dst)
        }
        return try VPhoneBundle.load(at: dst)
    }

    private static func fileByteSize(_ url: URL) -> Int64 {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return Int64(size ?? 0)
    }
}

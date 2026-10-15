import Darwin
import Foundation
import Testing
import VPhoneArchiveKit
@testable import VPhoneCore

@Suite(.serialized)
struct NativeTransferTests {
    private func withFixture(_ body: (URL, VPhoneLibrary, VPhoneBundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-transfer-\(UUID())")
        let directory = root.appendingPathComponent("library/source")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = VPhoneVirtualMachineManifest(machineIdentifier: Data([9, 8, 7]), cpuCount: 2,
            memorySize: 2 << 30, romImages: .init(avpBooter: "boot.bin", avpSEPBooter: "sep.bin"))
        try manifest.write(to: directory.appendingPathComponent("config.plist"))
        for name in ["Disk.img", "nvram.bin", "SEPStorage", "ticket.shsh", "boot.bin", "sep.bin"] {
            try Data((name + " contents").utf8).write(to: directory.appendingPathComponent(name))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("Disk.img").path)
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("relative-link").path, withDestinationPath: "ticket.shsh")
        try FileManager.default.linkItem(at: directory.appendingPathComponent("ticket.shsh"), to: directory.appendingPathComponent("ticket-copy"))
        try body(root, VPhoneLibrary(root: root.appendingPathComponent("library")), VPhoneBundle(url: directory, manifest: manifest))
    }

    @Test(arguments: VPhoneBundleOps.ArchiveBackend.allCases, VPhoneBundleOps.ExportCompression.allCases)
    func nativeAndSystemArchivesInteroperate(exporter: VPhoneBundleOps.ArchiveBackend,
                                             compression: VPhoneBundleOps.ExportCompression) throws {
        try withFixture { (root: URL, library: VPhoneLibrary, source: VPhoneBundle) throws -> Void in
            let archive = root.appendingPathComponent("export.\(compression.fileExtension)")
            var exported: [(Int64, Int64)] = []
            try VPhoneBundleOps.export(bundleNamed: "source", to: archive, includeIPSW: false,
                compression: compression, in: library, backend: exporter, progress: { exported.append(($0, $1)) })
            let exportCounts = exported.map { $0.0 }
            #expect(!exportCounts.isEmpty)
            #expect(exportCounts == exportCounts.sorted())
            for importer in VPhoneBundleOps.ArchiveBackend.allCases {
                let destination = VPhoneLibrary(root: root.appendingPathComponent(importer.rawValue))
                var progress: [(Int64, Int64)] = []
                let restored = try VPhoneBundleOps.importArchive(from: archive, name: "copy", in: destination,
                    backend: importer, progress: { progress.append(($0, $1)) })
                #expect(restored.manifest.machineIdentifier == source.manifest.machineIdentifier)
                #expect((try FileManager.default.attributesOfItem(atPath: restored.url.appendingPathComponent("Disk.img").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                for name in ["Disk.img", "nvram.bin", "SEPStorage", "ticket.shsh", "config.plist", "boot.bin", "sep.bin"] {
                    #expect(try Data(contentsOf: restored.url.appendingPathComponent(name)) == Data(contentsOf: source.url.appendingPathComponent(name)))
                }
                #expect(try FileManager.default.destinationOfSymbolicLink(atPath: restored.url.appendingPathComponent("relative-link").path) == "ticket.shsh")
                var a = stat(), b = stat()
                #expect(lstat(restored.url.appendingPathComponent("ticket.shsh").path, &a) == 0)
                #expect(lstat(restored.url.appendingPathComponent("ticket-copy").path, &b) == 0)
                #expect(a.st_ino == b.st_ino)
                #expect(!FileManager.default.fileExists(atPath: restored.url.appendingPathComponent(VPhoneVMRuntimeState.filename).path))
                #expect(progress.last?.0 == progress.last?.1)
                #expect(progress.last?.0 == Int64(try Data(contentsOf: archive).count))
            }
            if exporter == .native {
                #expect(exported.last?.0 == exported.last?.1)
                #expect(exported.allSatisfy { $0.0 <= $0.1 })
            }
        }
    }

    @Test(arguments: VPhoneBundleOps.ArchiveBackend.allCases)
    func exportRefusesExistingFilesAndSymlinkLeaves(backend: VPhoneBundleOps.ArchiveBackend) throws {
        try withFixture { root, library, _ in
            let target = root.appendingPathComponent("keep")
            let sentinel = Data("existing archive".utf8)
            try sentinel.write(to: target)
            for kind in ["file", "symlink", "dangling"] {
                let output = root.appendingPathComponent("\(kind).tzst")
                if kind == "file" { try sentinel.write(to: output) }
                else {
                    try FileManager.default.createSymbolicLink(atPath: output.path,
                        withDestinationPath: kind == "symlink" ? target.path : root.appendingPathComponent("missing").path)
                }
                #expect(throws: (any Error).self) {
                    try VPhoneBundleOps.export(bundleNamed: "source", to: output, includeIPSW: false,
                                              in: library, backend: backend)
                }
                if kind == "file" { #expect(try Data(contentsOf: output) == sentinel) }
                else { #expect(VPhoneNativeTransfer.fileType(at: output) == S_IFLNK) }
                #expect(try Data(contentsOf: target) == sentinel)
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(!remaining.contains { $0.hasPrefix(".vphone-export-") })
        }
    }

    @Test(arguments: VPhoneBundleOps.ArchiveBackend.allCases)
    func exportRejectsMissingParentSourceTreeAndAutomaticNameCollision(backend: VPhoneBundleOps.ArchiveBackend) throws {
        try withFixture { root, library, source in
            let collision = root.appendingPathComponent("source.tzst")
            try Data("keep".utf8).write(to: collision)
            for destination in [root, root.appendingPathComponent("missing/out.tzst"),
                                source.url.appendingPathComponent("out.tzst")] {
                #expect(throws: (any Error).self) {
                    try VPhoneBundleOps.export(bundleNamed: "source", to: destination, includeIPSW: false,
                                              in: library, backend: backend)
                }
            }
            #expect(try Data(contentsOf: collision) == Data("keep".utf8))
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
            #expect(!FileManager.default.fileExists(atPath: source.url.appendingPathComponent("out.tzst").path))
        }
    }

    @Test(arguments: VPhoneBundleOps.ArchiveBackend.allCases)
    func exportResolvesParentDirectoryAlias(backend: VPhoneBundleOps.ArchiveBackend) throws {
        try withFixture { root, library, _ in
            let directory = root.appendingPathComponent("exports")
            let alias = root.appendingPathComponent("alias")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: directory.path)
            let output = try VPhoneBundleOps.export(bundleNamed: "source", to: alias, includeIPSW: false,
                                                   in: library, backend: backend)
            #expect(output == directory.appendingPathComponent("source.tzst").resolvingSymlinksInPath())
            let imported = try VPhoneBundleOps.importArchive(from: output, name: "copy", in: library, backend: backend)
            #expect(try Data(contentsOf: imported.url.appendingPathComponent("Disk.img")) == Data("Disk.img contents".utf8))
        }
    }

    @Test(arguments: VPhoneBundleOps.ArchiveBackend.allCases)
    func exportCancellationRemovesPrivateOutput(backend: VPhoneBundleOps.ArchiveBackend) throws {
        try withFixture { root, library, source in
            let destination = root.appendingPathComponent("cancelled.tzst")
            let before = try Data(contentsOf: source.url.appendingPathComponent("Disk.img"))
            let cancellation = VPhoneChildCancellation(log: { _ in })
            defer { cancellation.complete() }
            var observed = false
            #expect(throws: (any Error).self) {
                try VPhoneChildCancellation.$current.withValue(cancellation) {
                    try VPhoneBundleOps.export(bundleNamed: "source", to: destination, includeIPSW: false,
                        in: library, backend: backend, isCancelled: { cancellation.isRequested },
                        progress: { _, _ in
                            guard !observed else { return }
                            observed = true
                            let staging = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.first { $0.lastPathComponent.hasPrefix(".vphone-export-") }
                            #expect(staging != nil)
                            if let staging {
                                var info = stat()
                                #expect(lstat(staging.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
                            }
                            #expect(!FileManager.default.fileExists(atPath: destination.path))
                            cancellation.request(signal: SIGTERM)
                        })
                }
            }
            #expect(observed)
            #expect(cancellation.settle())
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(!remaining.contains { $0.hasPrefix(".vphone-export-") })
            #expect(try Data(contentsOf: source.url.appendingPathComponent("Disk.img")) == before)
        }
    }

    @Test(arguments: VPhoneBundleOps.ArchiveBackend.allCases, [false, true])
    func exportProgressCannotPublishAfterCancellationOrReplaceCompetitor(
        backend: VPhoneBundleOps.ArchiveBackend, cancel: Bool
    ) throws {
        try withFixture { root, library, _ in
            let destination = root.appendingPathComponent("publish.tzst")
            var cancelled = false
            var observed = false
            #expect(throws: (any Error).self) {
                try VPhoneBundleOps.export(bundleNamed: "source", to: destination, includeIPSW: false,
                    in: library, backend: backend, isCancelled: { cancelled }, progress: { done, total in
                        let staging = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?.first { $0.lastPathComponent.hasPrefix(".vphone-export-") }
                        guard !observed, done >= total, let staging else { return }
                        if backend == .native,
                           !FileManager.default.fileExists(atPath: staging.appendingPathComponent("output").path) { return }
                        observed = true
                        if cancel { cancelled = true }
                        else {
                            do { try Data("competitor".utf8).write(to: destination, options: .withoutOverwriting) }
                            catch { Issue.record("could not create competing destination: \(error)") }
                        }
                    })
            }
            #expect(observed)
            if cancel { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
            else { #expect(try Data(contentsOf: destination) == Data("competitor".utf8)) }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(!remaining.contains { $0.hasPrefix(".vphone-export-") })
        }
    }

    @Test func nativeExportHonorsLockExclusionsAndExistingOutput() throws {
        try withFixture { (root: URL, library: VPhoneLibrary, source: VPhoneBundle) throws -> Void in
            let archive = root.appendingPathComponent("out.tzst")
            let lock = try VPhoneVMLock(directory: source.url, operation: VPhoneVMOperation.boot)
            #expect(throws: (any Error).self) {
                try VPhoneBundleOps.export(bundleNamed: "source", to: archive, includeIPSW: false, in: library, backend: .native)
            }
            withExtendedLifetime(lock) {}
        }
        try withFixture { (root: URL, library: VPhoneLibrary, source: VPhoneBundle) throws -> Void in
            for name in ["iPhone_Restore/nested", "cfw_input/nested"] {
                let directory = source.url.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data([1]).write(to: directory.appendingPathComponent("payload"))
            }
            let archive = try VPhoneBundleOps.export(bundleNamed: "source", to: root, includeIPSW: false, in: library, backend: .native)
            #expect(archive.lastPathComponent == "source.tzst")
            let names = try VPhoneArchiveReader.entries(of: archive).map(\.path)
            #expect(!names.contains { $0.contains("_Restore") || $0.contains("cfw_input") || $0.contains(".vphone-runtime") })
            let bytes = try Data(contentsOf: archive)
            #expect(throws: (any Error).self) {
                try VPhoneBundleOps.export(bundleNamed: "source", to: archive, includeIPSW: true, in: library, backend: .native)
            }
            #expect(try Data(contentsOf: archive) == bytes)
            let included = root.appendingPathComponent("included.tzst")
            try VPhoneBundleOps.export(bundleNamed: "source", to: included, includeIPSW: true, in: library, backend: .native)
            #expect(try VPhoneArchiveReader.entries(of: included).contains { $0.path.contains("_Restore/nested/payload") })
        }
    }

    @Test(arguments: ["../outside", "/absolute", "nested/../../outside"])
    func manifestEscapeIsRejectedWithoutPublication(path: String) throws {
        try withFixture { (root: URL, library: VPhoneLibrary, source: VPhoneBundle) throws -> Void in
            let manifest = VPhoneVirtualMachineManifest(cpuCount: 2, memorySize: 2 << 30, diskImage: path, romImages: nil)
            try manifest.write(to: source.configURL)
            let archive = root.appendingPathComponent("invalid.tar")
            try VPhoneArchiveWriter.create(archive: archive, from: source.url, topLevel: "source")
            #expect(throws: VPhoneBundleOpsError.self) {
                try VPhoneBundleOps.importArchive(from: archive, name: "rejected", in: library, backend: .native)
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: library.root.path) == ["source"])
        }
    }

    @Test(arguments: ["external-link", "config-link", "disk-link", "invalid-config", "multiple-roots"])
    func invalidBundlesLeaveNoPublishedFiles(kind: String) throws {
        try withFixture { (root: URL, library: VPhoneLibrary, source: VPhoneBundle) throws -> Void in
            let fm = FileManager.default
            if kind == "external-link" {
                try fm.createSymbolicLink(atPath: source.url.appendingPathComponent("escape").path, withDestinationPath: root.path)
            } else if kind == "config-link" || kind == "disk-link" {
                let path = kind == "config-link" ? source.configURL : source.url.appendingPathComponent("Disk.img")
                try fm.removeItem(at: path)
                try fm.createSymbolicLink(atPath: path.path, withDestinationPath: "ticket.shsh")
            } else if kind == "invalid-config" { try Data("invalid".utf8).write(to: source.configURL) }
            if kind == "multiple-roots" {
                try fm.createDirectory(at: library.root.appendingPathComponent("second"), withIntermediateDirectories: false)
            }
            let archive = root.appendingPathComponent("invalid.tar")
            try VPhoneArchiveWriter.create(archive: archive, from: library.root)
            let destination = VPhoneLibrary(root: root.appendingPathComponent("destination"))
            #expect(throws: (any Error).self) {
                try VPhoneBundleOps.importArchive(from: archive, name: "rejected", in: destination, backend: .native)
            }
            #expect(try fm.contentsOfDirectory(atPath: destination.root.path).isEmpty)
        }
    }

    @Test func publicationIsLockedAndDoesNotOverwriteARacingDirectory() throws {
        try withFixture { (root: URL, library: VPhoneLibrary, source: VPhoneBundle) throws -> Void in
            let archive = root.appendingPathComponent("input.tar")
            try VPhoneArchiveWriter.create(archive: archive, from: source.url, topLevel: "source")
            let target = library.url(forName: "competitor")
            #expect(throws: VPhoneLibraryError.alreadyExists(name: "competitor")) {
                try VPhoneBundleOps.importArchive(from: archive, name: "competitor", in: library, backend: .native, progress: nil, afterNameCheck: {
                    #expect(VPhoneLibraryLockProbe.isLockHeld(root: library.root))
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                    try Data("keep".utf8).write(to: target.appendingPathComponent("sentinel"))
                })
            }
            #expect(try String(contentsOf: target.appendingPathComponent("sentinel"), encoding: .utf8) == "keep")
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == ["sentinel"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: library.root.path).allSatisfy { !$0.hasPrefix(".import-") })
        }
    }

    @Test func nativeTransferPreservesSparseDiskAndPrivateStaging() throws {
        try withFixture { root, library, source in
            let disk = source.url.appendingPathComponent("Disk.img")
            let file = try FileHandle(forWritingTo: disk)
            try file.truncate(atOffset: 256 << 20)
            try file.seek(toOffset: 128 << 20)
            try file.write(contentsOf: Data(repeating: 0x42, count: 4096))
            try file.close()
            let archive = root.appendingPathComponent("sparse.tzst")
            try VPhoneBundleOps.export(bundleNamed: "source", to: archive, includeIPSW: false, in: library, backend: .native)
            var checkedStaging = false
            let imported = try VPhoneBundleOps.importArchive(from: archive, name: "copy", in: library, backend: .native, progress: { _, _ in
                let staging = (try? FileManager.default.contentsOfDirectory(at: library.root, includingPropertiesForKeys: nil))?.first { $0.lastPathComponent.hasPrefix(".import-") }
                if let staging {
                    var info = stat()
                    #expect(lstat(staging.path, &info) == 0)
                    #expect(info.st_mode & 0o777 == 0o700)
                    checkedStaging = true
                }
            })
            #expect(checkedStaging)
            let output = imported.url.appendingPathComponent("Disk.img")
            var info = stat()
            #expect(lstat(output.path, &info) == 0)
            #expect(info.st_size == 256 << 20)
            #expect(info.st_blocks * 512 < info.st_size / 2)
            let before = try FileHandle(forReadingFrom: disk)
            let after = try FileHandle(forReadingFrom: output)
            defer { try? before.close(); try? after.close() }
            while try autoreleasepool(invoking: { () throws -> Bool in
                let a = try before.read(upToCount: 1 << 20) ?? Data()
                let b = try after.read(upToCount: 1 << 20) ?? Data()
                #expect(a == b)
                return !a.isEmpty
            }) {}
        }
    }

    @Test(arguments: VPhoneBundleOps.ArchiveBackend.allCases)
    func importCancellationRemovesStagingAndDoesNotPublish(backend: VPhoneBundleOps.ArchiveBackend) throws {
        try withFixture { root, library, source in
            let archive = root.appendingPathComponent("cancel.tar")
            try VPhoneArchiveWriter.create(archive: archive, from: source.url, topLevel: "source")
            let originalArchive = try Data(contentsOf: archive)
            let originalDisk = try Data(contentsOf: source.url.appendingPathComponent("Disk.img"))
            let cancellation = VPhoneChildCancellation(log: { _ in })
            defer { cancellation.complete() }
            var observed = false
            #expect(throws: (any Error).self) {
                try VPhoneChildCancellation.$current.withValue(cancellation) {
                    try VPhoneBundleOps.importArchive(from: archive, name: "cancelled", in: library,
                        backend: backend, isCancelled: { cancellation.isRequested }, progress: { _, _ in
                            observed = true
                            cancellation.request(signal: SIGTERM)
                        })
                }
            }
            #expect(observed)
            #expect(cancellation.settle())
            #expect(!FileManager.default.fileExists(atPath: library.url(forName: "cancelled").path))
            let remaining = try FileManager.default.contentsOfDirectory(atPath: library.root.path)
            #expect(!remaining.contains { $0.hasPrefix(".import-") })
            #expect(try Data(contentsOf: archive) == originalArchive)
            #expect(try Data(contentsOf: source.url.appendingPathComponent("Disk.img")) == originalDisk)
        }
    }

    @Test(arguments: VPhoneBundleOps.ArchiveBackend.allCases)
    func importCancellationImmediatelyBeforePublication(backend: VPhoneBundleOps.ArchiveBackend) throws {
        try withFixture { root, library, source in
            let archive = root.appendingPathComponent("cancel-publish.tar")
            try VPhoneArchiveWriter.create(archive: archive, from: source.url, topLevel: "source")
            var cancelled = false
            #expect(throws: CancellationError.self) {
                try VPhoneBundleOps.importArchive(from: archive, name: "cancelled", in: library,
                    backend: backend, isCancelled: { cancelled }, progress: nil,
                    afterNameCheck: { cancelled = true })
            }
            #expect(cancelled)
            #expect(!FileManager.default.fileExists(atPath: library.url(forName: "cancelled").path))
            let remaining = try FileManager.default.contentsOfDirectory(atPath: library.root.path)
            #expect(!remaining.contains { $0.hasPrefix(".import-") })
            #expect(FileManager.default.fileExists(atPath: source.url.path))
        }
    }

    @Test(arguments: VPhoneBundleOps.ArchiveBackend.allCases)
    func importRejectsFIFOWithoutCreatingStaging(backend: VPhoneBundleOps.ArchiveBackend) throws {
        try withFixture { root, library, _ in
            let fifo = root.appendingPathComponent("input.tar")
            #expect(mkfifo(fifo.path, 0o600) == 0)
            #expect(throws: VPhoneBundleOpsError.self) {
                try VPhoneBundleOps.importArchive(from: fifo, name: "cancelled", in: library, backend: backend)
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: library.root.path)
            #expect(!remaining.contains { $0.hasPrefix(".import-") })
        }
    }

    @Test(arguments: VPhoneBundleOps.ArchiveBackend.allCases)
    func archiveRootHeaderCannotWidenPrivateStaging(backend: VPhoneBundleOps.ArchiveBackend) throws {
        try withFixture { root, library, _ in
            let archive = root.appendingPathComponent("root-header.tar")
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: library.root.path)
            try VPhoneArchiveWriter.create(archive: archive, from: library.root, topLevel: ".")
            var observed = false
            let imported = try VPhoneBundleOps.importArchive(from: archive, name: "copy", in: library, backend: backend, progress: { _, _ in
                for item in (try? FileManager.default.contentsOfDirectory(at: library.root, includingPropertiesForKeys: nil)) ?? []
                    where item.lastPathComponent.hasPrefix(".import-") {
                    var info = stat()
                    #expect(lstat(item.path, &info) == 0)
                    #expect(info.st_mode & 0o777 == 0o700)
                    observed = true
                }
            })
            #expect(observed)
            #expect(imported.name == "copy")
        }
    }
}

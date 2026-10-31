import ArgumentParser
import Foundation
import VPhoneCore

extension VPhoneBundleOps.ArchiveBackend: ExpressibleByArgument {}

struct VPhoneVMCloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clone",
        abstract: "Copy a stopped VM bundle (using APFS copy-on-write when available)",
        discussion: """
        The source VM must be stopped. Its snapshots, runtime records, control socket and \
        host-local firmware history/plans are not copied.

        By default the copy keeps the machine identifier (ECID), MAC address, NVRAM, SEP \
        storage and every setting, so it acts as a backup of the same device.

        --new-identity clears the machine identifier and MAC address, so the copy gets new \
        ones, and with them a new UDID, on its first start. It also clears fixed IPv4 \
        addresses, port forwards and hand-chosen mDNS names; a derived mDNS name follows \
        the new VM name. NVRAM, SEPStorage and Disk.img remain byte-for-byte copies and \
        share the SEP root secret and Data volume keys created by the original restore \
        (new ECID/MAC/UDID do not create independent cryptographic keys; use full \
        create/restore for independent keys). The host must be trusted again in the guest \
        before lockdown tools work.
        """)

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "source VM name") var name: String?
    @Argument(help: "new VM name") var newName: String?
    @Flag(help: "give the copy a new machine identifier and MAC address on its first start")
    var newIdentity = false

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let newName = try VPhoneVMSelection.resolveNewName(newName, prompt: "New VM name:")
        let source = try lib.library.bundle(named: name)
        let clone = try VPhoneBundleOps.clone(
            bundleNamed: name, to: newName, in: lib.library, newIdentity: newIdentity)
        print("cloned \(name) → \(clone.name)")
        guard newIdentity else { return }
        print("new identity: machine identifier and MAC address are generated on first start")
        for setting in VPhoneBundleOps.networkSettingsClearedByNewIdentity(
            source.manifest.networkConfig, sourceName: source.name
        ) {
            print("cleared \(setting)")
        }
    }
}

struct VPhoneVMExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export", abstract: "Export a VM bundle to a compressed archive (.tzst fast / .txz max)")

    @Option(help: "Archive backend: system-tar (default) or native (real-VM acceptance pending)")
    var archiveBackend: VPhoneBundleOps.ArchiveBackend = .systemTar

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "output archive path") var out: String
    @Flag(help: "densest compression (xz -9) instead of the default fast (zstd -3)") var max = false
    @Flag(help: "include the *_Restore* IPSW directory") var includeIpsw = false

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let compression: VPhoneBundleOps.ExportCompression = max ? .max : .fast
        let bar = VPhoneProgressBar(label: "exporting \(name)")
        let progress = VPhoneTransferProgressReporter(direction: .exportArchive)
        var lastBytes: Int64 = 0
        var lastTotal: Int64?
        let cancellation = VPhoneChildCancellation(log: { _ in })
        cancellation.install()
        defer { cancellation.complete(); cancellation.uninstall() }
        do {
            let outURL = try VPhoneChildCancellation.$current.withValue(cancellation) {
                try VPhoneBundleOps.export(
                    bundleNamed: name, to: URL(fileURLWithPath: out), includeIPSW: includeIpsw,
                    compression: compression, in: lib.library, backend: archiveBackend,
                    isCancelled: { cancellation.isRequested },
                    progress: { done, total in
                        bar.update(done: done, total: total)
                        lastBytes = done; lastTotal = archiveBackend == .native ? total : nil
                        progress?.update(bytes: done, total: lastTotal)
                    })
            }
            bar.finish()
            progress?.update(bytes: lastBytes, total: lastTotal, completed: true)
            print("exported \(name) → \(outURL.path)")
        } catch {
            if let signal = cancellation.requestedSignal {
                cancellation.settle()
                throw ExitCode(128 + signal)
            }
            throw error
        }
    }
}

struct VPhoneVMImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Import a VM bundle from a .tzst/.txz archive")

    @Option(help: "Archive backend: system-tar (default) or native (real-VM acceptance pending)")
    var archiveBackend: VPhoneBundleOps.ArchiveBackend = .systemTar

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "input archive path") var input: String
    @Option(name: .shortAndLong, help: "name for the imported VM (default: the archive's own name)") var name: String?

    func run() throws {
        let bar = VPhoneProgressBar(label: "importing")
        let progress = VPhoneTransferProgressReporter(direction: .importArchive)
        var lastBytes: Int64 = 0
        var lastTotal: Int64?
        let cancellation = VPhoneChildCancellation(log: { _ in })
        cancellation.install()
        defer { cancellation.complete(); cancellation.uninstall() }
        do {
            let bundle = try VPhoneChildCancellation.$current.withValue(cancellation) {
                try VPhoneBundleOps.importArchive(
                    from: URL(fileURLWithPath: input), name: name, in: lib.library, backend: archiveBackend,
                    isCancelled: { cancellation.isRequested },
                    progress: { done, total in
                        bar.update(done: done, total: total)
                        lastBytes = done; lastTotal = total
                        progress?.update(bytes: done, total: total)
                    })
            }
            bar.finish()
            progress?.update(bytes: lastBytes, total: lastTotal, completed: true)
            print("imported → \(bundle.name)")
        } catch {
            if let signal = cancellation.requestedSignal {
                cancellation.settle()
                throw ExitCode(128 + signal)
            }
            throw error
        }
    }
}

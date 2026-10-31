import CryptoKit
import Darwin
import Foundation

extension VPhoneMachineBinding {
    /// Holds the stopped VM lock. Host-only rebinds retain all component origins.
    /// A first legacy binding requires a complete copied snapshot verified by
    /// file hashes and link targets before the metadata is published.
    public static func persistHost(_ version: String, machine: URL,
                                  expected: Snapshot?, firstMigrationBackup: URL? = nil) throws {
        _ = try Self(bundle: version)
        try VPhoneBundleGuard.withBundleLock(directory: machine, operation: VPhoneVMOperation.bindCoreBundle) { _ in
            let manifest = try VPhoneVirtualMachineManifest.load(from: machine.appendingPathComponent("config.plist"))
            let holders = try VPhoneLsof.holders(of: machine.appendingPathComponent(manifest.diskImage))
            if let refusal = VPhoneProcessHolder.diskRefusal(holders.map { VPhoneProcessHolder(pid: $0) }, rerun: "change the Core Bundle again") {
                throw VPhoneMachineBindingError(refusal + " Binding and backup were not changed.")
            }
            let current = try snapshot(machine)
            guard current == expected else { throw VPhoneMachineBindingError("VM binding changed; inspect it before retrying") }
            let next: Self
            if let current {
                next = try current.binding.replacingHost(with: version)
            } else {
                guard let backup = firstMigrationBackup else {
                    throw VPhoneMachineBindingError("First Core Bundle binding requires a stopped VM backup directory")
                }
                let source = machine.resolvingSymlinksInPath().standardizedFileURL
                let destination = backup.resolvingSymlinksInPath().standardizedFileURL
                guard destination != source, !destination.path.hasPrefix(source.path + "/"),
                      !source.path.hasPrefix(destination.path + "/") else {
                    throw VPhoneMachineBindingError("Backup must be outside the VM directory")
                }
                let before = try snapshotInventory(source)
                try VPhoneStoppedSnapshotCopy.copy(from: source, to: destination)
                guard try snapshotInventory(destination) == before, try snapshotInventory(source) == before else {
                    throw VPhoneMachineBindingError("VM backup verification failed; binding was not changed. Preserve the backup for inspection.")
                }
                next = try Self(bundle: version)
            }
            guard try snapshot(machine) == expected else {
                throw VPhoneMachineBindingError("VM binding changed during backup; binding was not changed")
            }
            let temporary = machine.appendingPathComponent(".binding-\(UUID().uuidString).json")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try output.write(contentsOf: encoder.encode(next))
            try output.synchronize()
            try output.close()
            guard try snapshot(machine) == expected else { throw VPhoneMachineBindingError("VM binding changed before publication") }
            let final = machine.appendingPathComponent("launchpad.json")
            let status = expected == nil
                ? renamex_np(temporary.path, final.path, UInt32(RENAME_EXCL))
                : rename(temporary.path, final.path)
            guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard try snapshot(machine)?.binding == next else { throw VPhoneMachineBindingError("Published VM binding could not be verified") }
        }
    }

    private static func snapshotInventory(_ root: URL) throws -> [String: String] {
        var entries: [String: String] = [:]
        func visit(_ url: URL, relative: String) throws {
            if relative == VPhoneVMRuntimeState.filename || relative == "vphone.sock" { return }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                entries[relative] = "directory"
                for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                    try visit(url.appendingPathComponent(name), relative: relative.isEmpty ? name : relative + "/" + name)
                }
            case S_IFLNK:
                entries[relative] = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            case S_IFREG:
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? input.close() }
                let digest = try VPhoneFileDigest.sha256(input).digest
                var after = stat()
                guard fstat(fd, &after) == 0, info.st_dev == after.st_dev, info.st_ino == after.st_ino,
                      info.st_size == after.st_size, info.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      info.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
                    throw VPhoneMachineBindingError("File changed during snapshot verification: \(relative)")
                }
                entries[relative] = digest
            default: throw VPhoneMachineBindingError("Unsupported VM snapshot entry: \(relative)")
            }
        }
        try visit(root, relative: "")
        return entries
    }
}

import Darwin
import Foundation

// MARK: - Activity

/// Whether a machine is in use, for operations that read or replace its state
/// files and need them to stand still: cloning, snapshotting and reverting.
public enum VPhoneBundleActivity {
    /// The files a running VM holds open, and the ones a clone, snapshot or
    /// revert must take together, by their names inside the bundle.
    public static func stateFileNames(of bundle: VPhoneBundle) -> [String] {
        [bundle.manifest.diskImage, bundle.manifest.sepStorage, bundle.manifest.nvramStorage]
    }

    public static func requireStopped(_ bundle: VPhoneBundle) throws {
        try requireStopped(bundle, waitingForReaders: 0)
    }

    public static let readerWait: TimeInterval = 2

    public static func requireStopped(
        _ bundle: VPhoneBundle,
        name: String? = nil,
        waitingForReaders wait: TimeInterval
    ) throws {
        let urls = stateFileNames(of: bundle).map { bundle.url.appendingPathComponent($0) }
        let socket = bundle.url.appendingPathComponent("vphone.sock")
        try requireStopped(
            name: name ?? bundle.name,
            waitingForReaders: wait,
            holders: { processesHolding(urls).map { VPhoneProcessHolder(pid: $0) } },
            socketIsLive: { controlSocketIsLive(socket) },
            sleep: { Thread.sleep(forTimeInterval: $0) }
        )
    }

    static func requireStopped(
        name: String,
        waitingForReaders wait: TimeInterval,
        interval: TimeInterval = 0.1,
        holders: () -> [VPhoneProcessHolder],
        socketIsLive: () -> Bool,
        sleep: (TimeInterval) -> Void
    ) throws {
        var waited: TimeInterval = 0
        while true {
            let found = holders()
            if found.isEmpty {
                if socketIsLive() {
                    throw VPhoneBundleActivityError.running(name: name, holders: [])
                }
                return
            }
            if waited + interval / 2 >= wait || found.contains(where: \.runsMachine) || socketIsLive() {
                throw VPhoneBundleActivityError.running(name: name, holders: found)
            }
            sleep(interval)
            waited += interval
        }
    }

    /// Captures the stat revision of each core state file so an operation can
    /// detect a state file that was modified and closed while copying.
    public static func stateSignature(of bundle: VPhoneBundle) throws -> [String: String] {
        var signature: [String: String] = [:]
        for name in stateFileNames(of: bundle) {
            let url = bundle.url.appendingPathComponent(name)
            var info = stat()
            if lstat(url.path, &info) == 0 {
                signature[name] = try VPhoneTransferSource.file(url)
            } else if errno == ENOENT {
                signature[name] = "missing"
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return signature
    }

    // MARK: - Processes

    static func processesHolding(_ urls: [URL]) -> [pid_t] {
        var targets = Set<FileID>()
        for url in urls {
            var info = stat()
            if stat(url.path, &info) == 0 {
                targets.insert(FileID(device: info.st_dev, inode: info.st_ino))
            }
        }
        guard !targets.isEmpty else { return [] }
        return VPhoneGuestProcesses.allPIDs().filter { holds(pid: $0, anyOf: targets) }
    }

    private struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private static func holds(pid: pid_t, anyOf targets: Set<FileID>) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard filled > 0 else { return false }
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfo()
            let got = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEINFO, &info, Int32(MemoryLayout<vnode_fdinfo>.size))
            guard got == Int32(MemoryLayout<vnode_fdinfo>.size) else { continue }
            let st = info.pvi.vi_stat
            if targets.contains(FileID(device: dev_t(bitPattern: st.vst_dev), inode: ino_t(st.vst_ino))) {
                return true
            }
        }
        return false
    }

    // MARK: - Control socket

    private static func controlSocketIsLive(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK else { return false }
        switch VPhoneUnixSocket.connect(to: url.path) {
        case let .success(fd):
            close(fd)
            return true
        case let .failure(.connect(failure)):
            return failure != ECONNREFUSED && failure != ENOENT
        case .failure(.pathTooLong), .failure(.socket):
            return true
        }
    }
}

// MARK: - Error

public enum VPhoneBundleActivityError: Error, Equatable {
    case running(name: String, holders: [VPhoneProcessHolder])
    case stateChanged(name: String)

    public static func running(name: String, pids: [pid_t]) -> VPhoneBundleActivityError {
        .running(name: name, holders: pids.map { VPhoneProcessHolder(pid: $0) })
    }
}

extension VPhoneBundleActivityError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case let .running(name, holders):
            let (machine, others) = VPhoneProcessHolder.classify(holders)
            guard machine.isEmpty, !others.isEmpty else {
                let who = holders.isEmpty ? "" : " (process \(VPhoneProcessHolder.describe(machine + others)))"
                return "VM '\(name)' is running\(who). Stop it, then try again."
            }
            return "VM '\(name)' is in use: its disk or state files are open in process "
                + "\(VPhoneProcessHolder.describe(others)), which does not run it. "
                + "Try again once that process closes them."
        case let .stateChanged(name):
            return "VM '\(name)' state files changed while the operation was in progress. Stop all writers and try again."
        }
    }

    public var errorDescription: String? {
        description
    }
}

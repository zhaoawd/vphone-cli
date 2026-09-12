import Foundation
import VPhoneCore

/// One JSON request/response per Unix socket connection. Command semantics and
/// optional GUI capabilities live in VPhoneHostCommandExecutor.
@MainActor
final class VPhoneHostControl {
    struct StartError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let socketPath: String
    private var source: DispatchSourceRead?
    private var identity: (device: dev_t, inode: ino_t)?
    private var stopped = false
    private let acceptQueue = DispatchQueue(label: "vphone.hostcontrol.accept")
    private let service: VPhoneHostCommandService
    private let clients = Clients()

    // Client workers own close(); stop only shuts down descriptors while holding
    // the same lock, so it cannot accidentally shut down a reused descriptor.
    final class Clients: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptors: Set<Int32> = []
        private var stopped = false
        private let slots = DispatchSemaphore(value: HostControlIO.maximumConnections)

        func add(_ fd: Int32) -> Bool {
            lock.withLock {
                guard !stopped, slots.wait(timeout: .now()) == .success else { return false }
                descriptors.insert(fd)
                return true
            }
        }

        func closeClient(_ fd: Int32) {
            lock.withLock {
                if descriptors.remove(fd) != nil { close(fd); slots.signal() }
            }
        }

        func stop() {
            lock.withLock {
                stopped = true
                for fd in descriptors { shutdown(fd, SHUT_RDWR) }
            }
        }

        var isStopped: Bool { lock.withLock { stopped } }
    }

    init(socketPath: String, executor: VPhoneHostCommandExecutor) {
        self.socketPath = socketPath
        service = VPhoneHostCommandService(execute: executor.execute)
    }

    func start() throws {
        guard !stopped else { throw StartError(message: "host control already stopped") }
        guard source == nil else { return }
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        var directoryInfo = stat()
        guard lstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o022 == 0 else {
            throw StartError(message: "socket directory must be owned by the current user and not writable by other users")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketPath.utf8CString
        guard !socketPath.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw StartError(message: "invalid or oversized socket path")
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { target in
                for (index, byte) in bytes.enumerated() { target[index] = byte }
            }
        }

        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == geteuid() else {
                throw StartError(message: "refusing to replace a non-socket or another user's socket")
            }
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            guard probe >= 0 else { throw StartError(message: "cannot probe existing socket") }
            guard fcntl(probe, F_SETFL, O_NONBLOCK) == 0 else {
                close(probe)
                throw StartError(message: "cannot configure socket probe")
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            let connectError = errno
            close(probe)
            guard result < 0, connectError == ECONNREFUSED else {
                throw StartError(message: "socket already active or cannot be safely replaced")
            }
            var current = stat()
            guard lstat(socketPath, &current) == 0,
                  current.st_dev == existing.st_dev, current.st_ino == existing.st_ino,
                  unlink(socketPath) == 0 else {
                throw StartError(message: "stale socket changed or cannot be removed")
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError(message: "failed to create socket") }
        var published = false
        defer {
            if !published { close(fd); removeOwnedPath() }
        }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw StartError(message: "failed to configure listener")
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw StartError(message: "bind failed: \(String(cString: strerror(errno)))") }
        var info = stat()
        guard lstat(socketPath, &info) == 0 else { throw StartError(message: "cannot inspect bound socket") }
        identity = (info.st_dev, info.st_ino)
        guard chmod(socketPath, 0o600) == 0 else { throw StartError(message: "failed to set socket permissions") }
        guard listen(fd, Int32(HostControlIO.maximumConnections)) == 0 else {
            throw StartError(message: "listen failed: \(String(cString: strerror(errno)))")
        }
        let service = service
        let clients = clients
        let listener = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        listener.setEventHandler { @Sendable in Self.acceptAvailable(fd, service: service, clients: clients) }
        listener.setCancelHandler { @Sendable in close(fd) }
        source = listener
        published = true
        listener.resume()
        print("[hostctl] listening on \(socketPath)")
    }

    func stop() {
        stopped = true
        service.stop()
        clients.stop()
        source?.cancel()
        source = nil
        removeOwnedPath()
    }

    private func removeOwnedPath() {
        guard let identity else { return }
        var current = stat()
        if lstat(socketPath, &current) == 0,
           current.st_dev == identity.device, current.st_ino == identity.inode {
            unlink(socketPath)
        }
        self.identity = nil
    }

    private nonisolated static func acceptAvailable(_ fd: Int32, service: VPhoneHostCommandService, clients: Clients) {
        while !clients.isStopped {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            HostControlIO.configure(client)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid(), clients.add(client) else {
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async {
                handleClient(client, service: service, clients: clients)
            }
        }
    }

    // This box is written once before signal() and read only after wait().
    private final class Reply: @unchecked Sendable { var data = Data() }

    nonisolated static func handleClient(_ fd: Int32, service: VPhoneHostCommandService, clients: Clients? = nil) {
        defer { if let clients { clients.closeClient(fd) } else { close(fd) } }
        let request: Data
        do {
            guard let data = try HostControlIO.readRequest(fd) else { return }
            request = data
        } catch {
            let response = VPhoneHostCommandExecutor.response(ok: false, error: "\(error)",
                extra: ["code": (error as? HostControlIO.Failure)?.rawValue ?? "io_error"])
            HostControlIO.writeResponse(response + Data([10]), to: fd)
            return
        }
        let reply = Reply()
        let completed = DispatchSemaphore(value: 0)
        Task { @MainActor in
            reply.data = await service.submit(request)
            completed.signal()
        }
        completed.wait()
        HostControlIO.writeResponse(reply.data + Data([10]), to: fd)
    }
}

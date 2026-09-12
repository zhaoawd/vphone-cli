import Foundation
import VPhoneCore

/// One JSON request/response per Unix socket connection. Command semantics and
/// optional GUI capabilities live in VPhoneHostCommandExecutor.
@MainActor
final class VPhoneHostControl {
    private let socketPath: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "vphone.hostcontrol.accept")
    private let service: VPhoneHostCommandService

    init(socketPath: String, executor: VPhoneHostCommandExecutor) {
        self.socketPath = socketPath
        service = VPhoneHostCommandService(execute: executor.execute)
    }

    func start() {
        guard listenFD < 0 else { return }
        let directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        var directoryInfo = stat()
        guard lstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o022 == 0 else {
            print("[hostctl] socket directory must be owned by the current user and not writable by other users")
            return
        }
        var existing = stat()
        if lstat(socketPath, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == geteuid() else {
                print("[hostctl] refusing to replace a non-socket or another user's socket")
                return
            }
            unlink(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[hostctl] failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            print("[hostctl] socket path too long")
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                for (i, byte) in pathBytes.enumerated() {
                    dst[i] = byte
                }
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, addrLen)
            }
        }
        guard bindResult == 0 else {
            print("[hostctl] bind failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        guard chmod(socketPath, 0o600) == 0 else {
            close(fd)
            unlink(socketPath)
            return
        }
        guard listen(fd, Int32(HostControlIO.maximumConnections)) == 0 else {
            print("[hostctl] listen failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        listenFD = fd
        print("[hostctl] listening on \(socketPath)")

        let capturedFD = fd
        let service = service
        acceptQueue.async {
            Self.acceptLoop(listenFD: capturedFD, service: service)
        }
    }

    func stop() {
        service.stop()
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
            unlink(socketPath)
        }
    }

    private nonisolated static func acceptLoop(listenFD: Int32, service: VPhoneHostCommandService) {
        let slots = DispatchSemaphore(value: HostControlIO.maximumConnections)
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else { break }
            HostControlIO.configure(clientFD)
            var uid: uid_t = 0
            var gid: gid_t = 0
            guard getpeereid(clientFD, &uid, &gid) == 0, uid == geteuid(),
                  slots.wait(timeout: .now()) == .success else {
                close(clientFD)
                continue
            }
            // Handle each client on its own worker: commands that block for a
            // while (a long guest shell, a large file_get) must not freeze the
            // rest of the socket surface. Per-command ordering on the guest is
            // still enforced by the vsock request pipeline.
            DispatchQueue.global(qos: .userInitiated).async {
                defer { slots.signal() }
                handleClient(clientFD, service: service)
            }
        }
    }

    // This box is written once before signal() and read only after wait().
    private final class Reply: @unchecked Sendable { var data = Data() }

    nonisolated static func handleClient(_ fd: Int32, service: VPhoneHostCommandService) {
        defer { close(fd) }
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

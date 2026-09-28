import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

enum GuestFileTransfer {
    static func path(from uri: String) throws -> String {
        let components = URLComponents(string: "http://vphoned\(uri)")
        guard let path = components?.queryItems?.first(where: { $0.name == "path" })?.value,
              path.hasPrefix("/"), !path.contains("\0")
        else { throw GuestAPIError.invalidRequest("An absolute path query parameter is required") }
        return path
    }

    static func download(path: String, fileIO: NonBlockingFileIO, channel: Channel) {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            GuestHyperTextHandler.send(APIWire.error("File could not be opened", status: 404), on: channel)
            return
        }
        let handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fd)
        do {
            var statBuffer = stat()
            guard fstat(fd, &statBuffer) == 0, (statBuffer.st_mode & S_IFMT) == S_IFREG else {
                throw GuestAPIError.invalidRequest("Path is not a regular file")
            }
            let region = try FileRegion(fileHandle: handle)
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/octet-stream")
            headers.add(name: "X-Vphone-Instance-ID", value: APISessionIdentity.instanceID)
            headers.add(name: "X-Vphone-Binary-Hash", value: GuestAPI.binaryHash)
            headers.add(name: "Content-Length", value: String(region.readableBytes))
            headers.add(name: "Connection", value: "close")
            channel.write(
                HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: headers)),
                promise: nil,
            )
            fileIO.readChunked(
                fileRegion: region,
                chunkSize: 64 * 1024,
                allocator: channel.allocator,
                eventLoop: channel.eventLoop,
            ) { bytes in
                channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(bytes)))
            }.whenComplete { result in
                try? handle.close()
                switch result {
                case .success:
                    channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                        channel.close(promise: nil)
                    }
                case .failure:
                    channel.close(promise: nil)
                }
            }
        } catch {
            try? handle.close()
            GuestHyperTextHandler.send(APIWire.error(String(describing: error), status: 400), on: channel)
        }
    }
}

final class GuestFileUpload: @unchecked Sendable {
    private let destination: String
    private let transaction: APIFileUploadTransaction
    private let handle: NIOFileHandle
    private let fileIO: NonBlockingFileIO
    private var writes: EventLoopFuture<Void>
    private var pendingWrites = 0
    private let onCommit: ((String) throws -> Void)?

    init(
        destination: String,
        fileIO: NonBlockingFileIO,
        channel: Channel,
        mode: mode_t = 0o644,
        expectedBytes: Int64? = nil,
        onCommit: ((String) throws -> Void)? = nil,
    ) throws {
        let transaction = try APIFileUploadTransaction(destination: destination, expectedBytes: expectedBytes, mode: mode)
        let fd = dup(transaction.descriptor)
        guard fd >= 0 else { throw GuestAPIError.operationFailed("Could not duplicate upload file") }
        self.destination = destination
        self.transaction = transaction
        handle = NIOFileHandle(_deprecatedTakingOwnershipOfDescriptor: fd)
        self.fileIO = fileIO
        writes = channel.eventLoop.makeSucceededFuture(())
        self.onCommit = onCommit
    }

    func append(_ buffer: ByteBuffer, channel: Channel) {
        let start: Int64
        do { start = try transaction.reserve(buffer.readableBytes) }
        catch { transaction.cancel(); channel.close(promise: nil); return }
        pendingWrites += 1
        _ = channel.setOption(ChannelOptions.autoRead, value: false)
        writes = writes.flatMap { [fileIO, handle] in
            fileIO.write(fileHandle: handle, toOffset: start, buffer: buffer, eventLoop: channel.eventLoop)
        }
        writes.whenComplete { [self] result in
            pendingWrites -= 1
            if case .failure = result {
                channel.close(promise: nil)
            } else if pendingWrites == 0, channel.isActive {
                _ = channel.setOption(ChannelOptions.autoRead, value: true)
            }
        }
    }

    func finish(channel: Channel) {
        writes.whenComplete { [self] result in
            do {
                try handle.close()
                switch result {
                case let .failure(error): throw error
                case .success: break
                }
                guard channel.isActive else { transaction.cancel(); return }
                try transaction.commit()
                try onCommit?(destination)
                GuestHyperTextHandler.send(.json(["result": ["path": destination, "size": transaction.size,
                    "instance_id": APISessionIdentity.instanceID, "binary_hash": GuestAPI.binaryHash]]), on: channel)
            } catch {
                transaction.cancel()
                GuestHyperTextHandler.send(APIWire.error(String(describing: error), status: 500), on: channel)
            }
        }
    }

    func cancel() { transaction.cancel() }

    deinit {
        if handle.isOpen {
            try? handle.close()
        }
    }
}

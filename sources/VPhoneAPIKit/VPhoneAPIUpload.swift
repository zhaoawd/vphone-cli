import Darwin
import Foundation

/// A private snapshot keeps URLSession uploads independent of source mutations.
public final class VPhoneAPIUpload: Sendable {
    private let staged: VPhoneAPIDownload
    public var size: Int { staged.size }
    var file: URL { get throws { try staged.uploadFile() } }
    private init(_ staged: VPhoneAPIDownload) { self.staged = staged }

    public static func prepare(data: Data) throws -> VPhoneAPIUpload {
        let file = try VPhoneAPIDownload(directory: FileManager.default.temporaryDirectory)
        try file.append(data, maximumBytes: 1024 * 1024)
        try file.finish(expectedBytes: Int64(data.count))
        return VPhoneAPIUpload(file)
    }

    public static func prepare(path: String) async throws -> VPhoneAPIUpload {
        let operation = Task.detached {
            guard path.hasPrefix("/"), !path.contains("\0") else { throw failure() }
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw failure() }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw failure() }
            guard info.st_size <= 64 * 1024 * 1024 else {
                throw VPhoneAPIError(code: "file_too_large", message: "Upload exceeds 64 MiB")
            }
            let file = try VPhoneAPIDownload(directory: FileManager.default.temporaryDirectory)
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                try Task.checkCancellation()
                let count = read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw failure() }
                if count == 0 { break }
                try file.append(Data(buffer.prefix(count)), maximumBytes: 64 * 1024 * 1024)
            }
            try file.finish(expectedBytes: Int64(file.size))
            return VPhoneAPIUpload(file)
        }
        let result = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        return result
    }

    private static func failure() -> VPhoneAPIError { .init(code: "file_io", message: "Could not read upload source") }
}

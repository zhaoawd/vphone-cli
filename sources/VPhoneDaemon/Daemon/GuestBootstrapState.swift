import CoreFoundation
import Darwin
import Foundation

/// Reads a completion record without rewriting credentials, keys or packages.
/// A present invalid primary marker must not reactivate a legacy installation.
enum GuestBootstrapState {
    struct Installation: Equatable, Sendable { let layout: String; let root: String }
    enum Refusal: Error { case invalidMarker }

    static func read(primary: URL, legacy: URL) throws -> Installation? {
        guard let data = try bytes(primary) ?? bytes(legacy) else { return nil }
        guard let marker = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Refusal.invalidMarker }
        if let installed = marker["installed"] {
            guard let number = installed as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw Refusal.invalidMarker }
            if !number.boolValue { return nil }
        }
        guard let layout = marker["layout"] as? String, let root = marker["jbroot"] as? String,
              validRoot(root, layout: layout) else { throw Refusal.invalidMarker }
        return Installation(layout: layout, root: root)
    }

    static func validRoot(_ root: String, layout: String) -> Bool {
        if layout == "rootless" { return root == "/var/jb" }
        let prefix = "/private/var/containers/Bundle/Application/"
        return layout == "roothide" && root.hasPrefix(prefix) && rootHideName(String(root.dropFirst(prefix.count)))
    }

    static func rootHideName(_ name: String) -> Bool {
        guard name.range(of: "^\\.jbroot-[0-9a-fA-F]{16}$", options: .regularExpression) != nil,
              let value = UInt64(name.dropFirst(8), radix: 16) else { return false }
        let check = (1...7).reduce(UInt8(0)) { $0 ^ UInt8(truncatingIfNeeded: value >> ($1 * 8)) }
        return check == UInt8(truncatingIfNeeded: value)
    }

    private static func bytes(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 65536 else { throw Refusal.invalidMarker }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw Refusal.invalidMarker }
            if count == 0 { break }
            guard count <= 65536 - result.count else { throw Refusal.invalidMarker }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count == info.st_size else { throw Refusal.invalidMarker }
        return result
    }
}

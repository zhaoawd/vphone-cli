import CryptoKit
import Foundation

/// Incremental digest of an already-open file. The caller owns its descriptor
/// and validates its identity before and after reading when required.
enum VPhoneFileDigest {
    static func sha256(_ input: FileHandle) throws -> (digest: String, size: Int64) {
        var hash = SHA256()
        var size: Int64 = 0
        // FileHandle's Foundation read creates autoreleased buffers on macOS.
        // Drain each chunk even when the caller has no surrounding run loop.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
            hash.update(data: chunk)
            size += Int64(chunk.count)
            return true
        }) {}
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}

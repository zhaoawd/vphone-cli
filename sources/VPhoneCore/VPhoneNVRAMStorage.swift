import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Selects the NVRAM operation without recreating existing persistent state.
/// The VM's existing bundle lock must be held by the caller. This is a leaf
/// type check, not a replacement for a trusted directory or the bundle lock.
public enum VPhoneNVRAMStorage {
    public enum StorageError: Error, Equatable {
        case invalidURL
        case notRegularFile(String)
    }

    /// `createNew` MUST create exclusively, without an overwrite option.
    /// Errors from opening existing state propagate; they never trigger creation.
    public static func openOrCreate<Storage>(
        at url: URL,
        openExisting: (URL) throws -> Storage,
        createNew: (URL) throws -> Storage
    ) throws -> Storage {
        guard url.isFileURL, !url.path.utf8.contains(0) else {
            throw StorageError.invalidURL
        }
        var info = stat()
        if lstat(url.path, &info) != 0 {
            let code = errno
            guard code == ENOENT else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                              userInfo: [NSFilePathErrorKey: url.path])
            }
            // A competing creator must be rejected by createNew, not overwritten.
            return try createNew(url)
        }
        // lstat deliberately rejects even dangling symlinks, directories and FIFOs.
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw StorageError.notRegularFile(url.path)
        }
        return try openExisting(url)
    }
}

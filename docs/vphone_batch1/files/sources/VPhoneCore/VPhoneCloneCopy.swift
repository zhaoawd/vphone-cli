import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Copies into a caller-owned private staging directory, never into a public
/// library name. The source VM lock must remain held until publication finishes.
enum VPhoneCloneCopy {
    static func exists(at url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                      userInfo: [NSFilePathErrorKey: url.path])
    }

    /// Returns zero on success, otherwise the errno captured at the call site.
    static func nativeClone(from source: URL, to destination: URL) -> Int32 {
        #if canImport(Darwin)
        return clonefile(source.path, destination.path, 0) == 0 ? 0 : errno
        #else
        // Used by the isolated, framework-free test harness; not a Linux VM backend.
        return ENOTSUP
        #endif
    }

    static func copy(
        from source: URL, to destination: URL, excludingRootNames: Set<String>,
        cloneDirectory: (URL, URL) -> Int32 = nativeClone
    ) throws {
        let fm = FileManager.default
        // An unexpected staging collision is never owned by this copy operation.
        guard try !exists(at: destination) else { throw CocoaError(.fileWriteFileExists) }
        let result = cloneDirectory(source, destination)
        if result != 0 {
            guard result != EEXIST else { throw CocoaError(.fileWriteFileExists) }
            // The caller owns destination's private parent; a failed clone may
            // have left partial output here. Never run this cleanup on a final name.
            if try exists(at: destination) { try fm.removeItem(at: destination) }
            let copier = FileManager()
            let filter = RootItemFilter(source: source, excluded: excludingRootNames)
            copier.delegate = filter
            defer { withExtendedLifetime(filter) {} }
            // Exclude stale Unix sockets BEFORE fallback copying: they are not
            // ordinary files and may make recursive copy fail on non-APFS volumes.
            try copier.copyItem(at: source, to: destination)
        }
        // Native directory clones also include the source lock's diagnostic file.
        // Only exact root-level runtime entries are removed; persistent files,
        // custom storage paths and identically named nested files are untouched.
        for name in excludingRootNames {
            let url = destination.appendingPathComponent(name)
            if try exists(at: url) { try fm.removeItem(at: url) }
        }
    }

    private final class RootItemFilter: NSObject, FileManagerDelegate {
        let excludedPaths: Set<String>
        init(source: URL, excluded: Set<String>) {
            excludedPaths = Set(excluded.map {
                source.appendingPathComponent($0).standardizedFileURL.path
            })
        }
        // Foundation's non-Objective-C implementation requires the complete
        // delegate surface. This private manager is used only for copying.
        func fileManager(_ fm: FileManager, shouldCopyItemAtPath srcPath: String,
                         toPath dstPath: String) -> Bool {
            !excludedPaths.contains(URL(fileURLWithPath: srcPath).standardizedFileURL.path)
        }
        func fileManager(_ fm: FileManager, shouldProceedAfterError error: Error,
                         copyingItemAtPath srcPath: String, toPath dstPath: String) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldProceedAfterError error: Error,
                         copyingItemAt srcURL: URL, to dstURL: URL) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldMoveItemAtPath srcPath: String,
                         toPath dstPath: String) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldMoveItemAt srcURL: URL,
                         to dstURL: URL) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldProceedAfterError error: Error,
                         movingItemAtPath srcPath: String, toPath dstPath: String) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldProceedAfterError error: Error,
                         movingItemAt srcURL: URL, to dstURL: URL) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldLinkItemAtPath srcPath: String,
                         toPath dstPath: String) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldLinkItemAt srcURL: URL,
                         to dstURL: URL) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldProceedAfterError error: Error,
                         linkingItemAtPath srcPath: String, toPath dstPath: String) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldProceedAfterError error: Error,
                         linkingItemAt srcURL: URL, to dstURL: URL) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldRemoveItemAtPath path: String) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldRemoveItemAt URL: URL) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldProceedAfterError error: Error,
                         removingItemAtPath path: String) -> Bool { false }
        func fileManager(_ fm: FileManager, shouldProceedAfterError error: Error,
                         removingItemAt URL: URL) -> Bool { false }
        func fileManager(_ fileManager: FileManager, shouldCopyItemAt srcURL: URL,
                         to dstURL: URL) -> Bool {
            !excludedPaths.contains(srcURL.standardizedFileURL.path)
        }
    }
}

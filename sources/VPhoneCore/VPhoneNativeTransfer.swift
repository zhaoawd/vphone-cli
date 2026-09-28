import Darwin
import Foundation

/// Local transfer policy; adapted from upstream 2.0.8 VPhoneBundleTransfer.
/// Archive codecs remain in VPhoneArchiveKit, while locks and manifests stay in Core.
enum VPhoneNativeTransfer {
    static func fileType(at url: URL) -> mode_t? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    static func validate(_ bundle: VPhoneBundle) throws {
        try checkLinks(in: bundle.url, depth: 0)
        let manifest = bundle.manifest
        var names = ["config.plist", "restore-info.json", "udid-prediction.txt",
                     manifest.diskImage, manifest.nvramStorage, manifest.sepStorage]
        if let rom = manifest.romImages { names += [rom.avpBooter, rom.avpSEPBooter] }
        for name in names {
            let components = name.split(separator: "/")
            guard !components.isEmpty, !name.hasPrefix("/"),
                  !components.contains(".."), !components.contains(".") else {
                throw VPhoneBundleOpsError.badArchive("invalid VM file path: \(name)")
            }
            var path = bundle.url
            for (index, component) in components.enumerated() {
                path.appendPathComponent(String(component))
                if let kind = fileType(at: path), kind != (index == components.count - 1 ? S_IFREG : S_IFDIR) {
                    throw VPhoneBundleOpsError.badArchive("VM file is not a regular file: \(name)")
                }
            }
        }
    }

    private static func checkLinks(in directory: URL, depth: Int) throws {
        // Bound recursion for archives supplied by another machine.
        guard depth <= 128 else { throw VPhoneBundleOpsError.badArchive("VM directory nesting exceeds 128") }
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let file = directory.appendingPathComponent(name)
            switch fileType(at: file) {
            case S_IFDIR: try checkLinks(in: file, depth: depth + 1)
            case S_IFLNK:
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                var climbs = 0
                var descended = false
                guard !target.isEmpty, !target.hasPrefix("/") else {
                    throw VPhoneBundleOpsError.badArchive("symbolic link leaves VM directory: \(name)")
                }
                for component in target.split(separator: "/") {
                    if component == "." { continue }
                    if component == ".." {
                        guard !descended else { throw VPhoneBundleOpsError.badArchive("ambiguous symbolic link: \(name)") }
                        climbs += 1
                    } else { descended = true }
                }
                guard climbs <= depth else { throw VPhoneBundleOpsError.badArchive("symbolic link leaves VM directory: \(name)") }
            case S_IFREG: break
            default: throw VPhoneBundleOpsError.badArchive("unsupported VM file type: \(name)")
            }
        }
    }

    /// Match the native writer's exclusions and count hardlinked payload only once.
    static func logicalSize(of root: URL, excluding patterns: [String]) -> Int64 {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var inodes = Set<String>()
        var total: Int64 = 0
        for case let url as URL in entries {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if patterns.contains(where: { fnmatch($0, relative, 0) == 0 || fnmatch($0, url.lastPathComponent, 0) == 0 }) {
                entries.skipDescendants()
                continue
            }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  inodes.insert("\(info.st_dev):\(info.st_ino)").inserted else { continue }
            total += info.st_size
        }
        return total
    }
}

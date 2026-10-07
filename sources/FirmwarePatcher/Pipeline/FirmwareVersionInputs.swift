import CryptoKit
import Darwin
import Foundation

/// Exact manifest bytes used to resolve gates. This is transaction evidence,
/// not an independently loadable desired configuration or write authorization.
struct FirmwareVersionInputs: Codable, Equatable {
    struct Manifest: Codable, Equatable {
        let name: String
        /// nil only when the manifest was absent at capture time.
        let sha256: String?
        let productVersion: String?
        let productBuildVersion: String?

        init(name: String, sha256: String?, productVersion: String?, productBuildVersion: String? = nil) {
            self.name = name; self.sha256 = sha256; self.productVersion = productVersion
            self.productBuildVersion = productBuildVersion
        }
    }

    let manifests: [Manifest]
    var baseVersion: String? { manifests.first { $0.name == "iPhone-BuildManifest.plist" }?.productVersion }
    var cloudOSVersion: String? { manifests.first { $0.name == "BuildManifest.plist" }?.productVersion }

    static func read(in directory: URL) throws -> Self {
        var manifests: [Manifest] = []
        for name in ["iPhone-BuildManifest.plist", "BuildManifest.plist"] {
            let file = directory.appendingPathComponent(name)
            let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor < 0 {
                if errno == ENOENT {
                    manifests.append(Manifest(name: name, sha256: nil, productVersion: nil))
                    continue
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard info.st_mode & S_IFMT == S_IFREG else {
                throw PatcherError.invalidFormat("Firmware version manifest is not a regular file: \(name)")
            }
            let data = try handle.readToEnd() ?? Data()
            guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw PatcherError.invalidFormat("Invalid firmware version manifest: \(name)")
            }
            var version: String?
            if let value = plist["ProductVersion"] {
                guard let string = value as? String, components(string) != nil else {
                    throw PatcherError.invalidFormat("Unrecognized ProductVersion in \(name)")
                }
                version = string
            }
            var build: String?
            if let value = plist["ProductBuildVersion"] {
                guard let string = value as? String, !string.isEmpty else {
                    throw PatcherError.invalidFormat("Unrecognized ProductBuildVersion in \(name)")
                }
                build = string
            }
            manifests.append(Manifest(name: name,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                productVersion: version, productBuildVersion: build))
        }
        return Self(manifests: manifests)
    }

    /// Reject a changed, newly added, removed, unreadable or corrupt staged source.
    func validate(in directory: URL) throws {
        guard try Self.read(in: directory) == self else {
            throw PatcherError.patchVerificationFailed("Firmware version manifests changed after plan resolution")
        }
    }

    /// Only complete, unsigned decimal components have a known version meaning.
    static func components(_ version: String?) -> [Int]? {
        guard let version else { return nil }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        var values: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part) else { return nil }
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }
}

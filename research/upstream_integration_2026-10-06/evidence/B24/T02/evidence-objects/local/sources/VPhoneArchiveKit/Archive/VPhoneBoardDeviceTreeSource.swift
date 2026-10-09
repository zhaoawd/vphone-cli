import Darwin
import Foundation

/// Read a board original without extracting an IPSW. The caller supplies an
/// independently validated product/board pairing; this checks the archive's
/// version, build, product coverage and requested board member. It does not
/// validate a device catalogue, IM4P payload or publish a FirmwareOriginals receipt.
public struct VPhoneBoardDeviceTreeSource: Sendable {
    public let archive: URL
    public let member: String
    public let contents: Data
    public let productType: String
    public let deviceClass: String
    public let version: String
    public let build: String

    public static func read(from archive: URL, productType: String, deviceClass: String, version: String, build: String) throws -> Self {
        func refuse(_ message: String) -> VPhoneArchiveError { .readFailed(path: archive.path, reason: message) }
        let board = deviceClass.lowercased()
        guard !board.isEmpty, board.utf8.count <= 64,
              board.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
              !productType.isEmpty, !version.isEmpty, !build.isEmpty else { throw refuse("missing firmware identity") }
        let entries = try VPhoneArchiveReader.entries(of: archive, maximumEntries: 200000)
        func regularMember(_ name: String) throws {
            let found = entries.filter { $0.path == name }
            guard found.count == 1, let entry = found.first, entry.fileType & S_IFMT == S_IFREG,
                  entry.linkTarget == nil, entry.hardlinkTarget == nil else { throw refuse("missing, linked or duplicate member: \(name)") }
        }
        try regularMember("BuildManifest.plist")
        let bytes = try VPhoneArchiveReader.readMember("BuildManifest.plist", from: archive, maximumBytes: 4 * 1024 * 1024)
        guard let manifest = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any],
              manifest["ProductVersion"] as? String == version,
              manifest["ProductBuildVersion"] as? String == build,
              (manifest["SupportedProductTypes"] as? [String])?.contains(productType) == true,
              let identities = manifest["BuildIdentities"] as? [[String: Any]] else { throw refuse("IPSW firmware identity does not match") }
        var members = Set<String>()
        for identity in identities {
            guard let info = identity["Info"] as? [String: Any],
                  (info["DeviceClass"] as? String)?.lowercased() == board else { continue }
            guard let components = identity["Manifest"] as? [String: Any],
                  let tree = components["DeviceTree"] as? [String: Any],
                  let treeInfo = tree["Info"] as? [String: Any], let path = treeInfo["Path"] as? String else {
                throw refuse("board identity has no DeviceTree source")
            }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.contains("\\"), !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  parts.last == "DeviceTree.\(board).im4p" else { throw refuse("unsafe or mismatched board DeviceTree member") }
            members.insert(path)
        }
        guard members.count == 1, let member = members.first else { throw refuse("board DeviceTree source is missing or ambiguous") }
        try regularMember(member)
        let contents = try VPhoneArchiveReader.readMember(member, from: archive, maximumBytes: 16 * 1024 * 1024)
        guard !contents.isEmpty else { throw refuse("empty board DeviceTree") }
        return Self(archive: archive, member: member, contents: contents, productType: productType,
                    deviceClass: board, version: version, build: build)
    }
}

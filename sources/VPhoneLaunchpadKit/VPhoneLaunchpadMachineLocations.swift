import CryptoKit
import Darwin
import Foundation
import VPhoneCore

// MARK: - Identity

/// Local Launchpad identity. Separate from upstream `com.vphone.launchpad`
/// so both can coexist on one host: the UserDefaults domain follows the
/// bundle identifier, and the log and support directories use their own name.
public enum VPhoneLaunchpadIdentity {
    public static let bundleIdentifier = "com.vphone.cli.launchpad"
    public static let dataDirectoryName = "vphone-cli-launchpad"

    /// `~/Library/Logs/vphone-cli-launchpad`. B1 computes the path only.
    public static func logsDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(dataDirectoryName, isDirectory: true)
    }

    /// `~/Library/Application Support/vphone-cli-launchpad`. B1 computes the
    /// path only.
    public static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(dataDirectoryName, isDirectory: true)
    }
}

// MARK: - Locations

/// The folders machines live in. The default library is the one
/// `vphone-cli` itself uses (`VPhoneLibrary.defaultRoot()`:
/// `VPHONE_LIBRARY_ROOT`, else `~/.vphone/VMs`); further folders come from
/// the `VPhoneLaunchpadLibraryRoots` default. Each is passed to `vphone-cli`
/// as `--library-root`.
///
/// Roots are canonical, so one folder is not listed twice under two
/// spellings.
public enum VPhoneLaunchpadMachineLocations {
    public static var defaultRoot: String {
        canonical(VPhoneLibrary.defaultRoot())
    }

    /// The resolved path of an existing folder, else the standardized path.
    public static func canonical(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// False while a chosen folder is missing, for example on a volume that
    /// is not mounted.
    public static func isAvailable(_ root: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The nearest existing folder at or above `url`.
    public static func existingAncestor(of url: URL) -> URL {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    public static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// The name of the volume holding `root`, for a narrow column. The full
    /// path goes in the column's help.
    public static func volumeName(_ root: String) -> String {
        let url = existingAncestor(of: URL(fileURLWithPath: root, isDirectory: true))
        return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? abbreviated(url)
    }

    /// Eight hex digits that tell libraries apart in log file names.
    public static func digest(_ root: String) -> String {
        SHA256.hash(data: Data(root.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// A machine's console log. Machines in the default library keep their
    /// names; elsewhere the name gains a digest of the library, since two
    /// libraries may each hold a machine with the same name. B1 only computes
    /// the path; B2 writes it.
    public static func consoleLog(
        _ machine: VPhoneLaunchpadMachinePath,
        suffix: String = "",
        defaultRoot: String = VPhoneLaunchpadMachineLocations.defaultRoot,
        logsDirectory: URL = VPhoneLaunchpadIdentity.logsDirectory()
    ) -> URL {
        let stem = machine.libraryRoot == defaultRoot
            ? machine.name
            : "\(machine.name)-\(digest(machine.libraryRoot))"
        return logsDirectory.appendingPathComponent("\(stem)\(suffix).log")
    }

    /// Added libraries from a stored list: absolute, canonical, not the
    /// default library, each once, in stored order.
    public static func addedRoots(from stored: [String], defaultRoot: String) -> [String] {
        var roots: [String] = []
        for entry in stored where entry.hasPrefix("/") {
            let root = canonical(URL(fileURLWithPath: entry, isDirectory: true))
            if root != defaultRoot, !roots.contains(root) {
                roots.append(root)
            }
        }
        return roots
    }
}
